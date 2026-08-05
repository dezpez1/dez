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
/// in magnification. Was 0.10, a doubling every 10s, which read as unmistakably
/// moving but slow; 0.16 is every 6.3s and has more of the falling-in quality
/// the form is for. Past ~0.25 it stops being something you can rest your eyes
/// on.
///
/// Changing this alone is safe: the feedback contraction is derived from it, so
/// the trail rate follows automatically. They must never be set independently —
/// see the note in the feedback block for what happens when they disagree.
constant float KALEIDO_ZOOM_RATE = 0.16;

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
/// is roughly 0.46 wide and 1.0 tall. It starts as a blob a little wider than
/// the screen is, and settles past the corners (~0.55) so that at rest the mat
/// covers the frame — but only just, and the ragged margin still bares a corner
/// now and then.
constant float COLONY_START = 0.34;
constant float COLONY_SETTLE = 0.78;
constant float COLONY_SPREAD_SECONDS = 45.0;

/// Tunnel geometry. COLUMNS is how many tiles go around the corridor and
/// **must stay a whole number** — theta wraps at the negative x-axis and the
/// column coordinate jumps by exactly this there, so an integer lands back on
/// the tiling and anything else leaves a seam down that line.
///
/// ROW is the height of one tile row in log-radius, which is what sets how
/// fast tiles grow as they come toward you.
constant float TUNNEL_COLUMNS = 26.0;
constant float TUNNEL_ROW = 0.30;

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
constant float TUNNEL_TWIST = 1.3;

constant float TUNNEL_GAP = 0.07;    // mortar between tiles
constant float TUNNEL_ROUND = 0.16;  // corner radius
constant float TUNNEL_BEVEL = 0.30;  // how domed each tile is

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

static inline float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        v += a * valueNoise(p);
        p *= 2.02;      // slightly off 2.0 to avoid axis-aligned banding
        a *= 0.5;
    }
    return v;
}

/// Ridged fbm — sharp creases where plain fbm gives soft blobs. This is what
/// pulls creases out of a wash. Currently unused by any shipping form — kept
/// because it's the obvious tool the moment one needs texture rather than line.
static inline float ridged(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 5; i++) {
        float n = 1.0 - abs(valueNoise(p) * 2.0 - 1.0);
        v += a * n * n;
        p *= 2.03;
        a *= 0.5;
    }
    return v;
}

// Inigo Quilez cosine palette. Smooth and cyclic by construction, which is
// why it can't produce a hard color jump.
static inline float3 palette(float t, float4 a, float4 b, float4 c, float4 d) {
    return a.rgb + b.rgb * cos(TAU * (c.rgb * t + d.rgb));
}

// MARK: - Forms

