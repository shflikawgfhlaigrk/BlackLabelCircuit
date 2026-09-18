// SpeechLeveler: the spoken-word lane — de-hum, de-noise, adaptive level, normalize, true-peak limit.
//
// SS-23. UNRELEASED: this lane is gated OFF by default and nothing in the app,
// the site, or the pricing reaches it. It exists so the DSP is built and proven
// while productization stays behind the founder's GO. Do not wire it to UI,
// copy, or checkout without that GO.
//
// Music mastering wants to keep a performance's dynamics. Speech wants the
// opposite: a listener in a car should hear the quiet aside and the loud laugh
// at the same level. So this lane *reduces* loudness variance on purpose, then
// parks the result on a delivery target (-16 LUFS podcast / -19 LUFS voice-alt).
//
// Every number this lane reports is measured off the sample arrays with the same
// BS.1770 K-weighting the music path uses (LoudnessMeter.kWeightingCoeffs) — no
// estimates, no placeholders. Deterministic: same input + target -> same output.
// Local DSP only; this file makes no network calls and reads no bundled audio.

import Foundation
import Accelerate

// MARK: - Feature flag (SS-23 is not shipped)

/// The gate for the whole speech lane. Defaults OFF, and every entry point in
/// this file refuses to run while it is off, so the lane is unreachable from a
/// stock build. Flipping it is a deliberate, in-process act (tests do it); there
/// is no UI, no preference, and no build setting that turns it on for a buyer.
enum SpeechLane {
    /// The out-of-box value. Asserted by the regression suite so a future edit
    /// cannot quietly ship the lane.
    static let defaultEnabled = false

    private static var _enabled: Bool = SpeechLane.defaultEnabled

    static var isEnabled: Bool { _enabled }

    /// Enable/disable the lane in-process. Intentionally not persisted.
    static func setEnabled(_ on: Bool) { _enabled = on }
}

// MARK: - Targets

/// A spoken-word delivery target. The LUFS figures are the platform-standard
/// speech levels; the ceiling leaves the headroom lossy codecs need.
struct SpeechTarget: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var targetLUFS: Double      // integrated delivery loudness
    var truePeakDBTP: Double    // hard ceiling — never exceeded
    var highPassHz: Double      // rumble / plosive / desk-thump cleanup
    var presenceDB: Double      // gentle intelligibility lift around 3 kHz
    var levelerStrength: Double // 0 = off, 1 = flatten every syllable to target
}

enum SpeechTargets {
    /// Podcast: the -16 LUFS spoken-word convention.
    static let podcast = SpeechTarget(name: "Podcast", targetLUFS: -16.0, truePeakDBTP: -1.0,
                                      highPassHz: 80, presenceDB: 1.5, levelerStrength: 0.85)

    /// Voice (alt): the quieter -19 LUFS delivery for platforms that normalize lower.
    static let voiceAlt = SpeechTarget(name: "Voice (alt)", targetLUFS: -19.0, truePeakDBTP: -1.0,
                                       highPassHz: 80, presenceDB: 1.0, levelerStrength: 0.85)

    static let all: [SpeechTarget] = [podcast, voiceAlt]
}

// MARK: - Reports (what the lane shows its work with)

struct HumReport: Equatable {
    var detected: Bool
    var fundamentalHz: Double     // 50 or 60, whichever was actually present
    var beforeDBFS: Double        // measured level of the hum tone before the notch
    var afterDBFS: Double         // ...and after
    var reductionDB: Double       // before - after, measured, not claimed
    static let empty = HumReport(detected: false, fundamentalHz: 0, beforeDBFS: -200,
                                 afterDBFS: -200, reductionDB: 0)
}

struct NoiseReport: Equatable {
    var engaged: Bool
    var floorDBFS: Double         // measured noise floor (10th-percentile block RMS)
    var thresholdDBFS: Double     // where downward expansion starts
    var pauseBeforeDBFS: Double   // level of the between-words pauses before the gate
    var pauseAfterDBFS: Double    // ...and after
    var reductionDB: Double       // before - after, in the pauses
    static let empty = NoiseReport(engaged: false, floorDBFS: -200, thresholdDBFS: -200,
                                   pauseBeforeDBFS: -200, pauseAfterDBFS: -200, reductionDB: 0)
}

