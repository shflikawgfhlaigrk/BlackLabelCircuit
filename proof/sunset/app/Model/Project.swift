#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// AppState: the app's single observable model — holds input/reference, targets, and drives the offline engines.

import Foundation
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// Central app state. Owns the loaded audio, the selected targets, and orchestrates the
/// offline mix/master engines on a background task while keeping UI updates on the main actor.
@MainActor
final class AppState: ObservableObject {
    private struct ProcessOutcome {
        var result: MasterResult?
        var mixResult: MixEngine.MixResult?
        var error: String?
    }

    // Input
    @Published var inputSignal: AudioSignal?
    @Published var inputURL: URL?
    @Published var stemURLs: [URL] = []
    @Published var referenceURL: URL?

    // Reference by link — synthesize a target from a streaming URL's public metadata.
    @Published var referenceLink: String = ""
    @Published var linkReference: LinkReference?
    @Published var isResolvingLink: Bool = false
    @Published var linkError: String?

    // Targets / mode
    @Published var selectedGenre: GenreTarget = GenreTargets.default
    @Published var selectedPlatform: PlatformTarget = PlatformTargets.default
    @Published var mode: ProcessMode = .masterOnly
    @Published var mixStyle: MixStyle = MixStyles.default   // drives the stems path (roles + sidechain)

    // Run state
    @Published var isProcessing: Bool = false
    @Published var progress: Double = 0          // 0...1
    @Published var statusLine: String = "Ready."
    @Published var result: MasterResult?         // MasterResult declared by the MasteringEngine agent
    @Published var mixResult: MixEngine.MixResult? // Finished mix bounce; never mislabeled as a master.
    @Published var log: [String] = []
    @Published var lastExportURL: URL?
    @Published var doctorReport: DoctorReport?
    @Published var masterVariants: [MasterVariant] = []
    @Published var isRenderingMatrix: Bool = false
    @Published var stemConflictReport: StemConflictReport?
    @Published var isAnalyzingStems: Bool = false

    /// Per-stem user controls (role override, gain trim, mute, solo, Phase-2 strip), keyed by
    /// stem display name. Held in the app state so overrides persist across renders and drive
    /// MixEngine directly.
    @Published var stemControls: [String: MixEngine.StemControl] = [:]

    // MARK: Phase 2 — MIX / MASTER areas

    /// Which top-level area is showing. Mixing and mastering are different disciplines —
    /// loading stems lands you in MIX, loading a stereo bounce lands you in MASTER.
    @Published var studioArea: StudioArea = .master

    /// MIX-area bus + send settings (per-stem strips ride on `stemControls[..].strip`).
    @Published var mixSession: MixSessionSettings = .neutral
    /// MASTER-area manual chain, layered on top of the guided mastering default.
    @Published var masterChain: MasterChainSettings = .neutral

    func busSettings(_ role: BusRole) -> BusSettings { mixSession.bus(role) }
    func setBusSettings(_ role: BusRole, _ settings: BusSettings) { mixSession.setBus(role, settings) }

    /// Switch jobs without conflating their inputs or render buttons. Each workspace keeps
    /// its own material in memory, but only its own engine becomes runnable.
    func activateStudioArea(_ area: StudioArea) {
        stopAudition()
        studioArea = area
        switch area {
        case .mix:
            mode = .mixOnly
            auditionSource = .master
            masterPeaks = mixResult.map { WaveformView.envelope($0.output) } ?? []
            note(stemURLs.isEmpty ? "MIXING ready — load stems." : "MIXING active — create a stereo mix bounce.")
        case .master:
            mode = .masterOnly
            auditionSource = result == nil ? .original : .master
            inputPeaks = inputSignal.map { WaveformView.envelope($0) } ?? []
            masterPeaks = result.map { WaveformView.envelope($0.output) } ?? []
            note(inputSignal == nil ? "MASTERING ready — load a finished stereo mix." : "MASTERING active — create a release master.")
        }
        playhead = 0
    }

    func stemStrip(_ name: String) -> StemStripSettings { stemControl(name).strip }
    func setStemStrip(_ name: String, _ strip: StemStripSettings) {
        var c = stemControl(name); c.strip = strip; stemControls[name] = c
    }

    // Export breadth (SS-07 / SS-08): container, PCM/FLAC bit depth, optional SRC, ISRC tag.
    @Published var exportFormat: ExportFormat = .wav
    @Published var exportBitDepth: Int = 24          // 16 or 24 (PCM + FLAC)
    @Published var exportSampleRate: Int = 0         // 0 = keep source; else 44100 / 48000
    @Published var exportISRC: String = ""
    /// The concrete export request built from the current picker state + track name for the title tag.
    var exportSettings: ExportSettings {
        let title = inputURL?.deletingPathExtension().lastPathComponent
        return ExportSettings(
            format: exportFormat,
            bitDepth: exportBitDepth,
            sampleRate: exportSampleRate > 0 ? Double(exportSampleRate) : nil,
            metadata: AudioMetadata(title: title, artist: nil, album: "Sunset master",
                                    isrc: exportISRC.trimmingCharacters(in: .whitespaces).isEmpty
                                          ? nil : exportISRC.trimmingCharacters(in: .whitespaces)))
    }

    // SS-16 report card: composed on demand from the finished master.
    var reportCard: ReportCard? {
        guard let result else { return nil }
        return ReportCard.compose(master: result, label: inputURL?.lastPathComponent ?? "Sunset master")
    }

    // SS-21 unified Explainable-Master Proof: report card + gain-matched A/B + delta + PSR, one surface.
    var masterProof: MasterProof? {
        guard let result else { return nil }
        return MasterProof.compose(master: result, label: inputURL?.lastPathComponent ?? "Sunset master")
    }

    // SS-20 per-platform delivery pack run state.
    @Published var isDeliveryPack: Bool = false
    @Published var deliveryPackSummaries: [String] = []
    @Published var lastDeliveryPackDir: URL?

    // SS-18 "Hear What Changed": the residual audition signal (reuses the translation playback slot).
    private var deltaAuditionSignal: AudioSignal?

    // Character / loudness controls
    @Published var intensity: MasterIntensity = .default
    @Published var useCustomLoudness: Bool = false
    @Published var customLUFS: Double = -9.0
    var loudnessOverride: Double? { useCustomLoudness ? customLUFS : nil }

