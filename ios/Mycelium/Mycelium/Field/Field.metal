//
//  Field.metal
//  The living surface. Everything the user stares into is computed here.
//
//  Four kinds of pass:
//    1. fieldFragment  — the selected Form + touch blooms, blended with the
//                        previous frame so strokes persist and get woven in.
//    2. bloomBrightFragment — pull out only what is brighter than white.
//    3. bloomBlurFragment   — separable gaussian, run twice at two spacings.
//    4. presentFragment     — add the glow back, set the black point, tonemap.
//
//  Forms are branches inside fieldFragment. They share the bloom math, the
//  palette, the breath, and the grounding treatment; they differ only in how
//  they turn a point into a scalar. Adding a form is adding a function and a
//  case — nothing outside this file needs to know.
//
//  Safety constraints are in the math, not bolted on:
//    - No strobe. Every animated term is a slow sine or an exponential decay.
//      There is no path through this shader that produces a hard flash.
//    - Luminance is soft-clamped in the present pass, so a pile of overlapping
//      blooms brightens the field but can never blow out to white. Individual
//      sources are now *allowed* past white — see the bloom pass — but the
//      rolloff is what stops the screen as a whole from following them.
//

#include <metal_stdlib>
using namespace metal;

constant int MAX_BLOOMS = 32;
constant float TAU = 6.28318530718;

constant int FORM_MYCELIAL = 0;
constant int FORM_KALEIDOSCOPE = 1;
constant int FORM_TUNNEL = 2;
constant int FORM_WEAVE = 3;

// How much of a tap each form takes. Mycelial is loose and can absorb a lot;
// the geometric forms already carry strong structure and a heavy flare washes
// it out, so they take slightly less.
constant float GLOW_ORGANIC = 1.0;
constant float GLOW_STRUCTURED = 0.85;

/// Struck-bell envelope for a tap: rise, then a long fall. Returns 0 at age 0,
/// peaks at ~0.26s, and is normalised so one tap at full strength peaks at 1.
///
/// The rise is deliberately not instant. A tap now brightens the entire screen
/// rather than one spot, and instant global steps at a tapping cadence land
/// squarely in the photosensitivity band — a soft attack keeps the modulation
/// smooth no matter how hard the screen gets hit.
static inline float tapEnvelope(float age) {
    return (exp(-age * 2.2) - exp(-age * 6.0)) * 2.82;
}

/// Octaves per second of kaleidoscope zoom. One octave = the view has doubled
/// in magnification. Walked up twice: 0.10 (a doubling every 10s) read as
/// unmistakably moving but slow, 0.16 had more of the falling-in quality the
/// form is for, and 0.20 — every 5s — is where it starts to feel like the
/// pattern is coming to meet you. Past ~0.25 it stops being something you can
/// rest your eyes on.
///
/// Changing this alone is safe: the feedback contraction is derived from it, so
/// the trail rate follows automatically. They must never be set independently —
/// see the note in the feedback block for what happens when they disagree.
constant float KALEIDO_ZOOM_RATE = 0.20;

// ── The colony is a tree ───────────────────────────────────────────────────
//
// Everything before this described the colony as a *region* — a margin that
// advanced outward, with the mat drawn inside it. Two versions of that, and
// both failed the same way for the same reason.
//
// The first thresholded a radius and grew mat wherever the noise peaked, so
// branches turned up in mid air. The march that replaced it fixed exactly that
// by making a point's age the cost of getting to it, and the strictly positive
// integrand guaranteed the grown set was star-shaped — one interval along every
// ray, no gaps behind anything.
//
// Which is also precisely why it could never web. **A star-shaped set whose
// boundary is a function of angle is a blob with a wiggly edge.** There is no
// branching topology anywhere in it: no junction, no fork, nothing that is the
// child of anything. What looked like branching was the Worley mat underneath —
// a space-filling foam, drawn everywhere the blob had got to — and the blob
// itself just got steadily bigger, which is what "it's slowly expanding, it's
// not webbing" is describing.
//
// So the colony is a tree now: an actual one, with a root and children. One
// trunk splits into two, each of those splits into two, seventeen levels deep.
// A pixel finds its own nearest branch by walking down from the root, which
// costs one iteration per level rather than one per branch — the whole reason a
// tree with thousands of tips is affordable per pixel at all.
//
// Growth is then not a boundary moving at all. It is levels arriving in order,
// with each branch extending out of its parent's tip. Connectivity is no longer
// a property that has to be argued from an integral; it is the data structure.

/// Loop bound only. What actually stops the descent is `grown` running out —
/// see `mycelialTree`. Seventeen is what a couple of taps' worth of pull-back
/// can afford before twigs go sub-pixel.
constant int   TREE_LEVELS = 17;

/// The first branch, in field units, where the screen is 1.0 tall.
///
/// Lengths shrink geometrically after it, so the colony's radius is the partial
/// sum TRUNK * (1 - SHRINK^n)/(1 - SHRINK) — 0.83 at eleven levels, which is
/// past the corners once the branches' zigzag is taken off. SHRINK is also what
/// keeps the outer levels legible: at 1.0 every generation would add the same
/// length while doubling the branch count, and the rim would pack into a solid
/// thicket within three levels of filling the frame.
constant float TREE_TRUNK  = 0.145;
constant float TREE_SHRINK = 0.870;

/// Half-angle of a fork, in radians, and how far a branch's own angle is free
/// to wander from it. SPREAD near 0.6 (~34 degrees) is the value at which a
/// tree reads as a tree — much tighter and the two children look like one line
/// that got thicker, much wider and every fork reads as a T-junction.
///
/// Both children's angles come from a hash of the branch path, so they are
/// never actually symmetric. That matters more than it sounds: the descent
/// below folds space with `abs`, which on its own builds a perfectly mirrored
/// canopy, and mirror symmetry is the single most artificial-looking thing a
/// fractal tree can have.
constant float TREE_SPREAD = 0.58;
constant float TREE_WANDER = 0.045;   // and the whole tree sways, very slowly

/// How much each branch curves, as the sideways offset of its own tip in
/// branch lengths. **This is the difference between a tree and a diagram of
/// one.** Straight segments meeting at hard angles is what a fractal tree looks
/// like when nothing bends it, and no growing thing does that — a hypha is laid
/// down by a tip that is steering as it goes, so it arrives somewhere curved.
///
/// A branch is therefore a parabola rather than a segment, and the child frame
/// is rotated by the tangent at the tip rather than by the branch's own
/// direction, so the curve carries through the fork instead of resetting at it.
/// That continuation is most of it: it's what makes a limb read as one
/// continuous sweep that happens to shed side branches.
///
/// Distance is measured to the curve point at the STRAIGHT projection's
/// parameter, not to the true nearest point. Off by O(bend^2), which at this
/// amplitude is well inside the width of the cord it's drawing.
constant float TREE_BEND = 0.80;

/// Cord half-width at the trunk, and the ratio per level. 0.86^10 is 0.22, so
/// a twig is about a fifth of the trunk's thickness — enough that the hierarchy
/// is readable at a glance, not so much that twigs vanish.
constant float TREE_WIDTH = 0.0110;
constant float TREE_TAPER = 0.860;

/// Some tips give up. Without this every branch runs to the level cap and the
/// rim comes out as a uniform fringe of equal-length twigs, which is the one
/// thing that gives a fractal tree away as generated.
///
/// They are STUNTED, not terminated, and that distinction was a bug worth
/// keeping. Ending the descent at a dead tip means the whole region of space
/// that would have been served by that subtree gets nothing — and because the
/// descent commits to a side at every level, the region it gets nothing in is
/// bounded by straight bisector lines. What that looked like was hard-edged
/// black wedges cutting across the colony, running clean off the frame. A
/// stunted branch still has its subtree, folded into a knot a third of the
/// size, so there is always something there and the edge is soft.
constant float TREE_STOP  = 0.11;
constant float TREE_STUNT = 0.55;

/// Three primaries, held back from each other so the first thing on screen is
/// **one** line. STAGGER is in levels: at half a level apart, the second trunk
/// starts about three seconds after the first.
///
/// All three are tested for every pixel rather than picking the nearest by
/// angle. Wedging the screen into thirds would be cheaper and is wrong — by
/// level six a branch has wandered well past 60 degrees from its trunk, so the
/// wedge boundary would cut it off mid-air along a straight radial line.
constant float TREE_PRIMARIES = 3.0;
constant float TREE_STAGGER   = 0.50;
constant float TREE_TILT      = 0.40;   // so the trunks aren't axis-aligned

/// How far the fuzz reaches off a cord: a multiple of that cord's own
/// half-width, plus a floor.
///
/// The multiple is what makes the hierarchy read — a trunk carries a broad
/// felted sheath and a twig a thin one. The floor is what makes it a WEB. A
/// halo that scales purely with width leaves the voids between major limbs
/// completely empty, and a tree with clean black gaps between its limbs is a
/// tree, not a mycelium. At 0.030 the sheaths of neighbouring limbs overlap and
/// the Worley layer — which is space-filling, and was the whole form once —
/// runs continuously across the gap as fine hyphae bridging between cords,
/// which is exactly what the real thing does.
constant float TREE_HALO       = 3.0;
constant float TREE_HALO_FLOOR = 0.021;

/// How much finer the mat texture is than the tree. The Worley layer used to be
/// the whole form and sat at ~10 cells across the screen; it is now a sheath
/// around branches whose twigs are ~0.02 long, so it has to be far finer than
/// it was or the fuzz is coarser than the thing it's fuzzing.
constant float TREE_TEX_SCALE = 5.5;

/// Ages, in **levels** — the unit growth is now counted in. A level takes
/// between 7s and 1.5s depending on how deep it is (see `Colony` in
/// FieldState.swift: tip speed is constant, so a shorter branch takes less
/// time), which means a trunk spends far longer thickening than a twig does.
/// That's the right way round; thick things do take longer.
///
/// The staging is the point. A real colony throws bare leading hyphae out first
/// and fills in behind them, so a cord arrives thin and alone, the mid net a
/// level later, and the fine hyphae last. Turn them all on together and each
/// branch materialises at full complexity, which is the "it was already there"
/// read this whole form has been fighting.
constant float AGE_EMERGE = 0.05;   // a cord fades up right at the tip
constant float AGE_TIP    = 0.42;   // reach of the bright growing tip
constant float AGE_THICK  = 2.20;   // cords reach full width
constant float AGE_MID    = 1.10;   // the mid net starts filling in
constant float AGE_FINE   = 2.60;   // fine hyphae fill the gaps last
constant float AGE_SETTLE = 5.00;   // and then the mat goes quiet again

/// What settled mat looks like. This is a legibility decision before it's an
/// aesthetic one: rendered at one intensity everywhere, the deep interior is so
/// dense that the branching cannot be read through it, and the margin — the
/// only part anyone can follow — is a thin ring around a screenful of noise.
/// Old mat drops toward half brightness and loses most of its fine hyphae, so
/// the light is where the growth is.
constant float MAT_SETTLED_DIM  = 0.60;
constant float MAT_FINE         = 0.60;   // fine hyphae, freshly filled in
constant float MAT_FINE_SETTLED = 0.38;   // and once the mat has quieted

/// Both of those are far gentler than they were, and the reason is that the
/// legibility problem they were solving is gone. They existed because the mat
/// filled the whole screen and the interior was too dense to trace through, so
/// old mat had to get out of the way. The mat is a sheath on a tree now and
/// most of the frame is black — there is nothing to see through — so settling
/// this hard just stripped every branch back to a flat painted stroke.

/// Base frequency of the fine threads, in cycles per unit of the coordinate
/// `mycelialLayer` is handed. It is called at TREE_TEX_SCALE now, so this is
/// the old 228 divided back down by it: left alone, the threads landed at ~1250
/// cycles across the screen, which is two pixels a line pair, and what came out
/// was not hyphae but the moire of two aliasing grids.
constant float MAT_THREAD_FREQ = 55.0;

