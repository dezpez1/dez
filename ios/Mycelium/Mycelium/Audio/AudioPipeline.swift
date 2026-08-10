//
//  AudioPipeline.swift
//  One microphone, two customers.
//
//  The analyser wants the room (so the field can move with the music); the
//  recorder wants the voice (so a held circle captures a realization). They
//  share one AVAudioEngine and one input tap, because two taps on one input is
//  not a thing and two engines fighting over a session is a worse one.
//
//  The session is configured ONCE, at session entry, and never reconfigured
//  while a session runs. Reconfiguring an active audio session is the classic
//  way to stall CHHapticEngine — and grounding haptics firing during a capture
//  is not an edge case here, it is the design working as intended.
//
//  Category choices, each load-bearing:
//
//    .playAndRecord + .mixWithOthers — a plain .record category PAUSES other
//        apps' audio. The music this feature exists to hear is usually playing
//        from this same phone. Non-negotiable.
//    .allowBluetoothA2DP — without it, activating a record-capable session
//        drags a Bluetooth speaker down to the HFP phone-call codec and the
//        music turns to mud. With it, output stays A2DP and input stays the
//        built-in mic, which is exactly the split we want.
//    No voice processing — echo cancellation exists to remove what the phone
//        itself is playing, which here would mean suppressing the music the
//        analyser is trying to hear.
//
//  Everything degrades silently, in the Haptics tradition: a session with no
//  mic permission, or an engine that refuses to start, is a session where the
//  field simply doesn't react and the capture circle isn't shown. Nothing
//  mid-trip ever surfaces an error.
//

import AVFAudio
import Foundation
import QuartzCore
import simd

@MainActor
final class AudioPipeline {
    static let shared = AudioPipeline()

    enum Permission {
        case undetermined, granted, denied
    }

    private(set) var permission: Permission = .undetermined

    let recorder = CaptureRecorder()

    private let engine = AVAudioEngine()
    private var analyser: AudioAnalyser?
    private var publishTimer: Timer?
    private weak var state: FieldState?
    private var log: SessionLog?
    private var running = false
    private var lastLogSample: CFTimeInterval = 0
    private var observers: [NSObjectProtocol] = []

    private init() {
        refreshPermission()
    }

    // ── Permission ─────────────────────────────────────────────────────────

