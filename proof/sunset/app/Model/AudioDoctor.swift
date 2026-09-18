// AudioDoctor: deterministic mix/master diagnosis, release checks, translation previews,
// reference DNA, master matrix rendering, and proof reports. No AI, no cloud, no training.

import Foundation

enum DoctorSeverity: String {
    case pass = "PASS"
    case info = "INFO"
    case warn = "WARN"
    case fail = "FAIL"

    var weight: Int {
        switch self {
        case .pass: return 0
        case .info: return 2
        case .warn: return 9
        case .fail: return 22
        }
    }
}

struct DoctorIssue: Identifiable {
    let id = UUID()
    var severity: DoctorSeverity
    var title: String
    var detail: String
    var fix: String
}

struct ReleaseCheck: Identifiable {
    let id = UUID()
    var name: String
    var value: String
    var target: String
    var severity: DoctorSeverity
}

struct TranslationPreview: Identifiable {
    let id = UUID()
    var profileID: String
    var device: String
    var score: Int
    var note: String
    var severity: DoctorSeverity
}

struct PlatformPlaybackEstimate: Identifiable {
    let id = UUID()
    var platform: String
    var playbackGainDB: Double
    var estimatedPlaybackLUFS: Double
    var codecPeakDBTP: Double
    var severity: DoctorSeverity
}

struct ReferenceTrait: Identifiable {
    let id = UUID()
    var name: String
    var target: String
    var reference: String
    var delta: String
    var severity: DoctorSeverity
}

struct DoctorMetrics {
    var sampleRateHz: Double
    var integratedLUFS: Double
    var loudnessRangeLU: Double
    var shortTermMaxLUFS: Double
    var truePeakDBTP: Double
    var codecPeakDBTP: Double
    var samplePeakDBFS: Double
    var crestFactorDB: Double
    var dcOffset: Double
    var clippedSamples: Int
    var monoCorrelation: Double
    var lowEndSideRatio: Double
    var mudExcessDB: Double
    var harshExcessDB: Double
    var subBalanceDB: Double
    var airBalanceDB: Double
    var spectralTiltDBPerOctave: Double
    var brightnessDB: Double
    var transientDensity: Double
}

struct StemConflictCell: Identifiable {
    let id = UUID()
    var title: String
    var keepStem: String
    var carveStem: String
    var freqHz: Double
    var severity: Double
    var suggestion: String
}

struct StemConflictReport {
    var stemCount: Int
    var summary: String
    var lanes: [StemConflictLane]
    var cells: [StemConflictCell]
    var suggestedCarves: [String: [EQBand]]
}

struct StemConflictLane: Identifiable {
    let id = UUID()
    var pair: String
    var stemA: String
    var stemB: String
    var severity: Double
    var frequencyHz: Double?
    var carveSuggestion: String
    var sidechainSuggestion: String
}

struct DoctorReport {
    var score: Int
    var summary: String
    var metrics: DoctorMetrics
    var issues: [DoctorIssue]
    var releaseChecks: [ReleaseCheck]
    var platformEstimates: [PlatformPlaybackEstimate]
    var translations: [TranslationPreview]
    var referenceTraits: [ReferenceTrait]
    var stemConflictReport: StemConflictReport?
    var proofText: String
    var proofJSON: String
}

struct MasterVariant: Identifiable {
    let id = UUID()
    var name: String
    var blurb: String
    var result: MasterResult
    var score: Int
    var lufs: Double
    var truePeak: Double
    var lra: Double
    var crest: Double
    var codecPeak: Double
}

enum AudioDoctor {
    static func analyze(signal: AudioSignal,
                        reference: AudioSignal?,
                        master: MasterResult?,
                        platform: PlatformTarget,
                        label: String,
                        stemConflicts: StemConflictReport? = nil) -> DoctorReport {
        let finalSignal = master?.output ?? signal
        let meter = LoudnessMeter(sampleRate: finalSignal.sampleRate, channels: max(1, finalSignal.channelCount))
        let loudness = meter.measure(finalSignal.channels)
        let metrics = metrics(for: finalSignal, loudness: loudness)
        let issues = issuesFor(metrics: metrics, platform: platform, hasMaster: master != nil,
                               stemConflicts: stemConflicts)
        let releaseChecks = checksFor(metrics: metrics, platform: platform)
        let platformEstimates = platformPlaybackEstimates(metrics: metrics)
        let translations = translationPreviews(metrics: metrics)
        let referenceTraits = reference.map { referenceDNA(target: finalSignal, reference: $0) } ?? []
        let score = readinessScore(issues: issues, translations: translations, checks: releaseChecks,
                                   platformEstimates: platformEstimates)
        let summary = summaryFor(score: score, issues: issues)
        let proof = proofText(label: label, score: score, metrics: metrics, checks: releaseChecks,
                              platformEstimates: platformEstimates, translations: translations,
                              referenceTraits: referenceTraits, stemConflicts: stemConflicts,
                              master: master, platform: platform)
        let json = proofJSON(label: label, score: score, metrics: metrics, checks: releaseChecks,
                             platformEstimates: platformEstimates, translations: translations,
                             referenceTraits: referenceTraits, stemConflicts: stemConflicts,
                             master: master, platform: platform)
        return DoctorReport(score: score, summary: summary, metrics: metrics, issues: issues,
                            releaseChecks: releaseChecks, platformEstimates: platformEstimates,
                            translations: translations, referenceTraits: referenceTraits,
                            stemConflictReport: stemConflicts, proofText: proof, proofJSON: json)
    }

