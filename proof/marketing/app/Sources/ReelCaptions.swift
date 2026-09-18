// Black Label Marketing — REEL AUTOCAPTION: timed subtitles burned INTO the exported .mp4.
//
// The reel renderer already draws each scene's title card; what it could not do is put the
// SPOKEN line on screen, on time, baked into the video — the thing that makes a reel readable
// on a muted feed. This is that track.
//
// Two honest sources, and deliberately only two — no model writes a subtitle here:
//   1. SCRIPT      — the buyer's OWN words: each scene's `voiceScript` (the exact text
//                    ReelProject.voiceoverText hands to the on-device narrator), optionally the
//                    scene's headline + subtitle. Nothing is rephrased, nothing is added.
//   2. SUPPLIED    — an already-timed track handed to the renderer, e.g. the real on-device
//                    transcription SpeechCaptionEngine produces from the buyer's own footage
//                    (import it here with `parseSRT`, which round-trips SpeechCaptionEngine.srt).
// A caption that says something the buyer never said is a fabricated claim about their business
// (§5.1), so there is no "let the model write a caption" path in this file at all.
//
// Everything except reading a file is PURE — wrapping, timing, the per-frame lookup and the
// fade — so the whole path is unit-tested headlessly and the renderer's per-frame behaviour is
// deterministic. `TimedCaption` is reused from SpeechCaptions.swift so a transcribed track and a
// script-derived track are the same type end to end.
import Foundation

/// Where a reel's burned-in subtitle text comes from. Both values name a source of REAL words.
enum ReelCaptionSource: String, Codable, CaseIterable, Identifiable, Hashable {
    /// The buyer's own scene narration script (and optionally the scene copy).
    case script = "Script"
    /// A pre-timed track supplied to the renderer (real transcription of the buyer's footage).
    case supplied = "Supplied"
    var id: String { rawValue }
}

/// A reel's burned-in subtitle settings, persisted on the project. Off by default so every
/// existing reel renders byte-for-byte as it did before this file existed.
struct ReelCaptionSettings: Codable, Hashable {
    var enabled: Bool = false
    var source: ReelCaptionSource = .script
    /// Also caption scenes that have NO separate narration script. Off by default on purpose:
    /// those scenes' words are the headline/subtitle, which the renderer already draws large on
    /// screen — captioning them again just prints the same sentence twice.
    var includeSceneCopy: Bool = false
    /// Wrap width for one on-screen line. Short lines read; paragraphs do not.
    var maxLineCharacters: Int = 34
    /// Draw the line upper-cased (some brand kits set their whole reel in caps).
    var uppercase: Bool = false
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum ReelCaptionEngine {
    /// The crossfade at each end of a line (seconds).
    static let fadeSeconds: Double = 0.12

    // MARK: - Source text (the buyer's own words — never rewritten)

    /// The words this scene actually says, composed EXACTLY the way ReelProject.voiceoverText
    /// composes them, so the burned-in line matches the narration rather than paraphrasing it.
    /// Returns "" when the scene contributes no caption.
    static func sceneScript(_ scene: ReelScene, includeSceneCopy: Bool) -> String {
        let script = scene.voiceScript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !script.isEmpty { return script }
        guard includeSceneCopy else { return "" }
        let parts = [scene.headline, scene.subtitle]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: ". ")
    }

    // MARK: - Wrapping (pure)

