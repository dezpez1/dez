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
/// because a gesture changes them, and a gesture is an event — the shader is a
/// pure function of what it's handed and has nowhere to keep the consequence.
///
/// The mechanic: the mat opens already meshed, keeps thickening for another half
/// minute, and then sits there. Pinching out shrinks everything on screen, which
/// is exactly what buys room for finer levels, and the colony grows into it. So
/// the form is a settled mat you can always give something to do — and unlike
/// the tap-to-pull-back it replaced, pinching back in is right there too.
enum Colony {
    /// Where the colony opens, in levels.
    ///
    /// It used to open at zero: one filament on a black screen, and something
    /// worth looking at about half a minute later. That ceremony was built when
    /// the whole argument was "prove it grows rather than appears" — and it did
    /// prove it, and then it cost the form every session's first thirty seconds.
    ///
    /// Eight is already meshed: the spores have met, there is a network across
    /// the frame, and the five levels still to come are the part you watch.
    /// Growth is not skipped, it is *joined in progress* — which is what looking
    /// at a real mat is, since nobody is present for the first day of one.
    ///
    /// Counted in levels of `grown`, which is no longer the same as depth: with
    /// TREE_JITTER every branch waits its own extra fraction of a level on top
    /// of its ancestors', averaging ~0.31 per level. Eight of these is about six
    /// levels deep.
    static let startLevels: Float = 1.5

    /// Seconds the first level takes, and the ratio per level after it.
    ///
    /// Not a constant rate per level, and that is the point: **the tip speed is
    /// what's constant.** Branch lengths shrink by TREE_SHRINK each level, so a
    /// deeper branch is shorter and therefore takes proportionally less time to
    /// put out. Growing every level in the same wall-clock time instead makes
    /// the twigs crawl and the trunk snap out, which is backwards.
    static let genSeconds: Float = 88.0
    static let genShrink: Float = 0.87

    /// …with a floor, or the geometric series would have level twelve arriving
    /// in a quarter of a second and every level after a zoom-out a blink.
    /// 1.5s is about as fast as a fork can appear and still be seen forking.
    static let genFloor: Float = 38.0

    /// Where growth stops at rest, and this is a legibility number rather than a
    /// coverage one. Every level doubles the branch count inside the same disc,
    /// and past about ten levels deep a colony comes out as dense mat with no
    /// branching legible in it at all — which is exactly the complaint this form
    /// has spent five rounds answering.
    ///
    /// Thirteen of `grown` is roughly ten deep once TREE_JITTER's average wait
    /// is taken off, which spans the frame across seven colonies and stops while
    /// the structure can still be read. The test is unchanged: **can you pick
    /// one cord at the margin and follow it inward through two junctions?**
    static let levels: Float = 13

    /// How many extra levels one octave of pulling back buys. Zooming out by 2x
    /// halves everything on screen, and each level is TREE_SHRINK shorter than
    /// the last, so an octave is worth ln2 / -ln(0.87) = 4.98 levels of it.
    /// This is what makes zooming out mean something: the colony gets smaller
    /// AND gets somewhere new to grow, and it grows there.
    static let levelsPerOctave: Float = 4.98

    /// How far the zoom can travel, in octaves, either side of where it opens.
    ///
    /// **It is a range and not a ratchet, and that is the whole of this
    /// control.** Zoom used to be a side effect of tapping that only ever
    /// increased, so about three taps in you hit the TREE_LEVELS loop bound and
    /// every further tap shrank the colony without buying any growth at all,
    /// with no path back. It is a two-way pinch now and the tap is out of it
    /// entirely — one gesture, one job.
    ///
    /// Out is the larger half because out is the half that does something new:
    /// each octave buys ~5 levels of growth to fill it. In only magnifies what
    /// is already there, and much past one octave the cords go soft, since the
    /// mat texture is generated at a fixed frequency and doesn't gain detail
    /// when you get closer to it.
    static let zoomIn:  Float = -1.0
    static let zoomOut: Float =  2.2

    /// How much of a pinch it takes to cross an octave. 1.7 means a pinch that
    /// doubles the finger spacing moves about 0.31 octaves — deliberately less
    /// than a photo app, because this gets used by people who are not precise
    /// and overshooting to a speck is worse than needing a second pinch.
    static let zoomPerPinch: Float = 1.7

    /// And how fast the view chases the pinch. Fast enough to feel attached to
    /// the fingers, slow enough that a jittery hand doesn't shake the field.
    static let zoomRate: Float = 9.0

    /// How far back one tap shoves the camera, in octaves. 0.62 is a shrink to
    /// 65% — big enough that there is unmistakably room in frame again, small
    /// enough that the colony doesn't vanish to a speck.
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

