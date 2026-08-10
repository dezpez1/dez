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
constant int FORM_LOBES = 3;

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
/// Lengths shrink geometrically after it, so one colony's radius is the partial
/// sum TRUNK * (1 - SHRINK^n)/(1 - SHRINK) — 0.45 at ten levels. SHRINK is also
/// what keeps the outer levels legible: at 1.0 every generation would add the
/// same length while doubling the branch count, and the rim would pack into a
/// solid thicket within three levels of filling the frame.
///
/// Halved from 0.145 when the primaries were scattered. At the old length a
/// single colony reached 0.83 — past the corners — so a frame-filling network
/// meant one colony's *interior*, and the interior of a branching tree is the
/// sparse part. Every good-looking capture of this form was taken at the moment
/// the growing margin happened to be crossing the frame, and by half a minute
/// later that margin was off-screen for good. Smaller colonies, more of them,
/// and the margins stay where they can be seen.
constant float TREE_TRUNK  = 0.045;
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
/// How long a branch dawdles before it starts, in levels, on top of everything
/// its ancestors already dawdled.
///
/// Without it the tree grows in **lockstep**: `reveal` was a function of the
/// level number alone, so all 2^n branches of a generation extended in perfect
/// unison and stopped in perfect unison. What that looks like is not a growing
/// front — it is a pom-pom. Every colony's margin was a dense simultaneous
/// shell of tips, arriving and freezing together, and then the next shell.
///
/// The delay ACCUMULATES down the tree rather than being drawn fresh per level,
/// and that is load-bearing rather than tidy. Drawn fresh, a child with a small
/// delay under a parent with a large one begins before its parent has finished
/// extending — which puts a branch in mid-air, hanging off a tip that has not
/// reached it yet. Accumulated, a child's start is its parent's completion plus
/// its own wait, so detachment is impossible for the same reason it was before:
/// there is nowhere for a detached thing to live.
constant float TREE_JITTER = 0.62;

constant float TREE_STOP  = 0.11;
constant float TREE_STUNT = 0.55;

/// How many colonies there are, where they start, and how far apart.
///
/// **They do not share an origin, and that is the whole pattern.** Three trunks
/// leaving one point is a starburst: three fans with hard black voids between
/// them and an unmistakable centre that everything radiates from. It was legible
/// and it was not a mycelium — a real mat has no middle, because it was seeded
/// from many spores at once and what you are looking at is where they met.
///
/// So each primary gets its own seed point, scattered on a golden-angle spiral
/// (irrational turn, so no two land on a common ray however many there are) with
/// a hash jitter on top so it isn't a visible phyllotaxis either. Radius goes as
/// sqrt(i) to keep the areal density even instead of crowding the rim.
///
/// Every primary is tested for every pixel rather than picking the nearest by
/// angle or by seed. Wedging the screen up would be cheaper and is wrong — by
/// level six a branch has wandered well past 60 degrees from its trunk, so the
/// wedge boundary would cut it off mid-air along a straight line.
/// The scatter is an ELLIPSE, not a disc, and squashed to roughly the frame's
/// own aspect. A phone is about 0.46 wide for 1.0 tall, so a circular scatter of
/// radius 0.40 puts most of the spores past the left and right edges and the
/// visible column gets only whatever grew back inwards — which showed up as two
/// dark vertical bands hugging the sides. Landing them where the frame actually
/// is costs one multiply and is the difference between a mat and a stripe.
constant float TREE_PRIMARIES = 11.0;
/// Where the spores land, now that this is the home screen's background: spaced
/// around the frame's PERIMETER, nudged just outside it, each facing in.
///
/// `TREE_EDGE_W` is the frame's width for a height of 1 — a phone is about 0.46.
/// It is a constant rather than the real aspect because the perimeter walk has
/// to be stable: feeding it a live aspect would slide every spore along the edge
/// whenever the view resized, and a background that reshuffles itself on a
/// rotation is worse than one that is slightly off on an iPad.
constant float TREE_EDGE_W     = 0.46;
constant float TREE_EDGE_OUT   = 1.04;   // how far outside the frame they start
constant float TREE_EDGE_SPRAY = 1.30;   // heading spread, radians, either side
constant float TREE_TILT      = 0.40;   // so the scatter isn't axis-aligned

constant float TREE_STAGGER = 0.16;   // levels between one spore and the next

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

/// …and how bright a tip stays once it is no longer one. Not zero — see the
/// note where it's used. Growth still reads because a fresh tip is 1/TIP_REST
/// times brighter than a settled node, not because settled nodes are dark.
constant float TIP_REST   = 0.10;
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
constant float MAT_SETTLED_DIM  = 1.00;
constant float MAT_FINE         = 0.60;   // fine hyphae, freshly filled in
constant float MAT_FINE_SETTLED = 0.60;

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
constant float MAT_TIP_HEAT = 4.9;


// **This struct is declared twice** — here and in Uniforms.swift. There is
// no shared header and nothing checks that they agree, so adding a field to one
// side still compiles cleanly and silently reinterprets memory on the other.
// Every field is a float4 for the same reason: no padding, so the two layouts
// can only disagree in ways that are obvious to read.
//
// Extend it at the END. Appending leaves every offset above it untouched, so a
// change applied to one side and not the other costs one garbage value rather
// than shifting the whole struct by sixteen bytes.
struct Uniforms {
    float4 resTime;     // xy = resolution px, z = time s, w = breath phase 0..1
    float4 groundCount; // x = grounding 0..1, y = bloom count, z = seed, w = form
    float4 holdParams;  // x = hold amount 0..1, y = hold phase 0..1, z = frame dt s, w spare
    float4 colony;      // x = colony reach, y = zoom push octaves, z = push delta this frame, w spare
    float4 palA;        // IQ cosine palette: bias
    float4 palB;        //                    amplitude
    float4 palC;        //                    frequency
    float4 palD;        //                    phase

