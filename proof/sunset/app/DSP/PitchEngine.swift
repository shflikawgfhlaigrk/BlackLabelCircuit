// PitchEngine.swift — the pitch lane (SUNSET-EFFECTS-STANDARD rows 26/27/29):
// pitch detection (YIN), TD-PSOLA pitch shifting, pitch correction (snap-to-key),
// harmonizer (up to 4 PSOLA voices), and a cepstral formant shifter.
//
// Contract: offline block processing on AudioSignal; output has identical shape.
// Bypassed settings (`enabled == false`, or a mathematically neutral parameter set —
// 0 semitones / strength 0 / no enabled voices) are a bit-transparent passthrough.
// Deterministic: no randomness anywhere in this file.
//
// DESIGNED FOR MONOPHONIC SOURCES (lead vocals, bass lines, lead synths). The detector
// tracks ONE f0 per frame; polyphonic material is honestly reported unvoiced/low-confidence
// and passes through untouched rather than being mangled.
//
// Method notes:
//   • Detection — YIN (de Cheveigné & Kawahara 2002): cumulative-mean-normalized difference
//     over overlapped frames (2048 @ 512 hop), absolute threshold 0.15, parabolic
//     interpolation of the dip. Confidence = 1 − CMND at the pick. Frames whose RMS is
//     below −60 dBFS are unvoiced by definition (silence never yields a pitch).
//   • Shifting — time-domain PSOLA keyed off detected epochs: pitch marks are placed at
//     polarity-locked waveform peaks one period apart inside each voiced region; synthesis
//     marks walk at period/ratio (fractional accumulator, so the AVERAGE output period is
//     exact); each synthesis mark overlap-adds a 2-period Hann grain from the nearest
//     analysis mark; the window sum is divided out (normalized OLA). Unvoiced/silent
//     audio passes through dry; region edges crossfade over ~6 ms.
//     TD-PSOLA grains are unmodified waveform snippets, so the spectral envelope
//     (formants) is preserved BY CONSTRUCTION — `formantPreserve = false` re-warps the
//     envelope by the pitch ratio to emulate a resample-style shift.
//   • Correction — per-frame f0 snapped to the nearest note of a user key/scale
//     (chromatic / major / natural minor, A4 = 440 Hz), retune-speed one-pole glide in the
//     cents domain, strength 0…1 exponent on the correction ratio.
//   • Formants — cepstral spectral-envelope warp: log-magnitude → cepstrum → low-quefrency
//     lifter (cutoff ≈ 0.45·sr/90 Hz ⇒ envelope resolution ≈ 200 Hz) → envelope warped by
//     2^(semitones/12) → magnitude re-weighted (envelope delta clamped ±24 dB), phase
//     untouched (so f0 does not move), Hann²-OLA resynthesis at 4× overlap.
//
// Stereo: detection runs on the channel average; the SAME marks/grains drive every
// channel, so stereo phase coherence is kept.

import Foundation

// MARK: - Pitch track

/// One detector frame: where it is, what it heard, and how sure it is.
struct PitchFrame: Equatable {
    /// Center of the analysis frame, in samples.
    var position: Int
    /// Detected fundamental, Hz (meaningful only when `voiced`).
    var f0: Double
    /// 1 − CMND at the picked lag (0…1, higher = cleaner periodicity).
    var confidence: Double
    var voiced: Bool
}

/// YIN pitch detector on overlapped frames. Monophonic by design (see file header).
final class PitchDetector {
    let sampleRate: Double
    let frameSize: Int
    let hop: Int
    let minF0: Double
    let maxF0: Double
    /// CMND absolute threshold (0.15 per the YIN paper's recommended range 0.1–0.2).
    let yinThreshold: Double
    /// Frames quieter than this are unvoiced by definition.
    let silenceFloorDB: Double

    init(sampleRate: Double, frameSize: Int = 2048, hop: Int = 512,
         minF0: Double = 60, maxF0: Double = 1000,
         yinThreshold: Double = 0.15, silenceFloorDB: Double = -60) {
        self.sampleRate = max(1.0, sampleRate)
        self.frameSize = max(256, frameSize)
        self.hop = max(64, hop)
        self.minF0 = max(20, minF0)
        self.maxF0 = min(max(maxF0, minF0 * 2), self.sampleRate / 4)
        self.yinThreshold = min(max(yinThreshold, 0.02), 0.5)
        self.silenceFloorDB = silenceFloorDB
    }

    /// Track f0 over the whole buffer. Frames land every `hop` samples.
    func track(_ mono: [Float]) -> [PitchFrame] {
        guard mono.count >= frameSize else { return [] }
        var frames: [PitchFrame] = []
        var start = 0
        while start + frameSize <= mono.count {
            frames.append(analyze(mono, start: start))
            start += hop
        }
        return frames
    }