/// The finished speech master plus everything needed to explain it.
struct SpeechResult {
    var output: AudioSignal
    var target: SpeechTarget
    var before: LoudnessResult
    var after: LoudnessResult
    var inputRangeLU: Double      // loudness spread of the input, speech-gated
    var outputRangeLU: Double     // ...and of the output. Lower = more even.
    var rangeReductionLU: Double  // inputRange - outputRange
    var hum: HumReport
    var noise: NoiseReport
    var limiterGRdB: Double
    var maxBoostDB: Double        // most the leveler lifted a quiet passage
    var maxCutDB: Double          // most it held a loud one back
    var notes: [String]           // plain-English "what changed and why"
}

// MARK: - Speech loudness measurement

/// Momentary-loudness primitives, shared by the lane and by anything that wants
/// to check the lane's work independently (the regression suite measures the
/// input and the output with these same functions rather than trusting a
/// self-reported number).
enum SpeechLoudness {

    static let blockMs: Double = 400
    static let hopMs: Double = 100

    /// K-weighted momentary loudness (LUFS) for every 400 ms block, hopped 100 ms.
    /// This is the BS.1770 block-loudness formula, just at speech time-scale.
    static func momentaryLUFS(_ s: AudioSignal, blockMs: Double = SpeechLoudness.blockMs,
                              hopMs: Double = SpeechLoudness.hopMs) -> [Double] {
        let sr = s.sampleRate > 0 ? s.sampleRate : 44100
        let n = s.frameCount
        let ch = s.channelCount
        guard n > 0, ch > 0 else { return [] }

        let block = max(1, Int(sr * blockMs / 1000.0))
        let hop = max(1, Int(sr * hopMs / 1000.0))
        guard n >= block else { return [] }

        // K-weight each channel once, then read blocks off the weighted signal.
        let (preC, rlbC) = LoudnessMeter.kWeightingCoeffs(sampleRate: sr)
        var weighted = [[Double]](repeating: [Double](repeating: 0, count: n), count: ch)
        for c in 0..<ch {
            let pre = Biquad(preC), rlb = Biquad(rlbC)
            pre.reset(); rlb.reset()
            for i in 0..<n {
                weighted[c][i] = rlb.process(pre.process(Double(s.channels[c][i])))
            }
        }

        var out: [Double] = []
        var start = 0
        while start + block <= n {
            var sum = 0.0
            for c in 0..<ch {
                var ms = 0.0
                for i in start..<(start + block) {
                    let v = weighted[c][i]
                    ms += v * v
                }
                ms /= Double(block)
                sum += channelWeight(c) * ms       // G_c per BS.1770 (1.0 for L/R)
            }
            out.append(sum > 0 ? (-0.691 + 10.0 * log10(sum)) : -200.0)
            start += hop
        }
        return out
    }

    // Voice-activity detection, at a much finer grid than the loudness blocks.
    static let vadFrameMs: Double = 50
    static let vadHopMs: Double = 10
    static let vadHangoverMs: Double = 60

    /// Per-10 ms speech-presence, plus the room floor it was measured against.
    ///
    /// The floor is the 10th percentile of frame level — what the mic hears when
    /// nobody is talking. A frame is speech if it clears that floor by 8 dB. The
    /// hangover then bridges the dips *inside* a word (the gap between syllables
    /// is not a pause), so a spoken phrase reads as one continuous region.
    static func presenceFrames(_ s: AudioSignal) -> (present: [Bool], floorDBFS: Double) {
        let sr = s.sampleRate > 0 ? s.sampleRate : 44100

        // The detector is high-passed hard before anything is measured off it.
        // A 50/60 Hz ground-loop buzz is not speech, but it is LOUD: left in, it
        // becomes the "floor", which drags the gate up above a quiet aside and
        // makes the VAD deaf to exactly the passages the leveler exists to rescue.
        // One 80 Hz biquad is not enough — it is only ~6 dB down at 60 Hz. Two
        // cascaded at 150 Hz put mains hum ~32 dB down while the speech harmonics
        // (a voice's 2nd partial and up) pass essentially untouched. Detection does
        // not need the fundamental; it needs to not be lied to.
        let raw = monoSum(s)
        var mono = [Float](repeating: 0, count: raw.count)
        let hpC = BiquadCoeffs.make(.highPass, freq: 150, sampleRate: sr, q: 0.707)
        let hp1 = Biquad(hpC), hp2 = Biquad(hpC)
        hp1.reset(); hp2.reset()
        for i in 0..<raw.count {
            mono[i] = Float(hp2.process(hp1.process(Double(raw[i]))))
        }

        let n = mono.count
        let frame = max(1, Int(sr * vadFrameMs / 1000.0))
        let hop = max(1, Int(sr * vadHopMs / 1000.0))
        guard n >= frame else { return ([], -200) }

        var levels: [Double] = []
        var start = 0
        while start + frame <= n {
            var ms = 0.0
            for i in start..<(start + frame) { let v = Double(mono[i]); ms += v * v }
            let rms = (ms / Double(frame)).squareRoot()
            levels.append(rms > 0 ? 20.0 * log10(rms) : -200.0)
            start += hop
        }
        guard levels.count >= 2 else { return ([], -200) }

        let floorDB = percentile(levels.sorted(), 0.10)
        let threshold = max(-90.0, floorDB + 8.0)
        var present = levels.map { $0 > threshold }

        // Hangover: dilate by ±60 ms so syllable troughs do not read as silence.
        let span = max(1, Int(vadHangoverMs / vadHopMs))
        let seed = present
        for i in 0..<present.count where !seed[i] {
            let lo = max(0, i - span), hi = min(seed.count - 1, i + span)
            for j in lo...hi where seed[j] { present[i] = true; break }
        }
        return (present, floorDB)
    }