/// Cell size and contrast, both moved for the same reason as the dimming.
///
/// Cells were 7.0 and 17.0, which put around fifteen coarse cells across a
/// screen — a convincing mat, and too many to follow. At 0.72 of that it's
/// nearer ten, which still reads as grown rather than as a diagram (four would
/// be a diagram) but leaves each cord long enough to trace from one junction to
/// the next. The gamma crushes the mid-tones so cords separate from the fuzz
/// instead of sitting in the same tonal band as it.
/// Brightness of the advancing front, drawn as a line in its own right rather
/// than as the mat lit up. Without it a finger whose tip lands on an empty
/// patch of mat reads as a detached scrap — see the note at `frontLine`.
constant float MARGIN_LINE = 0.80;

constant float MAT_CELL  = 0.72;
constant float MAT_GAMMA = 1.55;

/// How far past white a growing tip is allowed to go. This form measured at
/// 70% near-black and *zero* pixels above 200/255 — dark, which is right, and
/// with nothing bright in it at all, which is why it read as flat no matter how
/// the palette moved. The reference frames are the same deep black with 1.5–2%
/// of the pixels genuinely blown out, and that small bright fraction is doing
/// most of the work.
///
/// Tips are the right thing to spend it on: they are already the subject of the
/// form, they are a cord-width across so the lit area stays tiny, and they fade
/// as `age` passes AGE_TIP — so a settled colony has no hot spots left and the
/// screen doesn't slowly accumulate brightness. `front` peaks at 1, so this is
/// the multiple of white a brand-new tip reaches.
constant float MAT_TIP_HEAT = 3.2;

/// Tunnel geometry. COLUMNS is how many beads go around the corridor and
/// **must stay a whole number** — theta wraps at the negative x-axis and the
/// column coordinate jumps by exactly this there, so an integer lands back on
/// the tiling and anything else leaves a seam down that line.
///
/// ROW is the height of one row in log-radius. It is not free: the beads are
/// round, rows are staggered half a column, and circles pack tightest when the
/// row spacing is sqrt(3)/2 of the column spacing. So ROW = (TAU / COLUMNS) *
/// 0.866. Change COLUMNS and this has to move with it or the packing opens up.
///
/// COLUMNS also sets how deep the corridor looks, which is less obvious. Fewer
/// beads around means each is bigger on screen AND each row is taller in
/// log-radius, so fewer rings fit between the rim and the vanishing point. 22
/// was a long shaft; 17 is a bowl of marbles.
constant float TUNNEL_COLUMNS = 17.0;
constant float TUNNEL_ROW = 0.3200;

/// Bead radius, in column widths.
///
/// An earlier version of this comment claimed a hard ceiling of half the
/// nearest-neighbour distance — 0.433, falling out of the shear — because going
/// over it fused rows of beads into columns. That was true of the version that
/// tested only the pixel's own rectangular cell. It stopped being true the
/// moment the nine-way nearest-centre search went in, and the reason is worth
/// keeping: with nearest-site assignment, two overlapping discs don't blend
/// into a blob, they meet along the perpendicular bisector between their
/// centres. Overlap is a *flat contact*, which is what a jar of marbles under
/// its own weight actually looks like.
///
/// So this is free to go past 0.5, and the useful range runs to about 0.577 —
/// the circumradius of the packing, where the last triple-point gaps close and
/// there is no mortar left at all.
constant float TUNNEL_BEAD = 0.475;

/// How square. 0 is circles; 1 is a superellipse of order four, which is a
/// rounded square. Squareness closes the packing without moving the centres —
/// a square of half-width 0.5 reaches 0.71 into its corners — so the triple-
/// point gaps shrink and the beads meet along longer flats.
constant float TUNNEL_SQUARE = 0.42;

/// How much of a cylinder rather than a sphere. This is the whole difference
/// between a marble and a rod: a sphere's normal turns in both directions at
/// once and its highlight is a dot, while a cylinder's turns in one and its
/// highlight is a LINE down the axis. At 0.65 the surface bends mostly across
/// the corridor, so each bead carries a long straight glint running outward and
/// its ends stay flat and bright, the way a cut rod's do.
constant float TUNNEL_CYL = 0.65;

/// The mortar between beads glows and a wave runs down it.
///
/// TRAVELLING, not blinking. A wave moving along the corridor keeps total
/// screen luminance essentially constant — the bright part is always somewhere,
/// just not here — whereas the same swing applied globally is whole-field
/// modulation, which is the one thing this shader must never do. WAVE is in
/// cycles per row and DRIFT is radians per second, so a fixed point sees
/// DRIFT/TAU = 0.09 Hz. Two orders of magnitude below the photosensitive band.
///
/// FLOOR was 0.07 and is now zero, which is a reversal worth writing down. The
/// floor came from a direct request — the gaps should glow and pulse rather
/// than be black — and it did that, but a floor is a floor everywhere, so the
/// corridor came out as a lit grey room with beads in it. Measured against the
/// reference the difference was stark: 67% of that frame is near-black and
/// 2.2% is genuinely blown out, and ours had 26% near-black and *zero* pixels
/// above 200/255. The glow was there. The dark it needs to sit against wasn't.
///
/// So the pulse survives and the floor doesn't. SHARP raises the wave to a
/// power, which pins the troughs at zero and narrows the peak into a band, and
/// SWING nearly doubles to pay for the narrowing. Brighter than it ever was,
/// over less of the corridor, against black.
constant float TUNNEL_GAP_WAVE  = 1.9;
constant float TUNNEL_GAP_DRIFT = 0.58;
constant float TUNNEL_GAP_FLOOR = 0.0;    // and now it really is black
constant float TUNNEL_GAP_SWING = 1.55;
constant float TUNNEL_GAP_SHARP = 3.0;

/// …and how the bright band gets to be bright, which took one wrong turn to
/// find. Removing the floor put the mortar's brightness into `t`, and `t` is a
/// palette coordinate — so a bright band was a band FURTHER ALONG THE RAMP, at
/// 0.43 of it, which in these palettes is cream. Gaps came out pale exactly
/// where the light was strongest. The corridor was black in the shadowed
/// sectors and a white wash in the lit ones, which is worse than the floor it
/// replaced and for the same underlying reason: brightness had again been
/// spelled as colour.
///
/// So the band barely moves `t` — it stays down at the dark end of the ramp
/// with the rest of the corridor — and it goes into `shade` instead, which
/// multiplies after the palette and has no ceiling. The result is a saturated
/// dark colour turned up past white rather than a pale one: an emitting seam,
/// which is what the reference has and what a lighter grey can never be.
///
/// 1.6 puts the peak of the band at ~3.5x white, so the bloom pass carries it.
constant float TUNNEL_GAP_GLOW = 1.6;

/// The hot core at the vanishing point. STRENGTH multiplies `shade`, so 3.4
/// puts the middle of the corridor at over four times white — carried by the
/// float accumulation buffer instead of clipped, and picked up by the bloom
/// pass, which is the entire point of it. TIGHT is the falloff: 420 makes the
/// core about 0.05 field units across, roughly 5% of screen height.
///
/// Tiny on purpose, and the reason is in the note by `depth`. This form's
/// history is sampled slightly inward every frame, so anything broad at the
/// centre gets dragged outward across the whole screen and re-added as fog. A
/// core this small has no wide tail to drag and its trail is gone in three
/// frames.
constant float TUNNEL_CORE       = 3.4;
constant float TUNNEL_CORE_TIGHT = 420.0;

/// Rows per second of travel. **This is a safety constant, not a taste one.**
/// Bright tiles sweeping outward past dark gaps is periodic whole-field
/// luminance modulation at exactly one cycle per row — so this number, in rows
/// per second, is a flicker frequency in Hz. The photosensitive band starts
/// around 3Hz. Do not raise it into single digits.
///
/// 0.30 was picked as "obviously safe" without anything to check it against,
/// and it was too slow: at that rate the corridor drifts rather than travels,
/// which is most of why this form read as marbles turning instead of as a ride.
///
/// 0.62 is measured. Fitting a similarity transform between successive frames
/// of the reference clip gives it travelling at 0.145–0.335 log-radius per
/// second; ours was 0.096. Dividing by TUNNEL_ROW puts the reference at
/// 0.45–1.05 rows per second, and 0.62 sits in the middle of that. It is still
/// nearly five times clear of 3Hz — the headroom was never the constraint, the
/// absence of a number to aim at was.
constant float TUNNEL_SPEED = 0.62;

/// How far the rings wind into spiral arms. Swept through zero by a slow sine,
/// so the form passes through concentric rings and out the other side into
/// spirals leaning the opposite way.
///
/// Down from 1.3, then from 0.75, and the last cut bought two things at once.
/// Shear is what lets neighbouring beads approach each other (see TUNNEL_BEAD),
/// so less of it raises the ceiling on the radius and the packing can close up
/// — and a shallower spiral reads as rounder and more gathered. There is still
/// plenty of it: the colour travelling outward in a spiral is the whole reason
/// this form isn't a target, and that survives at 0.30 intact.
constant float TUNNEL_TWIST = 0.30;

/// Lobes. Without these the packing is a rigid lattice being rotated, and it
/// reads exactly like that — marbles spinning, not a corridor flowing. Bending
/// the log-polar coordinates *before* the packing means the whole lattice
/// waves: rows swell and pinch, beads slide against their neighbours, and the
/// highlights slide across them because the surface under them moved.
///
/// **LOBES must be a whole number**, for the same reason TUNNEL_COLUMNS is.
/// These are driven off the raw angle, which jumps a full turn at the negative
/// x-axis; sin(a * L) only survives that jump if L is an integer.
/// Amplitude is capped by shape, not by taste. The warp is not conformal — its
/// derivative with respect to the angle shears the row axis — so a bead that is
/// a circle in the warped coordinates comes back to the screen as an ellipse,
/// and the stretch scales with LOBE_R * LOBES. At 0.085 with three lobes every
/// bead was an egg and the packed-marble read was gone. Half that keeps the
/// wave and leaves them round enough to stay marbles.
constant float TUNNEL_LOBES  = 3.0;
constant float TUNNEL_LOBE_R = 0.036;  // how much the rings swell and pinch
constant float TUNNEL_LOBE_A = 0.026;  // and how much they lean side to side

/// A wave travelling *down* the corridor, which is a different thing from the
/// lobes and does the job the lobes couldn't.
///
/// The lobes bend the angle, and bending an angle shears — the warp isn't
/// conformal, so amplitude turns beads into eggs and the useful range is tiny.
/// This one only ever moves the log-radius, and its derivative is a pure
/// stretch along the row axis: rows bunch up and spread apart as it passes and
/// the beads stay the shape they were. Amplitude is therefore free in a way the
/// lobes' never was, which is why this can be a wave you actually see.
///
/// A * K is the stretch, so those two trade against each other: 0.09 * 1.8
/// packs and unpacks the rows by about a sixth as the wave goes by. TILT makes
/// the wavefront a spiral rather than a ring, and **must be a whole number** —
/// it multiplies the raw angle, which jumps a full turn at the negative x-axis.
///
/// It runs at 0.55 / 1.8 = 0.31 log-radius per second against the beads' own
/// 0.198, so the wave still overtakes them and the corridor flexes rather than
/// the whole lattice sliding as one piece — but by 1.6x now rather than 3.2x,
/// since the beads sped up and this didn't. That is the right side to lose the
/// margin on: this is the one thing left that is *supposed* to move against the
/// travel, and a flex that outruns the corridor threefold reads as the corridor
/// wobbling. If the wave stops reading at all, raise RATE rather than cutting
/// TUNNEL_SPEED, which has a measurement behind it and this doesn't.
constant float TUNNEL_WAVE_A    = 0.090;
constant float TUNNEL_WAVE_K    = 1.80;
constant float TUNNEL_WAVE_RATE = 0.55;
constant float TUNNEL_WAVE_TILT = 2.0;