    static func renderMatrix(input: AudioSignal,
                             reference: AudioSignal?,
                             genre: GenreTarget,
                             platform: PlatformTarget,
                             userEQ: [EQBand],
                             progress: ((Double, String) -> Void)? = nil) -> [MasterVariant] {
        let club = PlatformTargets.all.first { $0.name == "Club / DJ" } ?? platform
        let specs: [(String, String, MasterIntensity, PlatformTarget, [EQBand])] = [
            ("Clean", "Most dynamic, least processed", .gentle, platform, userEQ),
            ("Loud", "Competitive streaming loudness", .loud, platform, userEQ),
            ("Club", "Hotter DJ playback version", .max, club, userEQ),
            ("Warm", "Rounder low-mid, softer air", .balanced, platform, userEQ + [.peak(240, 1.2, 0.9), .highShelf(9_500, -1.0)]),
            ("Bright", "More presence and top", .balanced, platform, userEQ + [.peak(3_500, 1.1, 0.9), .highShelf(11_000, 1.4)]),
            ("Vocal Forward", "Presence push without extra loudness", .balanced, platform, userEQ + [.peak(1_500, 0.8, 1.0), .peak(4_000, 1.3, 0.9)]),
        ]

        var variants: [MasterVariant] = []
        for (idx, spec) in specs.enumerated() {
            progress?(Double(idx) / Double(specs.count), "Rendering \(spec.0)")
            let result = MasteringEngine.master(input: input, reference: reference, genre: genre,
                                                platform: spec.3, intensity: spec.2,
                                                userEQ: spec.4, progress: nil)
            let report = analyze(signal: input, reference: reference, master: result,
                                 platform: spec.3, label: spec.0)
            variants.append(MasterVariant(name: spec.0, blurb: spec.1, result: result,
                                          score: report.score, lufs: result.after.integratedLUFS,
                                          truePeak: result.after.truePeakDBTP,
                                          lra: report.metrics.loudnessRangeLU,
                                          crest: report.metrics.crestFactorDB,
                                          codecPeak: report.metrics.codecPeakDBTP))
        }
        progress?(1, "Master matrix ready")
        return variants
    }

    static func analyzeStems(_ stems: [(name: String, signal: AudioSignal)]) -> StemConflictReport {
        let report = MaskingDetector.analyze(stems: stems, analyzer: FFTAnalyzer(size: 4096))
        let cells = report.issues.prefix(36).map { issue -> StemConflictCell in
            let title = conflictTitle(keep: issue.stemA, carve: issue.stemB, freq: issue.freqHz)
            return StemConflictCell(title: title, keepStem: issue.stemA, carveStem: issue.stemB,
                                    freqHz: issue.freqHz, severity: issue.severity,
                                    suggestion: issue.suggestion)
        }
        let summary: String
        if cells.isEmpty {
            summary = "No major stem masking conflicts detected."
        } else {
            let severe = cells.filter { $0.severity >= 0.55 }.count
            summary = "\(cells.count) conflict bands found, \(severe) high-priority."
        }
        let lanes = conflictLanes(stems: stems, cells: cells)
        return StemConflictReport(stemCount: stems.count, summary: summary, lanes: lanes,
                                  cells: cells, suggestedCarves: report.suggestedCarves)
    }

    static func renderTranslation(signal: AudioSignal, profileID: String) -> AudioSignal {
        switch profileID {
        case "phone":
            return codecPreview(downsampleHold(applyEQ(mono(signal), bands: [.highPass(220), .lowPass(5_800), .peak(1_800, 2.2, 0.9)]),
                                                effectiveRate: 16_000))
        case "airpods":
            return codecPreview(downsampleHold(applyEQ(signal, bands: [.highPass(70), .peak(3_200, 1.0, 0.8), .highShelf(9_500, 1.2), .lowPass(16_500)]),
                                                effectiveRate: 32_000))
        case "car":
            return codecPreview(downsampleHold(applyEQ(signal, bands: [.highPass(32), .lowShelf(85, 3.2), .peak(260, 1.6, 0.9), .highShelf(9_000, -1.0)]),
                                                effectiveRate: 24_000))
        case "club":
            let narrowed = StereoImager().process(signal, width: 1.05, monoBelowHz: 150, sampleRate: signal.sampleRate)
            return codecPreview(applyEQ(narrowed, bands: [.highPass(28), .lowShelf(65, 4.0), .peak(180, -1.2, 0.9), .highShelf(11_000, 1.0)]))
        case "mono_bt":
            return codecPreview(downsampleHold(applyEQ(mono(signal), bands: [.highPass(95), .lowPass(12_000), .peak(240, 1.3, 0.9), .peak(3_000, 1.2, 0.9)]),
                                                effectiveRate: 22_050))
        default:
            return codecPreview(signal)
        }
    }

    // MARK: - Metrics

    private static func metrics(for s: AudioSignal, loudness: LoudnessResult) -> DoctorMetrics {
        let rms = rmsDB(s)
        let crest = loudness.samplePeakDBFS - rms
        let fp = fingerprint(s)
        let mid = avg(fp, 80, 12_000)
        let mud = avg(fp, 180, 500) - mid
        let harsh = avg(fp, 2_500, 6_500) - mid
        let sub = avg(fp, 35, 80) - avg(fp, 80, 180)
        let air = avg(fp, 10_000, 16_000) - mid
        let codecPeak = loudness.truePeakDBTP + codecOvershootDB(fp: fp, loudness: loudness)
        return DoctorMetrics(sampleRateHz: s.sampleRate,
                             integratedLUFS: loudness.integratedLUFS,
                             loudnessRangeLU: loudness.loudnessRangeLU,
                             shortTermMaxLUFS: loudness.shortTermMaxLUFS,
                             truePeakDBTP: loudness.truePeakDBTP,
                             codecPeakDBTP: codecPeak,
                             samplePeakDBFS: loudness.samplePeakDBFS,
                             crestFactorDB: crest,
                             dcOffset: dcOffset(s),
                             clippedSamples: clippedSamples(s),
                             monoCorrelation: monoCorrelation(s),
                             lowEndSideRatio: lowEndSideRatio(s),
                             mudExcessDB: mud,
                             harshExcessDB: harsh,
                             subBalanceDB: sub,
                             airBalanceDB: air,
                             spectralTiltDBPerOctave: spectralTilt(fp),
                             brightnessDB: avg(fp, 6_000, 16_000) - avg(fp, 250, 2_000),
                             transientDensity: transientDensity(s))
    }

