//
//  FieldRenderer.swift
//  Ping-pong Metal renderer.
//
//  Frame shape:
//    accum[prev] ──▶ fieldFragment ──▶ accum[cur] ─────────┐
//                                          │              ▼
//                                          └─▶ bright ─▶ blur x4 ─┐
//                                                                 ▼
//                                              presentFragment ──▶ drawable
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
    private var brightPipeline: MTLRenderPipelineState!
    private var blurPipeline: MTLRenderPipelineState!
    private var blurAddPipeline: MTLRenderPipelineState!
    private var presentPipeline: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!

    /// Two accumulation buffers, swapped each frame.
    private var accum: [MTLTexture] = []
    private var current = 0

    /// Bloom ping-pong. Same format as the accumulation buffers — the whole
    /// point of this pass is the part of the signal that is above 1, so an
    /// 8-bit target here would throw away exactly what it exists to carry.
    private var bloom: [MTLTexture] = []

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
              let bfn = library.makeFunction(name: "bloomBrightFragment"),
              let lfn = library.makeFunction(name: "bloomBlurFragment"),
              let pfn = library.makeFunction(name: "presentFragment") else {
            return false
        }

        let fieldDesc = MTLRenderPipelineDescriptor()
        fieldDesc.vertexFunction = vfn
        fieldDesc.fragmentFunction = ffn
        fieldDesc.colorAttachments[0].pixelFormat = Self.accumFormat

        let brightDesc = MTLRenderPipelineDescriptor()
        brightDesc.vertexFunction = vfn
        brightDesc.fragmentFunction = bfn
        brightDesc.colorAttachments[0].pixelFormat = Self.accumFormat

        let blurDesc = MTLRenderPipelineDescriptor()
        blurDesc.vertexFunction = vfn
        blurDesc.fragmentFunction = lfn
        blurDesc.colorAttachments[0].pixelFormat = Self.accumFormat

        // Same shader, additive. This is how the wide scale gets summed onto
        // the tight one instead of replacing it — see bloomBlurFragment for why
        // that is the difference between small things glowing and not.
        let blurAddDesc = MTLRenderPipelineDescriptor()
        blurAddDesc.vertexFunction = vfn
        blurAddDesc.fragmentFunction = lfn
        blurAddDesc.colorAttachments[0].pixelFormat = Self.accumFormat
        blurAddDesc.colorAttachments[0].isBlendingEnabled = true
        blurAddDesc.colorAttachments[0].rgbBlendOperation = .add
        blurAddDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        blurAddDesc.colorAttachments[0].destinationRGBBlendFactor = .one

        let presentDesc = MTLRenderPipelineDescriptor()
        presentDesc.vertexFunction = vfn
        presentDesc.fragmentFunction = pfn
        presentDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat

        do {
            fieldPipeline = try device.makeRenderPipelineState(descriptor: fieldDesc)
            brightPipeline = try device.makeRenderPipelineState(descriptor: brightDesc)
            blurPipeline = try device.makeRenderPipelineState(descriptor: blurDesc)
            blurAddPipeline = try device.makeRenderPipelineState(descriptor: blurAddDesc)
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

    /// How much of the screen's resolution the *field* pass actually renders
    /// at. The present pass still runs at full drawable size and upsamples with
    /// a linear sampler, so text-sharp edges would suffer — and there are none.
    ///
    /// This is the single biggest lever on frame time in the whole app, and it
    /// is worth understanding why it costs so little here. Every form is a
    /// fragment shader with no geometry, so cost is exactly proportional to
    /// pixels: 0.72 linear is barely half the work. What it buys back is
    /// detail, and these forms have none at pixel scale by construction —
    /// mycelial's sheath is a soft falloff, the tunnel anti-aliases its beads
    /// to their own average as they approach a pixel across, and every form
    /// then gets blended with a blurred copy of the previous frame at 26–66%.
    /// A 3x phone screen is rendering the field at an effective 2.2x and the
    /// feedback pass is smearing it anyway.
    ///
    /// If a future form has hard sub-pixel structure this is the first thing to
    /// put back.
    private static let fieldScale: CGFloat = 0.72

    /// The size the field pass actually renders at — which is what the shader
    /// needs in `resTime.xy`, not the drawable size. Getting that wrong doesn't
    /// crash: the aspect correction goes subtly wrong and the tunnel's
    /// anti-aliasing starts lying about how big a pixel is.
    private var fieldSize = CGSize(width: 1, height: 1)

    /// The bloom chain runs at a quarter of the field pass linearly — a
    /// sixteenth of its pixels — and the blur is what makes that free rather
    /// than merely cheap. A gaussian's whole job is to throw away detail, so
    /// resolving it finely is spending on something you are about to discard;
    /// the only visible consequence of a coarse blur buffer is that the glow
    /// can't have a hard edge, which is not a thing glows have.
    ///
    /// It also multiplies the blur's reach for nothing: a tap one texel wide
    /// here covers four field pixels, so the same five taps spread the light
    /// four times as far as they would at full rate.
    private static let bloomScale: CGFloat = 0.25
    private var bloomSize = CGSize(width: 1, height: 1)

    private func rebuildTextures(size: CGSize) {
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
        // Three: two to ping-pong through the separable passes, and one that
        // accumulates both scales. The third is what makes the sum possible.
        bloom = (0..<3).compactMap { _ in device.makeTexture(descriptor: bd) }

        current = 0
        clearAccumulation()
    }

    /// Textures come back with undefined contents. The field pass samples the
    /// previous frame at ~60% weight, so without this the first frame reads
    /// garbage and the feedback loop locks it in permanently instead of
    /// washing it out.
    private func clearAccumulation() {
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

        if accum.count < 2 || bloom.count < 3 { rebuildTextures(size: view.drawableSize) }
        // Both, together. The present pass adds the bloom target unconditionally,
        // so a half-built set would mean binding *something* there — and the
        // only thing to hand is the field itself, which would render the frame
        // added to itself at double brightness rather than failing visibly.
        guard accum.count == 2, bloom.count == 3 else { return }

        let prev = accum[current]
        let next = accum[1 - current]

        // ── Pass 1: the field, blended with the previous frame ──────────────
        let fieldPass = MTLRenderPassDescriptor()
        fieldPass.colorAttachments[0].texture = next
        fieldPass.colorAttachments[0].loadAction = .dontCare
        fieldPass.colorAttachments[0].storeAction = .store

        if let enc = cmd.makeRenderCommandEncoder(descriptor: fieldPass) {
            enc.setRenderPipelineState(fieldPipeline)

            // The field pass's own size, not the drawable's — see `fieldSize`.
            let size = fieldSize
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
                colony: SIMD4(state.colonyGrowth, state.zoomPush,
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

        // ── Pass 2: the glow ────────────────────────────────────────────────
        // Bright-pass, then two separable blurs at different tap spacings,
        // summed. One gaussian gives a glow with exactly one size and light
        // doesn't have one size — the references have a hard core inside a
        // wide faint halo. Chaining the two instead of summing them loses the
        // core entirely; see bloomBlurFragment for what that costs.
        //
        //   accum ──bright──▶ b0 ──H──▶ b1 ──V──▶ b2      (tight)
        //                     b2 ──H──▶ b1 ──V+─▶ b2      (wide, added on)
        let srcTexel = SIMD4<Float>(1 / Float(fieldSize.width),
                                    1 / Float(fieldSize.height), 0, 0)
        postPass(cmd: cmd, pipeline: brightPipeline,
                 from: next, to: bloom[0], params: srcTexel)

        let bx = 1 / Float(bloomSize.width)
        let by = 1 / Float(bloomSize.height)
        postPass(cmd: cmd, pipeline: blurPipeline, from: bloom[0], to: bloom[1],
                 params: SIMD4(bx, 0, 1, 0))
        postPass(cmd: cmd, pipeline: blurPipeline, from: bloom[1], to: bloom[2],
                 params: SIMD4(0, by, 1, 0))

        // The wide scale reads the tight result rather than the bright pass —
        // a gaussian of a gaussian is just a wider gaussian, so this costs
        // nothing and saves keeping the bright output alive. The gain rides on
        // the final pass so it applies once; the halo wants to be fainter than
        // the core or it stops reading as depth and starts reading as haze.
        let wide: Float = 2.6
        postPass(cmd: cmd, pipeline: blurPipeline, from: bloom[2], to: bloom[1],
                 params: SIMD4(bx * wide, 0, 1, 0))
        postPass(cmd: cmd, pipeline: blurAddPipeline, from: bloom[1], to: bloom[2],
                 params: SIMD4(0, by * wide, 0.75, 0), load: true)

        // ── Pass 3: tonemap to the screen ───────────────────────────────────
        if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentTexture(next, index: 0)
            enc.setFragmentTexture(bloom[2], index: 1)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cmd.present(drawable)
        cmd.commit()

        current = 1 - current
    }

    /// One fullscreen post pass: sample `from`, write `to`, hand the shader a
    /// float4 of whatever it needs. Every stage of the bloom chain is this,
    /// which is why the chain reads as five lines up there instead of ninety.
    ///
    /// `loadAction = .dontCare` on all but one of them. Each pass writes every
    /// pixel of its target, so loading the previous contents is pure bandwidth
    /// — and on a tile GPU that is the difference between the tile starting
    /// empty and the whole target being read back from memory first. The
    /// exception is the additive pass, which by definition needs what's already
    /// there; `load: true` is that, and pairing it with a non-blending pipeline
    /// would silently do nothing useful.
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
