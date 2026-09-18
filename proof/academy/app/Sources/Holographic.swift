#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Academy — holographic FX kit.
// Rules: decorative layers NEVER eat input (.allowsHitTesting(false));
// motion gates on the user toggle AND system Reduce Motion; static frame when off.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct AuroraBackdrop: View {
    @AppStorage("bl.motion") private var motion = false
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        let animate = motion && !reduce
        ZStack {
            BLTheme.bg.ignoresSafeArea()
            TimelineView(.animation(paused: !animate)) { tl in
                let t = animate ? tl.date.timeIntervalSinceReferenceDate : 0
                ZStack {
                    blob(BLTheme.goldBase.opacity(0.30), dx: sin(t * 0.05), dy: cos(t * 0.045), align: .topLeading)
                    blob(BLTheme.goldDim.opacity(0.22), dx: cos(t * 0.04), dy: sin(t * 0.05), align: .bottomTrailing)
                    blob(BLTheme.cyan.opacity(0.12), dx: sin(t * 0.03), dy: cos(t * 0.06), align: .center)
                }
            }
            .blur(radius: 90)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
    private func blob(_ c: Color, dx: Double, dy: Double, align: Alignment) -> some View {
        Circle().fill(c)
            .frame(width: 480, height: 480)
            .offset(x: dx * 70, y: dy * 70)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: align)
    }
}

extension View {
    func holoCard(radius: CGFloat = 16) -> some View {
        self
            .background(BLTheme.panelGrad)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [BLTheme.goldBase.opacity(0.5), BLTheme.stroke.opacity(0.4), BLTheme.cyan.opacity(0.22)],
                            startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            )
            .shadow(color: BLTheme.goldBase.opacity(0.12), radius: 12, y: 3)
    }
}

struct FoilText: View {
    let text: String
    var size: CGFloat = 28
    var weight: Font.Weight = .bold
    var body: some View {
        Text(text)
            .font(.system(size: size, weight: weight, design: .serif))
            .foregroundStyle(BLTheme.goldGrad)
            .shadow(color: BLTheme.goldBase.opacity(0.30), radius: 6)
    }
}
#endif // circuit-convert