/// The colour is a spiral coming out of the middle, and the beads have none of
/// their own.
///
/// The version before this hashed a hue per bead, which made a jar of mixed
/// marbles — every bead a painted object carrying its own colour around. What
/// a reflective object actually does is the opposite: it has no colour, it
/// shows you the colour of what's around it, and the colour therefore belongs
/// to the *room* and stays put while the objects move through it.
///
/// So the palette coordinate is a function of position only: a logarithmic
/// spiral, which in log-polar coordinates is just a straight line, so it costs
/// one sine. SPIRAL_A is how many arms and **must be a whole number** for the
/// same seam reason as everything else driven off the raw angle.
///
/// **The colour is painted on the corridor and travels with it.** There used to
/// be a RATE constant here giving the spiral its own outward speed, slower than
/// the beads', so the two slid against each other. That is a defensible thing
/// for a light to do and it is not what this form is: two things drifting past
/// each other at similar speeds reads as neither of them moving, just as
/// churning. Locked to the beads instead, the colour is a property of the
/// corridor — the walls are painted, and what changes the colour is that you
/// are travelling through it. Everything on screen now moves as one piece, and
/// the form finally has a direction.
///
/// SPIRAL_R is low on purpose. It sets how much palette a SINGLE BEAD spans,
/// and a bead that spans much of the ramp is a rainbow again however the colour
/// got there. At 0.32 and one arm a bead crosses about a sixth of the ramp,
/// which leaves the sectors big enough to read as regions of colour rather than
/// as a gradient — which is what the reference has and what a fine spiral
/// never gave us.
constant float TUNNEL_SPIRAL_R    = 0.32;   // colour cycles per unit log-radius
constant float TUNNEL_SPIRAL_A    = 1.0;    // arms

/// **Nothing per bead touches `t` at all any more, and that is the point.**
///
/// Two ways to make a bead look reflective: give it the colour of what's around
/// it, or give it the *brightness* of what's around it. The first was tried
/// twice and failed twice, both times for the same reason — `t` is a scalar
/// into a cosine palette that runs a full cycle over 0..1, so anything sweeping
/// a decent fraction of that range across one bead is a rainbow on every bead,
/// however principled the thing doing the sweeping was. It got there first
/// through the reflection strength and then through the two speculars.
///
/// So the colour is purely emitted now. There is a light at the vanishing point
/// whose colour changes, and it travels outward: `t` is a function of position
/// and time and nothing else, so every bead in a ring shares a colour and the
/// colour marches out through them. What makes them look polished is brightness
/// sliding across their faces — `env`, `rim` and the two speculars, all of
/// which go through `shade` and `detail`, neither of which can move the hue. A
/// mirror in a room lit by one colour is exactly this.
///
/// This is the knob for how much the light reads as light rather than as tint.
constant float TUNNEL_LIGHT = 0.42;

/// How much light reaches the side of a bead facing away. Low enough that the
/// terminator is unmistakable — a sphere is legible as a sphere because of
/// where it goes dark, not because of its highlight — and high enough that the
/// dark side keeps its colour instead of becoming a silhouette.
constant float TUNNEL_AMBIENT = 0.30;

// **This struct is declared twice** — here and in FieldRenderer.swift. There is
// no shared header and nothing checks that they agree, so adding a field to one
// side still compiles cleanly and silently reinterprets memory on the other.
// Every field is a float4 for the same reason: no padding, so the two layouts
// can only disagree in ways that are obvious to read.
struct Uniforms {
    float4 resTime;     // xy = resolution px, z = time s, w = breath phase 0..1
    float4 groundCount; // x = grounding 0..1, y = bloom count, z = seed, w = form
    float4 holdParams;  // x = hold amount 0..1, y = hold phase 0..1, z = frame dt s, w spare
    float4 colony;      // x = colony reach, y = zoom push octaves, z = push delta this frame, w spare
    float4 palA;        // IQ cosine palette: bias
    float4 palB;        //                    amplitude
    float4 palC;        //                    frequency
    float4 palD;        //                    phase
};

// xy = position in field space, z = birth time, w = strength.
//
// Nothing in this shader reads xy — a tap answers everywhere at once, so a
// touch in the corner and a touch dead centre produce an identical field.
// Position stays in the event log on purpose: it costs nothing, and that log is
// the substrate both sync and replay are built on.
typedef float4 Bloom;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle — no vertex buffer needed.
vertex VertexOut fullscreenVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = p;
    return out;
}

// MARK: - Noise

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);  // smoothstep interpolation
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// The five-octave fbm and ridged that used to live here are gone. Nothing
// shipping called either, they warned on every build, and the three-octave
// versions down beside the mycelial code — fbm3 and ridged3 — are what the
// forms actually reach for. In the history if a fifth octave is ever wanted.

// Inigo Quilez cosine palette. Smooth and cyclic by construction, which is
// why it can't produce a hard color jump.
static inline float3 palette(float t, float4 a, float4 b, float4 c, float4 d) {
    return a.rgb + b.rgb * cos(TAU * (c.rgb * t + d.rgb));
}

// MARK: - Forms

/// One evaluation of the Kali set. Split out because the infinite zoom needs
/// the same fractal sampled at two magnifications in the same frame.
///
/// Ten passes rather than nine. Every extra pass adds a finer generation of
/// orbit-trap structure, which is more chances for the orbit to come back near
/// a trap and put a crease through the middle of one of the flat washes this
/// form used to develop. Twelve was tried and is too many: past about ten the
/// new structure is finer than a pixel, so it stops reading as detail and
/// starts reading as noise — and on a phone it would crawl.
static inline void kaliLayer(float2 z, float2 c,
                             thread float &trapRadial, thread float &trapAxis,
                             thread float &trapSum) {
    trapRadial = 1e9;
    trapAxis = 1e9;
    trapSum = 0.0;
    for (int i = 0; i < 10; i++) {
        z = abs(z) / max(dot(z, z), 1e-5) - c;
        trapRadial = min(trapRadial, length(z));
        trapAxis = min(trapAxis, abs(z.x));

        // A running total, not a third minimum — and that is the entire point.
        // A min stops moving the instant it's attained, so anywhere the orbit's
        // closest approach happens on an early pass, both traps above are
        // constant for the rest of the loop and neighbouring pixels agree with
        // each other: a wide, smooth, featureless area. This one keeps taking
        // from every pass, so it still varies exactly where the other two have
        // gone quiet, and the washes get structure instead of a wash.
        trapSum += exp(-dot(z, z) * 1.8);
    }
    trapSum *= 1.0 / 10.0;
}

/// Kaleidoscope — sixfold mirror symmetry over a Kali-set inversion fractal,
/// falling forever into itself. The orbit traps supply self-similar detail at
/// every scale, which is the thing that rewards looking closer.
static inline float kaleidoscopeField(float2 p, float drift, float breathWave,
                                      thread float &detail) {
    // Fold into one wedge and mirror. Doing this before the fractal means the
    // detail is symmetric rather than symmetry being painted over noise.
    const float segments = 6.0;
    float seg = TAU / segments;
    // atan2 returns -pi..pi, and fmod keeps the sign of its dividend — folding
    // a negative angle directly leaves hard seams down the mirror lines. Lift
    // into positive territory first so the wedge wraps cleanly.
    float ang = atan2(p.y, p.x) + TAU;
    float rad = length(p);
    ang = fmod(ang, seg);
    ang = abs(ang - seg * 0.5);
    float2 q = float2(cos(ang), sin(ang)) * rad;

    float rot = drift * 0.026;             // very slow turn
    float cs = cos(rot), sn = sin(rot);
    q = float2(q.x * cs - q.y * sn, q.x * sn + q.y * cs);
    q *= 1.35 + breathWave * 0.10;         // breath still zooms on top

    // Kali set: z = |z| / dot(z,z) - c. The constant drifts slowly, which
    // makes the whole structure evolve rather than sit still.
    float2 c = float2(0.72 + 0.055 * sin(drift * 0.021),
                      0.51 + 0.055 * cos(drift * 0.017));

    // ── Infinite zoom ──────────────────────────────────────────────────────
    // Two copies of the fractal exactly one octave apart, cross-faded. By the
    // time the near layer has magnified 2x it sits precisely where the far
    // layer began, so at the wrap the two are identical and the handoff is
    // invisible — the fall never lands and never repeats a frame.
    //
    // The seam-free property comes from the octave spacing alone, not from the
    // fractal being self-similar. The Kali set isn't, exactly, which is the
    // good part: you keep arriving somewhere new that still looks like home.
    float k = fract(drift * KALEIDO_ZOOM_RATE);

    float radialNear, axisNear, sumNear, radialFar, axisFar, sumFar;
    kaliLayer(q * exp2(-k),       c, radialNear, axisNear, sumNear);
    kaliLayer(q * exp2(1.0 - k),  c, radialFar,  axisFar,  sumFar);

    // Linear, not smoothstep. Both are seamless at the wrap, but smoothstep
    // holds on one layer and then dissolves fast through the middle, and that
    // dissolve reads as an event. Linear spreads the double-exposure evenly so
    // nothing ever "happens" — which is the point of an endless zoom.
    float trapRadial = mix(radialNear, radialFar, k);
    float trapAxis   = mix(axisNear,   axisFar,   k);
    float trapSum    = mix(sumNear,    sumFar,    k);

    // The axis trap only lifts creases within 0.18 of the mirror line, which
    // left everything else with no highlight at all — one more reason the open
    // areas read as flat. Wider, and the accumulated trap carries the rest.
    detail = clamp((1.0 - clamp(trapAxis * 4.2, 0.0, 1.0)) * 0.72
                   + trapSum * 2.1, 0.0, 1.0);

    // Weighted well below what it takes to fill the washes on its own, and on
    // purpose: it is doing that job through `detail`, which lifts brightness
    // and leaves hue alone. Pushed hard into `t` instead it recolours the
    // entire form, because `t` is the palette coordinate and this term is
    // nonzero everywhere — the fractal stopped being the thing choosing the
    // colours and the palettes stopped meaning what they were tuned to mean.
    return trapRadial * 1.45 + trapAxis * 0.85 + trapSum * 0.70
         + breathWave * 0.04;
}