    /// The mycelial colony. `growth` is how many levels of the tree exist, as a
    /// real number; `zoomPush` is how far the camera has been shoved back, in
    /// octaves, and only ever grows. `pushDelta` is what it moved this frame —
    /// the shader needs it to keep the feedback trail locked to the camera
    /// during a pullback.
    private(set) var colonyGrowth: Float = Colony.startLevels
    private(set) var zoomPush: Float = 0
    private(set) var pushDelta: Float = 0
    private var zoomPushTarget: Float = 0

    /// Stable per-session seed so the same session looks like itself.
    ///
    /// Injectable because "random by default" and "reproducible when asked" are
    /// both requirements and they are not in tension: a session wants its own
    /// look, and a measurement wants to be a measurement. Field Lab's capture
    /// mode pins it — without that, two renders of the same shader differ and
    /// you cannot tell your edit apart from the dice.
    let seed: Float

    init(seed: Float = Float.random(in: 0..<100)) {
        self.seed = seed
    }

    func advance(deltaTime: Float) {
        elapsed += deltaTime

        // ── The colony ─────────────────────────────────────────────────────
        // The view chases the pinch. `pushDelta` is what it moved this frame,
        // which the shader needs to keep the feedback trail locked to the camera
        // while the zoom is moving — a trail that stays put while the field
        // slides under it doesn't read as a ghost, it reads as smear.
        let prevPush = zoomPush
        if abs(zoomPushTarget - zoomPush) > 0.0005 {
            zoomPush += (zoomPushTarget - zoomPush) * min(deltaTime * Colony.zoomRate, 1)
        } else {
            zoomPush = zoomPushTarget
        }
        pushDelta = zoomPush - prevPush

        // Then it grows, one level at a time, into however much room there is.
        //
        // The clock is per level and gets faster as it goes, because a deeper
        // branch is shorter and the thing that's actually constant is the speed
        // of a growing tip. Integrated rather than solved in closed form purely
        // so the floor can be in it — a geometric series has level fifteen
        // arriving in a fifth of a second, and a fork that appears in a fifth
        // of a second is a fork nobody saw happen.
        //
        // The cap is what zooming out moves, and only zooming OUT: pulling back
        // makes everything smaller on screen, which is exactly what buys room
        // for finer levels. Zooming in past the opening scale magnifies what is
        // already there and must not *remove* levels — un-growing a colony reads
        // as the mat retracting, which nothing living does. Hence `max(_, 0)`,
        // and hence growth staying monotone whatever the fingers do.
        let cap = Colony.levels + max(zoomPush, 0) * Colony.levelsPerOctave
        if colonyGrowth < cap {
            let duration = max(Colony.genSeconds * pow(Colony.genShrink, colonyGrowth),
                               Colony.genFloor)
            colonyGrowth = min(colonyGrowth + deltaTime / duration, cap)
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

    /// Back to the first frame of a session, keeping the seed so that what you
    /// see next is comparable with what you just saw. Everything here is either
    /// a clock or an eased scalar, so there is nothing to tear down — which is
    /// the event-log design paying off rather than a coincidence.
    ///
    /// Field Lab calls this; the Morning View will want it too, since a replay
    /// is a session restarted against a recorded log.
    func reset() {
        blooms.removeAll()
        elapsed = 0
        breathPhase = 0
        grounding = 0
        groundingTarget = 0
        hold = 0
        holdTarget = 0
        holdPhase = 0
        colonyGrowth = Colony.startLevels
        zoomPush = 0
        zoomPushTarget = 0
        pushDelta = 0
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
        // Oldest-out. Bounded so the uniform buffer never overflows.
        if blooms.count > Self.maxBlooms {
            blooms.removeFirst(blooms.count - Self.maxBlooms)
        }
    }

    func setGrounding(_ active: Bool) {
        groundingTarget = active ? 1 : 0
    }

    /// Where the zoom was when the current pinch started. The gesture reports an
    /// absolute scale relative to its own first frame, so the anchor is what
    /// turns that into an absolute position rather than an accumulating drift —
    /// pinch out, pinch back in the same amount, and you are exactly where you
    /// began instead of somewhere nearby.
    private var zoomAnchor: Float = 0

    func beginZoom() {
        zoomAnchor = zoomPushTarget
    }

    /// `scale` is the pinch's own factor: 1 at the start, >1 spread apart.
    ///
    /// Spreading fingers apart means "make it bigger", i.e. zoom **in**, i.e.
    /// less pullback — hence the minus. Logarithmic because `zoomPush` is in
    /// octaves, which is what makes a pinch feel the same whether it starts
    /// from close in or far out.
    func updateZoom(scale: CGFloat) {
        let octaves = -log2(Float(max(scale, 0.01))) / Colony.zoomPerPinch
        zoomPushTarget = min(max(zoomAnchor + octaves, Colony.zoomIn), Colony.zoomOut)
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
