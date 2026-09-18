// Black Label Marketing — video-clip scenes for the reel engine.
// A scene can now carry the buyer's OWN footage (trimmed in/out) instead of a still photo.
// Three real pieces live here, all local, no paid services:
//   1. ReelVideoClip — the Codable per-scene model (bookmark + trim + audio settings).
//      Optional on ReelScene (decodeIfPresent) so every old saved project loads unchanged.
//   2. ReelVideoClipSource — a sequential AVAssetReader frame tap the renderer pulls CGImages
//      from. The render pump advances monotonically, so sequential decode is exact and fast;
//      the source holds the last decoded frame for fps up-sampling and end-of-clip holds.
//   3. ReelClipAudio — the audio pass for reels WITH clips: places each clip's own sound at
//      its timeline offset (trimmed, gain-controlled, honoring mute) and mixes it with the
//      existing narration/music stems. ReelAudio.swift stays untouched — reels without clips
//      keep using ReelAudio.compose byte-for-byte.
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

// MARK: - Model (pure, Codable — persists with the project)

/// The buyer's own footage attached to one scene. The session-readable file is re-resolved from
/// `path` (last temp copy) or `bookmark` (the original picked file); nothing is ever bundled.
struct ReelVideoClip: Codable, Hashable {
    /// Display name of the picked movie (shown in the studio + layer tracks).
    var fileName: String = ""
    /// Last-known readable path (the session temp copy). Goes stale across launches; the
    /// bookmark below is the durable reference.
    var path: String = ""
    /// Security-scoped bookmark to the ORIGINAL picked file, so a saved project can re-open
    /// its footage on a later launch without re-picking.
    var bookmark: Data? = nil
    /// Probed duration of the source movie in seconds (drives the trim control bounds).
    var sourceSeconds: Double = 0
    /// Trim in-point (seconds into the source).
    var trimStart: Double = 0
    /// Trim out-point (seconds into the source).
    var trimEnd: Double = 0
    /// Drop the clip's own audio entirely.
    var muted: Bool = false
    /// Level for the clip's own audio when not muted (1.0 = as recorded).
    var audioGain: Double = 1.0

    init(fileName: String = "", path: String = "", bookmark: Data? = nil, sourceSeconds: Double = 0,
         trimStart: Double = 0, trimEnd: Double = 0, muted: Bool = false, audioGain: Double = 1.0) {
        self.fileName = fileName; self.path = path; self.bookmark = bookmark
        self.sourceSeconds = sourceSeconds; self.trimStart = trimStart; self.trimEnd = trimEnd
        self.muted = muted; self.audioGain = audioGain
    }

    /// The trimmed play length — this IS the scene duration for a video scene.
    var trimLength: Double { max(0.4, trimEnd - trimStart) }

    /// Re-resolve a readable file for this session: the last temp copy if it still exists, else
    /// the security-scoped bookmark (copied to a fresh temp file while the scope is open, so the
    /// background render never needs the scope itself). Returns nil honestly when neither works.
    func resolveReadableCopy() -> URL? {
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard let bm = bookmark else { return nil }
        var stale = false
        #if os(macOS)
        let opts: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
        let opts: URL.BookmarkResolutionOptions = []
        #endif
        guard let orig = try? URL(resolvingBookmarkData: bm, options: opts, relativeTo: nil,
                                  bookmarkDataIsStale: &stale) else { return nil }
        let started = orig.startAccessingSecurityScopedResource()
        defer { if started { orig.stopAccessingSecurityScopedResource() } }
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("blm-clip-\(UUID().uuidString)-\(orig.lastPathComponent)")
        guard (try? FileManager.default.copyItem(at: orig, to: dst)) != nil else { return nil }
        return dst
    }
}

// Robust decode: fields added later default when absent (same pattern as ReelScene/ReelMusic),
// so a clip saved by an older build still loads instead of throwing keyNotFound.
extension ReelVideoClip {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = (try? c.decode(String.self, forKey: .fileName)) ?? ""
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        bookmark = (try? c.decodeIfPresent(Data.self, forKey: .bookmark)) ?? nil
        sourceSeconds = (try? c.decode(Double.self, forKey: .sourceSeconds)) ?? 0
        trimStart = (try? c.decode(Double.self, forKey: .trimStart)) ?? 0
        trimEnd = (try? c.decode(Double.self, forKey: .trimEnd)) ?? 0
        muted = (try? c.decode(Bool.self, forKey: .muted)) ?? false
        audioGain = (try? c.decode(Double.self, forKey: .audioGain)) ?? 1.0
    }
}