    // Four scratch floats driven by Field Lab's sliders (ios/tools/FieldLab).
    // The app always sends zero.
    //
    // These are a probe, not a feature. To tune a constant, temporarily swap it
    // for u.lab.x, sweep it with the mouse, then write the number you found
    // into the constant and put the constant back. **Nothing committed may read
    // lab** — a form that does looks right in the lab and then renders with
    // that whole term at zero on a phone.
    float4 lab;

    // x = bass, y = mid, z = treble — smoothed 0..1 mic envelopes.
    // w = integrated audio drift-seconds (FieldState.audioDriftTime). A rate
    // cannot multiply `drift` — drift comes from absolute time, so scaling it
    // teleports position every time the envelope moves. Swift integrates;
    // this side only ever ADDS. Zero (no mic, tiles, denied permission) must
    // render exactly the audio-less frame.
    float4 audio;
};

// ── Audio ───────────────────────────────────────────────────────────────────
// The room, through the mic. Everything audio touches is phase, hue, or the
// amplitude of an existing slow oscillation — never `col`, never `shade`. The
// waiver on the photosensitivity constraint is on record for this feature, but
// a field that breathes with a track beats one that blinks at it, and the
// AudioDynamics smoothing (FieldState.swift) keeps the driving signal itself
// below the 3–60Hz band regardless. u.audio.xyz are 0…1 band envelopes;
// u.audio.w is the integrated drift bonus, whose story is at `driftA` in the
// field pass.

// How much a full mid band swells the breath's scale pulse. Amplitude of an
// oscillation that already ships at ≤0.077Hz — no new frequency content.
constant float AUDIO_BREATH = 0.5;

// Extra churn the bass drives through the mycelial mat — tap contributes 1.2
// on the same line. Worley phase only; it cannot brighten anything.
constant float AUDIO_CHURN = 0.8;