    private static func fingerprint(_ s: AudioSignal) -> [Float] {
        ReferenceMatcher.fingerprint(s, analyzer: FFTAnalyzer(size: 4096))
    }

    private static func avg(_ bands: [Float], _ lo: Double, _ hi: Double) -> Double {
        var sum = 0.0
        var count = 0
        for (i, f) in FreqBands.centers.enumerated() where i < bands.count && f >= lo && f <= hi {
            sum += Double(bands[i])
            count += 1
        }
        return count == 0 ? -120 : sum / Double(count)
    }

    private static func rmsDB(_ s: AudioSignal) -> Double {
        var e = 0.0
        var n = 0
        for ch in s.channels {
            for v in ch {
                let d = Double(v)
                e += d * d
            }
            n += ch.count
        }
        guard n > 0 else { return -120 }
        let rms = sqrt(e / Double(n))
        return rms > 1e-12 ? 20 * log10(rms) : -120
    }

    private static func clippedSamples(_ s: AudioSignal) -> Int {
        var count = 0
        for ch in s.channels {
            for v in ch where abs(v) >= 0.999 { count += 1 }
        }
        return count
    }

    private static func dcOffset(_ s: AudioSignal) -> Double {
        guard s.channelCount > 0 else { return 0 }
        var worst = 0.0
        for ch in s.channels where !ch.isEmpty {
            let mean = ch.reduce(0.0) { $0 + Double($1) } / Double(ch.count)
            worst = max(worst, abs(mean))
        }
        return worst
    }

    private static func monoCorrelation(_ s: AudioSignal) -> Double {
        guard s.channelCount >= 2 else { return 1 }
        let l = s.channels[0], r = s.channels[1]
        let n = min(l.count, r.count)
        guard n > 1 else { return 1 }
        var sumLR = 0.0, sumL2 = 0.0, sumR2 = 0.0
        for i in 0..<n {
            let a = Double(l[i]), b = Double(r[i])
            sumLR += a * b
            sumL2 += a * a
            sumR2 += b * b
        }
        let den = sqrt(sumL2 * sumR2)
        return den > 1e-12 ? max(-1, min(1, sumLR / den)) : 1
    }

    private static func lowEndSideRatio(_ s: AudioSignal) -> Double {
        guard s.channelCount >= 2, s.frameCount > 0 else { return 0 }
        let sr = s.sampleRate > 0 ? s.sampleRate : 44_100
        let lpL = Biquad(BiquadCoeffs.make(.lowPass, freq: 140, sampleRate: sr, q: 0.707))
        let lpR = Biquad(BiquadCoeffs.make(.lowPass, freq: 140, sampleRate: sr, q: 0.707))
        let l = s.channels[0], r = s.channels[1]
        let n = min(l.count, r.count)
        var midE = 0.0, sideE = 0.0
        for i in 0..<n {
            let a = lpL.process(Double(l[i]))
            let b = lpR.process(Double(r[i]))
            let mid = (a + b) * 0.5
            let side = (a - b) * 0.5
            midE += mid * mid
            sideE += side * side
        }
        let mid = sqrt(midE / Double(max(1, n)))
        let side = sqrt(sideE / Double(max(1, n)))
        return mid > 1e-9 ? side / mid : 0
    }

    // MARK: - Rules

