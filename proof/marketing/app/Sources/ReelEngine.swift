// Black Label Marketing — Reel / short-video engine.
// REAL native render: composes titled scenes (with the buyer's brand colors,
// optional logo, and per-scene background image) into an actual exported .mp4
// via AVAssetWriter + CoreGraphics. No paid tools, no network, no stubs.
//
// The pure parts (storyboard model, timing math, style resolution, layout math)
// are split from the AVFoundation render so they can be unit-tested headlessly.
//
// VISUAL SYSTEM (v2 — the "make it Apple-quality" rewrite):
//   • A real design-system: eyebrow / display headline / subtitle / CTA-chip stack,
//     auto-fit typography (long names shrink to fit, never clip), letter-spacing,
//     serif or sans display face per style.
//   • Controlled lighting — a CONTAINED accent glow that fades to CLEAR (not to the
//     base color), plus a vignette and fine grain. The old renderer mixed accent(0.22)
//     straight into an opaque base, which produced a muddy olive wash; the new glow
//     never touches the mid-field, so backgrounds stay rich and clean.
//   • Staggered element entrance + per-scene fade, all computed from scene progress so
//     the .mp4 and the still poster agree frame-for-frame.
//   • Story-style progress segments pinned to the safe area, one per scene.
import Foundation
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(CoreImage) && !CIRCUIT_WINDOWS_SIM
import CoreImage
#endif
#if canImport(ImageIO) && !CIRCUIT_WINDOWS_SIM
import ImageIO
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit   // NSMutableParagraphStyle / NSTextAlignment / NSString text drawing live in UIKit on iOS
#endif

// MARK: - Storyboard model (pure, Codable, testable)

/// How a scene's content animates in. Real per-frame motion (not just a text fade), computed
/// deterministically from scene progress so the .mp4 render and the poster agree.
enum SceneTransition: String, Codable, CaseIterable, Identifiable {
    case fade, slideLeft, slideUp, zoomIn, kenBurns
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fade: return "Fade"
        case .slideLeft: return "Slide"
        case .slideUp: return "Rise"
        case .zoomIn: return "Zoom"
        case .kenBurns: return "Ken Burns"
        }
    }
}

/// Non-destructive photo looks applied during the native render. These stay intentionally small and
/// useful: the original picked image is never changed, so every adjustment can be reset.
enum ReelPhotoFilter: String, Codable, CaseIterable, Identifiable {
    case original = "Original"
    case vivid = "Vivid"
    case warm = "Warm"
    case cool = "Cool"
    case mono = "Mono"
    var id: String { rawValue }
}

/// The role a scene plays in the story — drives layout emphasis (a CTA renders its
/// subtitle as a tappable-looking chip; an opener leans on the eyebrow/logo lockup).
enum SceneKind: String, Codable, CaseIterable, Identifiable {
    case opener, standard, cta
    var id: String { rawValue }
}

/// One scene of a reel: an optional eyebrow + headline + optional subtitle, shown for `seconds`.
struct ReelScene: Identifiable, Codable, Hashable {
    var id = UUID()
    /// Small tracked label above the headline (category, city, "Now booking"). Optional.
    var eyebrow: String = ""
    var headline: String = ""
    var subtitle: String = ""
    var seconds: Double = 2.5
    /// Optional background image (buyer's own asset), stored as file-relative name
    /// within the project's asset library. Empty = gradient background.
    var imageName: String = ""
    /// Motion applied to this scene's content. Default fade keeps old projects identical.
    var transition: SceneTransition = .fade
    /// The scene's role (opener/standard/cta). Drives CTA-chip vs plain-subtitle layout.
    var kind: SceneKind = .standard
    /// Optional explicit narration for this scene; empty = use headline + subtitle.
    var voiceScript: String = ""
    /// Independent timeline layers. Photo and text can be positioned/faded without touching the
    /// source asset; the values are baked into the exported MP4.
    var photoScale: Double = 1.0
    var photoRotation: Double = 0
    var photoOffsetX: Double = 0
    var photoOffsetY: Double = 0
    var photoOpacity: Double = 1.0
    var photoFilter: ReelPhotoFilter = .original
    var photoFadeIn: Double = 0.25
    var photoFadeOut: Double = 0.35
    var overlayOpacity: Double = 1.0
    var overlayFadeIn: Double = 0.25
    var overlayFadeOut: Double = 0.35
    /// Optional buyer footage for this scene (trimmed in/out; the scene plays real video frames
    /// instead of a photo background). nil = existing photo/gradient behavior, unchanged.
    var videoClip: ReelVideoClip? = nil
    /// Optional SECOND take composited over this scene as a corner picture-in-picture tile — the
    /// presenter talking over a screen recording, a demo, or a product shot. nil = no tile drawn,
    /// so every scene saved before this existed renders byte-identically. See ReelPresenterOverlay.
    var presenter: ReelPresenterOverlay? = nil

    init(id: UUID = UUID(), eyebrow: String = "", headline: String = "", subtitle: String = "",
         seconds: Double = 2.5, imageName: String = "", transition: SceneTransition = .fade,
         kind: SceneKind = .standard, voiceScript: String = "",
         photoScale: Double = 1, photoRotation: Double = 0, photoOffsetX: Double = 0,
         photoOffsetY: Double = 0, photoOpacity: Double = 1, photoFilter: ReelPhotoFilter = .original,
         photoFadeIn: Double = 0.25, photoFadeOut: Double = 0.35, overlayOpacity: Double = 1,
         overlayFadeIn: Double = 0.25, overlayFadeOut: Double = 0.35, videoClip: ReelVideoClip? = nil,
         presenter: ReelPresenterOverlay? = nil) {
        self.id = id; self.eyebrow = eyebrow; self.headline = headline; self.subtitle = subtitle
        self.seconds = seconds; self.imageName = imageName; self.transition = transition
        self.kind = kind; self.voiceScript = voiceScript
        self.photoScale = photoScale; self.photoRotation = photoRotation
        self.photoOffsetX = photoOffsetX; self.photoOffsetY = photoOffsetY
        self.photoOpacity = photoOpacity; self.photoFilter = photoFilter
        self.photoFadeIn = photoFadeIn; self.photoFadeOut = photoFadeOut
        self.overlayOpacity = overlayOpacity; self.overlayFadeIn = overlayFadeIn
        self.overlayFadeOut = overlayFadeOut
        self.videoClip = videoClip
        self.presenter = presenter
    }
}

// Robust decode: fields added over time (eyebrow, kind) default when absent, so a reel saved by an
// older build still loads instead of throwing keyNotFound (synthesized Codable would reject it).
extension ReelScene {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        eyebrow = (try? c.decodeIfPresent(String.self, forKey: .eyebrow)) ?? ""
        headline = (try? c.decode(String.self, forKey: .headline)) ?? ""
        subtitle = (try? c.decode(String.self, forKey: .subtitle)) ?? ""
        seconds = (try? c.decode(Double.self, forKey: .seconds)) ?? 2.5
        imageName = (try? c.decode(String.self, forKey: .imageName)) ?? ""
        transition = (try? c.decodeIfPresent(SceneTransition.self, forKey: .transition)) ?? .fade
        kind = (try? c.decodeIfPresent(SceneKind.self, forKey: .kind)) ?? .standard
        voiceScript = (try? c.decodeIfPresent(String.self, forKey: .voiceScript)) ?? ""
        photoScale = (try? c.decodeIfPresent(Double.self, forKey: .photoScale)) ?? 1
        photoRotation = (try? c.decodeIfPresent(Double.self, forKey: .photoRotation)) ?? 0
        photoOffsetX = (try? c.decodeIfPresent(Double.self, forKey: .photoOffsetX)) ?? 0
        photoOffsetY = (try? c.decodeIfPresent(Double.self, forKey: .photoOffsetY)) ?? 0
        photoOpacity = (try? c.decodeIfPresent(Double.self, forKey: .photoOpacity)) ?? 1
        photoFilter = (try? c.decodeIfPresent(ReelPhotoFilter.self, forKey: .photoFilter)) ?? .original
        photoFadeIn = (try? c.decodeIfPresent(Double.self, forKey: .photoFadeIn)) ?? 0.25
        photoFadeOut = (try? c.decodeIfPresent(Double.self, forKey: .photoFadeOut)) ?? 0.35
        overlayOpacity = (try? c.decodeIfPresent(Double.self, forKey: .overlayOpacity)) ?? 1
        overlayFadeIn = (try? c.decodeIfPresent(Double.self, forKey: .overlayFadeIn)) ?? 0.25
        overlayFadeOut = (try? c.decodeIfPresent(Double.self, forKey: .overlayFadeOut)) ?? 0.35
        videoClip = (try? c.decodeIfPresent(ReelVideoClip.self, forKey: .videoClip)) ?? nil
        presenter = (try? c.decodeIfPresent(ReelPresenterOverlay.self, forKey: .presenter)) ?? nil
    }
}

/// A reusable reel layout the buyer can start from and customize. Real starting points
/// (scene roles + copy scaffold + default motion), never fabricated metrics.
enum ReelTemplate: String, CaseIterable, Identifiable {
    case promo3 = "3-scene promo"
    case story5 = "5-scene story"
    case teaser2 = "2-scene teaser"
    case offer4 = "4-scene offer"
    case testimonial3 = "Testimonial"
    case launch4 = "Product launch"
    var id: String { rawValue }

