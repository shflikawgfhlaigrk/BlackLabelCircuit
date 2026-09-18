// MixEngine.swift — stems -> balanced mix -> polished master. Gain-stage, corrective EQ,
// cross-stem masking carves, constant-power placement, headroom-safe stereo sum, then hand
// the mix to MasteringEngine.master(...) and return its MasterResult with mix-stage notes.

import Foundation

enum MixEngine {

    /// A finished stereo mix bounce. This deliberately carries no mastering result:
    /// mixing stops at the headroom-safe stereo sum, while mastering is a separate job.
    struct MixResult {
        var output: AudioSignal
        var notes: [String]
    }

    // MARK: - Per-stem user controls

    /// User overrides for a single stem. When present they win over the engine's automatic,
    /// filename-based decisions — so a mis-detected or generically named stem is no longer
    /// silently guessed, and the user can trim / mute / solo each stem on its own chain.
    struct StemControl: Equatable, Sendable {
        var roleOverride: StemRole? = nil   // nil = use filename detection
        var gainTrimDB: Double = 0          // extra user trim, applied on top of auto gain-staging
        var muted: Bool = false
        var soloed: Bool = false
        /// User pan −1 (hard left) … +1 (hard right), constant-power. When set it WINS over
        /// the engine's automatic placement (including the centered-role rule) — mirroring
        /// how roleOverride/gainTrimDB already beat the automatic decisions.
        var panOverride: Double? = nil
        /// Phase-2 channel strip (gate → EQ → comp → de-ess → sat → dynEQ → transient →
        /// width → inserts → sends). Defaults to fully bypassed — bit-transparent.
        var strip: StemStripSettings = .neutral
        static let neutral = StemControl()
    }

    // MARK: - Public entry

