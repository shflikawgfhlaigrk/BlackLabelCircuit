// Black Label Marketing — Reel audio engine.
// Two honest, own-it sources of sound for a reel, mixed under the on-device narration:
//   1. The buyer's OWN music file (their asset) — muxed, level-controlled, faded.
//   2. A tasteful on-device PROCEDURAL bed (sine-pad chords, own-it, no paid music, no
//      sample packs) for buyers who don't have a track. Generated as real PCM — not a stub.
// Plus beat math so scene cuts can be snapped to a tempo grid ("sync cuts to beat").
//
// The mix is composited in a second pass (AVMutableComposition + AVAudioMix) after the silent
// video renders — the reliable path. Everything is local; nothing is uploaded.
import Foundation
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif

/// Where a reel's music comes from. Buyer's own file, or the on-device generated bed.
enum MusicSource: String, Codable, CaseIterable, Identifiable {
    case buyerTrack = "My track"
    case builtIn = "Built-in bed"
    var id: String { rawValue }
}

/// The mood of the built-in procedural bed. Each is a real chord voicing + tempo — synthesized
/// on-device, own-it. Kept intentionally subtle so it underlays narration without fighting it.
enum MusicMood: String, Codable, CaseIterable, Identifiable {
    case ambient = "Ambient", uplift = "Uplift", cinematic = "Cinematic", calm = "Calm"
    var id: String { rawValue }
    /// Root frequency (Hz) + chord intervals (semitones) + tempo (BPM) + brightness.
    var voicing: (root: Double, intervals: [Double], bpm: Double, bright: Double) {
        switch self {
        case .ambient:   return (146.83, [0, 7, 12, 16], 0, 0.5)     // D3 sus, no pulse — a soft pad
        case .uplift:    return (174.61, [0, 4, 7, 11], 112, 0.8)    // F major7, gentle 112 BPM pulse
        case .cinematic: return (110.00, [0, 7, 12, 15], 84, 0.6)    // A2 wide minor, slow 84 BPM swell
        case .calm:      return (130.81, [0, 5, 7, 12], 0, 0.35)     // C3 open, no pulse — very quiet
        }
    }
}

/// A reel's music settings (persisted on the project). New reels start with an audible, locally
/// generated bed so the normal render path never surprises the buyer with a silent export. Silence
/// remains available, but the studio requires it to be selected explicitly before rendering.
/// The buyer's own track URL is supplied at render time via ReelRenderer.Assets (never bundled).
struct ReelMusic: Codable, Hashable {
    var enabled: Bool = true
    var source: MusicSource = .builtIn
    var mood: MusicMood = .uplift
    var gain: Double = 0.58        // clearly audible, while leaving headroom for narration (0…1)
    var fadeIn: Double = 0.7       // seconds
    var fadeOut: Double = 1.2      // seconds

    init(enabled: Bool = true, source: MusicSource = .builtIn, mood: MusicMood = .uplift,
         gain: Double = 0.58, fadeIn: Double = 0.7, fadeOut: Double = 1.2) {
        self.enabled = enabled; self.source = source; self.mood = mood
        self.gain = gain; self.fadeIn = fadeIn; self.fadeOut = fadeOut
    }
}
extension ReelMusic {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        source = (try? c.decodeIfPresent(MusicSource.self, forKey: .source)) ?? .builtIn
        mood = (try? c.decodeIfPresent(MusicMood.self, forKey: .mood)) ?? .uplift
        gain = (try? c.decode(Double.self, forKey: .gain)) ?? 0.58
        fadeIn = (try? c.decode(Double.self, forKey: .fadeIn)) ?? 0.7
        fadeOut = (try? c.decode(Double.self, forKey: .fadeOut)) ?? 1.2
    }
}

