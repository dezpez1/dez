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

/// Breath pacing. Grounded pacing is resonant breathing — 5.5 breaths per
/// minute, i.e. a ~11s full cycle (5.5s in, 5.5s out). That number is the
/// point of the mode, so it's a named constant rather than a magic float.
enum Breath {
    static let groundedCycleSeconds: Float = 11.0
    /// Ambient sits between "barely moving" and "alive and flowing" — fast
    /// enough that the field is visibly going somewhere, slow enough that it
    /// never asks for attention.
    static let ambientCycleSeconds: Float = 13.0

    /// Hold-to-pulse rhythm: glow, dim, glow, dim. Deliberately faster than
    /// either breath — this one is an answer to your finger, so it has to read
    /// as caused rather than as the field's own idling.
    static let holdPulseSeconds: Float = 2.2
}

/// The mycelial colony's own dynamics. Lives here rather than in the shader
/// because a tap changes it, and a tap is an event — the shader is a pure
/// function of what it's handed and has nowhere to keep the consequence.
///
/// The mechanic: the mat grows until it fills the frame and then sits there.
/// Tapping shoves the camera back, which shrinks everything on screen and puts
/// the margin back inside the frame, and the colony has to grow into the space
/// again. So the form is a settled mat you can always give something to do.
enum Colony {
    /// Screen radius in field units, where the visible area is ~0.46 wide and
    /// 1.0 tall — the corners sit at ~0.55.
    ///
    /// `start` is deliberately tiny. Below COLONY_SEED * e^COLONY_SPAN (~0.29)
    /// the shader counts growth from a fixed speck rather than from a radius
    /// that scales with the colony, and it runs the resistance contrast far
    /// higher — so the first thing on screen is one filament finding its way
    /// out, not a small copy of a finished mat.
    static let start: Float = 0.045
    /// Past the corners on purpose: at rest the mat owns the whole frame.
    static let full: Float = 0.86
    /// However many times it gets tapped, the colony never shrinks to nothing.
    static let floorReach: Float = 0.17

    /// Octaves of radius per second. **Multiplicative, not an approach toward a
    /// target**, and the difference is the entire seedling phase.
    ///
    /// An exponential approach covers most of the absolute distance first,
    /// because that's where the gap is biggest — from a speck to a third of the
    /// screen took under two seconds, so the one-filament stage was over before
    /// anyone saw it. A colony doubles; it doesn't add inches. At a constant
    /// 0.10 octaves/sec the whole run from seed to full frame takes ~42s, the
    /// seedling stage lasts ~25s of it, and one tap's worth of pullback grows
    /// back in ~6s.
    static let growOctavesPerSecond: Float = 0.10

    /// Eased over the last half-octave so it settles instead of hitting the cap.
    static let growEaseOctaves: Float = 0.5

    /// How far back one tap shoves the camera, in octaves. 0.62 is a shrink to
    /// 65% — big enough that the margin is unmistakably back in frame, small
    /// enough that the mat doesn't vanish to a speck.
    static let tapPullback: Float = 0.62
    /// And how fast that shove eases in. Fast enough to read as caused by the
    /// finger, slow enough that it's a lurch backwards rather than a cut.
    static let pushRate: Float = 1.8
}

@MainActor
@Observable
final class FieldState {
    static let maxBlooms = 32

    private(set) var blooms: [Bloom] = []

    /// Which form is running, and which of that form's own palettes is
    /// selected. Palettes belong to the form now — see Form.swift for why —
    /// so this is an index into `form.palettes`, not a global mood.
    var form: Form = .mycelial {
        didSet { paletteIndex = min(paletteIndex, form.palettes.count - 1) }
    }
    var paletteIndex: Int = 0

    var palette: Palette {
        let all = form.palettes
        return all[min(max(paletteIndex, 0), all.count - 1)]
    }

    /// 0 = normal, 1 = fully grounded. Eased, never snapped — a hard cut to
    /// grounding mode would be its own jolt.
    private(set) var grounding: Float = 0
    private(set) var groundingTarget: Float = 0

    private(set) var breathPhase: Float = 0
    private(set) var elapsed: Float = 0

    /// Hold-to-pulse. `hold` is the eased amount (0 = released, 1 = fully
    /// engaged). The phase resets on engage so the rhythm always starts on the
    /// rise — coming in mid-dim would read as the field ignoring you.
    private(set) var hold: Float = 0
    private(set) var holdTarget: Float = 0
    private(set) var holdPhase: Float = 0

