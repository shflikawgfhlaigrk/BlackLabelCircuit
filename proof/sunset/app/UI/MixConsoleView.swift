#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MixConsoleView.swift — the MIX area (Phase 2 of SUNSET-EFFECTS-STANDARD).
//
// Per-stem channel strips in spec signal order (Gain/Trim → Gate/Expander → EQ → Compressor
// → De-Esser → Saturation → Dynamic EQ → Transient Shaper → Pan → Width/Haas → insert slots
// → sends), the three role buses (drums / instruments / vocals) with glue compression,
// parallel blend and the generalized ducker, and the project's shared wet-only Reverb +
// Delay returns. Every stage defaults to bypassed: with everything neutral the render is
// bit-for-bit the automatic engine — user settings layer ON TOP, they never replace it.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct MixConsoleView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            if state.stemDisplayNames.isEmpty {
                emptyConsole
            } else {
                consoleHeader
                ForEach(state.stemDisplayNames, id: \.self) { name in
                    StemStripCard(name: name)
                }
                busDeck
                sendsDeck
            }
        }
    }

    // MARK: - Empty state (honest — no fabricated console)

    private var emptyConsole: some View {
        StudioPanel(title: "Mix Console", icon: "slider.vertical.3") {
            VStack(alignment: .leading, spacing: 10) {
                Text("MIX works per stem — load stems to open the console.")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SD.text)
                Text("Each stem gets its own channel strip (gate, EQ, compressor, de-esser, saturation, dynamic EQ, transient shaper, width, inserts, sends), routed through drum / instrument / vocal buses. Everything starts bypassed — the automatic mix engine stays in charge until you reach for a control.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(SD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var consoleHeader: some View {
        StudioPanel(title: "Mix Console", icon: "slider.vertical.3") {
            Text("Every stage below starts BYPASSED — the automatic engine (gain-staging, role EQ, masking carves, kick ducking) keeps running underneath; your settings layer on top of it, exactly like role/gain/pan overrides already do.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(SD.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Buses

    private var busDeck: some View {
        StudioPanel(title: "Buses", icon: "point.3.connected.trianglepath.dotted") {
            VStack(spacing: 10) {
                ForEach(BusRole.allCases) { role in
                    BusCard(role: role)
                }
            }
        }
    }

    // MARK: - Sends

    private var sendsDeck: some View {
        StudioPanel(title: "Send Returns (shared, wet-only)", icon: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 10) {
                Text("One reverb + one delay return for the whole project. Per-stem send levels live on each strip; returns are always wet-only.")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(SD.dim)
                    .fixedSize(horizontal: false, vertical: true)
                reverbReturn
                Divider().overlay(SD.line)
                delayReturn
            }
        }
    }

    private var reverbReturn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("REVERB RETURN")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(SD.goldText)
                Spacer()
                Picker("", selection: Binding(
                    get: { state.mixSession.sends.reverb.preset },
                    set: { state.mixSession.sends.reverb.preset = $0 })) {
                    ForEach(ReverbPreset.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).tint(SD.gold).frame(maxWidth: 120)
            }
            SDSlider(label: "Decay",
                     value: Binding(get: { state.mixSession.sends.reverb.decaySeconds },
                                    set: { state.mixSession.sends.reverb.decaySeconds = $0 }),
                     range: 0.2...8, step: 0.1, format: "%.1f", unit: "s")
            SDSlider(label: "Predelay",
                     value: Binding(get: { state.mixSession.sends.reverb.predelayMs },
                                    set: { state.mixSession.sends.reverb.predelayMs = $0 }),
                     range: 0...120, step: 1, format: "%.0f", unit: "ms")
            SDSlider(label: "Return",
                     value: Binding(get: { state.mixSession.sends.reverbReturnDB },
                                    set: { state.mixSession.sends.reverbReturnDB = $0 }),
                     range: -24...6, step: 0.5)
        }
    }

    private var delayReturn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("DELAY RETURN")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(SD.goldText)
                Spacer()
                Picker("", selection: Binding(
                    get: { state.mixSession.sends.delay.mode },
                    set: { state.mixSession.sends.delay.mode = $0 })) {
                    ForEach(DelayMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).tint(SD.gold).frame(maxWidth: 120)
            }
            SDSlider(label: "Time",
                     value: Binding(get: { state.mixSession.sends.delay.timeMs },
                                    set: { state.mixSession.sends.delay.timeMs = $0 }),
                     range: 20...1200, step: 5, format: "%.0f", unit: "ms")
            SDSlider(label: "Feedback",
                     value: Binding(get: { state.mixSession.sends.delay.feedback },
                                    set: { state.mixSession.sends.delay.feedback = $0 }),
                     range: 0...0.9, step: 0.05, format: "%.2f", unit: "")
            SDSlider(label: "Return",
                     value: Binding(get: { state.mixSession.sends.delayReturnDB },
                                    set: { state.mixSession.sends.delayReturnDB = $0 }),
                     range: -24...6, step: 0.5)
        }
    }
}

