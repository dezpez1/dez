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
    case lattice = 2
    case weave = 3
    // Next up, per the plan: liquid light.
    //
    // `smoke` used to be case 0 — two-level domain-warped fbm. It was the first
    // form built and the weakest: a wash with no structure, which read as
    // washed-out no matter how much contrast went on top. Dropped rather than
    // kept for completeness. It's in the history if it's ever wanted back.

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .mycelial:     return "Mycelial"
        case .kaleidoscope: return "Kaleidoscope"
        case .lattice:      return "Lattice"
        case .weave:        return "Weave"
        }
    }

    var blurb: String {
        switch self {
        case .mycelial:     return "a colony, reaching"
        case .kaleidoscope: return "fractal, sixfold"
        case .lattice:      return "grids interfering"
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

        // Electric and synthetic. Moire is an interference effect, and it wants
        // contrast to read at all — this is the one form that earns hard colour.
        case .lattice:
            return [
                Palette(name: "Neon",
                        a: SIMD3(0.40, 0.20, 0.45), b: SIMD3(0.45, 0.35, 0.45),
                        c: SIMD3(1.00, 1.00, 1.00), d: SIMD3(0.00, 0.45, 0.75)),
                Palette(name: "Chrome",
                        a: SIMD3(0.42, 0.46, 0.52), b: SIMD3(0.32, 0.32, 0.34),
                        c: SIMD3(0.60, 0.60, 0.60), d: SIMD3(0.30, 0.35, 0.42)),
                Palette(name: "Ultraviolet",
                        a: SIMD3(0.22, 0.14, 0.42), b: SIMD3(0.30, 0.22, 0.42),
                        c: SIMD3(0.90, 1.10, 0.80), d: SIMD3(0.60, 0.70, 0.90)),
                Palette(name: "Signal",
                        a: SIMD3(0.26, 0.40, 0.22), b: SIMD3(0.30, 0.42, 0.20),
                        c: SIMD3(0.70, 0.90, 0.50), d: SIMD3(0.25, 0.20, 0.10)),
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