    // Pre-limiter soft-clip stage (club/tech-house punch). Independent, bypassable.
    @Published var softClipEnabled: Bool = false
    @Published var softClipDriveDB: Double = 1.25   // 0.5…3 dB design range
    var softClipSettings: SoftClipSettings { SoftClipSettings(enabled: softClipEnabled, driveDB: softClipDriveDB) }

    // Selectable loudness profile (Club / Tech-House, etc.). Default = defer to Intensity.
    @Published var loudnessProfileID: String = LoudnessProfiles.default.id
    var loudnessProfile: LoudnessProfile { LoudnessProfiles.byID(loudnessProfileID) ?? LoudnessProfiles.none }
    /// Select a loudness profile; a profile that calls for the soft clip switches it on
    /// (a convenience — the buyer can still bypass it from the Master Engine panel).
    func selectLoudnessProfile(id: String) {
        loudnessProfileID = id
        if let p = LoudnessProfiles.byID(id), p.softClip.enabled {
            softClipEnabled = true
            softClipDriveDB = p.softClip.driveDB
        }
    }

    // User 5-band tone control (Sub / Low / Mid / Presence / Air), −12…+12 dB each.
    @Published var tonePresetID: String = TonePresets.flat.id
    @Published var eqGains: [Double] = UserEQ.flat
    var userEQBands: [EQBand] { UserEQ.bands(eqGains) }
    func applyTonePreset(id: String) {
        guard let preset = TonePresets.byID(id) else { return }
        tonePresetID = preset.id
        if preset.id != TonePresets.custom.id {
            eqGains = preset.gains
        }
    }
    func setEQGain(_ index: Int, _ value: Double) {
        guard eqGains.indices.contains(index) else { return }
        eqGains[index] = value
        tonePresetID = TonePresets.custom.id
    }
    func resetEQ() { applyTonePreset(id: TonePresets.flat.id) }

    // A/B audition (in-app playback of original vs master)
    enum AuditionSource { case original, master, translation }
    let playback = PlaybackEngine()
    @Published var isPlaying: Bool = false
    @Published var auditionSource: AuditionSource = .master
    @Published var translationAuditionName: String = "Translation"
    @Published var playhead: Double = 0          // 0…1
    @Published var inputPeaks: [Float] = []
    @Published var masterPeaks: [Float] = []
    private var playTimer: Timer?
    private var translationAuditionSignal: AudioSignal?

    // Equal-loudness ("gain-matched") A/B: attenuate the louder audition path to the quietest
    // source's integrated LUFS so the comparison is TONE, not level. On by default — the honest
    // way to A/B. All offsets are measured (BS.1770), never guessed; see DSP/LoudnessMatch.swift.
    @Published var gainMatchEnabled: Bool = true
    private var translationAuditionLUFS: Double = -.infinity

    /// Measured integrated LUFS of an audition source (reused from the master pass where possible).
    private func auditionLUFS(_ src: AuditionSource) -> Double {
        switch src {
        case .original:    return result?.before.integratedLUFS ?? -.infinity
        case .master:      return result?.after.integratedLUFS ?? -.infinity
        case .translation: return translationAuditionLUFS
        }
    }

    /// The equal-loudness match target across the sources we can currently audition (the quietest).
    private var gainMatchTargetLUFS: Double? {
        guard gainMatchEnabled else { return nil }
        var candidates: [Double] = []
        if let before = result?.before.integratedLUFS { candidates.append(before) }
        if let after = result?.after.integratedLUFS { candidates.append(after) }
        if translationAuditionSignal != nil { candidates.append(translationAuditionLUFS) }
        return LoudnessMatch.targetLUFS(candidates)
    }

    /// Static match gain (dB) applied to `src` at audition — attenuation toward the quietest
    /// source, or 0 dB when matching is off / loudness is undefined. Surfaced in the UI indicator.
    func gainMatchDB(for src: AuditionSource) -> Double {
        guard gainMatchEnabled, let target = gainMatchTargetLUFS else { return 0 }
        return LoudnessMatch.gainDB(sourceLUFS: auditionLUFS(src), targetLUFS: target)
    }

    /// Integrated LUFS of an arbitrary signal (fresh, stateless meter) — used to measure the
    /// device-translation preview so it joins the equal-loudness match set.
    private func measureIntegratedLUFS(_ signal: AudioSignal) -> Double {
        LoudnessMeter(sampleRate: signal.sampleRate > 0 ? signal.sampleRate : 44100,
                      channels: max(1, signal.channelCount)).measure(signal.channels).integratedLUFS
    }

    // Batch
    @Published var isBatch: Bool = false
    @Published var batchDone: Int = 0
    @Published var batchTotal: Int = 0
    @Published var batchFailed: Int = 0
    @Published var lastBatchOutputDir: URL?

    /// Reference audio, decoded once when a reference URL is chosen; fed to the engines for matching.
    private var referenceSignal: AudioSignal?

    // MARK: - Reference-DNA library (SS-24)

    /// Saved reference-DNA profiles (newest first). Ships EMPTY — populated only from
    /// references the buyer imports. Persisted locally via `dnaStore`.
    @Published var dnaProfiles: [DNAProfile] = []
    /// The DNA profile currently armed to re-apply on masters/batches (nil = off).
    @Published var selectedDNAProfileID: UUID?
    private let dnaStore = DNAProfileStore()

    /// The armed profile's DNA, or nil when no profile is selected. Takes precedence over the
    /// live reference file in the mastering chain when set.
    var activeDNA: ReferenceDNA? {
        guard let id = selectedDNAProfileID else { return nil }
        return dnaProfiles.first { $0.id == id }?.dna
    }

    init() {
        dnaProfiles = dnaStore.load()
    }

    /// Running processing task, so a re-run can cancel a stale one.
    private var runTask: Task<Void, Never>?
    /// The detached DSP worker behind `runTask`. Detached tasks don't inherit cancellation,
    /// so cancel() must reach it directly or a cancelled render burns CPU to completion.
    private var engineTask: Task<ProcessOutcome, Never>?

    // MARK: - Logging

    private func note(_ line: String) {
        log.append(line)
        statusLine = line
    }

    // MARK: - Loading

