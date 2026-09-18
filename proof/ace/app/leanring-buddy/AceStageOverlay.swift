#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  AceStageOverlay.swift
//  Ace — the arrival.
//
//  A transparent, click-through panel on EVERY display that Ace uses as a stage
//  for two effects the normal cursor overlay can't do:
//
//   1. THE ARRIVAL — the Mac washes gold: a nebula blooms, stars come up, and
//      the gem coalesces out of them. Ace says "much better. i'm alive again."
//      and the desktop fades back in. This is the first thing a buyer ever sees.
//   2. THE CONSTELLATION — during the walk-around, each stop drops a labelled
//      star and a gold line is drawn from the last one, so by the end the tour
//      has literally sketched Ace's capabilities across the user's own desktop.
//
//  It is a separate window from the cursor overlay on purpose: the gem's flight
//  machinery in OverlayWindow is load-bearing for every day-to-day interaction,
//  and a first-run spectacle must not be able to break it. This stage is
//  additive — it renders above the desktop, ignores every click, never takes
//  focus, and when the show ends its windows are gone.
//

import Foundation
import CircuitPortKit
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Model

/// The four states the gem can be in, and the colours that mean them.
enum AceGemAccent {
    case gold
    case red
    case blue
    case purple

    var coreColors: [Color] {
        switch self {
        case .gold: return [DS.Colors.agentGoldBright, DS.Colors.agentGold, DS.Colors.agentGoldDeep]
        case .red: return [DS.Colors.agentRedBright, DS.Colors.agentRed, DS.Colors.agentRedDeep]
        case .blue: return [DS.Colors.agentBlueBright, DS.Colors.agentBlue, DS.Colors.agentBlueDeep]
        case .purple: return [DS.Colors.agentPurpleBright, DS.Colors.agentPurple, DS.Colors.agentPurpleDeep]
        }
    }

    var haloColor: Color {
        switch self {
        case .gold: return DS.Colors.agentGoldBright
        case .red: return DS.Colors.agentRedBright
        case .blue: return DS.Colors.agentBlueBright
        case .purple: return DS.Colors.agentPurpleBright
        }
    }
}

/// One stop of the tour, rendered as a star in the constellation.
struct AceConstellationStar: Identifiable, Equatable {
    let id: Int
    /// AppKit screen coordinates (bottom-left origin, global across displays).
    let location: CGPoint
    let label: String
}

@MainActor
final class AceStageModel: ObservableObject {
    /// 0 → invisible, 1 → the galaxy at full bloom.
    @Published var galaxyIntensity: Double = 0
    /// Gold gem drawn at the heart of the galaxy while it blooms.
    @Published var showsArrivalGem: Bool = false
    /// 0 → not yet ignited, 1 → the flash has fully expanded and faded. Drives
    /// the one EVENT in the arrival: the moment the gem catches light.
    @Published var ignitionProgress: Double = 0
    /// Stars laid down so far. Appending one animates its line in.
    @Published var constellationStars: [AceConstellationStar] = []
    /// Fades the whole constellation out at the end of the tour.
    @Published var constellationOpacity: Double = 0

    /// Where the touring gem is, in AppKit global coordinates. The tour draws
    /// its OWN gem here rather than borrowing the cursor overlay's: that one is
    /// wired to mouse-following and per-screen visibility rules built for
    /// answering questions, and during the first run it simply never appeared.
    /// The introduction cannot depend on a gem that might not show up.
    @Published var gemLocation: CGPoint?
    /// Gem scale — dropping toward 0 reads as diving behind a window.
    @Published var gemScale: Double = 1

    // MARK: - Driven flight
    //
    // SwiftUI's implicit animation moved the gem in a straight line between two
    // points and called it done. Straight-line, no trail, no easing character,
    // no sense of mass — which is precisely what "the motion looks cheap" means.
    // The flight is now driven per frame from a timestamp, so it can arc, ease
    // on a real curve, leave a wake, and land with weight.

    struct GemFlight {
        let origin: CGPoint
        let destination: CGPoint
        let startedAt: TimeInterval
        let duration: TimeInterval
        /// Perpendicular bow of the arc, in points. Signed, so consecutive
        /// flights curve opposite ways instead of tracing the same lane.
        let arcHeight: CGFloat
    }

    @Published private(set) var gemFlight: GemFlight?
    /// Rings that expand and fade where the gem arrived, dived, or surfaced.
    @Published private(set) var impactRings: [ImpactRing] = []

    struct ImpactRing: Identifiable {
        let id: Int
        let location: CGPoint
        let startedAt: TimeInterval
        /// Dive rings collapse inward; arrival rings expand outward.
        let isCollapsing: Bool
    }

    private var nextImpactRingID = 0

