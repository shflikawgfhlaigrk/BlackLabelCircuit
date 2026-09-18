#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// ContentView: the Sunset main window — import/targets on the left, spectrum/meters/chain/export on the right.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false

    var body: some View {
        HStack(spacing: 0) {
            leftColumn
                .frame(width: 360)
                .background(Color(red: 0.051, green: 0.051, blue: 0.059))
                .overlay(Rectangle().frame(width: 1).foregroundColor(Palette.stroke), alignment: .trailing)
            rightColumn
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
        .foregroundColor(.white)
    }

    // MARK: - Left: import + targets + run

    private var leftColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                Card(title: "Input", subtitle: state.mode == .mixOnly ? "Mix stems to a stereo bounce" : "Master a stereo bounce") {
                    VStack(alignment: .leading, spacing: 10) {
                        dropZone
                        HStack(spacing: 8) {
                            GoldButton(title: "Choose mix…") { chooseMix() }
                            GhostButton(title: "Choose stems…") { chooseStems() }
                        }
                        if let url = state.inputURL {
                            inputLabel(icon: "waveform", text: url.lastPathComponent, removeHelp: "Remove stereo mix") {
                                state.clearInputSource()
                            }
                        } else if !state.stemURLs.isEmpty {
                            inputLabel(icon: "square.stack.3d.up", text: "\(state.stemURLs.count) stems loaded", removeHelp: "Remove stems") {
                                state.clearInputSource()
                            }
                        }
                    }
                }

                Card(title: "Reference", subtitle: "Match a reference track (optional)") {
                    VStack(alignment: .leading, spacing: 8) {
                        GhostButton(title: state.referenceURL == nil ? "Match a reference track…" : "Change reference…") {
                            chooseReference()
                        }
                        if let ref = state.referenceURL {
                            inputLabel(icon: "target", text: ref.lastPathComponent, removeHelp: "Remove reference") {
                                state.clearReferenceFile()
                            }
                        } else {
                            Text("No reference — the genre target below drives the master.")
                                .font(.system(size: 10)).foregroundColor(Palette.dim)
                        }
                    }
                }

                Card(title: "Targets", subtitle: "Tonal profile + delivery loudness") {
                    VStack(alignment: .leading, spacing: 12) {
                        labeledPicker("Genre", selection: genreBinding, options: GenreTargets.all.map { ($0.id, $0.name) })
                        labeledPicker("Platform", selection: platformBinding, options: PlatformTargets.all.map { ($0.id, $0.name) })
                        Text(state.selectedPlatform.note).font(.system(size: 10)).foregroundColor(Palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if state.mode == .mixOnly { mixStyleCard } else { characterCard }

                eqCard

                runSection
            }
            .padding(18)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let ns = bundleLogo() {
                Image(nsImage: ns).resizable().scaledToFill().frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.goldDk, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 0) {
                Text("Sunset").font(.system(size: 17, weight: .bold)).foregroundColor(Palette.gold)
                Text("Separate mixing and mastering").font(.system(size: 10)).foregroundColor(Palette.dim)
            }
        }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 11)
            .fill(dropTargeted ? Palette.goldInk : Palette.ink)
            .frame(height: 90)
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(style: StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                .foregroundColor(dropTargeted ? Palette.gold : Palette.stroke))
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 18)).foregroundColor(Palette.gold)
                    Text("Drop your FL Studio bounce or stems to begin")
                        .font(.system(size: 11)).foregroundColor(Palette.dim)
                        .multilineTextAlignment(.center)
                }.padding(8)
            )
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                handleDrop(providers); return true
            }
    }

    private func inputLabel(icon: String, text: String, removeHelp: String? = nil, removeAction: (() -> Void)? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(Palette.gold)
            Text(text).font(.system(size: 11)).foregroundColor(Palette.goldTxt).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let removeAction {
                Button(action: removeAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Palette.dim)
                }
                .buttonStyle(.plain)
                .help(removeHelp ?? "Remove")
            }
        }
    }

    private func styleGuideRows(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(notes.prefix(5).enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(Palette.gold).frame(width: 5, height: 5).padding(.top, 5)
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(Palette.goldTxt)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var eqCard: some View {
        Card(title: "5-band EQ", subtitle: "Ride the tone on top of the master") {
            VStack(spacing: 10) {
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(0..<UserEQ.count, id: \.self) { i in
                        VStack(spacing: 6) {
                            Text(String(format: "%+.0f", state.eqGains[i]))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(abs(state.eqGains[i]) < 0.05 ? Palette.dim : Palette.goldTxt)
                            Slider(value: Binding(get: { state.eqGains[i] },
                                                  set: { state.eqGains[i] = $0 }), in: -12...12, step: 0.5)
                                .frame(width: 104)
                                .rotationEffect(.degrees(-90))
                                .frame(width: 30, height: 104)
                                .tint(Palette.gold)
                            Text(UserEQ.specs[i].label)
                                .font(.system(size: 9)).foregroundColor(Palette.dim)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                HStack {
                    Text("Sub 60 · Low 220 · Mid 1k · Pres 4k · Air 12k")
                        .font(.system(size: 8, design: .monospaced)).foregroundColor(Palette.dim)
                    Spacer()
                    Button(action: { state.resetEQ() }) {
                        Text("Reset").font(.system(size: 10)).foregroundColor(Palette.gold)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var mixStyleCard: some View {
        Card(title: "Mix style", subtitle: "Roles · sidechain · kick / bass / vocal") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: Binding(get: { state.mixStyle.id },
                                              set: { id in if let s = MixStyles.all.first(where: { $0.id == id }) { state.mixStyle = s } })) {
                    ForEach(MixStyles.all) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.menu).tint(Palette.gold)
                Text(state.mixStyle.blurb).font(.system(size: 10)).foregroundColor(Palette.dim)
                Text(String(format: "sidechain %.0f dB · kick %.0f%% · bass drive %.0f%% · vocal duck %.0f dB",
                            state.mixStyle.options.sidechainDepthDB, state.mixStyle.options.kickPunch * 100,
                            state.mixStyle.options.bassDrive * 100, state.mixStyle.options.vocalDuckDB))
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.mixStyle.guideNotes.isEmpty {
                    Divider().overlay(Palette.stroke)
                    styleGuideRows(state.mixStyle.guideNotes)
                }
            }
        }
    }

    private var characterCard: some View {
        Card(title: "Character", subtitle: "Loudness ↔ dynamics") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $state.intensity) {
                    ForEach(MasterIntensity.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented)
                Text("\(state.intensity.blurb)  ·  ~\(Int(state.intensity.targetLUFS)) LUFS")
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
                Toggle(isOn: $state.useCustomLoudness) {
                    Text("Custom loudness target").font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                }.tint(Palette.gold)
                if state.useCustomLoudness {
                    HStack(spacing: 8) {
                        Slider(value: $state.customLUFS, in: -16 ... -5).tint(Palette.gold)
                        Text(String(format: "%.0f LUFS", state.customLUFS))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(Palette.goldTxt).frame(width: 66)
                    }
                }
            }
        }
    }

    private var runSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GoldButton(title: state.mode == .mixOnly ? "CREATE MIX" : "CREATE MASTER") {
                state.run()
            }
            .disabled(state.isProcessing)
            .opacity(state.isProcessing ? 0.6 : 1)

            if state.isProcessing {
                ProgressView(value: state.progress)
                    .tint(Palette.gold)
                    .background(Palette.ink)
                GhostButton(title: "Cancel") { state.cancel() }
            }
            Text(state.statusLine).font(.system(size: 11)).foregroundColor(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                GhostButton(title: "Batch-master files…") { batchAction() }
                    .disabled(state.isProcessing || state.isBatch)
                if state.lastBatchOutputDir != nil {
                    GhostButton(title: "Reveal batch") { state.revealLastBatchFolder() }
                }
            }
            if state.isBatch {
                Text("Batch \(state.batchDone)/\(state.batchTotal) · \(state.batchFailed) failed")
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
            }
        }
    }

    // MARK: - Right: results

    private var rightColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Master").font(.system(size: 16, weight: .semibold)).foregroundColor(Palette.goldTxt)
                    Spacer()
                    if state.lastExportURL != nil {
                        GhostButton(title: "Reveal") { state.revealLastExport() }
                    }
                    GhostButton(title: "Export bundle…") { exportBundle() }
                        .disabled(state.result == nil)
                    GoldButton(title: "Export master…") { exportMaster() }
                        .disabled(state.result == nil)
                        .opacity(state.result == nil ? 0.5 : 1)
                }

                if let result = state.result {
                    transportSection
                    Spectrum3DView(before: result.spectrumBeforeDB,
                                   after: result.spectrumAfterDB,
                                   eqCurve: result.eqCurveDB)
                        .frame(height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.stroke, lineWidth: 1))
                        .overlay(alignment: .topLeading) { spectrumLegend.padding(10) }
                    MetersView(result: result, platform: state.selectedPlatform)
                    appliedChain(result)
                } else {
                    emptyResults
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var transportSection: some View {
        Card(title: "Audition", subtitle: "Before / after — click or drag either wave to scrub") {
            VStack(alignment: .leading, spacing: 12) {
                waveRow(label: "BEFORE  ·  your mix", peaks: state.inputPeaks,
                        tint: Palette.dim, active: state.auditionSource == .original)
                waveRow(label: "AFTER  ·  Sunset master", peaks: state.masterPeaks,
                        tint: Palette.gold, active: state.auditionSource == .master)

                HStack(spacing: 12) {
                    Button(action: { state.toggleAudition() }) {
                        Image(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 24)).foregroundColor(Palette.gold)
                    }.buttonStyle(.plain)
                    Picker("", selection: Binding(get: { state.auditionSource },
                                                  set: { state.setAudition($0) })) {
                        Text("Original").tag(AppState.AuditionSource.original)
                        Text("Master").tag(AppState.AuditionSource.master)
                        Text("Translation").tag(AppState.AuditionSource.translation)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 300)
                    Spacer()
                    Text(String(format: "%@ · %@", auditionLabel,
                                timeLabel(state.playhead)))
                        .font(.system(size: 10, design: .monospaced)).foregroundColor(Palette.dim)
                }
            }
        }
    }

    private func waveRow(label: String, peaks: [Float], tint: Color, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(active ? Palette.goldTxt : Palette.dim)
            WaveformView(peaks: peaks, playhead: state.playhead, tint: tint,
                         onSeek: { state.seek(to: $0) })
                .opacity(active ? 1 : 0.7)
        }
    }

    /// Playhead position as m:ss, using the loaded input duration when known.
    private func timeLabel(_ frac: Double) -> String {
        let frames: Int
        let sampleRate: Double
        switch state.auditionSource {
        case .original:
            frames = state.inputSignal?.frameCount ?? 0
            sampleRate = state.inputSignal?.sampleRate ?? 44_100
        case .master, .translation:
            frames = state.result?.output.frameCount ?? state.inputSignal?.frameCount ?? 0
            sampleRate = state.result?.output.sampleRate ?? state.inputSignal?.sampleRate ?? 44_100
        }
        let dur = Double(frames) / sampleRate
        let t = frac * dur
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private var auditionLabel: String {
        switch state.auditionSource {
        case .original: return "hearing original"
        case .master: return "hearing master"
        case .translation: return "hearing \(state.translationAuditionName)"
        }
    }

    private var spectrumLegend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) { Circle().fill(Palette.gold).frame(width: 7, height: 7); Text("AFTER").font(.system(size: 9, weight: .semibold)).foregroundColor(Palette.goldTxt) }
            HStack(spacing: 5) { Circle().fill(Color(red: 0.42, green: 0.47, blue: 0.62)).frame(width: 7, height: 7); Text("BEFORE").font(.system(size: 9, weight: .semibold)).foregroundColor(Palette.dim) }
            Text("drag to orbit").font(.system(size: 8, design: .monospaced)).foregroundColor(Palette.dim)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.black.opacity(0.35))
        .clipShape(Capsule())
    }

    private var emptyResults: some View {
        VStack(spacing: 10) {
            Spectrum3DView(before: [], after: [], eqCurve: [])
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.stroke, lineWidth: 1))
            VStack(spacing: 6) {
                Image(systemName: "waveform.path").font(.system(size: 26)).foregroundColor(Palette.stroke)
                Text("Drop your FL Studio bounce or stems to begin")
                    .font(.system(size: 12)).foregroundColor(Palette.dim)
                Text("Then hit \(state.mode == .mixOnly ? "CREATE MIX" : "CREATE MASTER").")
                    .font(.system(size: 11)).foregroundColor(Palette.dim)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
        }
    }

    private func appliedChain(_ result: MasterResult) -> some View {
        Card(title: "Applied chain", subtitle: "Every move, and why") {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(result.match.notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: 6) {
                        Circle().fill(Palette.gold).frame(width: 5, height: 5).padding(.top, 5)
                        Text(note).font(.system(size: 11)).foregroundColor(Palette.goldTxt)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !result.appliedEQ.isEmpty {
                    Divider().overlay(Palette.stroke).padding(.vertical, 2)
                    Text("Applied EQ").font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.dim)
                    ForEach(result.appliedEQ) { band in
                        Text(eqSummary(band)).font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Palette.dim)
                    }
                }
            }
        }
    }

    private func eqSummary(_ b: EQBand) -> String {
        let f = b.freq >= 1000 ? String(format: "%.1fkHz", b.freq / 1000) : String(format: "%.0fHz", b.freq)
        let kind: String
        switch b.kind {
        case .peaking:   kind = "peak"
        case .lowShelf:  kind = "low-shelf"
        case .highShelf: kind = "high-shelf"
        case .highPass:  kind = "high-pass"
        case .lowPass:   kind = "low-pass"
        }
        if b.kind == .highPass || b.kind == .lowPass {
            return String(format: "%@  %@  Q%.2f", kind, f, b.q)
        }
        return String(format: "%@  %@  %+.1fdB  Q%.2f", kind, f, b.gainDB, b.q)
    }

    // MARK: - Target pickers (bound by id so GenreTarget/PlatformTarget need not be Hashable)

    private var genreBinding: Binding<String> {
        Binding(get: { state.selectedGenre.id },
                set: { id in if let g = GenreTargets.all.first(where: { $0.id == id }) { state.selectedGenre = g } })
    }
    private var platformBinding: Binding<String> {
        Binding(get: { state.selectedPlatform.id },
                set: { id in if let p = PlatformTargets.all.first(where: { $0.id == id }) { state.selectedPlatform = p } })
    }

    private func labeledPicker(_ label: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.dim)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { opt in Text(opt.1).tag(opt.0) }
            }
            .labelsHidden().pickerStyle(.menu).tint(Palette.gold)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - File actions

    private func chooseMix() {
        if let url = FilePanels.openAudio(multiple: false).first { state.loadInput(url) }
    }
    private func chooseStems() {
        let urls = FilePanels.openAudio(multiple: true)
        if !urls.isEmpty { state.loadStems(urls) }
    }
    private func chooseReference() {
        if let url = FilePanels.openAudio(multiple: false).first { state.loadReference(url) }
    }
    private func exportMaster() {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent ?? "master"
        if let url = FilePanels.saveWav(defaultName: "\(base) - Sunset master.wav") { state.export(to: url) }
    }
    private func exportBundle() {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent ?? "master"
        if let url = FilePanels.saveWav(defaultName: "\(base) - Sunset release.wav") { state.exportReleaseBundle(to: url) }
    }
    private func batchAction() {
        let files = FilePanels.openAudio(multiple: true)
        guard !files.isEmpty else { return }
        guard let dir = FilePanels.chooseFolder() else { return }
        state.batchMaster(files, outputDir: dir)
    }

    /// Resolve dropped file URLs, then route: multiple -> stems, single -> mix.
    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let u = item as? URL { url = u }
                else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                if let url {
                    lock.lock(); urls.append(url); lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            // notify fires on the main queue — safe to touch the @MainActor AppState.
            MainActor.assumeIsolated {
                if urls.count > 1 { state.loadStems(urls) } else { state.loadInput(urls[0]) }
            }
        }
    }
}

