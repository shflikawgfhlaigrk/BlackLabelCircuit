#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  OverlayWindow.swift
//  leanring-buddy
//
//  System-wide transparent overlay window for blue glowing cursor.
//  One OverlayWindow is created per screen so the cursor buddy
//  seamlessly follows the cursor across multiple monitors.
//

import Foundation
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .screenSaver  // Always on top, above submenus and popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}

// Cursor-like triangle shape (equilateral) — retained for reference; the live
// cursor now uses the Black Label gem below.
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let size = min(rect.width, rect.height)
        let height = size * sqrt(3.0) / 2.0

        // Top vertex
        path.move(to: CGPoint(x: rect.midX, y: rect.midY - height / 1.5))
        // Bottom left vertex
        path.addLine(to: CGPoint(x: rect.midX - size / 2, y: rect.midY + height / 3))
        // Bottom right vertex
        path.addLine(to: CGPoint(x: rect.midX + size / 2, y: rect.midY + height / 3))
        path.closeSubpath()
        return path
    }
}

// Black Label gem — an elongated, pointed kite. Distinct from BlackLabel's flat
// triangle: it reads as a faceted gemstone and still points in its travel
// direction when it flies to an element.
struct BlackLabelGem: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))                 // top point (leads)
        path.addLine(to: CGPoint(x: rect.minX + w * 0.78, y: rect.minY + h * 0.42)) // right shoulder
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))             // bottom point
        path.addLine(to: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * 0.42)) // left shoulder
        path.closeSubpath()
        return path
    }
}

// The upper facet of the gem — a bright highlight that gives it depth.
struct BlackLabelGemFacet: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width, h = rect.height
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.78, y: rect.minY + h * 0.42))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + h * 0.5))
        path.addLine(to: CGPoint(x: rect.minX + w * 0.22, y: rect.minY + h * 0.42))
        path.closeSubpath()
        return path
    }
}


/// The ace-of-spades silhouette, in SwiftUI's y-down space. Ported from the
/// menu-bar glyph (`MenuBarPanelManager.makeBlackLabelMenuBarIcon`) so the gem
/// that flies around the screen and the icon in the menu bar are unmistakably
/// the same mark. A hexagon read as bulky; a spade is the brand and is slimmer.
func aceSpadePath(in size: CGSize) -> Path {
    // The glyph was authored in AppKit's y-up space; flip so it can be drawn in
    // a Canvas without every control point being re-derived by hand.
    func point(_ fractionX: CGFloat, _ fractionY: CGFloat) -> CGPoint {
        CGPoint(x: fractionX * size.width, y: (1 - fractionY) * size.height)
    }
    var path = Path()
    path.move(to: point(0.50, 0.96))
    path.addCurve(to: point(0.94, 0.42), control1: point(0.66, 0.80), control2: point(0.94, 0.66))
    path.addCurve(to: point(0.56, 0.20), control1: point(0.94, 0.26), control2: point(0.72, 0.20))
    path.addCurve(to: point(0.70, 0.06), control1: point(0.58, 0.15), control2: point(0.64, 0.10))
    path.addLine(to: point(0.30, 0.06))
    path.addCurve(to: point(0.44, 0.20), control1: point(0.36, 0.10), control2: point(0.42, 0.15))
    path.addCurve(to: point(0.06, 0.42), control1: point(0.28, 0.20), control2: point(0.06, 0.26))
    path.addCurve(to: point(0.50, 0.96), control1: point(0.06, 0.66), control2: point(0.34, 0.80))
    path.closeSubpath()
    return path
}