    /// Flies the gem along an eased arc. Distance sets the duration, so a short
    /// hop is quick and a cross-screen move takes the time it visually needs
    /// instead of every move sharing one arbitrary tempo. Returns that duration
    /// so choreography can wait for the landing instead of guessing with a
    /// fixed sleep — guessing short is what made the crawl dive mid-flight.
    @discardableResult
    func flyGem(to destination: CGPoint) -> TimeInterval {
        let now = CACurrentMediaTime()
        let origin = currentGemPosition() ?? destination
        let distance = hypot(destination.x - origin.x, destination.y - origin.y)
        // 0.55s for a short hop up to 1.5s across a wide screen.
        let duration = min(1.5, max(0.55, TimeInterval(distance / 1400.0) + 0.5))
        // Bow the arc away from the straight line, alternating side each flight.
        let bow = min(190, max(38, distance * 0.20)) * (flightCount.isMultiple(of: 2) ? 1 : -1)
        flightCount += 1
        let flight = GemFlight(
            origin: origin, destination: destination,
            startedAt: now, duration: duration, arcHeight: bow)
        gemFlight = flight
        // Every arc is kept so the whole route can be light-painted behind the
        // gem — a long-exposure photograph of where it has been. That replaced
        // the dashed polyline and floating labels, which read as a diagram drawn
        // on someone's desktop rather than as light.
        lightPaintedFlights.append(flight)
        gemLocation = destination
        return duration
    }

    /// Sets the gem down with NO flight — the crawl's "surfaces on the far
    /// side" cut. Clears any in-progress flight so the per-frame draw can't
    /// keep sampling a stale arc while the resting place has already moved.
    func placeGem(at point: CGPoint) {
        gemFlight = nil
        gemLocation = point
    }

    /// Every arc the gem has flown this show, for the long-exposure trail.
    @Published private(set) var lightPaintedFlights: [GemFlight] = []

    private var flightCount = 0

    /// Where the gem is right now — mid-flight if one is running, else its
    /// resting place. Used so a new flight starts from the visible position
    /// rather than snapping to the last destination first.
    func currentGemPosition() -> CGPoint? {
        guard let flight = gemFlight else { return gemLocation }
        let elapsed = CACurrentMediaTime() - flight.startedAt
        guard elapsed < flight.duration else { return flight.destination }
        return Self.pointAlongFlight(flight, progress: elapsed / flight.duration)
    }

    /// Position along the arc at eased progress. A quadratic bezier whose control
    /// point sits off the midpoint by `arcHeight`, perpendicular to the path.
    static func pointAlongFlight(_ flight: GemFlight, progress rawProgress: Double) -> CGPoint {
        let t = easeInOutCubic(min(1, max(0, rawProgress)))
        let midpoint = CGPoint(
            x: (flight.origin.x + flight.destination.x) / 2,
            y: (flight.origin.y + flight.destination.y) / 2)
        let dx = flight.destination.x - flight.origin.x
        let dy = flight.destination.y - flight.origin.y
        let length = max(1, hypot(dx, dy))
        let perpendicular = CGPoint(x: -dy / length, y: dx / length)
        let control = CGPoint(
            x: midpoint.x + perpendicular.x * flight.arcHeight,
            y: midpoint.y + perpendicular.y * flight.arcHeight)
        let oneMinusT = 1 - t
        return CGPoint(
            x: oneMinusT * oneMinusT * flight.origin.x
                + 2 * oneMinusT * t * control.x
                + t * t * flight.destination.x,
            y: oneMinusT * oneMinusT * flight.origin.y
                + 2 * oneMinusT * t * control.y
                + t * t * flight.destination.y)
    }

    /// Slow out of rest, quick through the middle, settle in — the curve that
    /// makes a moving object read as having mass.
    static func easeInOutCubic(_ t: Double) -> Double {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    func addImpactRing(at location: CGPoint, collapsing: Bool = false) {
        nextImpactRingID += 1
        let ring = ImpactRing(
            id: nextImpactRingID, location: location,
            startedAt: CACurrentMediaTime(), isCollapsing: collapsing)
        impactRings.append(ring)
        // Rings live 0.9s; prune so the array can't grow across a long tour.
        let expiringID = ring.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.impactRings.removeAll { $0.id == expiringID }
        }
    }
    /// The gem's colour, using the same language the live gem uses every day:
    /// gold answering, red working, blue taking notes, purple in trading mode.
    /// The tour shows each one as it explains it — the colours ARE the product's
    /// state machine, and a buyer who has never seen red does not know what red
    /// means when it shows up later.
    @Published var gemAccent: AceGemAccent = .gold

    /// Fixed star field for the galaxy — generated once so the sky doesn't
    /// reshuffle on every SwiftUI redraw.
    let starField: [GalaxyStar]

    struct GalaxyStar: Identifiable {
        let id: Int
        /// Unit position within the screen (0...1), scaled at draw time so one
        /// field works on every display size.
        let unitX: Double
        let unitY: Double
        let radius: Double
        let baseBrightness: Double
        /// Offsets each star's twinkle so the sky doesn't blink in unison.
        let twinklePhase: Double
    }

    /// Real footage for the arrival, when the bundle ships it. Filmed footage
    /// beats anything drawable in SwiftUI for this one moment, so if
    /// `arrival.mp4` is inside the app it plays; if it isn't, the procedural
    /// nebula below runs and the introduction still works. The show never
    /// depends on an asset that might be missing.
    static let arrivalVideoURL: URL? = Bundle.main.url(forResource: "arrival", withExtension: "mp4")