// MARK: - Async→sync AV bridges (same pattern used across the render flow)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum ReelVideoAV {
    static func firstTrack(_ asset: AVURLAsset, _ type: AVMediaType) -> AVAssetTrack? {
        var result: AVAssetTrack?
        let s = DispatchSemaphore(value: 0)
        Task { result = try? await asset.loadTracks(withMediaType: type).first; s.signal() }
        _ = s.wait(timeout: .now() + 15)
        return result
    }
    static func duration(_ asset: AVURLAsset) -> CMTime {
        var d = CMTime.zero
        let s = DispatchSemaphore(value: 0)
        Task { d = (try? await asset.load(.duration)) ?? .zero; s.signal() }
        _ = s.wait(timeout: .now() + 15)
        return d
    }
    static func preferredTransform(_ track: AVAssetTrack) -> CGAffineTransform {
        var t = CGAffineTransform.identity
        let s = DispatchSemaphore(value: 0)
        Task { t = (try? await track.load(.preferredTransform)) ?? .identity; s.signal() }
        _ = s.wait(timeout: .now() + 15)
        return t
    }
    /// Duration of the movie's VIDEO content in seconds (0 when there is no video track).
    static func videoSeconds(of url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        guard firstTrack(asset, .video) != nil else { return 0 }
        let d = duration(asset)
        return d.isNumeric ? d.seconds : 0
    }
}
#endif // circuit-convert

// MARK: - Frame source (sequential AVAssetReader tap for the render pump)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Pulls decoded frames from the buyer's footage in presentation order. The render pump asks for
/// strictly increasing times, so one sequential reader per scene is exact — no per-frame seeks.
/// Holds the last decoded frame so a 60 fps render over 30 fps footage (and the end-of-clip hold
/// when the scene runs slightly longer than the trim) both stay correct.
final class ReelVideoClipSource {
    private let asset: AVURLAsset
    private let track: AVAssetTrack
    private let transform: CGAffineTransform
    private let trimStart: Double
    private let trimEnd: Double
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var pending: CVPixelBuffer?
    private var lastPTS: Double = -.greatestFiniteMagnitude
    private var lastImage: CGImage?
    private var exhausted = false
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    init?(url: URL, trimStart: Double, trimEnd: Double) {
        asset = AVURLAsset(url: url)
        guard let t = ReelVideoAV.firstTrack(asset, .video) else { return nil }
        track = t
        transform = ReelVideoAV.preferredTransform(t)
        let assetDur = ReelVideoAV.duration(asset)
        let dur = assetDur.isNumeric ? assetDur.seconds : .greatestFiniteMagnitude
        self.trimStart = max(0, trimStart)
        self.trimEnd = min(dur, max(self.trimStart + 0.05, trimEnd))
        guard startReader() else { return nil }
    }

    private func startReader() -> Bool {
        guard let r = try? AVAssetReader(asset: asset) else { return false }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return false }
        r.add(out)
        r.timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 600),
                                  end: CMTime(seconds: trimEnd, preferredTimescale: 600))
        guard r.startReading() else { return false }
        reader = r; output = out
        lastPTS = -.greatestFiniteMagnitude
        exhausted = false
        return true
    }

    /// The decoded frame at (or just after) `seconds` into the SOURCE movie's timeline, with the
    /// scene's non-destructive look applied. Monotonic requests decode sequentially; a backward
    /// request (poster re-render) restarts the reader cleanly.
    func frame(at seconds: Double, filter: ReelPhotoFilter, grade: ReelColorGrade? = nil) -> CGImage? {
        if seconds + 0.05 < lastPTS {
            reader?.cancelReading()
            pending = nil
            guard startReader() else { return lastImage }
        }
        while !exhausted, lastPTS < seconds {
            guard let out = output, let sb = out.copyNextSampleBuffer() else {
                exhausted = true
                break
            }
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                pending = pb
                lastPTS = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            }
        }
        if let pb = pending {
            if let img = convert(pb, filter: filter, grade: grade) { lastImage = img }   // keep the last good frame on a failed convert
            pending = nil
        }
        return lastImage
    }

    private func convert(_ pb: CVPixelBuffer, filter: ReelPhotoFilter, grade: ReelColorGrade? = nil) -> CGImage? {
        var ci = CIImage(cvPixelBuffer: pb)
        // Honor the recording orientation (iPhone footage carries a 90°/180° preferredTransform).
        if !transform.isIdentity {
            ci = ci.transformed(by: transform)
            ci = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.origin.x,
                                                      y: -ci.extent.origin.y))
        }
        ci = Self.applyLook(ci, filter: filter)
        if let g = grade, !g.isNeutral { ci = g.apply(to: ci) }
        return Self.ciContext.createCGImage(ci, from: ci.extent)
    }

    /// The same non-destructive looks the photo path bakes in (same parameter values as
    /// ReelRenderer.filteredPhoto), applied per frame — video frames are never cached.
    static func applyLook(_ input: CIImage, filter: ReelPhotoFilter) -> CIImage {
        switch filter {
        case .original:
            return input
        case .vivid:
            return input.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.28, kCIInputContrastKey: 1.10, kCIInputBrightnessKey: 0.015
            ])
        case .warm:
            return input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.06, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.01, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.92, w: 0)
            ])
        case .cool:
            return input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.93, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1.0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.08, w: 0)
            ])
        case .mono:
            return input.applyingFilter("CIPhotoEffectMono")
        }
    }
}
#endif // circuit-convert

