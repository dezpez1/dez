//
//  FieldView.swift
//  The Field screen itself. Chromeless by design — during a session there is
//  nothing on screen but the field.
//
//  Gestures follow the trip-UX rules: nothing requires precision, nothing
//  requires reading, and the grounding affordance is reachable from anywhere
//  on screen without navigating.
//
//    1 finger   tap          → one pulse of shape and colour, everywhere at
//                              once — where you touch makes no difference
//    1 finger   press + rest → the field glows and dims in time, for as long
//                              as you stay put
//    1 finger   drag         → nothing; moving is only what cancels the hold
//    1 finger   hold the circle → a voice note records while you hold, stops
//                              when you lift. The circle is the ONE place on
//                              screen a touch means something different
//    2 fingers  press + hold → Ground Me (engages after a short delay so a
//                              stray two-finger touch can't flip it)
//    2 fingers  pinch        → zoom, both ways. Mycelial only; the other forms
//                              have no camera to move
//    3 fingers  tap          → leave the session (deliberate, hard to hit
//                              by accident, but not buried in a menu)
//
//  Tap and rest are the same gesture told apart by what happens after it
//  lands, so there is nothing to learn — and since neither one cares where it
//  lands, there is nothing to aim at either.
//
//  Ground Me and pinch are the same pair of fingers told apart the same way:
//  two that stay put ground, two that move apart or together zoom. Grounding is
//  the one that must never be missed, so it is the one that wins ties — the
//  pinch has to travel PINCH_SLOP before it is recognised at all, and once
//  grounding has engaged the pinch cannot take it away.
//
//  The capture circle is drawn by SwiftUI but hit-tested HERE, in the same
//  touch pipeline as everything else, and that is a load-bearing choice: an
//  overlay button would swallow its touches, and a swallowed touch is one the
//  grounding counter never saw. This way a capture press still counts toward
//  the two-finger and three-finger totals — grounding stays reachable and the
//  exit still works with a thumb resting on the circle.
//
//  Capture's own rules: no drag-to-cancel (a cancel gesture is a precision
//  gesture), and nothing ever discards a recording except a grazed circle
//  released inside half a second. A second finger landing during capture
//  grounds normally — the haptic pulse will be faintly audible in the note,
//  and that is accepted; grounding does not wait for anything.
//

import SwiftUI
import MetalKit

// MARK: - The capture circle's geometry

/// One definition, used by both the UIKit hit test and the SwiftUI glyph, so
/// the place you press and the place you see cannot drift apart.
///
/// The hit disc is bigger than the drawing — 110pt of target around 84pt of
/// glyph — because the hand aiming at it is not steady, and a miss that
/// blooms the field instead of recording a thought is the worse failure.
enum CaptureZone {
    static let hitRadius: CGFloat = 55
    static let glyphDiameter: CGFloat = 84
    /// Centre height above the bottom edge — clear of the home indicator,
    /// low enough to be where a resting thumb already is.
    static let bottomInset: CGFloat = 96

    static func center(in bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.midX, y: bounds.maxY - bottomInset)
    }

    static func contains(_ p: CGPoint, in bounds: CGRect) -> Bool {
        let c = center(in: bounds)
        return hypot(p.x - c.x, p.y - c.y) <= hitRadius
    }
}

// MARK: - Touch-handling MTKView

final class MetalFieldView: MTKView {

    var state: FieldState?
    var onExit: (() -> Void)?

    /// Capture: set by the representable. Disabled means the circle does not
    /// exist — no glyph, no zone, every touch is field.
    var captureEnabled = false
    var onCaptureStart: (() -> Void)?
    var onCaptureEnd: (() -> Void)?

    /// The one touch that is currently a recording, if any. Identity, not a
    /// count — a second finger joining does not end it, and only THIS touch
    /// lifting does.
    private var captureTouch: UITouch?

    private var groundingWorkItem: DispatchWorkItem?
    private static let groundingHoldDelay: TimeInterval = 0.35
    private var lastBloomAt: CFTimeInterval = 0