    /// One shared, muted, looping player drives every display, so a multi-monitor
    /// arrival stays in sync instead of three clips drifting apart.
    let arrivalPlayer: AVQueuePlayer? = {
        guard let url = AceStageModel.arrivalVideoURL else { return nil }
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        return player
    }()

    private var arrivalLooper: AVPlayerLooper?

    /// Starts the arrival footage from the top. Safe to call with no video.
    func startArrivalVideo() {
        guard let player = arrivalPlayer, let url = Self.arrivalVideoURL else { return }
        if arrivalLooper == nil {
            arrivalLooper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        }
        player.seek(to: .zero)
        player.play()
    }

    func stopArrivalVideo() {
        arrivalPlayer?.pause()
    }

    init(starCount: Int = 220) {
        // Deterministic pseudo-random: a fixed seed means the sky is identical
        // on every display and every launch, which matters when the same show
        // has to look composed across three monitors.
        var seed: UInt64 = 0x5DEECE66D
        func nextUnit() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 11) & 0xFFFFFFFF) / Double(0xFFFFFFFF)
        }
        starField = (0..<starCount).map { index in
            GalaxyStar(
                id: index,
                unitX: nextUnit(),
                unitY: nextUnit(),
                radius: 0.6 + nextUnit() * 1.9,
                baseBrightness: 0.35 + nextUnit() * 0.65,
                twinklePhase: nextUnit() * 6.283
            )
        }
    }
}

// MARK: - Window controller

@MainActor
final class AceStageOverlayController {
    static let shared = AceStageOverlayController()

    let model = AceStageModel()
    private var stageWindows: [NSWindow] = []

    /// Opens one stage window per display. Safe to call twice — the second call
    /// is a no-op rather than a second stack of windows.
    func present() {
        guard stageWindows.isEmpty,
              !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            // Above everything including full-screen apps, but it can never take
            // focus or eat a click — the user stays in control of their Mac
            // through the entire show.
            window.level = .floating
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let hostingView = AceHostingView(
                rootView: AceStageView(model: model, screenFrame: screen.frame)
            )
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            hostingView.layer?.isOpaque = false
            window.contentView = hostingView
            window.setFrame(screen.frame, display: true)
            let didShow =
                StealthEntryLatch.shared.performUnlessRaised {
                    guard !StealthVisibilityGate.shared.isActive else {
                        return false
                    }
                    window.orderFrontRegardless()
                    stageWindows.append(window)
                    return true
                } ?? false
            if !didShow {
                window.orderOut(nil)
                window.contentView = nil
                dismiss()
                return
            }
        }
        let didStart =
            StealthEntryLatch.shared.performUnlessRaised {
                guard !StealthVisibilityGate.shared.isActive else {
                    return false
                }
                model.startArrivalVideo()
                return true
            } ?? false
        if !didStart {
            dismiss()
        }
    }

    func dismiss() {
        model.stopArrivalVideo()
        for window in stageWindows {
            window.orderOut(nil)
        }
        stageWindows.removeAll()
        model.galaxyIntensity = 0
        model.showsArrivalGem = false
        model.constellationStars = []
        model.constellationOpacity = 0
    }

    var isPresented: Bool { !stageWindows.isEmpty }
}

// MARK: - View

private struct AceStageView: View {
    @ObservedObject var model: AceStageModel
    /// This display's frame in AppKit global coordinates — used to convert the
    /// tour's global star positions into this window's local space.
    let screenFrame: CGRect

    var body: some View {
        // Native refresh rate: the gem covers ~47pt per frame at flight speed on a
        // 3440-wide screen when capped to 30fps, and every direction change strobes.
        // Invisible layers are skipped entirely so full-rate stays cheap once the
        // galaxy and constellation have faded out.
        TimelineView(.animation) { timeline in
            let animationTime = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                if model.galaxyIntensity > 0 {
                    galaxyLayer(animationTime: animationTime)
                        .opacity(model.galaxyIntensity)
                }
                if model.constellationOpacity > 0 {
                    constellationLayer(animationTime: animationTime)
                        .opacity(model.constellationOpacity)
                }
                tourGemLayer(animationTime: animationTime)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: Galaxy

    private func galaxyLayer(animationTime: TimeInterval) -> some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                // The wash: deep space, not pure black, so the desktop reads as
                // "submerged" rather than "the monitor turned off".
                Color(red: 0.02, green: 0.02, blue: 0.03)
                    .opacity(0.94)

                if let arrivalPlayer = model.arrivalPlayer {
                    // Real footage fills the screen; the star field and the
                    // assembling gem still composite on top of it.
                    ArrivalVideoLayer(player: arrivalPlayer)
                        .allowsHitTesting(false)
                }

                // Gold nebula — three slow, counter-rotating clouds. Drawn only
                // when there is NO footage: the clip already carries its own
                // nebula and star field, and doubling them just muddies it.
                ForEach(0..<(model.arrivalPlayer == nil ? 3 : 0), id: \.self) { cloudIndex in
                    let drift = sin(animationTime * 0.11 + Double(cloudIndex) * 2.1)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    nebulaColor(cloudIndex).opacity(0.55),
                                    nebulaColor(cloudIndex).opacity(0.0),
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: size.width * 0.34
                            )
                        )
                        .frame(width: size.width * 0.85, height: size.width * 0.85)
                        // Clouds stay gathered around the middle, where the gem
                        // assembles — spread across the full width of an
                        // ultrawide they read as three unrelated smudges.
                        .offset(
                            x: CGFloat(drift) * size.width * 0.10 + CGFloat(cloudIndex - 1) * size.width * 0.11,
                            y: CGFloat(cos(animationTime * 0.09 + Double(cloudIndex))) * size.height * 0.10
                        )
                        .blur(radius: 70)
                }

