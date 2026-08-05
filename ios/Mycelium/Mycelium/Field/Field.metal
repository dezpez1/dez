//
//  Field.metal
//  The living surface. Everything the user stares into is computed here.
//
//  Two passes:
//    1. fieldFragment  — the selected Form + touch blooms, blended with the
//                        previous frame so strokes persist and get woven in.
//    2. presentFragment — tonemap the accumulation buffer to the drawable.
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
//      blooms brightens the field but can never blow out to white.
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

/// Octaves per second the mycelial camera pulls BACK. The same octave
/// cross-fade as the kaleidoscope, run in the other direction: rather than
/// falling into the pattern, the view retreats from it and the colony appears
/// to spread outward to fill the space being revealed.
///
/// Much slower than the kaleidoscope on purpose. This one is meant to be
/// growth, and growth you can catch happening is growth that's too fast — at
/// 0.045 the view doubles every ~22s, which is about the point where you can
/// tell it moved but never see it moving.
constant float MYCELIAL_GROW_RATE = 0.045;

/// The margin is a ridge network in log-polar coordinates, and both halves of
/// that matter.
///
/// A ridge network because ridges branch — see `ridgedP`. Log-polar because
/// branching has to point somewhere: `(log r, theta)` is conformal, so a
/// feature that is long in the log-radius axis and narrow in the angular one
/// comes back to the screen as a finger reaching outward, at every radius and
/// without ever being drawn as a line.
///
/// ANG is how many angular cells go around and **must be a whole number** —
/// theta wraps, and `ridgedP` wraps its lattice by exactly this. RAD sets how
/// stretched the fingers are: a feature spans `r/RAD` radially against
/// `r*TAU/ANG` tangentially, so smaller is longer.
///
/// The version before this sampled one ridge field on the unit circle and one
/// on the plane and multiplied them. Cheap, and wrong in a way that took a
/// while to see — a field sampled on a circle is one-dimensional, and a
/// one-dimensional ridge field has no junctions at all. It can only produce
/// isolated spikes, which is exactly what it produced.
constant float COLONY_BRANCH_ANG = 7.0;
constant float COLONY_BRANCH_RAD = 0.52;
constant float COLONY_BASE   = 0.46;   // reach with no ridge under it
constant float COLONY_FINGER = 1.05;   // how far a ridge throws a finger out

/// Ages, in octaves of camera retreat — 1 octave = 1/MYCELIAL_GROW_RATE
/// seconds, about 22s at 0.045.
///
/// This is the whole growth model, and it works because the retreat rate is
/// known. A point sitting at screen radius r inside a margin at frontEff
/// crossed that margin log2(frontEff / r) octaves ago, because the retreat is
/// what carried it there. No state, no simulation — one logarithm gives every
/// pixel its own age, and everything below is that age driving what has had
/// time to appear.
///
/// The staging is the point. A real colony throws bare leading hyphae out
/// first and fills in behind them, so the cords arrive on their own, the mid
/// net a few seconds later, and the fine hyphae last. Turn them all on at once
/// and the mat simply materialises at full complexity, which is exactly the
/// "already there, just uncovered" read this is fixing.
constant float AGE_EMERGE = 0.045;   // ~1s  — a cord fades up at the tip
constant float AGE_TIP    = 0.11;    // ~2.4s — reach of the bright growing edge
constant float AGE_THICK  = 0.60;    // ~13s — cords reach full width
constant float AGE_MID    = 0.30;    // ~7s  — the mid net starts filling in
constant float AGE_FINE   = 0.80;    // ~18s — fine hyphae fill the cells last
constant float AGE_SETTLE = 1.70;    // ~38s — and then the mat goes quiet again

/// What settled mat looks like. This is a legibility decision before it's an
/// aesthetic one: rendered at one intensity everywhere, the deep interior is so
/// dense that the branching cannot be read through it, and the margin — the
/// only part anyone can follow — is a thin ring around a screenful of noise.
/// Old mat drops toward half brightness and loses most of its fine hyphae, so
/// the light is where the growth is.
constant float MAT_SETTLED_DIM  = 0.52;
constant float MAT_FINE         = 0.52;   // fine hyphae, freshly filled in
constant float MAT_FINE_SETTLED = 0.15;   // and once the mat has quieted

