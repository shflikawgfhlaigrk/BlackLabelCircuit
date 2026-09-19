import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif

nonisolated enum AceMotionIntensity: String, CaseIterable, Identifiable, Sendable {
    case subtle, expressive, cinematic
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var energy: Double {
        switch self {
        case .subtle: return 0.35
        case .expressive: return 0.7
        case .cinematic: return 1
        }
    }
    static func resolve(_ value: String) -> Self {
        Self(rawValue: value) ?? .cinematic
    }
}

nonisolated enum AceMotionActivity: Equatable, Sendable {
    case hidden, idle, listening, thinking, speaking, working, waiting, muted, failed
    var animates: Bool {
        switch self {
        case .listening, .thinking, .speaking, .working: return true
        default: return false
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated struct AceFlightFrame: Equatable, Sendable {
    let position: CGPoint
    let rotation: Double
    let scaleX: Double
    let scaleY: Double
    let trail: [CGPoint]
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// One flight clock owns movement and its ribbon. No effect changes an input
/// coordinate, moves the system pointer, or outlives its navigation generation.
nonisolated enum AceMotionPolicy {
    static let preferenceKey = "ace.motion.intensity"
    static let gemSize: CGFloat = 16

    static func lightEnergy(_ value: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    static func duration(from start: CGPoint, to end: CGPoint) -> Double {
        min(0.72, max(0.26, hypot(end.x - start.x, end.y - start.y) / 1700))
    }

    static func frame(
        from start: CGPoint, to end: CGPoint, progress: Double,
        bounds: CGRect, intensity: AceMotionIntensity, reduceMotion: Bool
    ) -> AceFlightFrame {
        let progress = progress.isFinite ? min(1, max(0, progress)) : 1
        guard !reduceMotion else {
            return AceFlightFrame(position: end, rotation: 0, scaleX: 1, scaleY: 1, trail: [])
        }
        let distance = hypot(end.x - start.x, end.y - start.y)
        let arcHeight = min(distance * 0.12, 56) * CGFloat(intensity.energy)
        let controlY = (start.y + end.y) / 2 - arcHeight
        let control = CGPoint(x: (start.x + end.x) / 2,
            y: max(bounds.minY + 16, min(bounds.maxY - 16, controlY)))
        func point(at fraction: Double) -> CGPoint {
            let eased = fraction * fraction * fraction * (fraction * (fraction * 6 - 15) + 10)
            let remaining = 1 - eased
            let startWeight = CGFloat(remaining * remaining)
            let controlWeight = CGFloat(2 * remaining * eased)
            let endWeight = CGFloat(eased * eased)
            let x = startWeight * start.x + controlWeight * control.x + endWeight * end.x
            let y = startWeight * start.y + controlWeight * control.y + endWeight * end.y
            return CGPoint(x: x, y: y)
        }
        guard progress > 0, progress < 1, distance > 0.5 else {
            return AceFlightFrame(position: progress == 0 ? start : end, rotation: 0, scaleX: 1, scaleY: 1, trail: [])
        }
        let previous = point(at: max(0, progress - 0.001))
        let next = point(at: min(1, progress + 0.001))
        var heading = atan2(next.y - previous.y, next.x - previous.x) * 180 / .pi + 90
        if heading > 180 { heading -= 360 }
        let bank = min(1, progress / 0.13) * min(1, (1 - progress) / 0.18)
        let energy = sin(progress * .pi) * intensity.energy
        let span = min(progress, 0.11)
        let trail = (0...18).map { index in
            point(at: progress - span + span * Double(index) / 18)
        }
        return AceFlightFrame(
            position: point(at: progress), rotation: heading * bank,
            scaleX: 1 + energy * 0.06, scaleY: 1 + energy * 0.18,
            trail: trail
        )
    }

    static func animates(_ activity: AceMotionActivity, reduceMotion: Bool) -> Bool {
        activity.animates && !reduceMotion
    }
}
#endif // circuit-convert

nonisolated struct AceMotionGeneration: Sendable {
    private(set) var value: UInt64 = 0
    mutating func renew() -> UInt64 { value &+= 1; return value }
    func admits(_ captured: UInt64, visible: Bool) -> Bool {
        visible && captured == value
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// A revision also distinguishes repeated requests for the exact same point.
/// Bounds exist only when the app has read back a real control's geometry.
nonisolated struct AceInkTarget: Equatable, Sendable {
    let revision: UInt64
    let point: CGPoint
    let displayFrame: CGRect
    let verifiedBounds: CGRect?
    var permitsPointing: Bool = false

    var hasValidDestination: Bool {
        [point.x, point.y, displayFrame.minX, displayFrame.minY,
         displayFrame.width, displayFrame.height].allSatisfy(\.isFinite)
            && displayFrame.width > 0 && displayFrame.height > 0
            && displayFrame.contains(point)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated struct AceInkGesture: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case underline, arrow }
    let kind: Kind
    let start: CGPoint
    let control: CGPoint
    let end: CGPoint
    let surface: CGRect?
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated enum AceInkPolicy {
    static let gestureDuration = 0.65
    static let dockDuration = 0.38

    static func localPoint(_ point: CGPoint, display: CGRect) -> CGPoint {
        CGPoint(x: point.x - display.minX, y: display.maxY - point.y)
    }

    static func followingPosition(mouse: CGPoint, bounds: CGRect, docked: Bool = false) -> CGPoint {
        clamp(CGPoint(x: mouse.x + (docked ? 6 : 21), y: mouse.y + (docked ? 15 : 20)),
              to: bounds.insetBy(dx: 16, dy: 16))
    }

    static func gesture(for target: AceInkTarget) -> AceInkGesture? {
        guard target.permitsPointing else { return nil }
        let display = target.displayFrame
        guard finite(display), display.width >= 80, display.height >= 80,
              target.point.x.isFinite, target.point.y.isFinite,
              display.contains(target.point) else { return nil }
        let bounds = CGRect(origin: .zero, size: display.size).insetBy(dx: 8, dy: 8)
        let point = localPoint(target.point, display: display)
        if let verified = target.verifiedBounds,
           finite(verified), verified.width >= 6, verified.height >= 6,
           verified.width <= 280, verified.height <= 84,
           display.contains(verified), verified.contains(target.point) {
            let surface = CGRect(x: verified.minX - display.minX,
                y: display.maxY - verified.maxY, width: verified.width, height: verified.height)
            let halfWidth = min(90, surface.width / 2)
            let lineY = min(bounds.maxY - 2, surface.maxY + 3)
            return AceInkGesture(kind: .underline,
                start: clamp(CGPoint(x: surface.midX - halfWidth, y: lineY), to: bounds),
                control: clamp(CGPoint(x: surface.midX, y: lineY + 1.5), to: bounds),
                end: clamp(CGPoint(x: surface.midX + halfWidth, y: lineY - 0.5), to: bounds),
                surface: surface)
        }
        // A point from a screen answer has no proven control rectangle. A short
        // handwritten arrow indicates precisely that point without inventing one.
        let horizontal: CGFloat = point.x > bounds.midX ? -1 : 1
        let vertical: CGFloat = point.y > bounds.midY ? -1 : 1
        return AceInkGesture(kind: .arrow,
            start: clamp(CGPoint(x: point.x + horizontal * 38, y: point.y + vertical * 30), to: bounds),
            control: clamp(CGPoint(x: point.x + horizontal * 4, y: point.y + vertical * 32), to: bounds),
            end: point, surface: nil)
    }

    static func progress(elapsed: Double, duration: Double, reduceMotion: Bool) -> Double {
        guard !reduceMotion, elapsed.isFinite, duration.isFinite, duration > 0 else { return 1 }
        let fraction = min(1, max(0, elapsed / duration))
        return fraction * fraction * (3 - 2 * fraction)
    }

    private static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(bounds.maxX, max(bounds.minX, point.x)),
                y: min(bounds.maxY, max(bounds.minY, point.y)))
    }

    private static func finite(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && !rect.isNull && !rect.isInfinite
    }
}
#endif // circuit-convert