    /// Deterministically mix a set of named stems into one headroom-safe stereo bounce.
    /// - stems:     named raw stems (any sample rate / channel count).
    static func mix(stems: [(name: String, signal: AudioSignal)],
                    styleName: String = "EDM foundation",
                    options: MixOptions = .balanced,
                    controls: [String: StemControl] = [:],
                    session: MixSessionSettings = .neutral,
                    progress: ((Double, String) -> Void)? = nil) -> MixResult {

        var mixNotes: [String] = []

        // Common sample rate = highest stem rate (never upsample-then-lose); 44.1k fallback.
        let commonRate = stems.map { $0.signal.sampleRate }.filter { $0 > 0 }.max() ?? 44_100.0

        // ---- (1) gain-stage each stem to the EDM role peak targets, + resample to a common rate ----
        progress?(0.05, "Gain-staging stems")
        var prepared: [(name: String, role: StemRole, pan: Double?, signal: AudioSignal)] = []
        prepared.reserveCapacity(stems.count)
        var resampledAny = false

        // If any stem is soloed, only soloed stems pass through to the mix.
        let soloActive = controls.values.contains { $0.soloed }

        for stem in stems {
            let control = controls[stem.name] ?? .neutral

            // Mute / solo gating — drop the stem entirely from the sum.
            if control.muted {
                mixNotes.append("Muted \"\(stem.name)\" — excluded from the mix.")
                continue
            }
            if soloActive && !control.soloed {
                mixNotes.append("Soloed elsewhere — held \"\(stem.name)\" out of the mix.")
                continue
            }

            var sig = stem.signal
            guard sig.frameCount > 0, sig.channelCount > 0 else { continue }

            // Resample if this stem doesn't already run at the common rate.
            if abs(sig.sampleRate - commonRate) > 0.5 {
                sig = resample(sig, toRate: commonRate)
                resampledAny = true
            }

            // Role: a user override wins over filename detection (fixes mis-detected / .other stems).
            let detected = StemRole.detect(stem.name)
            let role = control.roleOverride ?? detected

            // Clamped trim toward the user's gain-staging table:
            // kick -8..-6 dB peak, bass -10..-8, leads/vocals about -12, drums around -8.
            // The user's manual trim is added on top of the automatic gain-stage.
            let peak = peakDB(sig)
            let targetPeak = peakTargetDB(for: role)
            let autoTrim = clampd(targetPeak - peak, -18.0, 12.0)
            let totalTrim = clampd(autoTrim + control.gainTrimDB, -30.0, 24.0)
            if abs(totalTrim) > 0.01 { sig = applyGain(sig, dB: totalTrim) }

            let pan = control.panOverride.map { clampd($0, -1.0, 1.0) }
            prepared.append((stem.name, role, pan, sig))
            if let p = pan {
                mixNotes.append(String(format: "Panned \"%@\" %@ (user override, constant-power).",
                                       stem.name,
                                       abs(p) < 0.005 ? "center"
                                       : String(format: "%.0f%% %@", abs(p) * 100, p < 0 ? "left" : "right")))
            }

            var note = String(format: "Gain-staged \"%@\" %+.1f dB toward %.0f dBFS peak (role: %@",
                              stem.name, totalTrim, targetPeak, role.label)
            if control.roleOverride != nil && role != detected {
                note += String(format: ", user override — was %@", detected.label)
            } else {
                note += ", auto-detected"
            }
            if abs(control.gainTrimDB) > 0.01 {
                note += String(format: ", incl. %+.1f dB user trim", control.gainTrimDB)
            }
            note += ")."
            mixNotes.append(note)
        }
        if resampledAny {
            mixNotes.insert(String(format: "Resampled mismatched stems to %.0f Hz (linear) before summing.",
                                   commonRate), at: 0)
        }
        mixNotes.insert("\(styleName) loaded: gain staging before EQ/compression, role EQ, fast kick ducking, low-end mono, and -6 dB pre-master headroom.", at: 0)

        // Nothing usable — return a silent stereo bounce so the app stays deterministic.
        guard !prepared.isEmpty else {
            let silence = AudioSignal(channels: [[0], [0]], sampleRate: commonRate)
            return MixResult(output: silence,
                             notes: ["No usable stems supplied — created a silent mix bounce."])
        }

        // ---- (3) cross-stem masking analysis on the gain-staged stems ----
        progress?(0.20, "Analyzing frequency masking")
        let analyzer = FFTAnalyzer(size: 4096)
        let maskInput = prepared.map { (name: $0.name, signal: $0.signal) }
        let masking = MaskingDetector.analyze(stems: maskInput, analyzer: analyzer)
        if masking.issues.isEmpty {
            mixNotes.append("No significant cross-stem masking — stems already sit in their own space.")
        } else {
            mixNotes.append("Resolved \(masking.issues.count) masking collision(s) with narrow carves:")
            // Surface the worst few so the notes stay readable.
            for issue in masking.issues.prefix(4) { mixNotes.append("  • " + issue.suggestion) }
        }

        // ---- (2)+(3) apply corrective EQ + masking carves in ONE ParametricEQ pass per stem ----
        progress?(0.35, "Corrective EQ + carves")
        var placed: [(name: String, role: StemRole, pan: Double?, signal: AudioSignal)] = []
        placed.reserveCapacity(prepared.count)
        for p in prepared {
            var bands = correctiveBands(for: p.role)      // HP + de-mud from the stem's role
            if let carves = masking.suggestedCarves[p.name] { bands.append(contentsOf: carves) }
            let eqd = applyEQ(p.signal, bands: bands, sampleRate: commonRate)
            placed.append((p.name, p.role, p.pan, eqd))
        }

        // ---- (3.5) role character + sidechain: the artist's sound ----
        // Kick punched; bass warmed + ducked under the kick (low, strong, never taking over,
        // and never stacking into distortion); pads/synths/fx ducked to the kick for groove;
        // the whole bed ducked under the vocal so vocals stay clear; risers/FX kept in check.
        progress?(0.42, "Sidechain + role dynamics")
        let kickSig = placed.first(where: { $0.role == .kick })?.signal
        let voxSig  = placed.first(where: { $0.role == .vox })?.signal
        var processed: [(name: String, role: StemRole, pan: Double?, signal: AudioSignal)] = []
        processed.reserveCapacity(placed.count)
        var scCount = 0
        var compressedRoles: [String] = []
        for item in placed {
            var sig = item.signal
            let compressed = applyRoleDynamics(sig, role: item.role, sampleRate: commonRate)
            sig = compressed.signal
            if compressed.gainReductionDB > 0.25 {
                compressedRoles.append(String(format: "%@ %.1f dB", item.role.label, compressed.gainReductionDB))
            }
            sig = applyRoleSaturation(sig, role: item.role, options: options)
            sig = applyRoleWidth(sig, role: item.role, sampleRate: commonRate)
            switch item.role {
            case .kick:
                sig = Sidechain.transientPunch(sig, amount: options.kickPunch, sampleRate: commonRate)
            case .subBass, .bass:
                sig = Sidechain.warmth(sig, drive: 1.4, mix: options.bassDrive)   // strong, not distorted
                if let k = kickSig {
                    sig = Sidechain.duck(sig, by: k, depthDB: options.sidechainDepthDB,
                                         attackMs: 0, releaseMs: options.sidechainReleaseMs, sampleRate: commonRate)
                    scCount += 1
                }
            case .lead, .pluck, .synth, .pad:
                if let k = kickSig {
                    sig = Sidechain.duck(sig, by: k, depthDB: options.sidechainDepthDB * 0.6,
                                         attackMs: 0, releaseMs: options.sidechainReleaseMs, sampleRate: commonRate)
                    scCount += 1
                }
                if let v = voxSig {
                    sig = Sidechain.duck(sig, by: v, depthDB: options.vocalDuckDB,
                                         attackMs: 18, releaseMs: 220, sampleRate: commonRate)
                }
            case .fx:
                if let k = kickSig {
                    sig = Sidechain.duck(sig, by: k, depthDB: options.sidechainDepthDB,
                                         attackMs: 0, releaseMs: options.sidechainReleaseMs, sampleRate: commonRate)
                    scCount += 1
                }
                if let v = voxSig {
                    sig = Sidechain.duck(sig, by: v, depthDB: options.vocalDuckDB * 1.2,
                                         attackMs: 15, releaseMs: 200, sampleRate: commonRate)
                }
            case .drums, .clap, .hat, .other:
                if let v = voxSig {
                    sig = Sidechain.duck(sig, by: v, depthDB: options.vocalDuckDB * 0.6,
                                         attackMs: 18, releaseMs: 220, sampleRate: commonRate)
                }
            case .vox:
                break   // the vocal sits on top; nothing ducks it
            }
            processed.append((item.name, item.role, item.pan, sig))
        }
        if !compressedRoles.isEmpty {
            mixNotes.append("Applied role compression where needed: \(compressedRoles.prefix(6).joined(separator: ", ")).")
        }
        if kickSig != nil && scCount > 0 {
            mixNotes.append(String(format: "Sidechained %d element(s) to the kick (%.0f dB, %.0f ms release) — bass sits under the kick, low end stays clean.",
                                   scCount, options.sidechainDepthDB, options.sidechainReleaseMs))
        }
        if voxSig != nil {
            mixNotes.append(String(format: "Ducked the bed under the vocal (%.0f dB) so vocals stay clear and out front.", options.vocalDuckDB))
        }
        if kickSig != nil {
            mixNotes.append(String(format: "Snapped the kick transient (%.0f%%) for a strong, quick hit.", options.kickPunch * 100))
        }

        // ---- (3.8) Phase-2 user channel strips + send taps (bit-transparent when neutral) ----
        var reverbTaps: AudioSignal? = nil
        var delayTaps: AudioSignal? = nil
        for idx in 0..<processed.count {
            let strip = controls[processed[idx].name]?.strip ?? .neutral
            if strip.hasInlineProcessing {
                let applied = strip.apply(to: processed[idx].signal, sampleRate: commonRate,
                                          stemName: processed[idx].name)
                processed[idx].signal = applied.signal
                mixNotes.append(contentsOf: applied.notes)
            }
            if strip.sendReverb > 0.0001 {
                let tap = SessionDSP.scaled(processed[idx].signal, by: strip.sendReverb)
                reverbTaps = reverbTaps.map { SessionDSP.summed($0, tap) } ?? tap
                mixNotes.append(String(format: "Send \"%@\" → reverb return at %.0f%%.",
                                       processed[idx].name, strip.sendReverb * 100))
            }
            if strip.sendDelay > 0.0001 {
                let tap = SessionDSP.scaled(processed[idx].signal, by: strip.sendDelay)
                delayTaps = delayTaps.map { SessionDSP.summed($0, tap) } ?? tap
                mixNotes.append(String(format: "Send \"%@\" → delay return at %.0f%%.",
                                       processed[idx].name, strip.sendDelay * 100))
            }
        }

        // ---- (4)+(5) constant-power placement, sum to stereo with -6 dB headroom ----
        // Neutral sessions take the EXACT pre-Phase-2 sum path (bit-identical, regression-locked).
        // Any active bus/send switches to the bus topology: stems → role buses → bus processing
        // (glue comp / parallel blend / ducking) → bus sum + wet-only returns → same headroom guard.
        progress?(0.45, "Placing + summing")
        var mix: AudioSignal
        if session.busesNeutral && reverbTaps == nil && delayTaps == nil {
            mix = sumToStereo(processed.map { ($0.role, $0.pan, $0.signal) }, sampleRate: commonRate)
            mixNotes.append("Summed with club-safe imaging: kick/sub/bass centered, side energy folded below 120 Hz, pre-master peak guarded around -6 dBFS.")
        } else {
            mix = busSum(processed, session: session, sampleRate: commonRate,
                         reverbTaps: reverbTaps, delayTaps: delayTaps, notes: &mixNotes)
            mixNotes.append("Summed through role buses (drums / instruments / vocals) with club-safe imaging and the same -6 dBFS pre-master headroom guard.")
        }

        progress?(1.0, "Mix ready")
        return MixResult(output: mix, notes: mixNotes)
    }