    /// One YIN frame at `start`.
    func analyze(_ x: [Float], start: Int) -> PitchFrame {
        let center = start + frameSize / 2

        // Silence gate first: a quiet frame never yields a pitch.
        var sumSq = 0.0
        for i in start..<(start + frameSize) { let d = Double(x[i]); sumSq += d * d }
        let rms = (sumSq / Double(frameSize)).squareRoot()
        let rmsDB = rms > 1e-12 ? 20 * log10(rms) : -240
        if rmsDB < silenceFloorDB {
            return PitchFrame(position: center, f0: 0, confidence: 0, voiced: false)
        }

        let tauMin = max(2, Int(sampleRate / maxF0))
        let tauMax = min(frameSize / 2, Int(sampleRate / minF0))
        guard tauMax > tauMin + 2 else {
            return PitchFrame(position: center, f0: 0, confidence: 0, voiced: false)
        }
        // Integration window: everything the frame can afford past the longest lag,
        // capped at 1024 for cost (≥ 1 full period of minF0 either way).
        let w = min(frameSize - tauMax, 1024)

        // Difference function + cumulative-mean normalization in one pass.
        var d = [Double](repeating: 0, count: tauMax + 1)
        var cmnd = [Double](repeating: 1, count: tauMax + 1)
        var runningSum = 0.0
        for tau in 1...tauMax {
            var acc = 0.0
            for i in 0..<w {
                let diff = Double(x[start + i]) - Double(x[start + i + tau])
                acc += diff * diff
            }
            d[tau] = acc
            runningSum += acc
            cmnd[tau] = runningSum > 1e-18 ? acc * Double(tau) / runningSum : 1
        }

        // First dip under threshold; walk to its local bottom.
        var tau = -1
        var t = tauMin
        while t <= tauMax {
            if cmnd[t] < yinThreshold {
                while t + 1 <= tauMax && cmnd[t + 1] < cmnd[t] { t += 1 }
                tau = t
                break
            }
            t += 1
        }
        // Fallback: global CMND minimum — voiced only if it is still a convincing dip.
        if tau < 0 {
            var best = tauMin
            for tt in tauMin...tauMax where cmnd[tt] < cmnd[best] { best = tt }
            if cmnd[best] < 0.3 { tau = best }
        }
        guard tau > 0 else {
            return PitchFrame(position: center, f0: 0, confidence: 0, voiced: false)
        }

        // Parabolic interpolation on CMND around the pick.
        var refined = Double(tau)
        if tau > tauMin && tau < tauMax {
            let a = cmnd[tau - 1], b = cmnd[tau], c = cmnd[tau + 1]
            let denom = a - 2 * b + c
            if abs(denom) > 1e-18 {
                let delta = 0.5 * (a - c) / denom
                if abs(delta) < 1 { refined += delta }
            }
        }
        let f0 = sampleRate / refined
        let confidence = min(max(1 - cmnd[tau], 0), 1)
        let voiced = f0 >= minF0 && f0 <= maxF0
        return PitchFrame(position: center, f0: voiced ? f0 : 0,
                          confidence: confidence, voiced: voiced)
    }

    /// Median f0 of the voiced frames (nil when nothing voiced) — the honest one-number readout.
    static func medianVoicedF0(_ track: [PitchFrame]) -> Double? {
        let v = track.filter { $0.voiced }.map { $0.f0 }.sorted()
        guard !v.isEmpty else { return nil }
        return v.count % 2 == 1 ? v[v.count / 2] : 0.5 * (v[v.count / 2 - 1] + v[v.count / 2])
    }
}

// MARK: - Key / scale

enum MusicalScale: String, Codable, CaseIterable, Sendable {
    case chromatic, major, minor

    /// Pitch-class offsets from the root (natural minor for `.minor`).
    var offsets: [Int] {
        switch self {
        case .chromatic: return Array(0...11)
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        }
    }
}

/// A key = root pitch class (0 = C … 11 = B) + scale, tuned to A4 = 440 Hz.
struct MusicalKey: Equatable, Codable {
    var rootSemitone: Int
    var scale: MusicalScale

    init(rootSemitone: Int = 0, scale: MusicalScale = .chromatic) {
        self.rootSemitone = ((rootSemitone % 12) + 12) % 12
        self.scale = scale
    }

    /// Absolute pitch classes of the scale, ascending.
    var pitchClasses: [Int] {
        scale.offsets.map { (rootSemitone + $0) % 12 }.sorted()
    }

    static func midi(fromHz f: Double) -> Double { 69 + 12 * log2(max(f, 1e-6) / 440.0) }
    static func hz(fromMidi m: Double) -> Double { 440.0 * pow(2.0, (m - 69) / 12.0) }