// MARK: - One bus card

private struct BusCard: View {
    @EnvironmentObject var state: AppState
    let role: BusRole

    private var bus: Binding<BusSettings> {
        Binding(get: { state.busSettings(role) }, set: { state.setBusSettings(role, $0) })
    }

    var body: some View {
        let b = bus
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(role.label.uppercased())
                    .font(.system(size: 9.5, weight: .black, design: .monospaced))
                    .foregroundColor(SD.goldText)
                Spacer()
                if role == .drums {
                    Menu("Preset") {
                        Button("Drum bus glue") { state.setBusSettings(role, BusPresets.drumGlue) }
                        Button("Parallel crush") { state.setBusSettings(role, BusPresets.parallelCrush) }
                        Button("Bypass") { state.setBusSettings(role, .neutral) }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.system(size: 9, weight: .bold))
                }
            }
            SDToggle(label: "Bus compressor (glue)", isOn: b.compressorEnabled)
            if b.wrappedValue.compressorEnabled {
                SDSlider(label: "Threshold", value: b.compressor.thresholdDB, range: -40...0, step: 0.5, format: "%.0f")
                SDSlider(label: "Ratio", value: b.compressor.ratio, range: 1...10, step: 0.5, format: "%.1f", unit: ": 1")
                SDSlider(label: "Blend", value: b.parallelWet, range: 0...1, step: 0.05, format: "%.0f", unit: "%", displayScale: 100)
                    .help("1.0 = the compressor sits fully in line; lower = parallel (NY) compression blended under the dry bus.")
            }
            SDToggle(label: "Duck this bus", isOn: b.duckEnabled)
            if b.wrappedValue.duckEnabled {
                HStack(spacing: 8) {
                    Text("SOURCE")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundColor(SD.dim)
                        .frame(width: 58, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { b.wrappedValue.duckSource },
                        set: { var v = b.wrappedValue; v.duckSource = $0; state.setBusSettings(role, v) })) {
                        Text("Pick a trigger").tag(DuckSource?.none)
                        ForEach(state.stemDisplayNames, id: \.self) { name in
                            Text("Stem: \(name)").tag(DuckSource?.some(.stem(name)))
                        }
                        ForEach(BusRole.allCases.filter { $0 != role }) { other in
                            Text(other.label).tag(DuckSource?.some(.bus(other)))
                        }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(SD.gold)
                }
                SDSlider(label: "Depth", value: b.ducker.depthDB, range: 0...24, step: 0.5, format: "%.1f")
                SDSlider(label: "Release", value: b.ducker.releaseMs, range: 20...600, step: 5, format: "%.0f", unit: "ms")
            }
        }
        .padding(9)
        .background(SD.panelDeep)
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - One channel strip

private struct StemStripCard: View {
    @EnvironmentObject var state: AppState
    let name: String
    @State private var expanded = false

    private var strip: Binding<StemStripSettings> {
        Binding(get: { state.stemStrip(name) }, set: { state.setStemStrip(name, $0) })
    }

