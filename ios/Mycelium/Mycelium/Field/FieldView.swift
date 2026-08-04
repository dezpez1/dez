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
//    2 fingers  press + hold → Ground Me (engages after a short delay so a
//                              stray two-finger touch can't flip it)
//    3 fingers  tap          → leave the session (deliberate, hard to hit
//                              by accident, but not buried in a menu)
//
//  Tap and rest are the same gesture told apart by what happens after it
//  lands, so there is nothing to learn — and since neither one cares where it
//  lands, there is nothing to aim at either.
//

import SwiftUI
import MetalKit

// MARK: - Touch-handling MTKView

final class MetalFieldView: MTKView {

    var state: FieldState?
    var onExit: (() -> Void)?

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
            guard groundingWorkItem == nil else { return }
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
            Haptics.shared.stopGroundingPulse()
            onExit?()
            return
        }

        updateGrounding(activeTouches: active)

        if active == 1, let t = touches.first {
            let p = t.location(in: self)
            // The pulse lands on contact. Waiting for the gesture to be
            // classified first would make every tap feel late.
            addTap(at: p, strength: 1.0)
            armHold(at: p)
        } else {
            // A second finger means grounding, not holding.
            cancelHold()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = event?.allTouches?.filter {
            $0.phase != .ended && $0.phase != .cancelled
        }.count ?? touches.count
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
        let remaining = event?.allTouches?.filter {
            $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 0
        updateGrounding(activeTouches: remaining)
        if remaining == 0 { cancelHold() }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateGrounding(activeTouches: 0)
        cancelHold()
    }
}

// MARK: - SwiftUI bridge

struct FieldViewRepresentable: UIViewRepresentable {
    let state: FieldState
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: FieldRenderer?
    }

    func makeUIView(context: Context) -> MetalFieldView {
        let view = MetalFieldView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.state = state
        view.onExit = onExit
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
    }
}

// MARK: - The session screen

struct FieldScreen: View {
    let state: FieldState
    let onExit: () -> Void

    var body: some View {
        FieldViewRepresentable(state: state, onExit: onExit)
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
