//
//  FieldState.swift
//  The model behind the Field. Deliberately plain: this is an event log plus
//  a few scalars, which is what makes replay and peer sync possible later
//  without rearchitecting.
//

import Foundation
import simd

/// A touch bloom. Position is in aspect-corrected field space (origin center),
/// which is the same space the shader works in, so these values can be sent
/// to a peer device verbatim and land in the same place on their screen.
struct Bloom: Equatable, Codable, Sendable {
    var x: Float
    var y: Float
    var birth: Float      // seconds since session start
    var strength: Float

    var packed: SIMD4<Float> { SIMD4(x, y, birth, strength) }
}

/// IQ cosine palette parameters: color(t) = a + b * cos(2pi * (c*t + d))
struct Palette: Equatable, Sendable {
    var a: SIMD3<Float>
    var b: SIMD3<Float>
    var c: SIMD3<Float>
    var d: SIMD3<Float>
}

/// Named moods. The "Before" screen will map a written intention onto one of
/// these; for now they're selectable directly.
enum Mood: String, CaseIterable, Identifiable, Sendable {
    case drift, ember, bloom, verdant, aurora

    var id: String { rawValue }

    var title: String {
        switch self {
        case .drift:   return "Drift"
        case .ember:   return "Ember"
        case .bloom:   return "Bloom"
        case .verdant: return "Verdant"
        case .aurora:  return "Aurora"
        }
    }

    var palette: Palette {
        switch self {
        case .drift:
            return Palette(a: SIMD3(0.22, 0.34, 0.44),
                           b: SIMD3(0.28, 0.34, 0.38),
                           c: SIMD3(1.00, 0.95, 0.60),
                           d: SIMD3(0.00, 0.18, 0.42))
        case .ember:
            return Palette(a: SIMD3(0.44, 0.26, 0.18),
                           b: SIMD3(0.40, 0.26, 0.16),
                           c: SIMD3(0.90, 0.80, 0.55),
                           d: SIMD3(0.02, 0.12, 0.24))
        case .bloom:
            return Palette(a: SIMD3(0.38, 0.22, 0.42),
                           b: SIMD3(0.36, 0.24, 0.38),
                           c: SIMD3(1.00, 0.85, 0.75),
                           d: SIMD3(0.10, 0.32, 0.58))
        case .verdant:
            return Palette(a: SIMD3(0.22, 0.38, 0.28),
                           b: SIMD3(0.24, 0.36, 0.26),
                           c: SIMD3(0.85, 1.00, 0.70),
                           d: SIMD3(0.18, 0.06, 0.34))
        case .aurora:
            return Palette(a: SIMD3(0.30, 0.32, 0.38),
                           b: SIMD3(0.34, 0.36, 0.36),
                           c: SIMD3(1.00, 1.00, 1.00),
                           d: SIMD3(0.00, 0.33, 0.67))
        }
    }
}

/// Breath pacing. Grounded pacing is resonant breathing — 5.5 breaths per
/// minute, i.e. a ~11s full cycle (5.5s in, 5.5s out). That number is the
/// point of the mode, so it's a named constant rather than a magic float.
enum Breath {
    static let groundedCycleSeconds: Float = 11.0
    static let ambientCycleSeconds: Float = 17.0   // slower + looser when not grounding
}

@MainActor
@Observable
final class FieldState {
    static let maxBlooms = 32

    private(set) var blooms: [Bloom] = []
    var mood: Mood = .drift

    /// 0 = normal, 1 = fully grounded. Eased, never snapped — a hard cut to
    /// grounding mode would be its own jolt.
    private(set) var grounding: Float = 0
    private(set) var groundingTarget: Float = 0

    private(set) var breathPhase: Float = 0
    private(set) var elapsed: Float = 0

    /// Stable per-session seed so the same session looks like itself.
    let seed: Float = Float.random(in: 0..<100)

    func advance(deltaTime: Float) {
        elapsed += deltaTime

        // Ease grounding toward its target over roughly a second.
        let easeRate: Float = 1.6
        if abs(groundingTarget - grounding) > 0.001 {
            grounding += (groundingTarget - grounding) * min(deltaTime * easeRate, 1)
        } else {
            grounding = groundingTarget
        }

        let cycle = simd_mix(Breath.ambientCycleSeconds, Breath.groundedCycleSeconds, grounding)
        breathPhase += deltaTime / cycle
        if breathPhase > 1 { breathPhase -= floor(breathPhase) }

        // Retire blooms once their contribution is imperceptible. The shader
        // decays at exp(-age * 0.28), so ~25s is comfortably past visible.
        blooms.removeAll { elapsed - $0.birth > 25 }
    }

    func addBloom(x: Float, y: Float, strength: Float = 1.0) {
        let bloom = Bloom(x: x, y: y, birth: elapsed, strength: strength)
        blooms.append(bloom)
        // Oldest-out. Bounded so the uniform buffer never overflows.
        if blooms.count > Self.maxBlooms {
            blooms.removeFirst(blooms.count - Self.maxBlooms)
        }
    }

    func setGrounding(_ active: Bool) {
        groundingTarget = active ? 1 : 0
    }

    /// Where in the breath cycle we are, as a 0…1 "fullness" value.
    /// Used to drive the grounding halo and haptics.
    var breathFullness: Float {
        (sin(breathPhase * 2 * .pi - .pi / 2) + 1) / 2
    }

    var packedBlooms: [SIMD4<Float>] {
        blooms.map(\.packed)
    }
}