    private var holdWorkItem: DispatchWorkItem?
    private var holdOrigin: CGPoint?

    /// Long enough that a tap is unambiguously a tap, short enough that
    /// resting a finger doesn't feel like waiting for permission.
    private static let holdDelay: TimeInterval = 0.40

    /// How far a finger may wander and still count as resting. Generous —
    /// this gets used by people who are not steady, which is the point.
    private static let holdSlop: CGFloat = 24

    /// Minimum spacing between taps. A tap now brightens the whole screen, so
    /// this is a safety limit as much as a budget one: unthrottled taps are
    /// global luminance modulation at whatever rate a finger can manage, and
    /// that belongs nowhere near the photosensitivity band. At 0.22s the
    /// envelopes overlap heavily and sum to a smooth swell rather than flicker.
    private static let tapInterval: CFTimeInterval = 0.22

    /// Pinch-to-zoom, sharing its two fingers with Ground Me.
    ///
    /// `pinchRef` is the span the pinch is measured against — set at the moment
    /// the gesture is *recognised*, not at the moment the second finger landed,
    /// so the zoom starts from zero instead of jumping by the slop it just spent
    /// proving itself.
    private var pinchSpan: CGFloat?      // span when the second finger landed
    private var pinchRef: CGFloat?       // …and once recognised, from here
    private var isZooming = false

    /// How far the fingers must travel, as a fraction of their spacing, before
    /// this counts as a pinch rather than a rest. Generous, because the fingers
    /// it has to tell apart belong to someone who is not steady, and calling a
    /// tremor a pinch would drift the zoom under a hand that meant to ground.
    private static let pinchSlop: CGFloat = 0.14

    /// The distance between the two active touches, or nil if there aren't two.
    private func span(_ event: UIEvent?) -> CGFloat? {
        let live = (event?.allTouches ?? []).filter {
            $0.phase != .ended && $0.phase != .cancelled
        }
        guard live.count == 2 else { return nil }
        let pts = live.map { $0.location(in: self) }
        return max(hypot(pts[0].x - pts[1].x, pts[0].y - pts[1].y), 1)
    }

