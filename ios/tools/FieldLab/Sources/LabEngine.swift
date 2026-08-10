//
//  LabEngine.swift
//  What the window is looking at: one FieldState, one renderer, one watcher.
//

import Foundation
import MetalKit
import simd

/// Where a slider can go. Ranges are editable because the constants this tool
/// exists to sweep are not all 0…1 — TUNNEL_SPEED is 0.62, TUNNEL_CORE_TIGHT is
/// 420, and a fixed unit slider would be useless for half of them.
struct LabSlider: Identifiable {
    let id: Int
    var lo: Float
    var hi: Float
    var value: Float

    var channel: String { ["x", "y", "z", "w"][id] }
}

/// What the window's synthetic room is doing: sitting at the slider levels, or
/// running one of the capture path's waveforms.
enum AudioWaveKind: String, CaseIterable {
    case off, sine, pulse
}

@MainActor
@Observable
final class LabSettings {
    var timeScale: Float = 1.0
    var paused = false

    var sliders: [LabSlider] = (0..<4).map {
        LabSlider(id: $0, lo: 0, hi: 1, value: 0)
    }

    var lab: SIMD4<Float> {
        SIMD4(sliders[0].value, sliders[1].value,
              sliders[2].value, sliders[3].value)
    }

    /// The synthetic room. Levels feed the field when the wave is off; a wave
    /// overrides them. Either way the renderer pushes it through AudioEnvelope
    /// before it reaches `state.audioLevel`, so the window, a capture and the
    /// phone all agree on what "smoothed" means.
    var audioWaveKind: AudioWaveKind = .off
    var audioHz: Float = 0.5
    var audioLevels: [Float] = [0, 0, 0, 0]

    var audioWave: AudioWave {
        switch audioWaveKind {
        case .off:   return .constant(SIMD4(audioLevels[0], audioLevels[1],
                                            audioLevels[2], audioLevels[3]))
        case .sine:  return .sine(hz: audioHz)
        case .pulse: return .pulse(hz: audioHz)
        }
    }

    /// 0 means "whatever shape the window is". Anything else is height ÷ width,
    /// which is worth having because framing is aspect-dependent — the tunnel's
    /// vanishing point sits at a different fraction of the screen on a 19.5:9
    /// phone than in a square window, and tuning it wide and shipping it tall
    /// is a mistake you only find on the device.
    var aspect: CGFloat = 19.5 / 9.0

    var compiling = false
    var compiles = 0
    var lastCompileMS: Double = 0
    var error: String?
    var fps: Double = 0
}

@MainActor
@Observable
final class LabEngine {

    /// Pinned, so two runs of run.sh are comparable with each other and with a
    /// capture. The app randomises it per session — that is right for a session
    /// and wrong for a workbench.
    let state = FieldState(seed: 42)
    let settings = LabSettings()
    let metalURL: URL

    @ObservationIgnored private var renderer: LabRenderer?
    @ObservationIgnored private var watcher: ShaderWatcher?

    init(metalURL: URL) {
        self.metalURL = metalURL
    }

    /// Called once, when the MTKView exists. The renderer needs a view to
    /// configure, and the watcher must not start firing at a renderer that
    /// isn't there yet.
    func attach(view: MTKView) {
        guard renderer == nil else { return }
        guard let device = MTLCreateSystemDefaultDevice(),
              let r = try? LabRenderer(device: device, colorFormat: .bgra8Unorm,
                                       state: state, settings: settings) else {
            settings.error = "No Metal device."
            return
        }
        renderer = r
        r.configure(view: view)

        let w = ShaderWatcher(url: metalURL) { [weak self] source in
            self?.renderer?.load(source: source)
        }
        w.start()
        watcher = w
    }

    /// Wipe the feedback buffers. The field blends ~60% of the previous frame,
    /// so a change to how something *starts* can stay hidden behind twenty
    /// seconds of ghost from before the edit — this is how you see the first
    /// frame of the shader you just wrote rather than a dissolve into it.
    func restart() {
        state.reset()
        renderer?.clearAccumulation()
    }

    /// Several taps in a row, at the same spacing the app throttles them to.
    /// A single tap tells you almost nothing about the bloom envelope; what
    /// matters is whether four of them sum into a swell or stack into a flash,
    /// and that is a safety property, not a taste one.
    func burst() {
        for i in 0..<4 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.22) {
                self.state.addBloom(x: 0, y: 0, strength: 1.0)
            }
        }
    }
}