    /// The mycelial colony. `reach` is its radius on screen; `zoomPush` is how
    /// far the camera has been shoved back, in octaves, and only ever grows.
    /// `pushDelta` is what it moved this frame — the shader needs it to keep
    /// the feedback trail locked to the camera during a pullback.
    private(set) var colonyReach: Float = Colony.start
    private(set) var zoomPush: Float = 0
    private(set) var pushDelta: Float = 0
    private var zoomPushTarget: Float = 0

    /// Stable per-session seed so the same session looks like itself.
    let seed: Float = Float.random(in: 0..<100)

    func advance(deltaTime: Float) {
        elapsed += deltaTime

        // ── The colony ─────────────────────────────────────────────────────
        let prevPush = zoomPush
        if abs(zoomPushTarget - zoomPush) > 0.0005 {
            zoomPush += (zoomPushTarget - zoomPush) * min(deltaTime * Colony.pushRate, 1)
        } else {
            zoomPush = zoomPushTarget
        }
        pushDelta = zoomPush - prevPush

        // Whatever the camera just did to the frame, the colony's footprint on
        // it did too. Driving both off the same eased delta rather than
        // setting the reach outright at the moment of the tap is what keeps
        // them from drifting apart: the mat shrinks at exactly the rate the
        // view pulls back, so the margin never slides against the texture.
        //
        // The floor is a floor on *shrinking*, never a minimum size. Applied
        // as a plain `max` it also silently promoted a brand-new seedling to
        // floor height on its first frame, so `Colony.start` did nothing at all
        // and the one-filament stage never existed. Clamping to whichever is
        // smaller of the floor and where the colony already was keeps taps from
        // shrinking it to nothing without ever growing it.
        colonyReach = max(colonyReach * exp2(-pushDelta),
                          min(Colony.floorReach, colonyReach))

        // Then it grows back into the room it was just given.
        let head = log2(Colony.full / max(colonyReach, 0.001))
        if head > 0 {
            let ease = min(1, head / Colony.growEaseOctaves)
            let step = min(Colony.growOctavesPerSecond * deltaTime * ease, head)
            colonyReach *= exp2(step)
        }

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

        // Hold engages faster than it releases. Snapping on is what makes it
        // feel caused; letting go slowly is what keeps release from being a
        // cut. Asymmetric on purpose.
        let holdRate: Float = holdTarget > hold ? 3.0 : 1.2
        if abs(holdTarget - hold) > 0.001 {
            hold += (holdTarget - hold) * min(deltaTime * holdRate, 1)
        } else {
            hold = holdTarget
        }
        holdPhase += deltaTime / Breath.holdPulseSeconds
        if holdPhase > 1 { holdPhase -= floor(holdPhase) }

        // Retire blooms once their contribution is imperceptible. The shader
        // decays at exp(-age * 0.28), so ~25s is comfortably past visible.
        blooms.removeAll { elapsed - $0.birth > 25 }
    }

    func addBloom(x: Float, y: Float, strength: Float = 1.0) {
        let bloom = Bloom(x: x, y: y, birth: elapsed, strength: strength)
        blooms.append(bloom)

        // A tap shoves the camera back. Only mycelial reads this, and only
        // mycelial wants it: on that form the mat settles into owning the whole
        // frame, and pulling back is what puts the growing margin — the only
        // part of it that's actually doing anything — back inside the screen.
        //
        // Accumulated rather than assigned, so leaning on the screen keeps
        // opening space rather than one tap winning and the rest doing nothing.
        //
        // Gated on the form, or tapping the kaleidoscope would quietly shrink a
        // colony you aren't looking at and you'd come back to a speck.
        if form == .mycelial { zoomPushTarget += Colony.tapPullback }
        // Oldest-out. Bounded so the uniform buffer never overflows.
        if blooms.count > Self.maxBlooms {
            blooms.removeFirst(blooms.count - Self.maxBlooms)
        }
    }

    func setGrounding(_ active: Bool) {
        groundingTarget = active ? 1 : 0
    }

    /// Engaged by a stationary finger. Starts the field glowing and dimming in
    /// time, and keeps it up until the finger lifts.
    func setHolding(_ active: Bool) {
        if active && holdTarget == 0 { holdPhase = 0 }
        holdTarget = active ? 1 : 0
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