    /// Classify each 400 ms loudness block against the VAD.
    ///
    /// `voiced` = every frame in the block is speech. `pause` = no frame is.
    /// Blocks that STRADDLE a boundary are neither, and that distinction is the
    /// whole point: a 400 ms window half-filled with silence reads quiet no
    /// matter how loud the talker was, so letting straddle blocks into the
    /// spread metric would measure window overlap instead of the voice — and no
    /// leveler on earth could move that number.
    static func blockClasses(_ s: AudioSignal) -> (voiced: [Bool], pause: [Bool]) {
        let sr = s.sampleRate > 0 ? s.sampleRate : 44100
        let n = s.frameCount
        let block = max(1, Int(sr * blockMs / 1000.0))
        let hop = max(1, Int(sr * hopMs / 1000.0))
        let vadHop = max(1, Int(sr * vadHopMs / 1000.0))
        let (present, _) = presenceFrames(s)
        guard n >= block, !present.isEmpty else { return ([], []) }

        var voiced: [Bool] = []
        var pause: [Bool] = []
        var start = 0
        while start + block <= n {
            let f0 = start / vadHop
            let f1 = min(present.count - 1, (start + block - 1) / vadHop)
            var all = true, none = true
            if f0 <= f1 {
                for f in f0...f1 {
                    if present[f] { none = false } else { all = false }
                }
            }
            voiced.append(all)
            pause.append(none)
            start += hop
        }
        return (voiced, pause)
    }

    /// Loudness spread of the speech, in LU: the 95th minus the 10th percentile
    /// of the fully-voiced blocks. A raw conversational take runs wide; a levelled
    /// one runs narrow. This is the number the leveler is judged on.
    static func rangeLU(_ s: AudioSignal) -> Double {
        rangeLU(s, voiced: blockClasses(s).voiced)
    }

    /// Spread over an EXPLICIT set of speech blocks.
    ///
    /// Before/after comparisons must use this with a mask derived from the INPUT.
    /// Where the speech is, is a fact about the recording, not about what we did
    /// to it — and re-running the VAD on the output would move the goalposts: the
    /// noise expander lowers the room, which lowers the floor the VAD calibrates
    /// against, which admits a different set of blocks. Measure the same blocks
    /// before and after, or the number means nothing.
    static func rangeLU(_ s: AudioSignal, voiced: [Bool]) -> Double {
        let l = momentaryLUFS(s)
        guard !l.isEmpty, voiced.count == l.count else { return 0 }
        let active = zip(l, voiced).filter { $0.1 }.map { $0.0 }.sorted()
        guard active.count >= 2 else { return 0 }
        return percentile(active, 0.95) - percentile(active, 0.10)
    }

    /// Linear-interpolated percentile of a pre-sorted array.
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let pos = clampd(p, 0, 1) * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(lo + 1, sorted.count - 1)
        let frac = pos - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }

    static func monoSum(_ s: AudioSignal) -> [Float] {
        let n = s.frameCount
        let ch = s.channelCount
        guard n > 0, ch > 0 else { return [] }
        if ch == 1 { return s.channels[0] }
        var out = [Float](repeating: 0, count: n)
        for c in 0..<ch {
            let src = s.channels[c]
            for i in 0..<n { out[i] += src[i] }
        }
        let inv = Float(1.0 / Double(ch))
        for i in 0..<n { out[i] *= inv }
        return out
    }

    /// BS.1770 channel weights: L/R = 1.0, surrounds get +1.5 dB. Sunset is
    /// mono/stereo, so this is 1.0 in practice.
    @inline(__always) static func channelWeight(_ c: Int) -> Double {
        return c < 2 ? 1.0 : 1.41
    }
}

