#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MasterChainView.swift — the MASTER area's explicit chain panel (Phase 2 of
// SUNSET-EFFECTS-STANDARD), in spec order:
//   EQ → Multiband → Dynamic EQ → Saturation / Exciter → Imager + M/S → Soft Clipper →
//   Limiter → Dither.
// The guided default (genre / platform / intensity / reference matching) KEEPS running —
// this panel is the manual layer on top. Stages 2–6 live in MasterChainSettings and apply
// to the bounce before the engine; the Soft Clipper / Limiter / Dither rows surface the
// engine's own controls, so nothing here duplicates DSP or fakes a number.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct MasterChainView: View {
    @EnvironmentObject var state: AppState

    private var chain: Binding<MasterChainSettings> {
        Binding(get: { state.masterChain }, set: { state.masterChain = $0 })
    }

    var body: some View {
        StudioPanel(title: "Master Chain (manual layer)", icon: "wand.and.rays") {
            VStack(alignment: .leading, spacing: 9) {
                header
                stageEQ
                Divider().overlay(SD.line)
                stageMultiband
                Divider().overlay(SD.line)
                stageDynamicEQ
                Divider().overlay(SD.line)
                stageSaturation
                Divider().overlay(SD.line)
                stageImaging
                Divider().overlay(SD.line)
                stageClipLimitDither
            }
        }
    }

    private var header: some View {
        HStack {
            Text("The guided master (genre / platform / intensity / reference) keeps running — these stages layer on top and start bypassed.")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(SD.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Menu("Preset") {
                ForEach(MasterChainPresets.menu, id: \.name) { p in
                    Button(p.name) { state.masterChain = p.chain }
                }
                Button("Bypass all") { state.masterChain = .neutral }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .font(.system(size: 9, weight: .bold))
        }
    }

    private func stageHeader(_ n: Int, _ title: String, stage: MasterChainStage?) -> some View {
        HStack(spacing: 7) {
            Text("\(n)")
                .font(.system(size: 9, weight: .black, design: .rounded))
                .foregroundColor(.black)
                .frame(width: 16, height: 16)
                .background(SD.gold)
                .clipShape(Circle())
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .black, design: .monospaced))
                .foregroundColor(SD.goldText)
            Spacer()
            if let stage, state.masterChain.isStageActive(stage) {
                Button(action: { state.auditionMasterStageBypass(stage) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 8, weight: .bold))
                        Text("A/B").font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                    .foregroundColor(SD.gold)
                }
                .buttonStyle(.plain)
                .disabled(state.mode != .masterOnly || state.inputSignal == nil)
                .help("Render the master WITHOUT this stage onto the Translation slot, gain-matched — flip the A/B picker to hear exactly what it contributes.")
            }
        }
    }

    // 1 — EQ
    private var stageEQ: some View {
        let c = chain
        return VStack(alignment: .leading, spacing: 6) {
            stageHeader(1, "EQ", stage: .eq)
            SDSlider(label: "Low 100", value: c.eqLowDB, range: -12...12, step: 0.5)
            SDSlider(label: "Mid 1k", value: c.eqMidDB, range: -12...12, step: 0.5)
            SDSlider(label: "High 10k", value: c.eqHighDB, range: -12...12, step: 0.5)
            Text("Your 5-band Tone control (left rail) also rides the guided layer — this EQ is the surgical manual band on the bounce itself.")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(SD.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // 2 — Multiband
    private var stageMultiband: some View {
        let c = chain
        return VStack(alignment: .leading, spacing: 6) {
            stageHeader(2, "Multiband Compressor", stage: .multiband)
            SDToggle(label: "Extra multiband glue", isOn: c.multibandEnabled)
            if c.wrappedValue.multibandEnabled {
                SDSlider(label: "Amount", value: c.multibandAmountDB, range: 1...12, step: 0.5, format: "%.1f")
                Text("Pushes the 3-band 2:1 glue threshold this far under the measured program level. The applied gain reduction is measured and reported in Chain.")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(SD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // 3 — Dynamic EQ
    private var stageDynamicEQ: some View {
        let c = chain
        return VStack(alignment: .leading, spacing: 6) {
            stageHeader(3, "Dynamic EQ", stage: .dynamicEQ)
            SDToggle(label: "Dynamic EQ", isOn: Binding(
                get: { c.wrappedValue.dynamicEQ.enabled },
                set: { on in
                    var v = c.wrappedValue
                    v.dynamicEQ.enabled = on
                    if on && v.dynamicEQ.bands.isEmpty {
                        v.dynamicEQ.bands = [DynamicEQBand(freq: 3500, thresholdDB: -22)]
                    }
                    state.masterChain = v
                }))
            if c.wrappedValue.dynamicEQ.enabled {
                DynamicEQBandsEditor(settings: Binding(
                    get: { c.wrappedValue.dynamicEQ },
                    set: { var v = c.wrappedValue; v.dynamicEQ = $0; state.masterChain = v }))
            }
        }
    }

    // 4 — Saturation / Exciter
    private var stageSaturation: some View {
        let c = chain
        return VStack(alignment: .leading, spacing: 6) {
            stageHeader(4, "Saturation / Exciter", stage: .saturation)
            SDToggle(label: "Saturation", isOn: c.saturation.enabled)
            if c.wrappedValue.saturation.enabled {
                HStack(spacing: 8) {
                    Picker("", selection: c.saturation.mode) {
                        ForEach(SaturationMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).tint(SD.gold).frame(maxWidth: 140)
                    Spacer()
                }
                SDSlider(label: "Drive", value: c.saturation.driveDB, range: 0...12, step: 0.5, format: "%.1f")
                SDSlider(label: "Mix", value: c.saturation.mix, range: 0...1, step: 0.05, format: "%.0f", unit: "%", displayScale: 100)
            }
            SDToggle(label: "Exciter", isOn: c.exciter.enabled)
            if c.wrappedValue.exciter.enabled {
                SDSlider(label: "Presence", value: c.exciter.presenceAmount, range: 0...0.6, step: 0.02, format: "%.0f", unit: "%", displayScale: 100)
                SDSlider(label: "Air", value: c.exciter.airAmount, range: 0...0.6, step: 0.02, format: "%.0f", unit: "%", displayScale: 100)
            }
        }
    }

    // 5 — Imager + M/S
    private var stageImaging: some View {
        let c = chain
        return VStack(alignment: .leading, spacing: 6) {
            stageHeader(5, "Stereo Imager + M/S", stage: .imaging)
            SDToggle(label: "Imager", isOn: c.imagerEnabled)
            if c.wrappedValue.imagerEnabled {
                SDSlider(label: "Width", value: c.imagerWidth, range: 0.5...1.6, step: 0.05, format: "%.2f", unit: "")
                SDSlider(label: "Mono <", value: c.imagerMonoBelowHz, range: 60...240, step: 5, format: "%.0f", unit: "Hz")
            }
            SDToggle(label: "Mid / Side", isOn: c.midSide.enabled)
            if c.wrappedValue.midSide.enabled {
                SDSlider(label: "Mid", value: c.midSide.midGainDB, range: -6...6, step: 0.25)
                SDSlider(label: "Side", value: c.midSide.sideGainDB, range: -6...6, step: 0.25)
            }
        }
    }

    // 6/7/8 — Soft Clipper / Limiter / Dither (the engine's own controls, surfaced in order)
    private var stageClipLimitDither: some View {
        VStack(alignment: .leading, spacing: 6) {
            stageHeader(6, "Soft Clipper", stage: nil)
            SDToggle(label: "Soft clip (pre-limiter, 4× oversampled)", isOn: Binding(
                get: { state.softClipEnabled }, set: { state.softClipEnabled = $0 }))
            if state.softClipEnabled {
                SDSlider(label: "Drive",
                         value: Binding(get: { state.softClipDriveDB }, set: { state.softClipDriveDB = $0 }),
                         range: 0.5...3, step: 0.05, format: "%.2f")
                if let r = state.result, r.softClip.enabled {
                    Text(String(format: "Measured last render: %.2f dB clipped on %.1f%% of samples.",
                                r.softClip.dBClipped, r.softClip.percentClipped))
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(SD.dim)
                }
            }
            Divider().overlay(SD.line)
            stageHeader(7, "Limiter", stage: nil)
            HStack {
                Text("Ceiling \(String(format: "%.1f dBTP", state.selectedPlatform.truePeakDBTP)) — owned by the platform target; loudness by Intensity / profile (left rail). The limiter's measured gain reduction is reported in Chain.")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(SD.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(SD.line)
            stageHeader(8, "Dither", stage: nil)
            Text("Noise-shaped TPDF to 24-bit on every render (16-bit exports re-dither at export). Always on — the honest last stage.")
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(SD.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif // circuit-convert