                // Sharp parallax stars, drawn at native resolution ON TOP of the
                // footage. The plate is an upscaled 2K crop, so it is inherently
                // soft; crisp points at three depths in front of it restore the
                // detail the upscale can't carry, and the depth-differentiated
                // drift is what makes it read as space rather than a texture.
                Canvas { context, canvasSize in
                    for star in model.starField {
                        // Depth from the star's own size: bigger = nearer =
                        // drifts further.
                        let depth = star.radius / 2.5
                        let drift = animationTime * (4 + depth * 26)
                        let twinkle = 0.5 + 0.5 * sin(animationTime * (1.4 + depth) + star.twinklePhase)
                        let x = (star.unitX * canvasSize.width + CGFloat(drift))
                            .truncatingRemainder(dividingBy: canvasSize.width)
                        let y = star.unitY * canvasSize.height
                        let radius = star.radius * (0.5 + depth * 0.5)
                        let brightness = star.baseBrightness * twinkle * (0.45 + depth * 0.55)
                        let starRect = CGRect(
                            x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                        context.fill(
                            Path(ellipseIn: starRect),
                            with: .color(Color(red: 1.0, green: 0.95, blue: 0.83).opacity(brightness)))
                    }
                }
                .blendMode(.screen)

                // Legacy procedural star field, only when there is no footage.
                Canvas { context, canvasSize in
                    guard model.arrivalPlayer == nil else { return }
                    for star in model.starField {
                        let twinkle = 0.55 + 0.45 * sin(animationTime * 1.7 + star.twinklePhase)
                        let brightness = star.baseBrightness * twinkle
                        let point = CGPoint(
                            x: star.unitX * canvasSize.width,
                            y: star.unitY * canvasSize.height
                        )
                        let starRect = CGRect(
                            x: point.x - star.radius,
                            y: point.y - star.radius,
                            width: star.radius * 2,
                            height: star.radius * 2
                        )
                        context.fill(
                            Path(ellipseIn: starRect),
                            with: .color(Color(red: 1.0, green: 0.94, blue: 0.78).opacity(brightness))
                        )
                    }
                }

                if model.showsArrivalGem {
                    // SQUARE frame, explicitly centered. Constraining only the
                    // width let the gem's own GeometryReader stretch to the full
                    // window height, which parked it at the bottom edge of an
                    // ultrawide display instead of the middle of the sky.
                    let gemSide = min(size.width, size.height) * 0.34
                    ArrivalGem(animationTime: animationTime, ignition: model.ignitionProgress)
                        .frame(width: gemSide, height: gemSide)
                        .position(x: size.width / 2, y: size.height / 2)

                    // The ignition flash and its shockwave: the moment the gem
                    // catches. Without a beat like this the arrival has no event
                    // in it — it just fades up, which is what read as cheap.
                    if model.ignitionProgress > 0, model.ignitionProgress < 1 {
                        let flash = sin(model.ignitionProgress * .pi)
                        Circle()
                            .fill(
                                RadialGradient(
                                    colors: [.white.opacity(flash * 0.55),
                                             DS.Colors.agentGoldBright.opacity(flash * 0.3),
                                             .clear],
                                    center: .center, startRadius: 0,
                                    endRadius: size.width * 0.5 * model.ignitionProgress))
                            .blendMode(.screen)
                        Circle()
                            .stroke(DS.Colors.agentGoldBright.opacity((1 - model.ignitionProgress) * 0.7),
                                    lineWidth: 2.5)
                            .frame(width: size.width * 0.9 * model.ignitionProgress,
                                   height: size.width * 0.9 * model.ignitionProgress)
                            .blur(radius: 2)
                            .position(x: size.width / 2, y: size.height / 2)
                    }
                }

                // Grade: a vignette to pull the eye to centre, and a whisper of
                // grain so the gradients don't band on a large panel. Both are
                // what separates "a dark rectangle with a video in it" from a
                // shot.
                RadialGradient(
                    colors: [.clear, .black.opacity(0.55)],
                    center: .center,
                    startRadius: size.width * 0.22,
                    endRadius: size.width * 0.72
                )
                .allowsHitTesting(false)

                Canvas { context, canvasSize in
                    // Cheap animated grain: a sparse scatter reseeded per frame
                    // from the frame time.
                    let grainCount = 260
                    var seed = UInt64(animationTime * 60) &* 6364136223846793005
                    for _ in 0..<grainCount {
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        let x = Double((seed >> 11) & 0xFFFF) / 65535.0 * canvasSize.width
                        seed = seed &* 6364136223846793005 &+ 1442695040888963407
                        let y = Double((seed >> 11) & 0xFFFF) / 65535.0 * canvasSize.height
                        context.fill(
                            Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)),
                            with: .color(.white.opacity(0.035)))
                    }
                }
                .blendMode(.overlay)
                .allowsHitTesting(false)
            }
        }
    }

    private func nebulaColor(_ index: Int) -> Color {
        switch index {
        case 0: return DS.Colors.agentGoldBright
        case 1: return DS.Colors.agentGold
        default: return DS.Colors.agentGoldDeep
        }
    }

    // MARK: Constellation

    private func constellationLayer(animationTime: TimeInterval) -> some View {
        GeometryReader { geometry in
            let mediaTime = CACurrentMediaTime()
            ZStack {
                // LONG EXPOSURE. Each arc the gem flew is redrawn as a soft
                // additive stroke that decays with age, so the screen slowly
                // accumulates a light-painted record of the route. Sampled along
                // the same bezier the gem actually travelled, so the trail and
                // the movement are the same curve — not an approximation of it.
                Canvas { context, canvasSize in
                    for flight in model.lightPaintedFlights {
                        let age = mediaTime - flight.startedAt
                        guard age < 26 else { continue }
                        // Only paint the part already flown.
                        let flownFraction = min(1.0, max(0.0, age / flight.duration))
                        guard flownFraction > 0.02 else { continue }
                        let decay = max(0.0, 1.0 - age / 26.0)

                        var path = Path()
                        let sampleCount = 26
                        for sampleIndex in 0...sampleCount {
                            let progress = (Double(sampleIndex) / Double(sampleCount)) * flownFraction
                            let worldPoint = AceStageModel.pointAlongFlight(flight, progress: progress)
                            guard screenFrame.contains(worldPoint) else { continue }
                            let localPointOnScreen = localPoint(for: worldPoint, in: canvasSize)
                            if path.isEmpty {
                                path.move(to: localPointOnScreen)
                            } else {
                                path.addLine(to: localPointOnScreen)
                            }
                        }
                        guard !path.isEmpty else { continue }

                        // Three passes: a wide dim bloom, a mid stroke, and a hot
                        // hairline core. That stack is what makes a line read as
                        // glowing light rather than as a coloured stroke.
                        context.blendMode = .screen
                        context.stroke(
                            path,
                            with: .color(model.gemAccent.haloColor.opacity(0.10 * decay)),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        context.stroke(
                            path,
                            with: .color(model.gemAccent.haloColor.opacity(0.22 * decay)),
                            style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                        context.stroke(
                            path,
                            with: .color(.white.opacity(0.30 * decay)),
                            style: StrokeStyle(lineWidth: 0.8, lineCap: .round))
                        context.blendMode = .normal
                    }
                }
                .blur(radius: 0.6)

                // A small hot spark where each stop happened — no captions. The
                // desktop is the user's, not a slide.
                ForEach(model.constellationStars) { star in
                    if screenFrame.contains(star.location) {
                        StopSpark(pulse: 0.5 + 0.5 * sin(animationTime * 2.0 + Double(star.id)))
                            .position(localPoint(for: star.location, in: geometry.size))
                    }
                }
            }
        }
    }

    // MARK: Touring gem

    @ViewBuilder
    private func tourGemLayer(animationTime: TimeInterval) -> some View {
        GeometryReader { geometry in
            // Driven per frame off the flight timestamp rather than handed to
            // SwiftUI's implicit animator: that is what buys the arc, the wake,
            // and the easing character.
            let mediaTime = CACurrentMediaTime()
            let livePosition = liveGemPosition(at: mediaTime)

            ZStack {
                // The wake: earlier samples of the same arc, fading and
                // shrinking behind the gem. Only drawn while actually moving.
                if let flight = model.gemFlight {
                    let elapsed = mediaTime - flight.startedAt
                    if elapsed < flight.duration {
                        let progress = elapsed / flight.duration
                        ForEach(1...7, id: \.self) { trailIndex in
                            let lag = Double(trailIndex) * 0.035
                            let trailProgress = max(0, progress - lag)
                            let trailPoint = AceStageModel.pointAlongFlight(flight, progress: trailProgress)
                            let fade = (1.0 - Double(trailIndex) / 8.0) * 0.5
                            Circle()
                                .fill(model.gemAccent.haloColor.opacity(fade * 0.55))
                                .frame(width: 22 - Double(trailIndex) * 2.1,
                                       height: 22 - Double(trailIndex) * 2.1)
                                .blur(radius: 3)
                                .position(localPoint(for: trailPoint, in: geometry.size))
                        }
                    }
                }

                // Impact rings: a soft ring expanding where it landed, or
                // collapsing inward where it dived under a window.
                ForEach(model.impactRings) { ring in
                    let age = mediaTime - ring.startedAt
                    if age < 0.9, screenFrame.contains(ring.location) {
                        let t = age / 0.9
                        let eased = 1 - pow(1 - t, 3)
                        let diameter = ring.isCollapsing ? (150 * (1 - eased) + 18) : (26 + eased * 150)
                        Circle()
                            .stroke(model.gemAccent.haloColor.opacity((1 - t) * 0.55), lineWidth: 1.6)
                            .frame(width: diameter, height: diameter)
                            .position(localPoint(for: ring.location, in: geometry.size))
                    }
                }

                if let livePosition, screenFrame.contains(livePosition) {
                    TouringGem(
                        animationTime: animationTime,
                        accent: model.gemAccent,
                        speedStretch: flightStretch(at: mediaTime)
                    )
                    .frame(width: 54, height: 54)
                    .animation(.easeInOut(duration: 0.45), value: model.gemAccent == .gold)
                    // The spade FLIES like a thing with a nose: tip leading the
                    // travel direction (founder 2026-07-26 — it used to glide
                    // right-side-up through every arc, which reads as a sprite
                    // being dragged, not a stone in flight). Recomputed per
                    // frame from the arc's tangent; ramps make it take off and
                    // land upright.
                    .rotationEffect(.degrees(flightHeadingDegrees(at: mediaTime)))
                    .scaleEffect(model.gemScale)
                    .position(localPoint(for: livePosition, in: geometry.size))
                    .animation(.easeInOut(duration: 0.28), value: model.gemScale)
                }
            }
        }
    }

    /// The gem's position this frame: along the arc mid-flight, at rest otherwise.
    private func liveGemPosition(at mediaTime: TimeInterval) -> CGPoint? {
        guard let flight = model.gemFlight else { return model.gemLocation }
        let elapsed = mediaTime - flight.startedAt
        guard elapsed < flight.duration else { return model.gemLocation }
        return AceStageModel.pointAlongFlight(flight, progress: elapsed / flight.duration)
    }

    /// 0 at rest, up to ~0.35 at peak speed. Peaks mid-flight, where the eased
    /// curve is fastest.
    private func flightStretch(at mediaTime: TimeInterval) -> Double {
        guard let flight = model.gemFlight else { return 0 }
        let elapsed = mediaTime - flight.startedAt
        guard elapsed < flight.duration else { return 0 }
        let progress = elapsed / flight.duration
        return sin(progress * .pi) * 0.35
    }

    /// The gem's heading this frame, in SwiftUI rotation degrees: 0 = upright,
    /// rotated so the spade's TIP leads the direction of travel. Sampled from
    /// the eased arc's tangent, and ramped — banking in over the first fifth
    /// of the flight and back out over the last — so the stone takes off
    /// upright, leans into the arc, and touches down upright.
    private func flightHeadingDegrees(at mediaTime: TimeInterval) -> Double {
        guard let flight = model.gemFlight else { return 0 }
        let elapsed = mediaTime - flight.startedAt
        guard elapsed >= 0, elapsed < flight.duration else { return 0 }
        let progress = elapsed / flight.duration

        // Tangent by symmetric sampling. Flight points are AppKit (y-up);
        // SwiftUI rotation is y-down, so the vertical component flips.
        let sampleStep = 0.02
        let pointBehind = AceStageModel.pointAlongFlight(flight, progress: max(0, progress - sampleStep))
        let pointAhead = AceStageModel.pointAlongFlight(flight, progress: min(1, progress + sampleStep))
        let deltaX = pointAhead.x - pointBehind.x
        let deltaY = -(pointAhead.y - pointBehind.y)
        guard abs(deltaX) > 0.01 || abs(deltaY) > 0.01 else { return 0 }

        // atan2's 0° points rightward; the spade's tip points UP (-90°), so
        // tip-leads-travel is the travel angle plus 90°.
        var headingDegrees = atan2(deltaY, deltaX) * 180 / .pi + 90
        // Normalize so the blend to/from upright never spins the long way round.
        while headingDegrees > 180 { headingDegrees -= 360 }
        while headingDegrees < -180 { headingDegrees += 360 }

        let bankIn = min(1.0, progress / 0.18)
        let bankOut = min(1.0, (1 - progress) / 0.22)
        return headingDegrees * bankIn * bankOut
    }

    /// AppKit global (bottom-left origin) → this window's SwiftUI space
    /// (top-left origin).
    private func localPoint(for globalPoint: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: globalPoint.x - screenFrame.minX,
            y: size.height - (globalPoint.y - screenFrame.minY)
        )
    }
}