// MARK: - The lane

enum SpeechLeveler {

    /// Run the speech chain. Returns `nil` when the lane is disabled — which is
    /// the out-of-box state, so a stock build cannot reach the DSP below.
    static func process(input: AudioSignal,
                        target: SpeechTarget = SpeechTargets.podcast,
                        progress: ((Double, String) -> Void)? = nil) -> SpeechResult? {
        guard SpeechLane.isEnabled else { return nil }
        guard input.frameCount > 0, input.channelCount > 0 else { return nil }

        let sr = input.sampleRate > 0 ? input.sampleRate : 44100
        var notes: [String] = []

        let meter: (AudioSignal) -> LoudnessResult = { sig in
            LoudnessMeter(sampleRate: sig.sampleRate > 0 ? sig.sampleRate : sr,
                          channels: max(1, sig.channelCount)).measure(sig.channels)
        }

        // One VAD pass, off the buyer's raw file, reused by every stage below.
        // Where the speech is (and where the pauses are) is a fact about the
        // recording; re-deriving it after each stage would let our own processing
        // redefine the thing we are measuring against.
        let (speechMask, pauseMask) = SpeechLoudness.blockClasses(input)

        let before = meter(input)
        let inputRange = SpeechLoudness.rangeLU(input, voiced: speechMask)
        progress?(0.1, "Measuring speech")
        notes.append(String(format: "Input: %.1f LUFS, %.1f dBTP, %.1f LU spread across the talk.",
                            before.integratedLUFS, before.truePeakDBTP, inputRange))

        // ---- 1. hum notch (mains buzz from a cheap interface / ground loop) ----
        progress?(0.25, "Hunting mains hum")
        let (deHummed, hum) = removeHum(input, sampleRate: sr)
        if hum.detected {
            notes.append(String(format: "Mains hum at %.0f Hz notched: %.1f dB down (%.1f → %.1f dBFS).",
                                hum.fundamentalHz, hum.reductionDB, hum.beforeDBFS, hum.afterDBFS))
        } else {
            notes.append("No mains hum found — nothing notched.")
        }

        // ---- 2. rumble high-pass -------------------------------------------
        let cleaned = applyBands(deHummed,
                                 bands: [EQBand.highPass(target.highPassHz, 0.707)],
                                 sampleRate: sr)
        notes.append(String(format: "High-passed at %.0f Hz — desk thumps and room rumble carry no speech.",
                            target.highPassHz))

        // ---- 3. noise floor: downward expansion in the pauses ---------------
        progress?(0.45, "Reducing room noise")
        let (denoised, noise) = reduceNoise(cleaned, sampleRate: sr, pauseMask: pauseMask)
        if noise.engaged {
            notes.append(String(format: "Room noise: floor measured at %.1f dBFS; pauses pulled down %.1f dB (%.1f → %.1f dBFS).",
                                noise.floorDBFS, noise.reductionDB, noise.pauseBeforeDBFS, noise.pauseAfterDBFS))
        } else {
            notes.append(String(format: "Room noise floor at %.1f dBFS is already clean — expander left off.",
                                noise.floorDBFS))
        }

        // ---- 4. the adaptive leveler ---------------------------------------
        progress?(0.6, "Levelling")
        let (levelled, maxBoost, maxCut) = level(denoised, target: target, sampleRate: sr,
                                                 voiced: speechMask)
        notes.append(String(format: "Adaptive leveler at %.0f%% strength: lifted quiet passages up to %.1f dB, held loud ones back up to %.1f dB.",
                            target.levelerStrength * 100, maxBoost, maxCut))

        // ---- 5. presence ----------------------------------------------------
        let voiced = target.presenceDB > 0
            ? applyBands(levelled, bands: [EQBand.peak(3000, target.presenceDB, 0.8)], sampleRate: sr)
            : levelled
        if target.presenceDB > 0 {
            notes.append(String(format: "Presence: %+.1f dB at 3 kHz for consonant clarity on phone speakers.",
                                target.presenceDB))
        }

        // ---- 6. normalize to target + true-peak limit ------------------------
        progress?(0.8, "Normalizing to target")
        let ceiling = target.truePeakDBTP
        var out = voiced
        var limiterGR = 0.0

        // Converge on the delivery target: the limiter can shave a little loudness
        // off, so measure what actually came out and correct, rather than assuming.
        for _ in 0..<3 {
            let cur = meter(out).integratedLUFS
            guard cur > -70 else { break }
            let delta = target.targetLUFS - cur
            if abs(delta) < 0.05 { break }
            out = applyGainDB(out, db: delta)
            let limiter = Limiter(settings: LimiterSettings(ceilingDBTP: ceiling,
                                                            lookaheadMs: 2, releaseMs: 120),
                                  sampleRate: sr)
            out = limiter.process(out)
            limiterGR = limiter.lastGainReductionDB
        }

        // The ceiling is a promise, not a best effort. Trim if the limiter's
        // estimate and the true-peak meter disagree.
        let tp = meter(out).truePeakDBTP
        if tp > ceiling {
            out = applyGainDB(out, db: ceiling - tp)
            notes.append(String(format: "True-peak safety trim: %.1f dB to guarantee the %.1f dBTP ceiling.",
                                ceiling - tp, ceiling))
        }

        let after = meter(out)
        let outputRange = SpeechLoudness.rangeLU(out, voiced: speechMask)
        progress?(1.0, "Done")

        notes.append(String(format: "Delivered %@ at %.1f LUFS / %.1f dBTP; spread tightened %.1f → %.1f LU (%.1f LU steadier). Limiter worked %.1f dB.",
                            target.name, after.integratedLUFS, after.truePeakDBTP,
                            inputRange, outputRange, inputRange - outputRange, limiterGR))

        return SpeechResult(output: out, target: target, before: before, after: after,
                            inputRangeLU: inputRange, outputRangeLU: outputRange,
                            rangeReductionLU: inputRange - outputRange,
                            hum: hum, noise: noise, limiterGRdB: limiterGR,
                            maxBoostDB: maxBoost, maxCutDB: maxCut, notes: notes)
    }

