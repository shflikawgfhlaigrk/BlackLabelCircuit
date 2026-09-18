// InsertParams.swift — Phase 4 of SUNSET-EFFECTS-STANDARD: the shared insert-parameter
// binding layer.
//
// Every insert kind exposes its REAL Settings fields as descriptor tables:
//   • `params`  — continuous parameters (label / unit / range / step straight from the
//                 Settings struct's documented clamps — §5.1: nothing invented here),
//   • `choices` — discrete parameters (mode / key / scale / carrier pickers).
// The MIX console builds its per-insert parameter rows from these descriptors, and the
// regression suite mutates settings through the SAME get/set closures — so the exact code
// path the UI binds to is the one that is tested and persisted. Foundation-only on purpose:
// this file is part of the headless test + CLI build.

import Foundation

// MARK: - Descriptors

/// One continuous insert parameter. Range/step/unit mirror the Settings struct's clamps.
struct InsertParam: Identifiable {
    let id: String
    let label: String
    let unit: String
    let range: ClosedRange<Double>
    let step: Double
    let format: String
    var displayScale: Double = 1
    let get: (InsertEffect) -> Double
    let set: (inout InsertEffect, Double) -> Void
}

/// One discrete insert parameter (a picker): `options` are the display labels,
/// get/set speak in option indices.
struct InsertChoice: Identifiable {
    let id: String
    let label: String
    let options: [String]
    let get: (InsertEffect) -> Int
    let set: (inout InsertEffect, Int) -> Void
}

// MARK: - Enable toggle (per slot)

extension InsertEffect {
    /// Flip this slot's enabled flag in place (the payload survives, so re-enabling
    /// restores the exact same settings).
    mutating func setEnabled(_ on: Bool) {
        switch self {
        case .chorus(var s): s.enabled = on; self = .chorus(s)
        case .flanger(var s): s.enabled = on; self = .flanger(s)
        case .phaser(var s): s.enabled = on; self = .phaser(s)
        case .tremolo(var s): s.enabled = on; self = .tremolo(s)
        case .vibrato(var s): s.enabled = on; self = .vibrato(s)
        case .autoPan(var s): s.enabled = on; self = .autoPan(s)
        case .bitcrusher(var s): s.enabled = on; self = .bitcrusher(s)
        case .distortion(var s): s.enabled = on; self = .distortion(s)
        case .ringMod(var s): s.enabled = on; self = .ringMod(s)
        case .resonator(var s): s.enabled = on; self = .resonator(s)
        case .frequencyShifter(var s): s.enabled = on; self = .frequencyShifter(s)
        case .filterFX(var s): s.enabled = on; self = .filterFX(s)
        case .pitchCorrection(var s): s.enabled = on; self = .pitchCorrection(s)
        case .harmonizer(var s): s.enabled = on; self = .harmonizer(s)
        case .vocoder(var s): s.enabled = on; self = .vocoder(s)
        case .formantShifter(var s): s.enabled = on; self = .formantShifter(s)
        }
    }
}

// MARK: - Per-kind settings accessors (voice/array editors + tests)

extension InsertEffect {
    var resonatorSettings: ResonatorSettings? {
        if case .resonator(let s) = self { return s }; return nil
    }
    mutating func setResonator(_ s: ResonatorSettings) {
        if case .resonator = self { self = .resonator(s) }
    }
    var harmonizerSettings: HarmonizerSettings? {
        if case .harmonizer(let s) = self { return s }; return nil
    }
    mutating func setHarmonizer(_ s: HarmonizerSettings) {
        if case .harmonizer = self { self = .harmonizer(s) }
    }
    var pitchCorrectionSettings: PitchCorrectionSettings? {
        if case .pitchCorrection(let s) = self { return s }; return nil
    }
    var vocoderSettings: VocoderSettings? {
        if case .vocoder(let s) = self { return s }; return nil
    }
}