private struct StopSpark: View {
    let pulse: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(DS.Colors.agentGoldBright.opacity(0.18 + 0.22 * pulse))
                .frame(width: 30, height: 30)
                .blur(radius: 8)
            Path { path in
                path.move(to: CGPoint(x: 0, y: 8)); path.addLine(to: CGPoint(x: 16, y: 8))
                path.move(to: CGPoint(x: 8, y: 0)); path.addLine(to: CGPoint(x: 8, y: 16))
            }
            .stroke(DS.Colors.agentGoldBright.opacity(0.5 + 0.3 * pulse), lineWidth: 0.8)
            .frame(width: 16, height: 16)
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 2.6, height: 2.6)
        }
        .allowsHitTesting(false)
    }
}

/// AVPlayerLayer host for the arrival footage. `resizeAspectFill` so a 16:9
/// clip still covers an ultrawide without letterboxing the show.
private struct ArrivalVideoLayer: NSViewRepresentable {
    let player: AVQueuePlayer

    func makeNSView(context: Context) -> NSView {
        let hostView = NSView()
        hostView.wantsLayer = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = hostView.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        hostView.layer?.addSublayer(playerLayer)
        return hostView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.sublayers?.forEach { $0.frame = nsView.bounds }
    }
}

/// The gem as it walks the desktop: a glowing core with a live corona and a
/// faint wake, gold normally and purple while trading mode is on.
/// A CUT gem, not a coloured circle.
///
/// A filled circle with a gradient reads as a UI dot; a gem reads as expensive
/// because of things a circle cannot do — flat facets that each catch the light
/// differently, a metal bezel with its own specular arc, colour splitting at the
/// edges, and a caustic flare off whichever facet currently faces the light. All
/// of it is drawn in one Canvas pass against a slowly rotating light direction,
/// so the stone appears to turn under a fixed lamp rather than animate.
/// The same cut stone the daily cursor uses, at any size: an ace-of-spades
/// silhouette with faceted interior shading, a metal girdle, edge dispersion and
/// a caustic flare. Shares `aceSpadePath` with the cursor gem and the menu-bar
/// glyph so every gem in the product is one object at different scales.
struct AceCutGem: View {
    let accent: AceGemAccent
    let animationTime: TimeInterval
    /// Widens the stone along travel while it's moving.
    var speedStretch: Double = 0

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, canvasSize in
                // The stone occupies the middle of its frame so the bloom drawn
                // behind it by the caller has room to breathe.
                let stoneSize = CGSize(width: canvasSize.width * 0.42,
                                       height: canvasSize.height * 0.56)
                let originOffset = CGPoint(x: (canvasSize.width - stoneSize.width) / 2,
                                           y: (canvasSize.height - stoneSize.height) / 2)
                let silhouette = aceSpadePath(in: stoneSize)
                    .offsetBy(dx: originOffset.x, dy: originOffset.y)
                let centre = CGPoint(x: canvasSize.width / 2,
                                     y: originOffset.y + stoneSize.height * 0.46)
                let reach = max(stoneSize.width, stoneSize.height)
                let lightAngle = animationTime * 0.42
                let colors = accent.coreColors
                let bright = colors[0], mid = colors[1], deep = colors[2]

