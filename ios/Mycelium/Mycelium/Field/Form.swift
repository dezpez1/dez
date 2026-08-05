//
//  Form.swift
//  Which shape the field takes, and the palettes that belong to it.
//
//  Palettes are a property of the form rather than a global list. The two were
//  orthogonal at first — five shared moods, any form in any palette — and it
//  didn't survive contact: a full-spectrum sweep that looks alive on a loose form
//  garish on the kaleidoscope, because that form already carries its own
//  structure and doesn't need the colour arguing with it. Curating per form
//  costs a little duplication and buys every combination being one worth
//  shipping.
//
//  Adding a form is: a case here with its palettes, a `somethingField()` in
//  Field.metal, and a branch in `fieldFragment`. Nothing else needs to know.
//

import simd

/// Inigo Quilez cosine palette: color(t) = a + b * cos(2pi * (c*t + d)).
/// Smooth and cyclic by construction, which is why it can't produce a hard
/// colour jump no matter what `t` does.
struct Palette: Equatable, Sendable {
    var name: String
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var c: SIMD3<Float>
    var d: SIMD3<Float>
}

enum Form: Int, CaseIterable, Identifiable, Sendable {
    case mycelial = 0
    case kaleidoscope = 1
    case tunnel = 2
    case weave = 3
    // Next up, per the plan: liquid light.
    //
    // Two forms have been dropped rather than kept for completeness. Both are
    // in the history if they're ever wanted back.
    //
    // `smoke` was case 0 — two-level domain-warped fbm. The first form built
    // and the weakest: a wash with no structure, which read as washed-out no
    // matter how much contrast went on top. Mycelial took its slot.
    //
    // `lattice` was case 2 — two hexagonal grids at a small relative angle,
    // showing the moiré between them. Genuinely clever and pure geometry with
    // no noise anywhere, but it and the tunnel wanted the same slot: hard-edged
    // synthetic structure in electric colour. The tunnel does more with it, so
    // the lattice went.

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .mycelial:     return "Mycelial"
        case .kaleidoscope: return "Kaleidoscope"
        case .tunnel:       return "Tunnel"
        case .weave:        return "Weave"
        }
    }

    var blurb: String {
        switch self {
        case .mycelial:     return "a colony, reaching"
        case .kaleidoscope: return "fractal, sixfold"
        case .tunnel:       return "a corridor, spiralling"
        case .weave:        return "one endless ribbon"
        }
    }

    /// Four per form. Curated rather than generated — the point of moving
    /// palettes onto the form was that every one of them should be good.
    var palettes: [Palette] {
        switch self {

        // Restrained on purpose. The fractal supplies the complexity, so these
        // stay narrow — this is the form where a rainbow reads as noise.
        case .kaleidoscope:
            return [
                Palette(name: "Obsidian",
                        a: SIMD3(0.10, 0.13, 0.18), b: SIMD3(0.35, 0.42, 0.50),
                        c: SIMD3(0.70, 0.70, 0.70), d: SIMD3(0.35, 0.45, 0.55)),
                Palette(name: "Reef",
                        a: SIMD3(0.25, 0.38, 0.40), b: SIMD3(0.35, 0.28, 0.30),
                        c: SIMD3(0.80, 0.60, 0.70), d: SIMD3(0.10, 0.45, 0.85)),
                Palette(name: "Bone",
                        a: SIMD3(0.42, 0.38, 0.33), b: SIMD3(0.28, 0.26, 0.22),
                        c: SIMD3(0.50, 0.50, 0.50), d: SIMD3(0.05, 0.10, 0.18)),
                Palette(name: "Vespers",
                        a: SIMD3(0.24, 0.16, 0.32), b: SIMD3(0.34, 0.24, 0.30),
                        c: SIMD3(0.75, 0.85, 0.55), d: SIMD3(0.72, 0.90, 0.20)),
            ]

        // The one form that earns a full spectrum. Every other form here is
        // busy — a wide sweep on top of busy structure reads as noise, which is
        // why the kaleidoscope's palettes are so restrained. The tunnel is the
        // opposite: large, smooth, well-separated tiles, and it can carry a
        // rainbow across them without any of it turning to mud.
        //
        // Built like the mycelial set so `t = 0` is exactly black (a == b,
        // d = 0.5). Here that isn't for empty space, it's for the mortar
        // between tiles — the corridor only reads as depth if the gaps are
        // genuinely dark.
        //
        // The three channels are given slightly different frequencies rather
        // than a shared one plus phase offsets. That's what makes the hue keep
        // travelling as `t` rises instead of settling into two alternating
        // colours.
        case .tunnel:
            return [
                Palette(name: "Prism",
                        a: SIMD3(0.50, 0.50, 0.50), b: SIMD3(0.50, 0.50, 0.50),
                        c: SIMD3(0.80, 1.00, 1.25), d: SIMD3(0.50, 0.50, 0.50)),
                Palette(name: "Neon",
                        a: SIMD3(0.50, 0.30, 0.55), b: SIMD3(0.50, 0.30, 0.55),
                        c: SIMD3(1.10, 0.85, 1.30), d: SIMD3(0.50, 0.50, 0.50)),
                Palette(name: "Oilslick",
                        a: SIMD3(0.38, 0.44, 0.52), b: SIMD3(0.38, 0.44, 0.52),
                        c: SIMD3(1.45, 1.15, 0.90), d: SIMD3(0.50, 0.50, 0.50)),
                Palette(name: "Vapor",
                        a: SIMD3(0.52, 0.40, 0.48), b: SIMD3(0.52, 0.40, 0.48),
                        c: SIMD3(0.65, 0.90, 1.05), d: SIMD3(0.50, 0.50, 0.50)),
            ]

        // Materials, not light. The weave reads as a made thing, so its
        // palettes are dyes and metals rather than glows.
        case .weave:
            return [
                Palette(name: "Rust",
                        a: SIMD3(0.42, 0.26, 0.14), b: SIMD3(0.38, 0.28, 0.16),
                        c: SIMD3(0.85, 0.75, 0.60), d: SIMD3(0.05, 0.15, 0.30)),
                Palette(name: "Jade",
                        a: SIMD3(0.20, 0.38, 0.32), b: SIMD3(0.24, 0.34, 0.30),
                        c: SIMD3(0.80, 0.95, 0.70), d: SIMD3(0.20, 0.10, 0.35)),
                Palette(name: "Ash",
                        a: SIMD3(0.34, 0.36, 0.40), b: SIMD3(0.26, 0.26, 0.28),
                        c: SIMD3(0.55, 0.55, 0.55), d: SIMD3(0.40, 0.44, 0.50)),
                Palette(name: "Saffron",
                        a: SIMD3(0.46, 0.34, 0.14), b: SIMD3(0.40, 0.32, 0.18),
                        c: SIMD3(0.75, 0.65, 0.90), d: SIMD3(0.10, 0.20, 0.55)),
            ]

        // Built so that t = 0 is exactly black: a == b and d == 0.5 makes
        // a + b*cos(pi) vanish. Every other form fills the screen with colour,
        // but this one is filaments against dark, and that only works if empty
        // space actually renders as empty.
        case .mycelial:
            return [
                Palette(name: "Spore",
                        a: SIMD3(0.42, 0.36, 0.26), b: SIMD3(0.42, 0.36, 0.26),
                        c: SIMD3(0.50, 0.55, 0.60), d: SIMD3(0.50, 0.50, 0.50)),
                Palette(name: "Fungal",
                        a: SIMD3(0.40, 0.24, 0.42), b: SIMD3(0.40, 0.24, 0.42),
                        c: SIMD3(0.50, 0.60, 0.55), d: SIMD3(0.50, 0.50, 0.50)),
                Palette(name: "Deep",
                        a: SIMD3(0.18, 0.32, 0.44), b: SIMD3(0.18, 0.32, 0.44),
                        c: SIMD3(0.55, 0.50, 0.45), d: SIMD3(0.50, 0.50, 0.50)),
                Palette(name: "Filament",
                        a: SIMD3(0.40, 0.37, 0.30), b: SIMD3(0.40, 0.37, 0.30),
                        c: SIMD3(0.45, 0.50, 0.60), d: SIMD3(0.50, 0.50, 0.50)),
            ]
        }
    }
}
