//
//  LabRenderer.swift
//  The same frame FieldRenderer draws, with the shader compiled from disk.
//
//  This is a deliberate near-duplicate of
//  ios/Mycelium/Mycelium/Field/FieldRenderer.swift, and the duplication is the
//  point of the tool rather than a shortcut in it. A lab that renders the field
//  *approximately* is worse than no lab: you would tune against it and find out
//  on a phone. So the pass chain, the pixel formats, the render scales, the blur
//  spacings and the dt clamp are copied exactly, and a change to one has to be
//  made in the other.
//
//  Exactly two things differ, both structural:
//
//    1. The library comes from `makeLibrary(source:)` at runtime instead of
//       `makeDefaultLibrary()`. That is the entire reason this file exists —
//       Xcode compiles .metal at build time, so there is no way to get a hot
//       reload out of the app target.
//    2. `Uniforms.lab` carries the four slider values instead of zero.
//
//  Compiles run on a background queue and only swap in on success, so a shader
//  with a syntax error leaves the previous frame running and puts the compiler's
//  message on top of it. That matters more than it sounds: the alternative is a
//  black window at exactly the moment you want to compare against what you had.
//
//  The renderer knows nothing about MTKView. `encodeFrame` takes a render pass
//  descriptor and fills it, which is what lets the same code path serve the live
//  window and the headless capture — if capture went through a second
//  implementation it would stop being evidence about the first.
//

import Metal
import MetalKit
import QuartzCore
import simd

/// The five pipelines a frame needs, grouped so they swap in as one value. A
/// partial swap would draw a frame from two versions of the shader, which is a
/// confusing thing to be shown while you are editing it.
private struct Pipelines {
    var field: MTLRenderPipelineState
    var bright: MTLRenderPipelineState
    var blur: MTLRenderPipelineState
    var blurAdd: MTLRenderPipelineState
    var present: MTLRenderPipelineState
}

final class LabRenderer: NSObject, MTKViewDelegate {

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private var sampler: MTLSamplerState!
    private var pipelines: Pipelines?

    private var accum: [MTLTexture] = []
    private var bloom: [MTLTexture] = []
    private var current = 0

    private let state: FieldState
    private let settings: LabSettings
    private let colorFormat: MTLPixelFormat
    private var lastFrameTime: CFTimeInterval?

    private var compiling = false
    private var pendingSource: String?
    private let compileQueue = DispatchQueue(label: "fieldlab.compile", qos: .userInitiated)

    // The window's stand-in for a microphone. Field time rather than wall
    // time, so a pulse wave slows down with the time-scale slider the same way
    // everything else does.
    private var audioEnv = AudioEnvelope()
    private var audioClock: Float = 0

    // These four must track FieldRenderer. See the file comment.
    private static let accumFormat: MTLPixelFormat = .rgba16Float
    private static let fieldScale: CGFloat = 0.72
    private static let bloomScale: CGFloat = 0.25
    private static let wideBlur: Float = 4.2

    private var fieldSize = CGSize(width: 1, height: 1)
    private var bloomSize = CGSize(width: 1, height: 1)

    enum LabError: Error {
        case noDevice
        case missingFunction(String)
    }