    var body: some View {
        let s = strip
        let control = state.stemControl(name)
        StudioPanel(title: name, icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 8) {
                // Header: role + active-stage count + presets + expand.
                HStack(spacing: 8) {
                    Text(state.effectiveStemRole(name).label.uppercased())
                        .font(.system(size: 8.5, weight: .black, design: .monospaced))
                        .foregroundColor(SD.dim)
                    if activeStageCount > 0 {
                        Text("\(activeStageCount) STAGE\(activeStageCount == 1 ? "" : "S") ON")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .foregroundColor(SD.goldText)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(SD.gold.opacity(0.14)).clipShape(Capsule())
                    }
                    Spacer()
                    Menu("Preset") {
                        ForEach(StripPresets.menu, id: \.name) { p in
                            Button(p.name) { state.setStemStrip(name, p.strip) }
                        }
                        Button("Bypass all") { state.setStemStrip(name, .neutral) }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .font(.system(size: 9, weight: .bold))
                    Button(action: { expanded.toggle() }) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(SD.gold)
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Collapse the strip" : "Open the full channel strip")
                }

                // Always-visible: gain / pan (the strip's head) + sends.
                SDSlider(label: "Gain",
                         value: Binding(get: { control.gainTrimDB },
                                        set: { state.setStemGainTrim(name, $0) }),
                         range: -12...12, step: 0.5)
                SDSlider(label: "Pan",
                         value: Binding(get: { control.panOverride ?? 0 },
                                        set: { v in
                                            var c = state.stemControl(name)
                                            c.panOverride = abs(v) < 0.001 ? nil : v
                                            state.stemControls[name] = c
                                        }),
                         range: -1...1, step: 0.05, format: "%+.2f", unit: "")
                    .help("0 = automatic placement (centered roles stay centered). Any other value is a constant-power user pan that wins over the engine.")

                if expanded {
                    stageRows(s)
                }

                HStack(spacing: 10) {
                    SDSlider(label: "Rev send", value: s.sendReverb, range: 0...1, step: 0.05, format: "%.0f", unit: "%", displayScale: 100)
                    SDSlider(label: "Dly send", value: s.sendDelay, range: 0...1, step: 0.05, format: "%.0f", unit: "%", displayScale: 100)
                }
            }
        }
    }

    private var activeStageCount: Int {
        let s = strip.wrappedValue
        var n = 0
        if s.gate.enabled { n += 1 }
        if s.isStageActive(.eq) { n += 1 }
        if s.compressorEnabled { n += 1 }
        if s.deEsser.enabled { n += 1 }
        if s.saturation.enabled { n += 1 }
        if s.dynamicEQ.enabled { n += 1 }
        if s.transient.enabled { n += 1 }
        if s.widener.enabled { n += 1 }
        n += s.inserts.filter { $0.isEnabled }.count
        return n
    }

