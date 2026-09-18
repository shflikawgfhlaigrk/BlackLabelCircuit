#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Theme / Appearance Studio.
// The buyer's full control surface for the holographic look, with a LIVE PREVIEW pane.
// Everything here is purely visual customization persisted in Prefs (HoloTheme + custom
// presets). It applies app-wide instantly because the whole FX kit reads \.holoTheme,
// which RootView injects from prefs.holoTheme. Reduce Motion hard-overrides motion.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

// MARK: - Theme Studio panel (drop into Settings)

struct ThemeStudioPanel: View {
    @EnvironmentObject var prefs: Prefs
    @State private var newPresetName = ""
    @State private var saved = ""
    @State private var backgroundError = ""
    @State private var showBackgroundImporter = false

    // A live binding to the persisted theme so every control re-skins the app instantly.
    private var t: Binding<HoloTheme> { $prefs.holoTheme }

    var body: some View {
        Panel(title: "Theme / Appearance Studio", icon: "paintpalette.fill") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Own the look. Every control below re-skins the entire app instantly — accent, holographic intensity, motion, particles, background and depth. Reduce Motion always wins over the motion settings.")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)

                // ── LIVE PREVIEW ──────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("LIVE PREVIEW").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                    ThemePreview()
                        // The preview always renders with the in-progress theme.
                        .environment(\.holoTheme, prefs.holoTheme)
                        .frame(height: 188)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                }