/// Tunnel — a logarithmic spiral corridor, built in log-polar coordinates.
///
/// Take (log r, theta) instead of (x, y) and two things become true. A
/// logarithmic spiral turns into a straight line, so a plain square grid in
/// that space comes back as this spiral when you map it to the screen. And
/// zooming turns into *translation*, which is the whole reason this form is
/// cheap: the kaleidoscope and mycelial both pay double to cross-fade two
/// octaves so their zoom can be endless, and this one needs none of it. Tiles
/// simply scroll, forever, out of an infinite integer grid.
///
/// Two constraints are structural rather than aesthetic:
///
/// TUNNEL_COLUMNS must stay a whole number. Theta wraps at the negative x-axis
/// and the column coordinate jumps by exactly that value there; an integer
/// jump lands on the same point in the tiling and nothing shows, while any
/// other value leaves a hard seam down that line. The shear is free to be
/// fractional — it multiplies the row coordinate, which doesn't jump.
///
/// TUNNEL_SPEED is a safety constant. High-contrast beads sweeping outward is
/// periodic whole-field luminance modulation at one cycle per row, so the rate
/// in rows per second IS a flicker frequency in Hz. See the note in the README;
/// this form is the one place in the app where going faster is not a taste
/// question.
///
/// `pxSize` is one screen pixel in field-space units. It is what keeps the
/// vanishing point alive: see the anti-aliasing note below.
///
/// `shade` is a straight brightness multiplier applied after the palette, and
/// it exists because a scalar `t` cannot express a lit sphere. Darkening a bead
/// through `t` walks it toward zero, which these palettes render as black —
/// correct at the end and a full trip round the colour wheel on the way, so
/// every bead comes out a rainbow. Shading has to be a multiply on the colour,
/// not a move along it. Forms that don't light anything return 1.
static inline float tunnelField(float2 p, float drift, float breathWave,
                                float pxSize, thread float &detail,
                                thread float &shade) {
    float r = max(length(p), 1e-6);
    float a = atan2(p.y, p.x);

    float lr = log(r) - breathWave * 0.05;

    // Kept before the warps: the colour field belongs to the room, not to the
    // lattice, so it is built from where a pixel actually is rather than from
    // where the packing has been bent to.
    float lrRoom = lr;

    // ── The wave, and the lobes ────────────────────────────────────────────
    // Applied to the coordinates, before anything is tiled. That's the whole
    // trick: distort the space and the packing distorts with it, so beads slide
    // against their neighbours and their highlights travel across them, rather
    // than a rigid lattice being spun on the spot.
    //
    // The travelling wave first, and it does most of the work — it is the only
    // one of these that is free to have real amplitude, because it moves the
    // log-radius alone and so only ever stretches rows rather than shearing
    // them. See the constants.
    lr += TUNNEL_WAVE_A * sin(lr * TUNNEL_WAVE_K - drift * TUNNEL_WAVE_RATE
                              + a * TUNNEL_WAVE_TILT);

    // Then the lobes, which bend the ring itself. Two waves crossing at
    // different rates, one of which also depends on the radius, so the swell
    // travels down the corridor instead of standing still. Every rate here is
    // roughly half what it was: with the wave carrying the motion, what these
    // were adding was spin, and spin was the complaint.
    lr += TUNNEL_LOBE_R * (sin(a * TUNNEL_LOBES + drift * 0.048)
                           + 0.62 * sin(a * (TUNNEL_LOBES * 2.0)
                                        - drift * 0.034 + lr * 1.5));
    a  += TUNNEL_LOBE_A * sin(lr * 2.3 - drift * 0.040);

    // Minus, so beads sweep outward past you and the corridor comes toward the
    // viewer. Plus reverses it into a retreat, which reads as falling backwards.
    float rows = lr / TUNNEL_ROW - drift * TUNNEL_SPEED;
    float cols = a / TAU * TUNNEL_COLUMNS;

    // The shear is the whole look. At zero the packing is concentric rings;
    // wind it up and the rings tilt into spiral arms. Sweeping it slowly
    // through both is far more interesting than either, and costs one sine.
    float shear = TUNNEL_TWIST * sin(drift * 0.018);
    cols += rows * shear;

    // ── Where the beads are ────────────────────────────────────────────────
    // Alternate rows are staggered half a column. Circles on a square lattice
    // leave a hole at every corner however tightly they're packed — you can
    // only close those by dropping each row into the notches of the one before
    // it. Staggered, the six nearest neighbours all sit at the same distance
    // and the leftover space becomes small curved triangles instead of a
    // cross-hatch, which is what a jar of marbles actually looks like.
    //
    // Wrap-safe: theta wrapping jumps the column index by TUNNEL_COLUMNS and
    // leaves the row index alone, so the stagger matches across the seam.
    //
    // The nine-way search is not optional, and skipping it was the bug in the
    // first version of this. A staggered lattice's cells are hexagons, and the
    // rectangle you get from floor() is not that hexagon — near a corner of the
    // rectangle the closest bead centre belongs to the row above. Testing only
    // the pixel's own rectangle clips every circle against the rectangle it
    // happens to fall in, and what comes out is a grid of rounded squares.
    float aspect = TUNNEL_ROW * TUNNEL_COLUMNS / TAU;   // = sqrt(3)/2 as tuned
    float rowI = floor(rows);

    float dq = 1e9;   // squared, until the winner is picked
    float2 e = float2(0.0);
    for (int dj = -1; dj <= 1; dj++) {
        float cj = rowI + float(dj);
        float stag = fract(cj * 0.5);                  // 0 even rows, 0.5 odd
        float ci0 = floor(cols - stag);
        for (int di = -1; di <= 1; di++) {
            float ci = ci0 + float(di);
            float2 off = float2(cols - (ci + stag + 0.5), rows - (cj + 0.5));
            // Back into real log-polar units. Index space is neither square nor
            // orthogonal — a column is TAU/COLUMNS wide while a row is
            // TUNNEL_ROW tall, and the shear tilts the row axis on top of that
            // — so a circle measured there would squash and lean with the
            // twist. Undone, the map to the screen is conformal and a circle
            // here is a circle on screen, at any shear and any radius.
            float2 ee = float2(off.x - shear * off.y, off.y * aspect);
            // Nearest centre by SQUARED distance. Twenty-seven square roots ran
            // in here — three per candidate, nine candidates — to compute a
            // metric whose only job inside the loop is to be compared. Squared
            // Euclidean orders the candidates identically for the round part
            // and within a few percent for the squared part, and the real
            // metric is computed once, outside, for whichever won.
            float d2 = dot(ee, ee);
            if (d2 < dq) { dq = d2; e = ee; }
        }
    }

    // Now the real metric, once. Superellipse rather than circle — see
    // TUNNEL_SQUARE — which closes the packing without moving any centres.
    float2 sq = e * e;
    dq = mix(sqrt(sq.x + sq.y),
             sqrt(sqrt(sq.x * sq.x + sq.y * sq.y)),
             TUNNEL_SQUARE);

    // ── The vanishing point ────────────────────────────────────────────────
    // Beads shrink without limit toward the centre, and the previous version
    // gave up on them early — faded the structure out below r = 0.075 and left
    // a flat disc, which is a ninth of the screen height rendered as one solid
    // colour sitting where the depth cue should be.
    //
    // The real problem was never the small beads, it was aliasing, and aliasing
    // is fixed by knowing how big a pixel is rather than by deleting the
    // detail. One pixel spans pxSize/(r*ROW) rows and pxSize*COLUMNS/(TAU*r)
    // columns — both blow up as 1/r, which is exactly the rate the beads shrink
    // — so widening the edge by that much makes each bead soften into its own
    // average precisely when it stops being resolvable. Structure survives to
    // within a few pixels of the centre and dissolves instead of aliasing.
    float aaRow = pxSize / (r * TUNNEL_ROW) * aspect;
    float aaCol = pxSize * TUNNEL_COLUMNS / (TAU * r);
    float aa = clamp(0.7 * max(aaRow, aaCol), 0.004, 0.9);

    float bead = smoothstep(TUNNEL_BEAD + aa, TUNNEL_BEAD - aa, dq);

    // ── Cylinder, not sphere ───────────────────────────────────────────────
    // `u` is still the round silhouette coordinate — the rim, the contact
    // shading and the anti-aliasing all want the outline. The NORMAL is a
    // different question, and the answer is what makes a rod a rod: it bends
    // mostly across the corridor and barely along it, so the face stays flat
    // over the whole length of the bead and the highlight becomes a line rather
    // than a dot. See TUNNEL_CYL.
    float u = min(dq / TUNNEL_BEAD, 1.0);
    float2 sn = float2(e.x / TUNNEL_BEAD,
                       e.y / TUNNEL_BEAD * (1.0 - TUNNEL_CYL));
    float h = sqrt(max(1.0 - min(dot(sn, sn), 1.0), 0.0));

    // ── Two highlights, and they are the whole material ────────────────────
    // What separates glass from painted plastic isn't gloss level, it's that a
    // glass bead carries two or three highlights in DIFFERENT colours — light
    // splitting on the way through — and that they're stretched arcs rather
    // than round dots, because the thing being reflected is a window or a strip
    // light, not a point.
    //
    // Both fall out of one trick: an anisotropic falloff around the point where
    // the normal faces the light. The first is the cylinder's own: tight across
    // and effectively unbounded along, so it runs the full length of the bead
    // as one unbroken streak. The second crosses it, and because they add
    // different amounts to `t` they land as two different colours.
    float2 d1 = (sn - float2(-0.34, 0.00)) * float2(8.2, 0.75);
    float2 d2 = (sn - float2( 0.42, 0.16)) * float2(2.6, 5.2);
    float s1 = exp(-dot(d1, d1) * 3.0) * bead;
    float s2 = exp(-dot(d2, d2) * 3.4) * bead;

    // ── Reflection ─────────────────────────────────────────────────────────
    // A banded environment, looked up by the surface NORMAL rather than by
    // position. That's the part that reads as reflective: the bands are fixed
    // in the world, so they slide across a bead whenever the surface under them
    // turns, and two neighbouring beads show different parts of the same room.
    // A pattern painted in bead-local coordinates instead looks like decoration
    // on the ball, however shiny it is.
    float env = 0.5 + 0.5 * sin(sn.x * 7.5 - sn.y * 5.3 + h * 4.4 + drift * 0.16);
    env = env * env * env * bead;

    // Bright edge where the sphere turns away — the giveaway of a transparent
    // ball, which gathers light around its silhouette instead of going dark.
    float rim = smoothstep(0.66, 0.99, u) * bead;

    // ── The thing that makes them balls ────────────────────────────────────
    // Real diffuse falloff, with a real terminator. The previous version put a
    // token amount of this into `detail`, which only ever brightens — so every
    // bead was uniformly lit and read as a printed circle. A sphere is legible
    // as a sphere because of where it goes DARK.
    float ndl = dot(normalize(float3(-0.34, 0.44, 0.83)), float3(sn, h));
    float lit = TUNNEL_AMBIENT + (1.0 - TUNNEL_AMBIENT)
                               * pow(clamp(ndl * 0.5 + 0.5, 0.0, 1.0), 1.6);

    // Contact shading. Beads sit in a packing, and the light doesn't reach far
    // into the crevices between them — darkening toward the silhouette is what
    // seats each one among its neighbours instead of floating it on top.
    lit *= mix(1.0, 0.62, smoothstep(0.55, 1.0, u));

    // Highlights are far higher frequency than the bead outline, so they alias
    // first. Fade them where a bead is only a few pixels across; below that the
    // bead is already averaging out and a stray glint would be the only thing
    // left flickering.
    float sharp = smoothstep(0.34, 0.10, aa);
    s1 *= sharp; s2 *= sharp; rim *= sharp; env *= sharp;

    // ── The light, which is emitted at the middle and travels out ──────────
    // A function of position and time, and of nothing else. No hash, no cell
    // index, no surface normal — see TUNNEL_LIGHT for why anything per bead in
    // here has twice come out as a rainbow on every bead.
    //
    // Built from `lrRoom`, the log-radius from before the wave and the lobes
    // bent it, so the colour stays clean sectors while the lattice flexes
    // underneath it rather than pumping along with the rows.
    //
    // The travel term is the beads' own — TUNNEL_ROW * TUNNEL_SPEED is their
    // speed in log-radius per second, and this is exactly that. So the colour
    // does not drift against the corridor at all; it IS the corridor, and it
    // arrives because you're moving. See TUNNEL_SPIRAL_R.
    float lrTravel = lrRoom - drift * TUNNEL_SPEED * TUNNEL_ROW;
    float lightPhase = TAU * lrTravel * TUNNEL_SPIRAL_R
                     + a * TUNNEL_SPIRAL_A;
    float spiral = 0.5 + 0.5 * sin(lightPhase);

    // And it reads as light rather than as tint because it carries brightness
    // with it, a quarter turn ahead of the colour — so the leading edge of an
    // arm is the bright part, which is what a source sweeping past looks like.
    //
    // Safe as whole-field modulation because it TRAVELS: the bright part is
    // always somewhere, just not here, so total screen luminance barely moves.
    // Same argument as the mortar pulse below.
    float lightLift = 1.0 + TUNNEL_LIGHT * sin(lightPhase - 1.5708);

    // ── The mortar ─────────────────────────────────────────────────────────
    // Beads overlap, so what's left is small curved triangles rather than a
    // grid of lines. Three versions: unlit, which put them at t = 0 and read as
    // dead; then a uniform glow with a wave over it, which lit them but lit
    // them *everywhere* and turned the corridor into a grey room; and now a
    // wave with no floor under it, so the gaps are black except where the band
    // is passing. See TUNNEL_GAP_FLOOR for the measurement that settled it.
    float gap = 1.0 - bead;
    float pulse = 0.5 + 0.5 * sin(rows * TUNNEL_GAP_WAVE - drift * TUNNEL_GAP_DRIFT);
    pulse = pow(pulse, TUNNEL_GAP_SHARP);
    float mortar = gap * (TUNNEL_GAP_FLOOR + TUNNEL_GAP_SWING * pulse);

    // Distance, as brightness rather than as a hole. Smooth and unbounded
    // rather than a masked disc, so it never has an edge of its own — the beads
    // keep rendering straight through it and only get brighter.
    //
    // Kept deliberately small, because the feedback pass amplifies it in a way
    // nothing else here is subject to: this form's history is sampled slightly
    // inward every frame, so whatever sits at the centre gets dragged outward
    // across the whole screen and re-added. A centre glow that looks modest in
    // one frame comes back as a pale fog over everything a few seconds later.
    float depth = 1.0 / (1.0 + r * 11.0);

    // And the thing `depth` was never allowed to be. Same idea — brightness
    // toward the middle — but a hundredth of the area, which is what buys it
    // permission to be forty times stronger. It goes into `shade` rather than
    // into `t`, so it is a light and not a colour, and it is the first thing in
    // this shader deliberately allowed past white. See TUNNEL_CORE.
    float hot = 1.0 / (1.0 + r * r * TUNNEL_CORE_TIGHT);

    // `env` and `depth` are both kept lean, and for the same reason: this
    // form's history is sampled slightly inward every frame, so any broad
    // brightness gets dragged outward across the whole screen and re-added as
    // fog. Tight highlights survive that; washes compound.
    // The highlights go here, and this is the third place they have been.
    //
    // Not in `t`: that is the palette coordinate, so a glint there is a
    // different colour rather than a brighter one, and every bead came out
    // striped. Not in `shade` either, which is where they went next — `shade`
    // is a raw multiply and stacking four highlights into it pushed pixels to
    // three times white. Nothing downstream is built for that: the contrast
    // curve, the tonemap and the saturation lift all clip per channel, at
    // different points, so what came out was hard-edged rainbow spikes.
    //
    // `detail` mixes toward `palette(t + 0.18)` at a bounded weight. It lifts,
    // it nudges the hue slightly, and it cannot blow out. That bound is the
    // whole reason it is the right channel for this.
    detail = clamp(s1 * 1.25 + s2 * 0.95 + rim * 0.60 + env * 0.60
                   + depth * 0.30 + mortar * 0.16, 0.0, 1.0);

    // Only the beads are shaded. The mortar is a light source, not a surface,
    // so it keeps its own brightness.
    //
    // Both multiplied by the travelling light. `shade` is applied after the
    // palette, so this is the one place the light can change how bright things
    // are without dragging their colour anywhere.
    //
    // It stays near 1 everywhere except the core, and the difference between
    // that and the highlights that used to live here is spatial: four glints on
    // every bead at 3x white is the whole screen over white, which the contrast
    // curve and the tonemap each clip at a different point, and what comes out
    // is rainbow spikes. One spot 5% of the screen across at 4x white is a
    // light. The clipping was never about the magnitude.
    // Two emitters in here now, and neither is a surface. The core is one; the
    // mortar band is the other, and it lands on `shade` for the same reason —
    // see TUNNEL_GAP_GLOW for the pale-gaps detour that established it.
    shade = mix(1.0, lit, bead)
          * lightLift
          * (1.0 + TUNNEL_CORE * hot + TUNNEL_GAP_GLOW * mortar);

    // Hue dominates `t` and the body shading stays out of it. That split
    // matters more than it looks: `t` is the palette coordinate, so anything
    // moving it moves colour, and an early version gave the body gradient
    // enough weight that shading swept the hue clean across every bead — every
    // one its own small rainbow. `lit` goes to `detail`, which lifts brightness
    // and only nudges hue.
    //
    // The two highlights are the deliberate exception. They're tight enough to
    // read as coloured glints rather than as a gradient, and the fact that they
    // move `t` by different amounts is exactly what makes them different
    // colours — which is the one thing that says glass.
    // Every weight here is a move along the palette, and there are almost none
    // left. A bead's colour is the light's colour where it sits, full stop.
    //
    // The mortar is now inside that same bracket rather than added beside it,
    // and the change is not cosmetic. Added beside, a gap band had a hue of its
    // own — a fixed 0.26 along the ramp regardless of where the arm was — so at
    // the new SWING it would have swept half the palette on its own and come
    // back striped, which is the third time this form would have found that
    // particular wall. Inside, the mortar is lit BY the spiral like everything
    // else: the gaps come up when the arm crosses them and are black when it
    // has gone. Which is also the honest reading of what he asked for — the
    // colour comes out of the middle, and the gaps are part of what it reaches.
    // The mortar's weight here is small and stays small. It exists only so the
    // gaps sit in the same family of colour as the corridor around them rather
    // than at a flat t = 0; everything that makes the band *bright* happens in
    // `shade`. 0.12 puts its peak at 0.19 of the ramp, still in the dark end.
    float lightT = 0.14 + 0.86 * spiral;
    return (bead + mortar * 0.12) * lightT
         + depth * 0.06;
}

