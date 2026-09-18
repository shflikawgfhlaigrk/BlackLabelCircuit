// Black Label Marketing — presenter picture-in-picture overlay for the reel engine.
//
// WHY: a reel often needs to cut to the PRESENTER while the main footage keeps playing — the
// person talking in a corner tile over a screen recording, a product shot, or a demo. Until now a
// scene could carry exactly one moving layer (its `videoClip`), so the presenter had to be
// stitched in outside the app, which means the app could not honestly be called the thing that
// made the reel. This adds a SECOND video layer per scene, composited as a corner tile.
//
// Three pieces live here, all pure and unit-testable (no AVFoundation, no drawing):
//   1. ReelPresenterCorner — which corner the tile sits in (bottom-left is the default).
//   2. ReelPresenterOverlay — the Codable per-scene model. It REUSES ReelVideoClip for the file
//      reference, trim, and audio settings, so the presenter take resolves, re-opens from its
//      security-scoped bookmark, and mixes its own sound exactly like a scene clip already does.
//   3. tileRect(...) — the geometry. The renderer and any preview both call this one function, so
//      what the studio shows and what the export bakes in can never drift apart.
//
// Optional on ReelScene (decodeIfPresent) so every project saved before this existed loads and
// renders byte-identically.
import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif

// MARK: - Corner

/// Where the presenter tile sits. Bottom-left is the default: it is the corner that stays clear of
/// the reel's top logo lockup and of the lower-right area most phones put their own UI over.
enum ReelPresenterCorner: String, Codable, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        }
    }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
}

// MARK: - Model

/// A secondary take (phone/camera footage of the presenter) composited over the scene's primary
/// picture as a rounded corner tile. Nothing is bundled: the file is the buyer's own, resolved the
/// same way a scene clip is.
struct ReelPresenterOverlay: Codable, Hashable {
    /// The presenter footage — file reference, trim, mute, and gain. Same model, same resolution
    /// path, same audio mixing as a scene's primary clip.
    var clip: ReelVideoClip = ReelVideoClip()
    /// Which corner the tile occupies.
    var corner: ReelPresenterCorner = .bottomLeft
    /// Tile width as a fraction of the frame width, before the height cap. Clamped to `widthRange`.
    var widthFraction: Double = 0.26
    /// Gap between the tile and the frame edges, as a fraction of the frame's SHORT edge, so the
    /// inset reads the same in vertical, square, and wide formats.
    var marginFraction: Double = 0.055
    /// Corner radius as a fraction of the tile's short edge (0 = square, 0.5 = pill).
    var cornerRadiusFraction: Double = 0.11
    /// Hairline accent border around the tile.
    var showsBorder: Bool = true
    /// Soft drop shadow that lifts the tile off the picture behind it.
    var showsShadow: Bool = true
    /// Peak opacity of the tile.
    var opacity: Double = 1.0
    /// Seconds the tile takes to fade in / out within its scene.
    var fadeIn: Double = 0.25
    var fadeOut: Double = 0.3

    /// Accepted tile-width band. The brief for this feature is "~22–28% of frame width"; the band
    /// is a little wider so an operator can push it without leaving a sane picture-in-picture.
    static let widthRange: ClosedRange<Double> = 0.16...0.36
    /// A tile is never allowed past this share of the frame height, so tall (9:16 phone) footage in
    /// a wide (16:9) reel stays a corner tile instead of becoming a column down the frame.
    static let maxHeightFraction: Double = 0.42
    /// Fallback source shape when the footage hasn't been probed yet: a phone shot upright.
    static let defaultSourceAspect: Double = 9.0 / 16.0

    init(clip: ReelVideoClip = ReelVideoClip(), corner: ReelPresenterCorner = .bottomLeft,
         widthFraction: Double = 0.26, marginFraction: Double = 0.055,
         cornerRadiusFraction: Double = 0.11, showsBorder: Bool = true, showsShadow: Bool = true,
         opacity: Double = 1.0, fadeIn: Double = 0.25, fadeOut: Double = 0.3) {
        self.clip = clip; self.corner = corner
        self.widthFraction = widthFraction; self.marginFraction = marginFraction
        self.cornerRadiusFraction = cornerRadiusFraction
        self.showsBorder = showsBorder; self.showsShadow = showsShadow
        self.opacity = opacity; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }

    /// The presenter take carries sound the reel should hear (their voice is usually THE audio).
    var isAudible: Bool { !clip.muted && clip.audioGain > 0.001 }

    /// Tile placement for a frame of `size`, honoring the corner, the clamped width, the height
    /// cap, and a bottom inset the caller reserves for chrome (the story-progress segments).
    /// Pure: the export, the poster, and any preview all agree because they all call this.
    ///
    /// `sourceAspect` is width/height of the ALREADY orientation-corrected presenter frame.
    /// Coordinates are CoreGraphics (y-up, origin bottom-left) — the space `drawFrame` composites in.
    func tileRect(in size: CGSize, sourceAspect: Double, bottomInset: CGFloat = 0) -> CGRect {
        Self.tileRect(in: size, corner: corner, widthFraction: widthFraction,
                      marginFraction: marginFraction, sourceAspect: sourceAspect,
                      bottomInset: bottomInset)
    }

    static func tileRect(in size: CGSize, corner: ReelPresenterCorner, widthFraction: Double,
                         marginFraction: Double, sourceAspect: Double,
                         bottomInset: CGFloat = 0) -> CGRect {
        guard size.width > 1, size.height > 1 else { return .zero }
        let shortEdge = min(size.width, size.height)
        let margin = CGFloat(min(0.2, max(0, marginFraction))) * shortEdge
        let aspect = CGFloat(sourceAspect.isFinite && sourceAspect > 0.01 ? sourceAspect : defaultSourceAspect)

        let clampedWidth = min(widthRange.upperBound, max(widthRange.lowerBound, widthFraction))
        var w = CGFloat(clampedWidth) * size.width
        var h = w / aspect
        // Cap the height first (tall footage in a wide reel), then the width (a very wide take in a
        // narrow reel). Both preserve the source aspect — the tile never stretches the presenter.
        let maxH = size.height * CGFloat(maxHeightFraction)
        if h > maxH { h = maxH; w = h * aspect }
        let maxW = max(1, size.width - margin * 2)
        if w > maxW { w = maxW; h = w / aspect }

        let inset = max(0, bottomInset)
        let x = corner.isLeft ? margin : size.width - margin - w
        let y = corner.isBottom ? margin + inset : size.height - margin - h
        return CGRect(x: x.rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
    }

    /// Corner radius for a tile of `rect`, clamped so it can never exceed a pill.
    func cornerRadius(for rect: CGRect) -> CGFloat {
        let f = CGFloat(min(0.5, max(0, cornerRadiusFraction)))
        return min(rect.width, rect.height) * f
    }
}

// Robust decode (the pattern every model in this engine uses): a field added later defaults when
// absent, so a project saved by an older build still loads instead of throwing keyNotFound.
extension ReelPresenterOverlay {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        clip = (try? c.decode(ReelVideoClip.self, forKey: .clip)) ?? ReelVideoClip()
        corner = (try? c.decodeIfPresent(ReelPresenterCorner.self, forKey: .corner)) ?? .bottomLeft
        widthFraction = (try? c.decodeIfPresent(Double.self, forKey: .widthFraction)) ?? 0.26
        marginFraction = (try? c.decodeIfPresent(Double.self, forKey: .marginFraction)) ?? 0.055
        cornerRadiusFraction = (try? c.decodeIfPresent(Double.self, forKey: .cornerRadiusFraction)) ?? 0.11
        showsBorder = (try? c.decodeIfPresent(Bool.self, forKey: .showsBorder)) ?? true
        showsShadow = (try? c.decodeIfPresent(Bool.self, forKey: .showsShadow)) ?? true
        opacity = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? 1.0
        fadeIn = (try? c.decodeIfPresent(Double.self, forKey: .fadeIn)) ?? 0.25
        fadeOut = (try? c.decodeIfPresent(Double.self, forKey: .fadeOut)) ?? 0.3
    }
}