    /// Nearest scale note (integer MIDI) to a MIDI value.
    func nearestScaleMidi(to m: Double) -> Int {
        let pcs = pitchClasses
        var best = Int(m.rounded())
        var bestDist = Double.greatestFiniteMagnitude
        let base = Int(m.rounded())
        for cand in (base - 7)...(base + 7) {
            let pc = ((cand % 12) + 12) % 12
            guard pcs.contains(pc) else { continue }
            let dist = abs(Double(cand) - m)
            if dist < bestDist { bestDist = dist; best = cand }
        }
        return best
    }

    /// Snap a frequency to the nearest scale note, Hz.
    func nearestNoteHz(to f: Double) -> Double {
        MusicalKey.hz(fromMidi: Double(nearestScaleMidi(to: MusicalKey.midi(fromHz: f))))
    }

    /// Walk `degrees` steps up/down the scale from the scale note nearest `m`. Returns MIDI.
    func scaleDegreeShift(fromMidi m: Double, degrees: Int) -> Int {
        let pcs = pitchClasses
        let count = pcs.count
        let m0 = nearestScaleMidi(to: m)
        let pc0 = ((m0 % 12) + 12) % 12
        let octave0 = (m0 - pc0) / 12
        let idx0 = pcs.firstIndex(of: pc0) ?? 0
        let linear = octave0 * count + idx0 + degrees
        let octave = Int(floor(Double(linear) / Double(count)))
        let idx = ((linear % count) + count) % count
        return octave * 12 + pcs[idx]
    }
}

// MARK: - TD-PSOLA core

/// Shared epoch-synchronous machinery for the shifter / corrector / harmonizer.
enum PSOLA {
    /// Contiguous voiced runs of the track, as sample ranges (single-frame unvoiced
    /// gaps are bridged so one glitchy frame doesn't split a note).
    static func voicedRegions(track: [PitchFrame], hop: Int, totalSamples: Int) -> [Range<Int>] {
        var regions: [Range<Int>] = []
        var runStart = -1
        var lastVoiced = -1
        for (i, f) in track.enumerated() {
            if f.voiced {
                if runStart < 0 { runStart = i }
                lastVoiced = i
            } else if runStart >= 0 && i > lastVoiced + 1 {
                regions.append(regionRange(track, runStart, lastVoiced, hop, totalSamples))
                runStart = -1
            }
        }
        if runStart >= 0 {
            regions.append(regionRange(track, runStart, lastVoiced, hop, totalSamples))
        }
        return regions.filter { $0.count > hop }
    }

    private static func regionRange(_ track: [PitchFrame], _ i0: Int, _ i1: Int,
                                    _ hop: Int, _ n: Int) -> Range<Int> {
        let lo = max(0, track[i0].position - hop / 2)
        let hi = min(n, track[i1].position + hop / 2)
        return lo..<max(lo, hi)
    }

    /// Linear-interpolated f0 at a sample position from the voiced frames of the track.
    static func f0At(_ sample: Int, track: [PitchFrame]) -> Double {
        let voiced = track.filter { $0.voiced }
        guard !voiced.isEmpty else { return 0 }
        if sample <= voiced[0].position { return voiced[0].f0 }
        if sample >= voiced[voiced.count - 1].position { return voiced[voiced.count - 1].f0 }
        for i in 1..<voiced.count where voiced[i].position >= sample {
            let a = voiced[i - 1], b = voiced[i]
            let span = Double(b.position - a.position)
            guard span > 0 else { return a.f0 }
            let t = Double(sample - a.position) / span
            return a.f0 + (b.f0 - a.f0) * t
        }
        return voiced[voiced.count - 1].f0
    }

    /// Pitch marks inside one voiced region: polarity-locked local peaks one period apart.
    static func pitchMarks(mono: [Float], region: Range<Int>, track: [PitchFrame],
                           sampleRate: Double) -> [Int] {
        let f0Start = f0At(region.lowerBound, track: track)
        guard f0Start > 0 else { return [] }
        let t0 = sampleRate / f0Start
        let seedEnd = min(region.lowerBound + Int(t0.rounded()) + 1, region.upperBound)
        guard seedEnd > region.lowerBound else { return [] }

        // Seed: strongest extremum in the first period; its sign locks polarity.
        var seed = region.lowerBound
        var seedMag = -1.0
        for i in region.lowerBound..<seedEnd {
            let a = abs(Double(mono[i]))
            if a > seedMag { seedMag = a; seed = i }
        }
        let polarity: Double = Double(mono[seed]) >= 0 ? 1 : -1

        var marks: [Int] = [seed]
        var pos = Double(seed)
        var guardCount = 0
        while guardCount < 1_000_000 {
            guardCount += 1
            let f0 = f0At(Int(pos.rounded()), track: track)
            guard f0 > 0 else { break }
            let period = sampleRate / f0
            let nominal = pos + period
            guard Int(nominal.rounded()) < region.upperBound - 2 else { break }
            // Re-lock to the polarity-matched peak near the nominal position.
            let win = max(2, Int((period * 0.2).rounded()))
            let lo = max(region.lowerBound, Int(nominal.rounded()) - win)
            let hi = min(region.upperBound - 1, Int(nominal.rounded()) + win)
            var best = Int(nominal.rounded())
            var bestVal = -Double.greatestFiniteMagnitude
            for i in lo...hi {
                let v = Double(mono[i]) * polarity
                if v > bestVal { bestVal = v; best = i }
            }
            marks.append(best)
            pos = Double(best)
        }
        return marks
    }