/// The studio and the renderer share one audio contract. A requested source that is not available
/// is blocked; a silent export is a separate, explicit state rather than an accidental fallback.
enum ReelAudioReadiness: Equatable {
    case ready(String)
    case silent
    case blocked(String)
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum ReelAudio {
    /// One audio source to mix into the video.
    struct Stem {
        var url: URL
        var gain: Double
        var fade: Bool          // apply fade-in/out ramps
        var loop: Bool          // repeat to fill the video length
        var fadeIn: Double = 0.7
        var fadeOut: Double = 1.2
    }

    /// Does this project need an audio pass at all?
    static func wants(_ p: ReelProject) -> Bool {
        (p.voice.enabled && !p.voiceoverText.isEmpty) || p.music.enabled
    }

    /// Validate requested audio before the expensive frame render begins. `hasClipAudio` means the
    /// timeline contains at least one readable, unmuted clip selected as an audio source; the final
    /// MP4 is still verified after muxing because a source movie can itself contain no audio track.
    static func readiness(_ p: ReelProject, musicURL: URL?, hasClipAudio: Bool) -> ReelAudioReadiness {
        var sources: [String] = []
        if p.voice.enabled {
            guard !p.voiceoverText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .blocked("Narration is on, but the reel has no spoken text.")
            }
            sources.append("on-device narration")
        }
        if p.music.enabled {
            switch p.music.source {
            case .builtIn:
                sources.append("built-in \(p.music.mood.rawValue.lowercased()) bed")
            case .buyerTrack:
                guard let musicURL, FileManager.default.isReadableFile(atPath: musicURL.path) else {
                    return .blocked("Music is set to My track, but no readable audio file is attached.")
                }
                sources.append("your music track")
            }
        }
        if hasClipAudio { sources.append("clip audio") }
        return sources.isEmpty ? .silent : .ready(sources.joined(separator: " + "))
    }

    /// Postcondition used by every audio render path: an export promised as audible must contain a
    /// real AVFoundation audio stream. This prevents a failed mix from being reported as success.
    static func hasAudioTrack(at url: URL) -> Bool {
        firstTrack(AVURLAsset(url: url), .audio) != nil
    }

    // MARK: - Beat math (pure, testable)

    /// Snap scene durations so each cut lands on a beat of `bpm` (min one beat per scene). Pure —
    /// no audio needed — so "sync cuts to beat" is unit-testable and deterministic.
    static func beatAlignedDurations(_ seconds: [Double], bpm: Double) -> [Double] {
        guard bpm > 0 else { return seconds }
        let beat = 60.0 / bpm
        return seconds.map { s in max(1, (s / beat).rounded()) * beat }
    }

    // MARK: - Compose (narration + music) → final mp4

    static func compose(project: ReelProject, silentVideo: URL, musicURL: URL?, to out: URL) -> Bool {
        var stems: [Stem] = []
        // Narration (Apple on-device TTS) at full level.
        if project.voice.enabled {
            guard !project.voiceoverText.isEmpty else { return false }
            let vo = FileManager.default.temporaryDirectory.appendingPathComponent("blm-vo-\(UUID().uuidString).caf")
            guard ReelRenderer.synthesizeVoiceover(text: project.voiceoverText, voice: project.voice, to: vo),
                  hasAudioTrack(at: vo) else { return false }
            stems.append(Stem(url: vo, gain: 1.0, fade: false, loop: false))
        }
        // Music: the buyer's own track, or the on-device generated bed.
        if project.music.enabled {
            var resolved: URL?
            switch project.music.source {
            case .buyerTrack:
                resolved = musicURL
            case .builtIn:
                let bed = FileManager.default.temporaryDirectory.appendingPathComponent("blm-bed-\(UUID().uuidString).caf")
                if generateBed(mood: project.music.mood, seconds: project.totalSeconds + 0.5, to: bed) { resolved = bed }
            }
            guard let m = resolved, hasAudioTrack(at: m) else { return false }
            stems.append(Stem(url: m, gain: project.music.gain, fade: true, loop: true,
                              fadeIn: project.music.fadeIn, fadeOut: project.music.fadeOut))
        }
        guard !stems.isEmpty else { return false }
        return mux(videoURL: silentVideo, tracks: stems, to: out)
    }

    // MARK: - Mux (video + N audio stems with per-stem gain/fade/loop)

