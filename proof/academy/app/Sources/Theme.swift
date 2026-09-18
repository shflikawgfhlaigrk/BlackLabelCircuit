#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Academy — premium gold/holographic design system.
// Matches the Black Label fleet (BLTheme palette, no hover scaleEffect, SheetCloseBar).
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension View {
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}

enum BLTheme {
    static let bg     = Color(hex: 0x050505)
    static let bg2    = Color(hex: 0x0B0B0B)
    static let bg3    = Color(hex: 0x121212)
    static let line   = Color(hex: 0x1F1F1F)
    static let stroke = Color(hex: 0x2A2A2A)
    static let text   = Color(hex: 0xE8E6E1)
    static let sub    = Color(hex: 0x8A8680)
    static let goldBase = Color(hex: 0xC9A961)
    static let goldDim  = Color(hex: 0x8A7340)
    static let goldLite = Color(hex: 0xF9E27D)
    static let cyan   = Color(hex: 0x4FD7FF)
    static let green  = Color(hex: 0x4FD8A6)
    static let red    = Color(hex: 0xE56B6B)
    static let amber  = Color(hex: 0xE8B04B)

    static var goldGrad: LinearGradient {
        LinearGradient(colors: [goldLite, goldBase, goldDim], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var panelGrad: LinearGradient {
        LinearGradient(colors: [bg3.opacity(0.62), bg2.opacity(0.92)], startPoint: .top, endPoint: .bottom)
    }
}

// Primary gold CTA. Hover cue is a growing glow — NEVER scaleEffect (resampling softens text).
struct GoldButton: View {
    let label: String
    var fill = false
    var icon = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !icon.isEmpty { Image(systemName: icon) }
                Text(label)
            }
            .font(.system(size: 13.5, weight: .bold, design: .rounded))
            .foregroundColor(Color(hex: 0x0A0A0A))
            .padding(.vertical, 11).padding(.horizontal, 18)
            .frame(maxWidth: fill ? .infinity : nil)
            .background(BLTheme.goldGrad)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: 0xFFF8E0).opacity(0.22), lineWidth: 0.5))
            .shadow(color: BLTheme.goldBase.opacity(hover ? 0.55 : 0.30), radius: hover ? 18 : 10, y: hover ? 5 : 3)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
    }
}

struct GhostButton: View {
    let label: String
    var icon = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if !icon.isEmpty { Image(systemName: icon) }
                Text(label)
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(hover ? BLTheme.goldLite : BLTheme.text)
            .padding(.vertical, 9).padding(.horizontal, 15)
            .background(BLTheme.bg2, in: Capsule())
            .overlay(Capsule().stroke(BLTheme.goldBase.opacity(hover ? 0.55 : 0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

struct EmptyState: View {
    let icon: String
    let title: String
    let hint: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 34, weight: .light))
                .foregroundStyle(BLTheme.goldGrad)
                .frame(width: 76, height: 76)
                .background(Circle().fill(BLTheme.goldBase.opacity(0.08)))
                .overlay(Circle().stroke(BLTheme.goldBase.opacity(0.25), lineWidth: 1))
            Text(title).font(.system(size: 19, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            Text(hint).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 26)
    }
}

// Esc-bound close bar for sheets (fixes the "no way back" defect).
struct SheetCloseBar: View {
    var title: String = ""
    let dismiss: () -> Void
    var body: some View {
        HStack {
            if !title.isEmpty {
                Text(title).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            Button(action: dismiss) {
                HStack(spacing: 5) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                    Text("Close").font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundColor(BLTheme.text)
                .padding(.vertical, 6).padding(.horizontal, 11)
                .background(BLTheme.bg2, in: Capsule())
                .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 2)
    }
}

struct Tag: View {
    let text: String
    var color: Color = BLTheme.goldBase
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundColor(color)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.30), lineWidth: 0.5))
    }
}
#endif // circuit-convert