    /// Epoch-synchronous render: every voiced region is re-synthesized with per-position
    /// pitch ratio `ratioAt` (clamped 0.25…4); unvoiced audio passes through dry;
    /// region edges crossfade over ~6 ms. Same marks drive every channel.
    static func render(input: AudioSignal, mono: [Float], track: [PitchFrame],
                       sampleRate: Double, hop: Int,
                       ratioAt: (Int) -> Double) -> AudioSignal {
        let n = mono.count
        let regions = voicedRegions(track: track, hop: hop, totalSamples: n)
        guard !regions.isEmpty, input.frameCount > 0 else { return input }

        var out = input.channels
        let chCount = input.channelCount

        for region in regions {
            let marks = pitchMarks(mono: mono, region: region, track: track, sampleRate: sampleRate)
            guard marks.count >= 3 else { continue }
            let rs = region.lowerBound
            let rLen = region.count
            var scratch = [[Double]](repeating: [Double](repeating: 0, count: rLen), count: chCount)
            var norm = [Double](repeating: 0, count: rLen)

            var tS = Double(marks[0])
            var guardCount = 0
            while tS < Double(region.upperBound) && guardCount < 1_000_000 {
                guardCount += 1
                let tSi = Int(tS.rounded())
                // Nearest analysis mark (marks are sorted).
                var lo = 0, hi = marks.count - 1
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if marks[mid] < tSi { lo = mid + 1 } else { hi = mid }
                }
                if lo > 0 && abs(marks[lo - 1] - tSi) < abs(marks[lo] - tSi) { lo -= 1 }
                let aIdx = lo
                let a = marks[aIdx]
                // Local analysis period from the neighbouring mark gaps.
                let gapL = aIdx > 0 ? Double(marks[aIdx] - marks[aIdx - 1]) : 0
                let gapR = aIdx < marks.count - 1 ? Double(marks[aIdx + 1] - marks[aIdx]) : 0
                var tIn = gapL > 0 && gapR > 0 ? 0.5 * (gapL + gapR) : max(gapL, gapR)
                if tIn <= 0 {
                    let f0 = f0At(a, track: track)
                    guard f0 > 0 else { break }
                    tIn = sampleRate / f0
                }
                let ratio = min(max(ratioAt(tSi), 0.25), 4.0)
                let tOut = tIn / ratio

                // 2-period Hann grain from the analysis mark, added at the synthesis mark.
                let len = min(max(Int((2 * tIn).rounded()), 32), 4096)
                let half = len / 2
                for k in 0..<len {
                    let srcIdx = a - half + k
                    guard srcIdx >= 0 && srcIdx < n else { continue }
                    let dstIdx = tSi - half + k - rs
                    guard dstIdx >= 0 && dstIdx < rLen else { continue }
                    let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(len - 1))
                    for c in 0..<chCount {
                        scratch[c][dstIdx] += Double(input.channels[c][srcIdx]) * w
                    }
                    norm[dstIdx] += w
                }
                tS += tOut
            }

            // Normalized OLA back into the dry buffer with edge crossfades.
            let fade = max(1, min(256, rLen / 4))
            for i in 0..<rLen {
                guard norm[i] > 1e-4 else { continue }          // no grain coverage → keep dry
                let edge = min(i, rLen - 1 - i)
                let ramp = min(1.0, Double(edge) / Double(fade))
                for c in 0..<chCount {
                    let wet = scratch[c][i] / norm[i]
                    let dry = Double(input.channels[c][rs + i])
                    out[c][rs + i] = Float(min(max(dry * (1 - ramp) + wet * ramp, -4.0), 4.0))
                }
            }
        }
        return AudioSignal(channels: out, sampleRate: input.sampleRate)
    }
}

// MARK: - Pitch shifter (row 26 machinery / spec quality bar)