                // ── PRESETS ───────────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("PRESETS").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                    let active = prefs.holoTheme.matchingPresetName
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 10)], spacing: 10) {
                        ForEach(HoloTheme.presets, id: \.name) { preset in
                            PresetChip(name: preset.name, theme: preset.theme, selected: active == preset.name) {
                                withAnimation(.easeOut(duration: 0.25)) { prefs.applyHoloTheme(preset.theme) }
                            }
                        }
                    }
                }

                Divider().overlay(BLTheme.stroke)

                // ── ACCENT ────────────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Text("ACCENT").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                    HStack(spacing: 12) {
                        // Built-in accent swatches drive the full accent triad.
                        ForEach(accentSwatches, id: \.0) { name, hex, hi, dim in
                            Button {
                                t.wrappedValue.accentHex = hex; t.wrappedValue.accentHiHex = hi; t.wrappedValue.accentDimHex = dim
                            } label: {
                                Circle().fill(Color(hex: hex)).frame(width: 26, height: 26)
                                    .overlay(Circle().stroke(Color.white.opacity(prefs.holoTheme.accentHex == hex ? 0.95 : 0.2), lineWidth: prefs.holoTheme.accentHex == hex ? 2 : 1))
                                    .shadow(color: Color(hex: hex).opacity(0.5), radius: prefs.holoTheme.accentHex == hex ? 8 : 0)
                            }.buttonStyle(.plain).help(name)
                                .accessibilityLabel("\(name) accent")
                                .accessibilityAddTraits(prefs.holoTheme.accentHex == hex ? .isSelected : [])
                        }
                        Spacer()
                        // Custom color picker — round-trips through holoHex.
                        ColorPicker("", selection: Binding(
                            get: { prefs.holoTheme.accent },
                            set: { c in
                                let h = c.holoHex
                                t.wrappedValue.accentHex = h
                                t.wrappedValue.accentHiHex = c.lighter(by: 0.18).holoHex
                                t.wrappedValue.accentDimHex = c.lighter(by: -0.0).holoHex   // base; dim derived by opacity in FX
                            }), supportsOpacity: false)
                            .labelsHidden().help("Custom accent color").accessibilityLabel("Custom accent color")
                    }
                    // Secondary iridescent hue (used in borders/sheens).
                    HStack(spacing: 10) {
                        Text("Iridescent hue").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        Spacer()
                        ColorPicker("", selection: Binding(
                            get: { prefs.holoTheme.iridescent },
                            set: { t.wrappedValue.iridescentHex = $0.holoHex }), supportsOpacity: false)
                            .labelsHidden().help("Secondary iridescent shimmer hue").accessibilityLabel("Iridescent hue")
                    }
                }

                Divider().overlay(BLTheme.stroke)

                // ── INTENSITY / MOTION / BACKGROUND ───────────────────────────
                segmentRow("HOLO INTENSITY", help: "Scales border iridescence, sheen and glow.",
                           selection: t.intensity, cases: HoloIntensity.allCases, label: { $0.label })
                segmentRow("MOTION LEVEL", help: "Drift / breathing / particle speed. Reduce Motion still overrides.",
                           selection: t.motion, cases: HoloMotion.allCases, label: { $0.label })
                segmentRow("BACKGROUND", help: "Aurora, starfield, solid, or the custom image below.",
                           selection: t.background, cases: HoloBackground.allCases, label: { $0.label })

                VStack(alignment: .leading, spacing: 10) {
                    Text("CUSTOM BACKGROUND").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                    HStack(spacing: 10) {
                        GoldButton(label: prefs.holoBackgroundData == nil ? "Choose image" : "Replace image",
                                   icon: "photo.on.rectangle.angled") { chooseBackgroundImage() }
                        if prefs.holoBackgroundData != nil {
                            GhostButton(label: "Remove", icon: "trash", tint: BLTheme.danger) {
                                withAnimation { prefs.clearHoloBackground() }
                                flash("Background removed.")
                            }
                        }
                        Spacer()
                        Label(prefs.holoBackgroundData == nil ? "No image" : "Custom image active",
                              systemImage: prefs.holoBackgroundData == nil ? "rectangle.dashed" : "photo.fill")
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundColor(prefs.holoBackgroundData == nil ? BLTheme.sub : BLTheme.green)
                    }
                    if !backgroundError.isEmpty {
                        Label(backgroundError, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundColor(BLTheme.danger)
                    }
                }

                Divider().overlay(BLTheme.stroke)

                // ── SLIDERS / TOGGLES ─────────────────────────────────────────
                sliderRow("Particle density", value: t.particleDensity, range: 0...1,
                          readout: prefs.holoTheme.particleCount == 0 ? "Off" : "\(prefs.holoTheme.particleCount) motes")
                sliderRow("Glow strength", value: t.glowStrength, range: 0...1,
                          readout: pct(prefs.holoTheme.glowStrength))

                Toggle(isOn: t.tiltEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Card 3D tilt").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("Off by default for crisp text. On, cards lean toward the pointer on hover.").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }.tint(BLTheme.gold)
                if prefs.holoTheme.tiltEnabled {
                    sliderRow("Tilt strength", value: t.tiltStrength, range: 0...1, readout: pct(prefs.holoTheme.tiltStrength))
                }

                Divider().overlay(BLTheme.stroke)

                // ── SAVE / LOAD CUSTOM LOOKS ──────────────────────────────────
                VStack(alignment: .leading, spacing: 10) {
                    Text("YOUR SAVED LOOKS").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                    HStack {
                        Field(title: "Look name", text: $newPresetName, prompt: "My brand look")
                        GoldButton(label: "Save current", icon: "plus") {
                            prefs.saveCurrentHoloPreset(named: newPresetName); newPresetName = ""; flash("Look saved.")
                        }
                    }
                    if prefs.holoPresets.isEmpty {
                        Text("Tune the look above, then save it here to reuse it across clients.")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    } else {
                        ForEach(prefs.holoPresets) { p in
                            HStack(spacing: 10) {
                                Circle().fill(p.theme.accent).frame(width: 16, height: 16)
                                    .overlay(Circle().stroke(p.theme.iridescent.opacity(0.7), lineWidth: 1))
                                Text(p.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                Spacer()
                                GhostButton(label: "Apply", icon: "arrow.down.circle") { withAnimation { prefs.applyHoloPreset(p) }; flash("Applied \(p.name).") }
                                IconButton(system: "trash", tint: BLTheme.danger) { prefs.deleteHoloPreset(p) }
                            }
                            .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                        }
                    }
                    HStack {
                        GhostButton(label: "Reset look to Gold Vault", icon: "arrow.counterclockwise") {
                            withAnimation { prefs.resetHoloTheme() }; flash("Look reset.")
                        }
                        if !saved.isEmpty {
                            Label(saved, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                        }
                        Spacer()
                    }
                }
            }
        }
        #if os(iOS)
        .fileImporter(isPresented: $showBackgroundImporter, allowedContentTypes: [.png, .jpeg, .image], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importBackgroundImage(url)
        }
        #endif
    }

    private let accentSwatches: [(String, UInt32, UInt32, UInt32)] = [
        ("Gold", 0xD9B65C, 0xF2D98A, 0xB8923A),
        ("Champagne", 0xD4C5A0, 0xEDE6D2, 0xA89878),
        ("Platinum", 0xD8DBE0, 0xFFFFFF, 0x9AA0A8),
        ("Cyan", 0x4FD7FF, 0xA6F0FF, 0x2E9BBF),
        ("Emerald", 0x5FCF95, 0xA9EFC8, 0x2E9D67),
        ("Royal", 0x9A8FE0, 0xC6BEFF, 0x6453C0),
        ("Crimson", 0xE0606A, 0xF2A2A8, 0xB83A44),
    ]

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    @ViewBuilder private func segmentRow<E: Hashable & Identifiable>(_ title: String, help: String, selection: Binding<E>, cases: [E], label: @escaping (E) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            Picker("", selection: selection) {
                ForEach(cases) { c in Text(label(c)).tag(c) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel(title)
            Text(help).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
        }
    }

    @ViewBuilder private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, readout: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Text(readout).font(BLFonts.mono(11, weight: .bold)).foregroundColor(BLTheme.gold)
            }
            Slider(value: value, in: range).tint(BLTheme.gold).accessibilityLabel(title).accessibilityValue(readout)
        }
    }

    private func flash(_ m: String) {
        saved = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if saved == m { saved = "" } }
    }

    private func chooseBackgroundImage() {
        backgroundError = ""
        #if os(iOS)
        showBackgroundImporter = true
        #else
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            importBackgroundImage(url)
        }
        #endif
    }

    private func importBackgroundImage(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard imageLooksValid(data) else {
                backgroundError = "That file is not a readable image."
                return
            }
            withAnimation {
                prefs.holoBackgroundData = data
                prefs.holoTheme.background = .customImage
            }
            backgroundError = ""
            flash("Background applied.")
        } catch {
            backgroundError = "That image couldn't be used — try a PNG or JPG. (\(error.localizedDescription))"
        }
    }

    private func imageLooksValid(_ data: Data) -> Bool {
        #if canImport(AppKit)
        return NSImage(data: data) != nil
        #elseif canImport(UIKit)
        return UIImage(data: data) != nil
        #else
        return !data.isEmpty
        #endif
    }
}