/// Weave — Truchet tiling. Every cell holds two quarter-circle arcs, flipped
/// by a per-cell hash, and the arcs always meet at the cell edges. The result
/// is one continuous woven maze that never repeats and never breaks. The grid
/// drifts and turns so the weave reorganises without ever cutting.
static inline float weaveField(float2 p, float drift, float breathWave,
                               thread float &detail) {
    float rot = drift * 0.015;
    float cs = cos(rot), sn = sin(rot);
    float2 q = float2(p.x * cs - p.y * sn, p.x * sn + p.y * cs);

    q = q * (7.5 + breathWave * 0.25);
    q += float2(drift * 0.035, drift * 0.021);   // slow travel across the weave

    float2 cell = floor(q);
    float2 f = fract(q);

    // The hash picks which diagonal the arcs run along. Flipping x mirrors the
    // tile, which is the whole trick — both orientations still meet their
    // neighbours at the edge midpoints, so the ribbon is always continuous.
    if (hash21(cell) < 0.5) f.x = 1.0 - f.x;

    // Distance to the nearer of the two quarter arcs.
    float d = min(length(f), length(f - 1.0));
    float ribbon = abs(d - 0.5);

    // Two widths: a band for colour, a tight core for the bright thread. The
    // band was 0.42 wide at first, which blurred the ribbon into lava — the
    // appeal of this form is that the edges are hard, so it stays narrow.
    float band = 1.0 - smoothstep(0.05, 0.26, ribbon);
    detail = 1.0 - smoothstep(0.0, 0.055, ribbon);

    return band * 0.85 + ribbon * 0.55 + breathWave * 0.04;
}

/// Cheap three-octave fbm. The five-octave one is more than the strand
/// wander needs, and this runs three times per pixel.
static inline float fbm3(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) { v += a * valueNoise(p); p *= 2.03; a *= 0.5; }
    return v;
}

// `valueNoiseP` and `ridgedP` used to live here — value noise and ridged fbm
// made exactly periodic in y by wrapping the lattice INDEX rather than the
// coordinate, which is what a log-polar field needs when one of its axes is an
// angle. They went out with the cost march that used them. The two findings
// worth keeping, both written up in ios/README.md: wrapping the index makes the
// seam exact because the cells either side of it really are the same cells; and
// ridged noise branches where plain fbm cannot, because folding each octave
// about its midpoint turns peaks into creases and creases meet.

/// Worley / cellular noise — the two nearest site distances (F1, F2). The set
/// where those are equal is a connected web with three-way junctions, which is
/// what the coarse structure of a real network actually is.
///
/// `churn` walks every site along its own small orbit, so the network
/// reorganises slowly instead of sitting still.
static inline float2 worley(float2 p, float churn) {
    float2 n = floor(p);
    float2 f = fract(p);
    float f1 = 8.0, f2 = 8.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(i, j);
            float2 h = float2(hash21(n + g), hash21(n + g + 17.3));
            float2 site = 0.5 + 0.42 * sin(churn + TAU * h);
            float d = length(g + site - f);
            if (d < f1)      { f2 = f1; f1 = d; }
            else if (d < f2) { f2 = d; }
        }
    }
    return float2(f1, f2);
}

