//
//  FieldRenderer.swift
//  Ping-pong Metal renderer.
//
//  Frame shape:
//    accum[prev] ──▶ fieldFragment ──▶ accum[cur] ──▶ presentFragment ──▶ drawable
//
//  The feedback texture is why strokes persist and get woven into the pattern
//  instead of just fading. It's also why replay will be cheap later: the field
//  is a pure function of (time, seed, bloom log), so re-running the log
//  reproduces the session exactly.
//

import Metal
import MetalKit
import simd

/// **This struct is declared twice** — here and in `Field.metal`. There is no
/// shared header and nothing checks that they agree, so adding a field to one
/// side still compiles cleanly and silently reinterprets memory on the other.
/// Every field is a `float4` for the same reason: no padding, so the two
/// layouts can only disagree in ways that are obvious to read.
private struct Uniforms {
    var resTime: SIMD4<Float>
    var groundCount: SIMD4<Float>
    var holdParams: SIMD4<Float>
    var colony: SIMD4<Float>
    var palA: SIMD4<Float>
    var palB: SIMD4<Float>
    var palC: SIMD4<Float>
    var palD: SIMD4<Float>
}

final class FieldRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var fieldPipeline: MTLRenderPipelineState!
    private var presentPipeline: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!

    /// Two accumulation buffers, swapped each frame.
    private var accum: [MTLTexture] = []
    private var current = 0

    private let state: FieldState
    private var lastFrameTime: CFTimeInterval?

    /// rgba16Float so bloom brightness can accumulate above 1.0 and get rolled
    /// off in the present pass rather than clipping mid-field.
    private static let accumFormat: MTLPixelFormat = .rgba16Float

    /// Preview tiles run several renderers at once on the picker screen, so
    /// they render at half rate. Everything else about them is identical —
    /// what you see in a tile is the real field, not an approximation.
    init?(view: MTKView, state: FieldState, preview: Bool = false) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.state = state
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        view.preferredFramesPerSecond = preview ? 30 : 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false

        guard makePipelines(view: view) else { return nil }
        makeSampler()
    }

    private func makePipelines(view: MTKView) -> Bool {
        guard let library = device.makeDefaultLibrary(),
              let vfn = library.makeFunction(name: "fullscreenVertex"),
              let ffn = library.makeFunction(name: "fieldFragment"),
              let pfn = library.makeFunction(name: "presentFragment") else {
            return false
        }

        let fieldDesc = MTLRenderPipelineDescriptor()
        fieldDesc.vertexFunction = vfn
        fieldDesc.fragmentFunction = ffn
        fieldDesc.colorAttachments[0].pixelFormat = Self.accumFormat

        let presentDesc = MTLRenderPipelineDescriptor()
        presentDesc.vertexFunction = vfn
        presentDesc.fragmentFunction = pfn
        presentDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat

        do {
            fieldPipeline = try device.makeRenderPipelineState(descriptor: fieldDesc)
            presentPipeline = try device.makeRenderPipelineState(descriptor: presentDesc)
            return true
        } catch {
            assertionFailure("Pipeline creation failed: \(error)")
            return false
        }
    }

    private func makeSampler() {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: d)
    }

    private func rebuildTextures(size: CGSize) {
        let w = max(Int(size.width), 1)
        let h = max(Int(size.height), 1)
        guard w > 1, h > 1 else { return }

        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.accumFormat, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private

        accum = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
        current = 0
        clearAccumulation()
    }

    /// Textures come back with undefined contents. The field pass samples the
    /// previous frame at ~60% weight, so without this the first frame reads
    /// garbage and the feedback loop locks it in permanently instead of
    /// washing it out.
    private func clearAccumulation() {
        guard let cmd = queue.makeCommandBuffer() else { return }
        for tex in accum {
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        rebuildTextures(size: size)
    }

    func draw(in view: MTKView) {
        // MTKView drives draw(in:) on the main thread with the default
        // configuration, so main-actor state is safe to touch here.
        MainActor.assumeIsolated { render(in: view) }
    }

    @MainActor
    private func render(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - (lastFrameTime ?? now), 1.0 / 20.0))
        lastFrameTime = now
        state.advance(deltaTime: dt)

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        if accum.count < 2 { rebuildTextures(size: view.drawableSize) }
        guard accum.count == 2 else { return }

        let prev = accum[current]
        let next = accum[1 - current]

        // ── Pass 1: the field, blended with the previous frame ──────────────
        let fieldPass = MTLRenderPassDescriptor()
        fieldPass.colorAttachments[0].texture = next
        fieldPass.colorAttachments[0].loadAction = .dontCare
        fieldPass.colorAttachments[0].storeAction = .store

        if let enc = cmd.makeRenderCommandEncoder(descriptor: fieldPass) {
            enc.setRenderPipelineState(fieldPipeline)

            let size = view.drawableSize
            let pal = state.palette
            var uniforms = Uniforms(
                resTime: SIMD4(Float(size.width), Float(size.height),
                               state.elapsed, state.breathPhase),
                groundCount: SIMD4(state.grounding,
                                   Float(state.blooms.count),
                                   state.seed,
                                   Float(state.form.rawValue)),
                // dt goes to the shader so the feedback trail can be locked to
                // the zoom rate instead of drifting at its own pace.
                holdParams: SIMD4(state.hold, state.holdPhase, dt, 0),
                // Mycelial only. Reach is the colony's radius on screen, push
                // is how far taps have shoved the camera back in octaves, and
                // the delta is this frame's share of that — the feedback trail
                // needs it or the ghost lags behind during a pullback.
                colony: SIMD4(state.colonyReach, state.zoomPush,
                              state.pushDelta, 0),
                palA: SIMD4<Float>(pal.a.x, pal.a.y, pal.a.z, 0),
                palB: SIMD4<Float>(pal.b.x, pal.b.y, pal.b.z, 0),
                palC: SIMD4<Float>(pal.c.x, pal.c.y, pal.c.z, 0),
                palD: SIMD4<Float>(pal.d.x, pal.d.y, pal.d.z, 0))
            enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

            // Always send a full-size array so the shader's bounded loop reads
            // valid memory even when fewer blooms are live.
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

        // ── Pass 2: tonemap to the screen ───────────────────────────────────
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentTexture(next, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()

        current = 1 - current
    }
}
