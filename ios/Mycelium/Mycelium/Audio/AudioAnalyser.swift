//
//  AudioAnalyser.swift
//  The microphone, reduced to four floats.
//
//  Buffers arrive on a realtime audio thread and leave as one SIMD4 snapshot —
//  bass, mid, treble, onset, each 0…1 and already smoothed with the
//  AudioDynamics taus. Everything heavy happens here, off the main thread, so
//  the render loop only ever pays for one lock-protected read.
//
//  The pipeline, in order:
//
//    ring buffer → Hann window → 1024-pt FFT → band magnitudes → AGC → gate →
//    AudioEnvelope → snapshot
//
//  Why an FFT rather than a bank of biquads: the band edges are data here, not
//  filter designs. The tuning loop moves them, and moving a number is cheaper
//  than redesigning a filter. Spectral-flux onset also falls out of the same
//  magnitudes for free.
//
//  The tap's bufferSize is advisory — iOS delivers ~100ms chunks whatever you
//  ask for. The ring buffer absorbs that: fixed 1024-sample windows at a 512
//  hop, however the chunks land. No allocation happens after init.
//
//  This file must never be compiled by Field Lab — the lab's synthetic room
//  drives FieldState.audioLevel directly, through the same AudioEnvelope this
//  uses, which is the contract that keeps the two worlds honest.
//

import AVFAudio
import Accelerate
import simd

final class AudioAnalyser {

    /// One snapshot, safe to read from any thread. The render loop's publish
    /// timer reads it at ~30Hz; the tap thread writes it per hop.
    var smoothed: SIMD4<Float> {
        lock.withLock { $0 }
    }

    private let lock = OSAllocatedUnfairLock<SIMD4<Float>>(initialState: .zero)

    // ── Analysis geometry ──────────────────────────────────────────────────
    private static let windowSize = 1024
    private static let hop = 512
    private static let log2n = vDSP_Length(10)   // 2^10 = 1024

    /// Band edges in Hz. Bass stops where a kick drum's fundamental does; mid
    /// carries voices and most melody; treble is the shimmer on top. Edges are
    /// converted to bins per session because the hardware sample rate is not
    /// ours to choose.
    private static let bassRange: ClosedRange<Float> = 40...160
    private static let midRange: ClosedRange<Float> = 160...1300
    private static let trebleRange: ClosedRange<Float> = 1300...8000

    /// A silent room must not flicker on mic hiss: below this, a band's target
    /// releases to zero rather than being normalised up into fake signal.
    private static let gateDB: Float = -55

    /// The AGC's release, seconds. Long on purpose — it adapts to the *room*
    /// (a phone speaker vs a party) and must not itself become rhythm.
    private static let agcRelease: Float = 15

    private let sampleRate: Float
    private let binHz: Float

    // Preallocated working storage — the tap thread must not allocate.
    private var ring: [Float]
    private var ringWrite = 0
    private var ringFill = 0
    private var window = [Float](repeating: 0, count: windowSize)
    private var frame = [Float](repeating: 0, count: windowSize)
    private var real = [Float](repeating: 0, count: windowSize / 2)
    private var imag = [Float](repeating: 0, count: windowSize / 2)
    private var magnitudes = [Float](repeating: 0, count: windowSize / 2)
    private var prevMagnitudes = [Float](repeating: 0, count: windowSize / 2)
    private let fft: FFTSetup

    // Per-band running peaks for the AGC, and the shared envelope.
    private var peaks = SIMD4<Float>(repeating: 1e-6)
    private var envelope = AudioEnvelope()

    private let bassBins: Range<Int>
    private let midBins: Range<Int>
    private let trebleBins: Range<Int>