    private func endPinch() {
        pinchSpan = nil
        pinchRef = nil
        isZooming = false
    }

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        super.init(frame: frameRect, device: device)
        isMultipleTouchEnabled = true
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        isMultipleTouchEnabled = true
    }

    /// UIKit point (origin top-left, y down) → shader field space
    /// (origin center, y up, x scaled by aspect).
    private func fieldPoint(_ p: CGPoint) -> (Float, Float) {
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let u = Float(p.x / w)
        let v = 1 - Float(p.y / h)          // flip to match Metal's y-up uv
        let aspect = Float(w / h)
        return ((u - 0.5) * aspect, v - 0.5)
    }

    /// Position is still recorded — the event log is what sync and replay are
    /// built on, and forms that use it are coming — but the shader currently
    /// answers the same way wherever the finger lands.
    private func addTap(at p: CGPoint, strength: Float) {
        let now = CACurrentMediaTime()
        guard now - lastBloomAt >= Self.tapInterval else { return }
        lastBloomAt = now
        let (x, y) = fieldPoint(p)
        state?.addBloom(x: x, y: y, strength: strength)
    }

    /// Arm the hold. Fires only if the finger is still down and still roughly
    /// where it started.
    private func armHold(at p: CGPoint) {
        cancelHold()
        holdOrigin = p
        let work = DispatchWorkItem { [weak self] in
            self?.state?.setHolding(true)
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }

    private func cancelHold() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        holdOrigin = nil
        state?.setHolding(false)
    }

    private func updateGrounding(activeTouches: Int) {
        if activeTouches >= 2 {
            // A recognised pinch is not a rest, so don't arm behind it.
            guard !isZooming, groundingWorkItem == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                self?.state?.setGrounding(true)
                Haptics.shared.startGroundingPulse()
            }
            groundingWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.groundingHoldDelay,
                                          execute: work)
        } else {
            groundingWorkItem?.cancel()
            groundingWorkItem = nil
            state?.setGrounding(false)
            Haptics.shared.stopGroundingPulse()
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = event?.allTouches?.filter {
            $0.phase != .ended && $0.phase != .cancelled
        }.count ?? touches.count

        if active >= 3 {
            groundingWorkItem?.cancel()
            groundingWorkItem = nil
            state?.setGrounding(false)
            cancelHold()
            endPinch()
            endCapture()   // finalize and KEEP — leaving mid-thought loses nothing
            Haptics.shared.stopGroundingPulse()
            onExit?()
            return
        }

        // Remember the spacing the moment the second finger lands, so a pinch
        // has something to be measured against if it turns out to be one.
        pinchSpan = active == 2 ? span(event) : nil
        if active != 2 { endPinch() }

        updateGrounding(activeTouches: active)

        if active == 1, let t = touches.first {
            let p = t.location(in: self)
            // The circle first: a press inside it is a recording, not a tap —
            // it must neither bloom nor arm the hold, or every voice note
            // would open with a flash and end with the field pulsing.
            if captureEnabled, CaptureZone.contains(p, in: bounds) {
                captureTouch = t
                onCaptureStart?()
                return
            }
            // The pulse lands on contact. Waiting for the gesture to be
            // classified first would make every tap feel late.
            addTap(at: p, strength: 1.0)
            armHold(at: p)
        } else {
            // A second finger means grounding, not holding.
            cancelHold()
        }
    }

    /// Finalize the recording if one is running. Keep is the only outcome —
    /// see the header. Called from every path a capture can end on.
    private func endCapture() {
        guard captureTouch != nil else { return }
        captureTouch = nil
        onCaptureEnd?()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = event?.allTouches?.filter {
            $0.phase != .ended && $0.phase != .cancelled
        }.count ?? touches.count

        // ── Two fingers: rest or pinch ─────────────────────────────────────
        if active == 2, let now = span(event), let start = pinchSpan {
            if isZooming, let ref = pinchRef {
                state?.updateZoom(scale: now / ref)
            } else if abs(now / start - 1) > Self.pinchSlop {
                // Recognised. Grounding is the gesture that must never be
                // missed, so once it has actually engaged it keeps the fingers
                // — a pinch can only claim them from a rest that is still only
                // pending.
                if state?.grounding ?? 0 > 0.001 { return }
                groundingWorkItem?.cancel()
                groundingWorkItem = nil
                state?.setGrounding(false)
                Haptics.shared.stopGroundingPulse()

                // Measured from here rather than from `start`, so the zoom
                // begins at zero instead of jumping by the slop it just spent.
                pinchRef = now
                isZooming = true
                state?.beginZoom()
            }
            return
        }

        guard active == 1, let t = touches.first else { cancelHold(); return }

        let p = t.location(in: self)

        // Wandering past the slop means this is a drag, not a rest. Drop the
        // hold, whether it was engaged or still only pending.
        if let origin = holdOrigin {
            if hypot(p.x - origin.x, p.y - origin.y) > Self.holdSlop {
                cancelHold()
            }
        }

        // Dragging no longer emits anything. It used to paint a trail of blooms,
        // which only meant something when a touch was a place on the screen —
        // now that a tap answers everywhere, a drag would just be a stream of
        // whole-screen flashes at whatever rate a finger moves. Moving is now
        // purely the signal that this isn't a hold.
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Identity check, not a count: only the capture finger lifting ends
        // the recording. The OTHER finger of a ground leaving must not.
        if let ct = captureTouch, touches.contains(ct) {
            endCapture()
        }

        let remaining = event?.allTouches?.filter {
            $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 0
        // A finger leaving ends the pinch outright rather than re-anchoring it
        // on whatever pair is left. Lifting one of three fingers should not
        // suddenly start zooming.
        if remaining < 2 { endPinch() }
        updateGrounding(activeTouches: remaining)
        if remaining == 0 { cancelHold() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endCapture()   // cancellation keeps the audio too — see the header
        endPinch()
        updateGrounding(activeTouches: 0)
        cancelHold()
    }
}

// MARK: - SwiftUI bridge

struct FieldViewRepresentable: UIViewRepresentable {
    let state: FieldState
    var captureEnabled = false
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: FieldRenderer?
    }

    func makeUIView(context: Context) -> MetalFieldView {
        let view = MetalFieldView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.state = state
        view.onExit = onExit
        view.captureEnabled = captureEnabled
        // The pipeline owns everything downstream of the gesture — file, log,
        // glyph state. The view only knows the circle went down and came up.
        view.onCaptureStart = { AudioPipeline.shared.beginCapture() }
        view.onCaptureEnd = { AudioPipeline.shared.endCapture() }
        view.backgroundColor = .black

        if let renderer = FieldRenderer(view: view, state: state) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        return view
    }

    func updateUIView(_ uiView: MetalFieldView, context: Context) {
        uiView.state = state
        uiView.onExit = onExit
        uiView.captureEnabled = captureEnabled
    }
}

