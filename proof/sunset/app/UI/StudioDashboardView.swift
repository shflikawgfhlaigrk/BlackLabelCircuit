#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
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

struct StudioDashboardView: View {
    @EnvironmentObject var state: AppState
    @State private var dropTargeted = false
    @State private var inspector: InspectorMode = .doctor
    @State private var newDNAName = ""

    private enum InspectorMode: String, CaseIterable, Identifiable {
        case doctor = "Doctor"
        case matrix = "Matrix"
        case chain = "Chain"
        var id: String { rawValue }
    }

    var body: some View {
        HStack(spacing: 0) {
            sessionRail
                .frame(width: 330)
                .background(SD.panelDeep)
                .overlay(Rectangle().fill(SD.line).frame(width: 1), alignment: .trailing)

            studioSurface
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            inspectorRail
                .frame(width: 360)
                .background(SD.panelDeep.opacity(0.86))
                .overlay(Rectangle().fill(SD.line).frame(width: 1), alignment: .leading)
        }
        .background(SD.bg)
        .foregroundColor(SD.text)
        .tint(SD.gold)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    // MARK: - Left Rail

    private var sessionRail: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                brandBlock
                privacySeal
                importPanel
                if state.studioArea == .mix {
                    characterPanel
                    runPanel
                } else {
                    targetPanel
                    characterPanel
                    runPanel
                    eqPanel
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var brandBlock: some View {
        HStack(spacing: 10) {
            if let ns = bundleLogo() {
                Image(nsImage: ns)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(SD.gold.opacity(0.45), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(SD.gold)
                    .frame(width: 34, height: 34)
                    .overlay(Text("S").font(.system(size: 20, weight: .black)).foregroundColor(.black))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("SUNSET").font(.system(size: 14, weight: .black, design: .rounded)).foregroundColor(SD.goldText)
                Text("MIXING / MASTERING").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundColor(SD.dim)
            }
            Spacer()
            statusDot
        }
    }

    private var statusDot: some View {
        let ready = state.result != nil || state.mixResult != nil
        return HStack(spacing: 5) {
            Circle().fill(ready ? SD.green : SD.gold).frame(width: 7, height: 7)
            Text(ready ? "READY" : "IDLE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(ready ? SD.green : SD.dim)
        }
    }

    // MARK: - Trust seal (no-upload wedge, surfaced)
    // Traceable to real properties: zero URLSession/http in DSP/ + Audio/ (the mastering path),
    // and the app renders on-device — the buyer's audio is never uploaded. Links to the
    // explainable "what changed and why" Chain notes so the claim is verifiable, not a slogan.
    private var privacySeal: some View {
        StudioPanel(title: "Private by design", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(SD.gold)
                    Text("AUDIO NEVER LEAVES THIS MAC")
                        .font(.system(size: 10.5, weight: .black, design: .rounded))
                        .foregroundColor(SD.goldText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Sunset mixes or masters your audio entirely on-device. No upload, no account, no cloud render queue — your audio is never sent anywhere.")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(SD.text.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    sealChip("No upload")
                    sealChip("No account")
                    sealChip("Offline render")
                }
                Button {
                    inspector = .chain
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 9, weight: .bold))
                        Text("Every move is shown in Chain — no black box")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(SD.gold)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sealChip(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 8.5, weight: .black, design: .monospaced))
            .foregroundColor(SD.goldText)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(SD.gold.opacity(0.14))
            .clipShape(Capsule())
    }

    private var importPanel: some View {
        StudioPanel(title: "Session", icon: "waveform.badge.plus") {
            VStack(alignment: .leading, spacing: 10) {
                dropTarget
                HStack(spacing: 8) {
                    commandButton("Mastering", icon: "waveform") { chooseMix() }
                    commandButton("Mixing", icon: "square.stack.3d.up") { chooseStems() }
                }
                loadedLine
                modeSignpost
                if state.studioArea == .master { referenceInputBlock }
            }
        }
    }

    /// Plain-language badge naming which path is active, so the two modes never blur together:
    /// one finished mix → master, vs raw stems → per-stem mix → one master. Shown once a source loads.
    @ViewBuilder private var modeSignpost: some View {
        if state.mode == .masterOnly && state.inputSignal != nil {
            modeBadge(icon: "wand.and.stars", title: "MASTERING",
                      detail: "One finished stereo mix in. One release master out.")
        } else if state.mode == .mixOnly && !state.stemURLs.isEmpty {
            modeBadge(icon: "slider.horizontal.3", title: "MIXING",
                      detail: "Stems become a stereo mix bounce. No mastering is applied.")
        }
    }

    private func modeBadge(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(SD.goldText)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9.5, weight: .black, design: .monospaced))
                    .foregroundColor(SD.goldText)
                Text(detail)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(SD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SD.gold.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(SD.gold.opacity(0.28), lineWidth: 1))
    }

    private var referenceInputBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Reference", systemImage: "target")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(SD.dim)
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("Paste link or type reference", text: $state.referenceLink)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(SD.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(SD.panelDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(SD.line, lineWidth: 1))
                    .onSubmit { state.resolveReferenceLink() }
                Button(action: { state.resolveReferenceLink() }) {
                    Image(systemName: state.isResolvingLink ? "hourglass" : "arrow.turn.down.left")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(SD.goldText)
                        .frame(width: 30, height: 30)
                        .background(SD.panelDeep)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(SD.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Apply reference")
                .disabled(state.isResolvingLink)
                Button(action: { chooseReference() }) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(SD.goldText)
                        .frame(width: 30, height: 30)
                        .background(SD.panelDeep)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(SD.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Choose exact reference file")
            }

            if let err = state.linkError {
                Text(err)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(SD.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reference = state.referenceURL {
                miniLine("waveform.badge.magnifyingglass", "Exact file: \(reference.lastPathComponent)", removeHelp: "Remove exact reference") {
                    state.clearReferenceFile()
                }
            }
            if let ref = state.linkReference {
                miniLine(ref.source == "Manual" ? "text.cursor" : "link", "\(ref.source): \(ref.inferredStyle.name)", removeHelp: "Remove style reference") {
                    state.clearReferenceLink()
                }
            }

            dnaLibraryBlock
        }
        .padding(10)
        .background(SD.ink.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SD.line, lineWidth: 1))
    }

    /// SS-24 Reference-DNA library: capture the loaded reference into a named, reusable
    /// profile; arm / rename / delete saved profiles. Re-applies across masters and batches.
    private var dnaLibraryBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().background(SD.line)
            HStack {
                Label("DNA Library", systemImage: "square.stack.3d.up")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(SD.dim)
                Spacer()
                Text("\(state.dnaProfiles.count) saved")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(SD.dim)
            }

            HStack(spacing: 8) {
                TextField("Name this reference's DNA", text: $newDNAName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(SD.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(SD.panelDeep)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(SD.line, lineWidth: 1))
                    .onSubmit { saveDNA() }
                Button(action: { saveDNA() }) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(state.referenceURL == nil ? SD.dim : SD.goldText)
                        .frame(width: 30, height: 30)
                        .background(SD.panelDeep)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(SD.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Save the loaded reference file's DNA as a reusable profile")
                .disabled(state.referenceURL == nil)
            }
            if state.referenceURL == nil {
                Text("Load a reference file to capture its DNA.")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(SD.dim)
            }

            ForEach(state.dnaProfiles) { profile in
                HStack(spacing: 7) {
                    Button(action: { state.selectDNAProfile(state.selectedDNAProfileID == profile.id ? nil : profile.id) }) {
                        Image(systemName: state.selectedDNAProfileID == profile.id ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(state.selectedDNAProfileID == profile.id ? SD.goldText : SD.dim)
                    }
                    .buttonStyle(.plain)
                    .help(state.selectedDNAProfileID == profile.id ? "Armed — click to disarm" : "Arm this DNA for masters + batches")
                    Image(systemName: "waveform")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(SD.dim)
                    Text(profile.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(SD.text)
                        .lineLimit(1)
                    Spacer()
                    Button(action: { state.deleteDNAProfile(profile.id) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(SD.dim)
                    }
                    .buttonStyle(.plain)
                    .help("Delete this DNA profile")
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(state.selectedDNAProfileID == profile.id ? SD.gold.opacity(0.12) : SD.panelDeep.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    private func saveDNA() {
        state.saveReferenceDNA(named: newDNAName)
        newDNAName = ""
    }

    private var dropTarget: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(dropTargeted ? SD.gold.opacity(0.16) : SD.ink)
            .frame(height: 78)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropTargeted ? SD.gold : SD.line, style: StrokeStyle(lineWidth: 1, dash: [5, 5])))
            .overlay(
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(SD.gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(inputHeadline).font(.system(size: 12, weight: .bold)).foregroundColor(SD.text)
                        Text(inputSubline).font(.system(size: 10, weight: .medium)).foregroundColor(SD.dim)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
            )
    }

    private var loadedLine: some View {
        Group {
            if state.mode == .mixOnly && !state.stemURLs.isEmpty {
                miniLine("square.stack.3d.up", "\(state.stemURLs.count) stems — each mixed on its own chain", removeHelp: "Remove stems") {
                    state.clearInputSource()
                }
            } else if state.mode == .masterOnly, let input = state.inputURL {
                miniLine("waveform", input.lastPathComponent, removeHelp: "Remove stereo mix") {
                    state.clearInputSource()
                }
            } else if state.mode == .masterOnly && state.inputSignal != nil && state.mixResult != nil {
                miniLine("arrow.right.circle", "Current mix bounce — ready for mastering", removeHelp: "Clear session") {
                    state.clearInputSource()
                }
            } else {
                miniLine("tray", "No source loaded")
            }
        }
    }

    private var targetPanel: some View {
        StudioPanel(title: "Target", icon: "scope") {
            VStack(alignment: .leading, spacing: 10) {
                pickerLine("Genre", selection: genreBinding, options: GenreTargets.all.map { ($0.id, $0.name) })
                pickerLine("Platform", selection: platformBinding, options: PlatformTargets.all.map { ($0.id, $0.name) })
                meterRow(label: "Ceiling", value: String(format: "%.1f dBTP", state.selectedPlatform.truePeakDBTP), tint: SD.blue)
                meterRow(label: "Playback", value: String(format: "%.0f LUFS", state.selectedPlatform.lufs), tint: SD.gold)
            }
        }
    }

    private var characterPanel: some View {
        StudioPanel(title: state.mode == .mixOnly ? "Mix Engine" : "Master Engine", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 10) {
                if state.mode == .mixOnly {
                    Picker("", selection: Binding(get: { state.mixStyle.id },
                                                  set: { id in if let s = MixStyles.all.first(where: { $0.id == id }) { state.mixStyle = s } })) {
                        ForEach(MixStyles.all) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(SD.gold)
                    Text(state.mixStyle.blurb)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(SD.dim)
                        .lineLimit(2)
                    meterRow(label: "Kick", value: String(format: "%.0f%%", state.mixStyle.options.kickPunch * 100), tint: SD.green)
                    meterRow(label: "Duck", value: String(format: "%.0f dB", state.mixStyle.options.sidechainDepthDB), tint: SD.blue)
                    meterRow(label: "Release", value: String(format: "%.0f ms", state.mixStyle.options.sidechainReleaseMs), tint: SD.gold)
                    if !state.mixStyle.guideNotes.isEmpty {
                        Divider().overlay(SD.line)
                        styleGuideRows(state.mixStyle.guideNotes)
                    }
                } else {
                    Picker("", selection: $state.intensity) {
                        ForEach(MasterIntensity.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .tint(SD.gold)
                    Toggle(isOn: $state.useCustomLoudness) {
                        Text("LUFS override").font(.system(size: 11, weight: .semibold)).foregroundColor(SD.text)
                    }
                    .tint(SD.gold)
                    if state.useCustomLoudness {
                        HStack(spacing: 8) {
                            Slider(value: $state.customLUFS, in: -16 ... -5)
                                .tint(SD.gold)
                            Text(String(format: "%.0f", state.customLUFS))
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundColor(SD.goldText)
                                .frame(width: 34)
                        }
                    }
                }
                if state.mode == .masterOnly {
                    loudnessProfileControls
                    softClipControls
                }
            }
        }
    }

    /// Selectable loudness profile (Club / Tech-House, Streaming, …). Sets the loudness
    /// target + true-peak ceiling; the meters always report what the master MEASURED.
    private var loudnessProfileControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().overlay(SD.line)
            pickerLine("Loudness", selection: loudnessProfileBinding,
                       options: LoudnessProfiles.all.map { ($0.id, $0.name) })
            Text(state.loudnessProfile.blurb)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(SD.dim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Pre-limiter soft-clip stage — bypassable. When engaged, shows the MEASURED
    /// "dB clipped" read-out from the last render (never asserted).
    private var softClipControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(SD.line)
            Toggle(isOn: $state.softClipEnabled) {
                Text("Soft clip (pre-limiter)")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(SD.text)
            }
            .tint(SD.gold)
            .help("Softly rounds the loudest peaks before the limiter, for club/tech-house punch. 4× oversampled.")
            if state.softClipEnabled {
                HStack(spacing: 8) {
                    Text("DRIVE")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .foregroundColor(SD.dim).frame(width: 46, alignment: .leading)
                    Slider(value: $state.softClipDriveDB, in: 0.5...3, step: 0.05).tint(SD.gold)
                    Text(String(format: "%.2f dB", state.softClipDriveDB))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(SD.goldText).frame(width: 56, alignment: .trailing)
                }
                if let r = state.result, r.softClip.enabled {
                    meterRow(label: "Clipped",
                             value: String(format: "%.2f dB · %.0f%%", r.softClip.dBClipped, r.softClip.percentClipped),
                             tint: SD.blue)
                }
            }
        }
    }

    private var eqPanel: some View {
        StudioPanel(title: "Tone", icon: "dial.low") {
            VStack(alignment: .leading, spacing: 8) {
                pickerLine("Preset", selection: tonePresetBinding, options: TonePresets.menu.map { ($0.id, $0.name) })
                if let preset = TonePresets.byID(state.tonePresetID) {
                    Text(preset.blurb)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(SD.dim)
                        .lineLimit(2)
                }
                ForEach(0..<UserEQ.count, id: \.self) { i in
                    HStack(spacing: 8) {
                        Text(UserEQ.specs[i].label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(SD.dim)
                            .frame(width: 52, alignment: .leading)
                        Slider(value: Binding(get: { i < state.eqGains.count ? state.eqGains[i] : 0 },
                                              set: { state.setEQGain(i, $0) }), in: -12...12, step: 0.5)
                            .tint(SD.gold)
                        Text(String(format: "%+.1f", i < state.eqGains.count ? state.eqGains[i] : 0))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(abs(i < state.eqGains.count ? state.eqGains[i] : 0) < 0.05 ? SD.dim : SD.goldText)
                            .frame(width: 45, alignment: .trailing)
                    }
                }
                HStack {
                    Spacer()
                    Button("Flat") { state.resetEQ() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(SD.gold)
                }
            }
        }
    }

    private var runPanel: some View {
        StudioPanel(title: "Render", icon: "bolt.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: { state.run() }) {
                    HStack {
                        Image(systemName: state.isProcessing ? "stopwatch.fill" : "play.fill")
                        Text(state.mode == .mixOnly ? "CREATE MIX" : "CREATE MASTER")
                        Spacer()
                    }
                    .font(.system(size: 13, weight: .black))
                    .foregroundColor(.black)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(SD.gold)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(state.isProcessing)

                if state.isProcessing {
                    ProgressView(value: state.progress).tint(SD.gold)
                    commandButton("Cancel", icon: "xmark") { state.cancel() }
                }

                Text(state.statusLine)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(SD.dim)
                    .lineLimit(3)

                if state.mode == .masterOnly {
                    HStack(spacing: 8) {
                        commandButton("Batch", icon: "square.stack") { batchAction() }
                        if state.lastBatchOutputDir != nil {
                            commandButton("Folder", icon: "folder") { state.revealLastBatchFolder() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Center Surface

    private var studioSurface: some View {
        VStack(spacing: 0) {
            areaSwitcher
            Divider().overlay(SD.line)
            if state.studioArea == .mix { mixTopBar } else { topBar }
            Divider().overlay(SD.line)
            ScrollView {
                VStack(spacing: 14) {
                    switch state.studioArea {
                    case .mix:
                        // MIX — the per-stem console: strips, buses, sends. Transport stays
                        // so you can audition while you mix.
                        audioDeck
                        MixConsoleView()
                    case .master:
                        // MASTER — the explicit chain + every mastering meter/proof surface.
                        audioDeck
                        MasterChainView()
                        if let result = state.result {
                            metersDeck(result)
                            reportCardDeck(result)
                            proofDeck(result)
                        } else {
                            idleDeck
                        }
                        matrixDeck
                    }
                }
                .padding(18)
            }
        }
        .background(SD.bg)
    }

    /// The two disciplines are different areas — a top-level switcher, never a blur.
    private var areaSwitcher: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(get: { state.studioArea },
                                           set: { state.activateStudioArea($0) })) {
                ForEach(StudioArea.allCases) { area in
                    Text(area == .mix ? "MIX" : "MASTER").tag(area)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .tint(SD.gold)
            .frame(width: 260)
            Text(state.studioArea == .mix
                 ? "Per-stem strips, buses, sends — mixing is its own discipline."
                 : "The stereo bounce: chain, loudness, meters, proof — mastering lives here.")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(SD.dim)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 8) {
                commandButton("Save session", icon: "square.and.arrow.down.on.square") { saveSessionAction() }
                commandButton("Load session", icon: "square.and.arrow.up.on.square") { loadSessionAction() }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(projectTitle)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundColor(SD.text)
                    .lineLimit(1)
                Text(projectSubtitle)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(SD.dim)
                    .lineLimit(1)
            }
            Spacer()
            topMetric("Score", value: state.doctorReport.map { "\($0.score)" } ?? "--", tint: scoreTint)
                .help("Release readiness, 0–100, measured on the loaded audio — your source before mastering, your master after. Higher means closer to clean and streaming-ready.")
            topMetric("LUFS", value: state.result.map { String(format: "%.1f", $0.after.integratedLUFS) } ?? "--", tint: SD.gold)
                .help("Loudness (LUFS) — how loud your track is overall. Streaming sits near −14; club and EDM masters run louder.")
            topMetric("Peak", value: state.result.map { String(format: "%.1f", $0.after.truePeakDBTP) } ?? "--", tint: SD.blue)
                .help("True peak (dBTP) — the loudest instant. Sunset keeps this under 0 so your track never distorts on playback.")
            exportOptionsMenu
                .disabled(state.result == nil)
            primaryCommand("Export", icon: "square.and.arrow.down") { exportMaster() }
                .disabled(state.result == nil)
                .help("Save your finished master in the chosen format (WAV/AIFF/AAC/FLAC).")
            deliveryCommands
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    /// Secondary delivery commands (Card / Bundle / Pack / Proof). Four fixed-width buttons
    /// cannot fit next to the metrics at the 1180pt minimum window on 13-inch displays, so
    /// below that width they collapse into a single Deliver menu instead of truncating.
    private var deliveryCommands: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                commandButton("Card", icon: "doc.text.image") { exportReportCard() }
                    .disabled(state.result == nil)
                    .help("Save the report card — before/after loudness, peak, range, and crest with the chain moves.")
                commandButton("Bundle", icon: "shippingbox") { exportBundle() }
                    .disabled(state.result == nil)
                    .help("Save the master WAV plus a proof report (txt + json) — everything you need for release.")
                commandButton("Pack", icon: "square.3.layers.3d.down.right") { exportDeliveryPack() }
                    .disabled(state.result == nil || state.isDeliveryPack)
                    .help("One-click delivery pack — renders your master to every platform's loudness + true-peak target (Spotify, Apple Music, YouTube, Tidal, Amazon, SoundCloud, Club/DJ) as one labeled file each.")
                commandButton("Proof", icon: "doc.badge.checkmark") { exportProof() }
                    .disabled(state.doctorReport == nil)
                    .help("Save a plain-text report listing every mastering move and every measurement.")
            }
            deliveryMenu
        }
    }

    private var deliveryMenu: some View {
        Menu {
            Button("Report card — before/after measurements") { exportReportCard() }
                .disabled(state.result == nil)
            Button("Release bundle — master WAV + proof (txt/json)") { exportBundle() }
                .disabled(state.result == nil)
            Button("Delivery pack — one master per platform") { exportDeliveryPack() }
                .disabled(state.result == nil || state.isDeliveryPack)
            Button("Proof — every move and measurement (txt)") { exportProof() }
                .disabled(state.doctorReport == nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox").font(.system(size: 10, weight: .bold))
                Text("Deliver").font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(SD.goldText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Delivery exports — report card, release bundle, per-platform pack, and proof.")
    }

    /// Mixing owns its own completion surface: export a mix bounce or explicitly hand that
    /// bounce to mastering. Master-only proof and delivery controls never appear here.
    private var mixTopBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(projectTitle)
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundColor(SD.text)
                    .lineLimit(1)
                Text("MIXING  /  \(state.stemURLs.count) STEMS  /  NO MASTERING")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(SD.dim)
            }
            Spacer()
            topMetric("Output", value: state.mixResult == nil ? "--" : "MIX", tint: SD.gold)
            exportOptionsMenu
                .disabled(state.mixResult == nil)
            primaryCommand("Export Mix", icon: "square.and.arrow.down") { exportMix() }
                .disabled(state.mixResult == nil)
                .help("Save the stereo mix bounce. No mastering stages are applied.")
            commandButton("Send to Mastering", icon: "arrow.right.circle") {
                state.sendMixToMastering()
            }
            .disabled(state.mixResult == nil)
            .help("Use this mix bounce as the input to the separate mastering workflow.")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
    }

    private var audioDeck: some View {
        StudioPanel(title: "Audio Surface", icon: "waveform.path.ecg") {
            VStack(spacing: 12) {
                ZStack(alignment: .topLeading) {
                    if let result = state.result {
                        Spectrum3DView(before: result.spectrumBeforeDB,
                                       after: result.spectrumAfterDB,
                                       eqCurve: result.eqCurveDB)
                            .frame(height: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(SD.line, lineWidth: 1))
                    } else {
                        dormantSpectrum
                    }
                    // Legend lists only the series the 3D scene actually draws (before/after rows).
                    HStack(spacing: 8) {
                        legendDot("Before", SD.dim)
                        legendDot("After", SD.gold)
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.34))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(10)
                }
                transportDeck
            }
        }
    }

    private var dormantSpectrum: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(SD.ink)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(SD.line, lineWidth: 1))
            VStack(spacing: 9) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(SD.gold.opacity(0.72))
                Text("NO SESSION")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(SD.dim)
            }
        }
        .frame(height: 360)
    }

    private var transportDeck: some View {
        VStack(spacing: 10) {
            if state.mode == .masterOnly {
                waveRow(label: "SOURCE", peaks: state.inputPeaks, tint: SD.dim, active: state.auditionSource == .original)
                waveRow(label: "MASTER", peaks: state.masterPeaks, tint: SD.gold, active: state.auditionSource == .master)
            } else {
                waveRow(label: "MIX BOUNCE", peaks: state.masterPeaks, tint: SD.gold, active: state.auditionSource == .master)
            }
            HStack(spacing: 12) {
                Button(action: { state.toggleAudition() }) {
                    Image(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 25, weight: .bold))
                        .foregroundColor(SD.gold)
                }
                .buttonStyle(.plain)
                Picker("", selection: Binding(get: { state.auditionSource },
                                              set: { state.setAudition($0) })) {
                    if state.mode == .masterOnly {
                        Text("Original").tag(AppState.AuditionSource.original)
                        Text("Master").tag(AppState.AuditionSource.master)
                        Text("Translation").tag(AppState.AuditionSource.translation)
                    } else {
                        Text("Mix").tag(AppState.AuditionSource.master)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .tint(SD.gold)
                .frame(width: 296)
                gainMatchControl
                hearWhatChangedButton
                Spacer()
                Text("\(auditionLabel)  \(timeLabel(state.playhead))")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(SD.dim)
            }
        }
    }

    /// SS-18 — "Hear What Changed": auditions the aligned, loudness-matched residual (original minus
    /// master). Available once a master exists from a stereo mix; flips the A/B picker to Translation.
    private var hearWhatChangedButton: some View {
        Button(action: { state.auditionDelta() }) {
            HStack(spacing: 4) {
                Image(systemName: "waveform.badge.minus").font(.system(size: 10, weight: .bold))
                Text("hear what changed").font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundColor(SD.dim)
        }
        .buttonStyle(.plain)
        // MASTER-area proof only: the MIX picker has no Translation slot, so firing it there
        // would deselect the picker and play master-era audio inside the mixing workspace.
        .disabled(state.result == nil || state.inputSignal == nil || state.mode != .masterOnly)
        .help("Play the residual — original minus the master, sample-aligned and loudness-matched — so you hear exactly what the chain added or removed.")
    }

    /// Equal-loudness A/B toggle + measured offset. Honest measurement only — no advice copy.
    /// When on, the louder audition path is attenuated to the quietest source's integrated LUFS
    /// so you compare tone, not level (the "louder sounds better" trick can't sneak in).
    private var gainMatchControl: some View {
        Button(action: { state.gainMatchEnabled.toggle() }) {
            HStack(spacing: 4) {
                Image(systemName: state.gainMatchEnabled ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .bold))
                Text(gainMatchLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundColor(state.gainMatchEnabled ? SD.goldText : SD.dim)
        }
        .buttonStyle(.plain)
        .help("Equal-loudness A/B — attenuates the louder path so you compare tone, not level. The offset is measured (integrated LUFS), not guessed.")
    }

    private var gainMatchLabel: String {
        guard state.gainMatchEnabled else { return "gain-match off" }
        guard state.result != nil else { return "gain-matched" }
        let db = state.gainMatchDB(for: state.auditionSource)
        return abs(db) < 0.05 ? "gain-matched  0.0 dB"
                              : String(format: "gain-matched  %+.1f dB", db)
    }

    /// SS-07 / SS-08 — the export format / bit-depth / sample-rate picker cluster next to Export.
    private var exportOptionsMenu: some View {
        Menu {
            Picker("Format", selection: $state.exportFormat) {
                ForEach(ExportFormat.allCases) { f in Text(f.displayName).tag(f) }
            }
            if state.exportFormat.honorsBitDepth {
                Picker("Bit depth", selection: $state.exportBitDepth) {
                    Text("16-bit").tag(16)
                    Text("24-bit").tag(24)
                }
            }
            Picker("Sample rate", selection: $state.exportSampleRate) {
                Text("Keep source").tag(0)
                Text("44.1 kHz").tag(44100)
                Text("48 kHz").tag(48000)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .bold))
                Text(state.exportFormat.fileExtension.uppercased())
                    .font(.system(size: 11, weight: .black, design: .rounded))
            }
            .foregroundColor(SD.text)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose the export container (WAV/AIFF/AAC/FLAC), bit depth, and sample rate. AAC/FLAC encode natively; MP3 is not offered (no licensed encoder).")
    }

    /// SS-16 — the readable per-master report card: before→after loudness, true peak, range, and
    /// crest in one titled surface, plus the chain moves, with export to text or image. Measurement
    /// only (no advice-imperatives — same rule as the PSR read).
    private func reportCardDeck(_ result: MasterResult) -> some View {
        let card = ReportCard.compose(master: result,
                                      label: state.inputURL?.lastPathComponent ?? "Sunset master")
        return StudioPanel(title: "Report Card", icon: "doc.text.image") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(card.metrics) { m in
                    HStack(spacing: 8) {
                        Text(m.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(SD.text)
                        Spacer()
                        Text("\(m.before) → \(m.after) \(m.unit)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(SD.dim)
                        Text("(\(m.delta))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(SD.gold)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Divider().overlay(SD.line)
                HStack(spacing: 10) {
                    commandButton("Text", icon: "doc.plaintext") { exportReportCard() }
                    commandButton("Image", icon: "photo") { exportReportCardImage(card) }
                    Spacer()
                    Text("measured on your audio — no advice, just the numbers")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(SD.dim)
                }
            }
        }
    }

    /// Render the report card to a PNG via ImageRenderer (export-to-image).
    @MainActor private func exportReportCardImage(_ card: ReportCard) {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent ?? "Sunset"
        guard let url = FilePanels.saveAudio(defaultName: "\(base) - Sunset report card.png", ext: "png") else { return }
        let renderer = ImageRenderer(content:
            Text(card.text)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
                .padding(22)
                .frame(width: 640, alignment: .leading)
                .background(Color(red: 0.06, green: 0.06, blue: 0.09))
        )
        renderer.scale = 2
        guard let ns = renderer.nsImage, let tiff = ns.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            state.statusLine = "Report card image render failed."; return
        }
        do { try png.write(to: url); state.statusLine = "Exported report card image: \(url.lastPathComponent)." }
        catch { state.statusLine = "Report card image failed: \(error.localizedDescription)" }
    }

    /// SS-21 — the unified Explainable-Master Proof: the Report Card (SS-16), the equal-loudness A/B
    /// (SS-17), the "hear what changed" delta (SS-18), and the PSR over-limit read (SS-19) composed
    /// into ONE titled, exportable surface. Measurements and chain notes only — no advice-imperatives.
    private func proofDeck(_ result: MasterResult) -> some View {
        let proof = MasterProof.compose(master: result,
                                        label: state.inputURL?.lastPathComponent ?? "Sunset master")
        return StudioPanel(title: "Explainable Master — Proof", icon: "checkmark.seal") {
            VStack(alignment: .leading, spacing: 10) {
                // 1. Report Card — measured before→after table.
                ForEach(proof.reportCard.metrics) { m in
                    HStack(spacing: 8) {
                        Text(m.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(SD.text)
                        Spacer()
                        Text("\(m.before) → \(m.after) \(m.unit)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(SD.dim)
                        Text("(\(m.delta))")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(SD.gold)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Divider().overlay(SD.line)
                // 2. PSR — the loudness-aware over-limit read (measured; the <8 dB flag is a fact).
                if proof.psr.hasData {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: proof.psr.overLimited ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(proof.psr.overLimited ? SD.blue : SD.gold)
                            .padding(.top, 1)
                        Text(proof.psr.note)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(SD.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // 3 + 4. The two audition proofs playable in-app for this master.
                proofLine("dial.min", proof.abLine)
                proofLine("waveform.badge.minus", proof.deltaLine)
                Divider().overlay(SD.line)
                HStack(spacing: 10) {
                    commandButton("Proof", icon: "square.and.arrow.up") { exportMasterProof() }
                    Spacer()
                    Text("measurements only — no advice, nothing uploaded")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(SD.dim)
                }
            }
        }
    }

    private func proofLine(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
                .foregroundColor(SD.gold).padding(.top, 1)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(SD.text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func metersDeck(_ result: MasterResult) -> some View {
        HStack(alignment: .top, spacing: 14) {
            StudioPanel(title: "Meters", icon: "gauge.with.dots.needle.50percent") {
                MetersView(result: result, platform: state.selectedPlatform)
                    .frame(minHeight: 110)
            }
            StudioPanel(title: "Release Gates", icon: "checklist.checked") {
                compactReleaseChecks
            }
        }
    }

    private var idleDeck: some View {
        VStack(spacing: 14) {
            gettingStartedGuide
            HStack(spacing: 14) {
                statusTile("Input", value: state.inputSignal == nil && state.stemURLs.isEmpty ? "Empty" : "Loaded", icon: "tray")
                statusTile("Reference", value: referenceStatus, icon: "target")
                statusTile("Mode", value: state.mode.label, icon: "slider.horizontal.2.square")
            }
        }
    }

    private var hasSource: Bool { state.inputSignal != nil || !state.stemURLs.isEmpty }

    private var gettingStartedGuide: some View {
        StudioPanel(title: "Getting Started", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                Text(hasSource
                     ? "Track loaded. Pick a genre and platform on the left, then hit the gold CREATE MASTER button. Four steps:"
                     : "New here? Sunset masters your track automatically — and shows you every move it makes. Four steps:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SD.text)
                    .fixedSize(horizontal: false, vertical: true)
                guideStep(1, "Add your track", "Drag a WAV, MP3, AIFF, or FLAC onto the panel on the left — or click Mastering to pick a finished mix. Mixing from parts? Click Mixing to load stems.")
                guideStep(2, "Pick your target", "Choose your genre and the platform you're releasing on — Spotify, Club / DJ, and more. Sunset aims the loudness for you.")
                guideStep(3, "Master", "Hit the gold CREATE MASTER button. Sunset runs the full engineer's chain and scores the result — no settings required.")
                guideStep(4, "Listen, then export", "A/B the before and after below, then click Export at the top to save your finished WAV.")
            }
        }
    }

    private func guideStep(_ n: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.system(size: 11, weight: .black, design: .rounded))
                .foregroundColor(.black)
                .frame(width: 20, height: 20)
                .background(SD.gold)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .bold)).foregroundColor(SD.goldText)
                Text(body)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(SD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var matrixDeck: some View {
        StudioPanel(title: "Master Matrix", icon: "square.grid.3x2") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(state.masterVariants.isEmpty ? "Six deterministic versions render here." : "\(state.masterVariants.count) versions ready")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(SD.dim)
                    Spacer()
                    commandButton(state.isRenderingMatrix ? "Rendering" : "Render 6", icon: "cpu") { state.renderMasterMatrix() }
                        .disabled(state.isRenderingMatrix || state.isProcessing)
                }
                if state.isRenderingMatrix {
                    ProgressView(value: state.progress).tint(SD.gold)
                }
                if !state.masterVariants.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(state.masterVariants) { variant in
                                variantCard(variant)
                            }
                        }
                    }
                }
            }
        }
    }

    private func variantCard(_ variant: MasterVariant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(variant.name)
                    .font(.system(size: 12, weight: .black))
                    .foregroundColor(SD.text)
                Spacer()
                Text("\(variant.score)")
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .foregroundColor(scoreColor(variant.score))
            }
            Text(variant.blurb)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(SD.dim)
                .lineLimit(2)
            VStack(alignment: .leading, spacing: 3) {
                metricLine("LUFS", String(format: "%.1f", variant.lufs))
                metricLine("TP", String(format: "%.1f", variant.truePeak))
                metricLine("Codec", String(format: "%.1f", variant.codecPeak))
            }
            HStack(spacing: 8) {
                commandButton("Hear", icon: "speaker.wave.2") { state.auditionVariant(variant) }
                commandButton("Use", icon: "checkmark") { state.applyVariant(variant) }
            }
        }
        .padding(12)
        .frame(width: 174, alignment: .topLeading)
        .background(SD.ink)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SD.line, lineWidth: 1))
    }

    // MARK: - Right Rail

    private var inspectorRail: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $inspector) {
                    ForEach(InspectorMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .tint(SD.gold)
            }
            .padding(14)
            Divider().overlay(SD.line)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    switch inspector {
                    case .doctor:
                        doctorInspector
                    case .matrix:
                        matrixInspector
                    case .chain:
                        chainInspector
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var doctorInspector: some View {
        Group {
            readinessPanel
            lowEndPanel
            crestPanel
            translationPanel
            referencePanel
            stemControlPanel
            stemConflictPanel
        }
    }

    /// Per-stem mixer: each loaded stem gets an editable role, a gain trim, mute/solo, and a
    /// readout of exactly what the engine applies to it — the hidden per-stem chain made visible.
    private var stemControlPanel: some View {
        StudioPanel(title: "Per-Stem Mixer", icon: "slider.vertical.3") {
            if state.stemDisplayNames.isEmpty {
                emptyText("No stems — load stems to mix each on its own chain")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Each stem is mixed on its OWN chain — gain, EQ, de-masking, compression, warmth, width, sidechain — then the whole session is mastered once.")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(SD.dim)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Sunset isn't just a final-touch master. It mixes every stem individually first — the exact chain each stem gets is listed under it below — then runs one master over the summed mix.")
                    ForEach(state.stemDisplayNames, id: \.self) { name in
                        stemControlRow(name)
                    }
                }
            }
        }
    }

    private func stemControlRow(_ name: String) -> some View {
        let detected = state.detectedStemRole(name)
        let effective = state.effectiveStemRole(name)
        let control = state.stemControl(name)
        return VStack(alignment: .leading, spacing: 6) {
            // Name + mute / solo
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(SD.text)
                    .lineLimit(1)
                Spacer()
                Button(action: { state.toggleStemMute(name) }) {
                    Text("M").font(.system(size: 10, weight: .black, design: .monospaced))
                        .frame(width: 22, height: 18)
                        .background(control.muted ? SD.orange : SD.panel)
                        .foregroundColor(control.muted ? .white : SD.dim)
                        .cornerRadius(4)
                }.buttonStyle(.plain)
                Button(action: { state.toggleStemSolo(name) }) {
                    Text("S").font(.system(size: 10, weight: .black, design: .monospaced))
                        .frame(width: 22, height: 18)
                        .background(control.soloed ? SD.gold : SD.panel)
                        .foregroundColor(control.soloed ? Color.black : SD.dim)
                        .cornerRadius(4)
                }.buttonStyle(.plain)
            }
            // Editable role — Auto (filename-detected) plus every role, fixing mis-detected stems.
            HStack(spacing: 6) {
                Text("ROLE").font(.system(size: 8, weight: .black, design: .monospaced)).foregroundColor(SD.dim)
                Picker("", selection: Binding(
                    get: { control.roleOverride },
                    set: { state.setStemRoleOverride(name, $0) })) {
                    Text("Auto · \(detected.label)").tag(MixEngine.StemRole?.none)
                    ForEach(MixEngine.StemRole.allCases) { role in
                        Text(role.label).tag(MixEngine.StemRole?.some(role))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
                if control.roleOverride != nil {
                    Text("override").font(.system(size: 8, weight: .bold)).foregroundColor(SD.gold)
                }
            }
            // Gain trim fader — feeds the mix on top of the automatic gain-stage.
            HStack(spacing: 6) {
                Text("GAIN").font(.system(size: 8, weight: .black, design: .monospaced)).foregroundColor(SD.dim)
                Slider(value: Binding(
                    get: { control.gainTrimDB },
                    set: { state.setStemGainTrim(name, $0) }), in: -12...12, step: 0.5)
                    .tint(SD.gold)
                Text(String(format: "%+.1f dB", control.gainTrimDB))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(SD.text).frame(width: 54, alignment: .trailing)
            }
            // What the engine applies to THIS stem (its own chain) — display-only transparency.
            VStack(alignment: .leading, spacing: 2) {
                Text("THIS STEM'S CHAIN")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundColor(SD.gold)
                    .padding(.top, 1)
                ForEach(MixEngine.treatmentSummary(for: effective), id: \.self) { line in
                    Text("• \(line)")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(SD.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(8)
        .background(control.muted ? SD.panelDeep.opacity(0.55) : SD.panelDeep)
        .cornerRadius(6)
    }

    /// Measured low-end clarity of the buyer's own track — fundamental, sub-rumble,
    /// mud, harshness, and stereo behaviour of the lows. Neutral flags, no advice.
    private var lowEndPanel: some View {
        StudioPanel(title: "Low-End Clarity", icon: "waveform.path") {
            if let r = state.result, r.lowEnd.hasData {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(r.lowEnd.rows) { row in
                        HStack {
                            Text(row.label)
                                .font(.system(size: 10, weight: .semibold)).foregroundColor(SD.text)
                            Spacer()
                            Text(row.value)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(row.flagged ? SD.orange : SD.dim)
                        }
                    }
                    if r.lowEnd.flags.isEmpty {
                        Text("No disproportionate bands measured.")
                            .font(.system(size: 9, weight: .medium)).foregroundColor(SD.dim)
                    }
                }
            } else {
                emptyText("Master to measure")
            }
        }
    }

    /// Punch: input vs output crest factor (peak-to-RMS), with a neutral note when the
    /// input's loudness was already limited upstream.
    private var crestPanel: some View {
        StudioPanel(title: "Punch / Crest", icon: "bolt.horizontal.circle") {
            if let r = state.result, r.crest.hasData {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(r.crest.rows) { row in
                        HStack {
                            Text(row.label)
                                .font(.system(size: 10, weight: .semibold)).foregroundColor(SD.text)
                            Spacer()
                            Text(row.value)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(row.flagged ? SD.orange : SD.dim)
                        }
                    }
                    if !r.crest.note.isEmpty {
                        Text(r.crest.note)
                            .font(.system(size: 9, weight: .medium)).foregroundColor(SD.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                emptyText("Master to measure")
            }
        }
    }

    private var readinessPanel: some View {
        StudioPanel(title: "Readiness", icon: "checkmark.seal") {
            if let report = state.doctorReport {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(SD.line, lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: CGFloat(report.score) / 100)
                            .stroke(scoreColor(report.score), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(report.score)")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                            .foregroundColor(SD.text)
                    }
                    .frame(width: 82, height: 82)
                    VStack(alignment: .leading, spacing: 5) {
                        metricLine("LUFS", String(format: "%.1f", report.metrics.integratedLUFS))
                        metricLine("TP", String(format: "%.1f", report.metrics.truePeakDBTP))
                        metricLine("LRA", String(format: "%.1f", report.metrics.loudnessRangeLU))
                        metricLine("Mono", String(format: "%.2f", report.metrics.monoCorrelation))
                    }
                }
                compactReleaseChecks
            } else {
                emptyText("No analysis")
            }
        }
    }

    private var compactReleaseChecks: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let report = state.doctorReport {
                ForEach(report.releaseChecks.prefix(7)) { check in
                    HStack(spacing: 8) {
                        Circle().fill(severityColor(check.severity)).frame(width: 7, height: 7)
                        Text(check.name).font(.system(size: 10, weight: .semibold)).foregroundColor(SD.text)
                        Spacer()
                        Text(check.value).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(SD.dim)
                    }
                }
            } else {
                emptyText("No gates")
            }
        }
    }

    private var translationPanel: some View {
        StudioPanel(title: "Translation", icon: "speaker.wave.2") {
            if let report = state.doctorReport {
                VStack(spacing: 8) {
                    ForEach(report.translations) { t in
                        HStack(spacing: 8) {
                            Text(t.device)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(SD.text)
                                .frame(width: 94, alignment: .leading)
                            ProgressView(value: Double(t.score), total: 100)
                                .tint(scoreColor(t.score))
                            Text("\(t.score)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(scoreColor(t.score))
                                .frame(width: 30, alignment: .trailing)
                            Button(action: { state.auditionTranslation(t) }) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(SD.gold)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else {
                emptyText("No previews")
            }
        }
    }

    private var referencePanel: some View {
        StudioPanel(title: "Reference DNA", icon: "target") {
            if let report = state.doctorReport, !report.referenceTraits.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(report.referenceTraits.prefix(6)) { trait in
                        HStack {
                            Text(trait.name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(SD.text)
                            Spacer()
                            Text(trait.delta)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(severityColor(trait.severity))
                        }
                    }
                }
            } else if let ref = state.linkReference {
                VStack(alignment: .leading, spacing: 7) {
                    metricLine("Source", ref.source)
                    metricLine("Target", ref.inferredStyle.name)
                    metricLine("Genre", ref.inferredStyle.genre.name)
                    metricLine("Drive", ref.inferredStyle.intensity.label)
                }
            } else {
                emptyText("No reference loaded")
            }
        }
    }

    private var stemConflictPanel: some View {
        StudioPanel(title: "Stem Heatmap", icon: "square.grid.3x1.below.line.grid.1x2") {
            if state.isAnalyzingStems {
                ProgressView().tint(SD.gold)
            } else if let lanes = state.doctorReport?.stemConflictReport?.lanes {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(lanes) { lane in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(lane.pair)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(SD.text)
                                Spacer()
                                Text(String(format: "%.0f%%", lane.severity * 100))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(scoreColor(Int(100 - lane.severity * 70)))
                            }
                            ProgressView(value: lane.severity, total: 1).tint(lane.severity > 0.55 ? SD.orange : SD.gold)
                        }
                    }
                }
            } else {
                emptyText("No stems")
            }
        }
    }

    private var matrixInspector: some View {
        Group {
            matrixDeck
            StudioPanel(title: "Platform Preview", icon: "antenna.radiowaves.left.and.right") {
                if let report = state.doctorReport {
                    VStack(spacing: 8) {
                        ForEach(report.platformEstimates) { estimate in
                            HStack {
                                Circle().fill(severityColor(estimate.severity)).frame(width: 7, height: 7)
                                Text(estimate.platform).font(.system(size: 10, weight: .bold)).foregroundColor(SD.text)
                                Spacer()
                                Text(String(format: "%.1f LUFS", estimate.estimatedPlaybackLUFS))
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(SD.dim)
                            }
                        }
                    }
                } else {
                    emptyText("No platform estimates")
                }
            }
        }
    }

    private var chainInspector: some View {
        StudioPanel(title: "Applied Chain", icon: "list.bullet.rectangle") {
            if let result = state.result {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(result.notes.prefix(18).enumerated()), id: \.offset) { _, note in
                        HStack(alignment: .top, spacing: 7) {
                            Circle().fill(SD.gold).frame(width: 5, height: 5).padding(.top, 5)
                            Text(note)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(SD.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                emptyText("No render")
            }
        }
    }

    // MARK: - Small Views

    private func waveRow(label: String, peaks: [Float], tint: Color, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(active ? SD.goldText : SD.dim)
            WaveformView(peaks: peaks, playhead: state.playhead, tint: tint,
                         onSeek: { state.seek(to: $0) })
                .frame(height: 42)
                .opacity(active ? 1 : 0.68)
        }
    }

    private func topMetric(_ label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 14, weight: .black, design: .monospaced))
                .foregroundColor(tint)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(SD.dim)
        }
        .frame(width: 58, alignment: .trailing)
    }

    private func statusTile(_ title: String, value: String, icon: String) -> some View {
        StudioPanel(title: title, icon: icon) {
            Text(value)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundColor(SD.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label.uppercased())
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(SD.dim)
        }
    }

    private func miniLine(_ icon: String, _ text: String, removeHelp: String? = nil, removeAction: (() -> Void)? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 10, weight: .bold)).foregroundColor(SD.gold)
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(SD.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let removeAction {
                Button(action: removeAction) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(SD.dim)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(removeHelp ?? "Remove")
            }
        }
    }

    private func meterRow(label: String, value: String, tint: Color) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(SD.dim)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(tint)
        }
    }

    private func metricLine(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(SD.dim)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(SD.text)
        }
    }

    private func styleGuideRows(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(notes.prefix(5).enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: 7) {
                    Circle().fill(SD.gold).frame(width: 5, height: 5).padding(.top, 5)
                    Text(note)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(SD.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func commandButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 10, weight: .bold))
            }
            .foregroundColor(SD.goldText)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SD.ink)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(SD.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Filled gold variant of `commandButton` for the single most important action (Export master).
    private func primaryCommand(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(title).font(.system(size: 10, weight: .black))
            }
            .foregroundColor(.black)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(SD.gold)
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func pickerLine(_ label: String, selection: Binding<String>, options: [(String, String)]) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(SD.dim)
                .frame(width: 62, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { opt in Text(opt.1).tag(opt.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(SD.gold)
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .foregroundColor(SD.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived State

    private var projectTitle: String {
        if let input = state.inputURL { return input.deletingPathExtension().lastPathComponent }
        if state.mode == .masterOnly && state.inputSignal != nil { return "Current Mix Bounce" }
        if !state.stemURLs.isEmpty { return "\(state.stemURLs.count) Stem Session" }
        return state.studioArea == .mix ? "New Mix" : "New Master"
    }

    private var projectSubtitle: String {
        "\(state.mode.label.uppercased())  /  \(state.selectedPlatform.name.uppercased())  /  \(state.selectedGenre.name.uppercased())"
    }

    private var inputHeadline: String {
        if state.inputURL != nil { return "Stereo Mix" }
        if state.mode == .masterOnly && state.inputSignal != nil { return "Mix Bounce" }
        if !state.stemURLs.isEmpty { return "Stem Session" }
        return "Drop Audio"
    }

    private var inputSubline: String {
        if let url = state.inputURL { return url.lastPathComponent }
        if state.mode == .masterOnly && state.inputSignal != nil { return "Created in Sunset Mixing" }
        if !state.stemURLs.isEmpty { return "\(state.stemURLs.count) files" }
        return "WAV, AIFF, MP3, FLAC"
    }

    private var scoreTint: Color {
        guard let score = state.doctorReport?.score else { return SD.dim }
        return scoreColor(score)
    }

    private var genreBinding: Binding<String> {
        Binding(get: { state.selectedGenre.id },
                set: { id in if let g = GenreTargets.all.first(where: { $0.id == id }) { state.selectedGenre = g } })
    }

    private var platformBinding: Binding<String> {
        Binding(get: { state.selectedPlatform.id },
                set: { id in if let p = PlatformTargets.all.first(where: { $0.id == id }) { state.selectedPlatform = p } })
    }

    private var tonePresetBinding: Binding<String> {
        Binding(get: { state.tonePresetID },
                set: { state.applyTonePreset(id: $0) })
    }

    private var loudnessProfileBinding: Binding<String> {
        Binding(get: { state.loudnessProfileID },
                set: { state.selectLoudnessProfile(id: $0) })
    }

    private var referenceStatus: String {
        if state.referenceURL != nil { return "Exact" }
        if state.linkReference != nil { return "Style" }
        return "None"
    }

    private var auditionLabel: String {
        switch state.auditionSource {
        case .original: return "SRC"
        case .master: return state.mode == .mixOnly ? "MIX" : "MASTER"
        case .translation: return state.translationAuditionName.uppercased()
        }
    }

    private func timeLabel(_ frac: Double) -> String {
        // Read the signal the transport will actually play, so the time always matches the audio
        // (in MIX that is the mix bounce, never the master).
        let sig = state.auditionSignal
        let frames = sig?.frameCount ?? 0
        let raw = sig?.sampleRate ?? 44_100
        let sampleRate = raw > 0 ? raw : 44_100
        let t = frac * (Double(frames) / sampleRate)
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func scoreColor(_ score: Int) -> Color {
        score >= 85 ? SD.green : (score >= 65 ? SD.orange : SD.red)
    }

    private func severityColor(_ s: DoctorSeverity) -> Color {
        switch s {
        case .pass: return SD.green
        case .info: return SD.gold
        case .warn: return SD.orange
        case .fail: return SD.red
        }
    }

    // MARK: - Actions

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

    private func exportProof() {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent ?? "Sunset"
        if let url = FilePanels.saveText(defaultName: "\(base) - Sunset proof.txt") {
            state.exportProof(to: url)
        }
    }

    private func exportMaster() {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent ?? "Sunset"
        let ext = state.exportFormat.fileExtension
        if let url = FilePanels.saveAudio(defaultName: "\(base) - Sunset master.\(ext)", ext: ext) {
            state.export(to: url)
        }
    }

    private func exportMix() {
        let base = state.stemURLs.first?.deletingPathExtension().lastPathComponent ?? "Sunset"
        let ext = state.exportFormat.fileExtension
        if let url = FilePanels.saveAudio(defaultName: "\(base) - Sunset mix.\(ext)", ext: ext) {
            state.exportMix(to: url)
        }
    }

    private func exportReportCard() {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent ?? "Sunset"
        if let url = FilePanels.saveText(defaultName: "\(base) - Sunset report card.txt") {
            state.exportReportCard(to: url)
        }
    }

    private func exportBundle() {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent ?? "Sunset"
        if let url = FilePanels.saveWav(defaultName: "\(base) - Sunset release.wav") {
            state.exportReleaseBundle(to: url)
        }
    }

    private func exportMasterProof() {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent ?? "Sunset"
        if let url = FilePanels.saveText(defaultName: "\(base) - Sunset proof.txt") {
            state.exportMasterProof(to: url)
        }
    }

    private func exportDeliveryPack() {
        guard let dir = FilePanels.chooseFolder() else { return }
        state.exportDeliveryPack(to: dir)
    }

    private func batchAction() {
        let files = FilePanels.openAudio(multiple: true)
        guard !files.isEmpty else { return }
        guard let dir = FilePanels.chooseFolder() else { return }
        state.batchMaster(files, outputDir: dir)
    }

    private func saveSessionAction() {
        let base = state.inputURL?.deletingPathExtension().lastPathComponent
            ?? (state.stemURLs.isEmpty ? "Sunset" : "\(state.stemURLs.count) stems")
        if let url = FilePanels.saveJSON(defaultName: "\(base) - Sunset session.json") {
            state.saveSession(to: url)
        }
    }

    private func loadSessionAction() {
        if let url = FilePanels.openJSON() { state.loadSession(from: url) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let u = item as? URL { url = u }
                else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            MainActor.assumeIsolated {
                if urls.count > 1 { state.loadStems(urls) }
                else { state.loadInput(urls[0]) }
            }
        }
    }
}

// StudioPanel + the SD palette moved to UI/StudioTheme.swift (shared with the
// Phase-2 MIX console and MASTER chain views).
#endif // circuit-convert