/// A single gem cursor, rendered in one of the assistant's identities.
/// Gold = the assistant talking with you. Red = the background worker.
/// Blue = the meeting notetaker capturing.
struct BlackLabelGemCursor: View {
    let bright: Color
    let mid: Color
    let deep: Color
    var size: CGFloat = AceMotionPolicy.gemSize
    var presentation: PartnerGemPresentation = .normal
    var activity: AceMotionActivity = .idle
    var audioLevel: CGFloat = 0
    var flightEnergy: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Why the old one looked like clip art: the whole silhouette was filled
        // with ONE top-to-bottom gradient, outlined in a dark stroke, with a
        // single static highlight triangle laid on top. One gradient means every
        // face of the stone catches identical light, so nothing reads as a plane;
        // a dark outline flattens a shape into a sticker; and a highlight that
        // never moves cannot say "polished". It is now cut into four facets that
        // each shade against a slowly turning lamp, with a bright rim on the lit
        // side, a travelling specular, and colour splitting at the edges.
        ZStack(alignment: .bottomTrailing) {
            facetFrame { lightAngle in
                let motion = AceMotionPolicy.lightEnergy(flightEnergy, reduceMotion: reduceMotion)
                let voice = AceMotionPolicy.lightEnergy(Double(audioLevel) * 3, reduceMotion: reduceMotion)
                let lightAngle = lightAngle + motion * .pi * 0.8
                let isObsidian =
                    presentation.appearance == .obsidian
                Canvas { context, canvasSize in
                let width = canvasSize.width
                let height = canvasSize.height
                // A SPADE — the brand's mark, and slimmer than the hexagon it
                // replaced. The facets are drawn as wedges from the stone's
                // centre and then CLIPPED to the spade, so the silhouette stays
                // the logo while the interior still shades like a cut stone.
                let silhouette = aceSpadePath(in: canvasSize)
                let centre = CGPoint(x: width / 2, y: height * 0.46)
                let reach = max(width, height)

                context.drawLayer { layerContext in
                    layerContext.clip(to: silhouette)
                    // Base: dark, so unlit facets have something to fall to.
                    layerContext.fill(
                        silhouette,
                        with: .radialGradient(
                            Gradient(
                                colors: isObsidian
                                    ? [
                                        DS.Colors.partnerObsidianBright
                                            .opacity(0.78),
                                        DS.Colors.partnerObsidianDeep,
                                    ]
                                    : [
                                        mid.opacity(0.55),
                                        Color.black.opacity(0.7),
                                    ]
                            ),
                            center: centre, startRadius: 0, endRadius: reach * 0.6))

                    let facetCount = 6
                    for facetIndex in 0..<facetCount {
                        let startAngle = Double(facetIndex) / Double(facetCount) * 2 * .pi - .pi / 2
                        let endAngle = Double(facetIndex + 1) / Double(facetCount) * 2 * .pi - .pi / 2
                        var wedge = Path()
                        wedge.move(to: centre)
                        wedge.addLine(to: CGPoint(x: centre.x + cos(startAngle) * reach,
                                                  y: centre.y + sin(startAngle) * reach))
                        wedge.addLine(to: CGPoint(x: centre.x + cos(endAngle) * reach,
                                                  y: centre.y + sin(endAngle) * reach))
                        wedge.closeSubpath()

                        let facetAngle = (startAngle + endAngle) / 2
                        let facing = cos(facetAngle - lightAngle)
                        // Full range: white-hot facing the lamp, nearly black
                        // opposite. A gentle mid-gold ramp is exactly what made
                        // the old gem read as a gradient-filled polygon.
                        let litness = pow(max(0, facing), 2.0)
                        let faceEdge = isObsidian
                            ? Color(
                                red: 0.38,
                                green: 0.55,
                                blue: 0.82
                            ).opacity(0.04 + 0.28 * litness)
                            : Color.white.opacity(
                                0.12 + 0.78 * litness
                            )
                        let faceBody: Color
                        if isObsidian {
                            faceBody = litness > 0.5
                                ? DS.Colors.partnerObsidianBright
                                : (
                                    litness > 0.12
                                        ? DS.Colors.partnerObsidian
                                        : DS.Colors.partnerObsidianDeep
                                )
                        } else {
                            faceBody = litness > 0.5
                                ? bright
                                : (
                                    litness > 0.12
                                        ? mid
                                        : Color.black.opacity(0.6)
                                )
                        }
                        layerContext.fill(
                            wedge,
                            with: .linearGradient(
                                Gradient(colors: [faceBody.opacity(0.58 + 0.42 * litness), faceEdge]),
                                startPoint: centre,
                                endPoint: CGPoint(x: centre.x + cos(facetAngle) * reach * 0.5,
                                                  y: centre.y + sin(facetAngle) * reach * 0.5)))
                        // Hairline along each facet join.
                        layerContext.stroke(
                            wedge,
                            with: .color(
                                (
                                    isObsidian
                                        ? DS.Colors.agentGold
                                        : bright
                                ).opacity(
                                    isObsidian
                                        ? 0.035 + 0.09 * litness
                                        : 0.10 + 0.30 * litness
                                )
                            ),
                            lineWidth: 0.5
                        )
                    }

                    // Voice illuminates the stone itself; movement rolls one
                    // narrow reflection across its facets using the flight clock.
                    let activeLight: Double = activity == .listening ? voice
                        : activity == .speaking ? (sin(lightAngle * 2.6) + 1) * 0.28
                        : activity == .thinking || activity == .working ? 0.32 : 0
                    let coreRadius = width * (0.20 + activeLight * 0.34)
                    layerContext.fill(silhouette, with: .radialGradient(
                        Gradient(colors: [bright.opacity(activeLight * 0.72), .clear]),
                        center: CGPoint(x: centre.x, y: height * 0.62),
                        startRadius: 0, endRadius: coreRadius))
                    if motion > 0 || activity == .thinking || activity == .working {
                        let reflectionX = width * (0.5 + cos(lightAngle) * 0.35)
                        layerContext.fill(silhouette, with: .linearGradient(
                            Gradient(stops: [.init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.38 + motion * 0.28), location: 0.5),
                                .init(color: .clear, location: 1)]),
                            startPoint: CGPoint(x: reflectionX - width * 0.12, y: 0),
                            endPoint: CGPoint(x: reflectionX + width * 0.12, y: height * 0.35)))
                    }
                }

                // The girdle: metal edge, bright where the lamp lands. No dark
                // outline anywhere — that was flattening it into a sticker.
                let lampSide = CGPoint(x: centre.x + cos(lightAngle) * reach * 0.6,
                                       y: centre.y + sin(lightAngle) * reach * 0.6)
                let shadowSide = CGPoint(x: centre.x - cos(lightAngle) * reach * 0.6,
                                         y: centre.y - sin(lightAngle) * reach * 0.6)
                context.stroke(
                    silhouette,
                    with: .linearGradient(
                        Gradient(
                            colors: isObsidian
                                ? [
                                    DS.Colors.agentGoldBright
                                        .opacity(
                                            presentation
                                                .goldRimOpacity
                                        ),
                                    DS.Colors.agentGold.opacity(
                                        presentation.goldRimOpacity
                                    ),
                                    DS.Colors.agentGoldDeep.opacity(
                                        presentation.goldRimOpacity
                                            * 0.72
                                    ),
                                ]
                                : [
                                    .white.opacity(0.92),
                                    bright.opacity(0.85),
                                    deep.opacity(0.45),
                                ]
                        ),
                        startPoint: lampSide, endPoint: shadowSide),
                    lineWidth: isObsidian ? 1.15 : 0.9)

                if isObsidian {
                    let innerSize = CGSize(
                        width: width * 0.82,
                        height: height * 0.82
                    )
                    let innerSilhouette = aceSpadePath(
                        in: innerSize
                    ).applying(
                        CGAffineTransform(
                            translationX: width * 0.09,
                            y: height * 0.09
                        )
                    )
                    context.stroke(
                        innerSilhouette,
                        with: .color(
                            DS.Colors.agentGold.opacity(0.16)
                        ),
                        lineWidth: 0.45
                    )
                }

                // Colour splitting at the edges — warm one side, cool the other.
                context.blendMode = .screen
                context.translateBy(x: 0.5, y: -0.4)
                context.stroke(
                    silhouette,
                    with: .color(
                        (
                            isObsidian
                                ? DS.Colors.agentGoldBright
                                : Color(
                                    red: 1,
                                    green: 0.75,
                                    blue: 0.4
                                )
                        ).opacity(isObsidian ? 0.22 : 0.38)
                    ),
                    lineWidth: 0.6
                )
                context.translateBy(x: -1.0, y: 0.8)
                context.stroke(
                    silhouette,
                    with: .color(
                        Color(
                            red: 0.55,
                            green: 0.78,
                            blue: 1
                        ).opacity(isObsidian ? 0.18 : 0.30)
                    ),
                    lineWidth: 0.6
                )
                context.translateBy(x: 0.5, y: -0.4)

                // Travelling specular: a hot point riding the lit edge.
                let specular = CGPoint(
                    x: centre.x + cos(lightAngle) * width * 0.26,
                    y: centre.y + sin(lightAngle) * height * 0.24)
                let specularRadius = min(1.5, width * 0.05)
                context.fill(
                    Path(ellipseIn: CGRect(x: specular.x - specularRadius, y: specular.y - specularRadius,
                        width: specularRadius * 2, height: specularRadius * 2)),
                    with: .color(
                        (
                            isObsidian
                                ? DS.Colors.agentGoldBright
                                : .white
                        ).opacity(0.95)
                    ))
                context.blendMode = .normal
            }
            }

            if presentation.badge != .none {
                Image(
                    systemName: presentation.badge == .muted
                        ? "mic.slash.fill"
                        : "exclamationmark"
                )
                .font(.system(size: size * 0.25, weight: .black))
                .foregroundColor(
                    presentation.badge == .error
                        ? DS.Colors.agentRedBright
                        : DS.Colors.agentGoldBright
                )
                .frame(width: size * 0.46, height: size * 0.46)
                .background(
                    Circle()
                        .fill(DS.Colors.partnerObsidianDeep)
                        .overlay(
                            Circle()
                                .stroke(
                                    DS.Colors.agentGold.opacity(0.72),
                                    lineWidth: 0.65
                                )
                        )
                )
                .offset(x: size * 0.16, y: size * 0.10)
            }
        }
        .frame(width: size * 0.86, height: size * 1.18)
        // Two shadows: a tight core glow and a wide soft bloom, so the light has
        // falloff instead of one flat halo.
        .shadow(
            color: (
                presentation.appearance == .obsidian
                    ? DS.Colors.agentGold
                    : bright
            ).opacity(
                presentation.appearance == .obsidian ? 0.38 : 0.62
            ),
            radius: size * 0.14
        )
        .shadow(
            color: (
                presentation.appearance == .obsidian
                    ? DS.Colors.partnerObsidianBright
                    : mid
            ).opacity(0.28),
            radius: size * 0.30
        )
    }

    /// Stable idle renders one exact facet frame and owns no display-link
    /// schedule. Only a visible phase with a nonzero rate constructs the
    /// TimelineView that advances the lamp.
    @ViewBuilder
    private func facetFrame<Content: View>(
        @ViewBuilder content: @escaping (Double) -> Content
    ) -> some View {
        if presentation.animationRate > 0 && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) {
                timeline in
                content(
                    timeline.date.timeIntervalSinceReferenceDate
                        * presentation.animationRate
                )
            }
        } else {
            content(0)
        }
    }
}