/// Cell size and contrast, both moved for the same reason as the dimming.
///
/// Cells were 7.0 and 17.0, which put around fifteen coarse cells across a
/// screen — a convincing mat, and too many to follow. At 0.72 of that it's
/// nearer ten, which still reads as grown rather than as a diagram (four would
/// be a diagram) but leaves each cord long enough to trace from one junction to
/// the next. The gamma crushes the mid-tones so cords separate from the fuzz
/// instead of sitting in the same tonal band as it.
constant float MAT_CELL  = 0.72;
constant float MAT_GAMMA = 1.55;

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
constant float TUNNEL_BEAD = 0.50;

/// The mortar between beads glows and a wave runs down it.
///
/// TRAVELLING, not blinking. A wave moving along the corridor keeps total
/// screen luminance essentially constant — the bright part is always somewhere,
/// just not here — whereas the same swing applied globally is whole-field
/// modulation, which is the one thing this shader must never do. WAVE is in
/// cycles per row and DRIFT is radians per second, so a fixed point sees
/// DRIFT/TAU = 0.09 Hz. Two orders of magnitude below the photosensitive band.
constant float TUNNEL_GAP_WAVE  = 1.9;
constant float TUNNEL_GAP_DRIFT = 0.58;
constant float TUNNEL_GAP_FLOOR = 0.16;   // the mortar is never black
constant float TUNNEL_GAP_SWING = 0.84;

/// Rows per second of travel. **This is a safety constant, not a taste one.**
/// Bright tiles sweeping outward past dark gaps is periodic whole-field
/// luminance modulation at exactly one cycle per row — so this number, in rows
/// per second, is a flicker frequency in Hz. The photosensitive band starts
/// around 3Hz. 0.30 keeps it an order of magnitude clear of it and reads as a
/// drift rather than a ride. Do not raise it into single digits.
constant float TUNNEL_SPEED = 0.30;

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

