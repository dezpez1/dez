//
//  ShaderWatcher.swift
//  Notices when Field.metal changes on disk.
//
//  Polls `stat` rather than watching a file descriptor, and that is on purpose.
//  Every editor worth using saves atomically — write a temporary file, then
//  rename it over the target — so the inode you opened is not the inode that
//  ends up at the path. A DispatchSource on an fd survives exactly one save and
//  then watches a deleted file forever, silently. Polling a path has no such
//  failure mode and costs one stat every fifth of a second.
//
//  Size is compared alongside mtime because HFS+ and some network filesystems
//  quantise mtime to a whole second, and a fast edit-save-edit-save can land two
//  writes inside one tick.
//

import Foundation

@MainActor
final class ShaderWatcher {

    private let url: URL
    private let onChange: (String) -> Void
    private var timer: Timer?
    private var signature: (Date, Int)?

    /// Fast enough to feel immediate next to a Cmd-S, slow enough to be free.
    private static let interval: TimeInterval = 0.2

    init(url: URL, onChange: @escaping (String) -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        check(force: true)
        let t = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated { self.check(force: false) }
        }
        // Without this the timer stops during a window resize or a menu track,
        // which is exactly when you have just alt-tabbed back from the editor.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func check(force: Bool) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return }

        if !force, let s = signature, s.0 == date, s.1 == size { return }
        signature = (date, size)

        // A save can be observed between the truncate and the write, which reads
        // as a zero-byte file and would report a wall of bogus errors. Treat an
        // empty read as "not finished yet" and pick it up on the next tick by
        // leaving the signature to be re-noticed.
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            signature = nil
            return
        }
        onChange(text)
    }
}
