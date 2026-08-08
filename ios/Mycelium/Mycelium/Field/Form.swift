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

    /// How much of a form's own hue spread this palette wants, as a multiplier.
    ///
    /// Only the lobes read it, and only because that form has two independent
    /// things driving one `t`: the lobe index spreads colour across the frame,
    /// and time carries the whole arrangement around the wheel. A palette alone
    /// cannot tell those apart — `a`, `b`, `c` and `d` all scale both at once —
    /// so "every lobe the same colour, and that colour cycling" is unreachable
    /// without a knob that touches the index term and not the time term.
    ///
    /// Rides in `palA.w`, which was a padding zero. Every other palette leaves
    /// this at 1 and behaves exactly as before.
    var spread: Float = 1
}

enum Form: Int, CaseIterable, Identifiable, Sendable {
    case mycelial = 0
    case kaleidoscope = 1
    case lobes = 3
    // Next up, per the plan: liquid light.
    //
    // The gap at 2 is deliberate. Raw values are what the shader switches on, so
    // renumbering to close it would be churn for nothing.
    //
    // Three forms have been dropped rather than kept for completeness, and all
    // three are in the history if they are ever wanted back.
    //
    // `smoke` was case 0 — two-level domain-warped fbm. The first form built
    // and the weakest: a wash with no structure, which read as washed-out no
    // matter how much contrast went on top. Mycelial took its slot.
    //
    // `lattice` was case 2 — two hexagonal grids at a small relative angle,
    // showing the moiré between them. Genuinely clever and pure geometry with
    // no noise anywhere, but it and the tunnel wanted the same slot: hard-edged
    // synthetic structure in electric colour. The tunnel did more with it, so
    // the lattice went.
    //
    // `tunnel` had case 2 after it — a log-polar vortex, and by the end the most
    // worked-on thing in the file. Cut 2026-08-07, and not because it was
    // broken. See the note at the top of its section in Field.metal for what is
    // worth stealing out of it.

    /// The forms you can actually choose.
    ///
    /// Mycelial is not among them, and that is the point rather than an
    /// oversight: it is the home screen's *background* now, growing in from the
    /// edges the whole time you sit there. It stays in this enum because the
    /// shader still switches on it and Field Lab still has to be able to render
    /// it — it just isn't a destination any more.
    static let pickable: [Form] = [.kaleidoscope, .lobes]

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .mycelial:     return "Mycelial"
        case .kaleidoscope: return "Kaleidoscope"
        case .lobes:        return "Lobes"
        }
    }

    var blurb: String {
        switch self {
        case .mycelial:     return "a colony, reaching"
        case .kaleidoscope: return "fractal, sixfold"
        case .lobes:        return "eight ways deep"
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

        // Wide and saturated. `t`
        // here is the lobe index, so the palette is sampled at eight points
        // spread evenly around it and nowhere in between. A narrow ramp would
        // hand eight nearly identical colours to the eight lobes and throw away
        // the one thing the form is built to show.
        //
        // These do NOT need t = 0 to be black, and shouldn't be: the dark in
        // this form is `shade` going to zero between
        // the beads, and a palette that also darkens at one lobe would put a
        // permanent dead wedge in the corridor. So a != b throughout, and the
        // dimmest any lobe gets is a deep version of its own colour.
        case .lobes:
            return [
                Palette(name: "Pearl",
                        a: SIMD3(0.52, 0.48, 0.56), b: SIMD3(0.44, 0.42, 0.48),
                        c: SIMD3(1.00, 1.00, 1.00), d: SIMD3(0.00, 0.33, 0.67)),
                Palette(name: "Aurora",
                        a: SIMD3(0.44, 0.52, 0.54), b: SIMD3(0.40, 0.46, 0.42),
                        c: SIMD3(1.00, 0.90, 1.10), d: SIMD3(0.15, 0.45, 0.75)),
                Palette(name: "Ember",
                        a: SIMD3(0.58, 0.44, 0.40), b: SIMD3(0.42, 0.34, 0.30),
                        c: SIMD3(0.90, 1.00, 0.85), d: SIMD3(0.05, 0.25, 0.55)),
                Palette(name: "Deep",
                        a: SIMD3(0.40, 0.44, 0.60), b: SIMD3(0.34, 0.38, 0.46),
                        c: SIMD3(1.05, 0.95, 0.80), d: SIMD3(0.60, 0.20, 0.40)),
                // The odd one out, and it needs `spread` to exist at all.
                //
                // Every palette above hands the eight lobes eight neighbouring
                // hues, so the frame is a colour *gradient* that drifts. This one
                // collapses the spread to almost nothing, which puts every lobe
                // on the same hue — and then the time term, which `spread` does
                // not touch, walks that single hue around the entire wheel. Red,
                // then orange, then yellow, one at a time, whole frame at once.
                //
                // Full amplitude with the three channels a third of a turn apart
                // (d = 0, 1/3, 2/3) is the textbook IQ rainbow. It would be
                // confetti at spread 1, which is exactly why LOBES_HUE_SPAN
                // exists; at 0.05 it is the one arrangement the form otherwise
                // could not make.
                // `d` is (0, 2/3, 1/3) and NOT the textbook (0, 1/3, 2/3),
                // which runs the wheel backwards: red → magenta → blue → cyan →
                // green → yellow → red. On screen that reads as the spectrum in
                // reverse — green sliding into yellow, yellow into orange,
                // orange into red — which is the order things *cool* in, and it
                // looks like the cycle is rewinding.
                //
                // Swapping the green and blue phases turns it around: red →
                // orange → yellow → green → cyan → blue → violet → magenta →
                // red. Same loop, same seam, travelled the other way, and the
                // seam is the one place a colour wheel can close without a join
                // you can see — magenta back into red.
                Palette(name: "Rainbow",
                        a: SIMD3(0.50, 0.50, 0.50), b: SIMD3(0.50, 0.50, 0.50),
                        c: SIMD3(1.00, 1.00, 1.00), d: SIMD3(0.00, 0.67, 0.33),
                        spread: 0.05),
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
