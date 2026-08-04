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

constant int FORM_SMOKE = 0;
constant int FORM_KALEIDOSCOPE = 1;
constant int FORM_LATTICE = 2;
constant int FORM_WEAVE = 3;

// How much of a tap each form takes. Smoke is a wash and can absorb a lot;
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
/// in magnification. 0.10 is a doubling every 10s — unmistakably moving without
/// being a ride. Past ~0.2 it starts to feel like falling.
constant float ZOOM_RATE = 0.10;

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
// Nothing in this shader reads xy any more — a tap answers everywhere at once,
// so a touch in the corner and a touch dead centre produce an identical field.
// Position stays in the event log on purpose: it costs nothing, forms that need
// it are coming (mycelial growth reaches out from where you touched), and that
// log is the substrate both sync and replay are built on.
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
/// pulls veins and filaments out of the smoke instead of leaving a wash.
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

/// Smoke — two-level domain-warped fbm with a ridged overlay for definition.
/// Returns a scalar the caller maps through the palette.
static inline float smokeField(float2 p, float drift, float breathWave,
                               thread float &detail) {
    float2 q = float2(fbm(p + drift * 0.062),
                      fbm(p + float2(5.2, 1.3) + drift * 0.053));
    float2 r = float2(fbm(p + 3.6 * q + float2(1.7, 9.2) + drift * 0.043),
                      fbm(p + 3.6 * q + float2(8.3, 2.8) + drift * 0.038));
    float f = fbm(p + 3.6 * r);

    // Ridges ride the same warped space, so the creases follow the flow
    // instead of sitting on top of it as unrelated texture.
    detail = ridged(p * 1.7 + 2.2 * r);

    // Widen the range fed to the palette so a single frame spans more of the
    // color sweep — the old version hovered near one hue and read as flat.
    return f * 1.35 + length(r) * 0.42 + breathWave * 0.05;
}

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
    float k = fract(drift * ZOOM_RATE);

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

/// Lattice — two hexagonal grids laid over each other at a slowly changing
/// relative angle and scale. The pattern you see isn't either grid: it's the
/// interference between them, which is why a fraction of a degree of drift
/// reorganises the entire screen. Pure geometry, no noise anywhere.
static inline float latticeField(float2 p, float drift, float breathWave,
                                 thread float &detail) {
    // Fine enough that the grid itself reads as a grid. The first version used
    // scale 9, which put barely one period on screen — the whole display became
    // a single soft blob with no lattice visible anywhere.
    float scale = 110.0 * (1.0 + breathWave * 0.02);

    // Both copies turn together slowly; what matters is the small angle
    // BETWEEN them, and that oscillates inside a narrow band rather than
    // running free. Letting the relative angle sweep sends the moire from
    // one screen-sized blob to invisible grain within a few seconds — the
    // interesting range is only about a tenth of a radian wide, so the form
    // has to live inside it deliberately.
    float base  = drift * 0.006;
    float split = 0.085 + 0.030 * sin(drift * 0.045);

    float sum = 0.0;
    float sharp = 0.0;

    for (int layer = 0; layer < 2; layer++) {
        float rot = base + (layer == 0 ? -split : split) * 0.5;
        float cs = cos(rot), sn = sin(rot);
        float2 q = float2(p.x * cs - p.y * sn, p.x * sn + p.y * cs) * scale;

        // Three axes at 60 degrees = a hexagonal lattice. Summed cosines
        // rather than a distance field, so it stays smooth and can't alias.
        for (int k = 0; k < 3; k++) {
            float a = float(k) * (M_PI_F / 3.0);
            float w = cos(dot(q, float2(cos(a), sin(a))));
            sum += w;
            sharp += w * w;
        }
    }

    // Crests where the two lattices agree — the bright nodes of the moire.
    detail = clamp(pow(max(sharp / 6.0, 0.0), 3.0) * 1.6, 0.0, 1.0);
    return sum * 0.18 + 0.5 + breathWave * 0.04;
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

    // Smoke is the default form, so it's the one tested for and the one
    // anything unrecognised falls back to.
    float glowScale = (form == FORM_SMOKE) ? GLOW_ORGANIC : GLOW_STRUCTURED;

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
    } else if (form == FORM_LATTICE) {
        t = latticeField(p, drift, breathWave, detail);
    } else if (form == FORM_WEAVE) {
        t = weaveField(p, drift, breathWave, detail);
    } else {
        t = smokeField(p, drift, breathWave, detail);
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
    // On the kaleidoscope the contraction is locked to the zoom rate rather
    // than left at a fixed 0.998. A fixed value drifts the trail outward at
    // ~11%/s against a field zooming at ~4%/s, and a ghost travelling 3x faster
    // than the thing casting it doesn't read as motion — it reads as blur, and
    // it buries the zoom entirely. Matched, the history lands exactly where the
    // pattern is going and the whole frame moves as one.
    float dt = max(u.holdParams.z, 1.0 / 240.0);
    float fbContract = (form == FORM_KALEIDOSCOPE) ? exp2(-ZOOM_RATE * dt) : 0.998;
    float2 fbUV = (uv - 0.5) * fbContract + 0.5;
    float3 history = prev.sample(smp, fbUV).rgb;
    // Lattice and weave live or die on hard edges, and heavy feedback is
    // exactly what softens them. They keep much less history than the two
    // forms whose appeal is smear in the first place.
    bool crisp = (form == FORM_LATTICE || form == FORM_WEAVE);
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