    private static func issuesFor(metrics m: DoctorMetrics, platform: PlatformTarget,
                                  hasMaster: Bool, stemConflicts: StemConflictReport?) -> [DoctorIssue] {
        var issues: [DoctorIssue] = []
        if m.clippedSamples > 0 {
            issues.append(issue(.fail, "Sample clipping", "\(m.clippedSamples) samples are at or above full scale.", "Lower input gain or re-export with headroom."))
        }
        if m.truePeakDBTP > platform.truePeakDBTP + 0.05 {
            issues.append(issue(hasMaster ? .fail : .warn, "True peak over ceiling", "\(fmt(m.truePeakDBTP)) dBTP exceeds \(platform.name)'s \(fmt(platform.truePeakDBTP)) dBTP ceiling.", "Use Sunset limiting or lower final gain."))
        }
        if m.codecPeakDBTP > 0 {
            issues.append(issue(.fail, "Codec clipping preview", "Lossy playback estimate reaches \(fmt(m.codecPeakDBTP)) dBTP.", "Lower final ceiling or choose Clean/Warm."))
        } else if m.codecPeakDBTP > -0.6 {
            issues.append(issue(.warn, "Codec headroom risk", "Lossy playback estimate is \(fmt(m.codecPeakDBTP)) dBTP.", "Leave more true-peak headroom for AAC/Ogg/TikTok transcodes."))
        }
        if m.dcOffset > 0.01 {
            issues.append(issue(.warn, "DC offset", "Worst channel offset is \(String(format: "%.3f", m.dcOffset)).", "High-pass or remove DC before final limiting."))
        }
        if m.loudnessRangeLU < 2.0 {
            issues.append(issue(.warn, "Low LRA", "Loudness range is \(fmt(m.loudnessRangeLU)) LU.", "Use a less aggressive matrix version if the track feels flat."))
        }
        if m.crestFactorDB < 6 {
            issues.append(issue(.fail, "Crushed dynamics", "Crest factor is \(fmt(m.crestFactorDB)) dB.", "Use a gentler variant or reduce limiting."))
        } else if m.crestFactorDB < 8 {
            issues.append(issue(.warn, "Low punch reserve", "Crest factor is \(fmt(m.crestFactorDB)) dB.", "Try Clean or Warm in the master matrix."))
        } else if m.crestFactorDB > 19 {
            issues.append(issue(.warn, "Spiky mix", "Crest factor is \(fmt(m.crestFactorDB)) dB.", "Control rogue transients before pushing loudness."))
        }
        if m.monoCorrelation < 0.1 {
            issues.append(issue(.fail, "Mono collapse risk", "Stereo correlation is \(String(format: "%.2f", m.monoCorrelation)).", "Narrow phasey stereo content and keep essentials center."))
        } else if m.monoCorrelation < 0.35 {
            issues.append(issue(.warn, "Weak mono compatibility", "Stereo correlation is \(String(format: "%.2f", m.monoCorrelation)).", "Check mono before release."))
        }
        if m.lowEndSideRatio > 0.28 {
            issues.append(issue(.fail, "Wide low end", "Sub/low side ratio is \(String(format: "%.2f", m.lowEndSideRatio)).", "Fold lows below 100-140 Hz toward mono."))
        } else if m.lowEndSideRatio > 0.16 {
            issues.append(issue(.warn, "Loose low-end image", "Sub/low side ratio is \(String(format: "%.2f", m.lowEndSideRatio)).", "Narrow the sub region for club and mono playback."))
        }
        if m.mudExcessDB > 4 {
            issues.append(issue(.warn, "Low-mid mud", "180-500 Hz is \(fmt(m.mudExcessDB)) dB above the broad tonal bed.", "Cut boxy buildup around 250-400 Hz."))
        }
        if m.harshExcessDB > 4 {
            issues.append(issue(.warn, "Harsh presence", "2.5-6.5 kHz is \(fmt(m.harshExcessDB)) dB above the broad tonal bed.", "Soften presence or de-harsh before exporting."))
        }
        if m.subBalanceDB > 7 {
            issues.append(issue(.warn, "Sub-heavy translation risk", "35-80 Hz is \(fmt(m.subBalanceDB)) dB above upper bass.", "Check phone/car translation and control sub sustain."))
        }
        if let stemConflicts, let worst = stemConflicts.cells.first, worst.severity >= 0.55 {
            issues.append(issue(.warn, "Stem masking conflicts", "\(stemConflicts.summary) Worst: \(worst.title).", "Apply the suggested carve/sidechain moves before final export."))
        }
        if issues.isEmpty {
            issues.append(issue(.pass, "Release path clear", "No hard technical blockers detected.", "Export proof and audition the variants."))
        }
        return issues
    }

    private static func checksFor(metrics m: DoctorMetrics, platform: PlatformTarget) -> [ReleaseCheck] {
        [
            ReleaseCheck(name: "True peak", value: "\(fmt(m.truePeakDBTP)) dBTP", target: "<= \(fmt(platform.truePeakDBTP)) dBTP", severity: m.truePeakDBTP <= platform.truePeakDBTP + 0.05 ? .pass : .fail),
            ReleaseCheck(name: "Platform loudness", value: "\(fmt(m.integratedLUFS)) LUFS", target: "\(platform.name) plays around \(fmt(platform.lufs)) LUFS", severity: abs(m.integratedLUFS - platform.lufs) <= 5 ? .pass : .info),
            ReleaseCheck(name: "Codec clipping preview", value: "\(fmt(m.codecPeakDBTP)) dBTP", target: "< 0.0 dBTP after transcode", severity: m.codecPeakDBTP < -0.6 ? .pass : (m.codecPeakDBTP < 0 ? .warn : .fail)),
            ReleaseCheck(name: "Mono correlation", value: String(format: "%.2f", m.monoCorrelation), target: ">= 0.35", severity: m.monoCorrelation >= 0.35 ? .pass : (m.monoCorrelation >= 0.1 ? .warn : .fail)),
            ReleaseCheck(name: "Low-end width", value: String(format: "%.2f", m.lowEndSideRatio), target: "<= 0.16 ideal", severity: m.lowEndSideRatio <= 0.16 ? .pass : (m.lowEndSideRatio <= 0.28 ? .warn : .fail)),
            ReleaseCheck(name: "Dynamics", value: "\(fmt(m.crestFactorDB)) dB crest", target: "8-18 dB", severity: (m.crestFactorDB >= 8 && m.crestFactorDB <= 18) ? .pass : .warn),
            ReleaseCheck(name: "PSR (over-limit)", value: "\(fmt(m.truePeakDBTP - m.shortTermMaxLUFS)) dB", target: ">= \(fmt(PunchGate.psrWarnDB)) dB (industry practice)", severity: (m.truePeakDBTP - m.shortTermMaxLUFS) >= PunchGate.psrWarnDB ? .pass : .warn),
            ReleaseCheck(name: "LRA", value: "\(fmt(m.loudnessRangeLU)) LU", target: ">= 2 LU", severity: m.loudnessRangeLU >= 2 ? .pass : .warn),
            ReleaseCheck(name: "DC offset", value: String(format: "%.4f", m.dcOffset), target: "<= 0.0100", severity: m.dcOffset <= 0.01 ? .pass : .warn),
        ]
    }