    /// Compatibility pipeline for tests, CLI clients, and old callers. The implementation
    /// composes the two independent jobs, so its audio remains identical while the app UI
    /// can stop after `mix(...)` and hand the bounce to mastering explicitly.
    static func mixAndMaster(stems: [(name: String, signal: AudioSignal)],
                             reference: AudioSignal?,
                             genre: GenreTarget,
                             platform: PlatformTarget,
                             intensity: MasterIntensity = .balanced,
                             loudnessOverrideLUFS: Double? = nil,
                             styleName: String = "EDM foundation",
                             options: MixOptions = .balanced,
                             controls: [String: StemControl] = [:],
                             session: MixSessionSettings = .neutral,
                             masterChain: MasterChainSettings = .neutral,
                             userEQ: [EQBand] = [],
                             softClip: SoftClipSettings = .bypassed,
                             ceilingOverrideDBTP: Double? = nil,
                             progress: ((Double, String) -> Void)? = nil) -> MasterResult {
        let mixed = mix(stems: stems, styleName: styleName, options: options,
                        controls: controls, session: session,
                        progress: { f, message in progress?(0.5 * f, message) })
        let sampleRate = mixed.output.sampleRate > 0 ? mixed.output.sampleRate : 44_100
        let manual = masterChain.apply(to: mixed.output, sampleRate: sampleRate)
        var result = MasteringEngine.master(
            input: manual.signal,
            reference: reference,
            genre: genre,
            platform: platform,
            intensity: intensity,
            loudnessOverrideLUFS: loudnessOverrideLUFS,
            userEQ: userEQ,
            softClip: softClip,
            ceilingOverrideDBTP: ceilingOverrideDBTP,
            progress: { f, message in progress?(0.5 + 0.5 * f, message) }
        )
        result.notes.insert(contentsOf: mixed.notes + manual.notes, at: 0)
        progress?(1.0, "Done")
        return result
    }

