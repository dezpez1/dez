//
//  Haptics.swift
//  The felt half of Ground Me.
//
//  While grounding is engaged, a soft pulse marks each half of the resonant
//  breath cycle — one at the top of the inhale, one at the top of the exhale.
//  Something to breathe *with* when reading is out of the question.
//
//  Everything degrades silently: no haptic hardware (simulator, iPad) means
//  the visual grounding still works exactly the same.
//

import CoreHaptics
import UIKit

final class Haptics {
    static let shared = Haptics()

    private var engine: CHHapticEngine?
    private var timer: Timer?
    private var onInhale = true

    private init() {}

    private func ensureEngine() {
        guard engine == nil,
              CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let e = try CHHapticEngine()
            // The system stops the engine on interruption; restart rather than
            // going silent for the rest of the session.
            e.stoppedHandler = { _ in }
            e.resetHandler = { [weak self] in
                try? self?.engine?.start()
            }
            try e.start()
            engine = e
        } catch {
            engine = nil   // no haptics — visual grounding carries it
        }
    }

    func startGroundingPulse() {
        guard timer == nil else { return }
        ensureEngine()
        onInhale = true
        pulse()

        let half = Double(Breath.groundedCycleSeconds) / 2
        let t = Timer(timeInterval: half, repeats: true) { [weak self] _ in
            self?.pulse()
        }
        // .common so the pulse keeps time while a finger is down and the
        // run loop is in tracking mode.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopGroundingPulse() {
        timer?.invalidate()
        timer = nil
    }

    private func pulse() {
        defer { onInhale.toggle() }
        guard let engine else { return }

        // Inhale reads slightly brighter than exhale so the two halves are
        // distinguishable by feel alone.
        let intensity: Float = onInhale ? 0.45 : 0.28
        let sharpness: Float = 0.15   // soft and round, never a click

        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0)

        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Ignore — a dropped pulse is not worth interrupting a session for.
        }
    }
}
