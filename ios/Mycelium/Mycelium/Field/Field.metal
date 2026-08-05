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

/// The colony's radius on screen, in field-space units where the visible area
/// is roughly 0.46 wide and 1.0 tall — so the corners sit at ~0.55.
///
/// SETTLE deliberately lands under that. An earlier 0.78 put the whole margin
/// off-screen, and once the interesting edge is outside the frame all you can
/// see is the middle of the mat, which is uniform — the growth becomes
/// invisible and the form reads as texture sliding around. The colony has to
/// stop short of filling the frame for the retreat to have anything to show.
constant float COLONY_START = 0.30;
constant float COLONY_SETTLE = 0.54;
constant float COLONY_SPREAD_SECONDS = 40.0;

/// The margin is a ridge network, not a wobbly circle.
///
/// ANG is sampled on the unit circle, so its features are identical at every
/// radius and come out as perfectly radial spikes — a starburst on its own.
/// ISO is sampled on the plane and is the same at every angle. Mixing them
/// gives spikes that vary along their length, split, and die out, which is what
/// a branching margin is. Either alone is a pattern; the pair is a colony.
constant float COLONY_RIDGE_ANG = 3.2;
constant float COLONY_RIDGE_ISO = 8.5;
constant float COLONY_BASE   = 0.50;   // reach with no ridge under it
constant float COLONY_FINGER = 1.00;   // how far a ridge throws a finger out

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

/// Tunnel geometry. COLUMNS is how many beads go around the corridor and
/// **must stay a whole number** — theta wraps at the negative x-axis and the
/// column coordinate jumps by exactly this there, so an integer lands back on
/// the tiling and anything else leaves a seam down that line.
///
/// ROW is the height of one row in log-radius. It is not free: the beads are
/// round, rows are staggered half a column, and circles pack tightest when the
/// row spacing is sqrt(3)/2 of the column spacing. So ROW = (TAU / COLUMNS) *
/// 0.866. Change COLUMNS and this has to move with it or the packing opens up.
constant float TUNNEL_COLUMNS = 22.0;
constant float TUNNEL_ROW = 0.2473;

/// Bead radius, in column widths. The ceiling is 0.433, and it is set by the
/// twist rather than by the packing.
///
/// Unsheared, the six nearest neighbours on a staggered lattice all sit exactly
/// one column width away, so 0.5 would have them kissing. But shear slides the
/// rows past each other, and once the shear passes half a column the staggered
/// neighbour has come directly overhead — sqrt(3)/2 = 0.866 away instead of
/// 1.0. Anything above half of that overlaps its neighbour every time the twist
/// sweeps through, and rows of beads visibly fuse into columns.
///
/// The side effect is worth keeping: between there and no shear at all the
/// mortar opens and closes on the twist's own cycle, so the packing breathes.
constant float TUNNEL_BEAD = 0.43;

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
/// Down from 1.3 because the shear now costs something it didn't when the tiles
/// were rectangles. Shearing the lattice slides the rows past each other, and
/// a stagger tuned for the unsheared packing opens up as it goes. The beads
/// themselves stay round at any shear — the distance is measured in real
/// log-polar units, not in sheared cell units — but the gaps between them
/// don't stay even, and past about 0.8 that reads as the packing coming apart.
constant float TUNNEL_TWIST = 0.75;