    // Phase 4: the per-stage on-demand A/B (one re-render with the stage bypassed onto the
    // Translation slot — the strip-side sibling of the MASTER chain's stage A/B).
    @ViewBuilder private func stripABButton(_ stage: StripStage, _ s: Binding<StemStripSettings>) -> some View {
        if s.wrappedValue.isStageActive(stage) {
            Button(action: { state.auditionStripStageBypass(name, stage) }) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 7, weight: .bold))
                    Text("A/B").font(.system(size: 8, weight: .bold, design: .monospaced))
                }
                .foregroundColor(SD.gold)
            }
            .buttonStyle(.plain)
            .disabled(state.mode != .mixOnly || state.stemURLs.isEmpty || state.isProcessing)
            .help("One re-render of the mix WITHOUT this stage onto the Translation slot, gain-matched — flip the A/B picker to hear exactly what it contributes. Renders only when you tap.")
        }
    }

    // The strip's stages, in spec signal order.
    @ViewBuilder private func stageRows(_ s: Binding<StemStripSettings>) -> some View {
        Divider().overlay(SD.line)

        // Gate / Expander
        HStack(spacing: 6) {
            SDToggle(label: "Gate / Expander", isOn: s.gate.enabled)
            stripABButton(.gate, s)
        }
        if s.wrappedValue.gate.enabled {
            HStack(spacing: 8) {
                Picker("", selection: s.gate.mode) {
                    ForEach(GateExpanderMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).tint(SD.gold).frame(maxWidth: 170)
                Spacer()
            }
            SDSlider(label: "Threshold", value: s.gate.thresholdDB, range: -80 ... -10, step: 1, format: "%.0f")
            SDSlider(label: "Release", value: s.gate.releaseMs, range: 20...500, step: 5, format: "%.0f", unit: "ms")
        }

        // EQ (user layer: 3 fixed bands + fully-editable extra bands, 8 total)
        HStack(spacing: 6) {
            SDToggle(label: "EQ (user layer)", isOn: Binding(
                get: { s.wrappedValue.isStageActive(.eq) },
                set: { on in
                    var v = s.wrappedValue
                    if !on {
                        v.eqLowDB = 0; v.eqMidDB = 0; v.eqHighDB = 0
                        for i in v.eqExtraBands.indices { v.eqExtraBands[i].enabled = false }
                    } else if !v.isStageActive(.eq) {
                        v.eqHighDB = 0.5
                    }
                    state.setStemStrip(name, v)
                }))
            stripABButton(.eq, s)
        }
        SDSlider(label: "Low 120", value: s.eqLowDB, range: -12...12, step: 0.5)
        SDSlider(label: "Mid 800", value: s.eqMidDB, range: -12...12, step: 0.5)
        SDSlider(label: "High 8k", value: s.eqHighDB, range: -12...12, step: 0.5)
        eqBandRows(s)

        // Compressor
        HStack(spacing: 6) {
            SDToggle(label: "Compressor", isOn: s.compressorEnabled)
            stripABButton(.compressor, s)
        }
        if s.wrappedValue.compressorEnabled {
            SDSlider(label: "Threshold", value: s.compressor.thresholdDB, range: -50...0, step: 0.5, format: "%.0f")
            SDSlider(label: "Ratio", value: s.compressor.ratio, range: 1...12, step: 0.5, format: "%.1f", unit: ": 1")
            SDSlider(label: "Attack", value: s.compressor.attackMs, range: 0.5...80, step: 0.5, format: "%.1f", unit: "ms")
            SDSlider(label: "Release", value: s.compressor.releaseMs, range: 20...500, step: 5, format: "%.0f", unit: "ms")
        }

        // De-Esser
        HStack(spacing: 6) {
            SDToggle(label: "De-Esser", isOn: s.deEsser.enabled)
            stripABButton(.deEsser, s)
        }
        if s.wrappedValue.deEsser.enabled {
            SDSlider(label: "Threshold", value: s.deEsser.thresholdDB, range: -60 ... -10, step: 1, format: "%.0f")
            SDSlider(label: "Max cut", value: s.deEsser.maxReductionDB, range: 1...24, step: 0.5, format: "%.0f")
        }

        // Saturation
        HStack(spacing: 6) {
            SDToggle(label: "Saturation", isOn: s.saturation.enabled)
            stripABButton(.saturation, s)
        }
        if s.wrappedValue.saturation.enabled {
            HStack(spacing: 8) {
                Picker("", selection: s.saturation.mode) {
                    ForEach(SaturationMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).tint(SD.gold).frame(maxWidth: 140)
                Spacer()
            }
            SDSlider(label: "Drive", value: s.saturation.driveDB, range: 0...24, step: 0.5, format: "%.1f")
            SDSlider(label: "Mix", value: s.saturation.mix, range: 0...1, step: 0.05, format: "%.0f", unit: "%", displayScale: 100)
        }

        // Dynamic EQ (full band editor, up to 4 bands)
        HStack(spacing: 6) {
            SDToggle(label: "Dynamic EQ", isOn: Binding(
                get: { s.wrappedValue.dynamicEQ.enabled },
                set: { on in
                    var v = s.wrappedValue
                    v.dynamicEQ.enabled = on
                    if on && v.dynamicEQ.bands.isEmpty {
                        v.dynamicEQ.bands = [DynamicEQBand(freq: 300, thresholdDB: -24)]
                    }
                    state.setStemStrip(name, v)
                }))
            stripABButton(.dynamicEQ, s)
        }
        if s.wrappedValue.dynamicEQ.enabled {
            DynamicEQBandsEditor(settings: Binding(
                get: { s.wrappedValue.dynamicEQ },
                set: { var v = s.wrappedValue; v.dynamicEQ = $0; state.setStemStrip(name, v) }))
        }

        // Transient shaper
        HStack(spacing: 6) {
            SDToggle(label: "Transient Shaper", isOn: s.transient.enabled)
            stripABButton(.transient, s)
        }
        if s.wrappedValue.transient.enabled {
            SDSlider(label: "Attack", value: s.transient.attackGainDB, range: -18...18, step: 0.5)
            SDSlider(label: "Sustain", value: s.transient.sustainGainDB, range: -18...18, step: 0.5)
        }

        // Width / Haas
        HStack(spacing: 6) {
            SDToggle(label: "Width (Haas)", isOn: s.widener.enabled)
            stripABButton(.widener, s)
        }
        if s.wrappedValue.widener.enabled {
            SDSlider(label: "Delay", value: s.widener.delayMs, range: 0.5...30, step: 0.5, format: "%.1f", unit: "ms")
            SDSlider(label: "Mix", value: s.widener.mix, range: 0...1, step: 0.05, format: "%.0f", unit: "%", displayScale: 100)
        }

        // Insert slots
        insertRows(s)
    }

    // Phase 4: extra user EQ bands — add/remove/edit type, freq, Q, gain.
    @ViewBuilder private func eqBandRows(_ s: Binding<StemStripSettings>) -> some View {
        HStack {
            Text("EXTRA BANDS (\(s.wrappedValue.eqExtraBands.count)/\(StemStripSettings.maxExtraEQBands))")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(SD.dim)
            Spacer()
            if s.wrappedValue.eqExtraBands.count < StemStripSettings.maxExtraEQBands {
                Button(action: {
                    var v = s.wrappedValue
                    v.addEQBand()
                    state.setStemStrip(name, v)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle").font(.system(size: 9, weight: .bold))
                        Text("Add band").font(.system(size: 9, weight: .bold))
                    }
                    .foregroundColor(SD.goldText)
                }
                .buttonStyle(.plain)
            }
        }
        ForEach(s.wrappedValue.eqExtraBands) { band in
            EQBandEditorRow(
                band: Binding(
                    get: { s.wrappedValue.eqExtraBands.first { $0.id == band.id } ?? .peak(1000, 0, 1.0) },
                    set: { v in
                        var strip = s.wrappedValue
                        if let i = strip.eqExtraBands.firstIndex(where: { $0.id == band.id }) {
                            strip.eqExtraBands[i] = v
                        }
                        state.setStemStrip(name, strip)
                    }),
                onRemove: {
                    var v = s.wrappedValue
                    v.removeEQBand(id: band.id)
                    state.setStemStrip(name, v)
                })
        }
    }

    @ViewBuilder private func insertRows(_ s: Binding<StemStripSettings>) -> some View {
        HStack {
            Text("INSERTS")
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(SD.dim)
            Spacer()
            Menu {
                ForEach(InsertEffect.menu) { fx in
                    Button(fx.label) {
                        var v = s.wrappedValue
                        v.inserts.append(fx)
                        state.setStemStrip(name, v)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle").font(.system(size: 9, weight: .bold))
                    Text("Add insert").font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(SD.goldText)
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        ForEach(Array(s.wrappedValue.inserts.enumerated()), id: \.offset) { idx, _ in
            InsertSlotRow(name: name, index: idx, strip: s)
        }
    }
}

// MARK: - One insert slot (Phase 4: enable / A/B / remove + full parameter editing)

/// One insert row: enable dot, label, A/B, disclosure into the kind's REAL parameters
/// (built from the shared `InsertParam`/`InsertChoice` descriptor tables), plus the
/// harmonizer/resonator voice editors. Every control writes back through
/// `state.setStemStrip`, so edits persist with the session and drive the render.
private struct InsertSlotRow: View {
    @EnvironmentObject var state: AppState
    let name: String
    let index: Int
    let strip: Binding<StemStripSettings>
    @State private var expanded = false

    private var current: InsertEffect? {
        let v = strip.wrappedValue
        return v.inserts.indices.contains(index) ? v.inserts[index] : nil
    }

    private func mutate(_ transform: (inout InsertEffect) -> Void) {
        var v = strip.wrappedValue
        guard v.inserts.indices.contains(index) else { return }
        transform(&v.inserts[index])
        state.setStemStrip(name, v)
    }

    var body: some View {
        if let fx = current {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Button(action: { mutate { $0.setEnabled(!fx.isEnabled) } }) {
                        Circle().fill(fx.isEnabled ? SD.gold : SD.dim).frame(width: 7, height: 7)
                    }
                    .buttonStyle(.plain)
                    .help(fx.isEnabled ? "Bypass this insert" : "Enable this insert")
                    Text(fx.label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(SD.text)
                    if !fx.isEnabled {
                        Text("BYPASSED")
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .foregroundColor(SD.dim)
                    }
                    Spacer()
                    if fx.isEnabled {
                        Button(action: { state.auditionStripStageBypass(name, .insert(index)) }) {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.left.arrow.right").font(.system(size: 7, weight: .bold))
                                Text("A/B").font(.system(size: 8, weight: .bold, design: .monospaced))
                            }
                            .foregroundColor(SD.gold)
                        }
                        .buttonStyle(.plain)
                        .disabled(state.mode != .mixOnly || state.stemURLs.isEmpty || state.isProcessing)
                        .help("One re-render of the mix WITHOUT this insert onto the Translation slot, gain-matched.")
                    }
                    Button(action: { expanded.toggle() }) {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(SD.gold)
                    }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide parameters" : "Edit parameters")
                    Button(action: {
                        var v = strip.wrappedValue
                        if v.inserts.indices.contains(index) { v.inserts.remove(at: index) }
                        state.setStemStrip(name, v)
                    }) {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(SD.dim)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this insert")
                }
                if expanded {
                    paramRows(fx)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(SD.panelDeep.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    @ViewBuilder private func paramRows(_ fx: InsertEffect) -> some View {
        ForEach(fx.choices) { choice in
            HStack(spacing: 8) {
                Text(choice.label.uppercased())
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundColor(SD.dim)
                    .frame(width: 58, alignment: .leading)
                Picker("", selection: Binding(
                    get: { current.map(choice.get) ?? 0 },
                    set: { i in mutate { choice.set(&$0, i) } })) {
                    ForEach(choice.options.indices, id: \.self) { i in
                        Text(choice.options[i]).tag(i)
                    }
                }
                .labelsHidden().pickerStyle(.menu).tint(SD.gold).fixedSize()
                Spacer()
            }
        }
        ForEach(fx.params) { p in
            SDSlider(label: p.label,
                     value: Binding(
                        get: { current.map(p.get) ?? p.range.lowerBound },
                        set: { v in mutate { p.set(&$0, v) } }),
                     range: p.range, step: p.step, format: p.format,
                     unit: p.unit, displayScale: p.displayScale)
        }
        if case .harmonizer = fx {
            HarmonizerVoicesEditor(name: name, index: index, strip: strip)
        }
        if case .resonator = fx {
            ResonatorVoicesEditor(name: name, index: index, strip: strip)
        }
    }
}

// MARK: - Harmonizer voices (Phase 4)

/// Add/remove/edit up to `HarmonizerSettings.maxVoices` harmony voices — interval kind
/// (fixed semitones or diatonic scale degrees), value, gain, pan, per-voice enable.
private struct HarmonizerVoicesEditor: View {
    @EnvironmentObject var state: AppState
    let name: String
    let index: Int
    let strip: Binding<StemStripSettings>

    private var settings: HarmonizerSettings? {
        let v = strip.wrappedValue
        guard v.inserts.indices.contains(index) else { return nil }
        return v.inserts[index].harmonizerSettings
    }

    private func mutate(_ transform: (inout HarmonizerSettings) -> Void) {
        var v = strip.wrappedValue
        guard v.inserts.indices.contains(index),
              var s = v.inserts[index].harmonizerSettings else { return }
        transform(&s)
        v.inserts[index].setHarmonizer(s)
        state.setStemStrip(name, v)
    }

    var body: some View {
        if let s = settings {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("VOICES (\(s.voices.count)/\(HarmonizerSettings.maxVoices))")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundColor(SD.dim)
                    Spacer()
                    if s.voices.count < HarmonizerSettings.maxVoices {
                        Button(action: { mutate { $0.addVoice() } }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.circle").font(.system(size: 9, weight: .bold))
                                Text("Add voice").font(.system(size: 9, weight: .bold))
                            }
                            .foregroundColor(SD.goldText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(Array(s.voices.enumerated()), id: \.offset) { vi, voice in
                    voiceRows(vi, voice)
                }
            }
        }
    }

    @ViewBuilder private func voiceRows(_ vi: Int, _ voice: HarmonyVoice) -> some View {
        let isDegrees: Bool = { if case .scaleDegrees = voice.interval { return true }; return false }()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: { mutate { s in
                    guard s.voices.indices.contains(vi) else { return }
                    s.voices[vi].enabled.toggle()
                } }) {
                    Circle().fill(voice.enabled ? SD.gold : SD.dim).frame(width: 6, height: 6)
                }
                .buttonStyle(.plain)
                .help(voice.enabled ? "Mute this voice" : "Enable this voice")
                Text("VOICE \(vi + 1)")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundColor(SD.goldText)
                Picker("", selection: Binding(
                    get: { isDegrees ? 1 : 0 },
                    set: { m in mutate { s in
                        guard s.voices.indices.contains(vi) else { return }
                        s.voices[vi].interval = m == 1 ? .scaleDegrees(2) : .semitones(7)
                    } })) {
                    Text("Semitones").tag(0)
                    Text("Scale deg").tag(1)
                }
                .labelsHidden().pickerStyle(.segmented).tint(SD.gold).frame(maxWidth: 160)
                Spacer()
                Button(action: { mutate { s in
                    guard s.voices.indices.contains(vi) else { return }
                    s.voices.remove(at: vi)
                } }) {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(SD.dim)
                }
                .buttonStyle(.plain)
                .help("Remove this voice")
            }
            SDSlider(label: "Interval",
                     value: Binding(
                        get: {
                            switch voice.interval {
                            case .semitones(let st): return Double(st)
                            case .scaleDegrees(let d): return Double(d)
                            }
                        },
                        set: { v in mutate { s in
                            guard s.voices.indices.contains(vi) else { return }
                            s.voices[vi].interval = isDegrees
                                ? .scaleDegrees(Int(v.rounded()))
                                : .semitones(Int(v.rounded()))
                        } }),
                     range: isDegrees ? -7...7 : -24...24, step: 1, format: "%+.0f",
                     unit: isDegrees ? "deg" : "st")
            SDSlider(label: "Gain",
                     value: Binding(
                        get: { voice.gainDB },
                        set: { v in mutate { s in
                            guard s.voices.indices.contains(vi) else { return }
                            s.voices[vi].gainDB = v
                        } }),
                     range: -24...12, step: 0.5)
            SDSlider(label: "Pan",
                     value: Binding(
                        get: { voice.pan },
                        set: { v in mutate { s in
                            guard s.voices.indices.contains(vi) else { return }
                            s.voices[vi].pan = v
                        } }),
                     range: -1...1, step: 0.05, format: "%+.2f", unit: "")
        }
        .padding(6)
        .background(SD.panelDeep.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - Resonator voices (Phase 4)

/// Add/remove/edit up to 8 resonator voices — frequency, decay, gain per voice.
private struct ResonatorVoicesEditor: View {
    @EnvironmentObject var state: AppState
    let name: String
    let index: Int
    let strip: Binding<StemStripSettings>

    private var settings: ResonatorSettings? {
        let v = strip.wrappedValue
        guard v.inserts.indices.contains(index) else { return nil }
        return v.inserts[index].resonatorSettings
    }

    private func mutate(_ transform: (inout ResonatorSettings) -> Void) {
        var v = strip.wrappedValue
        guard v.inserts.indices.contains(index),
              var s = v.inserts[index].resonatorSettings else { return }
        transform(&s)
        v.inserts[index].setResonator(s)
        state.setStemStrip(name, v)
    }

    var body: some View {
        if let s = settings {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("VOICES (\(s.voices.count)/\(ResonatorSettings.maxVoices))")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundColor(SD.dim)
                    Spacer()
                    if s.voices.count < ResonatorSettings.maxVoices {
                        Button(action: { mutate { $0.addVoice() } }) {
                            HStack(spacing: 4) {
                                Image(systemName: "plus.circle").font(.system(size: 9, weight: .bold))
                                Text("Add voice").font(.system(size: 9, weight: .bold))
                            }
                            .foregroundColor(SD.goldText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                ForEach(Array(s.voices.enumerated()), id: \.offset) { vi, voice in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("VOICE \(vi + 1)")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .foregroundColor(SD.goldText)
                            Spacer()
                            Button(action: { mutate { r in
                                guard r.voices.indices.contains(vi) else { return }
                                r.voices.remove(at: vi)
                            } }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(SD.dim)
                            }
                            .buttonStyle(.plain)
                            .help("Remove this voice")
                        }
                        SDSlider(label: "Freq",
                                 value: voiceField(vi, get: { $0.freqHz }, set: { $0.freqHz = $1 }, fallback: voice.freqHz),
                                 range: 20...8000, step: 5, format: "%.0f", unit: "Hz")
                        SDSlider(label: "Decay",
                                 value: voiceField(vi, get: { $0.decaySeconds }, set: { $0.decaySeconds = $1 }, fallback: voice.decaySeconds),
                                 range: 0.05...10, step: 0.05, format: "%.2f", unit: "s")
                        SDSlider(label: "Gain",
                                 value: voiceField(vi, get: { $0.gain }, set: { $0.gain = $1 }, fallback: voice.gain),
                                 range: 0...2, step: 0.05, format: "%.2f", unit: "")
                    }
                    .padding(6)
                    .background(SD.panelDeep.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    private func voiceField(_ vi: Int,
                            get: @escaping (ResonatorVoice) -> Double,
                            set: @escaping (inout ResonatorVoice, Double) -> Void,
                            fallback: Double) -> Binding<Double> {
        Binding(
            get: {
                guard let s = settings, s.voices.indices.contains(vi) else { return fallback }
                return get(s.voices[vi])
            },
            set: { v in mutate { r in
                guard r.voices.indices.contains(vi) else { return }
                set(&r.voices[vi], v)
            } })
    }
}

// MARK: - One extra EQ band (Phase 4)

/// Full band editing for one user EQ band: type, freq, Q, gain (pass filters hide gain),
/// per-band enable, remove.
private struct EQBandEditorRow: View {
    @Binding var band: EQBand
    let onRemove: () -> Void

    private var isPassFilter: Bool { band.kindRaw == 3 || band.kindRaw == 4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button(action: { band.enabled.toggle() }) {
                    Circle().fill(band.enabled ? SD.gold : SD.dim).frame(width: 6, height: 6)
                }
                .buttonStyle(.plain)
                .help(band.enabled ? "Bypass this band" : "Enable this band")
                Picker("", selection: $band.kindRaw) {
                    Text("Peak").tag(0)
                    Text("Low shelf").tag(1)
                    Text("High shelf").tag(2)
                    Text("High pass").tag(3)
                    Text("Low pass").tag(4)
                }
                .labelsHidden().pickerStyle(.menu).tint(SD.gold).fixedSize()
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(SD.dim)
                }
                .buttonStyle(.plain)
                .help("Remove this band")
            }
            SDSlider(label: "Freq", value: $band.freq, range: 20...16_000, step: 10, format: "%.0f", unit: "Hz")
            if !isPassFilter {
                SDSlider(label: "Gain", value: $band.gainDB, range: -12...12, step: 0.5)
            }
            SDSlider(label: "Q", value: $band.q, range: 0.3...10, step: 0.1, format: "%.2f", unit: "")
        }
        .padding(7)
        .background(SD.panelDeep.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
#endif // circuit-convert