// MARK: - Clip audio (timeline-placed, trimmed, gain-controlled — mixed with the bed)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The audio pass for reels that contain video clips. ReelAudio.swift is untouched: reels WITHOUT
/// clips still run ReelAudio.compose exactly as before; this superset only runs when clips exist.
enum ReelClipAudio {
    /// One clip's sound, resolved onto the reel timeline.
    struct Placement {
        var url: URL          // readable session copy of the clip
        var start: Double     // trim in-point in the SOURCE (seconds)
        var duration: Double  // seconds of source audio to use
        var at: Double        // where the scene starts on the reel timeline (seconds)
        var gain: Double      // 0…, per the clip's audio setting
    }

    /// Resolve every unmuted, audible clip onto the timeline using the SAME cumulative-duration
    /// math as ReelStoryboard.sceneIndex, so sound and picture stay locked.
    ///
    /// `presenterURLs` carries the corner picture-in-picture takes. The presenter's voice is
    /// usually THE audio of the reel, so a presenter tile contributes its own placement on top of
    /// (not instead of) the scene's primary clip audio. Defaulted empty, so every call site that
    /// predates the presenter layer behaves exactly as before.
    static func placements(project: ReelProject, videoURLs: [String: URL],
                           presenterURLs: [String: URL] = [:]) -> [Placement] {
        var out: [Placement] = []
        var acc = 0.0
        for s in project.scenes {
            let sceneDur = max(0.4, s.seconds)
            let key = s.id.uuidString
            if let clip = s.videoClip, !clip.muted, clip.audioGain > 0.001,
               let url = videoURLs[key] {
                let usable = min(clip.trimLength, sceneDur)
                if usable > 0.05 {
                    out.append(Placement(url: url, start: clip.trimStart, duration: usable,
                                         at: acc, gain: clip.audioGain))
                }
            }
            if let pres = s.presenter, pres.isAudible, let url = presenterURLs[key] {
                let usable = min(pres.clip.trimLength, sceneDur)
                if usable > 0.05 {
                    out.append(Placement(url: url, start: pres.clip.trimStart, duration: usable,
                                         at: acc, gain: pres.clip.audioGain))
                }
            }
            acc += sceneDur
        }
        return out
    }

    /// Mirror of ReelAudio.compose plus the clip placements: synthesize narration, resolve the
    /// music bed (buyer track or generated), then mux everything with per-track gain.
    static func compose(project: ReelProject, silentVideo: URL, musicURL: URL?,
                        clips: [Placement], to out: URL) -> Bool {
        var stems: [ReelAudio.Stem] = []
        if project.voice.enabled {
            guard !project.voiceoverText.isEmpty else { return false }
            let vo = FileManager.default.temporaryDirectory.appendingPathComponent("blm-vo-\(UUID().uuidString).caf")
            guard ReelRenderer.synthesizeVoiceover(text: project.voiceoverText, voice: project.voice, to: vo),
                  ReelAudio.hasAudioTrack(at: vo) else { return false }
            stems.append(ReelAudio.Stem(url: vo, gain: 1.0, fade: false, loop: false))
        }
        if project.music.enabled {
            var resolved: URL?
            switch project.music.source {
            case .buyerTrack:
                resolved = musicURL
            case .builtIn:
                let bed = FileManager.default.temporaryDirectory.appendingPathComponent("blm-bed-\(UUID().uuidString).caf")
                if ReelAudio.generateBed(mood: project.music.mood, seconds: project.totalSeconds + 0.5, to: bed) { resolved = bed }
            }
            guard let m = resolved, ReelAudio.hasAudioTrack(at: m) else { return false }
            stems.append(ReelAudio.Stem(url: m, gain: project.music.gain, fade: true, loop: true,
                                        fadeIn: project.music.fadeIn, fadeOut: project.music.fadeOut))
        }
        guard !stems.isEmpty || !clips.isEmpty else { return false }
        return mux(videoURL: silentVideo, stems: stems, clips: clips, to: out)
    }