    // MARK: - Stem role

    /// Musical role inferred from a stem's file name (case-insensitive keyword match),
    /// or set explicitly by the user via a per-stem override.
    enum StemRole: CaseIterable, Identifiable, Hashable, Sendable {
        case kick, subBass, bass, drums, clap, hat, vox, lead, pluck, synth, pad, fx, other

        var id: String { key }

        /// Stable string key (persistence + UI tags), independent of the display label.
        var key: String {
            switch self {
            case .kick: return "kick";       case .subBass: return "subBass"
            case .bass: return "bass";       case .drums: return "drums"
            case .clap: return "clap";       case .hat: return "hat"
            case .vox: return "vox";         case .lead: return "lead"
            case .pluck: return "pluck";     case .synth: return "synth"
            case .pad: return "pad";         case .fx: return "fx"
            case .other: return "other"
            }
        }

        var label: String {
            switch self {
            case .kick: return "kick";       case .subBass: return "sub bass"
            case .bass: return "bass";       case .drums: return "drums"
            case .clap: return "clap/snare"; case .hat: return "hi-hat"
            case .vox: return "vox";         case .lead: return "lead"
            case .pluck: return "pluck";     case .synth: return "synth"
            case .pad: return "pad";         case .fx: return "fx"
            case .other: return "other"
            }
        }

        /// Center-image roles: the foundation + focal elements stay mono-centered.
        var isCentered: Bool {
            switch self { case .kick, .subBass, .bass, .clap, .vox: return true; default: return false }
        }

        /// Low-end roles that must NOT be high-passed away.
        var isLowEnd: Bool {
            switch self { case .kick, .subBass, .bass: return true; default: return false }
        }

        /// Order matters: most specific keywords first (kick/bass before generic "drum"/"synth").
        static func detect(_ name: String) -> StemRole {
            let s = name.lowercased()
            func any(_ ks: [String]) -> Bool { ks.contains { s.contains($0) } }
            if any(["kick", "bd "]) { return .kick }
            if any(["808", "sub bass", "sub", "sine bass"]) { return .subBass }
            if any(["mid bass", "bass", "reese", "donk"]) { return .bass }
            if any(["vox", "vocal", "voice", "acapella"]) { return .vox }
            if any(["pluck", "plk"]) { return .pluck }
            if any(["lead", "topline", "melody", "hook", "pluck lead"]) { return .lead }
            if any(["snare", "clap", "rim"]) { return .clap }
            if any(["hat", "hihat", "hi-hat", "ride", "cymbal", "shaker"]) { return .hat }
            if any(["drum", "perc", "tom"]) { return .drums }
            if any(["synth", "arp", "stab", "key", "piano", "organ"]) { return .synth }
            if any(["pad", "string", "atmos", "ambient", "drone", "choir"]) { return .pad }
            if any(["fx", "riser", "sweep", "impact", "noise", "foley", "downlifter", "uplifter", "texture"]) { return .fx }
            return .other
        }
    }

    // MARK: - Per-stem corrective EQ

    /// Gentle, defensible per-stem cleanup: high-pass everything that isn't low-end,
    /// and scoop ~300 Hz mud on the roles that tend to build boxiness in a dense mix.
    private static func correctiveBands(for role: StemRole) -> [EQBand] {
        switch role {
        // Kick: keep the thump, carve where the bass lives (complementary), lift the beater click → "strong, quick".
        case .kick:  return [.peak(60, 1.5, 1.0), .peak(280, -2.0, 1.1), .peak(4000, 2.0, 1.0)]
        // Sub bass: keep only the low lane, remove rumble, low-pass the top, and keep it mono downstream.
        case .subBass: return [.highPass(25, 0.707), .lowPass(140, 0.707)]
        // Mid bass: make room for the kick/sub, give 150-300 Hz body, and cut mud.
        case .bass:  return [.highPass(110, 0.707), .peak(220, 1.2, 1.0), .peak(320, -2.0, 1.1), .highShelf(1200, -1.2)]
        case .drums: return [.highPass(90, 0.707), .peak(300, -1.5, 1.0), .highShelf(9000, 1.0)]
        case .clap:  return [.highPass(150, 0.707), .peak(3500, 1.5, 0.9), .highShelf(10000, 1.0)]
        case .hat:   return [.highPass(300, 0.707), .peak(10000, 1.5, 0.9)]
        // Vocals: clear + forward — de-mud, presence lift, a touch of de-harsh, air.
        case .vox:   return [.highPass(100, 0.707), .peak(300, -2.0, 1.1), .peak(3500, 2.0, 1.0), .peak(6500, -1.5, 3.0), .highShelf(11000, 1.5)]
        // Lead / synth: "carry the flow" — presence + air, a little out of the vocal's way.
        case .lead:  return [.highPass(180, 0.707), .peak(400, -1.2, 1.0), .peak(3500, 1.8, 1.0), .highShelf(12000, 1.8)]
        case .pluck: return [.highPass(220, 0.707), .peak(4500, 1.7, 1.0), .highShelf(10000, 0.8)]
        case .synth: return [.highPass(170, 0.707), .peak(350, -1.5, 1.0), .peak(3000, 1.2, 1.0), .highShelf(11000, 1.5)]
        case .pad:   return [.highPass(300, 0.707), .peak(450, -2.0, 1.0), .highShelf(12000, 1.5)]
        case .fx:    return [.highPass(150, 0.707)]
        case .other: return [.highPass(90, 0.707), .peak(300, -1.5, 1.0)]
        }
    }

