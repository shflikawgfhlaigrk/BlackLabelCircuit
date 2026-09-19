#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MasteringEngine: the offline mastering chain — measure, match/tonal-EQ, multiband glue, image, saturate, loudness-normalize + true-peak limit, dither.

// This is the product's brain. Every number in the result traces back to real
// DSP over the sample arrays or to an explainable target (a reference match or a
// hand-tuned GenreTarget). No placeholders, no fabricated meters. Deterministic:
// same input + settings -> same master, byte for byte.

import Foundation

/// The finished master plus everything the UI needs to explain and prove it.
struct MasterResult {
    var output: AudioSignal
    var before: LoudnessResult
    var after: LoudnessResult
    var appliedEQ: [EQBand]                 // the corrective/tonal curve actually applied
    var multibandGRdB: Double               // peak gain reduction from the glue stage
    var limiterGRdB: Double                 // peak gain reduction from the brickwall limiter
    var spectrumBeforeDB: [Float]           // third-octave bands, input
    var spectrumAfterDB: [Float]            // third-octave bands, output
    var eqCurveDB: [Float]                   // ParametricEQ response of the applied bands
    var match: MatchResult                   // the reference/genre target that drove the chain
    var platformReport: [(platform: String, willPlayAtLUFS: Double, action: String)]
    var notes: [String]                      // plain-English "what changed and why"
    // --- club/tech-house additions (all measured; defaults keep old call sites valid) ---
    var softClip: SoftClipResult = .bypassed // pre-limiter soft-clip stage read-out
    var lowEnd: LowEndReport = .empty        // measured low-end clarity of the buyer's input
    var crest: CrestReport = .empty          // punch: input-vs-output crest factor
    var psr: PSRReport = .empty              // over-limit read: true-peak vs short-term LUFS
}

enum MasteringEngine {

    // MARK: - Public entry point