/// Mycelial — built against a photograph of a real network, which settled two
/// arguments at once.
///
/// The coarse structure genuinely is cellular: thick bright cords enclosing
/// irregular regions. A radial branching model was the wrong shape for that,
/// however good the branching maths was.
///
/// But plain Worley was wrong too, in two specific ways. Its cells come out
/// near-uniform in size, which reads as crystalline foam — so the sampling
/// space is domain-warped first, and that irregularity is most of what makes
/// the result look grown rather than manufactured. And a real network is not
/// one net but three at once: chunky cords, a mid net, and dense fine hyphae
/// filling every enclosed region. A single scale, however pretty, always reads
/// as a diagram.
///
/// This is no longer the form. It used to be the whole of it — evaluated twice
/// an octave apart and cross-faded, to survive a camera retreating forever —
/// and that retreat is gone, so this is called once, at several times the
/// frequency, as a *sheath* around the branches of the tree. See
/// `mycelialField`. Same texture, demoted from structure to material.
///
/// `thicken`, `midAge` and `fineAge` are how old this pixel's patch of mat is,
/// already resolved into the three things age controls. They arrive as
/// arguments rather than being worked out here because age is a property of
/// where the pixel is on the SCREEN, and this function is handed a scaled copy
/// of that — one of the two octaves — so it can't recover it.
static inline float mycelialLayer(float2 p, float drift, float churn,
                                  float thicken, float midAge, float fineAge,
                                  float fineW,
                                  thread float &detail) {
    p += float2(drift * 0.006, drift * 0.004);   // the mat creeps

    float2 wr = float2(fbm3(p * 1.6), fbm3(p * 1.6 + 5.3));

    // Warp hard. At 0.60 the cells still came out within a factor of two of
    // each other, and near-equal cells are exactly what reads as a grid however
    // organic the edges are — the eye finds the regular spacing long before it
    // notices the wobble. 0.85 is as far as this can go: the displacement
    // gradient reaches about 0.7 there, and at 1.0 the map folds over itself
    // and the network starts crossing itself in ways no growth does.
    float2 q = p + (wr - 0.5) * 0.85;

    // Then shove the whole thing along the radius. Growth leaves the middle and
    // goes outward, so the cords should too — displacing radially by an amount
    // that varies around the ring stretches the cells into the direction of
    // travel and the coarse net stops being isotropic foam.
    //
    // Faded out near the origin, and that is not optional. `dir` sweeps through
    // every angle inside an arbitrarily small disc around the middle, so an
    // undamped radial displacement is a singularity there — it wound the fine
    // threads into nested concentric ovals, a smooth "eye" sitting in the
    // middle of the mat. Hidden for as long as the interior was dense enough to
    // cover it, and unmistakable the moment the settled mat thinned out.
    float2 dir = normalize(p + float2(1e-6, 1e-6));
    q += dir * (wr.y - 0.5) * 0.38 * smoothstep(0.0, 0.14, length(p));

    // Two cellular layers only. The third used to be a finer cell net, which
    // was the wrong primitive for what fills the cells — see below.
    float2 c1 = worley(q * (7.0  * MAT_CELL),       churn);
    float2 c2 = worley(q * (17.0 * MAT_CELL) + 3.1, churn * 1.4);

    // Cords are broad felted masses, not drawn lines. Varying the width along
    // their length with the same low-frequency warp field is what stops them
    // reading as strokes — a constant-width edge always looks like a diagram
    // however irregular its path.
    //
    // Width also depends on age, and this is the load-bearing half of the
    // growth: a hypha at the tip is a thread and the same hypha a minute later
    // is a rope. Fade a full-width cord up instead and it reads as something
    // being switched on, not something extending.
    float cordW = (0.22 + 0.16 * wr.x) * mix(0.28, 1.0, thicken);
    float cord = 1.0 - smoothstep(0.0, cordW, c1.y - c1.x);
    float mid  = 1.0 - smoothstep(0.0, 0.11 + 0.06 * wr.y, c2.y - c2.x);

    // ── Fine hyphae ────────────────────────────────────────────────────────
    // A tangle of long straight threads crossing at every angle. This is the
    // thing a cellular layer fundamentally cannot produce: the level set of a
    // cell field *encloses* regions, so it can only ever subdivide into
    // smaller cells. What actually fills a real mat is fibres running straight
    // through each other, and crossings are most of what makes it read as
    // webbing rather than as tiling.
    //
    // Five directions sharing one noise field, rather than five fbm calls.
    //
    // Two things about the angles, and both were learned the hard way.
    //
    // They are not evenly spaced. Five directions 72 degrees apart tile the
    // plane with a perfect triangular lattice, and once `fineAge` opened the
    // interior up, big patches of that lattice were the single most
    // grid-looking thing in the form — a drawn mesh sitting behind the mat. The
    // spacing here is deliberately not a neat fraction of a turn, so folded
    // into 0..pi the five end up unevenly spread and never close into a rosette.
    //
    // And the whole set turns as you move across the field. Even unevenly
    // spaced, five straight families of lines still read as a weave if they
    // hold their bearing over a large enough area; rotating them out from under
    // themselves means no orientation gets to establish anywhere.
    // Frequency matters as much as amplitude here. At 1.1 this varied over
    // about the width of the screen, so the whole frame got one orientation and
    // the threads came out as long parallel arcs sweeping across everything —
    // brushed hair, not a mat. It has to turn several times within the frame
    // for the rotation to be doing its job.
    // One field, two jobs. `turn` and the thread wander below both want a
    // noise field at roughly this frequency, and this function is evaluated on
    // most of the screen — a whole fbm3 is twelve hashes, which is a real cost
    // to pay twice for two things that only differ by a scale factor.
    float fieldA = fbm3(q * 3.6 + 21.7);
    float turn = fieldA * 2.4;

    // The wander is much larger than it was, and higher frequency with it. At
    // 3.4 the perturbation was a fifth of a line spacing — enough to make the
    // lines waver, nowhere near enough to stop them being lines. This is about
    // three spacings, so a thread crosses its neighbours' paths instead of
    // running parallel to them forever.
    // A second fbm3 here would undo the saving above — twelve more hashes for
    // a term whose only job is to shove the threads sideways. One octave of
    // plain noise on top of `fieldA` is indistinguishable at this amplitude.
    float nz = (fieldA * 1.7 + valueNoise(q * 7.3) * 0.55) * 6.0;
    float threads = 0.0;
    for (int k = 0; k < 5; k++) {
        float fk = float(k);
        float ang = fk * 1.1731 + turn + drift * 0.004;
        float2 dir = float2(cos(ang), sin(ang));
        float v = dot(q, dir) * (MAT_THREAD_FREQ + 4.6 * fk)
                + nz * (1.0 + 0.4 * fk)
                + (wr.x - 0.5) * 9.0 * fk
                + fk * 31.7;
        threads = max(threads, 1.0 - smoothstep(0.0, 0.26 + 0.03 * fk, abs(sin(v))));
    }

    // Everything thins where a cord already runs, so the cords stay solid.
    float open = 1.0 - cord;

    // The two finer nets are gated on age, so the leading edge is bare cords
    // reaching into the dark and the mat fills in behind them over the next
    // twenty seconds. Switch all three on together and the colony simply
    // materialises at full complexity wherever the margin happens to be, which
    // is the "it was already there, something just uncovered it" read.
    float web = cord
              + mid * 0.60 * midAge * (0.40 + 0.60 * open)
              + threads * fineW * fineAge * (0.25 + 0.75 * open);

    detail = clamp(cord * 1.2 + mid * 0.4 * midAge + threads * 0.24 * fineAge,
                   0.0, 1.0);
    return pow(max(web, 0.0), MAT_GAMMA);
}

/// One pixel's answer to "which branch am I nearest, and how old is that bit
/// of it".
///
/// A tree with 2^17 tips cannot be tested branch by branch, and does not have
/// to be. Every level of a binary tree splits space roughly in half, so a point
/// can walk *down* the tree: at each level, measure the branch you're on, step
/// to its tip, decide which of the two children you're nearer, and repeat in
/// that child's frame. One iteration per level, not per branch.
///
/// The step that does the deciding is `q.x = abs(q.x)` — after moving the
/// origin to the tip and orienting the fork symmetrically, folding the negative
/// half onto the positive one *is* the choice of nearer child, and it costs an
/// absolute value. Everything else in the loop is bookkeeping to keep the
/// frames straight.
///
/// It is an approximation: it commits to a side at every level, so a point
/// almost exactly on a bisector can miss a slightly nearer branch in the
/// subtree it didn't take. That error is always at a place where both branches
/// are far away, which is where nothing is being drawn anyway.
///
/// `grown` is how many levels have arrived, as a real number — the fractional
/// part is how far the newest branches have extended out of their parents. It
/// is what makes this growth rather than a reveal: a level-n branch is a
/// segment that starts at the tip of its level-(n-1) parent, and it cannot be
/// drawn at all until its parent is complete. Nothing appears detached from
/// anything because there is nowhere for a detached thing to live.
struct TreeHit {
    float d;     // distance to the nearest branch's centreline, field units
    float w;     // that branch's half-width where we hit it
    float age;   // levels since that point was laid down; <= 0 means nothing
    float id;    // per-branch hash, 0..1
    float dens;  // and how much branch is around here in total — see below
};

static inline TreeHit mycelialTree(float2 p, float grown, float drift) {
    TreeHit hit;
    hit.d = 1e9;
    hit.w = TREE_WIDTH;
    hit.age = -1.0;
    hit.id = 0.0;
    hit.dens = 0.0;

    for (int t = 0; t < int(TREE_PRIMARIES); t++) {
        // The trunks don't start together. Half a level apart is about three
        // seconds, which is enough that the first thing on screen is one line
        // and not a three-pointed star.
        float grow = grown - float(t) * TREE_STAGGER;
        if (grow <= 0.0) continue;

        // Rotate the world so this trunk points along +y. Every frame below is
        // relative to the branch it's on, which is what lets one loop body
        // handle every level.
        float rot = float(t) * (TAU / TREE_PRIMARIES) + TREE_TILT;
        float c0 = cos(rot), s0 = sin(rot);
        float2 q = float2(p.x * c0 - p.y * s0, p.x * s0 + p.y * c0);

        float idx = float(t) + 1.0;   // the path taken so far, as an integer
        float len = TREE_TRUNK;
        float wid = TREE_WIDTH;

        for (int i = 0; i < TREE_LEVELS; i++) {
            // How much of this level exists yet. Zero means growth hasn't
            // reached it, and since children live beyond their parent's tip,
            // that also ends the descent — there is nothing further out to be
            // near.
            float reveal = clamp(grow - float(i), 0.0, 1.0);
            if (reveal <= 0.0) break;

            // The branch is a curve up the y axis, only as long as it has had
            // time to be. Clamping the projection to `reveal` rather than to 1
            // is the whole of "it extends" — the far end is the growing tip and
            // it moves.
            // One hash, two uses. The fractional part after scaling is
            // uncorrelated with the value itself, which is enough decorrelation
            // for a bend and a stunt roll and saves a hash per level.
            float hb = hash21(float2(idx, 27.3));
            float bend = (hb - 0.5) * TREE_BEND;
            float ty = clamp(q.y / len, 0.0, reveal);
            float d  = length(q - float2(bend * ty * ty * len, ty * len));
            float w  = wid * (1.0 - 0.35 * ty);   // and it tapers along itself

            // Compared by distance to the SURFACE, not to the centreline. A
            // twig can easily be nearer the pixel's centre than the trunk it
            // came off while the trunk is the thing actually covering it.
            if (d - w < hit.d - hit.w) {
                hit.d = d;
                hit.w = w;
                hit.age = grow - (float(i) + ty);
                hit.id = fract(idx * 0.6180339887);
            }

            // ── And a separate, SMOOTH field for the fuzz ──────────────────
            // Summed over every branch the descent passes, rather than taken
            // from whichever one won. That difference is not cosmetic.
            //
            // `hit.d` is a minimum, and a minimum over a path that commits to a
            // side at every level jumps wherever the commitment flips. While
            // the fuzz was tight to the cords that jump happened where both
            // branches were far away and nothing was being drawn. Widening the
            // sheath so it bridges between limbs — which is what makes this a
            // web rather than a tree — put the discontinuity right in the
            // middle of visible material, as straight seams.
            //
            // A sum has no such flip. When the path switches, the terms from
            // the shared ancestors are unchanged and dominate, and the one term
            // that differs is the far one, which is near zero either way.
            //
            // Fourth power rather than an exponential: same tight core, much
            // heavier tail — which is the half that reaches across the gaps —
            // and no transcendental in a loop that runs thirty-six times.
            float hw = w * TREE_HALO + TREE_HALO_FLOOR;
            float rr = d / hw;
            rr *= rr;
            hit.dens += smoothstep(0.0, AGE_MID, grow - (float(i) + ty))
                      / (1.0 + rr * rr);

            // ── Down one level ─────────────────────────────────────────────
            q -= float2(bend * len, len);     // origin to the tip of the curve

            // Then turn to face along the curve's TANGENT there, not along the
            // branch's chord. That one rotation is what carries the bend
            // through the fork: without it every branch straightens out at
            // every junction and the tree goes back to being made of sticks.
            //
            // The obvious spelling is atan(2*bend) then sin and cos of it —
            // three transcendentals in a loop that runs thirty times a pixel.
            // But the slope IS the tangent of that angle, so the frame falls
            // straight out of it: cos = 1/sqrt(1 + slope^2). One reciprocal
            // square root, which the GPU does in hardware.
            float ct = rsqrt(1.0 + 4.0 * bend * bend);
            float st = 2.0 * bend * ct;
            q = float2(q.x * ct - q.y * st, q.x * st + q.y * ct);

            // ── The half-angle belongs to the FORK, not to either child ────
            // Both children leave at the same angle from the tangent, in
            // opposite directions, and that symmetry is load-bearing: it is
            // what makes `abs` the exact bisector between them and therefore
            // makes "which child am I nearer" a correct question to answer with
            // an absolute value.
            //
            // Giving each child its own angle — which is the obvious way to
            // stop a folded tree looking mirrored — moves the true bisector off
            // the x axis, so the fold sends a good fraction of space down the
            // WRONG subtree. Those pixels then find themselves nowhere near
            // anything, and because the fold's cells are bounded by straight
            // lines, what that looks like is hard-edged black polygons cut
            // clean through the colony. The asymmetry has to come from
            // somewhere the fold doesn't depend on: length, curvature, and the
            // subtrees themselves, all of which differ per child below.
            float hp = hash21(float2(idx, 3.7));
            float ang = TREE_SPREAD * (0.45 + 1.05 * hp)
                      + TREE_WANDER * sin(drift * 0.021 + hp * TAU);

            float side = q.x < 0.0 ? 0.0 : 1.0;
            idx = idx * 2.0 + side;           // remember which way we went
            q.x = abs(q.x);                   // and take that child

            float c = cos(ang), s = sin(ang);
            q = float2(q.x * c - q.y * s, q.x * s + q.y * c);

            float h2 = hash21(float2(idx, 11.3));
            float live = h2 < TREE_STOP ? TREE_STUNT : 1.0;   // some tips give up

            // Length jitter, half of it shared by the fork and half the child's
            // own. The shared half is free; the child's own half moves the tip
            // and so nudges the next bisector, which is why it is the smaller
            // of the two. The child's half reuses h2 rather than hashing again.
            len *= TREE_SHRINK * live
                 * (0.80 + 0.40 * hp)
                 * (0.88 + 0.24 * fract(h2 * 31.7));
            wid *= TREE_TAPER;
        }
    }
    return hit;
}

