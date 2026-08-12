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
//    ring buffer → RMS gate → Hann window → 2048-pt FFT → band powers →
//    loudness above a clamped noise floor × spectral share → AudioEnvelope
//
//  Why an FFT rather than a bank of biquads: the band edges are data here, not
//  filter designs. The tuning loop moves them, and moving a number is cheaper
//  than redesigning a filter. Spectral-flux onset also falls out of the same
//  magnitudes for free.
//
//  The tap's bufferSize is advisory — iOS delivers ~100ms chunks whatever you
//  ask for. The ring buffer absorbs that: fixed 2048-sample windows at a 512
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
    // 2048 rather than 1024, for the bass. At 44.1k a 1024-point window is
    // 43Hz per bin, which puts the ENTIRE 40–160Hz bass band in two and a bit
    // bins — a kick drum and the note above it land in the same number. 2048
    // halves that to 21.5Hz and costs one more radix-2 stage.
    private static let windowSize = 2048
    private static let hop = 512
    private static let log2n = vDSP_Length(11)   // 2^11 = 2048

    /// Band edges in Hz. Bass stops where a kick drum's fundamental does; mid
    /// carries voices and most melody; treble is the shimmer on top. Edges are
    /// converted to bins per session because the hardware sample rate is not
    /// ours to choose.
    private static let bassRange: ClosedRange<Float> = 40...160
    private static let midRange: ClosedRange<Float> = 160...1300
    private static let trebleRange: ClosedRange<Float> = 1300...8000

    /// A silent room must not flicker on mic hiss: below this, a band's target
    /// releases to zero rather than being normalised up into fake signal.
    ///
    /// Measured against true time-domain RMS, which is the only reading here
    /// that is honestly in dBFS. An earlier version gated on a mean FFT
    /// magnitude divided by the window size — a number in arbitrary units that
    /// happened to be called dB, and the miscalibration was a cliff rather
    /// than a floor: a 0.5-amplitude tone came through at full scale and a
    /// 0.05 one measured EXACTLY zero. Room-level music sits below that, so
    /// the feature did nothing at all until this was caught.
    private static let gateDB: Float = -60

    /// How the room becomes 0…1 — measured absolutely, with nothing adaptive
    /// anywhere in it, and getting here took three wrong answers.
    ///
    /// **Peak AGC (wrong).** Normalising each band by its recent maximum is an
    /// AGC, and an AGC exists to make loud and quiet sound the same — exactly
    /// the distinction this feature is built on. Measured: silence 0.27, music
    /// 0.33. It also destroyed band separation, since each band pinned to its
    /// own peak: an 80Hz sine read bass 1.00 AND mid 1.00 AND treble 0.87.
    ///
    /// **Noise-floor tracking (also wrong, less obviously).** Reading decibels
    /// above a per-band quiet baseline fixes silence and separation, and then
    /// fails on the case that matters most: the floor chases the music. After
    /// twelve seconds of loud playback the floor has crept up, so the same
    /// track twenty decibels quieter reads ZERO. Any adaptive reference
    /// eventually normalises away the signal it is watching for — and music
    /// plays for the whole session, which is precisely the sustained case.
    ///
    /// **Fixed absolute dBFS (nearly right).** A quiet room at a phone mic is
    /// around −60dBFS and music in the same room is −40 to −20. Real, stable,
    /// no learning required — until the input gain isn't a phone's. On a Mac
    /// mic driving the simulator, ambient measured −30dBFS and sat halfway up
    /// the scale before anything played.
    ///
    /// So: absolute mapping, off a floor that adapts but is **clamped** to a
    /// plausible band. The clamp is the whole trick. Adaptation handles the
    /// gain of whatever microphone this turns out to be; the ceiling means
    /// sustained music can never drag the floor up past −45 and normalise
    /// itself away, which is exactly how the pure floor-tracker failed.
    private static let floorFallTau: Float = 1.0    // finds a quiet room fast
    private static let floorRiseTau: Float = 45.0   // and gives it up slowly
    private static let floorFloorDB: Float = -70    // a very quiet phone mic
    private static let floorCeilDB: Float = -45     // a hot input, still quiet
    /// Decibels from the floor to full scale.
    private static let dynamicRange: Float = 38
    /// A band carrying an even third of the energy reads about two thirds;
    /// one carrying half or more saturates. Generous on purpose — the point is
    /// that bass-heavy music drives the bass channel, not that the three sum
    /// to one.
    private static let shareGain: Float = 2.0

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

    private var envelope = AudioEnvelope()
    /// The room's quiet level, in dBFS. Starts high so the fast fall finds the
    /// true floor within a second or two of launch rather than creeping up to
    /// it over a minute.
    private var floorDB: Float = -20

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
        // Rounded, and the top edge is inclusive — truncating dropped the bin
        // the band's upper corner actually lands in.
        func bins(_ range: ClosedRange<Float>, hz: Float) -> Range<Int> {
            let lo = max(Int((range.lowerBound / hz).rounded()), 1)
            let hi = min(Int((range.upperBound / hz).rounded()) + 1,
                         Self.windowSize / 2)
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
        // Level first, on the untouched samples — the Hann window below would
        // take about 4dB off it, and a gate threshold should mean the same
        // thing as a level meter.
        var rms: Float = 0
        vDSP_rmsqv(frame, 1, &rms, vDSP_Length(Self.windowSize))

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
        // Mean POWER, not mean magnitude. A band is scored by the sum of its
        // squares because squaring is what keeps a few strong bins from being
        // averaged into irrelevance by the quiet ones around them: the treble
        // band is ~155 bins wide and the bass band is ~7, so on a plain mean a
        // pad occupying two mid bins moved the mid average by almost nothing
        // and read as silence while the kick read 0.39.
        func bandPower(_ bins: Range<Int>) -> Float {
            var sum: Float = 0
            magnitudes.withUnsafeBufferPointer { mp in
                vDSP_svesq(mp.baseAddress! + bins.lowerBound, 1, &sum,
                           vDSP_Length(bins.count))
            }
            return sum / Float(bins.count)
        }
        var flux: Float = 0
        for i in bassBins.lowerBound..<trebleBins.upperBound {
            flux += max(magnitudes[i] - prevMagnitudes[i], 0)
        }
        swap(&magnitudes, &prevMagnitudes)

        var raw = SIMD4<Float>(bandPower(bassBins), bandPower(midBins),
                               bandPower(trebleBins), flux)

        let dt = Float(Self.hop) / sampleRate

        // The gate first, and on true RMS. A full-scale sine is −3dBFS, a
        // 0.005-amplitude one is −49dBFS, and a silent room's hiss is far
        // below −60 — so this is a floor under the noise rather than a cliff
        // under the music.
        if 20 * log10(max(rms, 1e-9)) < Self.gateDB {
            // Release toward silence rather than snapping: the gate closing
            // between two phrases must not chop the field.
            envelope.advance(toward: .zero, dt: dt)
            let quiet = envelope.value
            lock.withLock { $0 = quiet }
            return
        }

        // How loud the room is, above its own quiet level.
        let dB = 20 * log10(max(rms, 1e-9))
        let track = 1 - exp(-dt / (dB < floorDB ? Self.floorFallTau
                                                : Self.floorRiseTau))
        floorDB = min(max(floorDB + (dB - floorDB) * track,
                          Self.floorFloorDB), Self.floorCeilDB)
        let level = min(max((dB - floorDB) / Self.dynamicRange, 0), 1)

        // …and how that loudness is distributed. Shares rather than levels, so
        // the spectrum's shape is what separates the bands and the absolute
        // measurement is what says whether anything is playing at all.
        let total = raw.x + raw.y + raw.z
        if total > 1e-12 {
            raw.x = level * min(raw.x / total * Self.shareGain, 1)
            raw.y = level * min(raw.y / total * Self.shareGain, 1)
            raw.z = level * min(raw.z / total * Self.shareGain, 1)
        } else {
            raw.x = 0; raw.y = 0; raw.z = 0
        }

        // The onset is a flux — how much the spectrum CHANGED — so it is
        // scaled by the same loudness rather than by its own history. A quiet
        // room's jitter is a large relative change and a meaningless absolute
        // one, which is what pinned the old peak-normalised onset at 0.92 in
        // an empty room.
        raw.w = level * min(raw.w / max(total, 1e-12) * 0.5, 1)

        envelope.advance(toward: raw, dt: dt)
        let value = envelope.value
        lock.withLock { $0 = value }
    }
}
