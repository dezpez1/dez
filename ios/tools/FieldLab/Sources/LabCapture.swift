//
//  LabCapture.swift
//  Render a fixed number of seconds offscreen and write a PNG.
//
//      run.sh --capture out.png --form tunnel --at 12
//
//  Two things this is for.
//
//  The first is that the field is a *feedback* system, so "what it looks like"
//  is a function of how long it has been running. Grabbing the window after an
//  unknown amount of time is not a measurement; asking for second twelve is. The
//  clock here is a fixed 1/60 per frame rather than wall time, so the same
//  command produces the same image — and the same seed — every time.
//
//  The second is that the useful question about this shader has repeatedly not
//  been "does it look nice" but "how much of the frame is actually black, and
//  how much is actually blown out". Those are histogram questions, the answers
//  have been consistently surprising, and you cannot get them by eye. Every
//  brightness fix in this project came from measuring a reference clip and
//  discovering ours had 0.0% of its pixels above white.
//
//  It shares `encodeFrame` with the live window rather than reimplementing the
//  pass chain, because a capture drawn by different code would be evidence
//  about the capture rather than about the app.
//

import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

/// A synthetic room. `--audio` drives `state.audioLevel` with one of these,
/// pushed through the same `AudioEnvelope` smoothing the phone's analyser
/// applies — a raw square wave is a thing no analyser ever emits, and a capture
/// measured against one would be evidence about nothing.
///
///     --audio const:0.7            bass 0.7, the rest 0
///     --audio const:1,1,1          all three bands held at full
///     --audio sine:0.5             every band swelling at 0.5Hz
///     --audio pulse:2              a 2Hz beat at 25% duty — the strobe check
///     --audio ramp:20              silence to full over 20 seconds, then held
///
/// The window uses these too (LabSettings.audioWave), so the live tuning loop
/// and the headless measurement cannot drift apart.
enum AudioWave {
    case constant(SIMD4<Float>)
    case sine(hz: Float)
    case pulse(hz: Float)
    case ramp(seconds: Float)

    init?(spec: String) {
        let parts = spec.split(separator: ":", maxSplits: 1)
        guard let kind = parts.first else { return nil }
        let arg = parts.count > 1 ? String(parts[1]) : ""
        switch kind {
        case "const":
            var v = SIMD4<Float>(repeating: 0)
            for (n, f) in arg.split(separator: ",").compactMap({ Float($0) })
                .prefix(4).enumerated() { v[n] = f }
            self = .constant(v)
        case "sine":  self = .sine(hz: Float(arg) ?? 0.5)
        case "pulse": self = .pulse(hz: Float(arg) ?? 2.0)
        case "ramp":  self = .ramp(seconds: Float(arg) ?? 10)
        default: return nil
        }
    }

    /// The raw target at time `t` — what the room is doing, before the
    /// envelope decides how fast the field is allowed to hear it.
    func value(at t: Float) -> SIMD4<Float> {
        switch self {
        case .constant(let v):
            return v
        case .sine(let hz):
            let s = 0.5 + 0.5 * sin(2 * Float.pi * hz * t)
            return SIMD4(s, s, s, 0)
        case .pulse(let hz):
            let phase = (t * hz).truncatingRemainder(dividingBy: 1)
            let on: Float = phase < 0.25 ? 1 : 0
            return SIMD4(on, on, on, on)
        case .ramp(let seconds):
            let r = min(max(t / max(seconds, 0.01), 0), 1)
            return SIMD4(r, r, r, 0)
        }
    }
}

struct CaptureJob {
    var output: URL
    var stats = false
    var seconds: Float = 10
    var form: Form = .lobes
    var palette: Int = 0
    var width = 402
    var height = 874
    var lab = SIMD4<Float>(repeating: 0)
    var audio: AudioWave?
    /// Kept verbatim for the "wrote" line, so a capture with a room in it says
    /// so — a stale audio-less file is otherwise indistinguishable by eye.
    var audioSpec: String?

    /// Pinned, not random. Two captures of the same shader have to be the same
    /// image or the tool is not a measuring instrument — the first version of
    /// this took the app's random per-session seed and produced two visibly
    /// different frames from an unmodified shader, which reads as "my edit did
    /// something" when nothing was edited at all.
    var seed: Float = 42

    /// Nil when `--capture` isn't present, which is how the app knows to open a
    /// window instead.
    init?(_ args: [String]) {
        var out: URL?
        var i = 1
        func next() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        while i < args.count {
            switch args[i] {
            case "--capture": if let v = next() { out = URL(fileURLWithPath: v) }
            case "--stats": stats = true
            case "--at", "--seconds": if let v = next(), let f = Float(v) { seconds = f }
            case "--form": if let v = next(), let f = Self.form(named: v) { form = f }
            case "--palette": if let v = next(), let n = Int(v) { palette = n }
            case "--seed": if let v = next(), let f = Float(v) { seed = f }
            case "--width": if let v = next(), let n = Int(v) { width = n }
            case "--height": if let v = next(), let n = Int(v) { height = n }
            case "--lab":
                // Four comma-separated floats, so a slider sweep can be run
                // from a shell loop instead of by hand.
                if let v = next() {
                    let parts = v.split(separator: ",").compactMap { Float($0) }
                    for (n, f) in parts.prefix(4).enumerated() { lab[n] = f }
                }
            case "--audio":
                if let v = next() {
                    audio = AudioWave(spec: v)
                    audioSpec = audio != nil ? v : nil
                }
            default: break
            }
            i += 1
        }
        guard let out else { return nil }
        output = out
    }