    init?(format: AVAudioFormat) {
        guard let setup = vDSP_create_fftsetup(Self.log2n, FFTRadix(kFFTRadix2))
        else { return nil }
        fft = setup
        sampleRate = Float(format.sampleRate)
        binHz = sampleRate / Float(Self.windowSize)

        // Half a second of ring at 48k. Chunks arrive ~100ms; this is slack,
        // not precision.
        ring = [Float](repeating: 0, count: 1 << 15)

        // Takes the bin width as a parameter rather than reading the property:
        // a nested function that touches `self` before every stored property
        // is set won't compile, and shouldn't.
        func bins(_ range: ClosedRange<Float>, hz: Float) -> Range<Int> {
            let lo = max(Int(range.lowerBound / hz), 1)
            let hi = min(Int(range.upperBound / hz), Self.windowSize / 2 - 1)
            return lo..<max(hi, lo + 1)
        }
        bassBins = bins(Self.bassRange, hz: binHz)
        midBins = bins(Self.midRange, hz: binHz)
        trebleBins = bins(Self.trebleRange, hz: binHz)

        vDSP_hann_window(&window, vDSP_Length(Self.windowSize),
                         Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(fft)
    }

    /// Called from the tap. Audio-thread rules apply: no locks held long, no
    /// allocation, no Objective-C messaging beyond what vDSP already is.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)

        // Into the ring.
        for i in 0..<n {
            ring[ringWrite] = data[i]
            ringWrite = (ringWrite + 1) % ring.count
        }
        ringFill = min(ringFill + n, ring.count)

        // Fixed windows out of it, one hop at a time.
        while ringFill >= Self.windowSize {
            let start = (ringWrite - ringFill + ring.count * 2) % ring.count
            for i in 0..<Self.windowSize {
                frame[i] = ring[(start + i) % ring.count]
            }
            ringFill -= Self.hop
            analyseFrame()
        }
    }

    private func analyseFrame() {
        // Window, then pack for the real FFT. vDSP's zrip wants split-complex
        // even/odd interleave; ctoz does that reinterpretation.
        vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(Self.windowSize))
        frame.withUnsafeBufferPointer { fp in
            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                              capacity: Self.windowSize / 2) { cp in
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!,
                                                    imagp: ip.baseAddress!)
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(Self.windowSize / 2))
                        vDSP_fft_zrip(fft, &split, 1, Self.log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &magnitudes, 1,
                                   vDSP_Length(Self.windowSize / 2))
                    }
                }
            }
        }

        // Mean magnitude per band, and spectral flux for the onset — the sum
        // of magnitude *increases* since the last frame, so a sustained chord
        // contributes nothing and a struck one contributes everything.
        func bandLevel(_ bins: Range<Int>) -> Float {
            var sum: Float = 0
            magnitudes.withUnsafeBufferPointer { mp in
                vDSP_sve(mp.baseAddress! + bins.lowerBound, 1, &sum,
                         vDSP_Length(bins.count))
            }
            return sum / Float(bins.count)
        }
        var flux: Float = 0
        for i in bassBins.lowerBound..<trebleBins.upperBound {
            flux += max(magnitudes[i] - prevMagnitudes[i], 0)
        }
        swap(&magnitudes, &prevMagnitudes)

        var raw = SIMD4<Float>(bandLevel(bassBins), bandLevel(midBins),
                               bandLevel(trebleBins), flux)

        // AGC: each channel normalised against its own slow-release peak, so a
        // quiet room and a loud speaker both land in 0…1 without a knob.
        let dt = Float(Self.hop) / sampleRate
        let decay = exp(-dt / Self.agcRelease)
        for i in 0..<4 {
            peaks[i] = max(raw[i], peaks[i] * decay)
            raw[i] = peaks[i] > 1e-6 ? min(raw[i] / peaks[i], 1) : 0
        }

        // The gate, on the pre-AGC level in dBFS terms. Without it the AGC
        // dutifully normalises hiss to full scale and an empty room strobes.
        let overall = bandLevel(bassBins.lowerBound..<trebleBins.upperBound)
        if 20 * log10(max(overall / Float(Self.windowSize), 1e-9)) < Self.gateDB {
            raw = .zero
        }

        envelope.advance(toward: raw, dt: dt)
        let value = envelope.value
        lock.withLock { $0 = value }
    }
}