struct PitchShifterSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    /// Shift, semitones (±24). 0 = passthrough.
    var semitones: Double
    /// TD-PSOLA preserves the spectral envelope by construction; false re-warps the
    /// envelope by the pitch ratio (resample-style character).
    var formantPreserve: Bool
    /// Wet blend 0…1.
    var mix: Double

    init(enabled: Bool, semitones: Double = 0, formantPreserve: Bool = true, mix: Double = 1.0) {
        self.enabled = enabled
        self.semitones = min(max(semitones, -24), 24)
        self.formantPreserve = formantPreserve
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = PitchShifterSettings(enabled: false)

    private enum CodingKeys: String, CodingKey { case enabled, semitones, formantPreserve, mix }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  semitones: try c.decodeIfPresent(Double.self, forKey: .semitones) ?? 0,
                  formantPreserve: try c.decodeIfPresent(Bool.self, forKey: .formantPreserve) ?? true,
                  mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1.0)
    }
}

final class PitchShifter {
    let settings: PitchShifterSettings
    let sampleRate: Double
    /// Median voiced f0 of the last input, Hz (0 = nothing voiced) — measured.
    private(set) var lastInputF0: Double = 0

    init(settings: PitchShifterSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, abs(settings.semitones) > 1e-4,
              s.channelCount > 0, s.frameCount > 0 else { return s }
        let mono = PitchEngineUtil.monoAverage(s)
        let det = PitchDetector(sampleRate: sampleRate)
        let track = det.track(mono)
        lastInputF0 = PitchDetector.medianVoicedF0(track) ?? 0
        guard track.contains(where: { $0.voiced }) else { return s }   // honest: nothing to shift

        let ratio = pow(2.0, settings.semitones / 12.0)
        var wet = PSOLA.render(input: s, mono: mono, track: track,
                               sampleRate: sampleRate, hop: det.hop) { _ in ratio }
        if !settings.formantPreserve {
            let fs = FormantShifter(settings: FormantShifterSettings(enabled: true,
                                                                     semitones: settings.semitones),
                                    sampleRate: sampleRate)
            wet = fs.process(wet)
        }
        return PitchEngineUtil.blend(dry: s, wet: wet, mix: settings.mix)
    }
}

// MARK: - Pitch correction (row 26)

struct PitchCorrectionSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    var key: MusicalKey
    /// Glide time toward the snapped note, ms. 0 = instant (hard tune).
    var retuneMs: Double
    /// 0 = untouched (bit-transparent), 1 = fully on the snapped note.
    var strength: Double

    init(enabled: Bool, key: MusicalKey = MusicalKey(), retuneMs: Double = 20, strength: Double = 1.0) {
        self.enabled = enabled
        self.key = key
        self.retuneMs = min(max(retuneMs, 0), 500)
        self.strength = min(max(strength, 0), 1)
    }

    static let bypassed = PitchCorrectionSettings(enabled: false)

    private enum CodingKeys: String, CodingKey { case enabled, key, retuneMs, strength }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  key: try c.decodeIfPresent(MusicalKey.self, forKey: .key) ?? MusicalKey(),
                  retuneMs: try c.decodeIfPresent(Double.self, forKey: .retuneMs) ?? 20,
                  strength: try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1.0)
    }
}

final class PitchCorrector {
    let settings: PitchCorrectionSettings
    let sampleRate: Double
    /// Largest correction actually applied on the last pass, cents ≥ 0 — measured.
    private(set) var lastMaxCorrectionCents: Double = 0

    init(settings: PitchCorrectionSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, settings.strength > 1e-4,
              s.channelCount > 0, s.frameCount > 0 else { return s }
        let mono = PitchEngineUtil.monoAverage(s)
        let det = PitchDetector(sampleRate: sampleRate)
        let track = det.track(mono)
        guard track.contains(where: { $0.voiced }) else { return s }

        // Per-frame correction ratio, glided in the cents domain.
        let hopSeconds = Double(det.hop) / sampleRate
        let alpha = settings.retuneMs <= 0.0
            ? 0.0
            : exp(-hopSeconds * 1000.0 / settings.retuneMs)
        var ratios = [Double](repeating: 1, count: track.count)
        var glideCents = 0.0
        var glideSeeded = false
        var maxCents = 0.0
        for (i, f) in track.enumerated() {
            guard f.voiced, f.f0 > 0 else { glideSeeded = false; continue }
            let currentMidi = MusicalKey.midi(fromHz: f.f0)
            let targetMidi = Double(settings.key.nearestScaleMidi(to: currentMidi))
            let targetCents = (targetMidi - currentMidi) * 100.0
            if !glideSeeded { glideCents = targetCents; glideSeeded = true }
            else { glideCents = alpha * glideCents + (1 - alpha) * targetCents }
            let applied = glideCents * settings.strength
            ratios[i] = pow(2.0, applied / 1200.0)
            maxCents = max(maxCents, abs(applied))
        }
        lastMaxCorrectionCents = maxCents

        let positions = track.map { $0.position }
        let out = PSOLA.render(input: s, mono: mono, track: track,
                               sampleRate: sampleRate, hop: det.hop) { sample in
            PitchEngineUtil.interp(positions: positions, values: ratios, at: sample)
        }
        return out
    }
}