// MARK: - AppKit panel helpers

/// Thin wrappers over NSOpenPanel/NSSavePanel — synchronous modal, main-thread only.
enum FilePanels {
    /// Common audio import types; broad `.audio` plus explicit lossless/lossy fallbacks.
    private static var audioTypes: [UTType] {
        var t: [UTType] = [.audio, .wav, .aiff, .mpeg4Audio]
        if let mp3 = UTType(filenameExtension: "mp3") { t.append(mp3) }
        if let flac = UTType(filenameExtension: "flac") { t.append(flac) }
        return t
    }

    static func openAudio(multiple: Bool) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = audioTypes
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func saveWav(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = defaultName
        panel.prompt = "Export"
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Save panel constrained to a chosen audio extension (wav/aiff/m4a/flac) for the export picker.
    static func saveAudio(defaultName: String, ext: String) -> URL? {
        let panel = NSSavePanel()
        if let ut = UTType(filenameExtension: ext) { panel.allowedContentTypes = [ut] }
        panel.nameFieldStringValue = defaultName
        panel.prompt = "Export"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func saveText(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = defaultName
        panel.prompt = "Export"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose output folder"
        return panel.runModal() == .OK ? panel.urls.first : nil
    }

    /// Phase-2 session documents (JSON settings only — never audio).
    static func saveJSON(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = defaultName
        panel.prompt = "Save"
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func openJSON() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Open"
        return panel.runModal() == .OK ? panel.urls.first : nil
    }
}
#endif // circuit-convert
