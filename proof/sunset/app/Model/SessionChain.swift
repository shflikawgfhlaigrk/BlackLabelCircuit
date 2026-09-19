// SessionChain.swift — Phase 2 of SUNSET-EFFECTS-STANDARD: the user-facing MIX / MASTER
// session model and its offline render wiring.
//
// MIX area:   per-stem channel strips (Gate → EQ → Comp → De-Esser → Saturation → Dynamic EQ
//             → Transient → Width/Haas → insert slots → sends), role buses (drums /
//             instruments / vocals) with glue compression + parallel blend + generalized
//             ducking, and one shared Reverb + one shared Delay wet-only return per project.
// MASTER area: the explicit manual master chain (EQ → Multiband → Dynamic EQ → Saturation /
//             Exciter → Imager + M/S) applied as a layer ON TOP of the guided MasteringEngine
//             default (which keeps the soft clip → limiter → dither tail and all metering).
//
// Contract (regression-locked in tests/audio_regression.swift):
//   • EVERY stage defaults to bypassed. A neutral session is bit-transparent — existing
//     projects and the out-of-box render are byte-for-byte unchanged.
//   • Every applied stage appends a MEASURED note (compressor GR, gate attenuation, band
//     level deltas) — never an asserted one (§5.1).
//   • Everything here is Codable + versioned: a document missing new fields decodes to
//     bypassed defaults, so old saved sessions load unchanged.
//
// Foundation-only on purpose: this file is part of the headless test + CLI build.

import Foundation

// MARK: - Top-level area

/// The two top-level app areas. Mixing and mastering are different disciplines —
/// the UI switches between them explicitly and never blurs the two.
enum StudioArea: String, CaseIterable, Identifiable, Codable {
    case mix = "MIX"
    case master = "MASTER"
    var id: String { rawValue }
}