// MARK: - Harmonizer (row 27)

/// A voice interval: fixed semitones, or diatonic scale degrees in the harmonizer's key.
enum HarmonyInterval: Equatable, Codable {
    case semitones(Int)
    case scaleDegrees(Int)
}

struct HarmonyVoice: Equatable, Codable {
    var enabled: Bool
    var interval: HarmonyInterval
    /// Voice gain, dB (applied to the shifted copy only).
    var gainDB: Double
    /// Constant-power pan, −1 (L) … +1 (R).
    var pan: Double

    init(enabled: Bool = true, interval: HarmonyInterval = .semitones(7),
         gainDB: Double = -3, pan: Double = 0) {
        self.enabled = enabled
        self.interval = interval
        self.gainDB = min(max(gainDB, -60), 12)
        self.pan = min(max(pan, -1), 1)
    }

    private enum CodingKeys: String, CodingKey { case enabled, interval, gainDB, pan }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
                  interval: try c.decodeIfPresent(HarmonyInterval.self, forKey: .interval) ?? .semitones(7),
                  gainDB: try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? -3,
                  pan: try c.decodeIfPresent(Double.self, forKey: .pan) ?? 0)
    }
}

struct HarmonizerSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    /// Key for `.scaleDegrees` voices (fixed-semitone voices ignore it).
    var key: MusicalKey
    /// Up to 4 voices are rendered (extras are ignored, honestly, not silently mixed).
    var voices: [HarmonyVoice]
    /// Dry level 0…1 (1 keeps the input untouched under the added voices).
    var dryLevel: Double

    static let maxVoices = 4

    init(enabled: Bool, key: MusicalKey = MusicalKey(rootSemitone: 0, scale: .major),
         voices: [HarmonyVoice] = [HarmonyVoice()], dryLevel: Double = 1.0) {
        self.enabled = enabled
        self.key = key
        self.voices = voices
        self.dryLevel = min(max(dryLevel, 0), 1)
    }

    static let bypassed = HarmonizerSettings(enabled: false)

    var activeVoices: [HarmonyVoice] { Array(voices.filter { $0.enabled }.prefix(Self.maxVoices)) }

    private enum CodingKeys: String, CodingKey { case enabled, key, voices, dryLevel }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  key: try c.decodeIfPresent(MusicalKey.self, forKey: .key) ?? MusicalKey(rootSemitone: 0, scale: .major),
                  voices: try c.decodeIfPresent([HarmonyVoice].self, forKey: .voices) ?? [HarmonyVoice()],
                  dryLevel: try c.decodeIfPresent(Double.self, forKey: .dryLevel) ?? 1.0)
    }
}

final class Harmonizer {
    let settings: HarmonizerSettings
    let sampleRate: Double
    /// Median pitch ratio each rendered voice actually used — measured.
    private(set) var lastVoiceRatios: [Double] = []

    init(settings: HarmonizerSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        let voices = settings.activeVoices
        guard settings.enabled, !voices.isEmpty,
              s.channelCount > 0, s.frameCount > 0 else { return s }
        let mono = PitchEngineUtil.monoAverage(s)
        let det = PitchDetector(sampleRate: sampleRate)
        let track = det.track(mono)
        guard track.contains(where: { $0.voiced }) else { return s }
        let positions = track.map { $0.position }

        // Dry bed (dryLevel 1 keeps the input bit-exact under the voices).
        var out = s.channels
        if settings.dryLevel < 1.0 {
            for c in 0..<out.count {
                for i in 0..<out[c].count { out[c][i] = Float(Double(out[c][i]) * settings.dryLevel) }
            }
        }

        lastVoiceRatios = []
        for voice in voices {
            // Per-frame ratio for this voice.
            var ratios = [Double](repeating: 1, count: track.count)
            for (i, f) in track.enumerated() {
                guard f.voiced, f.f0 > 0 else { continue }
                switch voice.interval {
                case .semitones(let st):
                    ratios[i] = pow(2.0, Double(st) / 12.0)
                case .scaleDegrees(let deg):
                    let m = MusicalKey.midi(fromHz: f.f0)
                    let target = settings.key.scaleDegreeShift(fromMidi: m, degrees: deg)
                    ratios[i] = MusicalKey.hz(fromMidi: Double(target)) / f.f0
                }
            }
            let sortedR = ratios.enumerated().filter { track[$0.offset].voiced }.map { $0.element }.sorted()
            lastVoiceRatios.append(sortedR.isEmpty ? 1 : sortedR[sortedR.count / 2])

            let shifted = PSOLA.render(input: s, mono: mono, track: track,
                                       sampleRate: sampleRate, hop: det.hop) { sample in
                PitchEngineUtil.interp(positions: positions, values: ratios, at: sample)
            }
            // Constant-power pan + gain into the bed (unity at center, √2 at the hard edges).
            let g = pow(10.0, voice.gainDB / 20.0)
            let theta = (voice.pan + 1) * Double.pi / 4
            let panL = cos(theta) / cos(Double.pi / 4)
            let panR = sin(theta) / sin(Double.pi / 4)
            for c in 0..<out.count {
                let pg = out.count >= 2 ? (c == 0 ? panL : (c == 1 ? panR : 1.0)) : 1.0
                for i in 0..<out[c].count {
                    let v = Double(out[c][i]) + Double(shifted.channels[c][i]) * g * pg
                    out[c][i] = Float(min(max(v, -4.0), 4.0))
                }
            }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }
}

// MARK: - Formant shifter (row 29)

struct FormantShifterSettings: Equatable, Codable {
    /// When false the stage is a true bypass (output == input, untouched).
    var enabled: Bool
    /// Envelope shift, semitones (±12). 0 = passthrough. + moves formants UP.
    var semitones: Double
    /// Wet blend 0…1.
    var mix: Double