    /// Load a single stereo bounce as the input. Switches mode to master-only.
    func loadInput(_ url: URL) {
        do {
            let sig = try AudioIO.load(url)
            inputSignal = sig
            inputURL = url
            stemURLs = []
            stemControls = [:]
            mode = .masterOnly
            result = nil
            mixResult = nil
            lastExportURL = nil
            masterVariants = []
            stemConflictReport = nil
            translationAuditionSignal = nil
            progress = 0
            stopAudition()
            playhead = 0
            inputPeaks = WaveformView.envelope(sig)
            masterPeaks = []
            studioArea = .master
            note("Loaded input: \(url.lastPathComponent) — \(sig.channelCount)ch @ \(Int(sig.sampleRate)) Hz, \(sig.frameCount) frames.")
            refreshDoctor()
        } catch {
            note("Failed to load input: \(error.localizedDescription)")
        }
    }

    // MARK: - Per-stem controls (role override / gain / mute / solo)

    /// Stem display names in load order — the keys used for per-stem controls and the mix engine.
    /// Matches the name the decode uses (`url.deletingPathExtension().lastPathComponent`).
    var stemDisplayNames: [String] { stemURLs.map { $0.deletingPathExtension().lastPathComponent } }

    /// The role the engine will actually use: the user override, else filename detection.
    func effectiveStemRole(_ name: String) -> MixEngine.StemRole {
        stemControls[name]?.roleOverride ?? MixEngine.StemRole.detect(name)
    }
    /// The role the filename detector infers (shown as the "Auto" default in the picker).
    func detectedStemRole(_ name: String) -> MixEngine.StemRole { MixEngine.StemRole.detect(name) }

    func stemControl(_ name: String) -> MixEngine.StemControl { stemControls[name] ?? .neutral }
    func setStemRoleOverride(_ name: String, _ role: MixEngine.StemRole?) {
        var c = stemControl(name); c.roleOverride = role; stemControls[name] = c
    }
    func setStemGainTrim(_ name: String, _ dB: Double) {
        var c = stemControl(name); c.gainTrimDB = dB; stemControls[name] = c
    }
    func toggleStemMute(_ name: String) {
        var c = stemControl(name); c.muted.toggle(); stemControls[name] = c
    }
    func toggleStemSolo(_ name: String) {
        var c = stemControl(name); c.soloed.toggle(); stemControls[name] = c
    }

    /// Register a set of stems for mix+master. Decoding of the stems is deferred to the mix engine.
    func loadStems(_ urls: [URL]) {
        guard !urls.isEmpty else {
            note("No stems selected.")
            return
        }
        stemURLs = urls
        // Seed controls for the new stem set — preserve any control for a same-named stem,
        // neutral otherwise; drop controls for stems no longer loaded. Dup names collapse safely.
        var seeded: [String: MixEngine.StemControl] = [:]
        for u in urls {
            let k = u.deletingPathExtension().lastPathComponent
            seeded[k] = stemControls[k] ?? .neutral
        }
        stemControls = seeded
        inputSignal = nil
        inputURL = nil
        mode = .mixOnly
        result = nil
        mixResult = nil
        lastExportURL = nil
        doctorReport = nil
        masterVariants = []
        stemConflictReport = nil
        translationAuditionSignal = nil
        progress = 0
        studioArea = .mix
        note("Loaded \(urls.count) stem\(urls.count == 1 ? "" : "s") for mixing.")
        refreshStemConflicts()
    }

    /// Clear the selected stereo mix or stem session and all derived render state.
    func clearInputSource() {
        runTask?.cancel()
        engineTask?.cancel()
        stopAudition()
        inputSignal = nil
        inputURL = nil
        stemURLs = []
        stemControls = [:]
        mode = studioArea == .mix ? .mixOnly : .masterOnly
        isProcessing = false
        isAnalyzingStems = false
        progress = 0
        result = nil
        mixResult = nil
        lastExportURL = nil
        doctorReport = nil
        masterVariants = []
        stemConflictReport = nil
        translationAuditionSignal = nil
        translationAuditionLUFS = -.infinity
        inputPeaks = []
        masterPeaks = []
        playhead = 0
        note("Cleared source audio.")
    }

    /// Load a reference master to match against (tonal balance, loudness feel).
    func loadReference(_ url: URL) {
        do {
            referenceSignal = try AudioIO.load(url)
            referenceURL = url
            note("Loaded reference: \(url.lastPathComponent).")
            refreshDoctor()
        } catch {
            referenceSignal = nil
            referenceURL = nil
            note("Failed to load reference: \(error.localizedDescription)")
        }
    }

    /// Remove the exact reference file from future masters.
    func clearReferenceFile() {
        referenceSignal = nil
        referenceURL = nil
        refreshDoctor()
        note("Cleared exact reference file.")
    }

    /// Remove the link/manual style reference from the session.
    func clearReferenceLink() {
        referenceLink = ""
        linkReference = nil
        linkError = nil
        isResolvingLink = false
        refreshDoctor()
        note("Cleared style reference.")
    }

    // MARK: - Reference-DNA library (SS-24)

    /// Capture the currently-loaded reference file's DNA and save it as a named profile.
    /// Requires a loaded reference (no reference → nothing to capture; H1: buyer-imported only).
    func saveReferenceDNA(named rawName: String) {
        guard let ref = referenceSignal, ref.frameCount > 0 else {
            note("Load a reference file first — DNA is captured from your imported reference.")
            return
        }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty
            ? (referenceURL?.deletingPathExtension().lastPathComponent ?? "Reference DNA")
            : name
        let dna = ReferenceMatcher.captureDNA(ref) { [weak self] sig in
            self?.freshLoudness(sig) ?? LoudnessMeter(sampleRate: sig.sampleRate > 0 ? sig.sampleRate : 44100,
                                                      channels: max(1, sig.channelCount)).measure(sig.channels)
        }
        let profile = DNAProfile(name: finalName, dna: dna)
        dnaProfiles.insert(profile, at: 0)
        selectedDNAProfileID = profile.id
        persistDNAProfiles()
        note("Saved reference DNA “\(finalName)” — armed for masters and batches.")
        refreshDoctor()
    }