    // MARK: - Per-stem treatment readout (UI transparency)

    /// Human-readable summary of exactly what the mix engine applies to a stem of this role.
    /// The EQ line is derived from the same `correctiveBands` table the engine runs, so the
    /// readout can never drift from the DSP; the rest mirrors the role dynamics/width/sidechain.
    static func treatmentSummary(for role: StemRole) -> [String] {
        var lines: [String] = []

        // EQ — the exact corrective bands this role receives.
        let bands = correctiveBands(for: role).filter { $0.enabled }
        lines.append(bands.isEmpty ? "EQ: none"
                                   : "EQ: " + bands.map { describeBand($0) }.joined(separator: ", "))

        // Compression (role dynamics) — mirrors roleCompression(for:).
        switch role {
        case .kick:            lines.append("Comp: 4:1 fast — glue the thump")
        case .subBass, .bass:  lines.append("Comp: 3:1 medium — steady low end")
        case .vox:             lines.append("Comp: 3:1 fast — keep the vocal even")
        case .drums, .clap:    lines.append("Comp: 2:1 slow — control transients")
        default:               lines.append("Comp: none")
        }

        // Saturation / warmth — mirrors applyRoleSaturation.
        switch role {
        case .subBass:              lines.append("Warmth: light sub drive")
        case .bass:                 lines.append("Warmth: bass drive")
        case .drums, .clap:         lines.append("Warmth: subtle")
        case .vox:                  lines.append("Warmth: subtle vocal glue")
        case .lead, .pluck, .synth: lines.append("Warmth: subtle")
        default:                    break
        }

        // Stereo width / placement — mirrors applyRoleWidth + sumToStereo.
        switch role {
        case .kick, .subBass, .bass:               lines.append("Image: mono-centered — low end tight")
        case .vox, .clap:                          lines.append("Image: near-center, mono < 120 Hz")
        case .drums, .hat, .lead, .pluck, .synth:  lines.append("Image: widened, mono < 120 Hz")
        case .pad, .fx:                            lines.append("Image: wide, mono < 120 Hz")
        case .other:                               lines.append("Image: natural, mono < 120 Hz")
        }

        // Sidechain behaviour — mirrors the role switch in the sidechain stage.
        switch role {
        case .kick:                        lines.append("Sidechain: transient-punched — kick anchor")
        case .subBass, .bass:              lines.append("Sidechain: ducked under the kick")
        case .lead, .pluck, .synth, .pad:  lines.append("Sidechain: ducked to kick + under the vocal")
        case .fx:                          lines.append("Sidechain: ducked to kick + hard under vocal")
        case .drums, .clap, .hat, .other:  lines.append("Sidechain: light duck under the vocal")
        case .vox:                         lines.append("Sidechain: none — sits on top")
        }

        return lines
    }

    private static func describeBand(_ b: EQBand) -> String {
        func hz(_ f: Double) -> String { f >= 1000 ? String(format: "%.1fk", f / 1000) : String(format: "%.0f", f) }
        switch b.kind {
        case .highPass:  return "HPF \(hz(b.freq))Hz"
        case .lowPass:   return "LPF \(hz(b.freq))Hz"
        case .highShelf: return String(format: "HS \(hz(b.freq))Hz %+.1fdB", b.gainDB)
        case .lowShelf:  return String(format: "LS \(hz(b.freq))Hz %+.1fdB", b.gainDB)
        case .peaking:   return String(format: "%@ \(hz(b.freq))Hz %+.1fdB", b.gainDB >= 0 ? "boost" : "cut", b.gainDB)
        }
    }

    // MARK: - EDM foundation helpers

    /// The user's gain-staging targets, represented as midpoint peak levels.
    private static func peakTargetDB(for role: StemRole) -> Double {
        switch role {
        case .kick: return -7
        case .subBass, .bass: return -9
        case .drums, .clap, .hat: return -8
        case .vox, .lead, .pluck, .synth, .pad: return -12
        case .fx, .other: return -12
        }
    }