// Fully 16-byte aligned so the Swift side maps 1:1 with no padding surprises.
struct Uniforms {
    float4 resTime;     // xy = resolution px, z = time s, w = breath phase 0..1
    float4 groundCount; // x = grounding 0..1, y = bloom count, z = seed, w = form
    float4 holdParams;  // x = hold amount 0..1, y = hold phase 0..1, z = frame dt s, w spare
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
static inline float tunnelField(float2 p, float drift, float breathWave,
                                float pxSize, thread float &detail) {
    float r = max(length(p), 1e-6);
    float a = atan2(p.y, p.x);

    float lr = log(r) - breathWave * 0.05;

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
    float2 d1 = (sn - float2(-0.40,  0.46)) * float2(5.6, 1.7);
    float2 d2 = (sn - float2( 0.44, -0.30)) * float2(1.5, 5.2);
    float s1 = exp(-dot(d1, d1) * 3.0) * bead;
    float s2 = exp(-dot(d2, d2) * 3.4) * bead;

    // Bright edge where the sphere turns away — the giveaway of a transparent
    // ball, which gathers light around its silhouette instead of going dark.
    float rim = smoothstep(0.70, 0.99, u) * bead;

    // Body shading. Brightness only, deliberately: see the note on `t` below.
    float lit = 0.42 + 0.58 * clamp(dot(normalize(float3(-0.32, 0.42, 0.85)),
                                        float3(sn, h)), 0.0, 1.0);

    // Highlights are far higher frequency than the bead outline, so they alias
    // first. Fade them where a bead is only a few pixels across; below that the
    // bead is already averaging out and a stray glint would be the only thing
    // left flickering.
    float sharp = smoothstep(0.34, 0.10, aa);
    s1 *= sharp; s2 *= sharp; rim *= sharp;

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
    float cx = cell.x - floor(cell.x / TUNNEL_COLUMNS) * TUNNEL_COLUMNS;
    float hue = 0.5 + 0.5 * sin(TAU * hash21(float2(cx, cell.y)) + drift * 0.10);

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

    detail = clamp(s1 * 1.5 + s2 * 1.1 + rim * 0.45 + bead * lit * 0.18
                   + depth * 0.42 + mortar * 0.22, 0.0, 1.0);

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
         + s1 * 0.24 + s2 * 0.15 + rim * 0.10
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

/// Three-octave ridged noise, normalised to roughly 0..1.
///
/// Plain fbm gives rounded blobs, so its level sets are closed loops — an
/// expanding boundary driven by one is always some kind of amoeba. Folding
/// each octave about its midpoint replaces the peaks with creases, and creases
/// meet: a ridged field has a connected network of high ground with genuine
/// junctions in it, so a boundary riding on top of it throws fingers that
/// split. That's the difference between a lumpy circle and something branching.
static inline float ridged3(float2 p) {
    float v = 0.0, a = 0.55;
    for (int i = 0; i < 3; i++) {
        float n = 1.0 - abs(valueNoise(p) * 2.0 - 1.0);
        v += a * n * n * n;   // cubed, not squared: value noise clusters around
        p *= 2.07;            // its midpoint, so the gentler fold leaves broad
        a *= 0.5;             // plateaus where this wants narrow ridges
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
    float2 c1 = worley(q * 7.0,        churn);
    float2 c2 = worley(q * 17.0 + 3.1, churn * 1.4);

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
              + threads * 0.55 * fineAge * (0.25 + 0.75 * open);

    detail = clamp(cord * 1.2 + mid * 0.4 * midAge + threads * 0.24 * fineAge,
                   0.0, 1.0);
    return web;
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
static inline float mycelialField(float2 p, float drift, float time,
                                  float breathWave, float tap,
                                  thread float &detail) {
    p *= 1.0 + breathWave * 0.03;

    // ── The margin, computed first ─────────────────────────────────────────
    // Deliberately ahead of the field itself. Everything below costs two full
    // evaluations of the mat, and outside the colony all of it would be
    // multiplied by zero — so the reach is worked out first and the whole thing
    // skipped where it can't show. During the blob phase that is most of the
    // screen, which is exactly when the two-layer cost would otherwise be
    // hardest to afford.
    float front = mix(COLONY_START, COLONY_SETTLE,
                      smoothstep(0.0, COLONY_SPREAD_SECONDS, time));

    float r = max(length(p), 1e-5);
    float2 ring = p / r;

    // Two ridge fields, and neither works alone.
    //
    // The ring one is sampled on the unit circle, so it is the same at every
    // radius: its creases run straight out from the middle and it gives clean
    // radial spikes — but identical ones all the way along, which is a
    // starburst, not a colony. The plane one is the same at every angle and on
    // its own is isotropic lichen. Multiplied together the spikes get eaten
    // into along their length, break, and pick up side branches, and that is
    // the branching margin.
    //
    // Sampling the first on the circle rather than off atan2 is not a style
    // choice: an angle out of atan2 jumps a full turn across the negative
    // x-axis, and any noise driven by it leaves a hard seam down that line.
    // That exact bug shipped once already in an earlier version of this form.
    float ridgeA = ridged3(ring * COLONY_RIDGE_ANG
                           + float2(drift * 0.011, drift * 0.008));
    float ridgeB = ridged3(p * COLONY_RIDGE_ISO
                           + float2(-drift * 0.009, drift * 0.013));
    float ridge = ridgeA * (0.35 + 0.85 * ridgeB);

    float frontEff = front * (COLONY_BASE + COLONY_FINGER * ridge);

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
    float k = fract(time * MYCELIAL_GROW_RATE);

    float dNear = 0.0, dFar = 0.0;
    float webNear = mycelialLayer(p * exp2(k),       drift, churn,
                                  thicken, midAge, fineAge, dNear);
    float webFar  = mycelialLayer(p * exp2(k - 1.0), drift, churn,
                                  thicken, midAge, fineAge, dFar);

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
    return web * (1.15 + tip * 0.55);
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
    float t;
    if (form == FORM_KALEIDOSCOPE) {
        t = kaleidoscopeField(p, drift, breathWave, detail);
    } else if (form == FORM_TUNNEL) {
        t = tunnelField(p, drift, breathWave, pxSize, detail);
    } else if (form == FORM_WEAVE) {
        t = weaveField(p, drift, breathWave, detail);
    } else {
        t = mycelialField(p, drift, time, breathWave, tap, detail);
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
    else if (form == FORM_MYCELIAL)  fbContract = exp2( MYCELIAL_GROW_RATE * dt);
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