/// How fast a bead's own colour travels, in radians per second. Each one gets
/// its own rate inside this range, so the packing shimmers continuously without
/// ever pulsing together — a shared rate is a whole-field rhythm, which is the
/// thing this shader is not allowed to have. The slowest bead takes two
/// minutes to come round, the fastest half of one.
constant float TUNNEL_HUE_SLOW = 0.05;
constant float TUNNEL_HUE_SPAN = 0.22;

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

    // ── Lobes ──────────────────────────────────────────────────────────────
    // Applied to the coordinates, before anything is tiled. That's the whole
    // trick: distort the space and the packing distorts with it, so beads slide
    // against their neighbours and their highlights travel across them, rather
    // than a rigid lattice being spun on the spot.
    //
    // Two waves crossing at different rates, one of which also depends on the
    // radius, so the swell travels down the corridor instead of standing still.
    lr += TUNNEL_LOBE_R * (sin(a * TUNNEL_LOBES + drift * 0.09)
                           + 0.62 * sin(a * (TUNNEL_LOBES * 2.0)
                                        - drift * 0.061 + lr * 1.5));
    a  += TUNNEL_LOBE_A * sin(lr * 2.3 - drift * 0.074);

    // Minus, so beads sweep outward past you and the corridor comes toward the
    // viewer. Plus reverses it into a retreat, which reads as falling backwards.
    float rows = lr / TUNNEL_ROW - drift * TUNNEL_SPEED;
    float cols = a / TAU * TUNNEL_COLUMNS;

    // The shear is the whole look. At zero the packing is concentric rings;
    // wind it up and the rings tilt into spiral arms. Sweeping it slowly
    // through both is far more interesting than either, and costs one sine.
    float shear = TUNNEL_TWIST * sin(drift * 0.035);
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

    float dq = 1e9;
    float2 e = float2(0.0);
    float2 cell = float2(0.0);
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
            float d = length(ee);
            if (d < dq) { dq = d; e = ee; cell = float2(ci, cj); }
        }
    }

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

    // Sphere, not a dome on a tile: the height is the third component of a unit
    // normal, so the shading is a real ball and everything on it curves.
    float u = min(dq / TUNNEL_BEAD, 1.0);
    float h = sqrt(max(1.0 - u * u, 0.0));
    float2 sn = e / TUNNEL_BEAD;             // xy of the unit surface normal

    // ── Two highlights, and they are the whole material ────────────────────
    // What separates glass from painted plastic isn't gloss level, it's that a
    // glass bead carries two or three highlights in DIFFERENT colours — light
    // splitting on the way through — and that they're stretched arcs rather
    // than round dots, because the thing being reflected is a window or a strip
    // light, not a point.
    //
    // Both fall out of one trick: an anisotropic falloff around the point where
    // the normal faces the light. Squashing the falloff in y leaves a highlight
    // that's tight across and long down — a vertical streak; squashing it in x
    // gives the horizontal one. They cross on each bead, and because they add
    // different amounts to `t` they land as two different colours.
    float2 d1 = (sn - float2(-0.40,  0.46)) * float2(6.4, 1.9);
    float2 d2 = (sn - float2( 0.44, -0.30)) * float2(1.7, 6.0);
    float s1 = exp(-dot(d1, d1) * 3.0) * bead;
    float s2 = exp(-dot(d2, d2) * 3.4) * bead;

    // ── Reflection ─────────────────────────────────────────────────────────
    // A banded environment, looked up by the surface NORMAL rather than by
    // position. That's the part that reads as reflective: the bands are fixed
    // in the world, so they slide across a bead whenever the surface under them
    // turns, and two neighbouring beads show different parts of the same room.
    // A pattern painted in bead-local coordinates instead looks like decoration
    // on the ball, however shiny it is.
    float env = 0.5 + 0.5 * sin(sn.x * 7.5 - sn.y * 5.3 + h * 4.4 + drift * 0.30);
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

    // Per BEAD, from the cell index — not from the continuous angle. Driving
    // hue off `a` directly makes the colour sweep *through* each bead, so every
    // one is its own little rainbow and the packing stops reading as beads.
    //
    // Hashed rather than a smooth function of the index. A sine of the row put
    // every bead in a ring on the same colour, so the corridor came out in
    // concentric bands; the reference is closer to a jar of mixed marbles, and
    // scattered colour also stops the eye locking onto the rings and reading
    // the whole thing as flat.
    //
    // Wrapped by hand first, and it has to be. The column index jumps by
    // exactly TUNNEL_COLUMNS across the theta seam, and a hash of an index that
    // jumps is a different colour on the two sides of a line the geometry
    // crosses seamlessly. Folding it back into 0..COLUMNS-1 first is what makes
    // a per-bead random colour legal here at all.
    //
    // Two hashes, not one, and the second is the reason the packing looks alive
    // rather than fixed. It gives each bead its OWN rate to travel its colour
    // at, so they never come round together — a shared rate is a whole-field
    // rhythm, and the thing that made the previous version read as painted was
    // that every bead sat on its colour and stayed there.
    float cx = cell.x - floor(cell.x / TUNNEL_COLUMNS) * TUNNEL_COLUMNS;
    float hPhase = hash21(float2(cx, cell.y));
    float hRate  = hash21(float2(cx + 7.0, cell.y - 3.0));
    float hue = 0.5 + 0.5 * sin(TAU * hPhase
                                + drift * (TUNNEL_HUE_SLOW
                                           + TUNNEL_HUE_SPAN * hRate));

    // ── The mortar ─────────────────────────────────────────────────────────
    // Beads overlap, so what's left is small curved triangles rather than a
    // grid of lines. They used to land at t = 0, which the tunnel palettes
    // render as black — correct for depth, and dead. Lit instead, with a wave
    // running down the corridor: see the constants for why it travels rather
    // than blinks.
    float gap = 1.0 - bead;
    float pulse = 0.5 + 0.5 * sin(rows * TUNNEL_GAP_WAVE - drift * TUNNEL_GAP_DRIFT);
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

    // `env` and `depth` are both kept lean, and for the same reason: this
    // form's history is sampled slightly inward every frame, so any broad
    // brightness gets dragged outward across the whole screen and re-added as
    // fog. Tight highlights survive that; washes compound.
    detail = clamp(s1 * 1.5 + s2 * 1.1 + rim * 0.55 + env * 0.60
                   + depth * 0.30 + mortar * 0.22, 0.0, 1.0);

    // Only the beads are shaded. The mortar is a light source, not a surface,
    // so it keeps its own brightness.
    shade = mix(1.0, lit, bead);

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
    return bead * (0.18 + 0.95 * hue)
         + s1 * 0.24 + s2 * 0.15 + rim * 0.10 + env * 0.13
         + mortar * 0.30
         + depth * 0.11;
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