    private static func roleCompression(for role: StemRole,
                                        peakDB: Double,
                                        rmsDB: Double) -> CompressorSettings? {
        let threshold = min(peakDB - 3.0, rmsDB + 6.0)
        switch role {
        case .kick:
            return CompressorSettings(thresholdDB: threshold, ratio: 4.0, attackMs: 15, releaseMs: 55, kneeDB: 4, makeupDB: 0)
        case .subBass, .bass:
            return CompressorSettings(thresholdDB: threshold, ratio: 3.0, attackMs: 20, releaseMs: 100, kneeDB: 5, makeupDB: 0)
        case .vox:
            return CompressorSettings(thresholdDB: threshold, ratio: 3.0, attackMs: 10, releaseMs: 60, kneeDB: 6, makeupDB: 0)
        case .drums, .clap:
            return CompressorSettings(thresholdDB: min(peakDB - 2.0, rmsDB + 7.0), ratio: 2.0, attackMs: 30, releaseMs: 100, kneeDB: 6, makeupDB: 0)
        default:
            return nil
        }
    }

    private static func applyRoleDynamics(_ s: AudioSignal,
                                          role: StemRole,
                                          sampleRate: Double) -> (signal: AudioSignal, gainReductionDB: Double) {
        let levels = peakAndRMSDB(s)
        guard let settings = roleCompression(for: role, peakDB: levels.peakDB, rmsDB: levels.rmsDB) else {
            return (s, 0)
        }
        let compressor = Compressor(settings: settings, sampleRate: sampleRate)
        let out = compressor.process(s)
        return (out, compressor.lastGainReductionDB)
    }

    private static func applyRoleSaturation(_ s: AudioSignal,
                                            role: StemRole,
                                            options: MixOptions) -> AudioSignal {
        switch role {
        case .subBass:
            return Sidechain.warmth(s, drive: 1.2, mix: options.bassDrive * 0.45)
        case .bass:
            return Sidechain.warmth(s, drive: 1.5, mix: options.bassDrive)
        case .drums, .clap:
            return Sidechain.warmth(s, drive: 1.25, mix: 0.08)
        case .vox:
            return Sidechain.warmth(s, drive: 1.18, mix: 0.06)
        case .lead, .pluck, .synth:
            return Sidechain.warmth(s, drive: 1.22, mix: 0.07)
        default:
            return s
        }
    }

    private static func applyRoleWidth(_ s: AudioSignal,
                                       role: StemRole,
                                       sampleRate: Double) -> AudioSignal {
        guard s.channelCount >= 2 else { return s }
        let width: Double
        switch role {
        case .kick, .subBass, .bass:
            width = 0.0
        case .vox, .clap:
            width = 0.55
        case .drums, .hat, .lead, .pluck, .synth:
            width = 1.15
        case .pad, .fx:
            width = 1.35
        case .other:
            width = 1.0
        }
        return StereoImager().process(s, width: width, monoBelowHz: 120, sampleRate: sampleRate)
    }

    // MARK: - Placement + sum

    /// Constant-power pan of each stem into a single stereo bounce with -6 dB sum headroom.
    /// A user panOverride wins outright; otherwise center roles stay dead-center and the
    /// rest fan out deterministically L/R by appearance order.
    private static func sumToStereo(_ placed: [(role: StemRole, pan: Double?, signal: AudioSignal)],
                                    sampleRate: Double) -> AudioSignal {
        let n = placed.map { $0.signal.frameCount }.max() ?? 0
        guard n > 0 else { return AudioSignal(channels: [[0], [0]], sampleRate: sampleRate) }

        var accL = [Double](repeating: 0, count: n)
        var accR = [Double](repeating: 0, count: n)

        var spreadIndex = 0
        for item in placed {
            let sig = item.signal
            let ch = sig.channels
            guard let l = ch.first else { continue }
            let r = ch.count > 1 ? ch[1] : l   // mono -> duplicate into both sides

            // Pan position in [-1, 1]: a user override wins; else centered roles at 0,
            // others fan out ±.
            let pan: Double
            if let userPan = item.pan {
                pan = clampd(userPan, -1.0, 1.0)
            } else if item.role.isCentered {
                pan = 0.0
            } else {
                let sign: Double = (spreadIndex % 2 == 0) ? -1.0 : 1.0
                let mag = min(0.6, 0.25 + 0.12 * Double(spreadIndex / 2))
                pan = sign * mag
                spreadIndex += 1
            }

            // Constant-power law: theta 0..pi/2, gL=cos, gR=sin (equal power at every position).
            let theta = (pan + 1.0) * 0.5 * (Double.pi / 2.0)
            let gL = cos(theta)
            let gR = sin(theta)

            let m = min(n, min(l.count, r.count))
            for i in 0..<m {
                accL[i] += Double(l[i]) * gL
                accR[i] += Double(r[i]) * gR
            }
        }

        // -6 dB headroom on the sum, then a peak guard so nothing clips into the master.
        let headroom = dbToGain(-6.0)
        var peak = 0.0
        for i in 0..<n {
            accL[i] *= headroom; accR[i] *= headroom
            let a = max(abs(accL[i]), abs(accR[i]))
            if a > peak { peak = a }
        }
        let norm = peak > 0.999 ? (0.999 / peak) : 1.0

        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        for i in 0..<n {
            outL[i] = Float(accL[i] * norm)
            outR[i] = Float(accR[i] * norm)
        }
        return AudioSignal(channels: [outL, outR], sampleRate: sampleRate)
    }

    // MARK: - Bus topology (Phase 2)

