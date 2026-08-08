//
//  FieldLabApp.swift
//  Entry point. One binary, two jobs: a window, or a PNG.
//

import AppKit
import SwiftUI

/// The capture check has to happen before `NSApplication` starts, or a headless
/// render would still bounce a window into the dock on its way to writing a
/// file. Which means `@main` goes here rather than on the App, since an App's
/// synthesised main() runs the event loop unconditionally.
@main
enum Main {
    static func main() {
        MainActor.assumeIsolated {
            if let job = CaptureJob(CommandLine.arguments) {
                CaptureRunner.run(job)      // never returns
            }
        }
        FieldLabApp.main()
    }
}

struct FieldLabApp: App {

    @NSApplicationDelegateAdaptor(LabAppDelegate.self) private var delegate
    @State private var engine = LabEngine(metalURL: FieldLabApp.metalURL())

    var body: some Scene {
        WindowGroup("Field Lab") {
            LabRootView(engine: engine)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 860)
    }

    /// Where Field.metal is. `run.sh` sets FIELD_METAL to an absolute path; the
    /// argument and the relative fallback are there so the binary can be run by
    /// hand, and pointed at a copy, without editing anything.
    static func metalURL() -> URL {
        if let env = ProcessInfo.processInfo.environment["FIELD_METAL"] {
            return URL(fileURLWithPath: env)
        }
        let args = CommandLine.arguments
        if args.count > 1, !args[1].hasPrefix("--") {
            return URL(fileURLWithPath: args[1])
        }
        return URL(fileURLWithPath: "ios/Mycelium/Mycelium/Field/Field.metal",
                   relativeTo: URL(fileURLWithPath:
                        FileManager.default.currentDirectoryPath))
    }
}

/// A bare executable launches as an accessory: no dock icon, no menu bar, and —
/// the part that actually matters — no key window, so the field renders and then
/// ignores every click. Promoting it to a regular app at launch is what makes it
/// behave like something you can use.
final class LabAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        true
    }
}