/// The amber deafness cue — a soft pulsing ring at the cursor shown while the
/// on-device recognizer is provably deaf (see CompanionManager.surfaceSttDeafness).
/// The visible half of the deafness surface: a founder pressing the hotkey into a
/// wedged recognizer sees a quiet amber pulse instead of unexplained silence.
/// Completes the deafness-surface feature (its call site already shipped its
/// gating on companionManager.sttDeafnessActive).
struct SttDeafnessCueView: View {
    let animates: Bool
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .stroke(
                LinearGradient(colors: [DS.Colors.agentAmberBright, DS.Colors.agentAmber],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 2.5
            )
            .frame(width: 30, height: 30)
            .scaleEffect(animates && isPulsing ? 1.25 : 0.85)
            .opacity(animates && isPulsing ? 0.4 : 0.95)
            .shadow(color: DS.Colors.agentAmber.opacity(0.8), radius: 6)
            .onAppear {
                guard animates else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

// PreferenceKey for tracking bubble size
struct SizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
nonisolated enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

// SwiftUI view for the blue glowing cursor pointer.
// Each screen gets its own BlueCursorView. The view checks whether
// the cursor is currently on THIS screen and only shows the buddy
// triangle when it is. During voice interaction, the triangle is
// replaced by a waveform (listening), spinner (processing), or
// streaming text bubble (responding).
struct BlueCursorView: View {
    let screenFrame: CGRect
    let isFirstAppearance: Bool
    @ObservedObject var companionManager: CompanionManager
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    @AppStorage(AceMotionPolicy.preferenceKey) private var motionPreference = "cinematic"
    private var motionIntensity: AceMotionIntensity { .resolve(motionPreference) }
    private var motionActivity: AceMotionActivity {
        if companionManager.stealthActive { return .hidden }
        if companionManager.partnerModeIsActive {
            switch companionManager.partnerSessionPhase {
            case .inactive, .ready: return .idle
            case .listening: return .listening
            case .processing: return .thinking
            case .speaking: return .speaking
            case .waiting: return .waiting
            case .muted: return .muted
            case .error: return .failed
            }
        }
        switch companionManager.voiceState {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .thinking
        case .responding: return .speaking
        }
    }

    /// Per-lane gem colors for the trailing cluster (utah LaneManager port).
    static func trailingGemColors(for lane: LaneID) -> (bright: Color, mid: Color, deep: Color) {
        switch lane.gemVisualIdentity {
        case .gold:   return (DS.Colors.agentGoldBright, DS.Colors.agentGold, DS.Colors.agentGoldDeep)
        case .red:    return (DS.Colors.agentRedBright, DS.Colors.agentRed, DS.Colors.agentRedDeep)
        case .blue:   return (DS.Colors.agentBlueBright, DS.Colors.agentBlue, DS.Colors.agentBlueDeep)
        case .purple: return (DS.Colors.agentPurpleBright, DS.Colors.agentPurple, DS.Colors.agentPurpleDeep)
        case .silver: return (DS.Colors.agentSilverBright, DS.Colors.agentSilver, DS.Colors.agentSilverDeep)
        }
    }

    /// The trailing gem's gradient colors for the current lane (red worker >
    /// blue notetaker > purple trading), resolved by CompanionManager.
    private var trailingCompanionGemColors: (bright: Color, mid: Color, deep: Color) {
        switch companionManager.companionTrailingGemColor {
        case .red:    return (DS.Colors.agentRedBright, DS.Colors.agentRed, DS.Colors.agentRedDeep)
        case .blue:   return (DS.Colors.agentBlueBright, DS.Colors.agentBlue, DS.Colors.agentBlueDeep)
        case .purple: return (DS.Colors.agentPurpleBright, DS.Colors.agentPurple, DS.Colors.agentPurpleDeep)
        }
    }

    private var overlayActivityPhase: OverlayActivityPhase {
        if companionManager.stealthActive {
            return .hidden
        }
        if companionManager.partnerModeIsActive {
            return .partner(companionManager.partnerSessionPhase)
        }
        switch companionManager.voiceState {
        case .idle: return .idle
        case .listening: return .listening
        case .processing: return .processing
        case .responding: return .responding
        }
    }

    private var overlayPresentation: OverlayActivityPresentation {
        OverlayActivityPolicy.presentation(
            for: overlayActivityPhase,
            reduceMotion: reduceMotion,
            deafnessActive: companionManager.sttDeafnessActive
        )
    }

    private var primaryGemPresentation: PartnerGemPresentation {
        if companionManager.partnerModeIsActive {
            return PartnerGemPresentation.forPhase(
                companionManager.partnerSessionPhase,
                reduceMotion: reduceMotion
            )
        }
        return PartnerGemPresentation(
            appearance: .gold,
            animationRate: overlayPresentation.facetAnimationRate,
            goldRimOpacity: 0,
            badge: .none
        )
    }

    private var trailingGemPresentation: PartnerGemPresentation {
        let activity = OverlayActivityPolicy.presentation(
            for: .trailingLane,
            reduceMotion: reduceMotion,
            deafnessActive: false
        )
        return PartnerGemPresentation(
            appearance: .gold,
            animationRate: activity.facetAnimationRate,
            goldRimOpacity: 0,
            badge: .none
        )
    }

    @State private var cursorPosition: CGPoint
    @State private var isCursorOnThisScreen: Bool

    init(screenFrame: CGRect, isFirstAppearance: Bool, companionManager: CompanionManager) {
        self.screenFrame = screenFrame
        self.isFirstAppearance = isFirstAppearance
        self.companionManager = companionManager

        // Seed the cursor position from the current mouse location so the
        // buddy doesn't flash at (0,0) before onAppear fires.
        let mouseLocation = NSEvent.mouseLocation
        let localX = mouseLocation.x - screenFrame.origin.x
        let localY = screenFrame.height - (mouseLocation.y - screenFrame.origin.y)
        _cursorPosition = State(initialValue: AceInkPolicy.followingPosition(
            mouse: CGPoint(x: localX, y: localY), bounds: CGRect(origin: .zero, size: screenFrame.size)))
        _isCursorOnThisScreen = State(initialValue: screenFrame.contains(mouseLocation))
    }
    @State private var globalCursorEventMonitor: Any?
    @State private var localCursorEventMonitor: Any?
    @State private var welcomeText: String = ""
    @State private var showWelcome: Bool = true
    @State private var bubbleSize: CGSize = .zero
    @State private var bubbleOpacity: Double = 1.0
    @State private var cursorOpacity: Double = 0.0
    @State private var welcomeGeneration = UUID()
    @State private var welcomeStartTask: Task<Void, Never>?
    @State private var welcomeAnimationTimer: Timer?
    @State private var welcomeDismissTask: Task<Void, Never>?
    @State private var welcomeCharacterIndex = 0

    // MARK: - Buddy Navigation State

    /// The buddy's current behavioral mode (following cursor, navigating, or pointing).
    @State private var buddyNavigationMode: BuddyNavigationMode = .followingCursor

    /// The rotation angle of the triangle in degrees. Default is -35° (cursor-like).
    /// Changes to face the direction of travel when navigating to a target.
    @State private var triangleRotationDegrees: Double = 0.0
    @State private var flightTrail: [CGPoint] = []
    @State private var buddyFlightStretch: CGFloat = 1
    @State private var targetBeaconPosition: CGPoint?
    @State private var activeInkTargetRevision: UInt64?
    @State private var inkGesture: AceInkGesture?
    @State private var inkGestureProgress = 0.0
    @State private var inkDockProgress = 1.0
    @State private var arrivalBurstID: UUID?
    @State private var arrivalBurstPosition: CGPoint = .zero
    @State private var navigationGeneration = AceMotionGeneration()

    /// Speech bubble text shown when pointing at a detected element.
    @State private var navigationBubbleText: String = ""
    @State private var navigationBubbleOpacity: Double = 0.0
    @State private var navigationBubbleSize: CGSize = .zero

    /// The cursor position at the moment navigation started, used to detect
    /// if the user moves the cursor enough to cancel the navigation.
    @State private var cursorPositionWhenNavigationStarted: CGPoint = .zero

    /// Timer driving the frame-by-frame bezier arc flight animation.
    /// Invalidated when the flight completes, is canceled, or the view disappears.
    @State private var navigationAnimationTimer: Timer?

    /// Scale factor applied to the buddy triangle during flight. Grows to ~1.3x
    /// at the midpoint of the arc and shrinks back to 1.0x on landing, creating
    /// an energetic "swooping" feel.
    @State private var buddyFlightScale: CGFloat = 1.0

    /// Scale factor for the navigation speech bubble's pop-in entrance.
    /// Starts at 0.5 and springs to 1.0 when the first character appears.
    @State private var navigationBubbleScale: CGFloat = 1.0

    /// True when the buddy is flying BACK to the cursor after pointing.
    /// Only during the return flight can cursor movement cancel the animation.
    @State private var isReturningToCursor: Bool = false

    // MARK: - Onboarding Video Layout

    private let onboardingVideoPlayerWidth: CGFloat = 330
    private let onboardingVideoPlayerHeight: CGFloat = 186

    private let fullWelcomeMessage = "hey! i'm ace"

    var body: some View {
        ZStack {
            // Nearly transparent background (helps with compositing)
            Color.black.opacity(0.001)

            if buddyIsVisibleOnThisScreen && !companionManager.stealthActive {
                if !flightTrail.isEmpty && !reduceMotion {
                    AceFlightTrail(points: flightTrail, intensity: motionIntensity)
                }
                if buddyNavigationMode == .pointingAtTarget, let gesture = inkGesture {
                    AceInkAnnotation(gesture: gesture, progress: inkGestureProgress,
                        intensity: motionIntensity, reduceMotion: reduceMotion)
                        .opacity(navigationBubbleOpacity)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: navigationBubbleOpacity)
                }
                if inkDockProgress < 1 && !reduceMotion {
                    AceLivingInk(movement: (Double(buddyFlightStretch) - 1) / 0.18,
                        dock: inkDockProgress, intensity: motionIntensity)
                        .rotationEffect(.degrees(triangleRotationDegrees))
                        .position(x: cursorPosition.x - 9 - inkDockProgress * 6,
                                  y: cursorPosition.y + 12 - inkDockProgress * 17)
                }
                if let burstID = arrivalBurstID {
                    AceArrivalBurst(intensity: motionIntensity, reduceMotion: reduceMotion) {
                        if arrivalBurstID == burstID { arrivalBurstID = nil }
                    }
                    .id(burstID)
                    .position(arrivalBurstPosition)
                }
            }

            // Welcome speech bubble (first launch only)
            if isCursorOnThisScreen && showWelcome && !welcomeText.isEmpty {
                Text(welcomeText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(bubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(reduceMotion ? nil : .spring(response: 0.17, dampingFraction: 0.84, blendDuration: 0), value: cursorPosition)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: bubbleOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Onboarding video — always in the view tree so opacity animation works
            // reliably. When no player exists or opacity is 0, nothing is visible.
            // allowsHitTesting(false) prevents it from intercepting clicks.
            OnboardingVideoPlayerView(player: companionManager.onboardingVideoPlayer)
                .frame(width: onboardingVideoPlayerWidth, height: onboardingVideoPlayerHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(color: Color.black.opacity(0.4 * companionManager.onboardingVideoOpacity), radius: 12, x: 0, y: 6)
                .opacity(isCursorOnThisScreen ? companionManager.onboardingVideoOpacity : 0)
                .position(
                    x: cursorPosition.x + 10 + (onboardingVideoPlayerWidth / 2),
                    y: cursorPosition.y + 18 + (onboardingVideoPlayerHeight / 2)
                )
                .animation(reduceMotion ? nil : .spring(response: 0.17, dampingFraction: 0.84, blendDuration: 0), value: cursorPosition)
                .animation(reduceMotion ? nil : .easeInOut(duration: 2.0), value: companionManager.onboardingVideoOpacity)
                .allowsHitTesting(false)

            // Onboarding prompt — streams the canonical live push-to-talk
            // shortcut after the welcome video ends.
            if isCursorOnThisScreen && companionManager.showOnboardingPrompt && !companionManager.onboardingPromptText.isEmpty {
                Text(companionManager.onboardingPromptText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DS.Colors.overlayCursorBlue)
                            .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.5), radius: 6, x: 0, y: 0)
                    )
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: SizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .opacity(companionManager.onboardingPromptOpacity)
                    .position(x: cursorPosition.x + 10 + (bubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(reduceMotion ? nil : .spring(response: 0.17, dampingFraction: 0.84, blendDuration: 0), value: cursorPosition)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: companionManager.onboardingPromptOpacity)
                    .onPreferenceChange(SizePreferenceKey.self) { newSize in
                        bubbleSize = newSize
                    }
            }

            // Navigation pointer bubble — shown when buddy arrives at a detected element.
            // Pops in with a scale-bounce (0.5x → 1.0x spring) and a bright initial
            // glow that settles, creating a "materializing" effect.
            if buddyNavigationMode == .pointingAtTarget && !navigationBubbleText.isEmpty && !companionManager.stealthActive {
                Text(navigationBubbleText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AceGlassSurface(cornerRadius: 9))
                    .fixedSize()
                    .overlay(
                        GeometryReader { geo in
                            Color.clear
                                .preference(key: NavigationBubbleSizePreferenceKey.self, value: geo.size)
                        }
                    )
                    .scaleEffect(navigationBubbleScale)
                    .opacity(navigationBubbleOpacity)
                    .position(x: cursorPosition.x + 10 + (navigationBubbleSize.width / 2), y: cursorPosition.y + 18)
                    .animation(reduceMotion ? nil : .spring(response: 0.17, dampingFraction: 0.84, blendDuration: 0), value: cursorPosition)
                    .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.6), value: navigationBubbleScale)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: navigationBubbleOpacity)
                    .onPreferenceChange(NavigationBubbleSizePreferenceKey.self) { newSize in
                        navigationBubbleSize = newSize
                    }
            }

            // Blue triangle cursor — shown when idle or while TTS is playing (responding).
            // All three states (triangle, waveform, spinner) stay in the view tree
            // permanently and cross-fade via opacity so SwiftUI doesn't remove/re-insert
            // them (which caused a visible cursor "pop").
            //
            // During cursor following: fast spring animation for snappy tracking.
            // During navigation: NO implicit animation — the frame-by-frame bezier
            // timer controls position directly at 60fps for a smooth arc flight.
            if buddyIsVisibleOnThisScreen
                && !companionManager.stealthActive
                && (
                    companionManager.partnerModeIsActive
                        || companionManager.voiceState == .idle
                        || companionManager.voiceState == .responding
                ) {
                ZStack {
                    BlackLabelGemCursor(
                        bright: DS.Colors.agentGoldBright, mid: DS.Colors.agentGold,
                        deep: DS.Colors.agentGoldDeep, size: AceMotionPolicy.gemSize,
                        presentation: primaryGemPresentation,
                        activity: motionActivity,
                        audioLevel: companionManager.currentAudioPowerLevel,
                        flightEnergy: (Double(buddyFlightStretch) - 1) / 0.18
                    )
                    .scaleEffect(x: buddyFlightScale, y: buddyFlightStretch)
                    .rotationEffect(.degrees(triangleRotationDegrees))
                }
                .opacity(cursorOpacity)
                .position(cursorPosition)
                .animation(
                    buddyNavigationMode == .followingCursor && !reduceMotion
                        ? .spring(response: 0.17, dampingFraction: 0.84, blendDuration: 0)
                        : nil,
                    value: cursorPosition
                )
                .animation(reduceMotion ? nil : .easeIn(duration: 0.25), value: companionManager.voiceState)
                .animation(
                    buddyNavigationMode == .navigatingToTarget || reduceMotion ? nil : .easeInOut(duration: 0.3),
                    value: triangleRotationDegrees
                )
            }

            // Gold waveform — replaces the gem while listening
            if overlayPresentation.rendersWaveform {
                if buddyIsVisibleOnThisScreen
                    && !companionManager.partnerModeIsActive {
                    BlueCursorWaveformView(
                        audioPowerLevel:
                            companionManager.currentAudioPowerLevel,
                        animates: overlayPresentation.waveformAnimates,
                        intensity: motionIntensity
                    )
                        .opacity(cursorOpacity)
                        .position(cursorPosition)
                        .animation(reduceMotion ? nil : .spring(response: 0.17, dampingFraction: 0.84, blendDuration: 0), value: cursorPosition)
                        .animation(reduceMotion ? nil : .easeIn(duration: 0.15), value: companionManager.voiceState)
                }
            }

            // Gold spinner — shown while the AI is processing (transcription + Claude + waiting for TTS)
            if overlayPresentation.rendersSpinner {
                if buddyIsVisibleOnThisScreen
                    && !companionManager.partnerModeIsActive {
                    BlueCursorSpinnerView(
                        animates: overlayPresentation.spinnerAnimates,
                        intensity: motionIntensity
                    )
                        .opacity(cursorOpacity)
                        .position(cursorPosition)
                        .animation(reduceMotion ? nil : .spring(response: 0.17, dampingFraction: 0.84, blendDuration: 0), value: cursorPosition)
                        .animation(reduceMotion ? nil : .easeIn(duration: 0.15), value: companionManager.voiceState)
                }
            }

            // Trailing gem CLUSTER (utah LaneManager port, 2026-07-26) — each
            // active background lane gets its OWN gem: red for the first worker,
            // silver for a second worker or workflow, blue while the notetaker
            // captures, purple while trading mode is on,
            // all at once when they overlap. The old single gem was red XOR blue
            // XOR purple, which hid every concurrent lane behind a precedence
            // rule. Stable order from litTrailingLanes so the cluster never
            // reshuffles as lanes toggle; stealth empties it entirely.
            if buddyIsVisibleOnThisScreen
                && !companionManager.stealthActive {
                ForEach(Array(companionManager.litTrailingLanes.enumerated()), id: \.element) { laneIndex, lane in
                    let laneColors = Self.trailingGemColors(for: lane)
                    ZStack {
                        BlackLabelGemCursor(bright: laneColors.bright, mid: laneColors.mid,
                            deep: laneColors.deep, size: 9, presentation: trailingGemPresentation,
                            activity: .working)
                    }
                    .frame(width: 18, height: 18)
                        .opacity(0.95)
                        .position(x: cursorPosition.x - 18 - CGFloat(laneIndex) * 15,
                                  y: cursorPosition.y + 16 + CGFloat(laneIndex) * 3)
                        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                        .transition(.opacity.combined(with: .scale(scale: 0.6)))
                }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: companionManager.litTrailingLanes)
            }

            if companionManager.tradingModeActive {
                Text(
                    "TRADING • "
                        + companionManager.tradingModeBadgeDetail
                )
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(DS.Colors.agentPurpleDeep.opacity(0.94))
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                DS.Colors.agentPurpleBright.opacity(0.8),
                                lineWidth: 0.8
                            )
                    )
                    .opacity(
                        buddyIsVisibleOnThisScreen
                            && !companionManager.stealthActive
                            ? 1 : 0
                    )
                    .position(
                        x: cursorPosition.x + 4,
                        y: cursorPosition.y + 52
                    )
                    .allowsHitTesting(false)
            }