    /// Break text into readable caption lines at WORD boundaries. A single word longer than the
    /// limit gets its own line rather than being chopped — a half-word on screen is worse than a
    /// wide one. Every word of the input survives, in order.
    static func wrap(_ text: String, maxCharacters: Int) -> [String] {
        let limit = max(8, maxCharacters)
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        guard !words.isEmpty else { return [] }
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= limit {
                current += " " + word
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    // MARK: - Timing (pure)

    /// Spread `lines` across the window [start, start + duration], each line holding the screen
    /// in proportion to its length (longer line = more reading time). Lines never overlap and
    /// never run past the window, so a caption can never bleed into the next scene.
    static func distribute(_ lines: [String], start: Double, duration: Double) -> [TimedCaption] {
        guard !lines.isEmpty, duration > 0 else { return [] }
        let weights = lines.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return [] }
        var out: [TimedCaption] = []
        var cursor = start
        for (index, line) in lines.enumerated() {
            // The last line takes the exact remainder so rounding can never leave a gap or an
            // overrun at the scene boundary.
            let end = index == lines.count - 1 ? start + duration : cursor + duration * (weights[index] / total)
            out.append(TimedCaption(text: line, start: cursor, end: max(cursor, end)))
            cursor = end
        }
        return out
    }

    /// The full script-derived track for a project, in reel time. Pure: no file, no network, no
    /// permission — which is why it works on the headless `--render-reel` path.
    static func scriptTrack(project: ReelProject) -> [TimedCaption] {
        let settings = project.captions
        var out: [TimedCaption] = []
        var sceneStart = 0.0
        for scene in project.scenes {
            let duration = max(0.4, scene.seconds)
            let text = sceneScript(scene, includeSceneCopy: settings.includeSceneCopy)
            if !text.isEmpty {
                let raw = settings.uppercase ? text.uppercased() : text
                out.append(contentsOf: distribute(wrap(raw, maxCharacters: settings.maxLineCharacters),
                                                  start: sceneStart, duration: duration))
            }
            sceneStart += duration
        }
        return out.filter { $0.duration > 0 }
    }

    /// The track the renderer should actually burn in.
    /// `supplied` (a real transcription) always wins when present; otherwise the script track.
    /// Captions off ⇒ an EMPTY track, so an existing project renders exactly as it always did.
    static func track(project: ReelProject, supplied: [TimedCaption] = []) -> [TimedCaption] {
        guard project.captions.enabled else { return [] }
        if !supplied.isEmpty { return supplied.sorted { $0.start < $1.start } }
        guard project.captions.source == .script else { return [] }
        return scriptTrack(project: project)
    }

    // MARK: - Per-frame lookup (pure)

    /// The line on screen at `seconds`, or nil. The track is ordered and non-overlapping.
    static func active(_ track: [TimedCaption], at seconds: Double) -> TimedCaption? {
        track.first { seconds >= $0.start && seconds < $0.end }
    }

    /// A line's opacity at `seconds`: a short crossfade at each end so lines dissolve instead of
    /// popping. Clamped so a very short line still reaches full opacity mid-line.
    static func alpha(for caption: TimedCaption, at seconds: Double) -> Double {
        let duration = caption.duration
        guard duration > 0 else { return 0 }
        let fade = min(fadeSeconds, duration / 3)
        let t = seconds - caption.start
        guard t >= 0, t <= duration else { return 0 }
        guard fade > 0 else { return 1 }
        if t < fade { return t / fade }
        if t > duration - fade { return (duration - t) / fade }
        return 1
    }

    // MARK: - SubRip import (pure) — closes the loop with the on-device transcriber

    /// Parse a SubRip (.srt) document into a timed track. This is the inverse of
    /// SpeechCaptionEngine.srt, so a sidecar written by the on-device transcriber can be burned
    /// straight into a reel. Malformed blocks are SKIPPED rather than guessed at.
    static func parseSRT(_ text: String) -> [TimedCaption] {
        var out: [TimedCaption] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let arrowIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let stamps = lines[arrowIndex].components(separatedBy: "-->")
            guard stamps.count == 2,
                  let start = srtSeconds(stamps[0]), let end = srtSeconds(stamps[1]) else { continue }
            let body = lines[(arrowIndex + 1)...].joined(separator: " ")
            guard !body.isEmpty else { continue }
            out.append(TimedCaption(text: body, start: start, end: max(start, end)))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// "00:01:02,500" → 62.5 seconds. nil when the stamp is not a SubRip timestamp.
    static func srtSeconds(_ raw: String) -> Double? {
        let stamp = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = stamp.components(separatedBy: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}
#endif // circuit-convert