/// Capped voice add for the harmonizer (renders at most `maxVoices` — the editor
/// enforces the same cap so the UI never shows a voice the engine would ignore).
extension HarmonizerSettings {
    @discardableResult mutating func addVoice() -> Bool {
        guard voices.count < Self.maxVoices else { return false }
        voices.append(HarmonyVoice(enabled: true, interval: .semitones(7), gainDB: -3, pan: 0))
        return true
    }
}

/// Capped voice add for the resonator ("small bank" — the settings init caps at 8).
extension ResonatorSettings {
    static let maxVoices = 8
    @discardableResult mutating func addVoice() -> Bool {
        guard voices.count < Self.maxVoices else { return false }
        voices.append(ResonatorVoice(freqHz: 440, decaySeconds: 0.5, gain: 0.8))
        return true
    }
}

// MARK: - Descriptor factory

private func mkParam<S>(_ extract: @escaping (InsertEffect) -> S?,
                        _ embed: @escaping (S) -> InsertEffect,
                        _ id: String, _ label: String, unit: String,
                        range: ClosedRange<Double>, step: Double, format: String,
                        displayScale: Double = 1,
                        get: @escaping (S) -> Double,
                        set: @escaping (inout S, Double) -> Void) -> InsertParam {
    InsertParam(id: id, label: label, unit: unit, range: range, step: step,
                format: format, displayScale: displayScale,
                get: { fx in extract(fx).map(get) ?? range.lowerBound },
                set: { fx, v in
                    guard var s = extract(fx) else { return }
                    set(&s, v)
                    fx = embed(s)
                })
}

private func mkChoice<S>(_ extract: @escaping (InsertEffect) -> S?,
                         _ embed: @escaping (S) -> InsertEffect,
                         _ id: String, _ label: String, options: [String],
                         get: @escaping (S) -> Int,
                         set: @escaping (inout S, Int) -> Void) -> InsertChoice {
    InsertChoice(id: id, label: label, options: options,
                 get: { fx in extract(fx).map(get) ?? 0 },
                 set: { fx, i in
                     guard var s = extract(fx), options.indices.contains(i) else { return }
                     set(&s, i)
                     fx = embed(s)
                 })
}

/// Root-note display names for key pickers (0 = C … 11 = B, matching MusicalKey).
let musicalRootNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

// MARK: - The per-kind tables

