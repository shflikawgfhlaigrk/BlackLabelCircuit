#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// StudioTheme.swift — the shared Sunset studio palette + panel chrome.
// Extracted from StudioDashboardView so the MIX console and MASTER chain views
// (Phase 2) speak the exact same visual language.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

enum SD {
    static let bg = Color(red: 0.055, green: 0.075, blue: 0.220)        // #0e1338
    static let panelDeep = Color(red: 0.059, green: 0.039, blue: 0.118) // #0f0a1e
    static let panel = Color(red: 0.125, green: 0.067, blue: 0.180)     // #20112e
    static let ink = Color(red: 0.101, green: 0.075, blue: 0.180)
    static let line = Color(red: 1.000, green: 0.878, blue: 0.627).opacity(0.16)
    static let text = Color(red: 0.957, green: 0.925, blue: 0.875)      // #f4ecdf
    static let dim = Color(red: 0.735, green: 0.672, blue: 0.690)
    static let gold = Color(red: 1.000, green: 0.722, blue: 0.416)      // #ffb86a
    static let goldText = Color(red: 1.000, green: 0.808, blue: 0.522)  // #ffce85
    static let blue = Color(red: 1.000, green: 0.565, blue: 0.290)      // #ff904a
    static let green = Color(red: 1.000, green: 0.878, blue: 0.627)     // #ffe0a0
    static let orange = Color(red: 0.890, green: 0.365, blue: 0.333)    // #e35d55
    static let red = Color(red: 0.870, green: 0.215, blue: 0.305)
}

struct StudioPanel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(SD.gold)
                    .frame(width: 18)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(SD.dim)
                Spacer()
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SD.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(SD.line, lineWidth: 1))
    }
}

// MARK: - Shared micro-controls (Phase 2 consoles)

/// A labeled slider row in the studio idiom: LABEL — slider — monospaced value.
struct SDSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    var format: String = "%+.1f"
    var unit: String = "dB"
    /// Display multiplier (e.g. 100 to show a 0…1 mix as a percentage).
    var displayScale: Double = 1

    var body: some View {
        HStack(spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .foregroundColor(SD.dim)
                .frame(width: 58, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .tint(SD.gold)
            Text(String(format: format, value * displayScale) + (unit.isEmpty ? "" : " \(unit)"))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(SD.text)
                .frame(width: 64, alignment: .trailing)
        }
    }
}

/// A compact stage-enable toggle in the studio idiom.
struct SDToggle: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(SD.text)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(SD.gold)
    }
}

// MARK: - Phase 4: full dynamic-EQ band editor (shared by the strip + MASTER consoles)

/// Add/remove/edit every DynamicEQBand field (shape, mode, freq, Q, threshold, ratio,
/// attack, release, range), capped at `DynamicEQSettings.maxUserBands`. Ranges mirror
/// the DynamicEQBand clamps. Both the MIX strips and the MASTER chain use this editor,
/// so the two areas speak the same band language.
struct DynamicEQBandsEditor: View {
    @Binding var settings: DynamicEQSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("BANDS (\(settings.bands.count)/\(DynamicEQSettings.maxUserBands))")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundColor(SD.dim)
                Spacer()
                if settings.bands.count < DynamicEQSettings.maxUserBands {
                    Button(action: { settings.addBand() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle").font(.system(size: 9, weight: .bold))
                            Text("Add band").font(.system(size: 9, weight: .bold))
                        }
                        .foregroundColor(SD.goldText)
                    }
                    .buttonStyle(.plain)
                }
            }
            ForEach(Array(settings.bands.enumerated()), id: \.offset) { idx, _ in
                bandRows(idx)
            }
        }
    }

    @ViewBuilder private func bandRows(_ idx: Int) -> some View {
        if settings.bands.indices.contains(idx) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("BAND \(idx + 1)")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .foregroundColor(SD.goldText)
                    Picker("", selection: field(idx, \.shape)) {
                        Text("Bell").tag(DynamicEQShape.bell)
                        Text("Lo shelf").tag(DynamicEQShape.lowShelf)
                        Text("Hi shelf").tag(DynamicEQShape.highShelf)
                    }
                    .labelsHidden().pickerStyle(.menu).tint(SD.gold).fixedSize()
                    Picker("", selection: field(idx, \.mode)) {
                        Text("Cut").tag(DynamicEQMode.cut)
                        Text("Boost").tag(DynamicEQMode.boost)
                    }
                    .labelsHidden().pickerStyle(.segmented).tint(SD.gold).frame(maxWidth: 110)
                    Spacer()
                    Button(action: { settings.removeBand(at: idx) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(SD.dim)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this band")
                }
                SDSlider(label: "Freq", value: field(idx, \.freq), range: 60...12_000, step: 10, format: "%.0f", unit: "Hz")
                SDSlider(label: "Q", value: field(idx, \.q), range: 0.3...10, step: 0.1, format: "%.1f", unit: "")
                SDSlider(label: "Threshold", value: field(idx, \.thresholdDB), range: -60 ... -6, step: 1, format: "%.0f")
                SDSlider(label: "Ratio", value: field(idx, \.ratio), range: 1...10, step: 0.5, format: "%.1f", unit: ": 1")
                SDSlider(label: "Attack", value: field(idx, \.attackMs), range: 0.1...50, step: 0.1, format: "%.1f", unit: "ms")
                SDSlider(label: "Release", value: field(idx, \.releaseMs), range: 5...500, step: 5, format: "%.0f", unit: "ms")
                SDSlider(label: "Range", value: field(idx, \.maxGainDB), range: 1...24, step: 0.5, format: "%.1f")
            }
            .padding(7)
            .background(SD.panelDeep.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    /// Index-safe binding into one band field (a stale row during remove reads defaults).
    private func field<T>(_ idx: Int, _ keyPath: WritableKeyPath<DynamicEQBand, T>) -> Binding<T> {
        Binding(
            get: {
                settings.bands.indices.contains(idx)
                    ? settings.bands[idx][keyPath: keyPath]
                    : DynamicEQBand(freq: 1000)[keyPath: keyPath]
            },
            set: { v in
                guard settings.bands.indices.contains(idx) else { return }
                settings.bands[idx][keyPath: keyPath] = v
            })
    }
}
#endif // circuit-convert