                context.drawLayer { layerContext in
                    layerContext.clip(to: silhouette)
                    layerContext.fill(
                        silhouette,
                        with: .radialGradient(
                            Gradient(colors: [mid.opacity(0.5), Color.black.opacity(0.72)]),
                            center: centre, startRadius: 0, endRadius: reach * 0.6))

                    let facetCount = 8
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
                        let litness = pow(max(0, cos(facetAngle - lightAngle)), 2.0)
                        let faceEdge = Color.white.opacity(0.05 + 0.6 * litness)
                        let faceBody = litness > 0.5 ? bright : (litness > 0.12 ? mid : Color.black.opacity(0.62))
                        layerContext.fill(
                            wedge,
                            with: .linearGradient(
                                Gradient(colors: [faceBody.opacity(0.4 + 0.6 * litness), faceEdge]),
                                startPoint: centre,
                                endPoint: CGPoint(x: centre.x + cos(facetAngle) * reach * 0.5,
                                                  y: centre.y + sin(facetAngle) * reach * 0.5)))
                        layerContext.stroke(
                            wedge, with: .color(bright.opacity(0.09 + 0.30 * litness)), lineWidth: 0.6)
                    }
                }

                // Metal girdle, bright where the lamp lands.
                let lampSide = CGPoint(x: centre.x + cos(lightAngle) * reach * 0.6,
                                       y: centre.y + sin(lightAngle) * reach * 0.6)
                let shadowSide = CGPoint(x: centre.x - cos(lightAngle) * reach * 0.6,
                                         y: centre.y - sin(lightAngle) * reach * 0.6)
                context.stroke(
                    silhouette,
                    with: .linearGradient(
                        Gradient(colors: [.white.opacity(0.9), bright.opacity(0.85), deep.opacity(0.45)]),
                        startPoint: lampSide, endPoint: shadowSide),
                    lineWidth: max(1.0, reach * 0.012))

                // Dispersion at the edges.
                context.blendMode = .screen
                context.translateBy(x: 1.0, y: -0.7)
                context.stroke(silhouette, with: .color(Color(red: 1, green: 0.74, blue: 0.38).opacity(0.34)), lineWidth: 0.8)
                context.translateBy(x: -2.0, y: 1.4)
                context.stroke(silhouette, with: .color(Color(red: 0.52, green: 0.77, blue: 1).opacity(0.28)), lineWidth: 0.8)
                context.translateBy(x: 1.0, y: -0.7)

                // Caustic flare off the facet facing the lamp.
                let flareCentre = CGPoint(x: centre.x + cos(lightAngle) * reach * 0.34,
                                          y: centre.y + sin(lightAngle) * reach * 0.34)
                let flareLength = reach * 0.6
                var flare = Path()
                flare.move(to: CGPoint(x: flareCentre.x - flareLength, y: flareCentre.y))
                flare.addLine(to: CGPoint(x: flareCentre.x + flareLength, y: flareCentre.y))
                flare.move(to: CGPoint(x: flareCentre.x, y: flareCentre.y - flareLength * 0.55))
                flare.addLine(to: CGPoint(x: flareCentre.x, y: flareCentre.y + flareLength * 0.55))
                context.stroke(flare, with: .color(.white.opacity(0.34)), lineWidth: 0.9)
                context.fill(
                    Path(ellipseIn: CGRect(x: flareCentre.x - 2.2, y: flareCentre.y - 2.2, width: 4.4, height: 4.4)),
                    with: .color(.white.opacity(0.92)))
                context.blendMode = .normal
            }
            // Stretch along the TIP axis (local vertical): the gem now rotates
            // so its tip leads the travel direction, which makes "along travel"
            // the local Y. The old horizontal stretch assumed an unrotated gem
            // and would smear it SIDEWAYS mid-bank.
            .scaleEffect(x: 1 - speedStretch * 0.2, y: 1 + speedStretch * 0.45)
        }
    }
}