extension InsertEffect {
    /// Continuous parameters for THIS insert kind, in display order.
    var params: [InsertParam] {
        switch self {
        case .chorus:
            let ex: (InsertEffect) -> ChorusSettings? = { if case .chorus(let s) = $0 { return s }; return nil }
            let em: (ChorusSettings) -> InsertEffect = { .chorus($0) }
            return [
                mkParam(ex, em, "chorus.rate", "Rate", unit: "Hz", range: 0.05...10, step: 0.05, format: "%.2f",
                        get: { $0.rateHz }, set: { $0.rateHz = $1 }),
                mkParam(ex, em, "chorus.depth", "Depth", unit: "ms", range: 0.1...15, step: 0.1, format: "%.1f",
                        get: { $0.depthMs }, set: { $0.depthMs = $1 }),
                mkParam(ex, em, "chorus.base", "Delay", unit: "ms", range: 5...40, step: 0.5, format: "%.1f",
                        get: { $0.baseDelayMs }, set: { $0.baseDelayMs = $1 }),
                mkParam(ex, em, "chorus.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }),
            ]
        case .flanger:
            let ex: (InsertEffect) -> FlangerSettings? = { if case .flanger(let s) = $0 { return s }; return nil }
            let em: (FlangerSettings) -> InsertEffect = { .flanger($0) }
            return [
                mkParam(ex, em, "flanger.rate", "Rate", unit: "Hz", range: 0.02...5, step: 0.02, format: "%.2f",
                        get: { $0.rateHz }, set: { $0.rateHz = $1 }),
                mkParam(ex, em, "flanger.depth", "Depth", unit: "ms", range: 0.1...10, step: 0.1, format: "%.1f",
                        get: { $0.depthMs }, set: { $0.depthMs = $1 }),
                mkParam(ex, em, "flanger.base", "Delay", unit: "ms", range: 0.1...10, step: 0.1, format: "%.1f",
                        get: { $0.baseDelayMs }, set: { $0.baseDelayMs = $1 }),
                mkParam(ex, em, "flanger.fb", "Feedback", unit: "", range: -0.9...0.9, step: 0.05, format: "%+.2f",
                        get: { $0.feedback }, set: { $0.feedback = $1 }),
                mkParam(ex, em, "flanger.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }),
            ]
        case .phaser:
            let ex: (InsertEffect) -> PhaserSettings? = { if case .phaser(let s) = $0 { return s }; return nil }
            let em: (PhaserSettings) -> InsertEffect = { .phaser($0) }
            return [
                mkParam(ex, em, "phaser.rate", "Rate", unit: "Hz", range: 0.02...5, step: 0.02, format: "%.2f",
                        get: { $0.rateHz }, set: { $0.rateHz = $1 }),
                mkParam(ex, em, "phaser.min", "Sweep lo", unit: "Hz", range: 40...10_000, step: 10, format: "%.0f",
                        get: { $0.minHz }, set: { $0.minHz = $1 }),
                mkParam(ex, em, "phaser.max", "Sweep hi", unit: "Hz", range: 200...16_000, step: 10, format: "%.0f",
                        get: { $0.maxHz }, set: { $0.maxHz = max($1, $0.minHz + 10) }),
                mkParam(ex, em, "phaser.fb", "Feedback", unit: "", range: 0...0.9, step: 0.05, format: "%.2f",
                        get: { $0.feedback }, set: { $0.feedback = $1 }),
                mkParam(ex, em, "phaser.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }),
            ]
        case .tremolo:
            let ex: (InsertEffect) -> TremoloSettings? = { if case .tremolo(let s) = $0 { return s }; return nil }
            let em: (TremoloSettings) -> InsertEffect = { .tremolo($0) }
            return [
                mkParam(ex, em, "tremolo.rate", "Rate", unit: "Hz", range: 0.05...20, step: 0.05, format: "%.2f",
                        get: { $0.rateHz }, set: { $0.rateHz = $1 }),
                mkParam(ex, em, "tremolo.depth", "Depth", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.depth }, set: { $0.depth = $1 }),
            ]
        case .vibrato:
            let ex: (InsertEffect) -> VibratoSettings? = { if case .vibrato(let s) = $0 { return s }; return nil }
            let em: (VibratoSettings) -> InsertEffect = { .vibrato($0) }
            return [
                mkParam(ex, em, "vibrato.rate", "Rate", unit: "Hz", range: 0.1...12, step: 0.05, format: "%.2f",
                        get: { $0.rateHz }, set: { $0.rateHz = $1 }),
                mkParam(ex, em, "vibrato.depth", "Depth", unit: "ms", range: 0.1...8, step: 0.1, format: "%.1f",
                        get: { $0.depthMs }, set: { $0.depthMs = $1 }),
            ]
        case .autoPan:
            let ex: (InsertEffect) -> AutoPanSettings? = { if case .autoPan(let s) = $0 { return s }; return nil }
            let em: (AutoPanSettings) -> InsertEffect = { .autoPan($0) }
            return [
                mkParam(ex, em, "autopan.rate", "Rate", unit: "Hz", range: 0.05...10, step: 0.05, format: "%.2f",
                        get: { $0.rateHz }, set: { $0.rateHz = $1 }),
                mkParam(ex, em, "autopan.depth", "Width", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.depth }, set: { $0.depth = $1 }),
            ]
        case .bitcrusher:
            let ex: (InsertEffect) -> BitcrusherSettings? = { if case .bitcrusher(let s) = $0 { return s }; return nil }
            let em: (BitcrusherSettings) -> InsertEffect = { .bitcrusher($0) }
            return [
                mkParam(ex, em, "crush.bits", "Bits", unit: "bit", range: 2...24, step: 1, format: "%.0f",
                        get: { Double($0.bits) }, set: { $0.bits = Int($1.rounded()) }),
                mkParam(ex, em, "crush.down", "Downsmpl", unit: "×", range: 1...64, step: 1, format: "%.0f",
                        get: { Double($0.downsample) }, set: { $0.downsample = Int($1.rounded()) }),
                mkParam(ex, em, "crush.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }),
            ]
        case .distortion:
            let ex: (InsertEffect) -> DistortionSettings? = { if case .distortion(let s) = $0 { return s }; return nil }
            let em: (DistortionSettings) -> InsertEffect = { .distortion($0) }
            return [
                mkParam(ex, em, "dist.drive", "Drive", unit: "dB", range: 0...36, step: 0.5, format: "%.1f",
                        get: { $0.driveDB }, set: { $0.driveDB = $1 }),
                mkParam(ex, em, "dist.tone", "Tone", unit: "Hz", range: 500...20_000, step: 100, format: "%.0f",
                        get: { $0.toneHz }, set: { $0.toneHz = $1 }),
                mkParam(ex, em, "dist.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }),
            ]
        case .ringMod:
            let ex: (InsertEffect) -> RingModSettings? = { if case .ringMod(let s) = $0 { return s }; return nil }
            let em: (RingModSettings) -> InsertEffect = { .ringMod($0) }
            return [
                mkParam(ex, em, "ring.carrier", "Carrier", unit: "Hz", range: 1...10_000, step: 1, format: "%.0f",
                        get: { $0.carrierHz }, set: { $0.carrierHz = $1 }),
                mkParam(ex, em, "ring.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }),
            ]
        case .resonator:
            let ex: (InsertEffect) -> ResonatorSettings? = { if case .resonator(let s) = $0 { return s }; return nil }
            let em: (ResonatorSettings) -> InsertEffect = { .resonator($0) }
            return [
                mkParam(ex, em, "res.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }),
            ]
        case .frequencyShifter:
            let ex: (InsertEffect) -> FrequencyShifterSettings? = { if case .frequencyShifter(let s) = $0 { return s }; return nil }
            let em: (FrequencyShifterSettings) -> InsertEffect = { .frequencyShifter($0) }
            return [
                mkParam(ex, em, "shift.hz", "Shift", unit: "Hz", range: -5000...5000, step: 1, format: "%+.0f",
                        get: { $0.shiftHz }, set: { $0.shiftHz = $1 }),
                mkParam(ex, em, "shift.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }),
            ]
        case .filterFX:
            let ex: (InsertEffect) -> FilterFXSettings? = { if case .filterFX(let s) = $0 { return s }; return nil }
            let em: (FilterFXSettings) -> InsertEffect = { .filterFX($0) }
            var list: [InsertParam] = [
                mkParam(ex, em, "ffx.min", "Freq lo", unit: "Hz", range: 20...16_000, step: 10, format: "%.0f",
                        get: { $0.minHz }, set: { $0.minHz = $1 }),
                mkParam(ex, em, "ffx.max", "Freq hi", unit: "Hz", range: 20...16_000, step: 10, format: "%.0f",
                        get: { $0.maxHz }, set: { $0.maxHz = max($1, $0.minHz) }),
                mkParam(ex, em, "ffx.res", "Reso", unit: "Q", range: 0.5...12, step: 0.1, format: "%.1f",
                        get: { $0.resonance }, set: { $0.resonance = $1 }),
            ]
            if let s = ex(self) {
                switch s.sweep {
                case .lfo:
                    list.append(mkParam(ex, em, "ffx.rate", "LFO rate", unit: "Hz", range: 0.02...10, step: 0.02,
                                        format: "%.2f", get: { $0.rateHz }, set: { $0.rateHz = $1 }))
                case .envelope:
                    list.append(mkParam(ex, em, "ffx.atk", "Env atk", unit: "ms", range: 0.1...200, step: 0.1,
                                        format: "%.1f", get: { $0.envAttackMs }, set: { $0.envAttackMs = $1 }))
                    list.append(mkParam(ex, em, "ffx.rel", "Env rel", unit: "ms", range: 1...1000, step: 1,
                                        format: "%.0f", get: { $0.envReleaseMs }, set: { $0.envReleaseMs = $1 }))
                case .none:
                    break
                }
            }
            list.append(mkParam(ex, em, "ffx.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                                displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }))
            return list
        case .pitchCorrection:
            let ex: (InsertEffect) -> PitchCorrectionSettings? = { if case .pitchCorrection(let s) = $0 { return s }; return nil }
            let em: (PitchCorrectionSettings) -> InsertEffect = { .pitchCorrection($0) }
            return [
                mkParam(ex, em, "tune.retune", "Retune", unit: "ms", range: 0...500, step: 5, format: "%.0f",
                        get: { $0.retuneMs }, set: { $0.retuneMs = $1 }),
                mkParam(ex, em, "tune.strength", "Strength", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.strength }, set: { $0.strength = $1 }),
            ]
        case .harmonizer:
            let ex: (InsertEffect) -> HarmonizerSettings? = { if case .harmonizer(let s) = $0 { return s }; return nil }
            let em: (HarmonizerSettings) -> InsertEffect = { .harmonizer($0) }
            return [
                mkParam(ex, em, "harm.dry", "Dry", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.dryLevel }, set: { $0.dryLevel = $1 }),
            ]
        case .vocoder:
            let ex: (InsertEffect) -> VocoderSettings? = { if case .vocoder(let s) = $0 { return s }; return nil }
            let em: (VocoderSettings) -> InsertEffect = { .vocoder($0) }
            var list: [InsertParam] = [
                mkParam(ex, em, "voc.bands", "Bands", unit: "", range: 16...32, step: 1, format: "%.0f",
                        get: { Double($0.bands) }, set: { $0.bands = Int($1.rounded()) }),
            ]
            if let s = ex(self), case .saw = s.carrier {
                list.append(mkParam(ex, em, "voc.sawHz", "Carrier", unit: "Hz", range: 30...1000, step: 1,
                                    format: "%.0f",
                                    get: { if case .saw(let f) = $0.carrier { return f }; return 110 },
                                    set: { $0.carrier = .saw(freqHz: $1) }))
            }
            list.append(contentsOf: [
                mkParam(ex, em, "voc.atk", "Attack", unit: "ms", range: 0.1...100, step: 0.1, format: "%.1f",
                        get: { $0.attackMs }, set: { $0.attackMs = $1 }),
                mkParam(ex, em, "voc.rel", "Release", unit: "ms", range: 1...500, step: 1, format: "%.0f",
                        get: { $0.releaseMs }, set: { $0.releaseMs = $1 }),
                mkParam(ex, em, "voc.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }),
            ])
            return list
        case .formantShifter:
            let ex: (InsertEffect) -> FormantShifterSettings? = { if case .formantShifter(let s) = $0 { return s }; return nil }
            let em: (FormantShifterSettings) -> InsertEffect = { .formantShifter($0) }
            return [
                mkParam(ex, em, "formant.st", "Shift", unit: "st", range: -12...12, step: 0.5, format: "%+.1f",
                        get: { $0.semitones }, set: { $0.semitones = $1 }),
                mkParam(ex, em, "formant.mix", "Mix", unit: "%", range: 0...1, step: 0.05, format: "%.0f",
                        displayScale: 100, get: { $0.mix }, set: { $0.mix = $1 }),
            ]
        }
    }

    /// Discrete parameters (pickers) for THIS insert kind, in display order.
    var choices: [InsertChoice] {
        let scaleNames = MusicalScale.allCases.map { $0.rawValue.capitalized }
        switch self {
        case .phaser:
            let ex: (InsertEffect) -> PhaserSettings? = { if case .phaser(let s) = $0 { return s }; return nil }
            let em: (PhaserSettings) -> InsertEffect = { .phaser($0) }
            return [mkChoice(ex, em, "phaser.stages", "Stages", options: ["4 stages", "8 stages"],
                             get: { $0.stages >= 8 ? 1 : 0 }, set: { $0.stages = $1 == 1 ? 8 : 4 })]
        case .distortion:
            let ex: (InsertEffect) -> DistortionSettings? = { if case .distortion(let s) = $0 { return s }; return nil }
            let em: (DistortionSettings) -> InsertEffect = { .distortion($0) }
            let modes = DistortionMode.allCases
            return [
                mkChoice(ex, em, "dist.mode", "Mode", options: modes.map { $0.rawValue.capitalized },
                         get: { modes.firstIndex(of: $0.mode) ?? 0 }, set: { $0.mode = modes[$1] }),
                mkChoice(ex, em, "dist.os", "Oversample", options: ["4×", "8×"],
                         get: { $0.oversample >= 8 ? 1 : 0 }, set: { $0.oversample = $1 == 1 ? 8 : 4 }),
            ]
        case .filterFX:
            let ex: (InsertEffect) -> FilterFXSettings? = { if case .filterFX(let s) = $0 { return s }; return nil }
            let em: (FilterFXSettings) -> InsertEffect = { .filterFX($0) }
            let shapes = FilterFXShape.allCases
            let sweeps = FilterFXSweepSource.allCases
            return [
                mkChoice(ex, em, "ffx.shape", "Shape", options: ["Low pass", "High pass", "Band pass", "Comb"],
                         get: { shapes.firstIndex(of: $0.shape) ?? 0 }, set: { $0.shape = shapes[$1] }),
                mkChoice(ex, em, "ffx.sweep", "Sweep", options: ["None", "LFO", "Envelope"],
                         get: { sweeps.firstIndex(of: $0.sweep) ?? 0 }, set: { $0.sweep = sweeps[$1] }),
            ]
        case .pitchCorrection:
            let ex: (InsertEffect) -> PitchCorrectionSettings? = { if case .pitchCorrection(let s) = $0 { return s }; return nil }
            let em: (PitchCorrectionSettings) -> InsertEffect = { .pitchCorrection($0) }
            let scales = MusicalScale.allCases
            return [
                mkChoice(ex, em, "tune.root", "Key", options: musicalRootNames,
                         get: { $0.key.rootSemitone }, set: { $0.key.rootSemitone = $1 }),
                mkChoice(ex, em, "tune.scale", "Scale", options: scaleNames,
                         get: { scales.firstIndex(of: $0.key.scale) ?? 0 }, set: { $0.key.scale = scales[$1] }),
            ]
        case .harmonizer:
            let ex: (InsertEffect) -> HarmonizerSettings? = { if case .harmonizer(let s) = $0 { return s }; return nil }
            let em: (HarmonizerSettings) -> InsertEffect = { .harmonizer($0) }
            let scales = MusicalScale.allCases
            return [
                mkChoice(ex, em, "harm.root", "Key", options: musicalRootNames,
                         get: { $0.key.rootSemitone }, set: { $0.key.rootSemitone = $1 }),
                mkChoice(ex, em, "harm.scale", "Scale", options: scaleNames,
                         get: { scales.firstIndex(of: $0.key.scale) ?? 0 }, set: { $0.key.scale = scales[$1] }),
            ]
        case .vocoder:
            let ex: (InsertEffect) -> VocoderSettings? = { if case .vocoder(let s) = $0 { return s }; return nil }
            let em: (VocoderSettings) -> InsertEffect = { .vocoder($0) }
            return [mkChoice(ex, em, "voc.carrier", "Carrier", options: ["Saw", "Noise"],
                             get: { if case .noise = $0.carrier { return 1 }; return 0 },
                             set: { s, i in
                                 if i == 1 { s.carrier = .noise }
                                 else if case .saw = s.carrier {} else { s.carrier = .saw(freqHz: 110) }
                             })]
        default:
            return []
        }
    }
}