/// The colony.
///
/// The tree above supplies the topology and the age; everything here is
/// material. There is no camera move any more, and that removal is half the
/// fix: the previous version cross-faded two octaves of mat while retreating at
/// a constant rate, so every pixel on screen drifted outward at the same speed
/// forever. That is a zoom. Growth is tips extending into empty space while
/// everything behind them stays exactly where it is, and you cannot have both.
///
/// So the frame is still, the tree gets deeper, and the only thing that moves
/// the camera is a tap — see `Colony` in FieldState.swift. Tapping shoves the
/// view back, which shrinks the colony on screen and buys it room for another
/// couple of levels, and it grows into them.
static inline float mycelialField(float2 p, float drift, float time,
                                  float breathWave, float tap,
                                  float grown, float push,
                                  thread float &detail, thread float &shade) {
    p *= 1.0 + breathWave * 0.03;
    p *= exp2(push);                  // a tap shoves the camera back

    TreeHit h = mycelialTree(p, grown, drift);
    if (h.age <= 0.0) {
        detail = 0.0;
        return 0.0;
    }

    float age = h.age;   // in levels

    float emerge  = smoothstep(0.0, AGE_EMERGE, age);
    float thicken = smoothstep(0.0, AGE_THICK,  age);
    float midAge  = smoothstep(AGE_MID  * 0.30, AGE_MID,  age);
    float fineAge = smoothstep(AGE_FINE * 0.25, AGE_FINE, age);
    float tip     = exp(-age / AGE_TIP);

    // ── Settling ───────────────────────────────────────────────────────────
    // Old mat dims and loses most of its fine hyphae. A legibility decision
    // before an aesthetic one — at one intensity everywhere the interior is too
    // dense to trace, and the growth is the part worth looking at. It also
    // happens to be true of the real thing: the active edge is the bright part.
    float settle = smoothstep(AGE_SETTLE * 0.25, AGE_SETTLE, age);
    float quiet  = mix(1.0, MAT_SETTLED_DIM, settle);
    float fineW  = mix(MAT_FINE, MAT_FINE_SETTLED, settle);

    // ── The cord ───────────────────────────────────────────────────────────
    // Width is age, and this is the load-bearing half of the growth: a hypha at
    // the tip is a thread and the same hypha a minute later is a rope. Fade a
    // full-width cord up instead and it reads as something switching on rather
    // than something extending.
    float w = h.w * mix(0.26, 1.0, thicken);
    float core = 1.0 - smoothstep(w * 0.5, w * 1.7, h.d);

    // ── And the fuzz around it ─────────────────────────────────────────────
    // The Worley mat is no longer the form; it is a sheath, and `dens` is how
    // much branch is in this pixel's neighbourhood — summed over every branch
    // the descent passed, weighted by each one's own thickness and age. See
    // the note where it's accumulated for why a sum and not a distance.
    //
    // Where two limbs run close, their sheaths add and the mat between them
    // fills in. That is the whole of the webbing: fine hyphae bridging from one
    // cord to the next, which is what a mycelium does and a tree does not.
    float near = min(h.dens, 1.35);

    // Nothing to draw and nothing near enough to fuzz: skip the mat entirely.
    // That is most of the screen for the first half-minute, and it is what pays
    // for the descent above.
    if (core <= 0.0 && near < 0.02) {
        detail = 0.0;
        return 0.0;
    }

    // A tap drives the churn forward, so the network visibly reorganises rather
    // than only brightening. The idle term is deliberately tiny: a net still
    // rearranging itself long after it grew is a net that was never growing.
    float churn = drift * 0.012 + tap * 1.2;

    float dTex = 0.0;
    float tex = mycelialLayer(p * TREE_TEX_SCALE, drift, churn,
                              thicken, midAge, fineAge, fineW, dTex);

    // ── The advancing tip ──────────────────────────────────────────────────
    // Every branch currently extending has `age` near zero at its far end, so
    // this lights up all of them at once — which is the whole thing he asked
    // for made visible. A growing hypha carries its cytoplasm at the end, and
    // the bright point travelling ahead of a dim trail is most of what makes a
    // timelapse read as advancing rather than as appearing.
    float front = core * tip * emerge;

    // A cord is a BUNDLE of hyphae, not a slab. Rendering the core as a solid
    // gives a flat painted stroke of a single colour — `t` is the palette
    // coordinate, so a constant core is a constant hue, and the whole tree came
    // out one shade of beige. Running the mat texture through the cord's own
    // body is what gives it longitudinal fibre and lets the palette move
    // across it.
    float body = core * (0.42 + 0.80 * tex);
    float fuzz = tex * near * (0.30 + 0.70 * emerge) * fineW * 1.7;
    float web = (body + fuzz) * emerge;

    detail = clamp(core * 0.9 + dTex * (near * 0.45 + core * 0.5)
                   + front * 1.6, 0.0, 1.0);

    // The tip, again, and this time as a light rather than as more material.
    // Everything below goes into `t`, which is a palette coordinate — it can
    // only move a tip's colour along the ramp, and the ramp tops out. `shade`
    // multiplies after the palette and has no ceiling, so this is the only
    // channel that can make a tip genuinely brighter than everything around it
    // instead of merely a different colour from it. See MAT_TIP_HEAT.
    //
    // Left at the caller's 1.0 on both early returns above, which is correct:
    // empty space is unlit, not unshaded.
    shade = 1.0 + front * MAT_TIP_HEAT;

    float raw = (web * (1.05 + tip * 0.35) + front * MARGIN_LINE) * quiet;

    // Compressed, and it has to be. `t` is the palette coordinate and these
    // palettes are cosines — they WRAP. Anything past 1 comes back round
    // through the whole colour wheel, so the densest knots, which should simply
    // be the brightest thing on screen, were coming out fringed in cyan and red
    // instead. Rolling off keeps the top end inside one trip through the ramp.
    //
    // No offset at the bottom: empty space lands at exactly t = 0, which the
    // mycelial palettes render as black.
    return raw / (1.0 + raw * 0.55);
}

// MARK: - Field pass

fragment float4 fieldFragment(VertexOut in [[stage_in]],
                              constant Uniforms &u        [[buffer(0)]],
                              constant Bloom *blooms      [[buffer(1)]],
                              texture2d<float> prev       [[texture(0)]],
                              sampler smp                 [[sampler(0)]]) {
    float2 res = u.resTime.xy;
    float time = u.resTime.z;
    float breath = u.resTime.w;
    float grounding = u.groundCount.x;
    int bloomCount = int(u.groundCount.y);
    float seed = u.groundCount.z;
    int form = int(u.groundCount.w);
    float hold = u.holdParams.x;
    float holdPhase = u.holdParams.y;

    float glowScale = (form == FORM_MYCELIAL) ? GLOW_ORGANIC : GLOW_STRUCTURED;

    // ── Taps ───────────────────────────────────────────────────────────────
    // Summed with no reference to position, so every tap does the same thing
    // to the whole field. Computed up here because the swell feeds the zoom.
    float tap = 0.0;
    for (int i = 0; i < MAX_BLOOMS; i++) {
        if (i >= bloomCount) break;
        Bloom b = blooms[i];
        tap += tapEnvelope(max(time - b.z, 0.0)) * b.w;
    }
    tap *= glowScale;

    // Saturate the pile. x/(1+kx) asymptotes to 1/k, so one tap comes through
    // near full and a flurry simply stops getting louder instead of stacking
    // linearly into a white blowout.
    tap = tap / (1.0 + tap * 0.55);

    // Hold-to-pulse: glow, dim, glow, dim, for as long as a finger rests.
    // Starts at the TOP of the swing so pressing brightens immediately — the
    // eased `hold` ramp means that's a swell, not a pop. Beginning on the dim
    // half would read as the field ignoring you for a second.
    // Cosine, never a step: the no-strobe rule holds here like everywhere else.
    float holdWave = (1.0 + cos(holdPhase * TAU)) * 0.5;   // 1 → 0 → 1, smooth
    // Offset below centre so the swing dims genuinely below baseline instead
    // of only ever adding light. 0.30 rather than a symmetric 0.5 because the
    // present pass rolls off highlights but not shadows — an even split
    // measures as a much deeper dim than glow.
    float holdSwing = hold * (holdWave - 0.30);

    // Aspect-corrected field space, origin at center.
    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(res.x / max(res.y, 1.0), 1.0);

    // Breath drives a slow scale pulse. Grounding deepens it and slows the
    // field's own motion toward stillness.
    float breathWave = sin(breath * TAU);
    float zoom = 1.0 + breathWave * mix(0.035, 0.075, grounding);
    // Hold and tap both swell the shapes as they brighten — smaller p
    // magnifies, so these subtract. Shape and light moving together is what
    // sells either as one pulse rather than a brightness effect laid over a
    // still picture.
    zoom -= holdSwing * 0.06 + tap * 0.045;
    p *= zoom;

    // Grounding slows drift to a near-stop rather than freezing hard.
    float drift = (time + seed * 7.0) * mix(1.0, 0.22, grounding);

    // One screen pixel, in the same units as `p`. Exact rather than measured:
    // p is a linear function of uv, so the step per pixel down the screen is
    // just the zoom over the height. The tunnel needs it to know when its beads
    // have shrunk past the point of being resolvable — see there.
    float pxSize = zoom / max(res.y, 1.0);

    // ── Form ───────────────────────────────────────────────────────────────
    float detail = 0.0;
    float shade = 1.0;   // brightness multiply after the palette — see tunnelField
    float t;
    if (form == FORM_KALEIDOSCOPE) {
        t = kaleidoscopeField(p, drift, breathWave, detail);
    } else if (form == FORM_TUNNEL) {
        t = tunnelField(p, drift, breathWave, pxSize, detail, shade);
    } else if (form == FORM_WEAVE) {
        t = weaveField(p, drift, breathWave, detail);
    } else {
        t = mycelialField(p, drift, time, breathWave, tap,
                          u.colony.x, u.colony.y, detail, shade);
    }

    // Both gestures shift hue as well as brightness, so a touch reads as a
    // colour event and not only a lighting one.
    t += tap * 0.22;
    t += holdSwing * 0.09;

    float3 col = palette(t, u.palA, u.palB, u.palC, u.palD);

    // Detail lifts the creases toward a shifted point in the same palette,
    // which keeps it in key instead of adding grey highlights.
    col = mix(col, palette(t + 0.18, u.palA, u.palB, u.palC, u.palD) * 1.22,
              detail * 0.42);

    // Lighting, as a multiply. `t` can only move a colour ALONG the palette, so
    // a form that wants a lit surface — one that goes genuinely dark where it
    // faces away — has to say so separately or every shaded object turns into a
    // rainbow on the way to black. Applied before the contrast curve so the
    // shading gets shaped by it like everything else.
    col *= shade;

    // Contrast. The old field sat in the middle of its range and read washed
    // out; this pushes darks down and lets the bright structure separate.
    //
    // Split at white, and it has to be. `col*col*(3-2col)` is smoothstep's
    // polynomial, which is only monotonic on [0,1] — it turns over at 1, hits
    // zero again at 1.5 and goes NEGATIVE past that. Every value in this shader
    // used to be under 1 so it never came up, and the moment anything is
    // allowed to be a light source it becomes a silent catastrophe: the
    // brightest pixel on screen renders black, and the ring around it renders
    // as a hard band on the way there.
    //
    // Below white the curve is untouched, bit for bit. Above it, the excess
    // passes straight through, so the function is continuous, monotone, and
    // still exactly the old contrast curve everywhere the old field lived.
    float3 lo = min(col, 1.0);
    col = lo * lo * (3.0 - 2.0 * lo) + max(col - 1.0, 0.0);

    // A tap lifts the whole field toward the warm end of the palette. No
    // falloff, no centre — the same everywhere on screen, by design.
    col += palette(t + 0.35, u.palA, u.palB, u.palC, u.palD) * tap * 0.95;

    // Hold pulse: the whole field swells with light and falls back. Applied
    // after the tap so a tap still punches through while you're holding.
    col *= 1.0 + holdSwing * 0.78;

    // Soft vignette keeps the eye centered and hides edge artifacts.
    float vig = 1.0 - 0.35 * dot(uv - 0.5, uv - 0.5) * 2.4;
    col *= vig;

    // Grounding: desaturate toward a calm blue-grey and dim. Never to black —
    // going fully dark during a trip is its own kind of alarming.
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    float3 calm = mix(float3(lum), float3(lum * 0.72, lum * 0.82, lum * 0.95), 0.65);
    col = mix(col, calm, grounding);
    col *= mix(1.0, 0.55, grounding);

    // Feedback: blend with the previous frame, slightly contracted so trails
    // drift outward. This is what makes strokes persist and slowly become part
    // of the pattern.
    //
    // Tuned by eye against the simulator: much above ~0.55 and both the fresh
    // structure and a new bloom drown in their own history.
    //
    // On the two zooming forms the contraction is locked to the zoom rate
    // rather than left at a fixed 0.998. A fixed value drifts the trail outward
    // at ~11%/s against a field zooming at ~4%/s, and a ghost travelling 3x
    // faster than the thing casting it doesn't read as motion — it reads as
    // blur, and it buries the zoom entirely. Matched, the history lands exactly
    // where the pattern is going and the whole frame moves as one.
    //
    // The signs are opposite because the forms move opposite ways. Under 1 the
    // history is sampled inward and so drifts outward, which is where the
    // kaleidoscope is going as it magnifies.
    float dt = max(u.holdParams.z, 1.0 / 240.0);
    float fbContract = 0.998;
    if (form == FORM_KALEIDOSCOPE)   fbContract = exp2(-KALEIDO_ZOOM_RATE * dt);
    // Mycelial's camera is still except during a tap, so its trail is still
    // too — the idle retreat this used to track is gone, and its removal is
    // most of why the form reads as growing now rather than as expanding. What
    // is left is this frame's share of the pullback, which is the one moment
    // the view really moves and so the one moment the ghost would lag.
    else if (form == FORM_MYCELIAL)  fbContract = exp2(u.colony.z);
    // The tunnel moves coherently too, so it needs the same lock. Its content
    // travels outward at TUNNEL_ROW * TUNNEL_SPEED in log-radius per second,
    // and that's a natural log, hence exp rather than exp2.
    else if (form == FORM_TUNNEL)    fbContract = exp(-TUNNEL_ROW * TUNNEL_SPEED * dt);
    float2 fbUV = (uv - 0.5) * fbContract + 0.5;
    float3 history = prev.sample(smp, fbUV).rgb;

    // Mycelial's contraction is the one above 1, which means near the border it
    // asks for history from just OUTSIDE the frame, where there has never been
    // anything. Clamped addressing answers with the edge pixel instead, and the
    // retreat then walks that replicated strip inward — which showed up as
    // small hard-edged blocks drifting in from the margins. Fading the history
    // out over the last few percent costs nothing on the forms that contract
    // inward and never sample out there at all, and it lives under the vignette
    // either way.
    float2 inside = smoothstep(0.0, 0.03, fbUV) * (1.0 - smoothstep(0.97, 1.0, fbUV));
    float inFrame = min(inside.x, inside.y);
    // How much history each form wants is a property of the form, not of two
    // buckets. Mycelial is the one whose appeal genuinely is smear — the mat
    // wants to look felted. Tunnel and weave live or die on hard edges, and
    // heavy feedback is exactly what softens them.
    //
    // The kaleidoscope sits in between and used to be lumped in with mycelial,
    // which was a mistake: at 0.66 the trail was a quarter of every pixel and
    // it filled the open areas of the fractal with a smear of where they had
    // just been. Half of the "blurry solid patches" was this and not the
    // fractal at all.
    float persistBase = 0.34;
    if (form == FORM_MYCELIAL)          persistBase = 0.66;
    else if (form == FORM_KALEIDOSCOPE) persistBase = 0.50;
    // The tunnel is the least of all of them. Glass is a hard-edged material
    // and every frame of history is one more frame of soft focus over it — and
    // this form is the one whose history is dragged outward from a bright
    // centre, so its trail also fogs the mortar it's supposed to leave dark.
    else if (form == FORM_TUNNEL)       persistBase = 0.26;
    float persistence = mix(persistBase, persistBase + 0.18, grounding);
    col = mix(col, history, persistence * 0.72 * inFrame);

    return float4(col, 1.0);
}