    /// Rename a saved DNA profile.
    func renameDNAProfile(_ id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let idx = dnaProfiles.firstIndex(where: { $0.id == id }) else { return }
        dnaProfiles[idx].name = name
        persistDNAProfiles()
        note("Renamed DNA profile to “\(name)”.")
    }

    /// Delete a saved DNA profile; disarm it if it was selected.
    func deleteDNAProfile(_ id: UUID) {
        guard let idx = dnaProfiles.firstIndex(where: { $0.id == id }) else { return }
        let removed = dnaProfiles.remove(at: idx)
        if selectedDNAProfileID == id { selectedDNAProfileID = nil }
        persistDNAProfiles()
        note("Deleted DNA profile “\(removed.name)”.")
        refreshDoctor()
    }

    /// Arm (or disarm, with nil) a saved DNA profile for the next master/batch.
    func selectDNAProfile(_ id: UUID?) {
        selectedDNAProfileID = id
        if let id = id, let p = dnaProfiles.first(where: { $0.id == id }) {
            note("Armed reference DNA “\(p.name)”.")
        } else {
            note("Reference DNA off — using the loaded reference or genre target.")
        }
        refreshDoctor()
    }

    private func freshLoudness(_ sig: AudioSignal) -> LoudnessResult {
        LoudnessMeter(sampleRate: sig.sampleRate > 0 ? sig.sampleRate : 44100,
                      channels: max(1, sig.channelCount)).measure(sig.channels)
    }

    private func persistDNAProfiles() {
        do { try dnaStore.save(dnaProfiles) }
        catch { note("Could not save the DNA library: \(error.localizedDescription)") }
    }

    // MARK: - Reference by link

    private func applyLinkReference(_ ref: LinkReference) {
        linkReference = ref
        mixStyle = ref.inferredStyle
        selectedGenre = ref.inferredStyle.genre
        intensity = ref.inferredStyle.intensity
        refreshDoctor()
    }