    /// The visual style this template opens with (the buyer can change it in the studio).
    var defaultStyle: ReelStyleID {
        switch self {
        case .promo3: return .spotlight
        case .story5: return .editorial
        case .teaser2: return .bold
        case .offer4: return .spotlight
        case .testimonial3: return .luxe
        case .launch4: return .minimal
        }
    }

    /// Build the template's scenes from the buyer's business/topic/city.
    func scenes(business: String, topic: String, city: String) -> [ReelScene] {
        let b = business.trimmingCharacters(in: .whitespaces)
        let who = b.isEmpty ? "Your Business" : b
        let t = topic.trimmingCharacters(in: .whitespaces).isEmpty ? "Now booking" : topic.trimmingCharacters(in: .whitespaces)
        let w = city.trimmingCharacters(in: .whitespaces)
        let serving = w.isEmpty ? "Proudly serving you." : "Proudly serving \(w)."
        switch self {
        case .promo3:
            return [
                ReelScene(eyebrow: w.isEmpty ? t.uppercased() : w.uppercased(), headline: who, subtitle: t, seconds: 2.4, transition: .zoomIn, kind: .opener),
                ReelScene(eyebrow: "Why us", headline: t, subtitle: "Real results, done right.", seconds: 2.6, transition: .slideUp),
                ReelScene(eyebrow: serving, headline: "Book today", subtitle: "Tap the link to get started", seconds: 2.4, transition: .fade, kind: .cta)
            ]
        case .story5:
            return [
                ReelScene(eyebrow: w.isEmpty ? "" : w.uppercased(), headline: who, subtitle: serving, seconds: 2.2, transition: .kenBurns, kind: .opener),
                ReelScene(eyebrow: "The problem", headline: "Most get this wrong", subtitle: "What to know about \(t.lowercased()).", seconds: 2.6, transition: .slideLeft),
                ReelScene(eyebrow: "Our approach", headline: "Done properly", subtitle: "Clear pricing. Real craftsmanship.", seconds: 2.6, transition: .slideUp),
                ReelScene(eyebrow: "The result", headline: "Work you trust", subtitle: "No surprises, no runaround.", seconds: 2.4, transition: .zoomIn),
                ReelScene(eyebrow: serving, headline: "Book today", subtitle: "Tap the link to get started", seconds: 2.2, transition: .fade, kind: .cta)
            ]
        case .teaser2:
            return [
                ReelScene(eyebrow: who.uppercased(), headline: t, subtitle: "", seconds: 1.8, transition: .zoomIn, kind: .opener),
                ReelScene(eyebrow: serving, headline: "Learn more", subtitle: "Tap the link", seconds: 1.8, transition: .slideUp, kind: .cta)
            ]
        case .offer4:
            return [
                ReelScene(eyebrow: w.isEmpty ? "LIMITED OFFER" : w.uppercased(), headline: who, subtitle: t, seconds: 2.2, transition: .kenBurns, kind: .opener),
                ReelScene(eyebrow: "Limited time", headline: "Save this week", subtitle: "For a short time only.", seconds: 2.4, transition: .slideLeft),
                ReelScene(eyebrow: "Why us", headline: "Quality & speed", subtitle: "Done right, at a fair price.", seconds: 2.4, transition: .slideUp),
                ReelScene(eyebrow: serving, headline: "Claim it now", subtitle: "Tap the link to book", seconds: 2.2, transition: .fade, kind: .cta)
            ]
        case .testimonial3:
            return [
                ReelScene(eyebrow: "What clients say", headline: who, subtitle: "", seconds: 2.0, transition: .kenBurns, kind: .opener),
                ReelScene(eyebrow: "Client review", headline: "“Add a real quote here.”", subtitle: "— Your happy customer", seconds: 3.0, transition: .fade),
                ReelScene(eyebrow: serving, headline: "Work with us", subtitle: "Tap the link to start", seconds: 2.2, transition: .slideUp, kind: .cta)
            ]
        case .launch4:
            return [
                ReelScene(eyebrow: "INTRODUCING", headline: t, subtitle: who, seconds: 2.2, transition: .zoomIn, kind: .opener),
                ReelScene(eyebrow: "Built for you", headline: "Designed to last", subtitle: "Every detail considered.", seconds: 2.4, transition: .slideUp),
                ReelScene(eyebrow: "Available now", headline: w.isEmpty ? "Ready today" : "Now in \(w)", subtitle: serving, seconds: 2.4, transition: .slideLeft),
                ReelScene(eyebrow: "Get yours", headline: "Order today", subtitle: "Tap the link", seconds: 2.2, transition: .fade, kind: .cta)
            ]
        }
    }
}

/// Output aspect for the reel. Real pixel dimensions drive the render.
enum ReelFormat: String, CaseIterable, Identifiable, Codable {
    case vertical = "Vertical 9:16", square = "Square 1:1", wide = "Wide 16:9"
    var id: String { rawValue }
    /// Render size in pixels. 1080-wide class, even dimensions (H.264 requires even).
    var size: CGSize {
        switch self {
        case .vertical: return CGSize(width: 1080, height: 1920)
        case .square:   return CGSize(width: 1080, height: 1080)
        case .wide:     return CGSize(width: 1920, height: 1080)
        }
    }
    var label: String { rawValue }
    /// Where the content block sits by default (fraction of height from the BOTTOM). Vertical
    /// reels compose lower (classic reel framing); square/wide center.
    var defaultAnchorY: CGFloat {
        switch self { case .vertical: return 0.40; case .square: return 0.50; case .wide: return 0.50 }
    }
}

// MARK: - Visual style (pure, testable) — the "look" applied to every scene

/// A named visual identity for the whole reel. Distinct type, layout, and lighting — not just a
/// palette swap. The buyer picks one; the brand accent color feeds all of them.
// MARK: - Brand kit integration (MK-16)