// ── Bloom ──────────────────────────────────────────────────────────────────
//
// Every form measured the same way and it was the most useful number this
// project has produced: across three reference clips, 1.5–2.2% of pixels are
// genuinely blown out and 10–67% are near-black. Across all four of our forms,
// *zero* pixels were above 200/255. Not "few" — none, in any frame of any form.
// The accumulation buffer has been rgba16Float from the first commit precisely
// so brightness could exceed 1, and nothing had ever put anything there.
//
// So two changes, and they only work as a pair. Sources are now allowed past
// white (TUNNEL_CORE, MAT_TIP_HEAT), and this pass spreads what's up there into
// the pixels around it — which is what a real camera does with a real light and
// what the eye reads as "that thing is emitting," as opposed to "that thing is
// a pale colour." A hot pixel with hard edges is just a white dot.
//
// Cost is close to free and worth understanding why. The bright pass halves the
// field buffer twice on the way in, so all five passes here run at 1/16 of the
// field's already-reduced pixel count — together about a third of one field
// pass, at a fraction of its per-pixel cost. Bloom is the cheapest visual
// upgrade available to this app, and it is the only one that improves all four
// forms at once.

/// Five linear taps standing in for a nine-tap gaussian: the offsets are
/// weighted midpoints between adjacent texels, so hardware bilinear filtering
/// fetches two samples for the price of one. Standard sigma-2 coefficients.
constant float BLUR_OFFSET[3] = { 0.0, 1.3846153846, 3.2307692308 };
constant float BLUR_WEIGHT[3] = { 0.2270270270, 0.3162162162, 0.0702702703 };

/// Where white starts, for the purposes of glowing. Not 1.0, deliberately:
/// structure sitting just under white should carry a faint halo or the effect
/// only ever shows up on the two forms that have a designated hot spot. The
/// squared knee below is what keeps that from becoming fog — at 0.8 a pixel
/// contributes 2% of itself, at 4.0 it contributes 76%.
constant float BLOOM_THRESHOLD = 0.58;

/// How much of the blurred result is added back. Above ~1.3 the glow starts
/// reading as a dirty lens rather than as light.
constant float BLOOM_STRENGTH = 0.60;

/// Black point, applied after the glow is added and before the tonemap.
///
/// This replaces a `pow(c, 0.90)` that used to sit at the end of this function
/// lifting the shadows, on the reasoning that deep areas should keep some
/// colour rather than crush out. That was the right instinct aimed at the wrong
/// end: what it produced was a floor under the entire frame, so nothing was
/// ever black and the contrast that makes a bright thing read as bright had
/// nowhere to come from. The references get their depth from the bottom of the
/// range, not the top.
///
/// Small — 4% — because it is a subtract, and everything below it is gone.
constant float BLACK_POINT = 0.040;

/// Bright pass. Downsamples 4x on the way in, which is where most of the
/// saving is. The four taps sit one source texel out from the centre, and the
/// centre of a 4x4 block is a texel *corner* — so each tap is a bilinear fetch
/// straddling four texels, and the four of them tile the block exactly. Sixteen
/// texels averaged, four fetches, no arithmetic.
///
/// Averaging *before* thresholding matters as much as the saving. Threshold
/// first and a single hot pixel drifting across the field pops in and out of
/// the glow frame by frame; average first and it fades.
fragment float4 bloomBrightFragment(VertexOut in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    sampler smp          [[sampler(0)]],
                                    constant float4 &params [[buffer(0)]]) {
    float2 o = params.xy;
    float3 c = (src.sample(smp, in.uv + float2(-o.x, -o.y)).rgb +
                src.sample(smp, in.uv + float2( o.x, -o.y)).rgb +
                src.sample(smp, in.uv + float2(-o.x,  o.y)).rgb +
                src.sample(smp, in.uv + float2( o.x,  o.y)).rgb) * 0.25;

    // Keyed off the brightest channel, not off luminance. A saturated red at
    // full blast has a luminance of 0.30 and is unmistakably a light; weighting
    // by luminance would bloom the greens of the palette and leave the reds
    // and blues flat, which is a colour cast rather than a glow.
    float peak = max(max(c.r, c.g), c.b);

    // Squared knee. `k` is the fraction of this pixel that is above the
    // threshold, so k*k ramps in smoothly instead of switching on — a hard
    // threshold makes the glow's edge crawl visibly as structure drifts across
    // it, and on a form that is mostly slow drift that crawl is the only thing
    // you'd look at.
    float k = max(peak - BLOOM_THRESHOLD, 0.0) / max(peak, 1e-4);
    return float4(c * k * k, 1.0);
}

/// One direction of the separable blur. `params.xy` is the tap spacing,
/// `params.z` a gain applied once at the end of a chain.
///
/// Run four times: horizontal, vertical, then both again at wider spacing —
/// and the second pair is *added* to the result of the first rather than
/// replacing it. That distinction is the whole reason small bright things glow
/// at all, and getting it wrong is invisible on anything big.
///
/// A gaussian conserves energy, so it spreads a source's brightness over its
/// own area and the peak falls as roughly the square of how far it spread. A
/// tunnel core a hundred pixels across barely notices. A mycelial tip three
/// pixels across, blurred over thirty, keeps about 1% of its peak — which is
/// nothing, and the tips came back with no halo at all. Chained, the wide pass
/// blurs the tight pass's output and there is no tight component left anywhere.
/// Summed, the tight scale survives at full strength underneath the wide one,
/// and a three-pixel tip gets a three-pixel glow instead of no glow.
fragment float4 bloomBlurFragment(VertexOut in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  sampler smp          [[sampler(0)]],
                                  constant float4 &params [[buffer(0)]]) {
    float2 d = params.xy;
    float3 c = src.sample(smp, in.uv).rgb * BLUR_WEIGHT[0];
    for (int i = 1; i < 3; i++) {
        float2 o = d * BLUR_OFFSET[i];
        c += (src.sample(smp, in.uv + o).rgb +
              src.sample(smp, in.uv - o).rgb) * BLUR_WEIGHT[i];
    }
    return float4(c * params.z, 1.0);
}

fragment float4 presentFragment(VertexOut in [[stage_in]],
                                texture2d<float> src   [[texture(0)]],
                                texture2d<float> bloom [[texture(1)]],
                                sampler smp            [[sampler(0)]]) {
    float3 c = src.sample(smp, in.uv).rgb;

    // Added before the black point, not after, and that ordering is the whole
    // difference between a glow and a haze. The far tail of the blur is a few
    // percent of a light spread over a lot of screen; run through the subtract
    // below it is simply gone, so the halo stays tight around what's actually
    // emitting and the empty parts of the frame stay empty. Lift the blacks
    // first and the same tail survives everywhere as a grey film.
    c += bloom.sample(smp, in.uv).rgb * BLOOM_STRENGTH;

    c = max(c - BLACK_POINT, 0.0) * (1.0 / (1.0 - BLACK_POINT));

    // Soft-clamp rather than hard clip: overlapping blooms can pile up
    // brightness, and this rolls it off instead of letting it flash white.
    // It's also what keeps the new hot sources from taking the screen with
    // them — a core at 4x white lands at 0.67 here, so it reads as bright
    // while its surroundings are unaffected.
    c = c / (1.0 + c * 0.50);

    // Saturation lift. The tonemap desaturates as it rolls off, and the ask
    // was for rich color, so this puts back what the curve takes out.
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c = clamp(mix(float3(lum), c, 1.28), 0.0, 1.0);

    return float4(c, 1.0);
}