    /// Sum via the three role buses (drums / instruments / vocals): pan positions are assigned
    /// with EXACTLY the same law/ordering as `sumToStereo`, each stem lands on its role bus,
    /// each bus runs its user glue compression / parallel blend / generalized ducking, and the
    /// wet-only send returns join the final sum before the same -6 dB headroom + peak guard.
    private static func busSum(_ items: [(name: String, role: StemRole, pan: Double?, signal: AudioSignal)],
                               session: MixSessionSettings,
                               sampleRate: Double,
                               reverbTaps: AudioSignal?,
                               delayTaps: AudioSignal?,
                               notes: inout [String]) -> AudioSignal {
        let n = items.map { $0.signal.frameCount }.max() ?? 0
        guard n > 0 else { return AudioSignal(channels: [[0], [0]], sampleRate: sampleRate) }

        // Pan gains, same law + fan-out ordering as the direct path.
        var spreadIndex = 0
        var panGains: [(gL: Double, gR: Double)] = []
        panGains.reserveCapacity(items.count)
        for item in items {
            let pan: Double
            if let userPan = item.pan {
                pan = clampd(userPan, -1.0, 1.0)
            } else if item.role.isCentered {
                pan = 0.0
            } else {
                let sign: Double = (spreadIndex % 2 == 0) ? -1.0 : 1.0
                let mag = min(0.6, 0.25 + 0.12 * Double(spreadIndex / 2))
                pan = sign * mag
                spreadIndex += 1
            }
            let theta = (pan + 1.0) * 0.5 * (Double.pi / 2.0)
            panGains.append((cos(theta), sin(theta)))
        }

        // Accumulate each stem into its role bus.
        var busAcc: [BusRole: (l: [Double], r: [Double])] = [:]
        var stemSignals: [String: AudioSignal] = [:]
        for (idx, item) in items.enumerated() {
            let busRole = BusRole.bus(for: item.role)
            var acc = busAcc[busRole] ?? ([Double](repeating: 0, count: n), [Double](repeating: 0, count: n))
            let ch = item.signal.channels
            guard let l = ch.first else { continue }
            let r = ch.count > 1 ? ch[1] : l
            let (gL, gR) = panGains[idx]
            let m = min(n, min(l.count, r.count))
            for i in 0..<m {
                acc.l[i] += Double(l[i]) * gL
                acc.r[i] += Double(r[i]) * gR
            }
            busAcc[busRole] = acc
            stemSignals[item.name] = item.signal
        }

        // Materialize pre-processing bus signals (ducker sources reference these — pre-duck,
        // so two buses ducking each other can never chase their own output). Fixed BusRole
        // ordering everywhere below: float summation order is part of determinism.
        var busPre: [BusRole: AudioSignal] = [:]
        for role in BusRole.allCases {
            guard let acc = busAcc[role] else { continue }
            busPre[role] = AudioSignal(channels: [acc.l.map(Float.init), acc.r.map(Float.init)],
                                       sampleRate: sampleRate)
        }

        // Per-bus user processing: glue comp + parallel blend, then the generalized ducker.
        var busOut: [AudioSignal] = []
        for role in BusRole.allCases {
            guard let pre = busPre[role] else { continue }
            let settings = session.bus(role)
            var sig = pre
            if settings.compressorEnabled {
                let comp = Compressor(settings: settings.compressor, sampleRate: sampleRate)
                let wet = comp.process(sig)
                let blend = clampd(settings.parallelWet, 0.0, 1.0)
                sig = ParallelBlend.blend(dry: sig, wet: wet, wetMix: blend)
                notes.append(String(format: "%@: glue compression %.1f:1 at %.0f dB — measured %.1f dB gain reduction%@.",
                                    role.label, settings.compressor.ratio, settings.compressor.thresholdDB,
                                    comp.lastGainReductionDB,
                                    blend < 0.999 ? String(format: ", parallel-blended %.0f%% wet", blend * 100) : ""))
            }
            if settings.duckEnabled, let source = settings.duckSource {
                let trigger: AudioSignal?
                switch source {
                case .stem(let name): trigger = stemSignals[name]
                case .bus(let srcRole): trigger = srcRole == role ? nil : busPre[srcRole]
                }
                if let trigger {
                    sig = Sidechain.duck(sig, by: trigger, settings: settings.ducker, sampleRate: sampleRate)
                    notes.append(String(format: "%@: ducked %.0f dB by %@ (%.0f ms release).",
                                        role.label, settings.ducker.depthDB, source.label,
                                        settings.ducker.releaseMs))
                } else {
                    notes.append("\(role.label): duck source \"\(source.label)\" not found — ducker skipped.")
                }
            }
            busOut.append(sig)
        }

        // Wet-only shared returns (reverb + delay), fed by the strips' send taps.
        var returns: [AudioSignal] = []
        if let taps = reverbTaps {
            var cfg = session.sends.reverb
            cfg.enabled = true
            cfg.mix = 1.0                                    // wet-only return, always
            let wet = Reverb(settings: cfg, sampleRate: sampleRate).process(taps)
            let trimmed = SessionDSP.applyGainDB(wet, db: session.sends.reverbReturnDB)
            returns.append(trimmed)
            notes.append(String(format: "Reverb return: %@ %.1f s decay, wet-only at %+.1f dB — measured return RMS %.1f dBFS.",
                                cfg.preset.rawValue, cfg.decaySeconds, session.sends.reverbReturnDB,
                                trimmed.rms(across: 0)))
        }
        if let taps = delayTaps {
            var cfg = session.sends.delay
            cfg.enabled = true
            cfg.mix = 1.0                                    // wet-only return, always
            let wet = StereoDelay(settings: cfg, sampleRate: sampleRate).process(taps)
            let trimmed = SessionDSP.applyGainDB(wet, db: session.sends.delayReturnDB)
            returns.append(trimmed)
            notes.append(String(format: "Delay return: %@ %.0f ms, wet-only at %+.1f dB — measured return RMS %.1f dBFS.",
                                cfg.mode.rawValue, cfg.timeMs, session.sends.delayReturnDB,
                                trimmed.rms(across: 0)))
        }

        // Final sum: buses + returns, then the same -6 dB headroom + 0.999 peak guard.
        var accL = [Double](repeating: 0, count: n)
        var accR = [Double](repeating: 0, count: n)
        for sig in busOut + returns {
            let ch = sig.channels
            guard let l = ch.first else { continue }
            let r = ch.count > 1 ? ch[1] : l
            let m = min(n, min(l.count, r.count))
            for i in 0..<m {
                accL[i] += Double(l[i])
                accR[i] += Double(r[i])
            }
        }
        let headroom = dbToGain(-6.0)
        var peak = 0.0
        for i in 0..<n {
            accL[i] *= headroom; accR[i] *= headroom
            let a = max(abs(accL[i]), abs(accR[i]))
            if a > peak { peak = a }
        }
        let norm = peak > 0.999 ? (0.999 / peak) : 1.0
        var outL = [Float](repeating: 0, count: n)
        var outR = [Float](repeating: 0, count: n)
        for i in 0..<n {
            outL[i] = Float(accL[i] * norm)
            outR[i] = Float(accR[i] * norm)
        }
        return AudioSignal(channels: [outL, outR], sampleRate: sampleRate)
    }