    init(enabled: Bool, semitones: Double = 0, mix: Double = 1.0) {
        self.enabled = enabled
        self.semitones = min(max(semitones, -12), 12)
        self.mix = min(max(mix, 0), 1)
    }

    static let bypassed = FormantShifterSettings(enabled: false)

    private enum CodingKeys: String, CodingKey { case enabled, semitones, mix }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
                  semitones: try c.decodeIfPresent(Double.self, forKey: .semitones) ?? 0,
                  mix: try c.decodeIfPresent(Double.self, forKey: .mix) ?? 1.0)
    }
}

final class FormantShifter {
    let settings: FormantShifterSettings
    let sampleRate: Double
    static let fftSize = 2048
    static let hop = 512
    /// Envelope-delta clamp, dB (guards low-envelope bins from noise blowups).
    static let maxEnvelopeMoveDB = 24.0

    init(settings: FormantShifterSettings, sampleRate: Double) {
        self.settings = settings
        self.sampleRate = max(1.0, sampleRate)
    }

    func process(_ s: AudioSignal) -> AudioSignal {
        guard settings.enabled, abs(settings.semitones) > 1e-4,
              s.channelCount > 0, s.frameCount > 0 else { return s }
        let alpha = pow(2.0, settings.semitones / 12.0)
        let n = s.frameCount
        let fft = Self.fftSize
        let hop = Self.hop
        let half = fft / 2
        // Lifter cutoff: envelope only (quefrency below ~1/(90 Hz)·0.45 ⇒ ≈200 Hz resolution).
        let lifterCut = min(fft / 2 - 1, Int(sampleRate / 90.0 * 0.45))
        let clampNat = Self.maxEnvelopeMoveDB / 8.685889638   // dB → nepers (ln domain)

        var window = [Double](repeating: 0, count: fft)
        for i in 0..<fft { window[i] = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(fft - 1)) }

        var outChannels: [[Float]] = []
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            var acc = [Double](repeating: 0, count: n)
            var norm = [Double](repeating: 0, count: n)
            var start = 0
            while start < n {
                // Windowed frame (zero-padded past the end).
                var re = [Double](repeating: 0, count: fft)
                var im = [Double](repeating: 0, count: fft)
                for j in 0..<fft {
                    let idx = start + j
                    re[j] = idx < n ? Double(src[idx]) * window[j] : 0
                }
                SmallFFT.fft(&re, &im, inverse: false)

                // Magnitude / phase; log-envelope via liftered cepstrum.
                var mag = [Double](repeating: 0, count: fft)
                var logMag = [Double](repeating: 0, count: fft)
                for k in 0..<fft {
                    mag[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot()
                    logMag[k] = log(max(mag[k], 1e-9))
                }
                var cepRe = logMag
                var cepIm = [Double](repeating: 0, count: fft)
                SmallFFT.fft(&cepRe, &cepIm, inverse: false)
                for q in 0..<fft {
                    let keep = q <= lifterCut || q >= fft - lifterCut
                    if !keep { cepRe[q] = 0; cepIm[q] = 0 }
                }
                SmallFFT.fft(&cepRe, &cepIm, inverse: true)
                let envLog = cepRe                                  // smooth log envelope

                // Warp the envelope by alpha and re-weight the magnitudes (phase untouched).
                for k in 0...half {
                    let srcBin = Double(k) / alpha
                    var warped: Double
                    if srcBin >= Double(half) {
                        warped = envLog[half]
                    } else {
                        let k0 = Int(srcBin)
                        let frac = srcBin - Double(k0)
                        warped = envLog[k0] * (1 - frac) + envLog[min(k0 + 1, half)] * frac
                    }
                    let delta = min(max(warped - envLog[k], -clampNat), clampNat)
                    let scale = exp(delta)
                    let kMirror = k == 0 ? 0 : fft - k
                    re[k] *= scale; im[k] *= scale
                    if kMirror != k && kMirror > half {
                        re[kMirror] *= scale; im[kMirror] *= scale
                    }
                }
                SmallFFT.fft(&re, &im, inverse: true)

                // Hann²-OLA (analysis + synthesis windows, norm divided out per sample).
                for j in 0..<fft {
                    let idx = start + j
                    guard idx < n else { break }
                    acc[idx] += re[j] * window[j]
                    norm[idx] += window[j] * window[j]
                }
                start += hop
            }

            var outCh = [Float](repeating: 0, count: n)
            let mix = settings.mix
            for i in 0..<n {
                let dry = Double(src[i])
                let wet = norm[i] > 1e-6 ? acc[i] / norm[i] : dry
                let v = dry * (1 - mix) + wet * mix
                outCh[i] = Float(min(max(v, -4.0), 4.0))
            }
            outChannels.append(outCh)
        }
        return AudioSignal(channels: outChannels, sampleRate: s.sampleRate)
    }
}