    /// Called from the HOME screen, and only from there. A system permission
    /// alert is a modal, text-heavy jolt — exactly the thing the trip UX rules
    /// exist to keep out of a session. Asked sober, once; re-checked on each
    /// home appearance in case Settings changed underneath us.
    func requestPermissionIfNeeded() {
        refreshPermission()
        guard permission == .undetermined else { return }
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                self.permission = granted ? .granted : .denied
            }
        }
    }

    private func refreshPermission() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: permission = .granted
        case .denied: permission = .denied
        default: permission = .undetermined
        }
    }

    // ── Session lifecycle ──────────────────────────────────────────────────

    /// Start listening, feeding `state.audioLevel` and (throttled) the log.
    /// Safe to call without permission — it just does nothing, and the session
    /// runs exactly as it did before this feature existed.
    func beginSession(feeding state: FieldState, log: SessionLog?) {
        guard permission == .granted, !running else { return }
        self.state = state
        self.log = log

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .allowBluetoothA2DP])
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0,
                  let analyser = AudioAnalyser(format: format) else { return }
            self.analyser = analyser

            recorder.prepare(format: format)
            if let log { recorder.arm(directory: log.directory) }

            // One tap, two customers. The block runs on an audio-adjacent
            // thread — both callees are written for that, and nothing here
            // touches main-actor state.
            let recorder = self.recorder
            input.installTap(onBus: 0, bufferSize: 1024, format: format) {
                buffer, _ in
                analyser.process(buffer)
                recorder.write(buffer)
            }

            engine.prepare()
            try engine.start()
            running = true
            observeInterruptions()
            startPublishing()
        } catch {
            // Degrade silently — the field just doesn't react. The print is
            // for a developer with a cable, not a user with a phone.
            #if DEBUG
            print("AudioPipeline: begin failed — \(error)")
            #endif
            teardownEngine()
        }
    }

    /// Stop listening and give the hardware back. The mic indicator turning
    /// off at the home screen is part of the point: the app listens during a
    /// session and provably not outside one.
    func endSession() {
        guard running else { return }
        endCapture()
        teardownEngine()
        state?.audioLevel = .zero
        state = nil
        log = nil
    }

    // ── Capture ────────────────────────────────────────────────────────────
    // The touch layer's whole interface to recording: the circle went down,
    // the circle came up. Everything else — file, log, glyph state — is
    // consequence, and it lives here because this is where the state and the
    // log already are.

    /// Whether the circle should exist at all this session.
    var captureAvailable: Bool { running }

    func beginCapture() {
        guard running, let state else { return }
        guard let name = recorder.start(elapsed: state.elapsed) else { return }
        state.setCapturing(true)
        log?.captureStart(t: state.elapsed, file: name)
    }

    /// Finalize and keep. Every path out of a recording ends here — a lifted
    /// finger, a three-finger exit, an interruption, the session ending — and
    /// none of them lose audio. The only discard is the recorder's own
    /// graze rule, and the log records even that.
    func endCapture() {
        guard let state else { return }
        state.setCapturing(false)
        switch recorder.stop() {
        case .kept(let file, let seconds):
            log?.captureEnd(t: state.elapsed, file: file, seconds: seconds)
        case .discarded:
            log?.captureDiscard(t: state.elapsed)
        case .idle:
            break
        }
    }

    private func teardownEngine() {
        publishTimer?.invalidate()
        publishTimer = nil
        // By token, not by `removeObserver(self)`. These are registered with
        // the block-based API, which does not make `self` the observer — the
        // self-based removal is a silent no-op, and every session after the
        // first would run its interruption handler one extra time.
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if running || engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        analyser = nil
        running = false
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    // ── Publishing ─────────────────────────────────────────────────────────

    /// The hop from the audio thread to the main actor. 30Hz is comfortably
    /// above anything the envelopes can do (the fastest attack is 50ms) and
    /// cheap enough to not think about. `.common` mode for the same reason the
    /// grounding haptics use it: a finger resting on the glass puts the run
    /// loop in tracking mode, and the field must keep hearing through that.
    private func startPublishing() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
            Task { @MainActor in self.publish() }
        }
        RunLoop.main.add(timer, forMode: .common)
        publishTimer = timer
    }

    private func publish() {
        guard let analyser, let state else { return }
        let level = analyser.smoothed
        state.audioLevel = level

        // ~10Hz to the log — enough to re-integrate audioDriftTime on replay,
        // small enough to never think about.
        let now = CACurrentMediaTime()
        if now - lastLogSample >= 0.1 {
            lastLogSample = now
            log?.audioSample(t: state.elapsed, level: level)
        }
    }

    // ── Interruptions ──────────────────────────────────────────────────────

    /// Phone calls, Siri, another app claiming the mic. The rule for capture
    /// is the same everywhere: nothing ever discards a recording. An
    /// interruption finalizes and keeps whatever was said before it.
    private func observeInterruptions() {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey]
                        as? UInt).flatMap {
                AVAudioSession.InterruptionType(rawValue: $0)
            }
            Task { @MainActor in self?.handleInterruption(type) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
            // Route changed under us — headphones out, speaker in. The engine
            // stops itself; restart it against the new hardware.
            Task { @MainActor in self?.restartAfterConfigurationChange() }
        })
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?) {
        switch type {
        case .began:
            endCapture()
            state?.audioLevel = .zero
        case .ended:
            restartAfterConfigurationChange()
        default:
            break
        }
    }

    private func restartAfterConfigurationChange() {
        guard running else { return }
        if !engine.isRunning {
            try? AVAudioSession.sharedInstance().setActive(true)
            engine.prepare()
            try? engine.start()
        }
    }
}