    // MARK: - DSP helpers

    @inline(__always) private static func clampd(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        x < lo ? lo : (x > hi ? hi : x)
    }
    @inline(__always) private static func dbToGain(_ db: Double) -> Double { pow(10.0, db / 20.0) }

    private static func peakDB(_ s: AudioSignal) -> Double {
        let peak = peakAndRMSDB(s).peakDB
        return peak.isFinite ? peak : -200
    }

    /// Broadband peak and RMS across all channels, in dBFS.
    private static func peakAndRMSDB(_ s: AudioSignal) -> (peakDB: Double, rmsDB: Double) {
        var peak = 0.0
        var sumSq = 0.0
        var count = 0
        for ch in s.channels {
            for v in ch {
                let d = Double(v)
                let a = abs(d)
                if a > peak { peak = a }
                sumSq += d * d
            }
            count += ch.count
        }
        guard count > 0 else { return (-200, -200) }
        let rms = (sumSq / Double(count)).squareRoot()
        let pDB = peak > 0 ? max(-200, 20.0 * log10(peak)) : -200
        let rDB = rms > 0 ? max(-200, 20.0 * log10(rms)) : -200
        return (pDB, rDB)
    }

    /// Apply a fixed broadband gain (dB) to every sample; math in Double, stored as Float.
    private static func applyGain(_ s: AudioSignal, dB: Double) -> AudioSignal {
        let g = dbToGain(dB)
        var out = s.channels
        for c in 0..<out.count {
            for i in 0..<out[c].count { out[c][i] = Float(Double(out[c][i]) * g) }
        }
        return AudioSignal(channels: out, sampleRate: s.sampleRate)
    }

    /// Render a set of EQ bands through a stateful ParametricEQ, one pass per channel.
    private static func applyEQ(_ s: AudioSignal, bands: [EQBand], sampleRate: Double) -> AudioSignal {
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

    /// Linear-interpolating sample-rate conversion (per channel). Deterministic, phase-safe enough
    /// for stem alignment; the master stage does the final quality-critical work.
    private static func resample(_ s: AudioSignal, toRate: Double) -> AudioSignal {
        guard s.sampleRate > 0, toRate > 0, s.frameCount > 0 else {
            return AudioSignal(channels: s.channels, sampleRate: toRate)
        }
        let ratio = toRate / s.sampleRate
        let newLen = max(1, Int((Double(s.frameCount) * ratio).rounded()))
        var out = [[Float]](repeating: [Float](repeating: 0, count: newLen), count: s.channelCount)
        for c in 0..<s.channelCount {
            let src = s.channels[c]
            let srcLen = src.count
            guard srcLen > 0 else { continue }
            for i in 0..<newLen {
                let pos = Double(i) / ratio
                let i0 = Int(pos)
                if i0 >= srcLen - 1 {
                    out[c][i] = src[srcLen - 1]
                } else {
                    let frac = pos - Double(i0)
                    let a = Double(src[i0]), b = Double(src[i0 + 1])
                    out[c][i] = Float(a + (b - a) * frac)
                }
            }
        }
        return AudioSignal(channels: out, sampleRate: toRate)
    }
}
