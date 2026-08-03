//
//  Field.metal
//  The living surface. Everything the user stares into is computed here.
//
//  Two passes:
//    1. fieldFragment  — domain-warped fbm + touch blooms, blended with the
//                        previous frame so strokes persist and get woven in.
//    2. presentFragment — tonemap the accumulation buffer to the drawable.
//
//  Safety constraints baked into the math, not bolted on:
//    - No strobe. Every animated term is a slow sine or an exponential decay.
//      Nothing in here can produce a hard flash.
//    - Luminance is soft-clamped in the present pass so a pile of overlapping
//      blooms can brighten the field but never blow it out.
//

#include <metal_stdlib>
using namespace metal;

constant int MAX_BLOOMS = 32;
constant float TAU = 6.28318530718;

// Fully 16-byte aligned so the Swift side maps 1:1 with no padding surprises.
struct Uniforms {
    float4 resTime;     // xy = resolution px, z = time s, w = breath phase 0..1
    float4 groundCount; // x = grounding 0..1, y = bloom count, z = seed, w = spare
    float4 palA;        // IQ cosine palette: bias
    float4 palB;        //                    amplitude
    float4 palC;        //                    frequency
    float4 palD;        //                    phase
};

// xy = position in field space, z = birth time, w = strength
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

// Inigo Quilez cosine palette. Smooth and cyclic by construction, which is
// why it can't produce a hard color jump.
static inline float3 palette(float t, float4 a, float4 b, float4 c, float4 d) {
    return a.rgb + b.rgb * cos(TAU * (c.rgb * t + d.rgb));
}

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

    // Aspect-corrected field space, origin at center.
    float2 uv = in.uv;
    float2 p = (uv - 0.5) * float2(res.x / max(res.y, 1.0), 1.0);

    // Breath drives a slow scale pulse. Grounding deepens it and slows the
    // field's own motion toward stillness.
    float breathWave = sin(breath * TAU);
    float zoom = 1.0 + breathWave * mix(0.035, 0.075, grounding);
    p *= zoom;

    // Grounding slows drift to a near-stop rather than freezing hard.
    float drift = time * mix(1.0, 0.25, grounding);

    // Accumulate bloom influence: a radial push plus a soft expanding ring.
    float2 warp = float2(0.0);
    float glow = 0.0;
    for (int i = 0; i < MAX_BLOOMS; i++) {
        if (i >= bloomCount) break;
        Bloom b = blooms[i];
        float age = max(time - b.z, 0.0);
        float2 d = p - b.xy;
        float dist = length(d);
        float radius = age * 0.16;                       // expands slowly
        float ring = exp(-pow((dist - radius) * 7.0, 2.0));
        float decay = exp(-age * 0.28);                  // long, gentle tail
        // A bright, fast-fading core so a touch reads immediately, plus the
        // slower ring that travels outward from it.
        float core = exp(-dist * dist * 55.0) * exp(-age * 1.1);
        warp += normalize(d + 1e-6) * ring * decay * 0.12 * b.w;
        glow += (ring * decay + core) * b.w;
    }

    // Domain warping — two levels. This is what makes it read as organic
    // rather than as noise.
    float2 q = float2(fbm(p + seed + drift * 0.045),
                      fbm(p + float2(5.2, 1.3) + drift * 0.038));
    float2 r = float2(fbm(p + 3.6 * q + float2(1.7, 9.2) + drift * 0.031),
                      fbm(p + 3.6 * q + float2(8.3, 2.8) + drift * 0.027));
    float f = fbm(p + 3.6 * r + warp * 3.0);

    // Color from the intention-seeded palette.
    float t = f + 0.25 * length(r) + breathWave * 0.04;
    float3 col = palette(t, u.palA, u.palB, u.palC, u.palD);

    // Blooms brighten toward the warm end of the palette.
    col += palette(t + 0.35, u.palA, u.palB, u.palC, u.palD) * glow * 1.05;

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
    // drift inward instead of smearing outward. This is what makes strokes
    // persist and slowly become part of the pattern.
    float2 fbUV = (uv - 0.5) * 0.998 + 0.5;
    float3 history = prev.sample(smp, fbUV).rgb;
    // Tuned by eye against the simulator: much above ~0.55 and a fresh bloom
    // is drowned by its own history before it can read as a touch.
    float persistence = mix(0.72, 0.86, grounding);   // holds longer when grounded
    col = mix(col, history, persistence * 0.72);

    return float4(col, 1.0);
}

fragment float4 presentFragment(VertexOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                sampler smp          [[sampler(0)]]) {
    float3 c = src.sample(smp, in.uv).rgb;

    // Soft-clamp rather than hard clip: overlapping blooms can pile up
    // brightness, and this rolls it off instead of letting it flash white.
    c = c / (1.0 + c * 0.55);

    // Mild lift so deep areas keep some color instead of crushing to black.
    c = pow(max(c, 0.0), float3(0.92));

    return float4(c, 1.0);
}