    // MARK: - Stage 1: hum

    /// Find mains hum (50 Hz in EU/UK, 60 Hz in NA) and notch it plus its
    /// harmonics. Engages only when a tone is genuinely prominent over its
    /// spectral neighbourhood — a bass note near 60 Hz must not be gutted.
    static func removeHum(_ s: AudioSignal, sampleRate sr: Double) -> (AudioSignal, HumReport) {
        let mono = SpeechLoudness.monoSum(s)
        guard mono.count > Int(sr / 10) else { return (s, .empty) }

        // Prominence = the tone over a nearby non-harmonic reference frequency.
        func prominence(_ f0: Double) -> Double {
            let tone = toneDBFS(mono, freq: f0, sampleRate: sr)
            let ref1 = toneDBFS(mono, freq: f0 * 1.18, sampleRate: sr)
            let ref2 = toneDBFS(mono, freq: f0 * 0.82, sampleRate: sr)
            return tone - max(ref1, ref2)
        }

        let p50 = prominence(50), p60 = prominence(60)
        let f0 = p60 >= p50 ? 60.0 : 50.0
        let prom = max(p50, p60)
        let beforeDB = toneDBFS(mono, freq: f0, sampleRate: sr)

        // Two independent conditions: it must stick out of the spectrum AND be
        // loud enough to matter. Otherwise there is nothing honest to remove.
        guard prom > 6.0, beforeDB > -60.0 else {
            return (s, HumReport(detected: false, fundamentalHz: f0, beforeDBFS: beforeDB,
                                 afterDBFS: beforeDB, reductionDB: 0))
        }

        // Notch the fundamental, plus only those harmonics that are themselves
        // prominent. A blanket harmonic comb would sit on top of real vocal
        // harmonics (a 115 Hz voice has energy at 230, 345, 460 Hz) and gut them.
        var freqs: [Double] = [f0]
        var k = 2.0
        while f0 * k <= 500.0 && f0 * k < sr * 0.45 {
            if prominence(f0 * k) > 6.0 { freqs.append(f0 * k) }
            k += 1
        }

        var out = s
        for f in freqs {
            let c = notchCoeffs(freq: f, q: 25.0, sampleRate: sr)
            for ch in 0..<out.channelCount {
                let b = Biquad(c)
                b.reset()
                for i in 0..<out.channels[ch].count {
                    out.channels[ch][i] = Float(b.process(Double(out.channels[ch][i])))
                }
            }
        }

        let afterDB = toneDBFS(SpeechLoudness.monoSum(out), freq: f0, sampleRate: sr)
        return (out, HumReport(detected: true, fundamentalHz: f0, beforeDBFS: beforeDB,
                               afterDBFS: afterDB, reductionDB: beforeDB - afterDB))
    }