private struct TouringGem: View {
    let animationTime: TimeInterval
    let accent: AceGemAccent
    /// 0 at rest, ~0.35 at peak speed. Stretches the gem along travel and
    /// pushes the bloom, so fast motion looks fast rather than looking like a
    /// sprite that changed coordinates.
    var speedStretch: Double = 0

    private var coreColors: [Color] { accent.coreColors }
    private var haloColor: Color { accent.haloColor }

    var body: some View {
        let breathe = 1 + 0.06 * sin(animationTime * 2.4)
        ZStack {
            // Outer bloom — wide, soft, and brighter while moving.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [haloColor.opacity(0.42 + speedStretch * 0.5), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 38
                    )
                )
                .scaleEffect(breathe * (1 + speedStretch * 0.5))
                .blur(radius: 5)

            // Tight inner bloom — gives the core an actual falloff instead of a
            // hard edge against the desktop.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [haloColor.opacity(0.85), haloColor.opacity(0.0)],
                        center: .center,
                        startRadius: 1,
                        endRadius: 20
                    )
                )
                .blur(radius: 2)

            // Orbiting motes — the gem reads as alive even while it sits still
            // waiting for the user to hold the keys. They trail back when fast.
            ForEach(0..<7, id: \.self) { moteIndex in
                let angle = Double(moteIndex) / 7.0 * 6.283 + animationTime * 1.1
                let orbit = 25.0 + speedStretch * 6.0
                Circle()
                    .fill(haloColor)
                    .frame(width: 3.2, height: 3.2)
                    .offset(x: CGFloat(cos(angle)) * orbit, y: CGFloat(sin(angle)) * orbit)
                    .opacity(0.7 - speedStretch * 0.35)
            }

            // The stone itself — faceted, bezelled, dispersing at the edges.
            AceCutGem(accent: accent, animationTime: animationTime, speedStretch: speedStretch)
                .frame(width: 54, height: 54)
                .shadow(color: haloColor.opacity(0.75), radius: 12)
        }
    }
}