extension ReelTemplate {
    /// Build the template's scenes straight from the buyer's LOCKED brand kit — business name and
    /// city are read from the kit, never passed as drifting per-call args.
    func scenes(kit: BrandKit, topic: String) -> [ReelScene] {
        scenes(business: kit.resolvedName, topic: topic, city: kit.city)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension ReelProject {
    /// Materialize a reel from the buyer's LOCKED brand kit: brand accent tints the render, and the
    /// name/city drive the copy — all read from ONE kit so the reel matches the site + email exactly.
    init(template: ReelTemplate = .promo3, topic: String, kit: BrandKit, name: String? = nil) {
        self.init(name: name ?? "\(kit.resolvedName) — \(topic)",
                  scenes: template.scenes(kit: kit, topic: topic),
                  paletteAccentHex: kit.accentHex,
                  styleID: template.defaultStyle)
    }
}
#endif // circuit-convert

enum ReelStyleID: String, Codable, CaseIterable, Identifiable {
    case spotlight = "Spotlight"   // bold lower-third, huge sans headline, strong accent bar
    case editorial = "Editorial"   // refined, centered, medium sans, understated
    case luxe = "Luxe"             // serif display, generous space, premium
    case minimal = "Minimal"       // thin type, lots of air, tiny accent
    case bold = "Bold"             // high-contrast, left-aligned, punchy
    var id: String { rawValue }
    var blurb: String {
        switch self {
        case .spotlight: return "Big lower-third headline with a strong accent — the default reel look."
        case .editorial: return "Centered, refined, understated. Clean and trustworthy."
        case .luxe:      return "Serif display and generous spacing. Premium and calm."
        case .minimal:   return "Thin type and lots of air. Modern and quiet."
        case .bold:      return "Left-aligned, high-contrast, punchy. Grabs attention."
        }
    }
}

/// Resolved, concrete draw parameters for a style. Pure value type so style resolution + the
/// downstream layout are unit-testable without touching AVFoundation.
struct ReelStyle: Equatable {
    var serif: Bool
    var centered: Bool              // center vs left alignment
    var headlineScale: CGFloat      // × render width
    var headlineWeightRaw: CGFloat  // NSFont.Weight rawValue (kept as a plain number for testability)
    var subtitleScale: CGFloat
    var eyebrowScale: CGFloat
    var eyebrowTracking: CGFloat    // letter-spacing as a fraction of the eyebrow font size
    var headlineTracking: CGFloat
    var glowStrength: CGFloat       // 0…1 accent glow alpha ceiling
    var vignetteStrength: CGFloat   // 0…1
    var grain: CGFloat              // 0…1 grain overlay alpha
    var showAccentBar: Bool
    var showProgress: Bool
    var uppercaseHeadline: Bool

    static func resolve(_ id: ReelStyleID) -> ReelStyle {
        switch id {
        case .spotlight:
            return ReelStyle(serif: false, centered: true, headlineScale: 0.100, headlineWeightRaw: 0.62,
                             subtitleScale: 0.036, eyebrowScale: 0.026, eyebrowTracking: 0.22, headlineTracking: -0.01,
                             glowStrength: 0.16, vignetteStrength: 0.34, grain: 0.045,
                             showAccentBar: true, showProgress: true, uppercaseHeadline: false)
        case .editorial:
            return ReelStyle(serif: false, centered: true, headlineScale: 0.078, headlineWeightRaw: 0.30,
                             subtitleScale: 0.032, eyebrowScale: 0.023, eyebrowTracking: 0.30, headlineTracking: -0.005,
                             glowStrength: 0.11, vignetteStrength: 0.30, grain: 0.04,
                             showAccentBar: true, showProgress: true, uppercaseHeadline: false)
        case .luxe:
            return ReelStyle(serif: true, centered: true, headlineScale: 0.086, headlineWeightRaw: 0.30,
                             subtitleScale: 0.033, eyebrowScale: 0.022, eyebrowTracking: 0.34, headlineTracking: 0.0,
                             glowStrength: 0.13, vignetteStrength: 0.36, grain: 0.05,
                             showAccentBar: false, showProgress: true, uppercaseHeadline: false)
        case .minimal:
            return ReelStyle(serif: false, centered: true, headlineScale: 0.070, headlineWeightRaw: 0.20,
                             subtitleScale: 0.030, eyebrowScale: 0.021, eyebrowTracking: 0.40, headlineTracking: 0.0,
                             glowStrength: 0.07, vignetteStrength: 0.22, grain: 0.03,
                             showAccentBar: false, showProgress: true, uppercaseHeadline: false)
        case .bold:
            return ReelStyle(serif: false, centered: false, headlineScale: 0.110, headlineWeightRaw: 0.80,
                             subtitleScale: 0.037, eyebrowScale: 0.026, eyebrowTracking: 0.18, headlineTracking: -0.02,
                             glowStrength: 0.18, vignetteStrength: 0.38, grain: 0.05,
                             showAccentBar: true, showProgress: true, uppercaseHeadline: true)
        }
    }
}

/// On-device voiceover settings for a reel. Uses Apple's free AVSpeechSynthesizer (own-it —
/// no paid TTS provider). Narration is optional; new reels still receive the default music bed.
struct ReelVoice: Codable, Hashable {
    var enabled: Bool = false
    var voiceIdentifier: String = ""   // empty = system default voice
    var rate: Float = 0.5              // AVSpeechUtteranceDefaultSpeechRate ≈ 0.5
    var pitch: Float = 1.0             // 0.5...2.0
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// A complete reel project: ordered scenes + style, persisted with the app data.
struct ReelProject: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var format: ReelFormat = .vertical
    var scenes: [ReelScene] = []
    var paletteAccentHex: UInt32 = 0xD9B65C   // resolved from the buyer's brand palette
    var styleID: ReelStyleID = .spotlight     // visual look
    var fps: Int = 30
    var voice = ReelVoice()
    var music = ReelMusic()
    var created = Date()
    /// Whole-reel color grade. Optional so projects saved before the feature decode unchanged.
    var grade: ReelColorGrade? = nil
    /// Burned-in subtitles (autocaption). Disabled by default, so a reel saved before this
    /// existed renders exactly as it did. See ReelCaptions.swift.
    var captions = ReelCaptionSettings()

    init(id: UUID = UUID(), name: String = "", format: ReelFormat = .vertical, scenes: [ReelScene] = [],
         paletteAccentHex: UInt32 = 0xD9B65C, styleID: ReelStyleID = .spotlight, fps: Int = 30,
         voice: ReelVoice = ReelVoice(), music: ReelMusic = ReelMusic(), created: Date = Date(),
         grade: ReelColorGrade? = nil, captions: ReelCaptionSettings = ReelCaptionSettings()) {
        self.id = id; self.name = name; self.format = format; self.scenes = scenes
        self.paletteAccentHex = paletteAccentHex; self.styleID = styleID; self.fps = fps
        self.voice = voice; self.music = music; self.created = created; self.grade = grade
        self.captions = captions
    }

    /// The narration text: each scene's explicit voiceScript, else its headline + subtitle.
    var voiceoverText: String {
        scenes.map { s in
            let script = s.voiceScript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !script.isEmpty { return script }
            let parts = [s.headline, s.subtitle].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return parts.joined(separator: ". ")
        }.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    /// Total duration in seconds (sum of scene durations), clamped to sane bounds.
    var totalSeconds: Double { max(0, scenes.reduce(0) { $0 + max(0.4, $1.seconds) }) }
    /// Total frame count for the render at the project fps.
    var totalFrames: Int { Int((totalSeconds * Double(max(1, fps))).rounded()) }
    var style: ReelStyle { ReelStyle.resolve(styleID) }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Robust decode: `styleID` and `music` were added after the first ReelProject shape shipped; default
// them so an older saved reel still loads (synthesized Codable would throw keyNotFound otherwise).
extension ReelProject {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        format = (try? c.decode(ReelFormat.self, forKey: .format)) ?? .vertical
        scenes = (try? c.decode([ReelScene].self, forKey: .scenes)) ?? []
        paletteAccentHex = (try? c.decode(UInt32.self, forKey: .paletteAccentHex)) ?? 0xD9B65C
        styleID = (try? c.decodeIfPresent(ReelStyleID.self, forKey: .styleID)) ?? .spotlight
        fps = (try? c.decode(Int.self, forKey: .fps)) ?? 30
        voice = (try? c.decodeIfPresent(ReelVoice.self, forKey: .voice)) ?? ReelVoice()
        music = (try? c.decodeIfPresent(ReelMusic.self, forKey: .music)) ?? ReelMusic()
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
        // `grade` and `captions` are optional-by-default fields added after the first shape
        // shipped. They MUST be decoded explicitly: a stored property with a default is silently
        // left at that default by a custom init(from:), which is how a saved color grade was
        // being dropped on every reload before this line existed.
        grade = try? c.decodeIfPresent(ReelColorGrade.self, forKey: .grade)
        captions = (try? c.decodeIfPresent(ReelCaptionSettings.self, forKey: .captions)) ?? ReelCaptionSettings()
    }
}
#endif // circuit-convert

// MARK: - Storyboard + layout helpers (pure)

enum ReelStoryboard {
    /// Which scene index is on screen at a given frame, plus that scene's local
    /// progress 0...1. Pure timing math — unit-tested without any rendering.
    static func sceneIndex(at frame: Int, scenes: [ReelScene], fps: Int) -> (index: Int, progress: Double)? {
        guard !scenes.isEmpty, fps > 0 else { return nil }
        let t = Double(frame) / Double(fps)
        var acc = 0.0
        for (i, s) in scenes.enumerated() {
            let dur = max(0.4, s.seconds)
            if t < acc + dur || i == scenes.count - 1 {
                let p = dur > 0 ? min(1, max(0, (t - acc) / dur)) : 1
                return (i, p)
            }
            acc += dur
        }
        return (scenes.count - 1, 1)
    }

    /// Build a default 3-scene storyboard from a business + topic — a real starting
    /// point the buyer edits, never fabricated metrics.
    static func defaultScenes(business: String, topic: String, city: String) -> [ReelScene] {
        ReelTemplate.promo3.scenes(business: business, topic: topic, city: city)
    }
}

/// Pure motion/layout math — no drawing, so it's fully unit-testable.
enum ReelMotion {
    static func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }

    /// Scene-level fade: ramps in over the first 16% and out over the last 16%.
    static func sceneAlpha(progress: Double) -> Double {
        if progress < 0.16 { return progress / 0.16 }
        if progress > 0.84 { return (1 - progress) / 0.16 }
        return 1
    }

    /// Timeline opacity for one layer. Fade lengths are real seconds and are clamped so overlapping
    /// fades never produce invalid ramps on a short clip.
    static func layerAlpha(progress: Double, seconds: Double, fadeIn: Double, fadeOut: Double,
                           opacity: Double) -> Double {
        let duration = max(0.4, seconds)
        let t = min(duration, max(0, progress * duration))
        let fi = min(max(0, fadeIn), duration / 2)
        let fo = min(max(0, fadeOut), duration / 2)
        let inAlpha = fi > 0 ? min(1, t / fi) : 1
        let outAlpha = fo > 0 ? min(1, (duration - t) / fo) : 1
        return min(1, max(0, opacity)) * min(inAlpha, outAlpha)
    }

    /// Per-element staggered entrance. Element `index` (0 = eyebrow, 1 = headline, …) starts a
    /// beat later than the one above it, then eases in over ~30% of the scene. Returns the
    /// eased 0…1 amount used to drive both a small rise and the element's opacity.
    static func entrance(progress: Double, index: Int) -> Double {
        let delay = 0.05 * Double(index)
        return easeOutCubic((progress - delay) / 0.30)
    }

    /// The intro amount that drives slide/zoom base motion (eased over the first 35%).
    static func intro(progress: Double) -> Double { easeOutCubic(progress / 0.35) }
}

// MARK: - AVFoundation renderer (real .mp4 export)

enum ReelRenderError: LocalizedError {
    case noScenes, audio(String), writerSetup(String), pixelBuffer, finish(String)
    var errorDescription: String? {
        switch self {
        case .noScenes: return "Add at least one scene before rendering."
        case .audio(let m): return "Audio isn't ready: \(m)"
        case .writerSetup(let m): return "Couldn't start the video writer: \(m)"
        case .pixelBuffer: return "Couldn't allocate a video frame buffer."
        case .finish(let m): return "The render didn't finish cleanly: \(m)"
        }
    }
}

/// Drives frame appending across repeated `requestMediaDataWhenReady` invocations.
/// AVFoundation re-invokes the block after encoder back-pressure; the frame cursor must RESUME
/// where it stopped — restarting at 0 re-appends earlier presentation times and kills the writer
/// (the intermittent `finish("The operation could not be completed")` export failure).
final class RenderPump {
    private(set) var nextFrame = 0
    private(set) var failed = false
    let totalFrames: Int
    init(totalFrames: Int) { self.totalFrames = max(1, totalFrames) }
    var isDone: Bool { failed || nextFrame >= totalFrames }
    /// One ready-callback invocation: append while the input stays ready. Returns true when the
    /// render is COMPLETE (every frame appended, or aborted on failure) and the writer must be
    /// finished; false means back-pressure paused us and AVFoundation will call again.
    func drive(isReady: () -> Bool, appendFrame: (Int) -> Bool) -> Bool {
        while !isDone {
            if !isReady() { return false }                    // pause; resume on next invocation
            if !appendFrame(nextFrame) { failed = true; return true }
            nextFrame += 1
        }
        return true
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Renders a ReelProject to an actual H.264 .mp4 at `outputURL`.
/// `logo` and per-scene background images are optional buyer assets.
/// `progress` is called on a background queue with 0...1.
final class ReelRenderer {
    struct Assets {
        var logo: CGImage?
        /// imageName -> decoded CGImage (buyer's own asset library).
        var backgrounds: [String: CGImage] = [:]
        /// The buyer's own music file (used only when project.music.source == .buyerTrack). Never bundled.
        var music: URL?
        /// scene id (uuidString) -> readable session copy of that scene's picked footage.
        /// Empty when the reel has no video clips — every existing call site is unchanged.
        var videoClips: [String: URL] = [:]
        /// scene id (uuidString) -> readable session copy of that scene's PRESENTER take (the
        /// corner picture-in-picture tile). Keyed separately from `videoClips` because a scene can
        /// carry both: its main picture AND the presenter over it. Empty ⇒ no tile is composited.
        var presenterClips: [String: URL] = [:]
        /// An already-timed subtitle track to burn in — e.g. the REAL on-device transcription
        /// SpeechCaptionEngine produced from the buyer's own footage (import a sidecar with
        /// ReelCaptionEngine.parseSRT). Empty ⇒ the project's own script track is used.
        /// Ignored entirely unless project.captions.enabled.
        var captions: [TimedCaption] = []
    }

    static func render(project: ReelProject, to outputURL: URL, assets: Assets = Assets(),
                       progress: @escaping (Double) -> Void = { _ in }) throws {
        guard !project.scenes.isEmpty else { throw ReelRenderError.noScenes }

        let size = project.format.size
        let fps = max(1, project.fps)

        // Audio is composited in a second pass: render the silent video to a temp file, then mix the
        // narration + music track into the real outputURL. Far more reliable than interleaving live.
        // Video-clip scenes can carry their own sound, so a reel with unmuted clips needs the audio
        // pass even when narration and music are both off.
        let clipAudio = ReelClipAudio.placements(project: project, videoURLs: assets.videoClips,
                                                 presenterURLs: assets.presenterClips)
        if case .blocked(let reason) = ReelAudio.readiness(project, musicURL: assets.music,
                                                           hasClipAudio: !clipAudio.isEmpty) {
            throw ReelRenderError.audio(reason)
        }
        try? FileManager.default.removeItem(at: outputURL)
        let wantAudio = ReelAudio.wants(project) || !clipAudio.isEmpty
        let videoTarget = wantAudio ? outputURL.deletingPathExtension().appendingPathExtension("silent.mp4") : outputURL
        if wantAudio { try? FileManager.default.removeItem(at: videoTarget) }

        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: videoTarget, fileType: .mp4) }
        catch { throw ReelRenderError.writerSetup(error.localizedDescription) }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(size.width * size.height * 6),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { throw ReelRenderError.writerSetup("input rejected") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ReelRenderError.writerSetup(writer.error?.localizedDescription ?? "unknown")
        }
        writer.startSession(atSourceTime: .zero)

        let totalFrames = max(1, project.totalFrames)
        let accent = project.paletteAccentHex
        let style = project.style
        let scenes = project.scenes
        // One sequential frame source per video scene. The pump advances monotonically, so each
        // source decodes in order — no per-frame seeking. Scenes without clips get no source and
        // render exactly as before.
        let videoSources = makeVideoSources(scenes: scenes, urls: assets.videoClips)
        // Second sequential source per scene that carries a presenter tile. Independent of the
        // primary clip source: one scene can pull a frame from both in the same output frame.
        let presenterSources = makePresenterSources(scenes: scenes, urls: assets.presenterClips)
        // Burned-in subtitles, resolved ONCE for the whole reel (pure — no file, no permission),
        // then looked up per frame. Empty unless the project turns captions on.
        let captionTrack = ReelCaptionEngine.track(project: project, supplied: assets.captions)
        let sem = DispatchSemaphore(value: 0)
        var caughtError: Error?
        let queue = DispatchQueue(label: "com.blacklabel.marketing.reel.render")

        // The pump lives OUTSIDE the ready-callback: AVFoundation re-invokes the block after
        // back-pressure, and the cursor must resume, never restart (restart = duplicate PTS =
        // writer failure). `finished` guards the once-only finishWriting (serial queue = safe).
        let pump = RenderPump(totalFrames: totalFrames)
        var finished = false
        input.requestMediaDataWhenReady(on: queue) {
            guard !finished else { return }
            let complete = pump.drive(isReady: { input.isReadyForMoreMediaData }) { frame in
                autoreleasepool {
                    guard let pool = adaptor.pixelBufferPool,
                          let pb = ReelRenderer.makePixelBuffer(pool: pool) else {
                        caughtError = ReelRenderError.pixelBuffer; return false
                    }
                    let sb = ReelStoryboard.sceneIndex(at: frame, scenes: scenes, fps: fps)
                    // Video scene: pull the trimmed footage frame for this moment. The source time
                    // is trimStart + elapsed scene time, clamped to the trim so a slightly longer
                    // scene holds the last frame instead of overrunning the out-point.
                    var clipFrame: CGImage?
                    if let sb = sb, let clip = scenes[sb.index].videoClip,
                       let src = videoSources[scenes[sb.index].id.uuidString] {
                        let sceneDur = max(0.4, scenes[sb.index].seconds)
                        clipFrame = src.frame(at: clip.trimStart + min(sb.progress * sceneDur, clip.trimLength),
                                              filter: scenes[sb.index].photoFilter, grade: project.grade)
                    }
                    // Presenter tile: the SAME time math as the primary clip, against the presenter
                    // take's own trim. A scene with no presenter (or unreadable footage) yields nil
                    // and the frame is composited exactly as it was before this layer existed.
                    var presenterFrame: CGImage?
                    if let sb = sb, let pres = scenes[sb.index].presenter,
                       let src = presenterSources[scenes[sb.index].id.uuidString] {
                        let sceneDur = max(0.4, scenes[sb.index].seconds)
                        presenterFrame = src.frame(at: pres.clip.trimStart + min(sb.progress * sceneDur, pres.clip.trimLength),
                                                   filter: .original, grade: project.grade)
                    }
                    ReelRenderer.draw(into: pb, size: size, accentHex: accent, style: style,
                                      scene: sb.map { scenes[$0.index] }, sceneIndex: sb?.index ?? 0,
                                      sceneCount: scenes.count, progress: sb?.progress ?? 0, assets: assets,
                                      videoFrame: clipFrame, presenterFrame: presenterFrame, grade: project.grade,
                                      captions: captionTrack, seconds: Double(frame) / Double(fps))
                    let pts = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
                    if !adaptor.append(pb, withPresentationTime: pts) {
                        caughtError = ReelRenderError.finish(writer.error?.localizedDescription ?? "append failed")
                        return false
                    }
                    progress(Double(frame) / Double(totalFrames))
                    return true
                }
            }
            if complete {
                finished = true
                input.markAsFinished()
                writer.finishWriting { sem.signal() }
            }
        }
        sem.wait()
        if let e = caughtError { throw e }
        if writer.status != .completed {
            throw ReelRenderError.finish(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }

        // Audio pass: synthesize narration + load the buyer's music, mix, and mux into the final mp4.
        // Reels WITHOUT clips keep the exact existing ReelAudio path; clips route through the
        // superset mixer that also places each clip's own sound at its scene offset.
        if wantAudio {
            let composed = clipAudio.isEmpty
                ? ReelAudio.compose(project: project, silentVideo: videoTarget, musicURL: assets.music, to: outputURL)
                : ReelClipAudio.compose(project: project, silentVideo: videoTarget, musicURL: assets.music,
                                        clips: clipAudio, to: outputURL)
            if composed {
                guard ReelAudio.hasAudioTrack(at: outputURL) else {
                    try? FileManager.default.removeItem(at: outputURL)
                    try? FileManager.default.removeItem(at: videoTarget)
                    throw ReelRenderError.audio("The finished MP4 did not contain an audio track.")
                }
                try? FileManager.default.removeItem(at: videoTarget)
            } else {
                // Fail closed: the buyer requested audio, so a silent fallback is not a successful
                // render. Keep the UI truthful and require the source/mix problem to be fixed.
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: videoTarget)
                throw ReelRenderError.audio("The requested narration, music, or clip audio could not be mixed.")
            }
        }
        progress(1)
    }

    /// Synthesize narration to a .caf audio file using Apple's on-device speech (free, own-it).
    /// Returns false if nothing usable was produced.
    ///
    /// THREADING — this is why narrated reels used to fail: `AVSpeechSynthesizer.write` delivers
    /// its PCM buffers through the CALLER'S run loop, so a caller sitting on the main thread with a
    /// blocking semaphore deadlocks its own callback. Not one buffer arrives, the wait expires,
    /// this returns false, and `ReelAudio.compose` reports "narration, music, or clip audio could
    /// not be mixed" — the render_failed every headless `--render-reel --voice` run hit, because
    /// main.swift's render path IS the main thread. The Studio button escaped it only by rendering
    /// on a background queue. So: PUMP the run loop when we're on the main thread (buffers can then
    /// be delivered) and block only when we're not.
    static func synthesizeVoiceover(text: String, voice: ReelVoice, to url: URL) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let synth = AVSpeechSynthesizer()
        let utt = AVSpeechUtterance(string: trimmed)
        if !voice.voiceIdentifier.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voice.voiceIdentifier) { utt.voice = v }
        utt.rate = voice.rate
        utt.pitchMultiplier = max(0.5, min(2.0, voice.pitch))

        var file: AVAudioFile?
        var ok = true
        let done = DispatchSemaphore(value: 0)
        var signalled = false
        func finish() { if !signalled { signalled = true; done.signal() } }

        synth.write(utt) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength == 0 { finish(); return }   // final empty buffer = completion
            if file == nil {
                do { file = try AVAudioFile(forWriting: url, settings: pcm.format.settings) }
                catch { ok = false; finish(); return }
            }
            do { try file?.write(from: pcm) } catch { ok = false; finish() }
        }
        // Generous timeout so we never hang the render if the callback never signals completion.
        let deadline = Date().addingTimeInterval(30)
        if Thread.isMainThread {
            // Never block the main thread here — it is the thread the buffers are delivered on.
            // Each turn gives the run loop a slice to deliver, then checks completion cheaply.
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
                if done.wait(timeout: .now() + 0.02) == .success { break }
            }
        } else {
            _ = done.wait(timeout: .now() + 30)
        }
        // The synthesizer is only referenced by AVFoundation's own callback machinery after
        // `write` returns; keep it alive until the buffers are in hand.
        withExtendedLifetime(synth) {}
        return ok && file != nil
    }

    /// Mux a single synthesized audio track onto the rendered (silent) video via AVMutableComposition.
    /// Kept for callers/tests; the multi-track mix path lives in ReelAudio.compose.
    static func muxAudio(videoURL: URL, audioURL: URL, to outURL: URL) -> Bool {
        ReelAudio.mux(videoURL: videoURL, tracks: [ReelAudio.Stem(url: audioURL, gain: 1.0, fade: false, loop: false)], to: outURL)
    }

    /// Render a single still poster frame (the cover image for the reel) at the
    /// project's full resolution, using the SAME frame-draw path as the .mp4 render.
    /// `atSeconds` picks which moment to capture (default: middle of scene 1, fully
    /// faded in). Returns a CGImage the UI can show or export as PNG/JPEG. No network.
    static func renderPosterFrame(project: ReelProject, atSeconds: Double? = nil,
                                  assets: Assets = Assets()) -> CGImage? {
        guard !project.scenes.isEmpty else { return nil }
        let size = project.format.size
        let fps = max(1, project.fps)
        // Default: the visual mid-point of the first scene (text fully on screen).
        let firstDur = max(0.4, project.scenes[0].seconds)
        let second = atSeconds ?? (firstDur * 0.5)
        let frame = max(0, Int((second * Double(fps)).rounded()))

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue |
                                              CGBitmapInfo.byteOrder32Big.rawValue) else { return nil }
        let sb = ReelStoryboard.sceneIndex(at: frame, scenes: project.scenes, fps: fps)
        // Poster over a video scene: pull the single trimmed footage frame for that moment, using
        // the SAME time math as the .mp4 render so the poster matches the video frame-for-frame.
        var clipFrame: CGImage?
        if let sb = sb, let clip = project.scenes[sb.index].videoClip,
           let url = assets.videoClips[project.scenes[sb.index].id.uuidString],
           let src = ReelVideoClipSource(url: url, trimStart: clip.trimStart, trimEnd: clip.trimEnd) {
            let sceneDur = max(0.4, project.scenes[sb.index].seconds)
            clipFrame = src.frame(at: clip.trimStart + min(sb.progress * sceneDur, clip.trimLength),
                                  filter: project.scenes[sb.index].photoFilter, grade: project.grade)
        }
        // Poster over a presenter tile: same source, same time math as the .mp4, so the cover frame
        // shows the corner tile exactly where the video puts it.
        var presenterFrame: CGImage?
        if let sb = sb, let pres = project.scenes[sb.index].presenter,
           let url = assets.presenterClips[project.scenes[sb.index].id.uuidString],
           let src = ReelVideoClipSource(url: url, trimStart: pres.clip.trimStart, trimEnd: pres.clip.trimEnd) {
            let sceneDur = max(0.4, project.scenes[sb.index].seconds)
            presenterFrame = src.frame(at: pres.clip.trimStart + min(sb.progress * sceneDur, pres.clip.trimLength),
                                       filter: .original, grade: project.grade)
        }
        drawFrame(into: ctx, size: size, accentHex: project.paletteAccentHex, style: project.style,
                  scene: sb.map { project.scenes[$0.index] }, sceneIndex: sb?.index ?? 0,
                  sceneCount: project.scenes.count, progress: sb?.progress ?? 0.5, assets: assets,
                  videoFrame: clipFrame, presenterFrame: presenterFrame, grade: project.grade,
                  captions: ReelCaptionEngine.track(project: project, supplied: assets.captions),
                  seconds: Double(frame) / Double(fps))
        return ctx.makeImage()
    }

    /// Render the poster frame and write it as a PNG to `url`. Returns true on success.
    @discardableResult
    static func writePosterPNG(project: ReelProject, to url: URL, atSeconds: Double? = nil,
                               assets: Assets = Assets()) -> Bool {
        guard let img = renderPosterFrame(project: project, atSeconds: atSeconds, assets: assets),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    private static func makePixelBuffer(pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    /// Build one sequential frame source per video scene that has a readable file. Scenes whose
    /// footage can't be opened simply get no source and fall back to the gradient background —
    /// honest degradation, never a crash mid-render.
    private static func makeVideoSources(scenes: [ReelScene], urls: [String: URL]) -> [String: ReelVideoClipSource] {
        var out: [String: ReelVideoClipSource] = [:]
        for s in scenes {
            let key = s.id.uuidString
            guard let clip = s.videoClip, out[key] == nil, let url = urls[key] else { continue }
            if let src = ReelVideoClipSource(url: url, trimStart: clip.trimStart, trimEnd: clip.trimEnd) {
                out[key] = src
            }
        }
        return out
    }

    /// Build one sequential frame source per scene that carries a PRESENTER tile with readable
    /// footage. Same honest degradation as the primary clip: unreadable footage simply yields no
    /// source, so the tile is not drawn rather than the render dying mid-way.
    private static func makePresenterSources(scenes: [ReelScene], urls: [String: URL]) -> [String: ReelVideoClipSource] {
        var out: [String: ReelVideoClipSource] = [:]
        for s in scenes {
            let key = s.id.uuidString
            guard let pres = s.presenter, out[key] == nil, let url = urls[key] else { continue }
            if let src = ReelVideoClipSource(url: url, trimStart: pres.clip.trimStart, trimEnd: pres.clip.trimEnd) {
                out[key] = src
            }
        }
        return out
    }

    /// Draw one frame into the pixel buffer (bridges the pixel buffer to a CGContext).
    private static func draw(into pb: CVPixelBuffer, size: CGSize, accentHex: UInt32, style: ReelStyle,
                             scene: ReelScene?, sceneIndex: Int, sceneCount: Int, progress: Double, assets: Assets,
                             videoFrame: CGImage? = nil, presenterFrame: CGImage? = nil,
                             grade: ReelColorGrade? = nil,
                             captions: [TimedCaption] = [], seconds: Double = 0) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: base, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else { return }
        drawFrame(into: ctx, size: size, accentHex: accentHex, style: style, scene: scene,
                  sceneIndex: sceneIndex, sceneCount: sceneCount, progress: progress, assets: assets,
                  videoFrame: videoFrame, presenterFrame: presenterFrame, grade: grade,
                  captions: captions, seconds: seconds)
    }

    /// Pure CGContext frame compositor — shared by the .mp4 render (per-frame) and the still
    /// poster export, so the poster looks exactly like the video. Builds the frame in layers:
    /// background → lighting → grain → content → logo → progress chrome → presenter tile.
    private static func drawFrame(into ctx: CGContext, size: CGSize, accentHex: UInt32, style: ReelStyle,
                                  scene: ReelScene?, sceneIndex: Int, sceneCount: Int,
                                  progress: Double, assets: Assets, videoFrame: CGImage? = nil,
                                  presenterFrame: CGImage? = nil,
                                  grade: ReelColorGrade? = nil,
                                  captions: [TimedCaption] = [], seconds: Double = 0) {
        let cs = CGColorSpaceCreateDeviceRGB()
        let r = CGRect(origin: .zero, size: size)
        let (ar, ag, ab) = rgb(accentHex)
        let transition = scene?.transition ?? .fade
        let intro = CGFloat(ReelMotion.intro(progress: progress))

        // ---- Layer 1: background base (dark, faintly accent-tinted — never muddy) ----
        let topTint = mix((0.055, 0.055, 0.062), (ar, ag, ab), 0.06)
        let botTint = (0.018, 0.018, 0.022)
        if let grad = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: topTint.0, green: topTint.1, blue: topTint.2, alpha: 1),
            CGColor(red: botTint.0, green: botTint.1, blue: botTint.2, alpha: 1)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: 0), options: [])
        } else {
            ctx.setFillColor(CGColor(red: botTint.0, green: botTint.1, blue: botTint.2, alpha: 1)); ctx.fill(r)
        }

        // ---- Layer 2: lighting ----
        let anchorY = size.height * (scene?.kind == .opener ? 0.5 : 0.44)  // where the light pools
        // A video-scene frame (already filtered + orientation-corrected) takes the background slot;
        // otherwise the buyer's still photo, exactly as before. When both are nil: gradient + glow.
        let stillBG: CGImage? = {
            guard videoFrame == nil, let s = scene, !s.imageName.isEmpty else { return nil }
            return assets.backgrounds[s.imageName]
        }()
        if let s = scene, let source = videoFrame ?? stillBG {
            // Buyer background image: aspect-fill with Ken-Burns/zoom, then a legibility scrim.
            let bgScale: CGFloat = {
                switch transition {
                case .kenBurns: return 1.0 + 0.10 * CGFloat(progress)   // continuous push across the scene
                case .zoomIn:   return 1.06 - 0.06 * intro              // settles from 1.06 → 1.0
                default:        return 1.03
                }
            }()
            let photoA = ReelMotion.layerAlpha(progress: progress, seconds: s.seconds,
                                                fadeIn: s.photoFadeIn, fadeOut: s.photoFadeOut,
                                                opacity: s.photoOpacity)
            let img = videoFrame != nil ? source : filteredPhoto(source, filter: s.photoFilter, cacheKey: s.imageName, grade: grade)
            ctx.saveGState()
            ctx.setAlpha(photoA)
            drawAspectFill(img, in: r, ctx: ctx,
                           scale: bgScale * CGFloat(max(0.5, min(3, s.photoScale))),
                           rotationDegrees: CGFloat(s.photoRotation),
                           offset: CGPoint(x: CGFloat(s.photoOffsetX) * size.width * 0.5,
                                           y: CGFloat(s.photoOffsetY) * size.height * 0.5))
            // Bottom-up dark scrim so lower-third text is always legible over any photo.
            if let scrim = CGGradient(colorsSpace: cs, colors: [
                CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 0.86),
                CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 0.0)] as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(scrim, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size.height * 0.72), options: [])
            }
            ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 0.18)); ctx.fill(r)  // gentle overall darken
            ctx.restoreGState()
        } else {
            // No photo: a CONTAINED accent glow that fades to CLEAR (α→0), so it reads as a pool of
            // light behind the headline and never washes the whole field into mud (the old bug).
            if let grad = CGGradient(colorsSpace: cs, colors: [
                CGColor(red: ar, green: ag, blue: ab, alpha: style.glowStrength),
                CGColor(red: ar, green: ag, blue: ab, alpha: 0)] as CFArray, locations: [0, 1]) {
                let cx = style.centered ? size.width / 2 : size.width * 0.30
                ctx.drawRadialGradient(grad, startCenter: CGPoint(x: cx, y: anchorY), startRadius: 0,
                                       endCenter: CGPoint(x: cx, y: anchorY), endRadius: size.width * 0.72, options: [])
            }
        }
        // Vignette: darken the edges to focus the eye (radial clear→dark).
        if style.vignetteStrength > 0, let vig = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0),
            CGColor(red: 0, green: 0, blue: 0, alpha: style.vignetteStrength)] as CFArray, locations: [0.55, 1]) {
            let rad = max(size.width, size.height) * 0.72
            ctx.drawRadialGradient(vig, startCenter: CGPoint(x: size.width/2, y: size.height/2), startRadius: 0,
                                   endCenter: CGPoint(x: size.width/2, y: size.height/2), endRadius: rad, options: [])
        }
        // ---- Layer 3: fine grain (premium, non-flat finish) ----
        if style.grain > 0.001 { drawGrain(ctx: ctx, size: size, alpha: style.grain) }

        // ---- Layer 7: burned-in subtitles (autocaption) ----
        // Deferred so it is the LAST thing drawn (nothing may cover a subtitle) and so it still
        // runs on the no-scene early return below. Empty track ⇒ this draws nothing at all.
        defer { drawCaption(ctx: ctx, size: size, track: captions, seconds: seconds) }

        guard let s = scene else { return }
        let sceneA = CGFloat(ReelMotion.layerAlpha(progress: progress, seconds: s.seconds,
                                                    fadeIn: s.overlayFadeIn, fadeOut: s.overlayFadeOut,
                                                    opacity: s.overlayOpacity))

        // ---- Layer 4: content block (eyebrow / headline / subtitle-or-CTA) ----
        // Motion is baked into DRAW COORDINATES (offset + font scale), NOT into the CGContext CTM.
        // Mutating the shared context transform around the NSGraphicsContext text draw intermittently
        // corrupts the H.264 writer (verified: CTM transforms → flaky finalize; coordinate motion → 0
        // failures). So every animated value below is a coordinate/size, never ctx.scaleBy/translateBy.
        let baseDX: CGFloat, baseDY: CGFloat, fgScale: CGFloat
        switch transition {
        case .slideLeft: baseDX = size.width * 0.12 * (1 - intro); baseDY = 0; fgScale = 1
        case .slideUp:   baseDX = 0; baseDY = -size.height * 0.06 * (1 - intro); fgScale = 1     // CG y-up: start low, rise
        case .zoomIn:    baseDX = 0; baseDY = 0; fgScale = 0.90 + 0.10 * intro
        case .fade, .kenBurns: baseDX = 0; baseDY = 0; fgScale = 1
        }

        let margin = size.width * 0.08
        let maxW = size.width - margin * 2
        let alignLeft = !style.centered
        let centerX = alignLeft ? margin + maxW / 2 : size.width / 2

        // Build the stacked element list (eyebrow, headline, subtitle/CTA), measuring each.
        var elems: [LaidText] = []
        var idx = 0
        let eyebrowText = s.eyebrow.trimmingCharacters(in: .whitespaces)
        if !eyebrowText.isEmpty {
            let f = displayFont(size.width * style.eyebrowScale, weight: .semibold, serif: false)
            elems.append(LaidText(text: eyebrowText.uppercased(), font: f,
                                  color: (Double(ar), Double(ag), Double(ab)), kern: style.eyebrowScale * size.width * style.eyebrowTracking,
                                  gapBelow: size.height * 0.018, index: idx, isChip: false)); idx += 1
        }
        let headText = style.uppercaseHeadline ? s.headline.uppercased() : s.headline
        if !headText.trimmingCharacters(in: .whitespaces).isEmpty {
            let startSize = size.width * style.headlineScale * fgScale
            let hf = fittedFont(text: headText, maxWidth: maxW, startSize: startSize,
                                minSize: startSize * 0.5, maxLines: maxHeadlineLines(size),
                                weight: weight(style.headlineWeightRaw), serif: style.serif)
            elems.append(LaidText(text: headText, font: hf, color: (0.98, 0.97, 0.95),
                                  kern: hf.pointSize * style.headlineTracking, gapBelow: size.height * 0.02,
                                  index: idx, isChip: false)); idx += 1
        }
        let subText = s.subtitle.trimmingCharacters(in: .whitespaces)
        if !subText.isEmpty {
            if s.kind == .cta {
                let f = displayFont(size.width * style.subtitleScale * 1.02 * fgScale, weight: .bold, serif: false)
                elems.append(LaidText(text: subText, font: f, color: (0.09, 0.07, 0.03),
                                      kern: 0.5, gapBelow: 0, index: idx, isChip: true))
            } else {
                let f = displayFont(size.width * style.subtitleScale * fgScale, weight: .regular, serif: style.serif)
                elems.append(LaidText(text: subText, font: f, color: (0.78, 0.76, 0.72),
                                      kern: 0, gapBelow: 0, index: idx, isChip: false))
            }
        }

        // Optional accent bar drawn just above the block (its own stagger = element -1).
        let laid = layoutBlock(elems, anchorY: size.height * (scene?.kind == .opener ? 0.50 : 0.42),
                               maxW: maxW, centerX: centerX, size: size)
        if style.showAccentBar, let first = laid.first {
            let e0 = CGFloat(ReelMotion.entrance(progress: progress, index: 0))
            let barW = size.width * 0.14
            let barX = alignLeft ? margin : (size.width - barW) / 2
            let barY = first.rect.maxY + size.height * 0.016
            ctx.setAlpha(sceneA * e0)
            ctx.setFillColor(CGColor(red: ar, green: ag, blue: ab, alpha: 1))
            fillRoundedRect(ctx, CGRect(x: barX + baseDX, y: barY + baseDY, width: barW, height: max(4, size.height * 0.004)), radius: 3)
            ctx.setAlpha(1)
        }

        for item in laid {
            let e = CGFloat(ReelMotion.entrance(progress: progress, index: item.elem.index))
            let riseDY = (1 - e) * size.height * 0.028
            let a = sceneA * e
            guard a > 0.01 else { continue }
            let rect = item.rect.offsetBy(dx: baseDX, dy: baseDY - riseDY)
            if item.elem.isChip {
                drawChip(item.elem.text, font: item.elem.font, ctx: ctx, rect: rect,
                         accent: (ar, ag, ab), inkColor: item.elem.color, alpha: a, alignLeft: alignLeft, centerX: centerX + baseDX)
            } else {
                drawText(item.elem.text, ctx: ctx, rect: rect, font: item.elem.font,
                         color: item.elem.color, alpha: a, kern: item.elem.kern, alignLeft: alignLeft)
            }
        }

        // ---- Layer 5: logo lockup (buyer asset), top-center with padding ----
        if let logo = assets.logo {
            let lw = size.width * 0.17
            let lh = lw * CGFloat(logo.height) / CGFloat(max(1, logo.width))
            let ly = size.height - lh - size.height * 0.075
            ctx.saveGState(); ctx.setAlpha(0.96 * Double(min(1, sceneA + 0.2)))
            ctx.draw(logo, in: CGRect(x: (size.width - lw)/2, y: ly, width: lw, height: lh))
            ctx.restoreGState()
        }

        // ---- Layer 6: Story-style progress segments pinned to the bottom safe area ----
        let showsProgressChrome = style.showProgress && sceneCount > 1
        if showsProgressChrome {
            drawProgress(ctx: ctx, size: size, count: sceneCount, current: sceneIndex,
                         currentProgress: progress, accent: (ar, ag, ab))
        }

        // ---- Layer 6.5: presenter picture-in-picture (the corner tile) ----
        // Drawn ABOVE the content and chrome (the presenter is the subject) but BELOW the burned-in
        // subtitles, which the deferred drawCaption still puts last. A bottom-corner tile is lifted
        // clear of the story-progress segments so the two never sit on top of each other.
        if let pres = s.presenter, let frame = presenterFrame {
            let inset: CGFloat = (showsProgressChrome && pres.corner.isBottom) ? size.height * 0.048 : 0
            let alpha = CGFloat(ReelMotion.layerAlpha(progress: progress, seconds: s.seconds,
                                                      fadeIn: pres.fadeIn, fadeOut: pres.fadeOut,
                                                      opacity: pres.opacity))
            drawPresenterTile(ctx: ctx, size: size, overlay: pres, image: frame,
                              accent: (ar, ag, ab), alpha: alpha, bottomInset: inset)
        }
    }

    /// Composite the presenter take into its corner as a rounded, aspect-filled tile with a soft
    /// drop shadow and a hairline accent border — the same gold-accent language the rest of the
    /// reel chrome uses. Geometry comes from ReelPresenterOverlay.tileRect so the export, the
    /// poster, and the studio preview cannot drift apart.
    ///
    /// NOTE ON THE CONTEXT: this clips a path and draws an image — it never scales or translates
    /// the shared CTM. Mutating the CTM around the text draw is what intermittently corrupted the
    /// H.264 writer (see the Layer 4 comment), so this layer deliberately avoids it too.
    static func drawPresenterTile(ctx: CGContext, size: CGSize, overlay: ReelPresenterOverlay,
                                  image: CGImage, accent: (CGFloat, CGFloat, CGFloat),
                                  alpha: CGFloat, bottomInset: CGFloat) {
        guard alpha > 0.01, image.width > 0, image.height > 0 else { return }
        let aspect = Double(image.width) / Double(max(1, image.height))
        let rect = overlay.tileRect(in: size, sourceAspect: aspect, bottomInset: bottomInset)
        guard rect.width > 2, rect.height > 2 else { return }
        let radius = overlay.cornerRadius(for: rect)

        // Drop shadow: cast by an opaque rounded plate drawn under the tile, so the shadow follows
        // the rounded silhouette instead of a hard rectangle.
        if overlay.showsShadow {
            ctx.saveGState()
            ctx.setAlpha(alpha)
            ctx.setShadow(offset: CGSize(width: 0, height: -size.height * 0.006),
                          blur: size.width * 0.018,
                          color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
            ctx.setFillColor(CGColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1))
            fillRoundedRect(ctx, rect, radius: radius)
            ctx.restoreGState()
        }

        // The tile itself: clipped to the rounded rect, aspect-FILLED so the presenter never
        // letterboxes or stretches inside their own frame.
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.beginPath()
        addRoundedRectPath(ctx, rect, radius: radius)
        ctx.clip()
        drawAspectFill(image, in: rect, ctx: ctx)
        ctx.restoreGState()

        // Hairline accent border — subtle, the same accent that draws the eyebrow and accent bar.
        if overlay.showsBorder {
            ctx.saveGState()
            ctx.setAlpha(alpha * 0.55)
            ctx.setLineWidth(max(1.5, size.width * 0.0022))
            ctx.setStrokeColor(CGColor(red: accent.0, green: accent.1, blue: accent.2, alpha: 1))
            ctx.beginPath()
            addRoundedRectPath(ctx, rect.insetBy(dx: 0.75, dy: 0.75), radius: max(0, radius - 0.75))
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - Text layout (pure-ish; uses text measurement which is deterministic)

    /// A measured, positioned text element.
    private struct LaidElem { let text: String; let font: NSFont; let color: (Double, Double, Double); let kern: CGFloat; let gapBelow: CGFloat; let index: Int; let isChip: Bool }
    private typealias LaidText = LaidElem
    private struct Positioned { let elem: LaidElem; let rect: CGRect }

    private static func layoutBlock(_ elems: [LaidElem], anchorY: CGFloat, maxW: CGFloat, centerX: CGFloat, size: CGSize) -> [Positioned] {
        // Measure each element's wrapped height.
        let measured: [(LaidElem, CGFloat)] = elems.map { e in
            let h = e.isChip ? e.font.pointSize * 2.5 : measureHeight(e.text, font: e.font, maxWidth: maxW, kern: e.kern)
            return (e, h)
        }
        let totalH = measured.reduce(0) { $0 + $1.1 } + measured.dropLast().reduce(0) { $0 + $1.0.gapBelow }
        // Place the block centered on anchorY (CG y-up: start at the top and walk down).
        var cursorTop = anchorY + totalH / 2
        var out: [Positioned] = []
        for (e, h) in measured {
            let rect = CGRect(x: centerX - maxW / 2, y: cursorTop - h, width: maxW, height: h)
            out.append(Positioned(elem: e, rect: rect))
            cursorTop -= (h + e.gapBelow)
        }
        return out
    }

    private static func maxHeadlineLines(_ size: CGSize) -> Int {
        size.height >= size.width ? 3 : 2   // vertical/square allow 3, wide allows 2
    }

    /// Shrink a display font until the text wraps within `maxLines` lines at `maxWidth`.
    static func fittedFont(text: String, maxWidth: CGFloat, startSize: CGFloat, minSize: CGFloat,
                           maxLines: Int, weight: NSFont.Weight, serif: Bool) -> NSFont {
        var s = max(minSize, startSize)
        while s > minSize {
            let f = displayFont(s, weight: weight, serif: serif)
            let lh = lineHeight(f)
            let h = measureHeight(text, font: f, maxWidth: maxWidth, kern: 0)
            if Int((h / lh).rounded()) <= maxLines { break }
            s *= 0.94
        }
        return displayFont(max(minSize, s), weight: weight, serif: serif)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        return ("Ag" as NSString).boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin], attributes: attrs, context: nil).height
    }

    private static func measureHeight(_ text: String, font: NSFont, maxWidth: CGFloat, kern: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
        if kern != 0 { attrs[.kern] = kern }
        return (text as NSString).boundingRect(with: CGSize(width: maxWidth, height: CGFloat.greatestFiniteMagnitude),
                                               options: [.usesLineFragmentOrigin], attributes: attrs, context: nil).height
    }

    private static func drawText(_ text: String, ctx: CGContext, rect: CGRect, font: NSFont,
                                 color: (Double, Double, Double), alpha: CGFloat, kern: CGFloat, alignLeft: Bool) {
        guard !text.isEmpty, alpha > 0.01 else { return }
        let para = NSMutableParagraphStyle(); para.alignment = alignLeft ? .left : .center; para.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(srgbRed: color.0, green: color.1, blue: color.2, alpha: Double(alpha)),
            .paragraphStyle: para
        ]
        if kern != 0 { attrs[.kern] = kern }
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = nsCtx
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        NSGraphicsContext.current = prev
    }

    /// Draw the CTA subtitle as a filled accent chip (reads like a tappable button).
    private static func drawChip(_ text: String, font: NSFont, ctx: CGContext, rect: CGRect,
                                 accent: (CGFloat, CGFloat, CGFloat), inkColor: (Double, Double, Double),
                                 alpha: CGFloat, alignLeft: Bool, centerX: CGFloat) {
        guard alpha > 0.01 else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let tw = (text as NSString).size(withAttributes: attrs).width
        let padX = font.pointSize * 0.95, chipH = font.pointSize * 2.3
        let chipW = tw + padX * 2
        let cx = alignLeft ? (rect.minX + chipW / 2) : centerX
        let chip = CGRect(x: cx - chipW / 2, y: rect.midY - chipH / 2, width: chipW, height: chipH)
        ctx.setAlpha(alpha)
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
            CGColor(red: accent.0, green: accent.1, blue: accent.2, alpha: 1),
            CGColor(red: accent.0 * 0.82, green: accent.1 * 0.82, blue: accent.2 * 0.82, alpha: 1)] as CFArray, locations: [0, 1]) {
            ctx.saveGState()
            addRoundedRectPath(ctx, chip, radius: chipH / 2); ctx.clip()
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: chip.maxY), end: CGPoint(x: 0, y: chip.minY), options: [])
            ctx.restoreGState()
        }
        ctx.setAlpha(1)
        // Chip label centered inside.
        let labelRect = CGRect(x: chip.minX, y: chip.midY - font.pointSize * 0.72, width: chip.width, height: font.pointSize * 1.5)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let la: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para,
            .foregroundColor: NSColor(srgbRed: inkColor.0, green: inkColor.1, blue: inkColor.2, alpha: Double(alpha)), .kern: 0.5]
        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = nsCtx
        (text as NSString).draw(with: labelRect, options: [.usesLineFragmentOrigin], attributes: la, context: nil)
        NSGraphicsContext.current = prev
    }

    /// Story-style progress: one rounded segment per scene, pinned to the bottom safe area. The
    /// active segment fills with the accent as the scene plays; finished segments are solid accent.
    private static func drawProgress(ctx: CGContext, size: CGSize, count: Int, current: Int,
                                     currentProgress: Double, accent: (CGFloat, CGFloat, CGFloat)) {
        let totalW = min(size.width * 0.62, CGFloat(count) * size.width * 0.14)
        let gap = size.width * 0.012
        let segW = (totalW - gap * CGFloat(count - 1)) / CGFloat(count)
        let h = max(3, size.height * 0.0035)
        let y = size.height * 0.045
        var x = (size.width - totalW) / 2
        for i in 0..<count {
            let track = CGRect(x: x, y: y, width: segW, height: h)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
            fillRoundedRect(ctx, track, radius: h / 2)
            let fillFrac: CGFloat = i < current ? 1 : (i == current ? CGFloat(min(1, max(0, currentProgress))) : 0)
            if fillFrac > 0.001 {
                ctx.setFillColor(CGColor(red: accent.0, green: accent.1, blue: accent.2, alpha: 1))
                fillRoundedRect(ctx, CGRect(x: x, y: y, width: segW * fillFrac, height: h), radius: h / 2)
            }
            x += segW + gap
        }
    }

    /// Burn the subtitle line that is live at `seconds` into the frame: a centered white-on-scrim
    /// pill in the bottom safe area, crossfading at each end. This is the visual language the
    /// camera polisher already uses for its captions, so a reel and a polished take match.
    /// An empty track (captions off) draws NOTHING — the frame is byte-identical to before.
    static func drawCaption(ctx: CGContext, size: CGSize, track: [TimedCaption], seconds: Double) {
        guard let caption = ReelCaptionEngine.active(track, at: seconds) else { return }
        let text = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let alpha = CGFloat(ReelCaptionEngine.alpha(for: caption, at: seconds))
        guard !text.isEmpty, alpha > 0.01 else { return }

        let font = displayFont(max(14, size.width * 0.036), weight: .semibold, serif: false)
        let maxTextWidth = size.width * 0.78
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para]
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], attributes: attrs, context: nil)
        let textWidth = min(maxTextWidth, ceil(measured.width))
        let textHeight = ceil(measured.height)
        let padX = font.pointSize * 0.72, padY = font.pointSize * 0.40
        let pill = CGRect(x: (size.width - (textWidth + padX * 2)) / 2,
                          y: size.height * 0.105,
                          width: textWidth + padX * 2, height: textHeight + padY * 2)

        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.62))
        fillRoundedRect(ctx, pill, radius: min(pill.height / 2, font.pointSize * 0.8))
        ctx.restoreGState()

        drawText(text, ctx: ctx,
                 rect: CGRect(x: pill.minX + padX, y: pill.minY + padY, width: textWidth, height: textHeight),
                 font: font, color: (0.98, 0.98, 0.97), alpha: alpha, kern: 0, alignLeft: false)
    }

    // MARK: - Draw primitives

    private static func drawAspectFill(_ img: CGImage, in rect: CGRect, ctx: CGContext, scale extra: CGFloat = 1,
                                       rotationDegrees: CGFloat = 0, offset: CGPoint = .zero) {
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let scale = max(rect.width/iw, rect.height/ih) * max(1, extra)
        let w = iw*scale, h = ih*scale
        let cx = rect.midX + offset.x, cy = rect.midY + offset.y
        if abs(rotationDegrees) > 0.01 {
            ctx.saveGState()
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: rotationDegrees * .pi / 180)
            ctx.draw(img, in: CGRect(x: -w/2, y: -h/2, width: w, height: h))
            ctx.restoreGState()
        } else {
            ctx.draw(img, in: CGRect(x: cx - w/2, y: cy - h/2, width: w, height: h))
        }
    }

    private static let photoFilterContext = CIContext(options: [.cacheIntermediates: true])
    private static let photoFilterLock = NSLock()
    private static var photoFilterCache: [String: CGImage] = [:]

    /// Render a Canva-style non-destructive look once per picked photo/filter/grade triple, then
    /// reuse it for every video frame. This keeps the native exporter fast even at 60 fps.
    private static func filteredPhoto(_ image: CGImage, filter: ReelPhotoFilter, cacheKey: String,
                                      grade: ReelColorGrade? = nil) -> CGImage {
        let activeGrade = (grade?.isNeutral == false) ? grade : nil
        guard filter != .original || activeGrade != nil else { return image }
        let key = "\(cacheKey)|\(filter.rawValue)|\(activeGrade?.cacheToken ?? "-")|\(image.width)x\(image.height)"
        photoFilterLock.lock()
        if let cached = photoFilterCache[key] { photoFilterLock.unlock(); return cached }
        photoFilterLock.unlock()

        let input = CIImage(cgImage: image)
        var output: CIImage
        switch filter {
        case .original:
            output = input
        case .vivid:
            output = input.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.28, kCIInputContrastKey: 1.10, kCIInputBrightnessKey: 0.015
            ])
        case .warm:
            output = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.06, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.01, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.92, w: 0)
            ])
        case .cool:
            output = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.93, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.08, w: 0)
            ])
        case .mono:
            output = input.applyingFilter("CIPhotoEffectMono")
        }
        if let g = activeGrade { output = g.apply(to: output) }
        guard let rendered = photoFilterContext.createCGImage(output, from: input.extent) else { return image }
        photoFilterLock.lock(); photoFilterCache[key] = rendered; photoFilterLock.unlock()
        return rendered
    }

    private static func addRoundedRectPath(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat) {
        let r = min(radius, min(rect.width, rect.height) / 2)
        ctx.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        ctx.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: r)
        ctx.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        ctx.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        ctx.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        ctx.closePath()
    }
    private static func fillRoundedRect(_ ctx: CGContext, _ rect: CGRect, radius: CGFloat) {
        ctx.beginPath(); addRoundedRectPath(ctx, rect, radius: radius); ctx.fillPath()
    }

    /// A cached, deterministic fine-grain tile drawn tiled at low alpha for a premium, non-flat
    /// finish. Same every frame (the poster matches the video) — a paper-grain texture, not shimmer.
    private static var grainTile: CGImage? = {
        let n = 96
        let cs = CGColorSpaceCreateDeviceGray()
        guard let c = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        guard let data = c.data else { return nil }
        var seed: UInt64 = 0x9E3779B97F4A7C15
        let px = data.bindMemory(to: UInt8.self, capacity: n * c.bytesPerRow)
        for i in 0..<(n * c.bytesPerRow) {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            px[i] = UInt8(truncatingIfNeeded: seed)
        }
        return c.makeImage()
    }()

    private static func drawGrain(ctx: CGContext, size: CGSize, alpha: CGFloat) {
        guard let tile = grainTile else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.setBlendMode(.softLight)
        let t = CGFloat(tile.width)
        var y: CGFloat = 0
        while y < size.height { var x: CGFloat = 0; while x < size.width { ctx.draw(tile, in: CGRect(x: x, y: y, width: t, height: t)); x += t }; y += t }
        ctx.restoreGState()
    }

    // MARK: - Fonts / color

    /// A display font honoring the style's serif choice, cross-platform (Georgia exists on both
    /// macOS and iOS; system font otherwise). Avoids the design-descriptor API that differs by OS.
    static func displayFont(_ size: CGFloat, weight: NSFont.Weight, serif: Bool) -> NSFont {
        if serif {
            let heavy = weight == .black || weight == .heavy || weight == .bold || weight == .semibold
            if let f = NSFont(name: heavy ? "Georgia-Bold" : "Georgia", size: size) { return f }
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
    private static func weight(_ raw: CGFloat) -> NSFont.Weight { NSFont.Weight(raw) }

    private static func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat((hex >> 16) & 0xFF)/255, CGFloat((hex >> 8) & 0xFF)/255, CGFloat(hex & 0xFF)/255)
    }
    private static func mix(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat), _ t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
    }
}
#endif // circuit-convert