    /// Master `input`, optionally imposing `reference`'s tonal balance/loudness, targeting `platform`.
    /// `genre` supplies the tonal target when no reference is given. Reports progress 0..1 with a label.
    static func master(input: AudioSignal,
                       reference: AudioSignal?,
                       genre: GenreTarget,
                       platform: PlatformTarget,
                       intensity: MasterIntensity = .balanced,
                       loudnessOverrideLUFS: Double? = nil,
                       userEQ: [EQBand] = [],
                       softClip: SoftClipSettings = .bypassed,
                       ceilingOverrideDBTP: Double? = nil,
                       dna: ReferenceDNA? = nil,
                       progress: ((Double, String) -> Void)? = nil) -> MasterResult {

        let sr = input.sampleRate > 0 ? input.sampleRate : 44100
        let chCount = max(1, input.channelCount)

        // A reusable loudness meter closure (fresh state per signal — measurement is stateless to the caller).
        let meter: (AudioSignal) -> LoudnessResult = { sig in
            let m = LoudnessMeter(sampleRate: sig.sampleRate > 0 ? sig.sampleRate : sr,
                                  channels: max(1, sig.channelCount))
            return m.measure(sig.channels)
        }

        // Guard: empty input -> return a trivially-valid, honest result rather than crashing.
        guard input.frameCount > 0, input.channelCount > 0 else {
            let empty = meter(input)
            let flat = ReferenceMatcher.fromGenre(genre)
            return MasterResult(output: input, before: empty, after: empty, appliedEQ: [],
                                multibandGRdB: 0, limiterGRdB: 0,
                                spectrumBeforeDB: [], spectrumAfterDB: [],
                                eqCurveDB: ParametricEQ.responseDB(flat.bands, sampleRate: sr),
                                match: flat, platformReport: [],
                                notes: ["Empty input — nothing to master."])
        }

        progress?(0.02, "Analyzing input")

        // ---- 1. measure BEFORE + spectrum ---------------------------------
        let before = meter(input)
        let analyzer = FFTAnalyzer(size: 4096)
        let monoIn = sumToMono(input)
        let spectrumBeforeDB = FreqBands.toBandsDB(power: analyzer.averagePower(monoIn),
                                                   sampleRate: sr, fftSize: analyzer.size)

        progress?(0.12, "Building target")

        // ---- 2. build the target (saved DNA > live reference > genre curve) --
        let match: MatchResult
        if let dna = dna, !dna.fingerprint.isEmpty {
            // Reusable Reference-DNA path (SS-24): re-apply a saved reference's DNA.
            match = ReferenceMatcher.matchDNA(target: input, dna: dna, targetLUFS: nil, meter: meter)
        } else if let ref = reference, ref.frameCount > 0, ref.channelCount > 0 {
            match = ReferenceMatcher.match(target: input, reference: ref, targetLUFS: nil, meter: meter)
        } else {
            match = ReferenceMatcher.fromGenre(genre)
        }
        // The user's 5-band tone control rides on top of the matched/genre curve.
        let displayBands = match.bands + userEQ
        let eqCurveDB = ParametricEQ.responseDB(displayBands, sampleRate: sr)

        // Cooperative cancellation: the app cancels a render by cancelling the worker task;
        // the chain bails at the next stage boundary instead of burning CPU to completion.
        // The bail output is the untouched input and its note says so — a cancelled caller
        // discards it, and outside a task Task.isCancelled is always false (CLI/tests unaffected).
        let cancelledResult: () -> MasterResult = {
            MasterResult(output: input, before: before, after: before, appliedEQ: [],
                         multibandGRdB: 0, limiterGRdB: 0,
                         spectrumBeforeDB: spectrumBeforeDB, spectrumAfterDB: spectrumBeforeDB,
                         eqCurveDB: eqCurveDB, match: match, platformReport: [],
                         notes: ["Cancelled before completion — input returned unchanged."])
        }

        var notes: [String] = []
        notes.append(contentsOf: match.notes)
        notes.append(String(format: "Input: %.1f LUFS integrated, %.1f dBTP peak.",
                            before.integratedLUFS, before.truePeakDBTP))

        // ---- 3. corrective / tonal EQ (+ the user's 5-band tone control) ----
        if Task.isCancelled { return cancelledResult() }
        progress?(0.22, "Applying tonal EQ")
        var sig = applyEQ(input, bands: match.bands, sampleRate: sr)
        if !userEQ.isEmpty {
            sig = applyEQ(sig, bands: userEQ, sampleRate: sr)
            notes.append("Applied your 5-band tone control on top of the match.")
        }

        // ---- 4. multiband compression (gentle EDM glue) --------------------
        if Task.isCancelled { return cancelledResult() }
        progress?(0.42, "Multiband glue")
        let (peakDB, rmsDB) = monoLevels(sig)
        let bandSettings = glueSettings(peakDB: peakDB, rmsDB: rmsDB)
        let mbc = MultibandCompressor(sampleRate: sr, crossovers: [120, 2500])
        sig = mbc.process(sig, band: bandSettings)
        let multibandGRdB = mbc.lastGainReductionDB
        notes.append(String(format: "EDM bus glue: gentle 2:1 multiband compression, up to %.1f dB gain reduction for cohesion.", multibandGRdB))

        // ---- 5. stereo imaging ---------------------------------------------
        if Task.isCancelled { return cancelledResult() }
        progress?(0.58, "Stereo imaging")
        if input.channelCount >= 2 {
            sig = StereoImager().process(sig, width: match.stereoWidth,
                                         monoBelowHz: match.lowMonoHz, sampleRate: sr)
        }

        // ---- 6. subtle parallel saturation (glue + perceived loudness) -----
        if Task.isCancelled { return cancelledResult() }
        progress?(0.68, "Saturation")
        sig = saturate(sig, drive: 1.2, mix: intensity.saturationMix)

        // ---- 7. loudness normalize + true-peak limit -----------------------
        if Task.isCancelled { return cancelledResult() }
        progress?(0.80, "Loudness + limiting")
        // Loudness is the artist's call, driven by the Intensity control (or an explicit
        // override), NOT silently pinned to the platform — you master to your loudness and
        // let each platform normalize on playback (see the platform report). The platform
        // still owns the true-peak ceiling, so every intensity stays clip-safe.
        // A live reference OR a saved Reference-DNA both carry the reference's own loudness
        // target off the match; either one drives loudness to that target (not the Intensity).
        let hasDNA = (dna?.fingerprint.isEmpty == false)
        let matchedReference = (reference != nil || hasDNA) && match.targetLUFS.isFinite
        let desiredLUFS = clampd(loudnessOverrideLUFS ?? (matchedReference ? match.targetLUFS : intensity.targetLUFS), -24.0, -3.0)
        // Platform + genre own the true-peak ceiling; a loudness profile may tighten it further.
        var ceiling = min(platform.truePeakDBTP, match.truePeakDBTP)
        if let co = ceilingOverrideDBTP { ceiling = min(ceiling, co) }

        let pre = sig                                   // pre-gain, pre-limit reference for the retry pass
        let curLUFS = meter(pre).integratedLUFS
        var gainDB = clampd(desiredLUFS - curLUFS, -24.0, 24.0)

        // Pre-limiter soft-clip stage (… > soft clip > limiter > ceiling). Bypassed by
        // default → out-of-box master is byte-for-byte build 2; engaged, it shaves the
        // tallest transients so the limiter pumps less (club/tech-house punch).
        let clipper = SoftClipper(settings: softClip, sampleRate: sr)
        let limiter = Limiter(settings: LimiterSettings(ceilingDBTP: ceiling, lookaheadMs: 2,
                                                        releaseMs: intensity.limiterReleaseMs),
                              sampleRate: sr)
        var gained = applyGainDB(pre, db: gainDB)
        var clipped = clipper.process(gained)
        var limited = limiter.process(clipped)
        var afterLUFS = meter(limited).integratedLUFS

        // One corrective pass: limiting + program-dependent loudness rarely lands exactly.
        if abs(afterLUFS - desiredLUFS) > 0.5 {
            let delta = clampd(desiredLUFS - afterLUFS, -6.0, 6.0)
            gainDB = clampd(gainDB + delta, -24.0, 24.0)
            gained = applyGainDB(pre, db: gainDB)
            clipped = clipper.process(gained)
            limiter.reset()
            limited = limiter.process(clipped)
            afterLUFS = meter(limited).integratedLUFS
        }
        let softClipResult = clipper.lastResult
        let limiterGRdB = limiter.lastGainReductionDB
        let loudnessSource = matchedReference ? "reference match" : "intensity \(intensity.label)"
        notes.append(String(format: "Loudness target from %@: %.1f LUFS. %+.1f dB gain; limiter %.1f dB at %.1f dBTP ceiling.",
                            loudnessSource, desiredLUFS, gainDB, limiterGRdB, ceiling))
        if softClipResult.enabled {
            notes.append(String(format: "Soft clip before the limiter (%d× oversampled): %.1f dB drive, %.1f dB shaved off peaks (%.1f%% of samples).",
                                softClip.oversample, softClipResult.driveDB, softClipResult.dBClipped, softClipResult.percentClipped))
        }

        // Guaranteed true-peak ceiling. The limiter's estimate can differ slightly from the
        // BS.1770 meter's reconstruction filter; true peak scales linearly with gain, so if
        // anything still pokes over we static-trim by exactly the overshoot. This makes the
        // ceiling a hard promise, not a best-effort — no master leaves clipping.
        let tpCheck = meter(limited).truePeakDBTP
        if tpCheck > ceiling {
            limited = applyGainDB(limited, db: ceiling - tpCheck)
            afterLUFS = meter(limited).integratedLUFS
            notes.append(String(format: "True-peak safety trim: %.1f dB to guarantee the %.1f dBTP ceiling.",
                                ceiling - tpCheck, ceiling))
        }

        // ---- 8. dither to 24-bit + measure AFTER ---------------------------
        if Task.isCancelled { return cancelledResult() }
        progress?(0.94, "Dithering")
        let output = Dither.apply(limited, targetBitDepth: 24)
        let after = meter(output)
        let monoOut = sumToMono(output)
        let spectrumAfterDB = FreqBands.toBandsDB(power: analyzer.averagePower(monoOut),
                                                  sampleRate: sr, fftSize: analyzer.size)
        notes.append(String(format: "Output: %.1f LUFS integrated, %.1f dBTP true peak, %.1f LU range.",
                            after.integratedLUFS, after.truePeakDBTP, after.loudnessRangeLU))
        notes.append("Dithered to 24-bit with noise-shaped TPDF for clean quiet detail.")

        // ---- 9. platform report --------------------------------------------
        progress?(0.98, "Platform report")
        let report = platformReport(masterLUFS: after.integratedLUFS)

        // ---- 10. measured analyses (buyer's own input) ---------------------
        // Low-end clarity is measured on the untouched INPUT (§5.2 — their track only);
        // crest/punch compares that input against the finished master. Both are pure
        // measurement — no prescriptive text, no fabricated numbers.
        let lowEnd = LowEndAnalyzer.analyze(input)
        for f in lowEnd.flags { notes.append("Low-end: " + f) }
        let crest = CrestMeter.measure(input: input, output: output)
        notes.append(String(format: "Punch: input crest %.1f dB → master %.1f dB (%+.1f dB peak-to-RMS).",
                            crest.inputCrestDB, crest.outputCrestDB, crest.deltaDB))
        if crest.inputHeavilyLimited { notes.append(crest.note) }

        // PSR (peak-to-short-term-loudness) — the loudness-aware over-limit read on the finished
        // master. Always stated as measurement; the <8 dB flag is a measured fact, not advice.
        let psr = PunchGate.psr(master: after)
        if psr.hasData { notes.append(psr.note) }

        progress?(1.0, "Done")
        _ = chCount
        return MasterResult(output: output, before: before, after: after,
                            appliedEQ: displayBands, multibandGRdB: multibandGRdB,
                            limiterGRdB: limiterGRdB, spectrumBeforeDB: spectrumBeforeDB,
                            spectrumAfterDB: spectrumAfterDB, eqCurveDB: eqCurveDB,
                            match: match, platformReport: report, notes: notes,
                            softClip: softClipResult, lowEnd: lowEnd, crest: crest, psr: psr)
    }