    static func mux(videoURL: URL, tracks stems: [Stem], to outURL: URL) -> Bool {
        let comp = AVMutableComposition()
        let vAsset = AVURLAsset(url: videoURL)
        guard let srcV = firstTrack(vAsset, .video),
              let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
        let vDur = duration(vAsset)
        guard vDur > .zero else { return false }
        do { try vTrack.insertTimeRange(CMTimeRange(start: .zero, duration: vDur), of: srcV, at: .zero) }
        catch { return false }

        var mixParams: [AVMutableAudioMixInputParameters] = []
        for stem in stems {
            let aAsset = AVURLAsset(url: stem.url)
            guard let srcA = firstTrack(aAsset, .audio),
                  let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return false }
            let aDur = duration(aAsset)
            guard aDur > .zero else { return false }
            if stem.loop && aDur < vDur {
                // Fill the whole video length by repeating the (shorter) music track.
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

        guard mixParams.count == stems.count, !mixParams.isEmpty else { return false }
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
        return ok && hasAudioTrack(at: outURL)
    }

    // MARK: - Procedural bed generation (own-it, on-device PCM synthesis)

    /// Synthesize a subtle chord-pad bed to a .caf file. Real PCM (sine partials + slow envelope +
    /// optional beat pulse), generated locally — no samples, no network, no paid music.
    @discardableResult
    static func generateBed(mood: MusicMood, seconds: Double, to url: URL) -> Bool {
        let sr = 44100.0
        let n = max(1, Int(seconds * sr))
        let (root, intervals, bpm, bright) = mood.voicing
        let freqs = intervals.map { root * pow(2.0, $0 / 12.0) }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)),
              let ch = buffer.floatChannelData?[0] else { return false }
        buffer.frameLength = AVAudioFrameCount(n)

        let twoPi = 2.0 * Double.pi
        let pulseHz = bpm > 0 ? bpm / 60.0 : 0
        // Partial gains: fundamental + a soft second/third for warmth; brighter moods carry more upper.
        let partialGains: [Double] = [1.0, 0.5 * bright, 0.22 * bright]
        var rph = [Double](repeating: 0, count: freqs.count)

        for i in 0..<n {
            let t = Double(i) / sr
            // Global fade so the bed never clicks in/out (also fades under the render's own audio-mix).
            let fadeEdge = 0.6
            let env = min(1, t / fadeEdge) * min(1, max(0, (seconds - t) / fadeEdge))
            // Slow tremolo swell for life.
            let swell = 0.82 + 0.18 * sin(twoPi * 0.08 * t)
            // Optional beat pulse: a gentle amplitude bump on each beat.
            var pulse = 1.0
            if pulseHz > 0 {
                let phase = (t * pulseHz).truncatingRemainder(dividingBy: 1.0)
                pulse = 0.78 + 0.22 * exp(-phase * 6.0)   // quick attack, decay across the beat
            }
            var sample = 0.0
            for (k, f) in freqs.enumerated() {
                rph[k] += twoPi * f / sr
                if rph[k] > twoPi { rph[k] -= twoPi }
                var partial = 0.0
                for (h, g) in partialGains.enumerated() { partial += g * sin(Double(h + 1) * rph[k]) }
                sample += partial
            }
            sample /= Double(freqs.count) * 1.7   // normalize by voices
            ch[i] = Float(sample * env * swell * pulse * 0.5)   // headroom; final level set by the audio-mix
        }

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return true
        } catch { return false }
    }

    // MARK: - Async→sync AV bridges (same pattern used across the render flow)

    private static func firstTrack(_ asset: AVURLAsset, _ type: AVMediaType) -> AVAssetTrack? {
        var result: AVAssetTrack?
        let s = DispatchSemaphore(value: 0)
        Task { result = try? await asset.loadTracks(withMediaType: type).first; s.signal() }
        _ = s.wait(timeout: .now() + 15)
        return result
    }
    private static func duration(_ asset: AVURLAsset) -> CMTime {
        var d = CMTime.zero
        let s = DispatchSemaphore(value: 0)
        Task { d = (try? await asset.load(.duration)) ?? .zero; s.signal() }
        _ = s.wait(timeout: .now() + 15)
        return d
    }
}
#endif // circuit-convert