    private static func platformPlaybackEstimates(metrics m: DoctorMetrics) -> [PlatformPlaybackEstimate] {
        let targets: [(String, Double, Double)] = [
            ("Spotify", -14, -1),
            ("Apple", -16, -1),
            ("YouTube", -14, -1),
            ("TikTok", -14, -1)
        ]
        return targets.map { name, targetLUFS, peakCeiling in
            let playbackGain = min(0, targetLUFS - m.integratedLUFS)
            let playbackLUFS = m.integratedLUFS + playbackGain
            let codecPeak = m.codecPeakDBTP + playbackGain
            let sev: DoctorSeverity = codecPeak <= peakCeiling ? .pass : (codecPeak <= 0 ? .warn : .fail)
            return PlatformPlaybackEstimate(platform: name, playbackGainDB: playbackGain,
                                            estimatedPlaybackLUFS: playbackLUFS,
                                            codecPeakDBTP: codecPeak, severity: sev)
        }
    }

    private static func translationPreviews(metrics m: DoctorMetrics) -> [TranslationPreview] {
        let phone = clamp(86 - Int(max(0, m.subBalanceDB - 3) * 4) - Int(max(0, m.mudExcessDB - 3) * 4), 0, 100)
        let earbuds = clamp(90 - Int(max(0, m.harshExcessDB - 3) * 6) - (m.truePeakDBTP > -1 ? 10 : 0), 0, 100)
        let car = clamp(88 - Int(max(0, m.mudExcessDB - 3) * 5) - Int(max(0, m.subBalanceDB - 6) * 3), 0, 100)
        let club = clamp(92 - Int(max(0, m.lowEndSideRatio - 0.16) * 120) - (m.truePeakDBTP > -0.8 ? 10 : 0), 0, 100)
        let mono = clamp(Int((m.monoCorrelation + 1.0) * 50.0), 0, 100)
        return [
            translation("phone", "Phone speaker", phone, phone >= 75 ? "Lead/midrange should survive small speakers." : "Likely loses weight or gets boxy on phones."),
            translation("airpods", "AirPods", earbuds, earbuds >= 75 ? "Top end should hold without obvious bite." : "Presence/codec edge may feel sharp."),
            translation("car", "Car", car, car >= 75 ? "Low end should stay controlled in a cabin." : "Low-mid or sub buildup may bloom in cars."),
            translation("club", "Club system", club, club >= 75 ? "Low end is centered enough for systems." : "Wide or hot low end can weaken punch."),
            translation("mono_bt", "Mono Bluetooth", mono, mono >= 75 ? "Mono fold-down is stable." : "Stereo phase may disappear in mono."),
        ]
    }

    private static func referenceDNA(target: AudioSignal, reference: AudioSignal) -> [ReferenceTrait] {
        let tMeter = LoudnessMeter(sampleRate: target.sampleRate, channels: max(1, target.channelCount)).measure(target.channels)
        let rMeter = LoudnessMeter(sampleRate: reference.sampleRate, channels: max(1, reference.channelCount)).measure(reference.channels)
        let tMetrics = metrics(for: target, loudness: tMeter)
        let rMetrics = metrics(for: reference, loudness: rMeter)
        let tFP = fingerprint(target)
        let rFP = fingerprint(reference)
        let traits: [(String, Double, Double, String)] = [
            ("Spectral tilt", spectralTilt(tFP), spectralTilt(rFP), "dB/oct"),
            ("Low-end curve", avg(tFP, 35, 80) - avg(tFP, 80, 180), avg(rFP, 35, 80) - avg(rFP, 80, 180), "dB"),
            ("Brightness", avg(tFP, 6_000, 16_000) - avg(tFP, 250, 2_000), avg(rFP, 6_000, 16_000) - avg(rFP, 250, 2_000), "dB"),
            ("Stereo width", tMetrics.lowEndSideRatio, rMetrics.lowEndSideRatio, "ratio"),
            ("Loudness", tMeter.integratedLUFS, rMeter.integratedLUFS, "LUFS"),
            ("Transient density", tMetrics.transientDensity, rMetrics.transientDensity, "events/s"),
        ]
        return traits.map { name, targetValue, refValue, unit in
            let delta = refValue - targetValue
            let sev: DoctorSeverity = abs(delta) < (unit == "ratio" ? 0.08 : 1.5) ? .pass : (abs(delta) < (unit == "ratio" ? 0.18 : 3.5) ? .info : .warn)
            return ReferenceTrait(name: name, target: metric(targetValue, unit), reference: metric(refValue, unit),
                                  delta: signed(delta, unit), severity: sev)
        }
    }