/// Value noise that is *exactly* periodic in y with the given period, which
/// must be a whole number. Wrapping the lattice index rather than the
/// coordinate is what makes it exact — the two cells either side of the seam
/// really are the same cells, so there is nothing to blend and nothing to show.
static inline float valueNoiseP(float2 p, float per) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float y0 = i.y - floor(i.y / per) * per;
    float y1 = i.y + 1.0;
    y1 = y1 - floor(y1 / per) * per;
    float a = hash21(float2(i.x,       y0));
    float b = hash21(float2(i.x + 1.0, y0));
    float c = hash21(float2(i.x,       y1));
    float d = hash21(float2(i.x + 1.0, y1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

/// Three-octave ridged noise, periodic in y, normalised to roughly 0..1.
///
/// Ridged rather than plain fbm because of what the level sets do. Plain fbm is
/// rounded blobs and its level sets are closed loops, so an expanding boundary
/// driven by one is always some kind of amoeba. Folding each octave about its
/// midpoint replaces the peaks with creases, and creases *meet*: a ridged field
/// has a connected network of high ground with genuine junctions in it, so a
/// boundary riding on top of it throws fingers that split rather than fingers
/// that just get longer.
///
/// Periodic because the margin is sampled in log-polar coordinates and one of
/// those axes is an angle. The frequency steps by exactly 2 and the period
/// doubles with it, so every octave stays whole-numbered and the whole stack
/// wraps.
static inline float ridgedP(float2 p, float per) {
    float v = 0.0, a = 0.55;
    for (int i = 0; i < 3; i++) {
        float n = 1.0 - abs(valueNoiseP(p, per) * 2.0 - 1.0);
        v += a * n * n * n;   // cubed, not squared: value noise clusters around
        p *= 2.0;             // its midpoint, so the gentler fold leaves broad
        per *= 2.0;           // plateaus where this wants narrow ridges
        a *= 0.5;
    }
    return v * (1.0 / 0.9625);
}

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
/// This is one octave of the mat. The camera pulls steadily back from it, so
/// `mycelialField` below evaluates it twice and cross-fades — see there.
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
    float2 dir = normalize(p + float2(1e-6, 1e-6));
    q += dir * (wr.y - 0.5) * 0.38;

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
    float turn = fbm3(q * 3.2 + 21.7) * 2.4;

    // The wander is much larger than it was, and higher frequency with it. At
    // 3.4 the perturbation was a fifth of a line spacing — enough to make the
    // lines waver, nowhere near enough to stop them being lines. This is about
    // three spacings, so a thread crosses its neighbours' paths instead of
    // running parallel to them forever.
    float nz = fbm3(q * 4.0) * 9.0;
    float threads = 0.0;
    for (int k = 0; k < 5; k++) {
        float fk = float(k);
        float ang = fk * 1.1731 + turn + drift * 0.004;
        float2 dir = float2(cos(ang), sin(ang));
        float v = dot(q, dir) * (228.0 + 19.0 * fk)
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

/// The colony: one blob of mat, spreading, with the camera retreating from it
/// forever.
///
/// Two things are happening at once and they are easy to confuse.
///
/// The retreat is the kaleidoscope's octave cross-fade run backwards. A single
/// layer cannot simply be scaled up without limit — the cell size on screen
/// halves every octave, and within a minute the mat is finer than a pixel and
/// aliases into grey mush. So two copies run an octave apart and cross-fade:
/// the near one grows from 1x to 2x while the far one grows from 0.5x to 1x,
/// and at the wrap the far layer is sitting exactly where the near one began.
/// The scale on screen therefore never actually changes, but the motion of
/// everything moving inward and new structure appearing at the edges is
/// unambiguous, and it reads as growth rather than as a camera move.
///
/// The margin is separate, and it is where the growth actually happens.
///
/// The first version of it was a mask: a ragged circle that got bigger and
/// uncovered a mat that had been sitting there the whole time. Which is exactly
/// what it looked like — a pre-made net being wiped into view. Nothing about
/// the wipe was wrong; the mistake was thinking growth is a boundary at all.
///
/// Growth is what a patch of mat has had *time* to do, and the retreat rate
/// hands that over for free. A point at screen radius r inside a margin at
/// frontEff crossed that margin log2(frontEff / r) octaves ago, because the
/// retreat is the thing that carried it inward. One logarithm, no state, and
/// every pixel knows its own age — after which the cords can arrive thin and
/// thicken, and the finer nets can turn up later, and the whole thing builds
/// itself in place instead of being revealed.
///
/// The margin still has to be in SCREEN space. One pinned in world space gets
/// dragged inward by the retreat and shrinks to a dot however fast it grows.
///
/// `reach` and `push` come from Swift, because a tap changes them and a tap is
/// an event this function has nowhere to remember. See `Colony` in
/// FieldState.swift: at rest the mat owns the whole frame, and tapping shoves
/// the camera back so the margin — the only part of it actually doing anything
/// — is inside the screen again and has room to grow into.
static inline float mycelialField(float2 p, float drift, float time,
                                  float breathWave, float tap,
                                  float reach, float push,
                                  thread float &detail) {
    p *= 1.0 + breathWave * 0.03;

    // ── The margin, computed first ─────────────────────────────────────────
    // Deliberately ahead of the field itself. Everything below costs two full
    // evaluations of the mat, and outside the colony all of it would be
    // multiplied by zero — so the reach is worked out first and the whole thing
    // skipped where it can't show. Right after a tap that is most of the
    // screen, which is exactly when the two-layer cost would otherwise be
    // hardest to afford.
    float r = max(length(p), 1e-5);
    float ang = atan2(p.y, p.x) + drift * 0.004;   // the whole margin turns

    // Log-polar. The radius axis is `log r`, so a feature keeps its shape at
    // every scale and the fingers are as detailed near the middle as at the
    // rim; the angular axis is wrapped by `ridgedP` at COLONY_BRANCH_ANG, which
    // is why that constant has to be a whole number. The slow sine on the
    // radial axis is the fingers breathing in and out — without it the margin's
    // silhouette is almost static once the colony has settled, and the mat just
    // flows through a fixed outline.
    float2 lp = float2(log(r) * COLONY_BRANCH_RAD + 0.22 * sin(drift * 0.023),
                       ang / TAU * COLONY_BRANCH_ANG);
    float ridge = ridgedP(lp, COLONY_BRANCH_ANG);

    // A little isotropic noise on top, so the fingers aren't all the same
    // length and the ones that fall short leave bays behind them.
    float lump = fbm3(p * 5.0 + float2(-drift * 0.008, drift * 0.011));

    float frontEff = reach * (COLONY_BASE
                              + COLONY_FINGER * ridge * (0.55 + 0.80 * lump));

    // Age in octaves of retreat. Negative means the margin hasn't been here
    // yet, and that is the only place this returns nothing — the softness at
    // the very tip is `emerge` below, not a wide fade band. A wide one was what
    // made the old version read as a cotton ball with a halo.
    float age = log2(frontEff / r);
    if (age <= 0.0) {
        detail = 0.0;
        return 0.0;
    }

    float emerge  = smoothstep(0.0, AGE_EMERGE, age);
    float thicken = smoothstep(0.0, AGE_THICK,  age);
    float midAge  = smoothstep(AGE_MID  * 0.30, AGE_MID,  age);
    float fineAge = smoothstep(AGE_FINE * 0.25, AGE_FINE, age);
    float tip     = exp(-age / AGE_TIP);   // the bright growing edge

    // ── Settling ───────────────────────────────────────────────────────────
    // The mat quiets down as it ages, and this is about legibility rather than
    // biology. Rendered at one intensity everywhere, the deep interior is so
    // dense you cannot read the branching through it — the margin was the only
    // part anyone could follow, and the margin is a thin ring around a screen
    // full of noise.
    //
    // Old mat therefore loses most of its fine hyphae and drops toward half
    // brightness, which puts the light where the growth is and leaves the
    // interior as structure you can actually trace. It also happens to be true
    // of the real thing: the active edge is the bright part.
    float settle = smoothstep(AGE_SETTLE * 0.25, AGE_SETTLE, age);
    float quiet = mix(1.0, MAT_SETTLED_DIM, settle);
    float fineW = mix(MAT_FINE, MAT_FINE_SETTLED, settle);

    // ── The mat ────────────────────────────────────────────────────────────
    // A tap drives the churn forward, so the whole network visibly reorganises
    // rather than only brightening.
    //
    // The idle term is a quarter of what it was. Sites orbiting at 0.05 kept
    // the interior of the mat writhing, and a net that is still rearranging
    // itself long after it grew is a net that was never growing — it reads as
    // one animated texture, which is half of why this form looked pre-made.
    // Settled behind the margin, live at the margin, and a tap still stirs the
    // whole thing on demand.
    float churn = drift * 0.012 + tap * 1.2;

    // Driven by raw elapsed time rather than `drift`, which carries the session
    // seed and is slowed by grounding. Growth wants to be the one thing in the
    // field that is the same every session and never stops.
    //
    // A tap adds to this phase, which is the whole reason the pullback works at
    // all: the cross-fade is seamless at every value of k, so the camera can be
    // shoved anywhere along the zoom at any moment and there is nothing to
    // stitch. The mat simply rushes inward for a second and settles.
    float k = fract(time * MYCELIAL_GROW_RATE + push);

    float dNear = 0.0, dFar = 0.0;
    float webNear = mycelialLayer(p * exp2(k),       drift, churn,
                                  thicken, midAge, fineAge, fineW, dNear);
    float webFar  = mycelialLayer(p * exp2(k - 1.0), drift, churn,
                                  thicken, midAge, fineAge, fineW, dFar);

    // Linear, not smoothstep — the same finding as the kaleidoscope. A
    // smoothstep dissolves quickly through the middle of the octave, and that
    // burst of dissolve is itself an event you can see and time.
    float web = mix(webNear, webFar, k) * emerge;

    // The tip glows. A growing hypha carries its cytoplasm at the end, and the
    // bright point travelling ahead of a dim trail is most of what makes a
    // timelapse read as advancing rather than as appearing.
    detail = clamp(mix(dNear, dFar, k) * emerge + web * tip * 1.2, 0.0, 1.0);

    // No offset: empty space lands at exactly t = 0, which the mycelial
    // palettes render as black.
    return web * (1.15 + tip * 0.55) * quiet;
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
                          u.colony.x, u.colony.y, detail);
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
    col = col * col * (3.0 - 2.0 * col);

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
    // kaleidoscope is going as it magnifies. Mycelial retreats instead —
    // everything on screen travels inward — so its history has to travel inward
    // with it, and that needs a factor above 1.
    float dt = max(u.holdParams.z, 1.0 / 240.0);
    float fbContract = 0.998;
    if (form == FORM_KALEIDOSCOPE)   fbContract = exp2(-KALEIDO_ZOOM_RATE * dt);
    // Mycelial adds this frame's share of the tap pullback. Without it the
    // trail stays locked to the idle retreat while the camera is doing
    // something four times faster, and the pullback — the one moment on this
    // form where the view really moves — is the one moment the ghost lags.
    else if (form == FORM_MYCELIAL)  fbContract = exp2( MYCELIAL_GROW_RATE * dt
                                                        + u.colony.z);
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

fragment float4 presentFragment(VertexOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                sampler smp          [[sampler(0)]]) {
    float3 c = src.sample(smp, in.uv).rgb;

    // Soft-clamp rather than hard clip: overlapping blooms can pile up
    // brightness, and this rolls it off instead of letting it flash white.
    c = c / (1.0 + c * 0.50);

    // Saturation lift. The tonemap desaturates as it rolls off, and the ask
    // was for rich color, so this puts back what the curve takes out.
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c = clamp(mix(float3(lum), c, 1.28), 0.0, 1.0);

    // Mild lift so deep areas keep some color instead of crushing to black.
    c = pow(max(c, 0.0), float3(0.90));

    return float4(c, 1.0);
}
