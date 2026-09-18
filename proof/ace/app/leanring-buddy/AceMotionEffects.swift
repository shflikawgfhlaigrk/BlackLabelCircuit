#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// A calligraphic accent shares the finite flight and docking clock. The
/// compact gem remains the primary status indicator throughout the action.
struct AceLivingInk: View {
    let movement: Double
    let dock: Double
    let intensity: AceMotionIntensity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Canvas { context, size in
            guard !reduceMotion else { return }
            let fold = min(1, max(0, dock))
            let opacity = (1 - fold) * (0.55 + intensity.energy * 0.45)
            guard opacity > 0 else { return }
            let morph = AceMotionPolicy.lightEnergy(movement, reduceMotion: reduceMotion)
            let color = DS.Colors.agentGold
            let pearl = DS.Colors.agentGoldBright
            func point(_ horizontal: Double, _ vertical: Double) -> CGPoint {
                CGPoint(x: size.width / 2 + horizontal * (1 - fold * 0.68),
                        y: size.height / 2 + vertical * (1 - fold * 0.94))
            }
            var ink = Path()
            ink.move(to: point(-7 - morph * 3, 3 * (1 - morph)))
            ink.addCurve(to: point(6, -1.5 * (1 - morph)),
                control1: point(-6, -6 * (1 - morph)),
                control2: point(5, -7 * (1 - morph)))
            ink.addCurve(to: point(0, 2 * (1 - morph)),
                control1: point(9, 4 * (1 - morph)),
                control2: point(-1, 5 * (1 - morph)))
            context.drawLayer { shadow in
                shadow.translateBy(x: 1 - fold, y: 2.8 - fold * 2)
                shadow.addFilter(.blur(radius: 1.7 - fold))
                shadow.stroke(ink, with: .color(.black.opacity(0.7 * opacity)),
                    style: StrokeStyle(lineWidth: 3.1, lineCap: .round, lineJoin: .round))
            }
            context.stroke(ink, with: .color(DS.Colors.agentGoldDeep.opacity(opacity)),
                style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
            context.stroke(ink, with: .linearGradient(Gradient(stops: [
                .init(color: color.opacity(0.75 * opacity), location: 0),
                .init(color: pearl.opacity(opacity), location: 0.32),
                .init(color: color.opacity(opacity), location: 0.63),
                .init(color: .white.opacity(opacity), location: 0.86),
                .init(color: color.opacity(0.5 * opacity), location: 1)]),
                startPoint: point(-9, -4), endPoint: point(9, 4)),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
            context.translateBy(x: -0.15, y: -0.45)
            context.stroke(ink, with: .color(.white.opacity(0.32 * opacity)),
                style: StrokeStyle(lineWidth: 0.42, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 30, height: 26)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One transient gesture, derived from the current real target. Surface light
/// is clipped to verified bounds and never captures input or moves the control.
struct AceInkAnnotation: View {
    let gesture: AceInkGesture
    let progress: Double
    let intensity: AceMotionIntensity
    let reduceMotion: Bool

    var body: some View {
        Canvas { context, _ in
            let visibleProgress = reduceMotion ? 1 : progress
            if let surface = gesture.surface {
                context.drawLayer { light in
                    light.clip(to: Path(roundedRect: surface, cornerRadius: min(7, surface.height / 3)))
                    let center = CGPoint(x: surface.midX, y: surface.maxY)
                    light.fill(Path(surface), with: .radialGradient(
                        Gradient(colors: [DS.Colors.agentGoldBright.opacity(0.14 * visibleProgress * intensity.energy), .clear]),
                        center: center, startRadius: 0, endRadius: max(20, surface.width * 0.7)))
                    var highlight = Path()
                    highlight.move(to: CGPoint(x: surface.minX + 4, y: surface.minY + 0.8))
                    highlight.addLine(to: CGPoint(x: surface.maxX - 4, y: surface.minY + 0.8))
                    light.stroke(highlight, with: .color(.white.opacity(0.2 * visibleProgress)), lineWidth: 0.7)
                }
            }
            var path = Path()
            path.move(to: gesture.start)
            path.addQuadCurve(to: gesture.end, control: gesture.control)
            var visible = path.trimmedPath(from: 0, to: visibleProgress)
            if gesture.kind == .arrow && visibleProgress > 0.85 {
                let finish = min(1, (visibleProgress - 0.85) / 0.15)
                let angle = atan2(gesture.end.y - gesture.control.y, gesture.end.x - gesture.control.x)
                visible.move(to: CGPoint(x: gesture.end.x - cos(angle - 0.6) * 7 * finish,
                    y: gesture.end.y - sin(angle - 0.6) * 7 * finish))
                visible.addLine(to: gesture.end)
                visible.addLine(to: CGPoint(x: gesture.end.x - cos(angle + 0.6) * 7 * finish,
                    y: gesture.end.y - sin(angle + 0.6) * 7 * finish))
            }
            context.drawLayer { shadow in
                shadow.translateBy(x: 0, y: 1.3)
                shadow.addFilter(.blur(radius: 1.4))
                shadow.stroke(visible, with: .color(.black.opacity(0.48)),
                    style: StrokeStyle(lineWidth: 2.7, lineCap: .round, lineJoin: .round))
            }
            context.stroke(visible, with: .linearGradient(
                Gradient(colors: [DS.Colors.agentGold.opacity(0.5), DS.Colors.agentGoldBright,
                    DS.Colors.agentGold.opacity(0.9)]), startPoint: gesture.start, endPoint: gesture.end),
                style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct AceFlightTrail: View {
    let points: [CGPoint]
    let intensity: AceMotionIntensity

    var body: some View {
        Canvas { context, _ in
            guard points.count > 1 else { return }
            func ribbon(width: CGFloat) -> Path {
                var left: [CGPoint] = []
                var right: [CGPoint] = []
                for index in points.indices {
                    let previous = points[max(0, index - 1)]
                    let next = points[min(points.count - 1, index + 1)]
                    let length = max(0.001, hypot(next.x - previous.x, next.y - previous.y))
                    let thickness = CGFloat(index) / CGFloat(points.count - 1) * width * intensity.energy
                    let normalX = -(next.y - previous.y) / length * thickness
                    let normalY = (next.x - previous.x) / length * thickness
                    left.append(CGPoint(x: points[index].x + normalX, y: points[index].y + normalY))
                    right.append(CGPoint(x: points[index].x - normalX, y: points[index].y - normalY))
                }
                var path = Path()
                path.addLines(left + right.reversed())
                path.closeSubpath()
                return path
            }
            context.drawLayer { bloom in
                bloom.addFilter(.blur(radius: 2))
                bloom.fill(ribbon(width: 2.8), with: .linearGradient(
                    Gradient(colors: [.clear, DS.Colors.agentGold.opacity(0.30)]),
                    startPoint: points[0], endPoint: points[points.count - 1]))
            }
            context.fill(ribbon(width: 0.85), with: .linearGradient(
                Gradient(colors: [.clear, DS.Colors.agentGoldBright.opacity(0.85)]),
                startPoint: points[0], endPoint: points[points.count - 1]))
            var core = Path()
            core.addLines(points)
            context.stroke(core, with: .linearGradient(Gradient(colors: [.clear, .white.opacity(0.9)]),
                startPoint: points[0], endPoint: points[points.count - 1]), lineWidth: 0.45)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Active states alone construct a display clock. Muted, waiting, failed,
/// hidden and normal idle remain static, including with a panel left open.
struct AceActivityHalo: View {
    let activity: AceMotionActivity
    var color: Color = DS.Colors.agentGoldBright
    var audioLevel: CGFloat = 0
    var intensity: AceMotionIntensity = .cinematic
    var reduceMotion: Bool = false

    var body: some View {
        Group {
            if AceMotionPolicy.animates(activity, reduceMotion: reduceMotion) {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    halo(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                halo(at: 0)
            }
        }
        .frame(width: 72, height: 72)
        .scaleEffect(0.60)
        .frame(width: 44, height: 44)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func halo(at time: Double) -> some View {
        Canvas { context, size in
            guard activity != .hidden && activity != .idle else { return }
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let ring = CGRect(x: centre.x - 23, y: centre.y - 23, width: 46, height: 46)
            context.stroke(Path(ellipseIn: ring), with: .color(color.opacity(0.16)), lineWidth: 0.7)
            if activity == .listening || activity == .speaking {
                let microphoneEnergy = reduceMotion ? 0.25 : min(1, max(0, Double(audioLevel) * 3))
                for index in 0..<18 {
                    let angle = Double(index) / 18 * 2 * .pi
                    let modulation = (sin(time * 3.4 + Double(index) * 0.8) + 1) / 2
                    let height = activity == .listening
                        ? 2 + microphoneEnergy * (5 + modulation * 9) * intensity.energy
                        : 2 + modulation * 7 * intensity.energy
                    var bar = Path()
                    bar.move(to: CGPoint(x: centre.x + cos(angle) * 23, y: centre.y + sin(angle) * 23))
                    bar.addLine(to: CGPoint(x: centre.x + cos(angle) * (23 + height),
                        y: centre.y + sin(angle) * (23 + height)))
                    context.stroke(bar, with: .color(color.opacity(0.5 + modulation * 0.5)),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
            } else if activity == .thinking || activity == .working {
                for orbit in 0..<3 {
                    let radius = Double(18 + orbit * 6)
                    let angle = time * (orbit == 1 ? -85 : 110) + Double(orbit * 120)
                    var arc = Path()
                    arc.addArc(center: centre, radius: radius, startAngle: .degrees(angle),
                        endAngle: .degrees(angle + 92), clockwise: false)
                    context.stroke(arc, with: .color(color.opacity(0.95 - Double(orbit) * 0.23)),
                        style: StrokeStyle(lineWidth: orbit == 0 ? 1.9 : 1, lineCap: .round))
                    let radians = angle * .pi / 180
                    context.fill(Path(ellipseIn: CGRect(x: centre.x + cos(radians) * radius - 1.7,
                        y: centre.y + sin(radians) * radius - 1.7, width: 3.4, height: 3.4)),
                        with: .color(.white.opacity(0.85)))
                }
            } else {
                var arc = Path()
                arc.addArc(center: centre, radius: 23, startAngle: .degrees(30),
                    endAngle: .degrees(150), clockwise: false)
                context.stroke(arc, with: .color(color.opacity(0.6)), lineWidth: 1.6)
            }
        }
    }
}

struct AceArrivalBurst: View {
    let intensity: AceMotionIntensity
    let reduceMotion: Bool
    var onFinished: () -> Void = {}
    @State private var progress = 0.0

    var body: some View {
        AceBurstDrawing(progress: progress, energy: intensity.energy, reduceMotion: reduceMotion)
            .frame(width: 48, height: 48)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.42)) { progress = 1 }
                do { try await Task.sleep(for: .milliseconds(440)) } catch { return }
                guard !Task.isCancelled else { return }
                onFinished()
            }
    }
}

private struct AceBurstDrawing: View, Animatable {
    var progress: Double
    let energy: Double
    let reduceMotion: Bool
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            guard !reduceMotion, progress < 1 else { return }
            let centre = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = 2 + progress * 13 * energy
            let glow = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: glow), with: .radialGradient(
                Gradient(colors: [DS.Colors.agentGoldBright.opacity((1 - progress) * 0.4), .clear]),
                center: centre, startRadius: 0, endRadius: radius))
            for index in 0..<6 {
                let angle = Double(index) / 6 * 2 * .pi + 0.15
                let travel = radius * (index % 2 == 0 ? 1 : 0.65)
                let point = CGPoint(x: centre.x + cos(angle) * travel, y: centre.y + sin(angle) * travel)
                var spark = Path()
                spark.move(to: point)
                spark.addLine(to: CGPoint(x: point.x + cos(angle) * 3 * (1 - progress),
                    y: point.y + sin(angle) * 3 * (1 - progress)))
                context.stroke(spark, with: .color(.white.opacity((1 - progress) * energy * 0.8)),
                    style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
            }
        }
    }
}

struct AceGlassSurface: View {
    var cornerRadius: CGFloat = 16
    var accent: Color = DS.Colors.agentGold

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [DS.Colors.surface2, DS.Colors.background],
                startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [accent.opacity(0.75), .white.opacity(0.13),
                        accent.opacity(0.08), accent.opacity(0.35)], startPoint: .topLeading,
                        endPoint: .bottomTrailing), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.32), radius: 12, x: 0, y: 5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct AceMotionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(DS.Colors.agentGold.opacity(isEnabled && hovered ? 0.09 : 0)))
            .brightness(isEnabled && hovered ? 0.04 : 0)
            .scaleEffect(reduceMotion || !isEnabled ? 1 : configuration.isPressed ? 0.975 : hovered ? 1.012 : 1)
            .offset(y: reduceMotion || !isEnabled || configuration.isPressed ? 0 : hovered ? -0.6 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.76), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovered = $0 }
            .pointerCursor()
    }
}
#endif // circuit-convert