// MARK: - Codable for pre-existing engine types

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Stable-key Codable for StemRole (persistence uses `key`, never the display label).
extension MixEngine.StemRole: Codable {
    init(from decoder: Decoder) throws {
        let key = try decoder.singleValueContainer().decode(String.self)
        self = MixEngine.StemRole.allCases.first { $0.key == key } ?? .other
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Tolerant Codable for the per-stem control: every field optional on decode, so a
/// document written before a field existed (e.g. pre-Phase-2 `strip`) loads unchanged
/// with that field at its bypassed default.
extension MixEngine.StemControl: Codable {
    private enum CodingKeys: String, CodingKey {
        case roleOverride, gainTrimDB, muted, soloed, panOverride, strip
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        roleOverride = try c.decodeIfPresent(MixEngine.StemRole.self, forKey: .roleOverride)
        gainTrimDB = try c.decodeIfPresent(Double.self, forKey: .gainTrimDB) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        soloed = try c.decodeIfPresent(Bool.self, forKey: .soloed) ?? false
        panOverride = try c.decodeIfPresent(Double.self, forKey: .panOverride)
        strip = try c.decodeIfPresent(StemStripSettings.self, forKey: .strip) ?? .neutral
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(roleOverride, forKey: .roleOverride)
        try c.encode(gainTrimDB, forKey: .gainTrimDB)
        try c.encode(muted, forKey: .muted)
        try c.encode(soloed, forKey: .soloed)
        try c.encodeIfPresent(panOverride, forKey: .panOverride)
        try c.encode(strip, forKey: .strip)
    }
}
#endif // circuit-convert

// MARK: - Insert slots (creative FX)

/// One insert slot on a channel strip: the user picks a creative effect; its settings ride
/// along. Enum-with-payload keeps the Codable document honest — a slot IS its effect.
enum InsertEffect: Equatable, Codable, Identifiable {
    case chorus(ChorusSettings)
    case flanger(FlangerSettings)
    case phaser(PhaserSettings)
    case tremolo(TremoloSettings)
    case vibrato(VibratoSettings)
    case autoPan(AutoPanSettings)
    case bitcrusher(BitcrusherSettings)
    case distortion(DistortionSettings)
    case ringMod(RingModSettings)
    case resonator(ResonatorSettings)
    case frequencyShifter(FrequencyShifterSettings)
    case filterFX(FilterFXSettings)
    // Phase 3 — pitch lane (rows 26–29). The vocoder insert has no second source routed,
    // so it always uses its built-in carrier (saw by default) — pragmatic v1.
    case pitchCorrection(PitchCorrectionSettings)
    case harmonizer(HarmonizerSettings)
    case vocoder(VocoderSettings)
    case formantShifter(FormantShifterSettings)

    var id: String { label }

    var label: String {
        switch self {
        case .chorus: return "Chorus";               case .flanger: return "Flanger"
        case .phaser: return "Phaser";               case .tremolo: return "Tremolo"
        case .vibrato: return "Vibrato";             case .autoPan: return "AutoPan"
        case .bitcrusher: return "Bitcrusher";       case .distortion: return "Distortion"
        case .ringMod: return "Ring Mod";            case .resonator: return "Resonator"
        case .frequencyShifter: return "Freq Shift"; case .filterFX: return "Filter FX"
        case .pitchCorrection: return "Pitch Correct"; case .harmonizer: return "Harmonizer"
        case .vocoder: return "Vocoder";             case .formantShifter: return "Formant"
        }
    }

    var isEnabled: Bool {
        switch self {
        case .chorus(let s): return s.enabled
        case .flanger(let s): return s.enabled
        case .phaser(let s): return s.enabled
        case .tremolo(let s): return s.enabled
        case .vibrato(let s): return s.enabled
        case .autoPan(let s): return s.enabled
        case .bitcrusher(let s): return s.enabled
        case .distortion(let s): return s.enabled
        case .ringMod(let s): return s.enabled
        case .resonator(let s): return s.enabled
        case .frequencyShifter(let s): return s.enabled
        case .filterFX(let s): return s.enabled
        case .pitchCorrection(let s): return s.enabled
        case .harmonizer(let s): return s.enabled
        case .vocoder(let s): return s.enabled
        case .formantShifter(let s): return s.enabled
        }
    }

    /// Fresh default (enabled) instance of every pickable insert, in menu order.
    static var menu: [InsertEffect] {
        [.chorus(ChorusSettings(enabled: true)),
         .flanger(FlangerSettings(enabled: true)),
         .phaser(PhaserSettings(enabled: true)),
         .tremolo(TremoloSettings(enabled: true)),
         .vibrato(VibratoSettings(enabled: true)),
         .autoPan(AutoPanSettings(enabled: true)),
         .bitcrusher(BitcrusherSettings(enabled: true)),
         .distortion(DistortionSettings(enabled: true)),
         .ringMod(RingModSettings(enabled: true)),
         .resonator(ResonatorSettings(enabled: true,
                                      voices: [ResonatorVoice(freqHz: 220, decaySeconds: 0.4, gain: 0.7)])),
         .frequencyShifter(FrequencyShifterSettings(enabled: true, shiftHz: 60)),
         .filterFX(FilterFXSettings(enabled: true)),
         .pitchCorrection(PitchCorrectionSettings(enabled: true)),
         .harmonizer(HarmonizerSettings(enabled: true)),
         .vocoder(VocoderSettings(enabled: true)),
         .formantShifter(FormantShifterSettings(enabled: true, semitones: 3))]
    }

    /// Run this insert over the signal (bypassed settings return the input untouched).
    func apply(to s: AudioSignal, sampleRate: Double) -> AudioSignal {
        switch self {
        case .chorus(let cfg): return Chorus(settings: cfg, sampleRate: sampleRate).process(s)
        case .flanger(let cfg): return Flanger(settings: cfg, sampleRate: sampleRate).process(s)
        case .phaser(let cfg): return Phaser(settings: cfg, sampleRate: sampleRate).process(s)
        case .tremolo(let cfg): return Tremolo(settings: cfg, sampleRate: sampleRate).process(s)
        case .vibrato(let cfg): return Vibrato(settings: cfg, sampleRate: sampleRate).process(s)
        case .autoPan(let cfg): return AutoPan(settings: cfg, sampleRate: sampleRate).process(s)
        case .bitcrusher(let cfg): return Bitcrusher(settings: cfg).process(s)
        case .distortion(let cfg): return Distortion(settings: cfg, sampleRate: sampleRate).process(s)
        case .ringMod(let cfg): return RingModulator(settings: cfg, sampleRate: sampleRate).process(s)
        case .resonator(let cfg): return Resonator(settings: cfg, sampleRate: sampleRate).process(s)
        case .frequencyShifter(let cfg): return FrequencyShifter(settings: cfg, sampleRate: sampleRate).process(s)
        case .filterFX(let cfg): return FilterFX(settings: cfg, sampleRate: sampleRate).process(s)
        case .pitchCorrection(let cfg): return PitchCorrector(settings: cfg, sampleRate: sampleRate).process(s)
        case .harmonizer(let cfg): return Harmonizer(settings: cfg, sampleRate: sampleRate).process(s)
        case .vocoder(let cfg): return Vocoder(settings: cfg, sampleRate: sampleRate).process(modulator: s)
        case .formantShifter(let cfg): return FormantShifter(settings: cfg, sampleRate: sampleRate).process(s)
        }
    }
}

// MARK: - Phase 4: user EQ bands + band caps

extension EQBand {
    /// True when this band would actually change audio: pass filters always do;
    /// gain bands (peak/shelf) only when the gain is non-zero. Keeps a freshly-added
    /// 0 dB band from breaking the strip's bit-transparent neutral contract.
    var isAudible: Bool {
        enabled && (kindRaw == 3 || kindRaw == 4 || gainDB != 0)
    }
}

/// User-layer band caps for the dynamic EQ editors (the engine itself is N-band;
/// these keep the session surface sane). Add/remove go through these helpers so the
/// UI and the regression suite share one mutation path.
extension DynamicEQSettings {
    static let maxUserBands = 4

    @discardableResult
    mutating func addBand(_ band: DynamicEQBand = DynamicEQBand(freq: 1000)) -> Bool {
        guard bands.count < Self.maxUserBands else { return false }
        bands.append(band)
        return true
    }

    mutating func removeBand(at index: Int) {
        guard bands.indices.contains(index) else { return }
        bands.remove(at: index)
    }
}

// MARK: - Per-stem channel strip

/// User channel-strip settings for ONE stem, in spec signal order. Gain/Trim and Pan live on
/// `StemControl` (they predate the strip); everything here defaults to bypassed so a stem with
/// a neutral strip renders bit-for-bit as before.
struct StemStripSettings: Equatable, Codable {
    var gate: GateExpanderSettings = .bypassed
    /// 3-band user EQ (low shelf 120 Hz / peak 800 Hz / high shelf 8 kHz), dB. 0 = bypass.
    var eqLowDB: Double = 0
    var eqMidDB: Double = 0
    var eqHighDB: Double = 0
    var compressorEnabled: Bool = false
    var compressor: CompressorSettings = CompressorSettings()
    var deEsser: DeEsserSettings = .bypassed
    var saturation: SaturationSettings = .bypassed
    var dynamicEQ: DynamicEQSettings = .bypassed
    var transient: TransientShaperSettings = .bypassed
    var widener: WidenerSettings = .bypassed
    var inserts: [InsertEffect] = []
    /// Send level into the project's shared reverb / delay returns, 0…1 linear.
    var sendReverb: Double = 0
    var sendDelay: Double = 0
    /// Phase 4: additional fully-editable user EQ bands (type / freq / Q / gain) on top of
    /// the 3 fixed shelves. Empty (the default) = old documents load and render unchanged.
    var eqExtraBands: [EQBand] = []

    /// User-layer cap for `eqExtraBands` (with the 3 fixed bands: an 8-band strip EQ).
    static let maxExtraEQBands = 5

    static let neutral = StemStripSettings()

    var isNeutral: Bool {
        !gate.enabled && eqLowDB == 0 && eqMidDB == 0 && eqHighDB == 0
            && !eqExtraBands.contains { $0.isAudible }
            && !compressorEnabled && !deEsser.enabled && !saturation.enabled
            && !dynamicEQ.enabled && !transient.enabled && !widener.enabled
            && !inserts.contains { $0.isEnabled }
            && sendReverb <= 0.0001 && sendDelay <= 0.0001
    }

    /// True when any in-line processing stage is active (sends alone don't alter the dry path).
    var hasInlineProcessing: Bool {
        gate.enabled || eqLowDB != 0 || eqMidDB != 0 || eqHighDB != 0
            || eqExtraBands.contains { $0.isAudible }
            || compressorEnabled || deEsser.enabled || saturation.enabled
            || dynamicEQ.enabled || transient.enabled || widener.enabled
            || inserts.contains { $0.isEnabled }
    }

    /// The user EQ as engine bands: the 3 fixed bands (only the non-zero ones) followed by
    /// the audible extra bands.
    var eqBands: [EQBand] {
        var bands: [EQBand] = []
        if eqLowDB != 0 { bands.append(.lowShelf(120, eqLowDB)) }
        if eqMidDB != 0 { bands.append(.peak(800, eqMidDB, 1.0)) }
        if eqHighDB != 0 { bands.append(.highShelf(8000, eqHighDB)) }
        bands.append(contentsOf: eqExtraBands.filter { $0.isAudible })
        return bands
    }

    /// Add one editable EQ band (capped). Returns false at the cap. The UI's "+ band"
    /// button and the regression suite both go through here.
    @discardableResult
    mutating func addEQBand(_ band: EQBand = .peak(1000, 0, 1.0)) -> Bool {
        guard eqExtraBands.count < Self.maxExtraEQBands else { return false }
        eqExtraBands.append(band)
        return true
    }

    mutating func removeEQBand(id: UUID) {
        eqExtraBands.removeAll { $0.id == id }
    }

    // Tolerant decode: any missing field = bypassed default (old documents load unchanged).
    private enum CodingKeys: String, CodingKey {
        case gate, eqLowDB, eqMidDB, eqHighDB, compressorEnabled, compressor, deEsser
        case saturation, dynamicEQ, transient, widener, inserts, sendReverb, sendDelay
        case eqExtraBands
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gate = try c.decodeIfPresent(GateExpanderSettings.self, forKey: .gate) ?? .bypassed
        eqLowDB = try c.decodeIfPresent(Double.self, forKey: .eqLowDB) ?? 0
        eqMidDB = try c.decodeIfPresent(Double.self, forKey: .eqMidDB) ?? 0
        eqHighDB = try c.decodeIfPresent(Double.self, forKey: .eqHighDB) ?? 0
        compressorEnabled = try c.decodeIfPresent(Bool.self, forKey: .compressorEnabled) ?? false
        compressor = try c.decodeIfPresent(CompressorSettings.self, forKey: .compressor) ?? CompressorSettings()
        deEsser = try c.decodeIfPresent(DeEsserSettings.self, forKey: .deEsser) ?? .bypassed
        saturation = try c.decodeIfPresent(SaturationSettings.self, forKey: .saturation) ?? .bypassed
        dynamicEQ = try c.decodeIfPresent(DynamicEQSettings.self, forKey: .dynamicEQ) ?? .bypassed
        transient = try c.decodeIfPresent(TransientShaperSettings.self, forKey: .transient) ?? .bypassed
        widener = try c.decodeIfPresent(WidenerSettings.self, forKey: .widener) ?? .bypassed
        inserts = try c.decodeIfPresent([InsertEffect].self, forKey: .inserts) ?? []
        sendReverb = try c.decodeIfPresent(Double.self, forKey: .sendReverb) ?? 0
        sendDelay = try c.decodeIfPresent(Double.self, forKey: .sendDelay) ?? 0
        eqExtraBands = try c.decodeIfPresent([EQBand].self, forKey: .eqExtraBands) ?? []
    }

    /// Apply the strip's in-line stages in spec order. Every applied stage appends a
    /// MEASURED note (the processor's own read-out, or a real level delta). Sends are
    /// taken by the caller from the returned (post-strip) signal.
    func apply(to input: AudioSignal, sampleRate: Double, stemName: String) -> (signal: AudioSignal, notes: [String]) {
        guard hasInlineProcessing, input.frameCount > 0 else { return (input, []) }
        var sig = input
        var notes: [String] = []

        if gate.enabled {
            let g = GateExpander(settings: gate, sampleRate: sampleRate)
            sig = g.process(sig)
            notes.append(String(format: "Strip \"%@\": %@ at %.0f dB — measured max attenuation %.1f dB.",
                                stemName, gate.mode == .gate ? "gate" : "expander",
                                gate.thresholdDB, g.lastMaxAttenuationDB))
        }
        let bands = eqBands
        if !bands.isEmpty {
            let before = sig.peakDBFS()
            sig = SessionDSP.applyEQ(sig, bands: bands, sampleRate: sampleRate)
            notes.append(String(format: "Strip \"%@\": EQ %@ — peak %.1f → %.1f dBFS.",
                                stemName,
                                [eqLowDB != 0 ? String(format: "low %+.1f", eqLowDB) : nil,
                                 eqMidDB != 0 ? String(format: "mid %+.1f", eqMidDB) : nil,
                                 eqHighDB != 0 ? String(format: "high %+.1f", eqHighDB) : nil]
                                    .compactMap { $0 }.joined(separator: ", "),
                                before, sig.peakDBFS()))
        }
        if compressorEnabled {
            let comp = Compressor(settings: compressor, sampleRate: sampleRate)
            sig = comp.process(sig)
            notes.append(String(format: "Strip \"%@\": compressor %.1f:1 at %.0f dB — measured %.1f dB gain reduction.",
                                stemName, compressor.ratio, compressor.thresholdDB, comp.lastGainReductionDB))
        }
        if deEsser.enabled {
            let de = DeEsser(settings: deEsser, sampleRate: sampleRate)
            sig = de.process(sig)
            notes.append(String(format: "Strip \"%@\": de-esser %.0f–%.0f Hz — measured %.1f dB reduction.",
                                stemName, deEsser.bandLowHz, deEsser.bandHighHz, de.lastReductionDB))
        }
        if saturation.enabled {
            let before = sig.peakDBFS()
            sig = Saturator(settings: saturation, sampleRate: sampleRate).process(sig)
            notes.append(String(format: "Strip \"%@\": %@ saturation %.1f dB drive (%.0f%% wet) — peak %.1f → %.1f dBFS.",
                                stemName, saturation.mode.rawValue, saturation.driveDB,
                                saturation.mix * 100, before, sig.peakDBFS()))
        }
        if dynamicEQ.enabled {
            let dyn = DynamicEQ(settings: dynamicEQ, sampleRate: sampleRate)
            sig = dyn.process(sig)
            let moved = dyn.lastBandGainDB.map { String(format: "%+.1f", $0) }.joined(separator: ", ")
            notes.append(String(format: "Strip \"%@\": dynamic EQ — measured band moves [%@] dB.", stemName, moved))
        }
        if transient.enabled {
            sig = TransientShaper(settings: transient, sampleRate: sampleRate).process(sig)
            notes.append(String(format: "Strip \"%@\": transient shaper attack %+.1f dB / sustain %+.1f dB.",
                                stemName, transient.attackGainDB, transient.sustainGainDB))
        }
        if widener.enabled {
            let w = HaasWidener(settings: widener, sampleRate: sampleRate)
            sig = w.process(sig)
            notes.append(String(format: "Strip \"%@\": Haas width %.1f ms — measured L/R correlation %.2f, mono fold %+.1f dB.",
                                stemName, widener.delayMs, w.lastReport.correlation, w.lastReport.monoSumDeltaDB))
        }
        for insert in inserts where insert.isEnabled {
            let before = sig.rms(across: 0)
            sig = insert.apply(to: sig, sampleRate: sampleRate)
            notes.append(String(format: "Strip \"%@\": insert %@ — RMS %.1f → %.1f dBFS.",
                                stemName, insert.label, before, sig.rms(across: 0)))
        }
        return (sig, notes)
    }
}

// MARK: - Phase 4: per-strip stage A/B

/// The A/B-auditionable stages of a channel strip (mirrors MasterChainStage for MASTER).
/// `.insert(i)` addresses one insert slot by position.
enum StripStage: Equatable, Hashable, Identifiable {
    case gate, eq, compressor, deEsser, saturation, dynamicEQ, transient, widener
    case insert(Int)

    var id: String { label }

    var label: String {
        switch self {
        case .gate: return "Gate"
        case .eq: return "EQ"
        case .compressor: return "Compressor"
        case .deEsser: return "De-Esser"
        case .saturation: return "Saturation"
        case .dynamicEQ: return "Dynamic EQ"
        case .transient: return "Transient"
        case .widener: return "Width"
        case .insert(let i): return "Insert \(i + 1)"
        }
    }
}

extension StemStripSettings {
    /// True when `stage` would actually process audio with the current settings.
    func isStageActive(_ stage: StripStage) -> Bool {
        switch stage {
        case .gate: return gate.enabled
        case .eq: return eqLowDB != 0 || eqMidDB != 0 || eqHighDB != 0
            || eqExtraBands.contains { $0.isAudible }
        case .compressor: return compressorEnabled
        case .deEsser: return deEsser.enabled
        case .saturation: return saturation.enabled
        case .dynamicEQ: return dynamicEQ.enabled
        case .transient: return transient.enabled
        case .widener: return widener.enabled
        case .insert(let i): return inserts.indices.contains(i) && inserts[i].isEnabled
        }
    }

    /// A copy of the strip with one stage bypassed — the "hear it without this stage" A/B.
    func disabling(_ stage: StripStage) -> StemStripSettings {
        var s = self
        switch stage {
        case .gate: s.gate.enabled = false
        case .eq:
            s.eqLowDB = 0; s.eqMidDB = 0; s.eqHighDB = 0
            for i in s.eqExtraBands.indices { s.eqExtraBands[i].enabled = false }
        case .compressor: s.compressorEnabled = false
        case .deEsser: s.deEsser.enabled = false
        case .saturation: s.saturation.enabled = false
        case .dynamicEQ: s.dynamicEQ.enabled = false
        case .transient: s.transient.enabled = false
        case .widener: s.widener.enabled = false
        case .insert(let i): if s.inserts.indices.contains(i) { s.inserts[i].setEnabled(false) }
        }
        return s
    }
}

// MARK: - Buses

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The three mix buses, routed by StemRole.
enum BusRole: String, CaseIterable, Identifiable, Codable {
    case drums, instruments, vocals
    var id: String { rawValue }

    var label: String {
        switch self {
        case .drums: return "Drum bus"
        case .instruments: return "Instrument bus"
        case .vocals: return "Vocal bus"
        }
    }

    /// Deterministic routing: which bus a stem role lands on.
    static func bus(for role: MixEngine.StemRole) -> BusRole {
        switch role {
        case .kick, .drums, .clap, .hat: return .drums
        case .vox: return .vocals
        default: return .instruments
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Ducker trigger source: another stem (by name) or a whole bus.
enum DuckSource: Equatable, Codable, Hashable {
    case stem(String)
    case bus(BusRole)

    var label: String {
        switch self {
        case .stem(let name): return name
        case .bus(let role): return role.label
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// User settings for one mix bus. All bypassed by default.
struct BusSettings: Equatable, Codable {
    var compressorEnabled: Bool = false
    /// Glue settings used when the compressor is enabled (defaults to the busGlue preset).
    var compressor: CompressorSettings = .busGlue
    /// Parallel (NY) blend: 1 = fully compressed (insert), 0.3 = classic parallel under the dry bus.
    var parallelWet: Double = 1.0
    var duckEnabled: Bool = false
    var duckSource: DuckSource? = nil
    var ducker: DuckerSettings = DuckerSettings()

    static let neutral = BusSettings()

    var isNeutral: Bool { !compressorEnabled && !duckEnabled }

    private enum CodingKeys: String, CodingKey {
        case compressorEnabled, compressor, parallelWet, duckEnabled, duckSource, ducker
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compressorEnabled = try c.decodeIfPresent(Bool.self, forKey: .compressorEnabled) ?? false
        compressor = try c.decodeIfPresent(CompressorSettings.self, forKey: .compressor) ?? .busGlue
        parallelWet = try c.decodeIfPresent(Double.self, forKey: .parallelWet) ?? 1.0
        duckEnabled = try c.decodeIfPresent(Bool.self, forKey: .duckEnabled) ?? false
        duckSource = try c.decodeIfPresent(DuckSource.self, forKey: .duckSource)
        ducker = try c.decodeIfPresent(DuckerSettings.self, forKey: .ducker) ?? DuckerSettings()
    }
}
#endif // circuit-convert

// MARK: - Sends (shared returns)

/// One shared reverb + one shared delay return for the whole project. Returns are WET-ONLY
/// (mix is forced to 1.0 at render), fed by each strip's send level, trimmed by the return level.
struct SendReturnSettings: Equatable, Codable {
    var reverb: ReverbSettings = ReverbSettings(enabled: true, preset: .hall,
                                                decaySeconds: 1.8, predelayMs: 20,
                                                size: 1.0, dampingHz: 6000, mix: 1.0)
    var reverbReturnDB: Double = 0
    var delay: DelaySettings = DelaySettings(enabled: true, mode: .pingPong, timeMs: 350,
                                             feedback: 0.35, mix: 1.0)
    var delayReturnDB: Double = 0

    static let neutral = SendReturnSettings()

    private enum CodingKeys: String, CodingKey { case reverb, reverbReturnDB, delay, delayReturnDB }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reverb = try c.decodeIfPresent(ReverbSettings.self, forKey: .reverb) ?? SendReturnSettings().reverb
        reverbReturnDB = try c.decodeIfPresent(Double.self, forKey: .reverbReturnDB) ?? 0
        delay = try c.decodeIfPresent(DelaySettings.self, forKey: .delay) ?? SendReturnSettings().delay
        delayReturnDB = try c.decodeIfPresent(Double.self, forKey: .delayReturnDB) ?? 0
    }
}

// MARK: - Master chain (manual layer)

/// The explicit MASTER-area chain, applied to the stereo bounce BEFORE the guided
/// MasteringEngine pass (which keeps soft clip → limiter → dither and all metering).
/// Neutral = bit-transparent, so the guided default remains exactly the shipped sound.
struct MasterChainSettings: Equatable, Codable {
    /// Manual master EQ (3 bands: low shelf 100 Hz / peak 1 kHz / high shelf 10 kHz), dB.
    var eqLowDB: Double = 0
    var eqMidDB: Double = 0
    var eqHighDB: Double = 0
    /// Extra multiband glue: threshold pushed `amountDB` below the measured program level.
    var multibandEnabled: Bool = false
    var multibandAmountDB: Double = 3
    var dynamicEQ: DynamicEQSettings = .bypassed
    var saturation: SaturationSettings = .bypassed
    var exciter: ExciterSettings = .bypassed
    var imagerEnabled: Bool = false
    var imagerWidth: Double = 1.15
    var imagerMonoBelowHz: Double = 120
    var midSide: MidSideSettings = .bypassed

    static let neutral = MasterChainSettings()

    var isNeutral: Bool {
        eqLowDB == 0 && eqMidDB == 0 && eqHighDB == 0 && !multibandEnabled
            && !dynamicEQ.enabled && !saturation.enabled && !exciter.enabled
            && !imagerEnabled && !midSide.enabled
    }

    var eqBands: [EQBand] {
        var bands: [EQBand] = []
        if eqLowDB != 0 { bands.append(.lowShelf(100, eqLowDB)) }
        if eqMidDB != 0 { bands.append(.peak(1000, eqMidDB, 1.0)) }
        if eqHighDB != 0 { bands.append(.highShelf(10_000, eqHighDB)) }
        return bands
    }

    private enum CodingKeys: String, CodingKey {
        case eqLowDB, eqMidDB, eqHighDB, multibandEnabled, multibandAmountDB
        case dynamicEQ, saturation, exciter, imagerEnabled, imagerWidth, imagerMonoBelowHz, midSide
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        eqLowDB = try c.decodeIfPresent(Double.self, forKey: .eqLowDB) ?? 0
        eqMidDB = try c.decodeIfPresent(Double.self, forKey: .eqMidDB) ?? 0
        eqHighDB = try c.decodeIfPresent(Double.self, forKey: .eqHighDB) ?? 0
        multibandEnabled = try c.decodeIfPresent(Bool.self, forKey: .multibandEnabled) ?? false
        multibandAmountDB = try c.decodeIfPresent(Double.self, forKey: .multibandAmountDB) ?? 3
        dynamicEQ = try c.decodeIfPresent(DynamicEQSettings.self, forKey: .dynamicEQ) ?? .bypassed
        saturation = try c.decodeIfPresent(SaturationSettings.self, forKey: .saturation) ?? .bypassed
        exciter = try c.decodeIfPresent(ExciterSettings.self, forKey: .exciter) ?? .bypassed
        imagerEnabled = try c.decodeIfPresent(Bool.self, forKey: .imagerEnabled) ?? false
        imagerWidth = try c.decodeIfPresent(Double.self, forKey: .imagerWidth) ?? 1.15
        imagerMonoBelowHz = try c.decodeIfPresent(Double.self, forKey: .imagerMonoBelowHz) ?? 120
        midSide = try c.decodeIfPresent(MidSideSettings.self, forKey: .midSide) ?? .bypassed
    }

    /// True when `stage` would actually process audio with the current settings.
    func isStageActive(_ stage: MasterChainStage) -> Bool {
        switch stage {
        case .eq: return eqLowDB != 0 || eqMidDB != 0 || eqHighDB != 0
        case .multiband: return multibandEnabled
        case .dynamicEQ: return dynamicEQ.enabled
        case .saturation: return saturation.enabled
        case .exciter: return exciter.enabled
        case .imaging: return imagerEnabled || midSide.enabled
        }
    }

    /// A copy of the chain with one stage bypassed — the "hear it without this stage" A/B.
    func disabling(_ stage: MasterChainStage) -> MasterChainSettings {
        var m = self
        switch stage {
        case .eq: m.eqLowDB = 0; m.eqMidDB = 0; m.eqHighDB = 0
        case .multiband: m.multibandEnabled = false
        case .dynamicEQ: m.dynamicEQ.enabled = false
        case .saturation: m.saturation.enabled = false
        case .exciter: m.exciter.enabled = false
        case .imaging: m.imagerEnabled = false; m.midSide.enabled = false
        }
        return m
    }

    /// Apply the manual chain in spec order (EQ → Multiband → Dynamic EQ → Saturation /
    /// Exciter → Imager + M/S). Neutral settings return the input bit-for-bit.
    /// The engine's soft clip → limiter → dither tail runs AFTER this, unchanged.
    func apply(to input: AudioSignal, sampleRate: Double) -> (signal: AudioSignal, notes: [String]) {
        guard !isNeutral, input.frameCount > 0 else { return (input, []) }
        var sig = input
        var notes: [String] = []

        let bands = eqBands
        if !bands.isEmpty {
            let before = sig.peakDBFS()
            sig = SessionDSP.applyEQ(sig, bands: bands, sampleRate: sampleRate)
            notes.append(String(format: "Master chain: manual EQ %@ — peak %.1f → %.1f dBFS.",
                                [eqLowDB != 0 ? String(format: "low %+.1f", eqLowDB) : nil,
                                 eqMidDB != 0 ? String(format: "mid %+.1f", eqMidDB) : nil,
                                 eqHighDB != 0 ? String(format: "high %+.1f", eqHighDB) : nil]
                                    .compactMap { $0 }.joined(separator: ", "),
                                before, sig.peakDBFS()))
        }
        if multibandEnabled {
            let levels = SessionDSP.peakAndRMSDB(sig)
            let base = (levels.peakDB + levels.rmsDB) * 0.5
            let thr = min(max(base - multibandAmountDB, -40.0), -1.0)
            let settings = [
                CompressorSettings(thresholdDB: thr, ratio: 2.0, attackMs: 30, releaseMs: 120, kneeDB: 7, makeupDB: 0),
                CompressorSettings(thresholdDB: thr, ratio: 2.0, attackMs: 30, releaseMs: 100, kneeDB: 7, makeupDB: 0),
                CompressorSettings(thresholdDB: thr, ratio: 2.0, attackMs: 20, releaseMs: 100, kneeDB: 7, makeupDB: 0),
            ]
            let mbc = MultibandCompressor(sampleRate: sampleRate, crossovers: [120, 2500])
            sig = mbc.process(sig, band: settings)
            notes.append(String(format: "Master chain: manual multiband %.1f dB deeper — measured %.1f dB gain reduction.",
                                multibandAmountDB, mbc.lastGainReductionDB))
        }
        if dynamicEQ.enabled {
            let dyn = DynamicEQ(settings: dynamicEQ, sampleRate: sampleRate)
            sig = dyn.process(sig)
            let moved = dyn.lastBandGainDB.map { String(format: "%+.1f", $0) }.joined(separator: ", ")
            notes.append(String(format: "Master chain: dynamic EQ — measured band moves [%@] dB.", moved))
        }
        if saturation.enabled {
            let before = sig.peakDBFS()
            sig = Saturator(settings: saturation, sampleRate: sampleRate).process(sig)
            notes.append(String(format: "Master chain: %@ saturation %.1f dB drive (%.0f%% wet) — peak %.1f → %.1f dBFS.",
                                saturation.mode.rawValue, saturation.driveDB, saturation.mix * 100,
                                before, sig.peakDBFS()))
        }
        if exciter.enabled {
            let before = sig.rms(across: 0)
            sig = Exciter(settings: exciter, sampleRate: sampleRate).process(sig)
            notes.append(String(format: "Master chain: exciter presence %.0f%% / air %.0f%% — RMS %.1f → %.1f dBFS.",
                                exciter.presenceAmount * 100, exciter.airAmount * 100,
                                before, sig.rms(across: 0)))
        }
        if imagerEnabled && sig.channelCount >= 2 {
            sig = StereoImager().process(sig, width: imagerWidth,
                                         monoBelowHz: imagerMonoBelowHz, sampleRate: sampleRate)
            notes.append(String(format: "Master chain: imager width %.2f, mono below %.0f Hz.",
                                imagerWidth, imagerMonoBelowHz))
        }
        if midSide.enabled && sig.channelCount >= 2 {
            sig = MidSideProcessor(settings: midSide, sampleRate: sampleRate).process(sig)
            notes.append(String(format: "Master chain: M/S mid %+.1f dB / side %+.1f dB.",
                                midSide.midGainDB, midSide.sideGainDB))
        }
        return (sig, notes)
    }
}

/// The A/B-auditionable stages of the manual master chain.
enum MasterChainStage: String, CaseIterable, Identifiable {
    case eq = "EQ"
    case multiband = "Multiband"
    case dynamicEQ = "Dynamic EQ"
    case saturation = "Saturation"
    case exciter = "Exciter"
    case imaging = "Imager + M/S"
    var id: String { rawValue }
}

// MARK: - The whole mix session

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Everything the MIX area adds on top of the automatic engine: per-stem strips (carried on
/// StemControl), the three buses, and the shared send returns. Neutral = the engine renders
/// exactly as before Phase 2 (regression-locked).
struct MixSessionSettings: Equatable, Codable {
    var drumBus: BusSettings = .neutral
    var instrumentBus: BusSettings = .neutral
    var vocalBus: BusSettings = .neutral
    var sends: SendReturnSettings = .neutral

    static let neutral = MixSessionSettings()

    func bus(_ role: BusRole) -> BusSettings {
        switch role {
        case .drums: return drumBus
        case .instruments: return instrumentBus
        case .vocals: return vocalBus
        }
    }
    mutating func setBus(_ role: BusRole, _ settings: BusSettings) {
        switch role {
        case .drums: drumBus = settings
        case .instruments: instrumentBus = settings
        case .vocals: vocalBus = settings
        }
    }

    var busesNeutral: Bool { drumBus.isNeutral && instrumentBus.isNeutral && vocalBus.isNeutral }

    private enum CodingKeys: String, CodingKey { case drumBus, instrumentBus, vocalBus, sends }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        drumBus = try c.decodeIfPresent(BusSettings.self, forKey: .drumBus) ?? .neutral
        instrumentBus = try c.decodeIfPresent(BusSettings.self, forKey: .instrumentBus) ?? .neutral
        vocalBus = try c.decodeIfPresent(BusSettings.self, forKey: .vocalBus) ?? .neutral
        sends = try c.decodeIfPresent(SendReturnSettings.self, forKey: .sends) ?? .neutral
    }
}
#endif // circuit-convert

// MARK: - Versioned session document (save / load)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The saved project file. Versioned + tolerant: a v1 document (or any JSON missing new
/// fields) decodes with every new setting at its bypassed default, so old saved projects
/// load unchanged and sound identical.
struct SessionDocument: Equatable, Codable {
    /// Format version. 1 = pre-Phase-2 (controls only), 2 = MIX/MASTER areas.
    var version: Int = 2
    var stemControls: [String: MixEngine.StemControl] = [:]
    var session: MixSessionSettings = .neutral
    var masterChain: MasterChainSettings = .neutral
    /// Existing master-side user settings carried with the project (guided layer).
    var eqGains: [Double] = UserEQ.flat
    var softClipEnabled: Bool = false
    var softClipDriveDB: Double = 1.25
    var loudnessProfileID: String = LoudnessProfiles.default.id

    private enum CodingKeys: String, CodingKey {
        case version, stemControls, session, masterChain, eqGains
        case softClipEnabled, softClipDriveDB, loudnessProfileID
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        stemControls = try c.decodeIfPresent([String: MixEngine.StemControl].self, forKey: .stemControls) ?? [:]
        session = try c.decodeIfPresent(MixSessionSettings.self, forKey: .session) ?? .neutral
        masterChain = try c.decodeIfPresent(MasterChainSettings.self, forKey: .masterChain) ?? .neutral
        eqGains = try c.decodeIfPresent([Double].self, forKey: .eqGains) ?? UserEQ.flat
        softClipEnabled = try c.decodeIfPresent(Bool.self, forKey: .softClipEnabled) ?? false
        softClipDriveDB = try c.decodeIfPresent(Double.self, forKey: .softClipDriveDB) ?? 1.25
        loudnessProfileID = try c.decodeIfPresent(String.self, forKey: .loudnessProfileID) ?? LoudnessProfiles.default.id
    }

    func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }
    static func decoded(_ data: Data) throws -> SessionDocument {
        try JSONDecoder().decode(SessionDocument.self, from: data)
    }
}
#endif // circuit-convert

// MARK: - Presets (honest parameter sets only — no claims language)

enum StripPresets {
    /// Vocal strip: light gate, 3:1 leveling, de-esser, gentle tube color, small air lift.
    static let vocal: StemStripSettings = {
        var s = StemStripSettings()
        s.gate = GateExpanderSettings(enabled: true, mode: .expander, thresholdDB: -48,
                                      ratio: 2, attackMs: 2, holdMs: 40, releaseMs: 150, rangeDB: 18)
        s.compressorEnabled = true
        s.compressor = CompressorSettings(thresholdDB: -22, ratio: 3, attackMs: 10,
                                          releaseMs: 80, kneeDB: 6, makeupDB: 0)
        s.deEsser = DeEsserSettings(enabled: true)
        s.saturation = SaturationSettings(enabled: true, mode: .tube, driveDB: 3, mix: 0.25)
        s.eqHighDB = 1.5
        return s
    }()

    /// Drum punch: transient snap + tape rounding.
    static let drumPunch: StemStripSettings = {
        var s = StemStripSettings()
        s.transient = TransientShaperSettings(enabled: true, attackGainDB: 4, sustainGainDB: -2)
        s.saturation = SaturationSettings(enabled: true, mode: .tape, driveDB: 4, mix: 0.3)
        return s
    }()

    /// Bass tight: expander cleanup + 3:1 hold + low shelf focus.
    static let bassTight: StemStripSettings = {
        var s = StemStripSettings()
        s.gate = GateExpanderSettings(enabled: true, mode: .expander, thresholdDB: -54,
                                      ratio: 2, attackMs: 2, holdMs: 60, releaseMs: 180, rangeDB: 12)
        s.compressorEnabled = true
        s.compressor = CompressorSettings(thresholdDB: -20, ratio: 3, attackMs: 20,
                                          releaseMs: 110, kneeDB: 5, makeupDB: 0)
        s.eqLowDB = 1.0
        s.eqMidDB = -1.0
        return s
    }()

    static let menu: [(name: String, strip: StemStripSettings)] = [
        ("Vocal strip", vocal), ("Drum punch", drumPunch), ("Bass tight", bassTight),
    ]
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum BusPresets {
    /// Drum bus glue: the busGlue compressor at full insert.
    static let drumGlue: BusSettings = {
        var b = BusSettings()
        b.compressorEnabled = true
        b.compressor = .busGlue
        b.parallelWet = 1.0
        return b
    }()

    /// Parallel drum crush: hard compression blended 35% under the dry bus.
    static let parallelCrush: BusSettings = {
        var b = BusSettings()
        b.compressorEnabled = true
        b.compressor = CompressorSettings(thresholdDB: -28, ratio: 8, attackMs: 2,
                                          releaseMs: 90, kneeDB: 2, makeupDB: 0)
        b.parallelWet = 0.35
        return b
    }()
}
#endif // circuit-convert

enum MasterChainPresets {
    /// EDM master: sub + air shelves, exciter air, wider image above the mono floor.
    static let edm: MasterChainSettings = {
        var m = MasterChainSettings()
        m.eqLowDB = 1.0
        m.eqHighDB = 1.5
        m.exciter = ExciterSettings(enabled: true, presenceAmount: 0.12, airAmount: 0.2)
        m.imagerEnabled = true
        m.imagerWidth = 1.2
        return m
    }()

    /// Warm tape: tape saturation into a slightly softer top.
    static let warmTape: MasterChainSettings = {
        var m = MasterChainSettings()
        m.saturation = SaturationSettings(enabled: true, mode: .tape, driveDB: 4, mix: 0.35)
        m.eqHighDB = -0.5
        return m
    }()

    /// Glue + width: manual multiband over the guided chain, gentle M/S side lift.
    static let glueWide: MasterChainSettings = {
        var m = MasterChainSettings()
        m.multibandEnabled = true
        m.multibandAmountDB = 3
        m.midSide = MidSideSettings(enabled: true, midGainDB: 0, sideGainDB: 1.0)
        return m
    }()

    static let menu: [(name: String, chain: MasterChainSettings)] = [
        ("EDM master", edm), ("Warm tape", warmTape), ("Glue + width", glueWide),
    ]
}

// MARK: - Shared DSP helpers (session layer)

enum SessionDSP {
    /// Stateful per-channel ParametricEQ pass (same idiom as the engines).
    static func applyEQ(_ s: AudioSignal, bands: [EQBand], sampleRate: Double) -> AudioSignal {
        let active = bands.filter { $0.enabled }
        guard !active.isEmpty, s.channelCount > 0, s.frameCount > 0 else { return s }
        let eq = ParametricEQ(bands: active, sampleRate: sampleRate, channels: s.channelCount)
        var out = s.channels
        for c in 0..<out.count {
            for i in 0..<out[c].count {
                out[c][i] = Float(eq.process(Double(out[c][i]), channel: c))
            }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    static func applyGainDB(_ s: AudioSignal, db: Double) -> AudioSignal {
        guard abs(db) > 0.0001 else { return s }
        let g = pow(10.0, db / 20.0)
        var out = s.channels
        for c in 0..<out.count {
            for i in 0..<out[c].count { out[c][i] = Float(Double(out[c][i]) * g) }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    static func scaled(_ s: AudioSignal, by linear: Double) -> AudioSignal {
        var out = s.channels
        for c in 0..<out.count {
            for i in 0..<out[c].count { out[c][i] = Float(Double(out[c][i]) * linear) }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    /// Sample-accurate stereo add (b into a), length = max.
    static func summed(_ a: AudioSignal, _ b: AudioSignal) -> AudioSignal {
        guard b.frameCount > 0 else { return a }
        guard a.frameCount > 0 else { return b }
        let n = max(a.frameCount, b.frameCount)
        let ch = max(a.channelCount, b.channelCount)
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: ch)
        for c in 0..<ch {
            let ca = a.channels.indices.contains(c) ? a.channels[c] : (a.channels.first ?? [])
            let cb = b.channels.indices.contains(c) ? b.channels[c] : (b.channels.first ?? [])
            for i in 0..<n {
                let va = i < ca.count ? Double(ca[i]) : 0
                let vb = i < cb.count ? Double(cb[i]) : 0
                out[c][i] = Float(va + vb)
            }
        }
        return AudioSignal(channels: out, sampleRate: a.sampleRate)
    }

    static func peakAndRMSDB(_ s: AudioSignal) -> (peakDB: Double, rmsDB: Double) {
        var peak = 0.0, sumSq = 0.0
        var count = 0
        for ch in s.channels {
            for v in ch {
                let d = Double(v), a = abs(d)
                if a > peak { peak = a }
                sumSq += d * d
            }
            count += ch.count
        }
        guard count > 0 else { return (-200, -200) }
        let rms = (sumSq / Double(count)).squareRoot()
        return (peak > 1e-10 ? 20 * log10(peak) : -200,
                rms > 1e-10 ? 20 * log10(rms) : -200)
    }
}

extension AudioSignal {
    /// RMS in dBFS of one channel (safe on empty).
    func rms(across channel: Int) -> Double {
        guard channels.indices.contains(channel), !channels[channel].isEmpty else { return -200 }
        return rmsDBFS(channel: channel)
    }
}