// MARK: - Shared helpers

enum PitchEngineUtil {
    /// Channel-average mono for detection (keeps every channel driven by ONE track).
    static func monoAverage(_ s: AudioSignal) -> [Float] {
        let n = s.frameCount
        guard s.channelCount > 1 else { return s.channels.first ?? [] }
        var mono = [Float](repeating: 0, count: n)
        let scale = Float(1.0 / Double(s.channelCount))
        for ch in s.channels {
            for i in 0..<min(n, ch.count) { mono[i] += ch[i] * scale }
        }
        return mono
    }

    /// Linear interpolation of per-frame values at a sample position.
    static func interp(positions: [Int], values: [Double], at sample: Int) -> Double {
        guard !positions.isEmpty else { return 1 }
        if sample <= positions[0] { return values[0] }
        if sample >= positions[positions.count - 1] { return values[values.count - 1] }
        for i in 1..<positions.count where positions[i] >= sample {
            let span = Double(positions[i] - positions[i - 1])
            guard span > 0 else { return values[i - 1] }
            let t = Double(sample - positions[i - 1]) / span
            return values[i - 1] + (values[i] - values[i - 1]) * t
        }
        return values[values.count - 1]
    }

    /// Sample-exact dry/wet blend (mix 1 returns wet untouched).
    static func blend(dry: AudioSignal, wet: AudioSignal, mix: Double) -> AudioSignal {
        guard mix < 1.0 else { return wet }
        var out = wet.channels
        for c in 0..<out.count {
            let dc = dry.channels.indices.contains(c) ? dry.channels[c] : []
            for i in 0..<out[c].count {
                let d = i < dc.count ? Double(dc[i]) : 0
                out[c][i] = Float(d * (1 - mix) + Double(out[c][i]) * mix)
            }
        }
        return AudioSignal(channels: out, sampleRate: wet.sampleRate)
    }
}

/// Minimal iterative radix-2 complex FFT (Double, deterministic, offline-grade).
/// Inverse includes the 1/N scale, so fft→ifft round-trips to the input.
enum SmallFFT {
    static func fft(_ re: inout [Double], _ im: inout [Double], inverse: Bool) {
        let n = re.count
        guard n > 1, n & (n - 1) == 0, im.count == n else { return }

        // Bit-reversal permutation.
        var j = 0
        for i in 0..<(n - 1) {
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
            var m = n >> 1
            while m >= 1 && j & m != 0 { j ^= m; m >>= 1 }
            j |= m
        }
        // Danielson–Lanczos.
        var len = 2
        while len <= n {
            let ang = (inverse ? 2.0 : -2.0) * Double.pi / Double(len)
            let wR = cos(ang), wI = sin(ang)
            var i = 0
            while i < n {
                var curR = 1.0, curI = 0.0
                for k in 0..<(len / 2) {
                    let a = i + k, b = i + k + len / 2
                    let tR = re[b] * curR - im[b] * curI
                    let tI = re[b] * curI + im[b] * curR
                    re[b] = re[a] - tR; im[b] = im[a] - tI
                    re[a] += tR; im[a] += tI
                    let nR = curR * wR - curI * wI
                    curI = curR * wI + curI * wR
                    curR = nR
                }
                i += len
            }
            len <<= 1
        }
        if inverse {
            let s = 1.0 / Double(n)
            for i in 0..<n { re[i] *= s; im[i] *= s }
        }
    }
}