// How far the kaleidoscope's palette coordinate leans with the mid band, in
// trips around the wheel. 0.05 is a lean, not a lap.
constant float AUDIO_HUE = 0.05;

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
// Every form takes `lab` and no form reads it. It is the debug probe described
// on `Uniforms.lab` — four floats coming straight from Field Lab's sliders.
//
// It is a parameter rather than something the functions reach for because they
// can't reach: a form function is `static inline` and gets values, not the
// uniform block, and the tunnel already has a local called `u`. Without this you
// cannot sweep any constant that lives inside a form, which is all of the
// interesting ones.
//
// An unused parameter costs nothing — it never survives inlining. What it buys
// is that probing a constant is a one-line edit inside the function you are
// already reading, instead of a signature change, a call-site change, and a
// compile to find out you missed one.
static inline float kaleidoscopeField(float2 p, float drift, float breathWave,
                                      float4 lab, thread float &detail) {
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

// MARK: - Tunnel: removed 2026-08-07
//
// A log-polar vortex: three families of logarithmic spirals whose pitch decided
// what each was *seen as* — two loop families three degrees apart overlapping in
// flower-of-life lens shapes, and a near-radial third that carried the rotation,
// because a striped pattern can only be seen to move perpendicular to its own
// stripes. It ended with a nineteen-second build-and-release, per-family
// parallax, atmospheric falloff and four single-family palettes.
//
// It went because Jacob cut it, not because it was broken, and his reasoning is
// worth keeping: the forms that have worked in this project worked almost
// immediately. Kaleidoscope never drew a complaint and lobes landed on its first
// showing. The tunnel and the mycelial between them absorbed nearly every round
// ever spent here, and neither converged.
//
// Four things in it are worth stealing before they are forgotten, and all four
// are still written up in ios/README.md:
//
//   - A surge has to be an INTEGRAL, not a multiplier. Multiplying speed by
//     something that rises and falls drags the whole picture backwards when it
//     falls; integrating the extra distance is monotone by construction.
//   - What makes a palette match itself is the amplitude `a`, not the frequency
//     `c`. A neutral base can reach every hue on the wheel however you wind it.
//   - Parallax is not pitch. Pitch is how a family is wound and therefore what
//     it is seen as; rate is how fast it arrives and therefore how far away it
//     reads. One shared rate makes the whole frame a single sheet of pattern.
//   - The gaps between bright lines need the unsharpened field in them, or the
//     thing reads as lines rather than as a place.
//
// git log ios/Mycelium/Mycelium/Field/Field.metal for the code.

// ── Lobes ──────────────────────────────────────────────────────────────────
//
// Ported from the WebGL prototype in experiments/eight-lobe-tunnel. That page
// draws its own RGB and tone-maps it; this file's contract is a palette
// coordinate plus `shade`, so the port is a rewrite of the colour half and a
// transcription of the geometry half. What survived unchanged is the part that
// makes it: beads live on a grid in (log-radius, angle), so they are evenly
// spaced in perspective and pile up toward the vanishing point on their own.
//
// The prototype's `u_lobes` slider is a constant 8 here. Everything it fed —
// `lobeCorrection = smoothstep(5, 8, u_lobes)` and the four mixes keyed to it —
// evaluates to 1 at eight and is folded out. If the count ever becomes a knob
// again, those mixes have to come back; they are not decoration, they retune
// bead size and lobe contrast for low counts.

constant float LOBES_N = 8.0;

/// Radial cells crossed per second, and therefore the rate beads pass a fixed
/// point on screen. **SAFETY constant.** This is the fastest repeating thing in
/// the form and it reads as a taste knob, which is exactly the trap: the
/// photosensitivity band starts around 3 Hz, and the prototype's 2.65 sits close
/// enough to it that a later "make it faster" would walk straight in. 1.15 Hz is
/// the same journey at a pace that leaves headroom, and it also fixed something
/// unrelated — at 2.65 the beads crossed a phone's pixel grid fast enough to
/// crawl, because the cells near the rim are only a few pixels apart.
constant float LOBES_ZOOM = 1.15;

/// Palette travel, in full traverses per second. Slow on purpose: the lobe index
/// already steps the colour eight ways around the wheel across the frame, so
/// this only has to keep the whole arrangement from sitting still.
constant float LOBES_COLOR_SPEED = 0.055;

/// How far around the palette the eight lobes reach. Not 1.0, and this is the
/// difference between the form and a bag of confetti: at full span each lobe
/// gets a hue a quarter-turn from its neighbour, the strands stop belonging to
/// each other, and what reads is a rainbow dot matrix. The prototype avoided
/// this without having to think about it, because its ramp was three analogous
/// colours; the app's palettes are full wheels, so the narrowing has to happen
/// here. At 0.32 the eight lobes are one colour family with the far lobes just
/// distinguishable from the near ones, which is what makes the corridor read as
/// one object. The palette still travels its whole range over time — that is
/// LOBES_COLOR_SPEED's job, and it is unaffected by this.
constant float LOBES_HUE_SPAN = 0.32;

/// Bead brightness, and the superlinear boost inside a bead core.
///
/// Two numbers because they do different jobs and were found separately. GAIN
/// alone could hit the reference near-black but left nothing above white — the
/// whole frame sat mid-tone, because unlike the tunnel's `fil` the bead light is
/// not sharpened and its halo is as wide as its core. GLOW keyed to `core`
/// rather than to the light is what puts the bead centres past white while
/// leaving their halos under it.
///
/// Keyed to `core`, not to `light`: an earlier pass multiplied by
/// (1 + glow·light²) and it flattened out, because `light` is well under 1
/// everywhere so the cube barely moved. `core` is ~1 inside a bead and 0
/// outside, which is exactly the mask this wants.
constant float LOBES_GAIN = 4.2;
constant float LOBES_GLOW = 4.0;

/// The haze between the beads. Small, and it earns its place: at zero the gaps
/// read as a flat black card with dots on it rather than as distance. It is not
/// an exposure control — sweeping it from 0 to 0.6 moved near-black by three
/// points, because what actually fills this frame is the bead halos.
constant float LOBES_HAZE = 0.35;

/// One bead layer. Returns its light; reports which lobe it belongs to (as a
/// palette coordinate) and how much of it is solid core rather than halo.
///
/// `scale`, `phase` and `weight` are what make two of these read as depth rather
/// than as one layer drawn twice — different zoom, different jitter, different
/// brightness. The prototype ran three. The third was dropped here after
/// measuring: it cost a third of the form's time and, once the field is behind
/// the app's bloom instead of the prototype's own tone map, it is not visible.
static inline float lobeLayer(float2 p, float time, float breathWave,
                              float phase, float scale, float weight,
                              float pxSize, float span,
                              thread float &tOut, thread float &coreOut) {
    p *= scale;
    float r = max(length(p), 1e-6);
    float angle = atan2(p.y, p.x);

    // One pixel, in this layer's units. The prototype used res.y/scale for the
    // same job; going through pxSize instead is what keeps bead size honest on a
    // phone, since the app's field space is aspect-corrected and the prototype's
    // was not.
    float toPixels = 1.0 / max(pxSize * scale, 1e-6);

    float slowMorph = sin(time * 0.17 + phase) * 0.55;

    // The twist is why the beads run in curved strands instead of straight
    // spokes: it is a rotation that grows with log-radius, so it shears the
    // whole grid into a spiral.
    float twist = 0.34 * log(r + 0.042) - time * 0.075
                + 0.12 * sin(r * 5.0 - time * 0.38 + phase);
    angle += twist;

    // The lobes. A radius modulation in angle, so the tunnel's cross-section is
    // a flower rather than a circle. The second harmonic at N+2 is what stops
    // the eight lobes reading as a mechanical cog.
    float flower = 1.0
        + 0.255 * sin(LOBES_N * angle - time * 0.31 + slowMorph)
        + 0.042 * sin((LOBES_N + 2.0) * angle + time * 0.19 - phase);

    // Breath drives the section in and out. The prototype had its own sine here;
    // taking the app's `breathWave` instead is what makes grounding reach this
    // form — `drift` is already slowed, but the section pulse would not have been.
    //
    // 0.035, where the prototype had 0.105. This is the single most
    // exposure-sensitive number in the form and it does not look like one.
    // `breathing` scales `tunnelR`, and `tunnelR` feeds two steep smoothsteps —
    // bead radius over 0.10…0.98 and the depth shade over 0.08…0.75. A 10%
    // section pulse walks a large fraction of the beads across both at once, so
    // the whole frame brightens and dims with the breath: measured over six
    // times, blown pixels ranged 0.38% to 6.79%, a seventeenfold swing against
    // the tunnel's twofold. At 0.035 the breath is still visible as the corridor
    // opening and closing, and the range collapses.
    //
    // Dead end on the way: the outward `pulse` crest was the obvious suspect and
    // halving it changed the spread by nothing at all. The tell was that the
    // bright samples were ~13s apart, which is `Breath.ambientCycleSeconds`, not
    // the 6.6s of the pulse.
    float breathing = 1.0 + 0.035 * breathWave;
    float tunnelR = r * breathing / flower;

    float radial = -log(tunnelR + 0.025) * 18.5 + time * LOBES_ZOOM + phase * 3.7;
    float angular = angle / TAU * 64.0
                  + radial * 0.215
                  + 1.4 * sin(log(tunnelR + 0.08) * 2.1 - time * 0.22 + phase);

    float2 cellId = floor(float2(radial, angular));

    // Nearest bead, searched over the three radial neighbours only. Angular
    // neighbours are not searched and do not need to be: the grid is 64 cells
    // around against a handful visible across the frame, so the angular spacing
    // on screen is always the smaller of the two and the nearest bead is never
    // an angular cell away. Searching all nine tripled the cost for an image
    // that measured identical.
    float depthLobeCenter = (0.5 * M_PI_F + time * 0.31 - slowMorph) / LOBES_N;
    float best = 1e5;
    float2 beadPixels = 0.0;
    float tRadial = 0.0, tTunnelR = 0.0, tAngle = 0.0, tDepth = 0.5;

    for (int n = -1; n <= 1; n++) {
        float2 id = cellId + float2(float(n), 0.0);
        float jx = (hash21(id + phase) - 0.5) * 0.12;
        float jy = (hash21(id.yx + phase * 4.0) - 0.5) * 0.10;
        float cRadial  = id.x + 0.5 - jx;
        float cAngular = id.y + 0.5 - jy;

        // Invert the forward map to get the bead's own position. This is the
        // expensive half of the form and it is unavoidable: the grid is defined
        // in warped space, so a cell's centre in screen space is only knowable
        // by running the warp backwards.
        float cTunnelR = max(exp(-(cRadial - time * LOBES_ZOOM - phase * 3.7) / 18.5) - 0.025,
                             0.002);
        float cAngle = TAU / 64.0 * (cAngular - cRadial * 0.215
                     - 1.4 * sin(log(cTunnelR + 0.08) * 2.1 - time * 0.22 + phase));
        float cFlower = 1.0
            + 0.255 * sin(LOBES_N * cAngle - time * 0.31 + slowMorph)
            + 0.042 * sin((LOBES_N + 2.0) * cAngle + time * 0.19 - phase);
        float cR = cTunnelR * cFlower / breathing;

        // Alternate lobes sit slightly nearer and slightly further, which is
        // what gives the eight a front-and-back rather than a flat rosette.
        float cRawLobe = fract((cAngle - depthLobeCenter) / TAU) * LOBES_N;
        float cDepth = 0.5 + 0.5 * cos(M_PI_F * cRawLobe);
        cR *= 1.0 + (cDepth * 2.0 - 1.0) * (0.034 + 0.006 * sin(time * 0.23 + phase));

        float cTwist = 0.34 * log(cR + 0.042) - time * 0.075
                     + 0.12 * sin(cR * 5.0 - time * 0.38 + phase);
        float cBase = cAngle - cTwist;
        float2 centre = cR * float2(cos(cBase), sin(cBase));
        float2 px = (p - centre) * toPixels;
        float d = length(px);

        if (d < best) {
            best = d; beadPixels = px;
            tRadial = cRadial; tTunnelR = cTunnelR; tAngle = cAngle; tDepth = cDepth;
        }
    }

    // Which lobe this bead belongs to, blended across the boundary so a strand
    // crossing between lobes changes colour smoothly instead of snapping.
    float alignedAngle = tAngle - depthLobeCenter;
    float rawLobe = fract(alignedAngle / TAU) * LOBES_N;
    float nearest = floor(rawLobe + 0.5);
    float delta = fract(rawLobe + 0.5) - 0.5;
    float blended = mix(nearest, nearest + sign(delta),
                        0.5 * smoothstep(0.26, 0.50, abs(delta)));

    // One full traverse of the palette per eight lobes. The prototype's ramp was
    // three named colours wide and wrapped with mod 3; the app's palette is
    // periodic in t with period 1, so the mapping is just the lobe fraction.
    float chase = 0.5 + 0.5 * sin(tRadial * 0.34 - time * 0.56 + tAngle * 0.72 + phase);
    // `span` is LOBES_HUE_SPAN already scaled by the palette's own `spread`.
    // At 1 the eight lobes get eight neighbouring hues and the frame is a colour
    // gradient; near 0 they all get the SAME hue and the only thing still moving
    // the colour is the time term below — which is the whole of the Rainbow
    // palette, one hue at a time across the entire frame.
    tOut = blended / LOBES_N * span + time * LOBES_COLOR_SPEED + 0.03 * chase;

    // ── The bead itself ────────────────────────────────────────────────────
    float lobeWave = 0.5 + 0.5 * sin(LOBES_N * tAngle - time * 0.31 + slowMorph);
    float lobePresence = smoothstep(0.02, 0.60, lobeWave);
    float lobeContrast = mix(0.62, 1.32, lobePresence);

    float ribbon = smoothstep(-0.18, 0.92,
        0.68 + 0.32 * sin(tAngle * LOBES_N * 0.5 + tRadial * 0.095 - time * 0.25));
    float mainLobe = smoothstep(0.76, 0.98, ribbon);
    float primaryLayer = smoothstep(0.82, 1.0, weight);

    // Beads grow toward the rim and shrink toward the vanishing point, which is
    // the perspective cue doing most of the work here.
    float radialSize = smoothstep(0.10, 0.98, tTunnelR);
    float radiusPixels = (0.95 + 9.90 * pow(radialSize, 1.18))
        * mix(1.10, 1.40, smoothstep(0.70, 1.0, weight))
        * 0.78
        * mix(0.86, 1.14, tDepth)
        * mix(0.30, 1.0, weight)
        * mix(1.0, 0.90, mainLobe);

    float aa = max(fwidth(best), 0.72);
    float core = smoothstep(radiusPixels + aa, radiusPixels - aa, best);

    float isolation = mix(1.0, mix(0.30, 1.0, primaryLayer), mainLobe);
    core *= isolation;

    float halo = exp(-mix(0.82, 1.38, mainLobe) * max(best - radiusPixels * 0.48, 0.0));
    halo *= 0.72 * isolation * mix(1.0, 0.76, mainLobe)
          * mix(0.70, 1.12, tDepth) * (1.0 + 0.22 * (1.0 - primaryLayer));

    // Sphere shading. The bead is treated as a ball: reconstruct a normal from
    // how far the pixel is from the centre, then light it. This is the whole
    // reason they read as pearls and not as flat dots, and it is also why the
    // form needs `shade` rather than only `t` — a lit ball has to be able to go
    // dark on its far side without travelling through the palette to get there.
    float nd = best / max(radiusPixels, 0.001);
    float sphereDepth = sqrt(max(0.0, 1.0 - nd * nd));
    float3 normal = normalize(float3(beadPixels / max(radiusPixels, 0.001),
                                     sphereDepth + 0.001));
    float3 lightDir = normalize(float3(-0.48, 0.58, 0.92));
    float3 halfway = normalize(lightDir + float3(0.0, 0.0, 1.0));
    float diffuse  = 0.36 + 0.64 * max(dot(normal, lightDir), 0.0);
    float specular = pow(max(dot(normal, halfway), 0.0), 30.0) * core;
    float rim      = pow(1.0 - sphereDepth, 2.2) * core;

    float edgeFade   = 1.0 - smoothstep(0.85, 1.55, r);
    float centreFade = smoothstep(0.0015, 0.009, r);

    // A slow swell running outward. pow 7 makes it a travelling crest rather
    // than the whole field breathing — at pow 1 this was a global brightness
    // oscillation, which is the one shape the no-strobe rule cares about most.
    float pulse = 0.88 + 0.34 * pow(0.5 + 0.5 * cos(tRadial * 0.34 - time * 0.95), 7.0);

    float light = (core * 1.12 + halo * 0.82)
                * ribbon * lobeContrast * pulse
                * edgeFade * centreFade * weight
                * mix(0.68, 1.13, tDepth);
    light *= mix(1.0, diffuse, core);
    light += specular * 0.34 + rim * 0.12;
    light *= 0.28 + 0.72 * smoothstep(0.08, 0.75, tunnelR);

    coreOut = core;
    return light;
}

/// Lobes — an eight-lobed corridor of pearl beads, falling away from you.
///
/// Beads sit on a grid in (log-radius, angle) rather than in the plane, so the
/// spacing you see is perspective rather than a texture: they crowd toward the
/// vanishing point without any of it being drawn that way. The cross-section is
/// a flower, not a circle, which is where the eight comes from — and the lobes
/// alternate slightly near and far, so the corridor has a front and a back.
static inline float lobesField(float2 p, float drift, float breathWave,
                               float pxSize, float span, float4 lab,
                               thread float &detail, thread float &shade) {
    // The whole field turns, slowly and unevenly. Without this the eight lobes
    // are pinned to the screen's axes and the form reads as a logo.
    float spin = -drift * 0.085 + 0.045 * sin(drift * 0.21);
    float cs = cos(spin), sn = sin(spin);
    p = float2(p.x * cs - p.y * sn, p.x * sn + p.y * cs);

    // Two layers. The second is rotated, offset, run at a different rate and a
    // different scale — four separate reasons for it not to line up with the
    // first, which is what keeps the depth from collapsing into moiré.
    float tA, coreA;
    float lightA = lobeLayer(p, drift, breathWave, 0.0, 1.0, 1.0, pxSize, span, tA, coreA);

    float rB = 0.075 + 0.035 * sin(drift * 0.27);
    float cb = cos(rB), sb = sin(rB);
    float2 pB = float2(p.x * cb - p.y * sb, p.x * sb + p.y * cb)
              + float2(0.011 * sin(drift * 0.31), 0.009 * cos(drift * 0.23));
    float tB, coreB;
    float lightB = lobeLayer(pB, drift * 0.93, breathWave, 1.9, 1.105, 0.58, pxSize, span, tB, coreB);

    // ── The room the beads are in ──────────────────────────────────────────
    float r = max(length(p), 1e-6);
    float a = atan2(p.y, p.x);

    float lobeWave = 0.5 + 0.5 * sin(LOBES_N * a - drift * 0.31);
    float lobes = smoothstep(0.0, 0.64, lobeWave);
    float gap = mix(0.60, 1.0, lobes);

    float haze = exp(-2.0 * r) * (0.066 + 0.074 *
        (0.5 + 0.5 * sin(7.0 * log(r + 0.12) + (LOBES_N - 1.0) * a - drift * 0.12)));
    haze += 0.060 * lobes * exp(-1.35 * r);
    haze += 0.018 * (1.0 - lobes) * exp(-1.08 * r);

    // A hue spiral in the emptiness. Faint, and the form needs it: without any
    // structure between the beads the gaps read as a flat black card with dots
    // on it rather than as distance.
    float spiral = smoothstep(0.18, 0.86,
        0.5 + 0.5 * sin(8.5 * log(r + 0.10) + LOBES_N * a - drift * 0.35));
    haze += spiral * exp(-1.25 * r) * 0.124;
    haze *= gap * LOBES_HAZE;

    // Background colour comes from the same lobe index the beads use, so the
    // haze behind a lobe is that lobe's colour and the corridor stays coherent.
    float bgCentre = (0.5 * M_PI_F + drift * 0.31) / LOBES_N;
    float bgRaw = fract((a - bgCentre) / TAU) * LOBES_N;
    float bgNearest = floor(bgRaw + 0.5);
    float bgDelta = fract(bgRaw + 0.5) - 0.5;
    float bgLobe = mix(bgNearest, bgNearest + sign(bgDelta),
                       0.5 * smoothstep(0.30, 0.50, abs(bgDelta)));
    float bgT = bgLobe / LOBES_N * span + drift * LOBES_COLOR_SPEED;

    // The vanishing point. A ring rather than a disc — a disc here is a lamp
    // sitting on top of the picture, which is the same mistake the tunnel's
    // `core` term made and had to be walked back from.
    float portal = exp(-pow((r - 0.0095) * 145.0, 2.0)) * (0.72 + 0.28 * sin(drift * 0.62));

    float light = lightA + lightB;

    // t follows whichever layer is brighter here, falling back to the room's own
    // colour where there are no beads. Averaging the two layers' t was tried
    // first and it is wrong: two beads of different colours overlapping produced
    // the colour halfway between them, which is a third bead that isn't there.
    float tBead = (lightA >= lightB) ? tA : tB;
    float t = mix(bgT, tBead, saturate(light * 3.0));

    float coreMax = max(coreA, coreB);
    shade = light * LOBES_GAIN * (1.0 + LOBES_GLOW * coreMax * coreMax) + haze + portal * 0.30;
    detail = saturate(coreMax * 0.85 + portal * 0.4);
    return fract(t);
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
        float ft = float(t);

        // The spores don't germinate together, but only just — a sixth of a
        // level apart. They used to be half a level, back when there were three
        // of them stacked on one origin and the point was that the first thing
        // on screen should be a single line. It isn't any more: the colony now
        // opens already meshed (see `Colony.startLevels`), so a long stagger
        // only buys a visibly last-place colony trailing the rest forever.
        float grow = grown - ft * TREE_STAGGER;
        if (grow <= 0.0) continue;

        // ── Where this spore landed: ON THE EDGE, facing in ───────────────
        // The colony is the home screen's background now rather than a form you
        // choose, and that changes where it starts. A scatter through the middle
        // grows *outward* into the frame from several centres, so the busiest
        // part of the picture ends up exactly where the title and the cards are.
        // Seeded around the perimeter facing inward, the frame fills from its
        // margins and the middle is the last place to arrive — which is the
        // right shape for something that has to sit behind type.
        //
        // Perimeter position comes from walking a rectangle by arc length, so
        // the long sides get proportionally more spores than the short ones and
        // a phone's tall frame doesn't crowd all of them onto the top and
        // bottom. The golden-ratio step means no two land on the same side by
        // construction, however many there are.
        float hs   = hash21(float2(ft, 5.13));
        float walk = fract(ft * 0.6180339887 + TREE_TILT + (hs - 0.5) * 0.06);

        // Half-perimeter in units where the frame is 1 tall and TREE_EDGE_W wide,
        // split so `walk` maps to a lap of the rectangle.
        float halfW = TREE_EDGE_W * 0.5;
        float sideW = TREE_EDGE_W / (TREE_EDGE_W + 1.0) * 0.5;   // one short side

        float2 origin;
        float inward;      // the heading that points at the middle
        if (walk < sideW) {                      // bottom
            origin = float2(mix(-halfW, halfW, walk / sideW), -0.5);
            inward = 0.0;
        } else if (walk < 0.5) {                 // right
            origin = float2(halfW, mix(-0.5, 0.5, (walk - sideW) / (0.5 - sideW)));
            inward = -TAU * 0.25;
        } else if (walk < 0.5 + sideW) {         // top
            origin = float2(mix(halfW, -halfW, (walk - 0.5) / sideW), 0.5);
            inward = TAU * 0.5;
        } else {                                 // left
            origin = float2(-halfW, mix(0.5, -0.5, (walk - 0.5 - sideW) / (0.5 - sideW)));
            inward = TAU * 0.25;
        }

        // Pushed just off-screen so the germination itself happens out of frame
        // and what you see is hyphae arriving over the edge, not seven dots
        // appearing on the border and then sprouting.
        origin *= TREE_EDGE_OUT;

        // Rotate the world so this trunk points along +y. Every frame below is
        // relative to the branch it's on, which is what lets one loop body
        // handle every level.
        //
        // Heading is inward plus a wide hashed spray. Dead-on inward makes seven
        // parallel columns marching at the frame; the spray is what makes them
        // wander in and meet each other instead.
        float rot = inward + (hash21(float2(ft, 17.7)) - 0.5) * TREE_EDGE_SPRAY;
        float c0 = cos(rot), s0 = sin(rot);
        float2 d0 = p - origin;
        float2 q = float2(d0.x * c0 - d0.y * s0, d0.x * s0 + d0.y * c0);

        float idx = float(t) + 1.0;   // the path taken so far, as an integer
        float len = TREE_TRUNK;
        float wid = TREE_WIDTH;
        float wait = 0.0;             // everything this path has dawdled so far

        for (int i = 0; i < TREE_LEVELS; i++) {
            // How much of this branch exists yet. Zero means growth hasn't
            // reached it, and since children live beyond their parent's tip,
            // that also ends the descent — there is nothing further out to be
            // near.
            //
            // `wait` is this particular branch's own arrival time on top of its
            // depth, which is what stops a whole generation extending in
            // unison. See TREE_JITTER.
            float born  = float(i) + wait;
            float reveal = clamp(grow - born, 0.0, 1.0);
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
                hit.age = grow - (born + ty);
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
            hit.dens += smoothstep(0.0, AGE_MID, grow - (born + ty))
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

            // And this child's own wait, added to its ancestors'. Hashed on the
            // child's `idx`, so siblings dawdle by different amounts and the two
            // halves of a fork stop arriving as a pair.
            wait += hash21(float2(idx, 61.7)) * TREE_JITTER;

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
                                  float breathWave, float tap, float bass,
                                  float grown, float push, float pxSize,
                                  float4 lab,
                                  thread float &detail, thread float &shade) {
    float warp = (1.0 + breathWave * 0.03) * exp2(push);
    p *= warp;                        // a tap shoves the camera back
    pxSize *= warp;                   // and a pixel is that much wider in here

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
    // Decays to a FLOOR rather than to zero. A tip used to flare and then go
    // fully out as its branch aged, so once growth reached its cap every
    // highlight on screen had extinguished itself and what was left was dull
    // cord — lights going off one by one, which is the other half of why this
    // form kept getting called dying. At a floor of TIP_REST the junctions stay
    // lit as permanent nodes and a *fresh* tip is still four times brighter than
    // them, so growth reads exactly as it did. Nothing on screen ever goes out.
    float tip     = TIP_REST + (1.0 - TIP_REST) * exp(-age / AGE_TIP);

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

    // ── The advancing tip ──────────────────────────────────────────────────
    // Every branch currently extending has `age` near zero at its far end, so
    // this lights up all of them at once — which is the whole thing he asked
    // for made visible. A growing hypha carries its cytoplasm at the end, and
    // the bright point travelling ahead of a dim trail is most of what makes a
    // timelapse read as advancing rather than as appearing.
    //
    // It gets its own radius with a PIXEL FLOOR, and does not reuse `core`.
    // That was one of the two reasons this form measured 0.00% of its pixels
    // blown out for months while looking, to anyone who looked at it, like it
    // had bright tips. `core` is a geometric test against `w`, and `w` is the
    // cord's half-width scaled by mix(0.26, 1, thicken) — at a tip, where
    // thicken is zero by definition, a deep branch is 0.0007 field units
    // across. That is a third of a pixel. The brightest thing in the form was
    // never more than a third covered on any pixel it touched, so the highlight
    // was real, correct, and invisible. Two pixels is the floor because one
    // still aliases into the dotted crawl you get from sampling a sub-pixel
    // line, and these move.
    float glowR = max(w * 2.0, pxSize * 2.0);
    float halo  = 1.0 - smoothstep(glowR * 0.35, glowR * 2.0, h.d);
    float front = halo * tip * emerge;

    // Nothing to draw, nothing near enough to fuzz, and no tip here: skip the
    // mat entirely. That is most of the screen, and it is what pays for the
    // descent above.
    //
    // `front` has to be in this test, and its absence was the other reason
    // there were no highlights. `near` is `h.dens`, which weights every branch
    // by `smoothstep(0, AGE_MID, age)` — so a brand new branch contributes
    // almost nothing to it, by design. A tip out ahead of the mat therefore
    // failed both halves of the old test and returned black with `shade` left
    // at 1.0, *before the line that lights it had run.* The leading tips — the
    // only part of this form that was ever supposed to be bright — were being
    // discarded for being too new.
    if (core <= 0.0 && near < 0.02 && front < 0.02) {
        detail = 0.0;
        return 0.0;
    }

    // A tap drives the churn forward, so the network visibly reorganises rather
    // than only brightening. The idle term is deliberately tiny: a net still
    // rearranging itself long after it grew is a net that was never growing.
    // Bass joins the same sum — the mat pulses with the beat the way it pulses
    // with a tap, and a Worley phase cannot brighten anything.
    float churn = drift * 0.012 + tap * 1.2 + bass * AUDIO_CHURN;

    float dTex = 0.0;
    float tex = mycelialLayer(p * TREE_TEX_SCALE, drift, churn,
                              thicken, midAge, fineAge, fineW, dTex);

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
    // be the brightest thing on screen, come out somewhere else entirely.
    //
    // **The asymptote is the whole point and it used to be wrong.** At 0.55 the
    // roll-off tops out at 1/0.55 = 1.82, which is not one trip through the ramp,
    // it is nearly two — so `t` was free to lap past 1 and land in the far side
    // of Spore, which is a dull orange-brown. That never showed while settled mat
    // was dimmed to 60%, because the dimming was holding `raw` down. Take the
    // dimming out and the dense interior lands squarely in it: mottled brown with
    // black cell edges speckled through it, which reads as **rot**. Three
    // separate reports of this form "still dying" and this was the last of them,
    // and unlike the other two it was not an animation at all — nothing was
    // fading, the colour was just wrong.
    //
    // At 1.05 the asymptote is 0.95 and the wrap is unreachable by construction.
    // Density now reads as brighter gold rather than as a different substance,
    // which is what density means in this form.
    //
    // No offset at the bottom: empty space lands at exactly t = 0, which the
    // mycelial palettes render as black.
    return raw / (1.0 + raw * 1.05);
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
    // field's own motion toward stillness. Music deepens it too — amplitude
    // only, on the mid band's slow envelope; the breath's own rate is
    // untouched, so this can't put a new frequency on screen.
    float breathWave = sin(breath * TAU);
    float zoom = 1.0 + breathWave * mix(0.035, 0.075, grounding)
                     * (1.0 + AUDIO_BREATH * u.audio.y);
    // Hold and tap both swell the shapes as they brighten — smaller p
    // magnifies, so these subtract. Shape and light moving together is what
    // sells either as one pulse rather than a brightness effect laid over a
    // still picture.
    zoom -= holdSwing * 0.06 + tap * 0.045;
    p *= zoom;

    // Grounding slows drift to a near-stop rather than freezing hard.
    float drift = (time + seed * 7.0) * mix(1.0, 0.22, grounding);

    // What the music has bought. u.audio.w is drift-SECONDS, integrated on the
    // Swift side (FieldState.audioDriftTime) — never a multiplier on `drift`,
    // because drift is absolute time wearing a hat: scale it by an envelope
    // and you move *position*, not speed. Ten minutes in, a 5% envelope dip is
    // a thirty-drift-second lurch backwards. Adding an integral is the only
    // shape of this that cannot jump — the same lesson the tunnel's surge
    // taught, from the other direction.
    //
    // The kaleidoscope stays on plain `drift`, deliberately: its feedback
    // contraction (below) assumes KALEIDO_ZOOM_RATE against a constant clock,
    // and a trail contracted at yesterday's speed under a zoom running at
    // today's is the difference between motion and smear. It hears the music
    // through hue instead — see below.
    float driftA = drift + u.audio.w;

    // One screen pixel, in the same units as `p`. Exact rather than measured:
    // p is a linear function of uv, so the step per pixel down the screen is
    // just the zoom over the height. The tunnel needs it to know when its beads
    // have shrunk past the point of being resolvable — see there.
    float pxSize = zoom / max(res.y, 1.0);

    // ── Form ───────────────────────────────────────────────────────────────
    float detail = 0.0;
    float shade = 1.0;   // brightness multiply applied after the palette
    float t;
    if (form == FORM_KALEIDOSCOPE) {
        t = kaleidoscopeField(p, drift, breathWave, u.lab, detail);
        // Its audio: a bounded hue lean rather than a faster clock — see
        // driftA for why this form's clock cannot move. Pure phase on the
        // slowest envelope; it returns as the music quiets.
        t += AUDIO_HUE * u.audio.y;
    } else if (form == FORM_LOBES) {
        t = lobesField(p, driftA, breathWave, pxSize,
                       LOBES_HUE_SPAN * u.palA.w, u.lab, detail, shade);
    } else {
        t = mycelialField(p, driftA, time, breathWave, tap, u.audio.x,
                          u.colony.x, u.colony.y, pxSize, u.lab, detail, shade);
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

    // A tap lifts the field toward another point on the palette. No falloff and
    // no centre — where the finger lands makes no difference, by design.
    //
    // It is scaled by what is already lit, and that is not a softening of the
    // idea, it is what makes it read as one. A flat addition lands on **every**
    // pixel, so on the two forms that are mostly black — the tunnel especially —
    // a tap painted the empty gaps between the filaments a solid colour and the
    // structure vanished into a coloured card for a moment. Light does not do
    // that. Scaling by luminance means a tap makes the lit parts brighter and
    // leaves the dark ones dark, so what you see is the corridor flaring rather
    // than the screen being tinted.
    float litNow = dot(col, float3(0.299, 0.587, 0.114));
    col += palette(t + 0.35, u.palA, u.palB, u.palC, u.palD)
         * tap * 1.35 * saturate(litNow * 1.7);

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
    // Mycelial's camera is still except while a pinch is moving it, so its
    // trail is still too — the idle retreat this used to track is gone, and its
    // removal is most of why the form reads as growing rather than expanding.
    // What is left is this frame's share of the zoom, which is the one moment
    // the view really moves and so the one moment the ghost would lag.
    else if (form == FORM_MYCELIAL)  fbContract = exp2(u.colony.z);
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
    // wants to look felted. Tunnel and lobes live or die on hard edges, and
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
// white (MAT_TIP_HEAT, LOBES_GLOW), and this pass spreads what's up there into
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

/// Where white starts, for the purposes of glowing — and it belongs well BELOW
/// white, which took a round to accept.
///
/// 0.58 was the first guess and it was reasoning about the wrong distribution.
/// It sat above almost everything the app actually draws: the forms live
/// between 0.3 and 0.9, and the only things clearing 0.58 by enough to matter
/// were the two spots deliberately made hot. So the entire visible result of
/// adding a bloom pass was that the tunnel's core got brighter, and every other
/// pixel in every form was unchanged. A correct pass wired to a threshold above
/// the content is indistinguishable from no pass at all.
///
/// 0.38 puts it under the bright half of the structure, so the beads glow, the
/// mycelial cords glow, and the light bleeds into the black between them, which
/// is the thing that reads as emission. The squared knee is what stops that
/// becoming fog: contribution is (1 - T/peak)^2, so 0.5 gives 5%, 0.8 gives
/// 27%, and 4.0 gives 91%. Bright things glow hard, mid things barely, dim
/// things not at all — the curve does the discriminating, not the cutoff.
///
/// 0.32 was one step too far and worth recording, because the failure was the
/// exact mirror of the first one. It filled the gaps between the tunnel's beads
/// with a pale wash and dropped near-black from 40% to 25%. **This constant has
/// a narrow window: too high and the pass does nothing, too low and it fogs.**
/// The lever that actually separates those two outcomes is not this number at
/// all — it is the width of the halo's tail, which is the wide pass's gain in
/// FieldRenderer. Cutting that from 0.75 to 0.40 recovered every point of
/// near-black while leaving the glow on the objects untouched.
constant float BLOOM_THRESHOLD = 0.38;

/// How much of the blurred result is added back. Above ~1.3 the glow starts
/// reading as a dirty lens rather than as light.
constant float BLOOM_STRENGTH = 0.75;

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
/// Went 4% to 7.8% as the bloom threshold came down, and the two move together
/// by necessity: a lower threshold pushes more light into the blur, whose far
/// tail lands everywhere, and this is the only thing standing between that tail
/// and a grey film. **If you raise BLOOM_STRENGTH or lower BLOOM_THRESHOLD,
/// check the darks.**
///
/// It is a hard subtract, so it costs a fixed amount everywhere and therefore
/// costs the *darkest* form proportionally the most. Mycelial reads about 2
/// points more near-black at 7.8% than at 5.5% while the tunnel barely notices.
/// If that ever needs to stop being true, the fix is a toe — `c*c/(c+k)` —
/// which leaves the highlights alone and crushes only near zero.
constant float BLACK_POINT = 0.078;

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