    // MARK: - Chain stages

    /// Sum all channels to a mono Float buffer (for analysis only). Averaged, clamped.
    private static func sumToMono(_ s: AudioSignal) -> [Float] {
        let n = s.frameCount
        guard n > 0, s.channelCount > 0 else { return [] }
        if s.channelCount == 1 { return s.channels[0] }
        var out = [Float](repeating: 0, count: n)
        let inv = 1.0 / Double(s.channelCount)
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            let m = min(n, src.count)
            for i in 0..<m { out[i] += Float(Double(src[i]) * inv) }
        }
        return out
    }

    /// Run the corrective/tonal EQ over every channel, sample by sample (biquads are stateful per channel).
    private static func applyEQ(_ s: AudioSignal, bands: [EQBand], sampleRate: Double) -> AudioSignal {
        let enabled = bands.filter { $0.enabled }
        guard !enabled.isEmpty else { return s }
        let ch = s.channelCount, n = s.frameCount
        let eq = ParametricEQ(bands: enabled, sampleRate: sampleRate, channels: ch)
        var out = s.channels
        for i in 0..<n {
            for c in 0..<ch {
                out[c][i] = Float(clampd(eq.process(Double(s.channels[c][i]), channel: c), -4.0, 4.0))
            }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    /// Peak and RMS level (dBFS) of the mono sum — used to set glue thresholds from the real signal.
    private static func monoLevels(_ s: AudioSignal) -> (peakDB: Double, rmsDB: Double) {
        let mono = sumToMono(s)
        guard !mono.isEmpty else { return (-60, -60) }
        var peak = 0.0, energy = 0.0
        for v in mono {
            let a = abs(Double(v))
            if a > peak { peak = a }
            energy += Double(v) * Double(v)
        }
        let rms = (energy / Double(mono.count)).squareRoot()
        let peakDB = peak > 1e-9 ? 20.0 * log10(peak) : -60.0
        let rmsDB = rms > 1e-9 ? 20.0 * log10(rms) : -60.0
        return (peakDB, rmsDB)
    }

    /// Gentle 3-band glue settings, thresholds derived from the measured program level.
    /// Ratios ~2:1, thresholds between RMS and peak so only the loud moments get touched.
    private static func glueSettings(peakDB: Double, rmsDB: Double) -> [CompressorSettings] {
        let base = (peakDB + rmsDB) * 0.5
        let lowThr  = clampd(base - 2.0, -40.0, -1.0)
        let midThr  = clampd(base,       -40.0, -1.0)
        let highThr = clampd(base + 1.0, -40.0, -1.0)
        return [
            CompressorSettings(thresholdDB: lowThr,  ratio: 2.0, attackMs: 30, releaseMs: 120, kneeDB: 7, makeupDB: 0),
            CompressorSettings(thresholdDB: midThr,  ratio: 2.0, attackMs: 30, releaseMs: 100, kneeDB: 7, makeupDB: 0),
            CompressorSettings(thresholdDB: highThr, ratio: 2.0, attackMs: 20, releaseMs: 100, kneeDB: 7, makeupDB: 0),
        ]
    }

    /// Parallel soft-tanh saturation: `mix` of a drive-normalized tanh blended with the dry signal.
    /// tanh(drive*x)/drive is ~unity at low level and softly rounds peaks — adds harmonics + density.
    private static func saturate(_ s: AudioSignal, drive: Double, mix: Double) -> AudioSignal {
        let d = max(0.1, drive)
        let m = clampd(mix, 0.0, 1.0)
        let dry = 1.0 - m
        let norm = 1.0 / d
        var out = s.channels
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            for i in 0..<src.count {
                let x = Double(src[i])
                let wet = tanh(d * x) * norm
                out[c][i] = Float(clampd(dry * x + m * wet, -4.0, 4.0))
            }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    /// Apply a broadband gain (dB) to every sample. Clamped generously; the limiter tames peaks after.
    private static func applyGainDB(_ s: AudioSignal, db: Double) -> AudioSignal {
        let g = pow(10.0, clampd(db, -48.0, 48.0) / 20.0)
        var out = s.channels
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            for i in 0..<src.count {
                out[c][i] = Float(clampd(Double(src[i]) * g, -16.0, 16.0))
            }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    // MARK: - Platform report

    /// For every known platform, what will happen to this master's loudness on playback.
    private static func platformReport(masterLUFS: Double) -> [(platform: String, willPlayAtLUFS: Double, action: String)] {
        // Platforms that raise quieter tracks toward their target (with their own limiter).
        let boosters: Set<String> = ["Spotify", "Apple Music"]
        var rows: [(platform: String, willPlayAtLUFS: Double, action: String)] = []
        for p in PlatformTargets.all {
            if masterLUFS > p.lufs + 0.05 {
                rows.append((p.name, p.lufs, String(format: "turned down to %.0f LUFS", p.lufs)))
            } else if masterLUFS < p.lufs - 0.05 {
                if boosters.contains(p.name) {
                    rows.append((p.name, p.lufs, String(format: "boosted to %.0f LUFS", p.lufs)))
                } else {
                    rows.append((p.name, masterLUFS, "played as-is (no upward normalization)"))
                }
            } else {
                rows.append((p.name, masterLUFS, "played as-is (already on target)"))
            }
        }
        return rows
    }

    // MARK: - tiny helpers

    @inline(__always) private static func clampd(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        x < lo ? lo : (x > hi ? hi : x)
    }
}
#endif // circuit-convert