    init(device: MTLDevice, colorFormat: MTLPixelFormat,
         state: FieldState, settings: LabSettings) throws {
        guard let queue = device.makeCommandQueue() else { throw LabError.noDevice }
        self.device = device
        self.queue = queue
        self.colorFormat = colorFormat
        self.state = state
        self.settings = settings
        super.init()

        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: d)
    }

    func configure(view: MTKView) {
        view.device = device
        view.colorPixelFormat = colorFormat
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.delegate = self
    }

    // MARK: - Compiling

    /// Compile `source` and, if it works, swap it in. Called on the main thread
    /// every time the file on disk changes.
    @MainActor
    func load(source: String) {
        guard !compiling else { pendingSource = source; return }
        compiling = true
        settings.compiling = true

        let started = CACurrentMediaTime()
        compileQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.build(source: source) }
            let ms = (CACurrentMediaTime() - started) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(result, ms: ms) }
            }
        }
    }

    /// Blocking compile, for the headless capture path — there is no previous
    /// frame to keep alive there, so there is nothing for the async version to
    /// buy.
    func loadSync(source: String) throws {
        pipelines = try build(source: source)
    }

    @MainActor
    private func finish(_ result: Result<Pipelines, Error>, ms: Double) {
        compiling = false
        settings.compiling = false
        settings.lastCompileMS = ms

        switch result {
        case .success(let p):
            // Only now does the old frame stop being the live one.
            pipelines = p
            settings.error = nil
            settings.compiles += 1
        case .failure(let e):
            settings.error = Self.readable(e)
        }

        // A save that landed mid-compile. Only the newest matters — the ones
        // between describe a file that no longer exists.
        if let next = pendingSource {
            pendingSource = nil
            load(source: next)
        }
    }

    nonisolated private func build(source: String) throws -> Pipelines {
        // Default options on purpose. Xcode compiles this same file in the app
        // target with its own defaults, and the one thing this tool must not do
        // is compile the shader differently from the way it ships — fast math
        // changes what the transcendentals return, and this shader is almost
        // entirely transcendentals.
        let lib = try device.makeLibrary(source: source, options: MTLCompileOptions())

        func fn(_ name: String) throws -> MTLFunction {
            guard let f = lib.makeFunction(name: name) else {
                throw LabError.missingFunction(name)
            }
            return f
        }

        let vfn = try fn("fullscreenVertex")

        func pipeline(_ name: String, _ format: MTLPixelFormat,
                      additive: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vfn
            d.fragmentFunction = try fn(name)
            d.colorAttachments[0].pixelFormat = format
            if additive {
                d.colorAttachments[0].isBlendingEnabled = true
                d.colorAttachments[0].rgbBlendOperation = .add
                d.colorAttachments[0].sourceRGBBlendFactor = .one
                d.colorAttachments[0].destinationRGBBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }

        return Pipelines(
            field:   try pipeline("fieldFragment", Self.accumFormat),
            bright:  try pipeline("bloomBrightFragment", Self.accumFormat),
            blur:    try pipeline("bloomBlurFragment", Self.accumFormat),
            blurAdd: try pipeline("bloomBlurFragment", Self.accumFormat, additive: true),
            present: try pipeline("presentFragment", colorFormat))
    }

    /// Metal wraps the compiler log in a sentence that is the same every time
    /// and pushes the line number off the visible area. Strip back to the
    /// diagnostics.
    static func readable(_ error: Error) -> String {
        if case LabError.missingFunction(let name) = error {
            return """
            The shader compiled, but there is no function called \(name).

            Every pass needs its entry point: fullscreenVertex, fieldFragment, \
            bloomBrightFragment, bloomBlurFragment, presentFragment.
            """
        }
        let text = (error as NSError).localizedDescription
        guard let colon = text.range(of: ":\n") else { return text }
        return String(text[colon.upperBound...])
    }

    // MARK: - Textures

    func resize(_ size: CGSize) {
        let w = max(Int((size.width  * Self.fieldScale).rounded()), 1)
        let h = max(Int((size.height * Self.fieldScale).rounded()), 1)
        guard w > 1, h > 1 else { return }
        fieldSize = CGSize(width: w, height: h)

        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.accumFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        accum = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }

        let bw = max(Int((CGFloat(w) * Self.bloomScale).rounded()), 1)
        let bh = max(Int((CGFloat(h) * Self.bloomScale).rounded()), 1)
        bloomSize = CGSize(width: bw, height: bh)

        let bd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.accumFormat, width: bw, height: bh, mipmapped: false)
        bd.usage = [.renderTarget, .shaderRead]
        bd.storageMode = .private
        bloom = (0..<3).compactMap { _ in device.makeTexture(descriptor: bd) }

        current = 0
        clearAccumulation()
    }

    /// Textures come back with undefined contents and the field pass samples the
    /// previous frame at ~60%, so without this the first frame reads garbage and
    /// the feedback loop locks it in rather than washing it out.
    func clearAccumulation() {
        guard let cmd = queue.makeCommandBuffer() else { return }
        for tex in accum + bloom {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = tex
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            pass.colorAttachments[0].storeAction = .store
            cmd.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        }
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    // MARK: - Frame

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        resize(size)
    }

    func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            let now = CACurrentMediaTime()
            let raw = min(now - (lastFrameTime ?? now), 1.0 / 20.0)
            lastFrameTime = now

            // Rolling average over roughly half a second. An instantaneous
            // readout flickers too much to read while watching the field.
            if raw > 0 { settings.fps += (1.0 / raw - settings.fps) * 0.06 }

            // Clamp first, scale second. Clamping afterwards would cap 8x time
            // at 20fps of simulation per frame and quietly stop the scale doing
            // anything past about 3x.
            let dt = settings.paused ? 0 : Float(raw) * settings.timeScale

            guard let drawable = view.currentDrawable,
                  let rpd = view.currentRenderPassDescriptor,
                  let cmd = queue.makeCommandBuffer() else { return }

            if accum.count < 2 || bloom.count < 3 { resize(view.drawableSize) }

            // The synthetic room, before encodeFrame for the same reason the
            // capture path does it there: the drift integral has to see this
            // frame's level.
            audioClock += dt
            audioEnv.advance(toward: settings.audioWave.value(at: audioClock),
                             dt: dt)
            state.audioLevel = audioEnv.value

            encodeFrame(cmd: cmd, dt: dt, into: rpd, lab: settings.lab)
            cmd.present(drawable)
            cmd.commit()
        }
    }

    /// Advance the model by `dt` and encode one whole frame into `rpd`.
    @MainActor
    func encodeFrame(cmd: MTLCommandBuffer, dt: Float,
                     into rpd: MTLRenderPassDescriptor, lab: SIMD4<Float>) {
        state.advance(deltaTime: dt)

        guard let pipelines, accum.count == 2, bloom.count == 3 else { return }

        let prev = accum[current]
        let next = accum[1 - current]

        // ── Pass 1: the field, blended with the previous frame ──────────────
        let fieldPass = MTLRenderPassDescriptor()
        fieldPass.colorAttachments[0].texture = next
        fieldPass.colorAttachments[0].loadAction = .dontCare
        fieldPass.colorAttachments[0].storeAction = .store

        if let enc = cmd.makeRenderCommandEncoder(descriptor: fieldPass) {
            enc.setRenderPipelineState(pipelines.field)

            let pal = state.palette
            var uniforms = Uniforms(
                resTime: SIMD4(Float(fieldSize.width), Float(fieldSize.height),
                               state.elapsed, state.breathPhase),
                groundCount: SIMD4(state.grounding,
                                   Float(state.blooms.count),
                                   state.seed,
                                   Float(state.form.rawValue)),
                holdParams: SIMD4(state.hold, state.holdPhase, dt, 0),
                colony: SIMD4(state.colonyGrowth, state.zoomPush, state.pushDelta, 0),
                // w carries the palette's own hue spread — see `Palette.spread`.
                palA: SIMD4<Float>(pal.a.x, pal.a.y, pal.a.z, pal.spread),
                palB: SIMD4<Float>(pal.b.x, pal.b.y, pal.b.z, 0),
                palC: SIMD4<Float>(pal.c.x, pal.c.y, pal.c.z, 0),
                palD: SIMD4<Float>(pal.d.x, pal.d.y, pal.d.z, 0),
                lab: lab,
                // Same fill as FieldRenderer's, from the same state — the lab
                // drives `state.audioLevel` from its sliders or a synthetic
                // waveform where the app drives it from the microphone.
                audio: SIMD4(state.audioLevel.x, state.audioLevel.y,
                             state.audioLevel.z, state.audioDriftTime))
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

            var packed = state.packedBlooms
            if packed.count < FieldState.maxBlooms {
                packed.append(contentsOf: Array(repeating: SIMD4<Float>(repeating: 0),
                                                count: FieldState.maxBlooms - packed.count))
            }
            enc.setFragmentBytes(&packed,
                                 length: MemoryLayout<SIMD4<Float>>.stride * FieldState.maxBlooms,
                                 index: 1)

            enc.setFragmentTexture(prev, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // ── Pass 2: the glow ────────────────────────────────────────────────
        //   accum ──bright──▶ b0 ──H──▶ b1 ──V──▶ b2      (tight)
        //                     b2 ──H──▶ b1 ──V+─▶ b2      (wide, added on)
        let srcTexel = SIMD4<Float>(1 / Float(fieldSize.width),
                                    1 / Float(fieldSize.height), 0, 0)
        postPass(cmd: cmd, pipeline: pipelines.bright, from: next, to: bloom[0],
                 params: srcTexel)

        let bx = 1 / Float(bloomSize.width)
        let by = 1 / Float(bloomSize.height)
        postPass(cmd: cmd, pipeline: pipelines.blur, from: bloom[0], to: bloom[1],
                 params: SIMD4(bx, 0, 1, 0))
        postPass(cmd: cmd, pipeline: pipelines.blur, from: bloom[1], to: bloom[2],
                 params: SIMD4(0, by, 1, 0))
        postPass(cmd: cmd, pipeline: pipelines.blur, from: bloom[2], to: bloom[1],
                 params: SIMD4(bx * Self.wideBlur, 0, 1, 0))
        postPass(cmd: cmd, pipeline: pipelines.blurAdd, from: bloom[1], to: bloom[2],
                 params: SIMD4(0, by * Self.wideBlur, 0.40, 0), load: true)

        // ── Pass 3: tonemap to the target ───────────────────────────────────
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(pipelines.present)
            enc.setFragmentTexture(next, index: 0)
            enc.setFragmentTexture(bloom[2], index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        current = 1 - current
    }

    /// One fullscreen post pass. `.dontCare` on all but the additive one: every
    /// pass writes every pixel of its target, so loading the previous contents
    /// is pure bandwidth. The additive pass by definition needs what's there.
    private func postPass(cmd: MTLCommandBuffer,
                          pipeline: MTLRenderPipelineState,
                          from: MTLTexture,
                          to: MTLTexture,
                          params: SIMD4<Float>,
                          load: Bool = false) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = to
        pass.colorAttachments[0].loadAction = load ? .load : .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        var p = params
        enc.setFragmentBytes(&p, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        enc.setFragmentTexture(from, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
