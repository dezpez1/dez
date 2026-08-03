//
//  FieldView.swift
//  The Field screen itself. Chromeless by design — during a session there is
//  nothing on screen but the field.
//
//  Gestures follow the trip-UX rules: nothing requires precision, nothing
//  requires reading, and the grounding affordance is reachable from anywhere
//  on screen without navigating.
//
//    1 finger   tap or drag  → bloom
//    2 fingers  press + hold → Ground Me (engages after a short delay so a
//                              stray two-finger touch can't flip it)
//    3 fingers  tap          → leave the session (deliberate, hard to hit
//                              by accident, but not buried in a menu)
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

    /// Blooms while dragging are rate-limited — an unthrottled drag would
    /// blow through the 32-bloom budget in well under a second.
    private static let bloomInterval: CFTimeInterval = 0.06

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

    private func addBloom(at p: CGPoint, strength: Float) {
        let now = CACurrentMediaTime()
        guard now - lastBloomAt >= Self.bloomInterval else { return }
        lastBloomAt = now
        let (x, y) = fieldPoint(p)
        state?.addBloom(x: x, y: y, strength: strength)
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
            Haptics.shared.stopGroundingPulse()
            onExit?()
            return
        }

        updateGrounding(activeTouches: active)

        if active == 1, let t = touches.first {
            addBloom(at: t.location(in: self), strength: 1.0)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let active = event?.allTouches?.filter {
            $0.phase != .ended && $0.phase != .cancelled
        }.count ?? touches.count
        guard active == 1, let t = touches.first else { return }
        // Softer than a tap so dragging paints rather than punches.
        addBloom(at: t.location(in: self), strength: 0.65)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let remaining = event?.allTouches?.filter {
            $0.phase != .ended && $0.phase != .cancelled
        }.count ?? 0
        updateGrounding(activeTouches: remaining)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        updateGrounding(activeTouches: 0)
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