            // Deafness cue — an amber pulsing ring at the cursor while the on-device
            // recognizer is provably deaf (Siri/Dictation off). This is the VISUAL
            // half of the deafness surface: a founder who presses the hotkey into a
            // wedged recognizer now sees amber (and heard one spoken line) instead of
            // nothing. Driven purely by companionManager.sttDeafnessActive.
            if overlayPresentation.rendersDeafnessCue {
                if buddyIsVisibleOnThisScreen {
                    SttDeafnessCueView(
                        animates:
                            overlayPresentation.deafnessCueAnimates
                    )
                        .opacity(0.95)
                        .position(cursorPosition)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: companionManager.sttDeafnessActive)
                        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.6, blendDuration: 0), value: cursorPosition)
                }
            }

        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .ignoresSafeArea()
        .onChange(of: companionManager.clickFlashTrigger) { _ in
            guard buddyIsVisibleOnThisScreen, !companionManager.stealthActive, !reduceMotion else { return }
            showArrivalBurst(at: cursorPosition)
        }
        .onChange(of: companionManager.stopWorkReceipt) { _ in
            cancelNavigationAndResumeFollowing()
        }
        .onChange(of: reduceMotion) { _ in
            cancelNavigationAndResumeFollowing()
        }
        .onAppear {
            // Set initial cursor position immediately before starting animation
            let mouseLocation = NSEvent.mouseLocation
            isCursorOnThisScreen = screenFrame.contains(mouseLocation)

            let swiftUIPosition = convertScreenPointToSwiftUICoordinates(mouseLocation)
            self.cursorPosition = AceInkPolicy.followingPosition(mouse: swiftUIPosition,
                bounds: CGRect(origin: .zero, size: screenFrame.size))

            startTrackingCursor()

            // Only show welcome message on first appearance (app start)
            // and only if the cursor starts on this screen
            if isFirstAppearance && isCursorOnThisScreen {
                withAnimation(.easeIn(duration: 2.0)) {
                    self.cursorOpacity = 1.0
                }
                beginWelcomeSequence()
            } else {
                self.cursorOpacity = 1.0
            }
        }
        .onDisappear {
            cancelWelcomeSequence()
            stopTrackingCursor()
            resetNavigationVisuals()
            companionManager.tearDownOnboardingVideo()
        }
        .onChange(of: companionManager.stealthActive) { isActive in
            if isActive {
                cancelWelcomeSequence()
                stopTrackingCursor()
                resetNavigationVisuals()
                companionManager.tearDownOnboardingVideo()
            } else {
                handleCursorMovement()
                startTrackingCursor()
            }
        }
        .onChange(of: companionManager.detectedElementVisualTarget) { target in
            guard let target else {
                if activeInkTargetRevision != nil { cancelNavigationAndResumeFollowing() }
                return
            }
            guard !companionManager.stealthActive,
                  target.displayFrame == screenFrame else {
                resetNavigationVisuals()
                return
            }
            startNavigatingToElement(screenLocation: target.point)
        }
    }

    /// Whether the buddy triangle should be visible on this screen.
    /// True when cursor is on this screen during normal following, or
    /// when navigating/pointing at a target on this screen. When another
    /// screen is navigating (detectedElementScreenLocation is set but this
    /// screen isn't the one animating), hide the cursor so only one buddy
    /// is ever visible at a time.
    private var buddyIsVisibleOnThisScreen: Bool {
        switch buddyNavigationMode {
        case .followingCursor:
            // If another screen's BlueCursorView is navigating to an element,
            // hide the cursor on this screen to prevent a duplicate buddy — but
            // ONLY when some live screen actually contains the target. After a
            // display change (hot-plug / rearrange / stale frame) the target may
            // match NO overlay, so nobody navigates; hiding everywhere would make
            // the gem vanish from every screen for the whole answer. In that case
            // keep following the cursor so the gem never goes dark.
            if companionManager.detectedElementScreenLocation != nil,
               someLiveScreenContainsDetectedTarget {
                return false
            }
            return isCursorOnThisScreen
        case .navigatingToTarget, .pointingAtTarget:
            return true
        }
    }

    /// Whether some currently-attached screen actually contains the detected
    /// target's display midpoint (i.e., a BlueCursorView WILL navigate to it).
    /// Mirrors the navigate guard in the detectedElementScreenLocation onChange.
    private var someLiveScreenContainsDetectedTarget: Bool {
        guard let target = companionManager.detectedElementVisualTarget,
              target.hasValidDestination else { return false }
        return NSScreen.screens.contains { $0.frame == target.displayFrame }
    }

    // MARK: - Cursor Tracking

    private func startTrackingCursor() {
        stopTrackingCursor()
        guard overlayPresentation.tracksCursor else { return }
        let eventMask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        globalCursorEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: eventMask
        ) { _ in
            Task { @MainActor in
                self.handleCursorMovement()
            }
        }
        localCursorEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: eventMask
        ) { event in
            self.handleCursorMovement()
            return event
        }
    }

    private func stopTrackingCursor() {
        if let globalCursorEventMonitor {
            NSEvent.removeMonitor(globalCursorEventMonitor)
            self.globalCursorEventMonitor = nil
        }
        if let localCursorEventMonitor {
            NSEvent.removeMonitor(localCursorEventMonitor)
            self.localCursorEventMonitor = nil
        }
    }

    private func handleCursorMovement() {
        let mouseLocation = NSEvent.mouseLocation
        let cursorIsOnScreen = screenFrame.contains(mouseLocation)
        if isCursorOnThisScreen != cursorIsOnScreen {
            isCursorOnThisScreen = cursorIsOnScreen
        }

        // During forward flight or pointing, the buddy is NOT interrupted by
        // mouse movement — it completes its full animation and return flight.
        // Only during the RETURN flight can a real mouse event cancel it.
        if buddyNavigationMode == .navigatingToTarget,
           isReturningToCursor {
            let currentMouseInSwiftUI =
                convertScreenPointToSwiftUICoordinates(mouseLocation)
            let distanceFromNavigationStart = hypot(
                currentMouseInSwiftUI.x
                    - cursorPositionWhenNavigationStarted.x,
                currentMouseInSwiftUI.y
                    - cursorPositionWhenNavigationStarted.y
            )
            if distanceFromNavigationStart > 100 {
                cancelNavigationAndResumeFollowing()
            }
            return
        }

        guard buddyNavigationMode == .followingCursor else { return }
        let swiftUIPosition =
            convertScreenPointToSwiftUICoordinates(mouseLocation)
        let nextPosition = AceInkPolicy.followingPosition(mouse: swiftUIPosition,
            bounds: CGRect(origin: .zero, size: screenFrame.size))
        guard cursorPosition != nextPosition else { return }
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        inkDockProgress = 1
        cursorPosition = nextPosition
    }

    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to this screen's overlay window.
    private func convertScreenPointToSwiftUICoordinates(_ screenPoint: CGPoint) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    // MARK: - Element Navigation

    /// Starts animating the buddy toward a detected UI element location.
    private func startNavigatingToElement(screenLocation: CGPoint) {
        // Don't interrupt welcome animation
        guard !showWelcome || welcomeText.isEmpty else { return }
        guard let target = companionManager.detectedElementVisualTarget,
              target.displayFrame == screenFrame,
              target.hasValidDestination else {
            cancelNavigationAndResumeFollowing()
            return
        }
        let gesture = AceInkPolicy.gesture(for: target)

        // Convert the AppKit screen location to SwiftUI coordinates for this screen
        let targetInSwiftUI = convertScreenPointToSwiftUICoordinates(screenLocation)

        // Offset the target so the buddy sits beside the element rather than
        // directly on top of it — 8px to the right, 12px below.
        let offsetTarget = CGPoint(
            x: targetInSwiftUI.x + 8,
            y: targetInSwiftUI.y + 12
        )

        // Clamp target to screen bounds with padding
        let clampedTarget = CGPoint(
            x: max(20, min(offsetTarget.x, screenFrame.width - 20)),
            y: max(20, min(offsetTarget.y, screenFrame.height - 20))
        )

        resetNavigationVisuals()
        targetBeaconPosition = targetInSwiftUI
        activeInkTargetRevision = target.revision
        inkGesture = gesture
        inkDockProgress = 0
        _ = navigationGeneration.renew()

        // Record the current cursor position so we can detect if the user
        // moves the mouse enough to cancel the return flight
        let mouseLocation = NSEvent.mouseLocation
        cursorPositionWhenNavigationStarted = convertScreenPointToSwiftUICoordinates(mouseLocation)

        // Enter navigation mode — stop cursor following
        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = false

        animateBezierFlightArc(to: clampedTarget) {
            guard self.buddyNavigationMode == .navigatingToTarget else { return }
            self.startPointingAtElement()
        }
    }

    /// Animates the buddy along a quadratic bezier arc from its current position
    /// to the specified destination. The triangle rotates to face its direction
    /// of travel (tangent to the curve) each frame, scales up at the midpoint
    /// for a "swooping" feel, and the glow intensifies during flight.
    private func animateBezierFlightArc(
        to destination: CGPoint,
        onComplete: @escaping @MainActor @Sendable () -> Void
    ) {
        navigationAnimationTimer?.invalidate()
        let generation = navigationGeneration.value
        let startPosition = cursorPosition
        let startedAt = ProcessInfo.processInfo.systemUptime
        let duration = AceMotionPolicy.duration(from: startPosition, to: destination)
        if reduceMotion {
            cursorPosition = destination
            buddyFlightScale = 1
            buddyFlightStretch = 1
            flightTrail = []
            onComplete()
            return
        }
        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            guard navigationGeneration.admits(generation, visible: !companionManager.stealthActive),
                  buddyNavigationMode == .navigatingToTarget else {
                timer.invalidate()
                return
            }
            let progress = (ProcessInfo.processInfo.systemUptime - startedAt) / duration
            let frame = AceMotionPolicy.frame(from: startPosition, to: destination, progress: progress,
                bounds: CGRect(origin: .zero, size: screenFrame.size),
                intensity: motionIntensity, reduceMotion: reduceMotion)
            cursorPosition = frame.position
            triangleRotationDegrees = frame.rotation
            buddyFlightScale = frame.scaleX
            buddyFlightStretch = frame.scaleY
            flightTrail = frame.trail
            if progress >= 1 {
                timer.invalidate()
                navigationAnimationTimer = nil
                onComplete()
            }
        }
    }

    private func showArrivalBurst(at point: CGPoint) {
        guard !reduceMotion, !companionManager.stealthActive else { return }
        arrivalBurstPosition = point
        arrivalBurstID = UUID()
        if UserDefaults.standard.bool(forKey: "ace.motion.landing-sound"),
           companionManager.voiceState == .idle,
           !companionManager.meetingNotetaker.isTakingNotes {
            NSSound(named: "Tink")?.play()
        }
    }

    private func resetNavigationVisuals() {
        _ = navigationGeneration.renew()
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        flightTrail = []
        targetBeaconPosition = nil
        activeInkTargetRevision = nil
        inkGesture = nil
        inkGestureProgress = 0
        inkDockProgress = 1
        arrivalBurstID = nil
        buddyFlightScale = 1
        buddyFlightStretch = 1
        triangleRotationDegrees = 0
        navigationBubbleText = ""
        navigationBubbleOpacity = 0
        navigationBubbleScale = 1
        buddyNavigationMode = .followingCursor
        isReturningToCursor = false
    }

    /// Transitions to pointing mode — shows a speech bubble with a bouncy
    /// scale-in entrance and variable-speed character streaming.
    private func startPointingAtElement() {
        guard let gesture = inkGesture,
              let target = companionManager.detectedElementVisualTarget,
              target.permitsPointing,
              target.revision == activeInkTargetRevision else {
            startFlyingBackToCursor()
            return
        }
        buddyNavigationMode = .pointingAtTarget
        let generation = navigationGeneration.value
        startInkGesture()
        if !companionManager.stealthActive,
           let targetFrame = companionManager.detectedElementDisplayFrame,
           let pointTurnIdentifier = companionManager.detectedElementVerifiedTurnID,
           pointTurnIdentifier == AceEventBus.shared.currentTurnID,
           targetFrame == screenFrame {
            LifecycleLog.append(
                "POINT overlay reached target turn="
                    + pointTurnIdentifier.uuidString.lowercased()
                    + " gesture=" + (gesture.kind == .underline ? "underline" : "arrow")
                    + " target=(\(target.point.x),\(target.point.y))"
                    + " localTip=(\(gesture.end.x),\(gesture.end.y))"
                    + " display=(\(screenFrame.minX),\(screenFrame.minY),\(screenFrame.width),\(screenFrame.height))"
            )
        }

        // Land upright — the spade stands on its stem when it isn't flying.
        triangleRotationDegrees = 0.0

        // Reset navigation bubble state — start small for the scale-bounce entrance
        navigationBubbleText = ""
        navigationBubbleOpacity = 1.0
        navigationBubbleSize = .zero
        navigationBubbleScale = reduceMotion ? 1 : 0.72

        // The gesture is the default cue. Show text only when the request owns
        // a specific explanation, keeping ordinary pointing free of extra chrome.
        let pointerPhrase = companionManager.detectedElementBubbleText ?? ""

        streamNavigationBubbleCharacter(phrase: pointerPhrase, characterIndex: 0) {
            // All characters streamed — hold for 3 seconds, then fly back
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                guard self.buddyNavigationMode == .pointingAtTarget,
                      self.navigationGeneration.admits(generation, visible: !companionManager.stealthActive) else { return }
                self.navigationBubbleOpacity = 0.0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    guard self.buddyNavigationMode == .pointingAtTarget,
                      self.navigationGeneration.admits(generation, visible: !companionManager.stealthActive) else { return }
                    self.startFlyingBackToCursor()
                }
            }
        }
    }

    private func startInkGesture() {
        navigationAnimationTimer?.invalidate()
        navigationAnimationTimer = nil
        inkGestureProgress = reduceMotion ? 1 : 0
        guard !reduceMotion else { return }
        let generation = navigationGeneration.value
        let startedAt = ProcessInfo.processInfo.systemUptime
        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            guard navigationGeneration.admits(generation, visible: !companionManager.stealthActive),
                  buddyNavigationMode == .pointingAtTarget else {
                timer.invalidate()
                return
            }
            inkGestureProgress = AceInkPolicy.progress(
                elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                duration: AceInkPolicy.gestureDuration, reduceMotion: reduceMotion)
            if inkGestureProgress >= 1 {
                timer.invalidate()
                navigationAnimationTimer = nil
            }
        }
    }

    /// Streams the navigation bubble text one character at a time with variable
    /// delays (30–60ms) for a natural "speaking" rhythm.
    private func streamNavigationBubbleCharacter(
        phrase: String,
        characterIndex: Int,
        onComplete: @escaping () -> Void
    ) {
        let generation = navigationGeneration.value
        guard buddyNavigationMode == .pointingAtTarget, !companionManager.stealthActive else { return }
        if reduceMotion { navigationBubbleText = phrase; navigationBubbleScale = 1; onComplete(); return }
        guard characterIndex < phrase.count else {
            onComplete()
            return
        }

        let charIndex = phrase.index(phrase.startIndex, offsetBy: characterIndex)
        navigationBubbleText.append(phrase[charIndex])

        // On the first character, trigger the scale-bounce entrance
        if characterIndex == 0 {
            navigationBubbleScale = 1.0
        }

        let characterDelay = Double.random(in: 0.03...0.06)
        DispatchQueue.main.asyncAfter(deadline: .now() + characterDelay) {
            guard self.navigationGeneration.admits(generation, visible: !companionManager.stealthActive) else { return }
            self.streamNavigationBubbleCharacter(
                phrase: phrase,
                characterIndex: characterIndex + 1,
                onComplete: onComplete
            )
        }
    }

    /// Flies the buddy back to the current cursor position after pointing is done.
    private func startFlyingBackToCursor() {
        targetBeaconPosition = nil
        inkGesture = nil
        let mouseLocation = NSEvent.mouseLocation
        guard screenFrame.contains(mouseLocation) else {
            finishNavigationAndResumeFollowing()
            return
        }
        let cursorInSwiftUI = convertScreenPointToSwiftUICoordinates(mouseLocation)
        let cursorWithTrackingOffset = AceInkPolicy.followingPosition(mouse: cursorInSwiftUI,
            bounds: CGRect(origin: .zero, size: screenFrame.size))

        cursorPositionWhenNavigationStarted = cursorInSwiftUI

        buddyNavigationMode = .navigatingToTarget
        isReturningToCursor = true

        animateBezierFlightArc(to: cursorWithTrackingOffset) {
            self.finishNavigationAndResumeFollowing()
            self.startInkDocking()
        }
    }

    /// Cancels an in-progress navigation because the user moved the cursor.
    private func cancelNavigationAndResumeFollowing() {
        finishNavigationAndResumeFollowing()
    }

    /// Retire the visual generation before clearing the shared target so old
    /// bubble delays cannot resume a replacement flight or revive after Stop.
    private func finishNavigationAndResumeFollowing() {
        let ownedTargetRevision = activeInkTargetRevision
        resetNavigationVisuals()
        if let ownedTargetRevision,
           companionManager.detectedElementVisualTarget?.revision == ownedTargetRevision {
            companionManager.clearDetectedElementLocation()
        }
        handleCursorMovement()
    }

    private func startInkDocking() {
        guard !reduceMotion, !companionManager.stealthActive,
              isCursorOnThisScreen, companionManager.detectedElementVisualTarget == nil else { return }
        inkDockProgress = 0
        let generation = navigationGeneration.value
        let startedAt = ProcessInfo.processInfo.systemUptime
        navigationAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            guard navigationGeneration.admits(generation, visible: !companionManager.stealthActive),
                  buddyNavigationMode == .followingCursor else {
                timer.invalidate()
                return
            }
            inkDockProgress = AceInkPolicy.progress(
                elapsed: ProcessInfo.processInfo.systemUptime - startedAt,
                duration: AceInkPolicy.dockDuration, reduceMotion: reduceMotion)
            if inkDockProgress >= 1 {
                timer.invalidate()
                navigationAnimationTimer = nil
            }
        }
    }

    // MARK: - Welcome Animation

    private func beginWelcomeSequence() {
        cancelWelcomeSequence()
        let generation = welcomeGeneration
        showWelcome = true
        welcomeStartTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard OnboardingPromptCallbackAdmission.isCurrent(
                expectedGeneration: generation,
                currentGeneration: welcomeGeneration,
                taskIsCancelled: Task.isCancelled,
                stealthIsActive:
                    StealthEntryLatch.shared.isRaised
                        || companionManager.stealthActive
                        || StealthVisibilityGate.shared.isActive
            ) else {
                return
            }
            welcomeStartTask = nil
            bubbleOpacity = 0.0
            startWelcomeAnimation(generation: generation)
        }
    }

    private func cancelWelcomeSequence() {
        welcomeGeneration = UUID()
        welcomeStartTask?.cancel()
        welcomeStartTask = nil
        welcomeAnimationTimer?.invalidate()
        welcomeAnimationTimer = nil
        welcomeDismissTask?.cancel()
        welcomeDismissTask = nil
        welcomeCharacterIndex = 0
        welcomeText = ""
        showWelcome = false
        bubbleOpacity = 0.0
    }

    private func startWelcomeAnimation(generation: UUID) {
        guard OnboardingPromptCallbackAdmission.isCurrent(
            expectedGeneration: generation,
            currentGeneration: welcomeGeneration,
            taskIsCancelled: false,
            stealthIsActive:
                StealthEntryLatch.shared.isRaised
                    || companionManager.stealthActive
                    || StealthVisibilityGate.shared.isActive
        ) else {
            return
        }
        withAnimation(.easeIn(duration: 0.4)) {
            self.bubbleOpacity = 1.0
        }

        welcomeCharacterIndex = 0
        welcomeAnimationTimer = Timer.scheduledTimer(
            withTimeInterval: 0.03,
            repeats: true
        ) { timer in
            guard OnboardingPromptCallbackAdmission.isCurrent(
                expectedGeneration: generation,
                currentGeneration: self.welcomeGeneration,
                taskIsCancelled: false,
                stealthIsActive:
                    StealthEntryLatch.shared.isRaised
                        || self.companionManager.stealthActive
                        || StealthVisibilityGate.shared.isActive
            ) else {
                timer.invalidate()
                return
            }
            guard self.welcomeCharacterIndex
                    < self.fullWelcomeMessage.count else {
                timer.invalidate()
                self.welcomeAnimationTimer = nil
                self.welcomeDismissTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard OnboardingPromptCallbackAdmission.isCurrent(
                        expectedGeneration: generation,
                        currentGeneration: self.welcomeGeneration,
                        taskIsCancelled: Task.isCancelled,
                        stealthIsActive:
                            StealthEntryLatch.shared.isRaised
                                || self.companionManager.stealthActive
                                || StealthVisibilityGate.shared.isActive
                    ) else {
                        return
                    }
                    self.bubbleOpacity = 0.0
                    try? await Task.sleep(for: .milliseconds(500))
                    guard OnboardingPromptCallbackAdmission.isCurrent(
                        expectedGeneration: generation,
                        currentGeneration: self.welcomeGeneration,
                        taskIsCancelled: Task.isCancelled,
                        stealthIsActive:
                            StealthEntryLatch.shared.isRaised
                                || self.companionManager.stealthActive
                                || StealthVisibilityGate.shared.isActive
                    ) else {
                        return
                    }
                    self.showWelcome = false
                    self.welcomeDismissTask = nil
                    self.companionManager.setupOnboardingVideo()
                }
                return
            }

            let index = self.fullWelcomeMessage.index(
                self.fullWelcomeMessage.startIndex,
                offsetBy: self.welcomeCharacterIndex
            )
            self.welcomeText.append(self.fullWelcomeMessage[index])
            self.welcomeCharacterIndex += 1
        }
    }
}