    private static func proofText(label: String,
                                  score: Int,
                                  metrics m: DoctorMetrics,
                                  checks: [ReleaseCheck],
                                  platformEstimates: [PlatformPlaybackEstimate],
                                  translations: [TranslationPreview],
                                  referenceTraits: [ReferenceTrait],
                                  stemConflicts: StemConflictReport?,
                                  master: MasterResult?,
                                  platform: PlatformTarget) -> String {
        var lines: [String] = []
        lines.append("Sunset Release Proof")
        lines.append("Label: \(label)")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Engine: deterministic local DSP; no AI, no cloud, no training")
        lines.append("Platform target: \(platform.name) \(fmt(platform.lufs)) LUFS / \(fmt(platform.truePeakDBTP)) dBTP")
        lines.append("")
        lines.append("Readiness score: \(score)/100")
        lines.append("Sample rate: \(Int(m.sampleRateHz.rounded())) Hz")
        // Bit depth is stated only for a finished master: the engine dithers every master
        // render to 24-bit. The export container's depth is chosen at export time and is
        // never asserted here — the proof states only what this analysis measured.
        if master != nil {
            lines.append("Render bit depth: 24-bit (engine dither)")
        }
        lines.append("Integrated loudness: \(fmt(m.integratedLUFS)) LUFS")
        lines.append("LRA: \(fmt(m.loudnessRangeLU)) LU")
        lines.append("Short-term max: \(fmt(m.shortTermMaxLUFS)) LUFS")
        lines.append("True peak: \(fmt(m.truePeakDBTP)) dBTP")
        lines.append("Codec peak preview: \(fmt(m.codecPeakDBTP)) dBTP")
        lines.append("Sample peak: \(fmt(m.samplePeakDBFS)) dBFS")
        lines.append("Crest factor: \(fmt(m.crestFactorDB)) dB")
        lines.append("DC offset: \(String(format: "%.4f", m.dcOffset))")
        lines.append("Mono correlation: \(String(format: "%.2f", m.monoCorrelation))")
        lines.append("Low-end side ratio: \(String(format: "%.2f", m.lowEndSideRatio))")
        lines.append("Clipped samples: \(m.clippedSamples)")
        lines.append("")
        lines.append("Release checks:")
        for c in checks { lines.append("- [\(c.severity.rawValue)] \(c.name): \(c.value) target \(c.target)") }
        lines.append("")
        lines.append("Platform playback estimates:")
        for p in platformEstimates {
            lines.append(String(format: "- [%@] %@: playback gain %+.1f dB, estimated %.1f LUFS, codec peak %.1f dBTP",
                                p.severity.rawValue, p.platform, p.playbackGainDB,
                                p.estimatedPlaybackLUFS, p.codecPeakDBTP))
        }
        lines.append("")
        lines.append("Translation previews:")
        for t in translations { lines.append("- [\(t.severity.rawValue)] \(t.device): \(t.score)/100 \(t.note)") }
        if !referenceTraits.isEmpty {
            lines.append("")
            lines.append("Reference DNA:")
            for r in referenceTraits { lines.append("- [\(r.severity.rawValue)] \(r.name): target \(r.target), reference \(r.reference), delta \(r.delta)") }
        }
        if let stemConflicts {
            lines.append("")
            lines.append("Stem Conflict Map:")
            lines.append(stemConflicts.summary)
            for lane in stemConflicts.lanes {
                let freq = lane.frequencyHz.map { " at \(freqLabel($0))" } ?? ""
                lines.append(String(format: "- %.0f%% %@%@: %@ %@", lane.severity * 100,
                                    lane.pair, freq, lane.carveSuggestion, lane.sidechainSuggestion))
            }
            for c in stemConflicts.cells.prefix(18) {
                lines.append(String(format: "- %.0f%% %@ at %@: %@",
                                    c.severity * 100, c.title, freqLabel(c.freqHz), c.suggestion))
            }
        }
        if let master {
            lines.append("")
            lines.append("Applied chain:")
            for note in master.notes.prefix(24) { lines.append("- \(note)") }
        }
        return lines.joined(separator: "\n")
    }

