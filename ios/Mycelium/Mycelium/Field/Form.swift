//
//  Form.swift
//  The *shape* of the visual, independent of its color.
//
//  Form and Mood are deliberately orthogonal: any form renders in any palette.
//  Adding a form means adding a case here and a branch in Field.metal — the
//  renderer, state, and picker all pick it up without changes.
//

import Foundation

enum Form: Int, CaseIterable, Identifiable, Sendable {
    case smoke = 0
    case kaleidoscope = 1
    case lattice = 2
    case weave = 3
    // Next up, per the plan: mycelial growth, liquid light.

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .smoke:        return "Smoke"
        case .kaleidoscope: return "Kaleidoscope"
        case .lattice:      return "Lattice"
        case .weave:        return "Weave"
        }
    }

    /// Shown under the live preview so the tiles read as more than swatches.
    var blurb: String {
        switch self {
        case .smoke:        return "ink through water"
        case .kaleidoscope: return "fractal, sixfold"
        case .lattice:      return "grids interfering"
        case .weave:        return "one endless ribbon"
        }
    }
}