/// The gem assembling itself out of the galaxy: an outer ring of gold motes
/// spiralling inward while the core brightens.
private struct ArrivalGem: View {
    let animationTime: TimeInterval
    /// 0 before ignition (a distant, dim point) → 1 fully lit. The gem arrives
    /// from far away rather than fading up in place.
    var ignition: Double = 1

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            // Before ignition the gem is small and dim, as if far off; the
            // ignition brings it to full size and brightness.
            let approach = 0.35 + 0.65 * AceStageModel.easeInOutCubic(min(1, max(0, ignition)))
            ZStack {
                // Motes drawing in toward the core.
                ForEach(0..<18, id: \.self) { moteIndex in
                    let angle = Double(moteIndex) / 18.0 * 6.283 + animationTime * 0.6
                    let orbit = size * 0.42 * (0.55 + 0.45 * abs(sin(animationTime * 0.5 + Double(moteIndex))))
                    Circle()
                        .fill(DS.Colors.agentGoldBright)
                        .frame(width: size * 0.022, height: size * 0.022)
                        .offset(x: CGFloat(cos(angle)) * orbit, y: CGFloat(sin(angle)) * orbit)
                        .opacity(0.55)
                        .blur(radius: 0.6)
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [DS.Colors.agentGoldBright.opacity(0.75), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.45
                        )
                    )
                    .scaleEffect(1 + 0.06 * sin(animationTime * 1.6))

                AceCutGem(accent: .gold, animationTime: animationTime)
                    .frame(width: size, height: size)
                    .shadow(color: DS.Colors.agentGold.opacity(0.8), radius: size * 0.10)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .scaleEffect(approach)
            .opacity(0.25 + 0.75 * min(1, max(0, ignition)))
        }
    }
}
#endif // circuit-convert