    private static func proofJSON(label: String,
                                  score: Int,
                                  metrics m: DoctorMetrics,
                                  checks: [ReleaseCheck],
                                  platformEstimates: [PlatformPlaybackEstimate],
                                  translations: [TranslationPreview],
                                  referenceTraits: [ReferenceTrait],
                                  stemConflicts: StemConflictReport?,
                                  master: MasterResult?,
                                  platform: PlatformTarget) -> String {
        var metricsDict: [String: Any] = [
                "sample_rate_hz": m.sampleRateHz,
                "integrated_lufs": m.integratedLUFS,
                "lra_lu": m.loudnessRangeLU,
                "short_term_max_lufs": m.shortTermMaxLUFS,
                "true_peak_dbtp": m.truePeakDBTP,
                "codec_peak_preview_dbtp": m.codecPeakDBTP,
                "sample_peak_dbfs": m.samplePeakDBFS,
                "crest_factor_db": m.crestFactorDB,
                "dc_offset": m.dcOffset,
                "clipped_samples": m.clippedSamples,
                "mono_correlation": m.monoCorrelation,
                "low_end_side_ratio": m.lowEndSideRatio,
                "mud_excess_db": m.mudExcessDB,
                "harsh_excess_db": m.harshExcessDB,
                "spectral_tilt_db_per_octave": m.spectralTiltDBPerOctave,
                "brightness_db": m.brightnessDB,
                "transient_density_events_per_second": m.transientDensity
        ]
        // Only a finished master has a known depth (the engine dithers every render to
        // 24-bit); the export container's depth is chosen at export time, never asserted.
        if master != nil { metricsDict["render_bit_depth"] = 24 }
        var root: [String: Any] = [
            "product": "Sunset",
            "label": label,
            "generated": ISO8601DateFormatter().string(from: Date()),
            "engine": "deterministic local DSP; no AI, no cloud, no training",
            "target": ["platform": platform.name, "lufs": platform.lufs, "true_peak_dbtp": platform.truePeakDBTP],
            "readiness_score": score,
            "metrics": metricsDict,
            "release_checks": checks.map { ["name": $0.name, "value": $0.value, "target": $0.target, "severity": $0.severity.rawValue] },
            "platform_playback_estimates": platformEstimates.map {
                ["platform": $0.platform, "playback_gain_db": $0.playbackGainDB,
                 "estimated_playback_lufs": $0.estimatedPlaybackLUFS,
                 "codec_peak_dbtp": $0.codecPeakDBTP, "severity": $0.severity.rawValue]
            },
            "translation_previews": translations.map {
                ["profile": $0.profileID, "device": $0.device, "score": $0.score,
                 "note": $0.note, "severity": $0.severity.rawValue]
            },
            "reference_dna": referenceTraits.map {
                ["name": $0.name, "target": $0.target, "reference": $0.reference,
                 "delta": $0.delta, "severity": $0.severity.rawValue]
            },
            "applied_chain": master?.notes ?? []
        ]
        if let stemConflicts {
            root["stem_conflict_map"] = [
                "stem_count": stemConflicts.stemCount,
                "summary": stemConflicts.summary,
                "heatmap_lanes": stemConflicts.lanes.map { laneJSON($0) },
                "conflicts": stemConflicts.cells.map {
                    ["title": $0.title, "keep_stem": $0.keepStem, "carve_stem": $0.carveStem,
                     "frequency_hz": $0.freqHz, "severity": $0.severity, "suggestion": $0.suggestion]
                }
            ]
        }
        guard JSONSerialization.isValidJSONObject(root),
              let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return "{\n  \"error\": \"proof json serialization failed\"\n}"
        }
        return json
    }

    private static func readinessScore(issues: [DoctorIssue], translations: [TranslationPreview],
                                       checks: [ReleaseCheck],
                                       platformEstimates: [PlatformPlaybackEstimate]) -> Int {
        let penalty = issues.reduce(0) { $0 + $1.severity.weight }
            + checks.reduce(0) { $0 + $1.severity.weight / 2 }
            + platformEstimates.reduce(0) { $0 + $1.severity.weight / 2 }
            + translations.reduce(0) { $0 + max(0, 75 - $1.score) / 5 }
        return clamp(100 - penalty, 0, 100)
    }

    private static func summaryFor(score: Int, issues: [DoctorIssue]) -> String {
        if score >= 90 { return "Release-ready. Export proof and ship." }
        if score >= 75 { return "Close. Fix the yellow items before final delivery." }
        if issues.contains(where: { $0.severity == .fail }) { return "Not ready. Hard technical blockers remain." }
        return "Needs polish before release."
    }

    private static func issue(_ severity: DoctorSeverity, _ title: String, _ detail: String, _ fix: String) -> DoctorIssue {
        DoctorIssue(severity: severity, title: title, detail: detail, fix: fix)
    }

    private static func translation(_ profileID: String, _ device: String, _ score: Int, _ note: String) -> TranslationPreview {
        TranslationPreview(profileID: profileID, device: device, score: score, note: note,
                           severity: score >= 80 ? .pass : (score >= 65 ? .warn : .fail))
    }

    private static func fmt(_ v: Double) -> String {
        v.isFinite ? String(format: "%+.1f", v) : "--"
    }

    private static func signed(_ v: Double, _ unit: String) -> String {
        unit == "ratio" ? String(format: "%+.2f", v) : String(format: "%+.1f %@", v, unit)
    }

    private static func metric(_ v: Double, _ unit: String) -> String {
        if unit == "ratio" { return String(format: "%.2f", v) }
        if unit == "events/s" { return String(format: "%.1f %@", v, unit) }
        return String(format: "%.1f %@", v, unit)
    }

    private static func clamp(_ x: Int, _ lo: Int, _ hi: Int) -> Int {
        min(max(x, lo), hi)
    }

    private static func spectralTilt(_ bands: [Float]) -> Double {
        var xs: [Double] = []
        var ys: [Double] = []
        for (i, f) in FreqBands.centers.enumerated() where i < bands.count && f >= 80 && f <= 12_000 {
            let y = Double(bands[i])
            if y > -119 {
                xs.append(log2(f / 1_000))
                ys.append(y)
            }
        }
        guard xs.count > 2 else { return 0 }
        let mx = xs.reduce(0, +) / Double(xs.count)
        let my = ys.reduce(0, +) / Double(ys.count)
        var num = 0.0, den = 0.0
        for i in xs.indices {
            let dx = xs[i] - mx
            num += dx * (ys[i] - my)
            den += dx * dx
        }
        return den > 1e-9 ? num / den : 0
    }

    private static func transientDensity(_ s: AudioSignal) -> Double {
        let mono = monoSamples(s)
        guard mono.count > 2, s.sampleRate > 0 else { return 0 }
        let hop = max(1, Int(0.01 * s.sampleRate))
        var last = 0.0
        var hits = 0
        var blocks = 0
        var i = 0
        while i < mono.count {
            let end = min(mono.count, i + hop)
            var peak = 0.0
            for j in i..<end { peak = max(peak, abs(Double(mono[j]))) }
            if peak > last * 1.8 && peak > 0.08 { hits += 1 }
            last = max(peak, last * 0.86)
            blocks += 1
            i += hop
        }
        let seconds = Double(mono.count) / s.sampleRate
        return seconds > 0 ? Double(hits) / seconds : 0
    }

    private static func codecOvershootDB(fp: [Float], loudness: LoudnessResult) -> Double {
        let top = avg(fp, 8_000, 16_000)
        let body = avg(fp, 250, 4_000)
        let brightnessRisk = max(0, top - body - 1.0) * 0.06
        let loudRisk = max(0, -9.0 - loudness.integratedLUFS) * 0.05
        return min(1.4, 0.25 + brightnessRisk + loudRisk)
    }

    private static func conflictLanes(stems: [(name: String, signal: AudioSignal)],
                                      cells: [StemConflictCell]) -> [StemConflictLane] {
        let named = stems.map { (name: $0.name, role: MixEngine.StemRole.detect($0.name)) }
        func first(_ roles: [MixEngine.StemRole]) -> String {
            named.first { roles.contains($0.role) }?.name ?? ""
        }
        let kick = first([.kick])
        let bass = first([.bass])
        let vocal = first([.vox])
        let synth = first([.synth, .pad, .lead])
        let snare = named.first { item in
            let n = item.name.lowercased()
            return n.contains("snare") || n.contains("clap")
        }?.name ?? first([.drums])

        return [
            lane(pair: "Kick vs bass", stemA: kick, stemB: bass, cells: cells, freqRange: 35...180,
                 carve: "Carve bass/kick overlap 2-4 dB at the hottest low band.",
                 sidechain: "Sidechain bass to kick 3-6 dB with 90-180 ms release."),
            lane(pair: "Vocal vs synth", stemA: vocal, stemB: synth, cells: cells, freqRange: 1_000...6_500,
                 carve: "Carve synth/pad presence around the conflict band.",
                 sidechain: "Duck synth bed under vocal 2-4 dB with 150-240 ms release."),
            lane(pair: "Snare vs vocal presence", stemA: snare, stemB: vocal, cells: cells, freqRange: 2_000...7_000,
                 carve: "Notch the less important presence band 1.5-3 dB.",
                 sidechain: "Use short dynamic EQ on snare/vocal presence during hits.")
        ]
    }

    private static func lane(pair: String,
                             stemA: String,
                             stemB: String,
                             cells: [StemConflictCell],
                             freqRange: ClosedRange<Double>,
                             carve: String,
                             sidechain: String) -> StemConflictLane {
        guard !stemA.isEmpty, !stemB.isEmpty else {
            return StemConflictLane(pair: pair, stemA: stemA, stemB: stemB, severity: 0,
                                    frequencyHz: nil, carveSuggestion: "Missing one of the stems for this lane.",
                                    sidechainSuggestion: "No sidechain suggested until both stems are present.")
        }
        let candidates = cells.filter { cell in
            freqRange.contains(cell.freqHz)
                && [cell.keepStem, cell.carveStem].contains(stemA)
                && [cell.keepStem, cell.carveStem].contains(stemB)
        }
        let strongest = candidates.max { $0.severity < $1.severity }
        return StemConflictLane(pair: pair, stemA: stemA, stemB: stemB,
                                severity: strongest?.severity ?? 0,
                                frequencyHz: strongest?.freqHz,
                                carveSuggestion: strongest?.suggestion ?? carve,
                                sidechainSuggestion: sidechain)
    }

    private static func laneJSON(_ lane: StemConflictLane) -> [String: Any] {
        var out: [String: Any] = [
            "pair": lane.pair,
            "stem_a": lane.stemA,
            "stem_b": lane.stemB,
            "severity": lane.severity,
            "carve_suggestion": lane.carveSuggestion,
            "sidechain_suggestion": lane.sidechainSuggestion
        ]
        if let frequencyHz = lane.frequencyHz {
            out["frequency_hz"] = frequencyHz
        }
        return out
    }

    private static func conflictTitle(keep: String, carve: String, freq: Double) -> String {
        let both = "\(keep) \(carve)".lowercased()
        if both.contains("kick") && (both.contains("bass") || both.contains("808") || both.contains("sub")) && freq < 180 {
            return "Kick vs bass"
        }
        if (both.contains("vocal") || both.contains("vox")) && (both.contains("synth") || both.contains("lead") || both.contains("pad")) && freq >= 1_000 && freq <= 6_500 {
            return "Vocal vs synth"
        }
        if (both.contains("snare") || both.contains("drum")) && (both.contains("vocal") || both.contains("vox")) && freq >= 2_000 && freq <= 7_000 {
            return "Snare vs vocal presence"
        }
        return "\(carve) vs \(keep)"
    }

    private static func freqLabel(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }

    private static func monoSamples(_ s: AudioSignal) -> [Float] {
        guard let first = s.channels.first else { return [] }
        if s.channelCount == 1 { return first }
        let n = first.count
        var out = [Float](repeating: 0, count: n)
        for ch in s.channels {
            let m = min(n, ch.count)
            for i in 0..<m { out[i] += ch[i] }
        }
        let inv = Float(1.0 / Double(max(1, s.channelCount)))
        for i in 0..<n { out[i] *= inv }
        return out
    }

    private static func mono(_ s: AudioSignal) -> AudioSignal {
        AudioSignal(channels: [monoSamples(s)], sampleRate: s.sampleRate)
    }

    private static func applyEQ(_ s: AudioSignal, bands: [EQBand]) -> AudioSignal {
        guard s.frameCount > 0, s.channelCount > 0 else { return s }
        let eq = ParametricEQ(bands: bands, sampleRate: s.sampleRate, channels: s.channelCount)
        var out = s.channels
        for c in 0..<s.channelCount {
            for i in 0..<s.frameCount {
                out[c][i] = Float(max(-1, min(1, eq.process(Double(s.channels[c][i]), channel: c))))
            }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    private static func downsampleHold(_ s: AudioSignal, effectiveRate: Double) -> AudioSignal {
        guard s.frameCount > 0, s.channelCount > 0, effectiveRate > 0, s.sampleRate > effectiveRate else { return s }
        let step = max(1, Int((s.sampleRate / effectiveRate).rounded()))
        var out = s.channels
        for c in 0..<s.channelCount {
            var held: Float = 0
            for i in 0..<s.frameCount {
                if i % step == 0 { held = s.channels[c][i] }
                out[c][i] = held
            }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    private static func codecPreview(_ s: AudioSignal) -> AudioSignal {
        guard s.frameCount > 0, s.channelCount > 0 else { return s }
        let lowPassed = applyEQ(s, bands: [.lowPass(min(16_000, s.sampleRate * 0.42))])
        var out = lowPassed.channels
        for c in 0..<lowPassed.channelCount {
            for i in 0..<lowPassed.frameCount {
                let x = Double(out[c][i])
                let shaped = tanh(x * 1.06) / tanh(1.06)
                let quantized = (shaped * 8192).rounded() / 8192
                out[c][i] = Float(max(-1, min(1, quantized)))
            }
        }
        return AudioSignal(channels: out, sampleRate: lowPassed.sampleRate)
    }
}
