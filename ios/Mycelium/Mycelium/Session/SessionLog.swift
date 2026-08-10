//
//  SessionLog.swift
//  The permanent record of a session: what happened, when, to be replayed.
//
//  The field is a pure function of (time, seed, bloom log) — and now of the
//  audio envelope, which is why the envelope is in here too: without it a
//  replay cannot re-integrate `audioDriftTime`, and the morning view would
//  play the session back with the music's effect missing.
//
//  Three files per session, in the app container (never the repo — public):
//
//    Documents/sessions/20260809-213045-s42.7/
//      session.json     the header: wall clock, seed, form, palette
//      events.jsonl     blooms, captures, grounding, the end — one per line
//      audio.jsonl      the smoothed envelope at ~10Hz
//      note-001-t0083.m4a …the recordings themselves
//
//  JSONL appended through FileHandle rather than a rewritten document, because
//  append-only is crash-honest: a session that dies at minute forty keeps
//  forty minutes. Timestamps are `FieldState.elapsed` seconds — the same clock
//  blooms are born on — and the ONLY wall-clock date in the whole app is the
//  `startedAt` in the header. The field itself never learns what day it is.
//
//  Known gap, deliberate: pinch/zoom events are not logged, so a mycelial
//  replay's growth cap can drift from the session it replays. Scoped out with
//  the morning view; the header records enough to notice.
//

import Foundation
import simd

@MainActor
final class SessionLog {

    let directory: URL

    private var events: FileHandle?
    private var audio: FileHandle?
    private var ended = false

    init?(seed: Float, form: Form, paletteIndex: Int) {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }

        let stamp = Self.stampFormatter.string(from: Date())
        let name = String(format: "%@-s%.1f", stamp, seed)
        directory = docs.appendingPathComponent("sessions", isDirectory: true)
                        .appendingPathComponent(name, isDirectory: true)

        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)

            let header: [String: Any] = [
                "version": 1,
                "startedAt": Self.isoFormatter.string(from: Date()),
                "seed": Double(seed),
                "form": form.title.lowercased(),
                "paletteIndex": paletteIndex,
            ]
            let headerData = try JSONSerialization.data(
                withJSONObject: header, options: [.sortedKeys])
            try headerData.write(to: directory.appendingPathComponent("session.json"))

            events = Self.appendHandle(at: directory.appendingPathComponent("events.jsonl"))
            audio = Self.appendHandle(at: directory.appendingPathComponent("audio.jsonl"))
        } catch {
            return nil
        }
    }

    // ── Events ─────────────────────────────────────────────────────────────

    func bloom(_ b: Bloom) {
        append(String(format:
            #"{"type":"bloom","t":%.3f,"x":%.4f,"y":%.4f,"strength":%.2f}"#,
            b.birth, b.x, b.y, b.strength))
    }

    func captureStart(t: Float, file: String) {
        append(String(format:
            #"{"type":"captureStart","t":%.3f,"file":"%@"}"#, t, file))
    }

    func captureEnd(t: Float, file: String, seconds: Float) {
        append(String(format:
            #"{"type":"captureEnd","t":%.3f,"file":"%@","seconds":%.2f}"#,
            t, file, seconds))
    }

    /// The graze rule fired and the file is gone. Logged rather than silently
    /// un-happened — an append-only log records what occurred, including the
    /// starts that came to nothing.
    func captureDiscard(t: Float) {
        append(String(format: #"{"type":"captureDiscard","t":%.3f}"#, t))
    }

    func grounding(t: Float, on: Bool) {
        append(String(format:
            #"{"type":"ground","t":%.3f,"on":%@}"#, t, on ? "true" : "false"))
    }

    func end(t: Float) {
        guard !ended else { return }
        ended = true
        append(String(format: #"{"type":"end","t":%.3f}"#, t))
        try? events?.close()
        try? audio?.close()
        events = nil
        audio = nil
    }

    /// The envelope, for replay. The pipeline throttles to ~10Hz before
    /// calling — roughly 2MB an hour, cheap enough to never think about.
    func audioSample(t: Float, level: SIMD4<Float>) {
        guard let audio else { return }
        let line = String(format:
            #"{"t":%.2f,"b":%.3f,"m":%.3f,"tr":%.3f,"o":%.3f}"#,
            t, level.x, level.y, level.z, level.w) + "\n"
        audio.write(Data(line.utf8))
    }

    // ── Plumbing ───────────────────────────────────────────────────────────

    private func append(_ line: String) {
        guard !ended, let events else { return }
        events.write(Data((line + "\n").utf8))
    }

    private static func appendHandle(at url: URL) -> FileHandle? {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? h.seekToEnd()
        return h
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let isoFormatter = ISO8601DateFormatter()
}