    /// RBJ notch. Kept local so the shared Biquad/EQBand vocabulary the music
    /// path depends on is not widened for this unreleased lane.
    static func notchCoeffs(freq: Double, q: Double, sampleRate sr: Double) -> BiquadCoeffs {
        let w0 = 2.0 * Double.pi * min(freq, sr * 0.49) / sr
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2.0 * max(q, 0.0001))
        let a0 = 1.0 + alpha
        return BiquadCoeffs.raw(b0: 1.0 / a0,
                                b1: (-2.0 * cw) / a0,
                                b2: 1.0 / a0,
                                a1: (-2.0 * cw) / a0,
                                a2: (1.0 - alpha) / a0)
    }

    /// Amplitude of a single frequency, in dBFS — a one-bin DFT (Goertzel-style
    /// quadrature correlation) so hum level is measured, never guessed.
    static func toneDBFS(_ x: [Float], freq: Double, sampleRate sr: Double) -> Double {
        let n = x.count
        guard n > 0, freq > 0, freq < sr / 2 else { return -200 }
        let w = 2.0 * Double.pi * freq / sr
        var re = 0.0, im = 0.0
        for i in 0..<n {
            let v = Double(x[i])
            re += v * cos(w * Double(i))
            im += v * sin(w * Double(i))
        }
        let amp = 2.0 * (re * re + im * im).squareRoot() / Double(n)
        return amp > 0 ? 20.0 * log10(amp) : -200
    }

    // MARK: - Stage 2: noise

    /// Downward expansion below the measured noise floor. This is a gate with a
    /// soft knee, not spectral subtraction: it cannot invent detail, so it cannot
    /// produce the watery artefacts that make a voice sound processed.
    static func reduceNoise(_ s: AudioSignal, sampleRate sr: Double,
                            pauseMask: [Bool]) -> (AudioSignal, NoiseReport) {
        let n = s.frameCount
        let ch = s.channelCount
        guard n > 0, ch > 0 else { return (s, .empty) }

        let mono = SpeechLoudness.monoSum(s)
        let block = max(1, Int(sr * SpeechLoudness.blockMs / 1000.0))
        let hop = max(1, Int(sr * SpeechLoudness.hopMs / 1000.0))
        guard n >= block else { return (s, .empty) }

        let blockRMS = blockLevels(mono, block: block, hop: hop)
        guard blockRMS.count >= 2 else { return (s, .empty) }

        // Pauses = blocks with NO speech in them at all (from the input-derived
        // VAD). Reading "before" off a straddle block would mix a word into the
        // room-tone measurement.
        guard pauseMask.count == blockRMS.count else { return (s, .empty) }

        // The floor is the 10th percentile of block RMS — what the room sounds
        // like when nobody is talking.
        let floorDB = SpeechLoudness.percentile(blockRMS.sorted(), 0.10)
        let pauseBefore = meanDB(blockRMS, where: pauseMask)

        // Nothing worth gating: a genuinely quiet room stays untouched.
        guard floorDB > -75.0 else {
            return (s, NoiseReport(engaged: false, floorDBFS: floorDB, thresholdDBFS: floorDB + 12,
                                   pauseBeforeDBFS: pauseBefore, pauseAfterDBFS: pauseBefore,
                                   reductionDB: 0))
        }

        let threshold = floorDB + 12.0    // start expanding under this
        let ratio = 4.0                   // 4:1 downward — a gate, softened
        let maxAtten = 18.0               // never scrub a pause to digital black

        // The detector has to be able to FALL to the room floor inside a real pause.
        // A sentence peaks ~40 dB above the room, and this envelope decays in the
        // linear domain, so a 140 ms release would need ~0.7 s to cover that drop —
        // longer than most pauses. The gate would then spend every pause still
        // coasting down from the last word and never actually engage. 30 ms covers
        // the same drop in ~150 ms.
        let envRel = smooth(ms: 30, sr: sr)
        // Gain: open fast so a word's onset is never chopped, close slowly so the
        // room does not chatter.
        let openC = smooth(ms: 5, sr: sr)
        let closeC = smooth(ms: 80, sr: sr)

        var out = s
        var env = 0.0
        var gainEnv = 0.0                 // dB, <= 0
        for i in 0..<n {
            let x = abs(Double(mono[i]))
            env = x > env ? x : (env * envRel + x * (1 - envRel))
            let envDB = env > 0 ? 20.0 * log10(env) : -200.0

            var targetGain = 0.0
            if envDB < threshold {
                let under = threshold - envDB
                targetGain = -min(maxAtten, under * (1.0 - 1.0 / ratio))
            }
            let c = targetGain > gainEnv ? openC : closeC
            gainEnv = gainEnv * c + targetGain * (1 - c)

            let g = Float(dbToGain(gainEnv))
            for c2 in 0..<ch { out.channels[c2][i] *= g }
        }

        // Measure what the gate actually did to those same pause blocks.
        let outRMS = blockLevels(SpeechLoudness.monoSum(out), block: block, hop: hop)
        let pauseAfter = meanDB(outRMS, where: pauseMask)

        return (out, NoiseReport(engaged: true, floorDBFS: floorDB, thresholdDBFS: threshold,
                                 pauseBeforeDBFS: pauseBefore, pauseAfterDBFS: pauseAfter,
                                 reductionDB: pauseBefore - pauseAfter))
    }

    // MARK: - Stage 3: the leveler

    /// Ride the gain so every spoken passage lands near the target. Works on the
    /// momentary-loudness grid, corrects each speech-active block toward the
    /// target by `strength`, smooths the gain curve, and holds gain through the
    /// pauses so room tone is never lifted.
    static func level(_ s: AudioSignal, target: SpeechTarget,
                      sampleRate sr: Double, voiced mask: [Bool]) -> (AudioSignal, Double, Double) {
        let n = s.frameCount
        guard n > 0 else { return (s, 0, 0) }

        // Correct only off blocks that are wholly speech. A straddle block reads
        // quiet because half of it is silence, not because the talker dropped —
        // correcting off one would ride the gain up into the pause.
        let loud = SpeechLoudness.momentaryLUFS(s)
        guard loud.count >= 2, mask.count == loud.count else { return (s, 0, 0) }

        // A quiet aside can sit ~17 LU under a projected sentence, so a 12 dB
        // boost ceiling would leave it short of the target no matter the strength.
        let maxBoostDB = 18.0
        let maxCutDB = 12.0
        let strength = clampd(target.levelerStrength, 0, 1)

        // Desired gain per speech block: pull it toward the target.
        var perBlock = [Double?](repeating: nil, count: loud.count)
        for i in 0..<loud.count where mask[i] {
            perBlock[i] = clampd((target.targetLUFS - loud[i]) * strength, -maxCutDB, maxBoostDB)
        }

        // Gain is solved PER SENTENCE, then ramped between sentences across the
        // pause. Two things are wrong with the obvious alternatives, and this
        // avoids both:
        //
        //  - Smooth the whole curve in one pass and a big boost queued up for a
        //    quiet line bleeds BACKWARD into the tail of the loud line before it,
        //    lifting the loudest blocks and widening the very spread we are closing.
        //  - Hold the previous sentence's gain through the pause and every quiet
        //    line spends its first few hundred ms climbing, so its opening is
        //    under-levelled.
        //
        // Solving each run against only its own blocks cannot bleed across a
        // boundary; ramping across the gap means the ride is already in place when
        // the talker comes back in. The gain only ever moves during silence the
        // expander has already pulled down.
        let hopSec = SpeechLoudness.hopMs / 1000.0
        let c = exp(-hopSec / 0.18)     // 180 ms, applied both directions

        var smoothed = [Double](repeating: 0, count: loud.count)
        var runs: [(start: Int, end: Int)] = []
        var i = 0
        while i < loud.count {
            guard mask[i] else { i += 1; continue }
            let start = i
            while i < loud.count, mask[i] { i += 1 }
            runs.append((start, i - 1))
        }
        guard !runs.isEmpty else { return (s, 0, 0) }

        // Within a sentence: zero-phase one-pole, so the ride breathes but does not lag.
        for run in runs {
            var g = perBlock[run.start] ?? 0
            for k in run.start...run.end {
                g = g * c + (perBlock[k] ?? g) * (1 - c)
                smoothed[k] = g
            }
            var h = smoothed[run.end]
            for k in stride(from: run.end, through: run.start, by: -1) {
                h = h * c + smoothed[k] * (1 - c)
                smoothed[k] = h
            }
        }

        // Between sentences: ramp linearly across the gap. Flat before the first
        // sentence and after the last.
        for k in 0..<runs[0].start { smoothed[k] = smoothed[runs[0].start] }
        for k in (runs[runs.count - 1].end + 1)..<loud.count {
            smoothed[k] = smoothed[runs[runs.count - 1].end]
        }
        for r in 1..<runs.count {
            let a = runs[r - 1].end, b = runs[r].start
            guard b > a + 1 else { continue }
            let ga = smoothed[a], gb = smoothed[b]
            for k in (a + 1)..<b {
                let t = Double(k - a) / Double(b - a)
                smoothed[k] = ga + (gb - ga) * t
            }
        }

        // Per-sample gain: linear interpolation between block centres.
        let block = max(1, Int(sr * SpeechLoudness.blockMs / 1000.0))
        let hop = max(1, Int(sr * SpeechLoudness.hopMs / 1000.0))
        let centre: (Int) -> Double = { Double($0 * hop + block / 2) }

        var out = s
        var maxBoost = 0.0, maxCut = 0.0
        for i in 0..<n {
            let x = Double(i)
            // Which pair of block centres does this sample sit between?
            var k = Int((x - Double(block / 2)) / Double(hop))
            k = max(0, min(k, smoothed.count - 1))
            let k2 = min(k + 1, smoothed.count - 1)
            let c1 = centre(k), c2 = centre(k2)
            let t = c2 > c1 ? clampd((x - c1) / (c2 - c1), 0, 1) : 0
            let gdb = smoothed[k] + (smoothed[k2] - smoothed[k]) * t

            maxBoost = max(maxBoost, gdb)
            maxCut = max(maxCut, -gdb)

            let lin = Float(dbToGain(gdb))
            for c in 0..<out.channelCount { out.channels[c][i] *= lin }
        }

        return (out, maxBoost, maxCut)
    }

    // MARK: - Shared helpers (local to the lane)

    static func applyBands(_ s: AudioSignal, bands: [EQBand], sampleRate sr: Double) -> AudioSignal {
        guard !bands.isEmpty else { return s }
        var out = s
        for band in bands where band.enabled {
            let c = BiquadCoeffs.make(band.kind, freq: band.freq, sampleRate: sr,
                                      q: band.q, gainDB: band.gainDB)
            for ch in 0..<out.channelCount {
                let b = Biquad(c)
                b.reset()
                for i in 0..<out.channels[ch].count {
                    out.channels[ch][i] = Float(b.process(Double(out.channels[ch][i])))
                }
            }
        }
        return out
    }

    static func applyGainDB(_ s: AudioSignal, db: Double) -> AudioSignal {
        let g = Float(dbToGain(clampd(db, -40, 40)))
        var out = s
        for c in 0..<out.channelCount {
            for i in 0..<out.channels[c].count { out.channels[c][i] *= g }
        }
        return out
    }

    /// Per-block RMS (dBFS) of a mono detector, on the loudness grid.
    static func blockLevels(_ mono: [Float], block: Int, hop: Int) -> [Double] {
        let n = mono.count
        guard n >= block, block > 0, hop > 0 else { return [] }
        var out: [Double] = []
        var start = 0
        while start + block <= n {
            var ms = 0.0
            for i in start..<(start + block) { let v = Double(mono[i]); ms += v * v }
            let rms = (ms / Double(block)).squareRoot()
            out.append(rms > 0 ? 20.0 * log10(rms) : -200)
            start += hop
        }
        return out
    }

    /// Energy-mean level (dB) of the blocks the mask selects.
    static func meanDB(_ blocks: [Double], where mask: [Bool]) -> Double {
        var acc = 0.0
        var count = 0
        for i in 0..<min(blocks.count, mask.count) where mask[i] {
            acc += pow(10.0, blocks[i] / 10.0)
            count += 1
        }
        guard count > 0 else { return -200 }
        return 10.0 * log10(acc / Double(count))
    }

    @inline(__always) static func smooth(ms: Double, sr: Double) -> Double {
        exp(-1.0 / (max(0.01, ms) * 0.001 * sr))
    }
}

// File-private numeric helpers (the music path keeps its own copies; this lane
// stays self-contained so it can be lifted out wholesale if SS-23 is cut).
@inline(__always) private func clampd(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(x, lo), hi)
}
@inline(__always) private func dbToGain(_ db: Double) -> Double { pow(10.0, db / 20.0) }