    /// Resolve a streaming link's public metadata and synthesize the matching style target.
    func resolveReferenceLink() {
        let link = referenceLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        if LinkResolver.oEmbed(for: link) == nil {
            let ref = LinkResolver.manual(link)
            applyLinkReference(ref)
            linkError = nil
            note("Applied manual reference: \(ref.summary) → \(ref.inferredStyle.name).")
            return
        }
        isResolvingLink = true; linkError = nil
        note("Understanding link…")
        Task { [weak self] in
            do {
                let ref = try await LinkResolver.resolve(link)
                await MainActor.run {
                    guard let self else { return }
                    self.applyLinkReference(ref)
                    self.isResolvingLink = false
                    self.note("Understood \(ref.source): \(ref.summary) → \(ref.inferredStyle.name).")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isResolvingLink = false
                    self.linkError = error.localizedDescription
                    self.note("Link: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Run

    /// Kick off processing on a background task. Progress/status/result are published on the main actor.
    func run() {
        guard !isProcessing else { return }

        switch mode {
        case .masterOnly:
            guard inputSignal != nil else { note("Load a stereo mix first."); return }
        case .mixOnly:
            guard !stemURLs.isEmpty else { note("Load stems first."); return }
        }

        // Snapshot everything the engines need so the detached task touches no @Published state.
        let genre = selectedGenre
        let platform = selectedPlatform
        let reference = referenceSignal
        let dna = activeDNA
        let mixInput = inputSignal
        let stems = stemURLs
        let runMode = mode
        let runIntensity = intensity
        let profile = loudnessProfile
        let override = profile.targetLUFS ?? loudnessOverride   // a profile target wins over the manual LUFS
        let clip = softClipSettings
        let ceilingOverride = profile.truePeakDBTP
        let style = mixStyle
        let userEQ = userEQBands
        let controls = stemControls
        let session = mixSession
        let chain = masterChain
        stopAudition()

        isProcessing = true
        progress = 0
        if runMode == .masterOnly { result = nil }
        if runMode == .mixOnly { mixResult = nil }
        lastExportURL = nil
        masterVariants = []
        translationAuditionSignal = nil
        note("Processing (\(runMode.label))…")

        runTask?.cancel()
        engineTask?.cancel()
        runTask = Task { [weak self] in
            // Progress callback hops back to the main actor to update the UI.
            let onProgress: @Sendable (Double, String) -> Void = { [weak self] p, s in
                Task { @MainActor in
                    guard let self, self.isProcessing else { return }
                    self.progress = min(max(p, 0), 1)
                    self.note(s)
                }
            }

            let worker = Task.detached(priority: .userInitiated) { () -> ProcessOutcome in
                switch runMode {
                case .masterOnly:
                    guard let mixInput else {
                        return ProcessOutcome(result: nil, mixResult: nil,
                                              error: "Load a stereo mix first.")
                    }
                    // Phase-2 manual MASTER chain: applied to the bounce BEFORE the guided
                    // engine pass. Neutral = bit-transparent, so the default sound is unchanged.
                    let sr = mixInput.sampleRate > 0 ? mixInput.sampleRate : 44_100
                    let manual = chain.apply(to: mixInput, sampleRate: sr)
                    var result = MasteringEngine.master(
                        input: manual.signal,
                        reference: reference,
                        genre: genre,
                        platform: platform,
                        intensity: runIntensity,
                        loudnessOverrideLUFS: override,
                        userEQ: userEQ,
                        softClip: clip,
                        ceilingOverrideDBTP: ceilingOverride,
                        dna: dna,
                        progress: onProgress
                    )
                    if !manual.notes.isEmpty {
                        result.notes.insert(contentsOf: manual.notes, at: 0)
                    }
                    return ProcessOutcome(result: result, mixResult: nil, error: nil)
                case .mixOnly:
                    // Decode stem files to signals off the main actor (contract: MixEngine takes decoded stems).
                    var decodedStems: [(name: String, signal: AudioSignal)] = []
                    var failedNames: [String] = []
                    for url in stems {
                        do {
                            let sig = try AudioIO.load(url)
                            decodedStems.append((name: url.deletingPathExtension().lastPathComponent, signal: sig))
                        } catch {
                            failedNames.append(url.lastPathComponent)
                        }
                    }
                    guard !decodedStems.isEmpty else {
                        return ProcessOutcome(result: nil, mixResult: nil,
                                              error: "No readable stems. Check the selected files and try again.")
                    }
                    var mixed = MixEngine.mix(
                        stems: decodedStems,
                        styleName: style.name,
                        options: style.options,
                        controls: controls,
                        session: session,
                        progress: onProgress
                    )
                    if !failedNames.isEmpty {
                        mixed.notes.insert("Skipped \(failedNames.count) unreadable stem\(failedNames.count == 1 ? "" : "s"): \(failedNames.joined(separator: ", ")).", at: 0)
                    }
                    return ProcessOutcome(result: nil, mixResult: mixed, error: nil)
                }
            }
            // Detached tasks don't inherit cancellation — track the worker so cancel()
            // reaches the engine (it bails at its next stage boundary).
            self?.engineTask = worker
            if Task.isCancelled { worker.cancel() }   // cancel() can land before this line runs
            let produced: ProcessOutcome = await worker.value

            await MainActor.run { [weak self] in
                guard let self else { return }
                // A cancelled run must not touch live state: cancel() already reported it,
                // and a newer run may be in flight (cancel → immediate re-run).
                if Task.isCancelled { return }
                self.engineTask = nil
                self.isProcessing = false
                if let result = produced.result {
                    self.result = result
                    self.progress = 1
                    self.masterPeaks = WaveformView.envelope(result.output)
                    self.auditionSource = .master
                    self.playhead = 0
                    self.note(String(format: "Done. %@ master — %.1f LUFS, %.1f dBTP.",
                                     self.intensity.label, result.after.integratedLUFS, result.after.truePeakDBTP))
                    self.refreshDoctor()
                } else if let mixed = produced.mixResult {
                    self.mixResult = mixed
                    self.progress = 1
                    self.masterPeaks = WaveformView.envelope(mixed.output)
                    self.auditionSource = .master
                    self.playhead = 0
                    self.note("Mix ready — stereo bounce at \(Int(mixed.output.sampleRate)) Hz. Mastering has not been applied.")
                } else {
                    self.progress = 0
                    self.note("Processing failed — \(produced.error ?? "no result produced").")
                }
            }
        }
    }

    /// Cancel an in-flight run.
    func cancel() {
        runTask?.cancel()
        engineTask?.cancel()
        stopAudition()
        isProcessing = false
        progress = 0
        note("Cancelled.")
    }

    // MARK: - Export

    /// Write the finished master to disk in the chosen container/bit-depth/sample-rate with tags.
    /// No-op with a status note if nothing has been produced yet.
    func export(to url: URL) {
        guard let result else {
            note("Nothing to export — run a master first.")
            return
        }
        let settings = exportSettings
        do {
            try AudioIO.export(result.output, to: url, settings: settings)
            lastExportURL = url
            let srNote = settings.sampleRate.map { " @ \(Int($0/1000))k" } ?? ""
            note("Exported: \(url.lastPathComponent) — \(exportFormat.displayName)\(srNote).")
        } catch {
            note("Export failed: \(error.localizedDescription)")
        }
    }

    /// Write the finished mix bounce without running any mastering stages.
    func exportMix(to url: URL) {
        guard let mixed = mixResult else {
            note("Nothing to export — create a mix first.")
            return
        }
        let title = stemURLs.first?.deletingPathExtension().lastPathComponent ?? "Sunset mix"
        let isrc = exportISRC.trimmingCharacters(in: .whitespacesAndNewlines)
        let settings = ExportSettings(
            format: exportFormat,
            bitDepth: exportBitDepth,
            sampleRate: exportSampleRate > 0 ? Double(exportSampleRate) : nil,
            metadata: AudioMetadata(title: title, artist: nil, album: "Sunset mix",
                                    isrc: isrc.isEmpty ? nil : isrc)
        )
        do {
            try AudioIO.export(mixed.output, to: url, settings: settings)
            lastExportURL = url
            note("Exported mix: \(url.lastPathComponent). Mastering was not applied.")
        } catch {
            note("Mix export failed: \(error.localizedDescription)")
        }
    }

    /// Use the rendered mix as mastering input. This is an explicit handoff between two
    /// independent jobs; no mastering runs until the user starts the MASTER workflow.
    func sendMixToMastering() {
        guard let mixed = mixResult else {
            note("Create a mix before sending it to mastering.")
            return
        }
        stopAudition()
        inputSignal = mixed.output
        inputURL = nil
        mode = .masterOnly
        studioArea = .master
        result = nil
        doctorReport = nil
        masterVariants = []
        translationAuditionSignal = nil
        inputPeaks = WaveformView.envelope(mixed.output)
        masterPeaks = []
        auditionSource = .original
        playhead = 0
        progress = 0
        note("Mix handed to MASTER. Choose mastering settings, then create the master separately.")
    }

    /// Export the SS-16 report card as plain text.
    func exportReportCard(to url: URL) {
        guard let card = reportCard else { note("No report card yet — master a track first."); return }
        do {
            try card.text.write(to: url, atomically: true, encoding: .utf8)
            note("Exported report card: \(url.lastPathComponent).")
        } catch {
            note("Report card export failed: \(error.localizedDescription)")
        }
    }

    /// SS-21: export the unified Explainable-Master Proof (report card + A/B + delta + PSR) as text.
    func exportMasterProof(to url: URL) {
        guard let proof = masterProof else { note("No proof yet — master a track first."); return }
        do {
            try proof.text.write(to: url, atomically: true, encoding: .utf8)
            note("Exported proof: \(url.lastPathComponent).")
        } catch {
            note("Proof export failed: \(error.localizedDescription)")
        }
    }

    /// SS-20: one-click per-platform delivery pack. Re-normalizes the finished master to every
    /// PlatformTarget's LUFS + true-peak ceiling and writes one labeled file per platform into a
    /// `DeliveryPack` subfolder. Offline + faster than real time; each file carries a measured summary.
    func exportDeliveryPack(to baseDir: URL) {
        guard let master = result?.output else {
            note("Master a track first to build a delivery pack."); return
        }
        let track = inputURL?.deletingPathExtension().lastPathComponent ?? "Sunset master"
        let fmt = exportFormat
        let bits = exportBitDepth
        let isrc = exportISRC.trimmingCharacters(in: .whitespaces)
        let platforms = PlatformTargets.all
        let packDir = baseDir.appendingPathComponent("DeliveryPack", isDirectory: true)

        isDeliveryPack = true
        deliveryPackSummaries = []
        lastDeliveryPackDir = packDir
        note("Delivery pack: rendering \(platforms.count) platform masters…")

        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> (summaries: [String], failed: Int) in
                do {
                    try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
                } catch {
                    return (["Could not create DeliveryPack folder: \(error.localizedDescription)"], platforms.count)
                }
                var summaries: [String] = []
                var failed = 0
                for p in platforms {
                    let render = DeliveryPack.normalize(master, to: p)
                    let safeName = p.name.replacingOccurrences(of: "/", with: "-")
                    let url = packDir.appendingPathComponent("\(track) — \(safeName).\(fmt.fileExtension)")
                    let settings = ExportSettings(
                        format: fmt, bitDepth: bits, sampleRate: nil,
                        metadata: AudioMetadata(title: track, artist: nil,
                                                album: "Sunset — \(p.name)",
                                                isrc: isrc.isEmpty ? nil : isrc))
                    do {
                        try AudioIO.export(render.signal, to: url, settings: settings)
                        summaries.append(render.target.summary)
                    } catch {
                        failed += 1
                        summaries.append("\(p.name): export failed — \(error.localizedDescription)")
                    }
                }
                return (summaries, failed)
            }.value

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isDeliveryPack = false
                self.deliveryPackSummaries = outcome.summaries
                for s in outcome.summaries { self.note(s) }
                let written = platforms.count - outcome.failed
                self.note("Delivery pack complete — \(written)/\(platforms.count) written to \(packDir.lastPathComponent)/.")
            }
        }
    }

    func revealDeliveryPack() {
        guard let lastDeliveryPackDir else { return }
        NSWorkspace.shared.open(lastDeliveryPackDir)
    }

    /// SS-18 "Hear What Changed": audition the aligned, loudness-matched residual (what the chain
    /// added or removed). Reuses the translation playback slot so the A/B picker can flip to it.
    func auditionDelta() {
        guard let out = result?.output, let input = inputSignal else {
            note("Master a stereo mix first to hear what changed.")
            return
        }
        stopAudition()
        let res = DeltaAudition.residual(original: input, master: out)
        guard res.hasData, res.signal.frameCount > 0 else {
            note("No audible delta — the master matches the original.")
            return
        }
        deltaAuditionSignal = res.signal
        translationAuditionSignal = res.signal
        translationAuditionLUFS = measureIntegratedLUFS(res.signal)
        translationAuditionName = "What changed"
        auditionSource = .translation
        playhead = 0
        note(String(format: "Hearing what changed — residual %.1f dBFS RMS, aligned %+d samples, %+.1f dB loudness-matched.",
                    res.residualRMSDBFS, res.lagSamples, res.matchGainDB))
        startAudition(from: 0)
    }

    func revealLastExport() {
        guard let lastExportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastExportURL])
    }