// MARK: - Blue Cursor Waveform

/// A small blue waveform that replaces the triangle cursor while
/// the user is holding the push-to-talk shortcut and speaking.
private struct BlueCursorWaveformView: View {
    let audioPowerLevel: CGFloat
    let animates: Bool
    let intensity: AceMotionIntensity
    var body: some View {
        ZStack {
            BlackLabelGemCursor(bright: DS.Colors.agentGoldBright, mid: DS.Colors.agentGold,
                deep: DS.Colors.agentGoldDeep, size: AceMotionPolicy.gemSize,
                presentation: PartnerGemPresentation(appearance: .gold,
                    animationRate: animates ? 0.7 : 0, goldRimOpacity: 0, badge: .none),
                activity: .listening, audioLevel: animates ? audioPowerLevel : 0)
        }
    }
}

private struct BlueCursorSpinnerView: View {
    let animates: Bool
    let intensity: AceMotionIntensity
    var body: some View {
        ZStack {
            BlackLabelGemCursor(bright: DS.Colors.agentGoldBright, mid: DS.Colors.agentGold,
                deep: DS.Colors.agentGoldDeep, size: AceMotionPolicy.gemSize,
                presentation: PartnerGemPresentation(appearance: .gold,
                    animationRate: animates ? 1.1 : 0, goldRimOpacity: 0, badge: .none),
                activity: .thinking)
        }
    }
}