    /// Superset of ReelAudio.mux: full-length stems (narration/music with loop + fade ramps) PLUS
    /// clip audio inserted at each scene's timeline offset, trimmed to its in/out points.
    static func mux(videoURL: URL, stems: [ReelAudio.Stem], clips: [Placement], to outURL: URL) -> Bool {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: videoURL)
        guard let srcV = ReelVideoAV.firstTrack(vAsset, .video),
              let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        let vDur = ReelVideoAV.duration(vAsset)
        guard vDur > .zero else { return false }
        do { try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: srcV, at: .zero) }
        catch { return false }

        var mixParams: [AVMutableAudioMixInputParameters] = []

        // Clip audio — placed at its scene's offset; clips with no audio track are skipped honestly.
        for clip in clips {
            let aAsset = AVURLAsset(url: clip.url)
            guard let srcA = ReelVideoAV.firstTrack(aAsset, .audio),
                  let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let aDur = ReelVideoAV.duration(aAsset)
            let start = CMTime(seconds: max(0, clip.start), preferredTimescale: 600)
            let at = CMTime(seconds: max(0, clip.at), preferredTimescale: 600)
            guard start < aDur, at < vDur else { continue }
            var use = CMTime(seconds: clip.duration, preferredTimescale: 600)
            if start + use > aDur { use = aDur - start }
            if at + use > vDur { use = vDur - at }
            guard use > .zero else { continue }
            try? aTrack.insertTimeRange(CMTimeRange(start: start, duration: use), of: srcA, at: at)
            let p = AVMutableAudioMixInputParameters(track: aTrack)
            p.setVolume(Float(min(2, max(0, clip.gain))), at: .zero)
            mixParams.append(p)
        }

        // Full-length stems — identical behavior to ReelAudio.mux (loop to fill, fade ramps, gain).
        for stem in stems {
            let aAsset = AVURLAsset(url: stem.url)
            guard let srcA = ReelVideoAV.firstTrack(aAsset, .audio),
                  let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
            let aDur = ReelVideoAV.duration(aAsset)
            guard aDur > .zero else { return false }
            if stem.loop && aDur < vDur {
                var at = CMTime.zero
                while at < vDur {
                    let remain = vDur - at
                    let use = min(aDur, remain)
                    do { try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: use), of: srcA, at: at) }
                    catch { return false }
                    at = at + use
                }
            } else {
                let use = min(aDur, vDur)
                do { try aTrack.insertTimeRange(CMTimeRange(start: .zero, duration: use), of: srcA, at: .zero) }
                catch { return false }
            }
            let p = AVMutableAudioMixInputParameters(track: aTrack)
            if stem.fade {
                let fi = CMTime(seconds: max(0.05, stem.fadeIn), preferredTimescale: 600)
                let fo = CMTime(seconds: max(0.05, stem.fadeOut), preferredTimescale: 600)
                p.setVolumeRamp(fromStartVolume: 0, toEndVolume: Float(stem.gain), timeRange: CMTimeRange(start: .zero, duration: fi))
                p.setVolume(Float(stem.gain), at: fi)
                let foStart = vDur - fo
                if foStart > fi { p.setVolumeRamp(fromStartVolume: Float(stem.gain), toEndVolume: 0, timeRange: CMTimeRange(start: foStart, duration: fo)) }
            } else {
                p.setVolume(Float(stem.gain), at: .zero)
            }
            mixParams.append(p)
        }

        guard !mixParams.isEmpty else { return false }
        try? FileManager.default.removeItem(at: outURL)
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { return false }
        export.outputURL = outURL
        export.outputFileType = .mp4
        if !mixParams.isEmpty {
            let mix = AVMutableAudioMix(); mix.inputParameters = mixParams; export.audioMix = mix
        }
        var ok = false
        let s = DispatchSemaphore(value: 0)
        export.exportAsynchronously { ok = export.status == .completed; s.signal() }
        _ = s.wait(timeout: .now() + 90)
        return ok && ReelAudio.hasAudioTrack(at: outURL)
    }
}
#endif // circuit-convert