/// One evaluation of the Kali set. Split out because the infinite zoom needs
/// the same fractal sampled at two magnifications in the same frame.
static inline void kaliLayer(float2 z, float2 c,
                             thread float &trapRadial, thread float &trapAxis) {
    trapRadial = 1e9;
    trapAxis = 1e9;
    for (int i = 0; i < 9; i++) {
        z = abs(z) / max(dot(z, z), 1e-5) - c;
        trapRadial = min(trapRadial, length(z));
        trapAxis = min(trapAxis, abs(z.x));
    }
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

    float radialNear, axisNear, radialFar, axisFar;
    kaliLayer(q * exp2(-k),       c, radialNear, axisNear);
    kaliLayer(q * exp2(1.0 - k),  c, radialFar,  axisFar);

    // Linear, not smoothstep. Both are seamless at the wrap, but smoothstep
    // holds on one layer and then dissolves fast through the middle, and that
    // dissolve reads as an event. Linear spreads the double-exposure evenly so
    // nothing ever "happens" — which is the point of an endless zoom.
    float trapRadial = mix(radialNear, radialFar, k);
    float trapAxis   = mix(axisNear,   axisFar,   k);

    detail = 1.0 - clamp(trapAxis * 5.5, 0.0, 1.0);   // bright filament cores
    return trapRadial * 1.45 + trapAxis * 0.85 + breathWave * 0.04;
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
/// TUNNEL_SPEED is a safety constant. High-contrast tiles sweeping outward is
/// periodic whole-field luminance modulation at one cycle per row, so the rate
/// in rows per second IS a flicker frequency in Hz. See the note in the README;
/// this form is the one place in the app where going faster is not a taste
/// question.
static inline float tunnelField(float2 p, float drift, float breathWave,
                                thread float &detail) {
    float r = length(p);
    float a = atan2(p.y, p.x);

    float lr = log(max(r, 1e-5)) - breathWave * 0.05;

    // Minus, so tiles sweep outward past you and the corridor comes toward the
    // viewer. Plus reverses it into a retreat, which reads as falling backwards.
    float rows = lr / TUNNEL_ROW - drift * TUNNEL_SPEED;
    float cols = a / TAU * TUNNEL_COLUMNS;

    // The shear is the whole look. At zero the tiling is concentric rings; wind
    // it up and the rings tilt into spiral arms. Sweeping it slowly through
    // both is far more interesting than either, and costs one sine.
    cols += rows * (TUNNEL_TWIST * sin(drift * 0.035));

    float2 g = float2(cols, rows);
    float2 cell = floor(g);
    float2 f = fract(g) - 0.5;

    // Rounded-rectangle distance field, negative inside the tile.
    float2 d = abs(f) - (0.5 - TUNNEL_GAP) + TUNNEL_ROUND;
    float sdf = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - TUNNEL_ROUND;

    float face = smoothstep(0.02, -0.02, sdf);

    // Square root rather than the raw bevel: it domes the tile instead of
    // coning it, and a dome is what makes these read as glass rather than as
    // cut paper.
    float dome = sqrt(clamp(-sdf / TUNNEL_BEVEL, 0.0, 1.0));

    // A fixed light, so every tile is lit the same way and the corridor reads
    // as one lit space rather than as tiles that each glow on their own.
    float2 n = f / max(length(f), 1e-4);
    float lit = 0.55 + 0.45 * dot(n, float2(-0.42, 0.68));
    float spec = pow(clamp(lit, 0.0, 1.0), 4.0) * (1.0 - dome) * face;

    // Cells shrink without limit toward the vanishing point. Below a few pixels
    // they alias into crawling noise, so the structure is faded out and the
    // centre left as a glow — which is what the eye expects from a corridor
    // going away from it anyway.
    float core = smoothstep(0.012, 0.075, r);
    face *= core;
    spec *= core;

    // Fading the structure out would leave a black hole at the vanishing point,
    // which reads as a dead pixel rather than as distance. The corridor ends in
    // light instead.
    float glow = (1.0 - core) * 0.9;

    // Per TILE, from the cell index — not from the continuous angle. Driving
    // hue off `a` directly makes the colour sweep *through* each tile, so every
    // tile is its own little rainbow and the tiling stops reading as tiles.
    //
    // The column frequency has to be a whole number of cycles per turn. cell.x
    // jumps by exactly TUNNEL_COLUMNS across the theta wrap, so any frequency
    // that isn't a multiple of TAU/TUNNEL_COLUMNS puts a colour seam down the
    // negative x-axis — the same trap as the tiling itself.
    float hue = 0.5 + 0.5 * sin(cell.x * (TAU / TUNNEL_COLUMNS)
                                + cell.y * 0.85 + drift * 0.12);

    detail = clamp(dome * face * 0.55 + spec * 1.8, 0.0, 1.0);

    // Hue dominates `t`; the dome contributes only a little. That split matters
    // more than it looks. `t` is the palette coordinate, so anything that moves
    // it moves colour — and the first version gave the dome enough weight that
    // shading swept the hue clean across each tile, turning every tile into its
    // own small rainbow. Shading belongs in `detail`, which lifts brightness
    // and only nudges hue.
    //
    // Gaps land at exactly t = 0, which the tunnel palettes render as black.
    return face * (0.25 + 0.22 * dome + 1.05 * hue) + spec * 0.75 + glow;
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
static inline float mycelialLayer(float2 p, float drift, float churn,
                                  thread float &detail) {
    p += float2(drift * 0.006, drift * 0.004);   // the mat creeps

    float2 wr = float2(fbm3(p * 1.6), fbm3(p * 1.6 + 5.3));
    float2 q = p + (wr - 0.5) * 0.60;

    // Two cellular layers only. The third used to be a finer cell net, which
    // was the wrong primitive for what fills the cells — see below.
    float2 c1 = worley(q * 7.0,        churn);
    float2 c2 = worley(q * 17.0 + 3.1, churn * 1.4);

    // Cords are broad felted masses, not drawn lines. Varying the width along
    // their length with the same low-frequency warp field is what stops them
    // reading as strokes — a constant-width edge always looks like a diagram
    // however irregular its path.
    float cord = 1.0 - smoothstep(0.0, 0.22 + 0.16 * wr.x, c1.y - c1.x);
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
    // Sharing it naively is wrong though: identical spacing and identical
    // perturbation makes all five layers cross at coherent points, and the
    // result is a repeating rosette that reads as lace. Each layer gets its
    // own spacing, its own share of the warp, and a constant phase offset, and
    // the coherence disappears for no extra sampling.
    float nz = fbm3(q * 2.2) * 3.4;
    float threads = 0.0;
    for (int k = 0; k < 5; k++) {
        float fk = float(k);
        float ang = fk * 1.2566 + drift * 0.004;         // 72° apart
        float2 dir = float2(cos(ang), sin(ang));
        float v = dot(q, dir) * (228.0 + 19.0 * fk)
                + nz * (1.0 + 0.4 * fk)
                + (wr.x - 0.5) * 9.0 * fk
                + fk * 31.7;
        threads = max(threads, 1.0 - smoothstep(0.0, 0.26 + 0.03 * fk, abs(sin(v))));
    }

    // Everything thins where a cord already runs, so the cords stay solid.
    float open = 1.0 - cord;

    float web = cord
              + mid * 0.60 * (0.40 + 0.60 * open)
              + threads * 0.85 * (0.25 + 0.75 * open);

    detail = clamp(cord * 1.2 + mid * 0.4 + threads * 0.3, 0.0, 1.0);
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
/// The front is separate, and it is what makes the first thirty seconds a
/// *colony* instead of an infinite mat. It's measured in SCREEN space, not
/// world space — a front pinned in world space would be dragged inward by the
/// retreat and shrink to a dot however fast it grew.
static inline float mycelialField(float2 p, float drift, float time,
                                  float breathWave, float tap,
                                  thread float &detail) {
    p *= 1.0 + breathWave * 0.03;

    // ── The front, computed first ──────────────────────────────────────────
    // Deliberately ahead of the field itself. Everything below costs two full
    // evaluations of the mat, and outside the colony all of it would be
    // multiplied by zero — so the mask is worked out first and the whole thing
    // skipped where it can't show. During the blob phase that is most of the
    // screen, which is exactly when the two-layer cost would otherwise be
    // hardest to afford.
    float front = mix(COLONY_START, COLONY_SETTLE,
                      smoothstep(0.0, COLONY_SPREAD_SECONDS, time));

    // Ragged, and ragged differently as it goes, so the margin advances in
    // lobes and tendrils instead of as an expanding circle.
    //
    // Sampled on the unit circle rather than from atan2: an angle taken
    // straight out of atan2 jumps a full turn across the negative x-axis, and
    // any noise driven by it leaves a hard seam down that line. That exact bug
    // shipped once already in an earlier version of this form.
    float r = length(p);
    float2 ring = (r > 1e-5) ? p / r : float2(1.0, 0.0);
    float lobes = fbm3(ring * 2.6 + float2(drift * 0.030, drift * 0.021));
    front *= 0.58 + 0.80 * lobes;

    // Then break the radius up in two dimensions as well as around the ring.
    // Ring noise alone only ever yields a wobbly circle: every point at a given
    // angle advances together, so the boundary stays one closed curve however
    // irregular it is. Perturbing the radius itself is what lets filaments run
    // out ahead of the front and small islands break off it.
    float rough = fbm3(p * 11.0 + float2(drift * 0.020, -drift * 0.015)) - 0.5;
    float rEff = r + rough * front * 0.42;

    // Narrow band. A wide one faded the mat out over a third of its radius and
    // the result read as a cotton ball with a halo rather than as a margin.
    float edge = 1.0 - smoothstep(front * 0.88, front, rEff);
    if (edge <= 0.0) {
        detail = 0.0;
        return 0.0;
    }

    // ── The mat ────────────────────────────────────────────────────────────
    // A tap drives the churn forward, so the whole network visibly reorganises
    // rather than only brightening.
    float churn = drift * 0.05 + tap * 1.2;

    // Driven by raw elapsed time rather than `drift`, which carries the session
    // seed and is slowed by grounding. Growth wants to be the one thing in the
    // field that is the same every session and never stops.
    float k = fract(time * MYCELIAL_GROW_RATE);

    float dNear = 0.0, dFar = 0.0;
    float webNear = mycelialLayer(p * exp2(k),       drift, churn, dNear);
    float webFar  = mycelialLayer(p * exp2(k - 1.0), drift, churn, dFar);

    // Linear, not smoothstep — the same finding as the kaleidoscope. A
    // smoothstep dissolves quickly through the middle of the octave, and that
    // burst of dissolve is itself an event you can see and time.
    float web = mix(webNear, webFar, k);
    detail    = mix(dNear,   dFar,   k) * edge;

    // No offset: empty space lands at exactly t = 0, which the mycelial
    // palettes render as black.
    return web * 1.15 * edge;
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

    // ── Form ───────────────────────────────────────────────────────────────
    float detail = 0.0;
    float t;
    if (form == FORM_KALEIDOSCOPE) {
        t = kaleidoscopeField(p, drift, breathWave, detail);
    } else if (form == FORM_TUNNEL) {
        t = tunnelField(p, drift, breathWave, detail);
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
    // Tunnel and weave live or die on hard edges, and heavy feedback is
    // exactly what softens them. They keep much less history than the two
    // forms whose appeal is smear in the first place.
    bool crisp = (form == FORM_TUNNEL || form == FORM_WEAVE);
    float persistBase = crisp ? 0.34 : 0.66;
    float persistence = mix(persistBase, persistBase + 0.18, grounding);
    col = mix(col, history, persistence * 0.72);

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