// Manager for overlay windows — creates one per screen so the cursor
// buddy seamlessly follows the cursor across multiple monitors.
@MainActor
class OverlayWindowManager {
    private var overlayWindows: [OverlayWindow] = []
    var hasShownOverlayBefore = false

    /// True while ghost mode is active — the overlay stays torn down so the gem
    /// and cursor are truly gone. CompanionManager restores the overlay on exit.
    private(set) var stealthModeIsActive = false

    /// Stealth on immediately tears the overlay down (gem + cursor vanish);
    /// stealth off is a no-op here — CompanionManager re-shows the overlay.
    func setStealthModeActive(_ stealthModeIsActive: Bool) {
        self.stealthModeIsActive = stealthModeIsActive
        if stealthModeIsActive { hideOverlay() }
    }

    @discardableResult
    func showOverlay(
        onScreens screens: [NSScreen],
        companionManager: CompanionManager
    ) -> Bool {
        guard !stealthModeIsActive,
              !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else { return false }
        // Hide any existing overlays
        hideOverlay()

        // Track if this is the first time showing overlay (welcome message)
        let isFirstAppearance = !hasShownOverlayBefore
        var committedAnyWindow = false

        // Create one overlay window per screen
        for screen in screens {
            let window = OverlayWindow(screen: screen)

            let contentView = BlueCursorView(
                screenFrame: screen.frame,
                isFirstAppearance: isFirstAppearance,
                companionManager: companionManager
            )

            let hostingView = AceHostingView(rootView: contentView)
            hostingView.frame = screen.frame
            window.contentView = hostingView

            let didShow =
                StealthEntryLatch.shared.performUnlessRaised {
                    guard !stealthModeIsActive,
                          !StealthVisibilityGate.shared.isActive else {
                        return false
                    }
                    overlayWindows.append(window)
                    window.orderFrontRegardless()
                    if !committedAnyWindow {
                        committedAnyWindow = true
                        hasShownOverlayBefore = true
                    }
                    return true
                } ?? false
            if !didShow {
                window.orderOut(nil)
                window.contentView = nil
                break
            }
        }
        return committedAnyWindow
    }

