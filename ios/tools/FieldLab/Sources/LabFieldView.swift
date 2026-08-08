//
//  LabFieldView.swift
//  The MTKView, and a mouse standing in for a finger.
//
//  The gesture set is the phone's, mapped as closely as one pointer allows.
//  FieldView.swift is the reference — a tap and a rest are the same gesture told
//  apart by what happens after it lands, so the click has to do both here too or
//  the timing of the hold can't be judged.
//
//    click              → one pulse, everywhere at once
//    click and rest     → the field glows and dims for as long as the button
//                         is down and the pointer stays put
//    click and drag     → cancels the hold, emits nothing (as on the phone)
//    right-click, hold  → Ground Me. Two fingers has no pointer equivalent, and
//                         a modifier key would collide with the editor.
//    scroll / pinch     → zoom. A trackpad pinch arrives here as a magnify
//                         event and is the same gesture as the phone's; a mouse
//                         wheel is the fallback for people without one.
//
//  Zoom is here because it could not be judged anywhere else. The phone's is a
//  two-finger pinch, and this window had no way to reach it at all — which meant
//  the only way to look at the mycelial camera was to build, install and run on
//  a simulator, for a control that takes one second to evaluate.
//
//  Coordinates need no flip: an unflipped AppKit view already has its origin at
//  the bottom-left with y going up, which is the shader's convention. UIKit is
//  the one that's upside down.
//

import MetalKit
import SwiftUI

final class LabMetalView: MTKView {

    var state: FieldState?

    private var holdWork: DispatchWorkItem?
    private var groundWork: DispatchWorkItem?
    private var holdOrigin: CGPoint?
    private var lastBloomAt: CFTimeInterval = 0

    // Same numbers as MetalFieldView. The whole value of judging a hold here is
    // that it is judged the same way.
    private static let holdDelay: TimeInterval = 0.40
    private static let holdSlop: CGFloat = 24
    private static let groundDelay: TimeInterval = 0.35
    private static let tapInterval: CFTimeInterval = 0.22

    override var acceptsFirstResponder: Bool { true }

    /// Without this, the click that focuses the window is swallowed and the
    /// first tap after every alt-tab does nothing.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func fieldPoint(_ p: CGPoint) -> (Float, Float) {
        let w = max(bounds.width, 1)
        let h = max(bounds.height, 1)
        let aspect = Float(w / h)
        return ((Float(p.x / w) - 0.5) * aspect, Float(p.y / h) - 0.5)
    }

    private func addTap(at p: CGPoint) {
        let now = CACurrentMediaTime()
        guard now - lastBloomAt >= Self.tapInterval else { return }
        lastBloomAt = now
        let (x, y) = fieldPoint(p)
        state?.addBloom(x: x, y: y, strength: 1.0)
    }

    private func cancelHold() {
        holdWork?.cancel()
        holdWork = nil
        holdOrigin = nil
        state?.setHolding(false)
    }

    // MARK: - Zoom

    /// A trackpad pinch. `magnification` is a delta per event rather than a
    /// cumulative scale, so this accumulates it and feeds the same
    /// begin/update pair the phone's pinch uses — one code path, so what is
    /// judged here is what ships.
    private var magnifyScale: CGFloat = 1

    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            magnifyScale = 1
            state?.beginZoom()
        case .changed:
            magnifyScale *= (1 + event.magnification)
            state?.updateZoom(scale: magnifyScale)
        default:
            break
        }
    }

    /// And the wheel, for anyone driving this with a mouse. Each notch is a
    /// fixed step rather than proportional to `scrollingDeltaY`, because a
    /// momentum-scrolling trackpad delivers dozens of events per flick and
    /// proportional handling sends the field to the clamp in one gesture.
    override func scrollWheel(with event: NSEvent) {
        guard event.phase == [] || event.phase == .changed else { return }
        let notch: CGFloat = event.scrollingDeltaY > 0 ? 1.08 : 1 / 1.08
        state?.beginZoom()
        state?.updateZoom(scale: notch)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        addTap(at: p)

        cancelHold()
        holdOrigin = p
        let work = DispatchWorkItem { [weak self] in self?.state?.setHolding(true) }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: work)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = holdOrigin else { return }
        let p = convert(event.locationInWindow, from: nil)
        if hypot(p.x - origin.x, p.y - origin.y) > Self.holdSlop { cancelHold() }
    }

    override func mouseUp(with event: NSEvent) { cancelHold() }

    override func rightMouseDown(with event: NSEvent) {
        guard groundWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.state?.setGrounding(true) }
        groundWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.groundDelay, execute: work)
    }

    override func rightMouseUp(with event: NSEvent) {
        groundWork?.cancel()
        groundWork = nil
        state?.setGrounding(false)
    }
}

struct LabFieldViewRepresentable: NSViewRepresentable {
    let engine: LabEngine

    func makeNSView(context: Context) -> LabMetalView {
        let view = LabMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.state = engine.state
        engine.attach(view: view)
        return view
    }

    func updateNSView(_ view: LabMetalView, context: Context) {
        view.state = engine.state
    }
}