    // MARK: - Doctor / proof

    func refreshDoctor() {
        let base = inputSignal ?? result?.output
        guard let base else {
            doctorReport = nil
            return
        }
        let name = inputURL?.lastPathComponent ?? "Sunset master"
        doctorReport = AudioDoctor.analyze(signal: base, reference: referenceSignal,
                                           master: result, platform: selectedPlatform, label: name,
                                           stemConflicts: stemConflictReport)
    }

    func refreshStemConflicts() {
        guard !stemURLs.isEmpty else {
            stemConflictReport = nil
            return
        }
        let urls = stemURLs
        isAnalyzingStems = true
        note("Analyzing stem conflicts…")
        Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> (StemConflictReport?, [String]) in
                var decoded: [(name: String, signal: AudioSignal)] = []
                var failed: [String] = []
                for url in urls {
                    do {
                        decoded.append((name: url.deletingPathExtension().lastPathComponent,
                                        signal: try AudioIO.load(url)))
                    } catch {
                        failed.append(url.lastPathComponent)
                    }
                }
                guard !decoded.isEmpty else { return (nil, failed) }
                return (AudioDoctor.analyzeStems(decoded), failed)
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.stemURLs == urls else { return }
                self.isAnalyzingStems = false
                self.stemConflictReport = outcome.0
                self.refreshDoctor()
                if let report = outcome.0 {
                    let skipped = outcome.1.isEmpty ? "" : " Skipped \(outcome.1.count) unreadable."
                    self.note("Stem conflict map ready — \(report.summary)\(skipped)")
                } else {
                    self.note("Stem conflict map failed — no readable stems.")
                }
            }
        }
    }

    func renderMasterMatrix() {
        guard !isRenderingMatrix else { return }
        guard let inputSignal else {
            note("Load a stereo mix before rendering a master matrix.")
            return
        }
        let reference = referenceSignal
        let genre = selectedGenre
        let platform = selectedPlatform
        let userEQ = userEQBands
        stopAudition()
        isRenderingMatrix = true
        progress = 0
        note("Rendering master matrix…")

        Task { [weak self] in
            let onProgress: @Sendable (Double, String) -> Void = { [weak self] p, s in
                Task { @MainActor in
                    guard let self, self.isRenderingMatrix else { return }
                    self.progress = min(max(p, 0), 1)
                    self.note(s)
                }
            }
            let variants = await Task.detached(priority: .userInitiated) {
                AudioDoctor.renderMatrix(input: inputSignal, reference: reference, genre: genre,
                                         platform: platform, userEQ: userEQ, progress: onProgress)
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.masterVariants = variants
                self.isRenderingMatrix = false
                self.progress = 1
                self.note("Master matrix ready — \(variants.count) versions.")
            }
        }
    }

    func applyVariant(_ variant: MasterVariant) {
        stopAudition()
        result = variant.result
        lastExportURL = nil
        masterPeaks = WaveformView.envelope(variant.result.output)
        auditionSource = .master
        playhead = 0
        refreshDoctor()
        note(String(format: "Applied %@ — %.1f LUFS, %.1f dBTP.",
                   variant.name, variant.lufs, variant.truePeak))
    }

    func auditionVariant(_ variant: MasterVariant) {
        applyVariant(variant)
        startAudition(from: 0)
    }

    func exportProof(to url: URL) {
        refreshDoctor()
        guard let report = doctorReport else {
            note("No proof report yet — load or master a track first.")
            return
        }
        do {
            try report.proofText.write(to: url, atomically: true, encoding: .utf8)
            note("Exported proof: \(url.lastPathComponent).")
        } catch {
            note("Proof export failed: \(error.localizedDescription)")
        }
    }

    func exportReleaseBundle(to wavURL: URL) {
        guard let result else {
            note("Nothing to export — run a master first.")
            return
        }
        refreshDoctor()
        guard let report = doctorReport else {
            note("No proof report yet — run analysis first.")
            return
        }
        let base = wavURL.deletingPathExtension()
        let txtURL = base.appendingPathExtension("txt")
        let jsonURL = base.appendingPathExtension("json")
        do {
            try AudioIO.write(result.output, to: wavURL, bitDepth: 24)
            try report.proofText.write(to: txtURL, atomically: true, encoding: .utf8)
            try report.proofJSON.write(to: jsonURL, atomically: true, encoding: .utf8)
            lastExportURL = wavURL
            note("Exported release bundle: \(wavURL.lastPathComponent), \(txtURL.lastPathComponent), \(jsonURL.lastPathComponent).")
        } catch {
            note("Release bundle export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - A/B audition

    /// Play/pause the currently-selected source (original or master).
    func toggleAudition() {
        if isPlaying { stopAudition() } else { startAudition(from: playhead) }
    }

    /// Switch which source plays, keeping the playhead — the instant A/B.
    func setAudition(_ src: AuditionSource) {
        guard src != auditionSource else { return }
        let wasPlaying = isPlaying
        let at = isPlaying ? playback.fraction : playhead
        auditionSource = src
        if wasPlaying { startAudition(from: at) }
    }

    private func currentAuditionSignal() -> AudioSignal? {
        switch auditionSource {
        case .original: return inputSignal
        // The areas never blur: MIX auditions only the mix bounce (its transport is labeled
        // MIX BOUNCE), MASTER prefers the mastered render. No cross-area fallback in MIX —
        // playing the master there would contradict the label.
        case .master:   return studioArea == .mix ? mixResult?.output
                                                  : (result?.output ?? mixResult?.output)
        case .translation: return translationAuditionSignal
        }
    }

    /// The signal the transport will actually play right now — the UI time label reads this
    /// so the displayed duration always matches the audible audio.
    var auditionSignal: AudioSignal? { currentAuditionSignal() }

    func auditionTranslation(_ preview: TranslationPreview) {
        guard let source = result?.output ?? mixResult?.output ?? inputSignal else {
            note("Load or master a track before translation audition.")
            return
        }
        stopAudition()
        let translated = AudioDoctor.renderTranslation(signal: source, profileID: preview.profileID)
        translationAuditionSignal = translated
        translationAuditionLUFS = measureIntegratedLUFS(translated)   // joins the equal-loudness match set
        translationAuditionName = preview.device
        auditionSource = .translation
        playhead = 0
        note("Auditioning \(preview.device) translation.")
        startAudition(from: 0)
    }

    private func startAudition(from frac: Double) {
        guard let sig = currentAuditionSignal() else { note("Nothing to play yet."); return }
        // Equal-loudness match: attenuate this source to the quietest audition path (0 dB if off).
        let matchGain = Float(pow(10.0, gainMatchDB(for: auditionSource) / 20.0))
        playback.play(sig, fromFraction: frac, gain: matchGain) { [weak self] in
            Task { @MainActor in self?.stopAudition() }
        }
        isPlaying = true
        playTimer?.invalidate()
        playTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.playhead = self.playback.fraction
            }
        }
    }

    func stopAudition() {
        playback.stop()
        isPlaying = false
        playTimer?.invalidate(); playTimer = nil
    }

    /// Scrub to a position (0…1). If playing, resume from there — otherwise just move the head.
    func seek(to fraction: Double) {
        let f = min(max(fraction, 0), 1)
        playhead = f
        if isPlaying { startAudition(from: f) }
    }

    // MARK: - Batch

    /// Master every file in `urls` with the current targets/intensity, writing to `outputDir`.
    func batchMaster(_ urls: [URL], outputDir: URL) {
        guard !urls.isEmpty else { note("No files selected for batch."); return }
        let genre = selectedGenre, platform = selectedPlatform
        let profile = loudnessProfile
        let runIntensity = intensity, override = profile.targetLUFS ?? loudnessOverride, reference = referenceSignal
        let clip = softClipSettings, ceilingOverride = profile.truePeakDBTP
        let dna = activeDNA
        isBatch = true; batchTotal = urls.count; batchDone = 0; batchFailed = 0
        lastBatchOutputDir = outputDir
        note("Batch: mastering \(urls.count) file\(urls.count == 1 ? "" : "s")…")
        Task { [weak self] in
            for (i, url) in urls.enumerated() {
                let outURL = outputDir.appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent + " — Sunset.wav")
                let failure: String? = await Task.detached(priority: .userInitiated) {
                    do {
                        let sig = try AudioIO.load(url)
                        let r = MasteringEngine.master(input: sig, reference: reference, genre: genre,
                                                       platform: platform, intensity: runIntensity,
                                                       loudnessOverrideLUFS: override, softClip: clip,
                                                       ceilingOverrideDBTP: ceilingOverride, dna: dna, progress: nil)
                        try AudioIO.write(r.output, to: outURL, bitDepth: 24)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }.value
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.batchDone = i + 1
                    if let failure {
                        self.batchFailed += 1
                        self.note("Batch \(i + 1)/\(urls.count) failed: \(url.lastPathComponent) — \(failure)")
                    } else {
                        self.note("Batch \(i + 1)/\(urls.count): \(url.lastPathComponent)")
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isBatch = false
                let written = urls.count - self.batchFailed
                self.note("Batch complete — \(written) written, \(self.batchFailed) failed.")
            }
        }
    }

    func revealLastBatchFolder() {
        guard let lastBatchOutputDir else { return }
        NSWorkspace.shared.open(lastBatchOutputDir)
    }

    // MARK: - Phase 2: session save / load (versioned, old documents load unchanged)

    /// Current session as a versioned document: per-stem controls + strips, buses, sends,
    /// master chain, and the guided-layer master settings.
    var sessionDocument: SessionDocument {
        var doc = SessionDocument()
        doc.stemControls = stemControls
        doc.session = mixSession
        doc.masterChain = masterChain
        doc.eqGains = eqGains
        doc.softClipEnabled = softClipEnabled
        doc.softClipDriveDB = softClipDriveDB
        doc.loudnessProfileID = loudnessProfileID
        return doc
    }

    /// Save the session settings document as JSON (no audio is ever stored).
    func saveSession(to url: URL) {
        do {
            try sessionDocument.encoded().write(to: url, options: .atomic)
            note("Saved session settings: \(url.lastPathComponent).")
        } catch {
            note("Session save failed: \(error.localizedDescription)")
        }
    }

    /// Load a session settings document. Old / pre-Phase-2 documents decode with every new
    /// field at its bypassed default, so they load unchanged and sound identical.
    func loadSession(from url: URL) {
        do {
            let doc = try SessionDocument.decoded(try Data(contentsOf: url))
            // Keep controls only for stems that are actually loaded (plus keep the rest
            // dormant if no stems are loaded yet — they attach when names match).
            stemControls = doc.stemControls
            mixSession = doc.session
            masterChain = doc.masterChain
            if doc.eqGains.count == UserEQ.count { eqGains = doc.eqGains; tonePresetID = TonePresets.custom.id }
            softClipEnabled = doc.softClipEnabled
            softClipDriveDB = doc.softClipDriveDB
            loudnessProfileID = doc.loudnessProfileID
            note("Loaded session settings (v\(doc.version)): \(url.lastPathComponent).")
        } catch {
            note("Session load failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Phase 2: master-chain stage A/B

    /// Re-render the master with ONE manual-chain stage bypassed and put it on the
    /// Translation audition slot — flip the A/B picker to hear the stage's contribution
    /// (gain-matched like every audition). Master-only mode; the mix path A/Bs per stem
    /// via mute/solo and the existing gain-matched Original/Master picker.
    func auditionMasterStageBypass(_ stage: MasterChainStage) {
        guard mode == .masterOnly, let input = inputSignal else {
            note("Stage A/B needs a loaded stereo mix in MASTER.")
            return
        }
        guard masterChain.isStageActive(stage) else {
            note("\(stage.rawValue) is bypassed — nothing to A/B.")
            return
        }
        let chainWithout = masterChain.disabling(stage)
        let genre = selectedGenre, platform = selectedPlatform
        let runIntensity = intensity
        let profile = loudnessProfile
        let override = profile.targetLUFS ?? loudnessOverride
        let clip = softClipSettings
        let ceilingOverride = profile.truePeakDBTP
        let userEQ = userEQBands
        let reference = referenceSignal
        let dna = activeDNA
        stopAudition()
        note("Rendering A/B without \(stage.rawValue)…")
        Task { [weak self] in
            let rendered: AudioSignal = await Task.detached(priority: .userInitiated) {
                let sr = input.sampleRate > 0 ? input.sampleRate : 44_100
                let manual = chainWithout.apply(to: input, sampleRate: sr)
                return MasteringEngine.master(input: manual.signal, reference: reference,
                                              genre: genre, platform: platform,
                                              intensity: runIntensity,
                                              loudnessOverrideLUFS: override,
                                              userEQ: userEQ, softClip: clip,
                                              ceilingOverrideDBTP: ceilingOverride,
                                              dna: dna, progress: nil).output
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.translationAuditionSignal = rendered
                self.translationAuditionLUFS = self.measureIntegratedLUFS(rendered)
                self.translationAuditionName = "No \(stage.rawValue)"
                self.auditionSource = .translation
                self.playhead = 0
                self.note("A/B ready — Translation slot plays the master WITHOUT \(stage.rawValue) (gain-matched).")
                self.startAudition(from: 0)
            }
        }
    }

    // MARK: - Phase 4: per-strip stage A/B

    /// Re-render the stems mix with ONE strip stage bypassed on ONE stem and put it on the
    /// Translation audition slot — the strip-side sibling of `auditionMasterStageBypass`.
    /// Explicit on-demand action: the user taps A/B, we render exactly once (no continuous
    /// re-rendering); the audition slot gain-matches like every A/B.
    func auditionStripStageBypass(_ stemName: String, _ stage: StripStage) {
        guard mode == .mixOnly, !stemURLs.isEmpty else {
            note("Strip stage A/B needs loaded stems in MIX.")
            return
        }
        guard !isProcessing else {
            note("Wait for the current render to finish before an A/B render.")
            return
        }
        let currentStrip = stemStrip(stemName)
        guard currentStrip.isStageActive(stage) else {
            note("\(stage.label) is bypassed on \(stemName) — nothing to A/B.")
            return
        }
        var controls = stemControls
        var control = controls[stemName] ?? MixEngine.StemControl()
        control.strip = currentStrip.disabling(stage)
        controls[stemName] = control

        // Snapshot everything the engine needs (same set as run()'s stems path).
        let stems = stemURLs
        let style = mixStyle
        let session = mixSession
        stopAudition()
        note("Rendering A/B without \(stage.label) on \(stemName)…")
        Task { [weak self] in
            let rendered: AudioSignal? = await Task.detached(priority: .userInitiated) {
                var decodedStems: [(name: String, signal: AudioSignal)] = []
                for url in stems {
                    if let sig = try? AudioIO.load(url) {
                        decodedStems.append((name: url.deletingPathExtension().lastPathComponent, signal: sig))
                    }
                }
                guard !decodedStems.isEmpty else { return nil }
                return MixEngine.mix(stems: decodedStems, styleName: style.name,
                                     options: style.options, controls: controls,
                                     session: session, progress: nil).output
            }.value
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let rendered else {
                    self.note("A/B render failed — no readable stems.")
                    return
                }
                self.translationAuditionSignal = rendered
                self.translationAuditionLUFS = self.measureIntegratedLUFS(rendered)
                self.translationAuditionName = "No \(stage.label) — \(stemName)"
                self.auditionSource = .translation
                self.playhead = 0
                self.note("A/B ready — Translation slot plays the mix WITHOUT \(stage.label) on \(stemName) (gain-matched).")
                self.startAudition(from: 0)
            }
        }
    }
}
#endif // circuit-convert