    func hideOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
            window.contentView = nil
        }
        overlayWindows.removeAll()
    }

    /// Fades out overlay windows over `duration` seconds, then removes them.
    func fadeOutAndHideOverlay(duration: TimeInterval = 0.4) {
        let windowsToFade = overlayWindows
        overlayWindows.removeAll()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in windowsToFade {
                window.animator().alphaValue = 0
            }
        }, completionHandler: {
            for window in windowsToFade {
                window.orderOut(nil)
                window.contentView = nil
            }
        })
    }

    func isShowingOverlay() -> Bool {
        return !overlayWindows.isEmpty
    }

    /// Read-only state from the actual per-screen windows. Waveform receipts
    /// use this instead of the manager's coarse requested-visible flag.
    func liveWaveformVisibility() -> WaveformOverlayVisibility {
        let visibleWindows = overlayWindows.filter { $0.isVisible }
        let nonzeroOpacityWindows = visibleWindows.filter {
            $0.alphaValue > 0.001
        }
        return WaveformOverlayVisibility(
            trackedScreenCount: overlayWindows.count,
            visibleScreenCount: visibleWindows.count,
            nonzeroOpacityScreenCount: nonzeroOpacityWindows.count
        )
    }
}

// MARK: - Onboarding Video Player

/// NSViewRepresentable wrapping an AVPlayerLayer so HLS video plays
/// inside SwiftUI. Uses a custom NSView subclass to keep the player
/// layer sized to the view's bounds automatically.
private struct OnboardingVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerNSView {
        let view = AVPlayerNSView()
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerNSView, context: Context) {
        nsView.player = player
    }
}

private class AVPlayerNSView: NSView {
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }

    private let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
#endif // circuit-convert