    private static func form(named s: String) -> Form? {
        if let n = Int(s) { return Form(rawValue: n) }
        return Form.allCases.first { $0.title.lowercased() == s.lowercased() }
    }
}

enum CaptureRunner {

    @MainActor
    static func run(_ job: CaptureJob) -> Never {
        do {
            try render(job)
            // Reported so a caller can tell a real render from a stale file it
            // is about to measure by mistake.
            let audio = job.audioSpec.map { ", audio \($0)" } ?? ""
            print("wrote \(job.output.path) — \(job.form.title), " +
                  "\(job.width)x\(job.height), t=\(job.seconds)s" + audio)
            exit(0)
        } catch {
            FileHandle.standardError.write(
                Data(("capture failed: " + LabRenderer.readable(error) + "\n").utf8))
            exit(1)
        }
    }

    @MainActor
    private static func render(_ job: CaptureJob) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LabRenderer.LabError.noDevice
        }

        let state = FieldState(seed: job.seed)
        state.form = job.form
        state.paletteIndex = job.palette

        let settings = LabSettings()
        let renderer = try LabRenderer(device: device, colorFormat: .bgra8Unorm,
                                       state: state, settings: settings)

        let source = try String(contentsOf: FieldLabApp.metalURL(), encoding: .utf8)
        try renderer.loadSync(source: source)

        renderer.resize(CGSize(width: job.width, height: job.height))

        // .shared so the CPU can read it back without a blit. Fine at one
        // texture on a unified-memory Mac, and it keeps the readback to a
        // single getBytes.
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: job.width, height: job.height,
            mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let target = device.makeTexture(descriptor: td),
              let queue = device.makeCommandQueue() else {
            throw LabRenderer.LabError.noDevice
        }

        // Fixed step, so the output is a function of `seconds` and nothing else.
        // 1/60 matches the app's preferredFramesPerSecond, which matters because
        // the feedback blend is applied once per frame — the same twelve seconds
        // at 30fps is half as many blends and visibly less smeared.
        let step: Float = 1.0 / 60.0
        let frames = max(Int((job.seconds / step).rounded()), 1)

        var audioEnv = AudioEnvelope()
        for frame in 0..<frames {
            guard let cmd = queue.makeCommandBuffer() else { break }

            // The synthetic room, heard through the same smoothing as the real
            // one. Set before encodeFrame so the drift integral in
            // FieldState.advance sees this frame's level, not last frame's.
            if let wave = job.audio {
                audioEnv.advance(toward: wave.value(at: Float(frame) * step),
                                 dt: step)
                state.audioLevel = audioEnv.value
            }

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            renderer.encodeFrame(cmd: cmd, dt: step, into: rpd, lab: job.lab)
            cmd.commit()
            // Serialised on purpose. Six hundred frames of command buffers
            // queued at once is a lot of live memory for no gain — nothing here
            // is waiting on the CPU.
            cmd.waitUntilCompleted()
        }

        try writePNG(texture: target, to: job.output)
        if job.stats { print(tonalReport(texture: target)) }
    }

    /// The two numbers that have decided every lighting argument in this
    /// project, and a mean to put them in context.
    ///
    /// They are worth having as a tool rather than an eyeball because they have
    /// been so consistently counter-intuitive. Reference footage runs 1.5–2.2%
    /// of pixels genuinely blown out and around two thirds of the frame near
    /// black; every form here sat at 0.0% blown for months while looking, to
    /// everyone who looked at it, like it had bright parts. Screens and eyes
    /// both adapt. A histogram doesn't.
    ///
    /// Near-black is luma < 16/255, which is roughly where a phone at moderate
    /// brightness stops showing you anything in a dark room. Blown is all three
    /// channels above 250 — deliberately all three, since a saturated red at
    /// 255,40,40 is vivid but is not blown out, and counting it as such is how
    /// you talk yourself into believing a frame has highlights it doesn't.
    private static func tonalReport(texture: MTLTexture) -> String {
        let w = texture.width, h = texture.height
        let rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }

        var total = 0.0, black = 0, blown = 0
        let count = w * h
        for i in stride(from: 0, to: bytes.count, by: 4) {
            // BGRA.
            let b = Double(bytes[i]), g = Double(bytes[i + 1]), r = Double(bytes[i + 2])
            let luma = 0.299 * r + 0.587 * g + 0.114 * b
            total += luma
            if luma < 16 { black += 1 }
            if r > 250, g > 250, b > 250 { blown += 1 }
        }

        let pc = { (n: Int) in Double(n) / Double(count) * 100 }
        return String(format: "mean %.1f · near-black %.1f%% · blown %.2f%%",
                      total / Double(count), pc(black), pc(blown))
    }

    private static func writePNG(texture: MTLTexture, to url: URL) throws {
        let w = texture.width, h = texture.height
        let rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }

        // The texture is BGRA and CoreGraphics has no BGRA constant — it is
        // spelled "32 bits little-endian with alpha first", which is the same
        // bytes read the other way round.
        let info = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.noneSkipFirst.rawValue |
            CGBitmapInfo.byteOrder32Little.rawValue)

        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureError.encodeFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CaptureError.encodeFailed }
    }

    enum CaptureError: Error { case encodeFailed }
}