// MARK: - The capture glyph

/// The visible half of the circle. Purely visual — `allowsHitTesting(false)`
/// at the call site, because the actual press is handled by MetalFieldView's
/// zone test (see the header for why that split is load-bearing).
///
/// Idle it is barely there: a hairline ring with a breath of fill, present
/// enough to find, dim enough to not compete with the field. Recording, it
/// brightens and swells on the hold-pulse rhythm — the same 2.2s the field
/// itself answers a resting finger with, so it reads as the field listening
/// rather than as an indicator light.
private struct CaptureGlyph: View {
    let state: FieldState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let recording = state.isCapturing
            let t = ctx.date.timeIntervalSinceReferenceDate
            let swell = recording
                ? 1.0 + 0.05 * sin(t * 2 * .pi / Double(Breath.holdPulseSeconds))
                : 1.0

            Circle()
                .strokeBorder(.white.opacity(recording ? 0.45 : 0.15),
                              lineWidth: 1)
                .background(
                    Circle().fill(RadialGradient(
                        colors: [.white.opacity(recording ? 0.20 : 0.05), .clear],
                        center: .center, startRadius: 0,
                        endRadius: CaptureZone.glyphDiameter / 2))
                )
                .frame(width: CaptureZone.glyphDiameter,
                       height: CaptureZone.glyphDiameter)
                .scaleEffect(swell)
                .animation(.easeInOut(duration: 0.4), value: recording)
        }
    }
}

// MARK: - The session screen

struct FieldScreen: View {
    let state: FieldState
    var captureEnabled = false
    let onExit: () -> Void

    var body: some View {
        ZStack {
            FieldViewRepresentable(state: state,
                                   captureEnabled: captureEnabled,
                                   onExit: onExit)
            if captureEnabled {
                // Positioned by the same CaptureZone the hit test uses. Both
                // views fill the screen edge to edge, so the coordinate
                // spaces agree by construction.
                GeometryReader { geo in
                    CaptureGlyph(state: state)
                        .position(CaptureZone.center(
                            in: CGRect(origin: .zero, size: geo.size)))
                }
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Haptics.shared.stopGroundingPulse()
        }
    }
}

#Preview("Field") {
    // Built inside a closure rather than as loose statements: the preview body
    // is a view builder, and a bare `state.addBloom(...)` there is an
    // expression of type () sitting where a View is expected.
    let state: FieldState = {
        let s = FieldState()
        // Palettes belong to the form now, so this is an index into
        // `form.palettes` rather than a global mood. 3 is Filament.
        s.form = .mycelial
        s.paletteIndex = 3
        // The shader ignores tap positions — a tap answers everywhere — but
        // they're still logged, so these are three taps of varying strength.
        s.addBloom(x: 0, y: 0, strength: 1.0)
        s.addBloom(x: -0.22, y: 0.34, strength: 0.85)
        s.addBloom(x: 0.24, y: -0.30, strength: 0.9)
        return s
    }()

    return FieldScreen(state: state) {}
        .preferredColorScheme(.dark)
}