// MARK: - Preset chip (a swatchy one-click named look)

struct PresetChip: View {
    let name: String
    let theme: HoloTheme
    let selected: Bool
    let tap: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 8) {
                // Mini swatch row showing the look's palette.
                HStack(spacing: 4) {
                    ForEach([theme.accent, theme.accentHi, theme.iridescent, theme.accentDim], id: \.self) { c in
                        RoundedRectangle(cornerRadius: 3).fill(c).frame(height: 18)
                    }
                }
                Text(name).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(selected ? theme.accent.opacity(0.12) : BLTheme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(selected ? theme.accent.opacity(0.8) : (hover ? BLTheme.gold.opacity(0.4) : BLTheme.stroke), lineWidth: selected ? 1.6 : 1))
            .shadow(color: selected ? theme.accent.opacity(0.3) : .clear, radius: 8)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Live preview pane (renders the kit with the in-progress theme)

struct ThemePreview: View {
    @Environment(\.holoTheme) private var theme
    var body: some View {
        ZStack {
            AuroraBackdrop().allowsHitTesting(false)
            ParticleField().allowsHitTesting(false)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    FoilText("Aa Studio", size: 26)
                    Text("Holographic preview").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                        Text("Primary").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.inkOnGold)
                    }
                    .padding(.vertical, 8).padding(.horizontal, 14)
                    .background(BLTheme.goldGrad).clipShape(Capsule())
                    .iridescentBorder(radius: 20).glowPulse().holoSheen()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("METRIC").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(1)
                    AnimatedCounter(value: 1280, font: .system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(BLTheme.goldText)
                    HoloShimmerSkeleton(width: 90, height: 10)
                }
                .padding(16)
                .holoCard(radius: 14)
            }
            .padding(16)
        }
    }
}
#endif // circuit-convert
