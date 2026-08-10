//
//  CaptureRecorder.swift
//  The held circle's other half: buffers in, an m4a out.
//
//  Written to from the same input tap the analyser reads — the recorder is a
//  second customer of one microphone, not a second microphone. `write` is a
//  no-op unless armed and started, so the tap costs nothing while nobody is
//  holding the circle.
//
//  Format: AAC mono at 64kbps (~0.5MB/min against ~11MB/min for raw float),
//  with a CAF fallback if the AAC writer refuses the hardware format — a
//  fallback chosen because it cannot fail, not because it is good. Files land
//  in the session's own directory in the app container. They never touch the
//  repo; the repo is public and these are voice memos from a trip.
//
//  Nothing here ever discards a recording except the accidental-graze rule:
//  under half a second means a brushed circle, not a thought, and keeping it
//  would fill the morning view with half-breaths.
//

import AVFAudio
import Foundation
import os

final class CaptureRecorder {

    enum Outcome {
        case kept(file: String, seconds: Float)
        case discarded
        case idle
    }

    private struct Active {
        let file: AVAudioFile
        let name: String
        var frames: AVAudioFramePosition = 0
        var converter: AVAudioConverter?
    }

    /// The lock serialises the tap thread's `write` against main-actor
    /// start/stop. Held only for the duration of one buffer append.
    private let lock = OSAllocatedUnfairLock<Active?>(initialState: nil)

    private var directory: URL?
    private var tapFormat: AVAudioFormat?
    private var count = 0

    private static let minimumSeconds: Float = 0.5

    /// Session start: where files go (the SessionLog's directory) and what the
    /// hardware is handing us.
    func arm(directory: URL) {
        self.directory = directory
        count = 0
    }

    func prepare(format: AVAudioFormat) {
        tapFormat = format
    }

    /// Open a file and start accepting buffers. Returns the filename for the
    /// log, or nil if the recorder isn't armed (no session directory, no mic).
    func start(elapsed: Float) -> String? {
        guard let directory, let tapFormat else { return nil }
        guard lock.withLock({ $0 == nil }) else { return nil }

        count += 1
        let base = String(format: "note-%03d-t%04d", count, Int(elapsed))

        // AAC first; CAF only if the encoder refuses. The settings ask for
        // mono regardless of the tap — the converter below bridges.
        let aac: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: tapFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        var name = base + ".m4a"
        var file: AVAudioFile?
        do {
            file = try AVAudioFile(forWriting: directory.appendingPathComponent(name),
                                   settings: aac)
        } catch {
            name = base + ".caf"
            file = try? AVAudioFile(forWriting: directory.appendingPathComponent(name),
                                    settings: tapFormat.settings)
        }
        guard let file else { return nil }

        // The tap format and the file's processing format usually agree on an
        // iPhone (mono float32 at the hardware rate). When they don't — a
        // stereo accessory mic, say — convert rather than refuse.
        var converter: AVAudioConverter?
        if tapFormat != file.processingFormat {
            converter = AVAudioConverter(from: tapFormat, to: file.processingFormat)
        }

        lock.withLock { $0 = Active(file: file, name: name, converter: converter) }
        return name
    }

    /// Called from the tap thread for every buffer, recording or not.
    func write(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { active in
            guard var a = active else { return }
            do {
                if let conv = a.converter {
                    // The converter path allocates its output buffer, which is
                    // against audio-thread manners — accepted because chunks
                    // arrive ~10 times a second, not per sample, and only on
                    // hardware where the formats disagree at all.
                    let ratio = a.file.processingFormat.sampleRate
                              / buffer.format.sampleRate
                    let cap = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                    guard let out = AVAudioPCMBuffer(pcmFormat: a.file.processingFormat,
                                                     frameCapacity: cap) else { return }
                    var handed = false
                    _ = conv.convert(to: out, error: nil) { _, status in
                        if handed { status.pointee = .noDataNow; return nil }
                        handed = true
                        status.pointee = .haveData
                        return buffer
                    }
                    try a.file.write(from: out)
                    a.frames += AVAudioFramePosition(out.frameLength)
                } else {
                    try a.file.write(from: buffer)
                    a.frames += AVAudioFramePosition(buffer.frameLength)
                }
                active = a
            } catch {
                // Drop the chunk. A torn chunk in a voice note beats anything
                // that could interrupt the session to report it.
            }
        }
    }

    /// Close the file and rule on it. `.discarded` is the graze rule and
    /// nothing else — every other path through this type keeps the audio.
    func stop() -> Outcome {
        let active = lock.withLock { st -> Active? in
            let a = st
            st = nil
            return a
        }
        guard let active else { return .idle }

        let seconds = Float(active.frames)
                    / Float(active.file.processingFormat.sampleRate)
        if seconds < Self.minimumSeconds {
            // Dropping the reference finalises the file; unlink after.
            let url = active.file.url
            try? FileManager.default.removeItem(at: url)
            return .discarded
        }
        return .kept(file: active.name, seconds: seconds)
    }
}
