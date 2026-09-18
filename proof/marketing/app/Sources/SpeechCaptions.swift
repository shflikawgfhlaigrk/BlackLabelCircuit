// Black Label Marketing — on-device speech → timed captions (Apple Speech framework).
// The buyer's recording never leaves this machine: requiresOnDeviceRecognition is forced ON,
// and any configuration where on-device recognition is unavailable fails HONESTLY (clear
// error message) instead of silently falling back to a server. No paid services, no network.
//
// The pure parts (word → line grouping, SRT serialization) are split from the Speech calls
// so they can be unit-tested headlessly without microphone/recognizer entitlements.

import Foundation
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(Speech) && !CIRCUIT_WINDOWS_SIM
import Speech
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

// MARK: - Model

/// One caption line with real recognizer word-timestamp bounds (seconds from clip start).
struct TimedCaption: Identifiable, Hashable {
    var id = UUID()
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var duration: TimeInterval { max(0, end - start) }
}

/// One recognized word with its timestamp — the pure input to the line grouper. Mirrors
/// SFTranscriptionSegment so grouping is testable without constructing Speech types.
struct SpeechCaptionWord: Hashable {
    var text: String
    var start: TimeInterval
    var duration: TimeInterval
    var end: TimeInterval { start + max(0, duration) }
}

// MARK: - Engine

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum SpeechCaptionEngine {
    enum CaptionError: LocalizedError {
        case permissionDenied
        case recognizerUnavailable
        case onDeviceUnsupported(String)
        case noAudioTrack
        case noSpeech
        case recognition(String)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Speech recognition permission was not granted. Enable it in System Settings → Privacy & Security → Speech Recognition, then try again."
            case .recognizerUnavailable:
                return "The speech recognizer is not available on this device right now."
            case .onDeviceUnsupported(let locale):
                return "On-device transcription is not available for \(locale) on this device. Captions only run on-device — nothing is uploaded — so this clip cannot be auto-captioned here."
            case .noAudioTrack:
                return "The recording has no audio track to transcribe."
            case .noSpeech:
                return "No speech was detected in the recording, so there are no captions to burn in."
            case .recognition(let reason):
                return "On-device transcription failed: \(reason)"
            }
        }
    }

    /// Line-grouping tuning: readable caption lines, not one giant paragraph.
    private static let maxLineCharacters = 38
    private static let maxLineSeconds: TimeInterval = 3.5
    private static let silenceBreak: TimeInterval = 0.8
    private static let minimumCaptionSeconds: TimeInterval = 0.9

    // Keeps the recognizer + task alive for the duration of one recognition (the result
    // handler captures the box; releasing both at the end breaks the retain cycle).
    private final class RecognitionBox {
        var recognizer: SFSpeechRecognizer?
        var task: SFSpeechRecognitionTask?
        let lock = NSLock()
        var finished = false

        /// True exactly once — recognizers can call the handler again after a final result.
        func claimFinish() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if finished { return false }
            finished = true
            return true
        }
    }

#if os(macOS)
    /// True when the buyer has explicitly denied (or MDM has restricted) speech recognition —
    /// the states only System Settings can change, so they are the ones that earn a deep link.
    static var permissionBlockedInSettings: Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted: return true
        default: return false
        }
    }

    /// Open the EXACT pane that controls this permission (System Settings → Privacy & Security →
    /// Speech Recognition) — the same Privacy_* anchor pattern the camera/microphone/screen
    /// permission surfaces already use, so no denial recovery ever lands on a generic page.
    static func openSpeechRecognitionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }
#endif

    /// Ask for speech-recognition permission (async prompt on first use). Completion on main.
    static func requestPermission(completion: @escaping (Bool) -> Void) {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async { completion(status == .authorized) }
            }
        default:
            DispatchQueue.main.async { completion(false) }
        }
    }

    /// Transcribe a recorded clip into timed caption lines. Strictly on-device
    /// (requiresOnDeviceRecognition = true). Completion is delivered on the main queue.
    static func transcribe(videoURL: URL, locale: Locale = .current,
                           completion: @escaping (Result<[TimedCaption], Error>) -> Void) {
        let finish: (Result<[TimedCaption], Error>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        let asset = AVURLAsset(url: videoURL)
        guard !asset.tracks(withMediaType: .audio).isEmpty else {
            finish(.failure(CaptionError.noAudioTrack)); return
        }
        requestPermission { granted in
            guard granted else { finish(.failure(CaptionError.permissionDenied)); return }
            let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer()
            guard let recognizer, recognizer.isAvailable else {
                finish(.failure(CaptionError.recognizerUnavailable)); return
            }
            guard recognizer.supportsOnDeviceRecognition else {
                finish(.failure(CaptionError.onDeviceUnsupported(recognizer.locale.identifier))); return
            }
            let request = SFSpeechURLRecognitionRequest(url: videoURL)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            request.taskHint = .dictation
            request.addsPunctuation = true

            let box = RecognitionBox()
            box.recognizer = recognizer
            box.task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    guard box.claimFinish() else { return }
                    box.task = nil; box.recognizer = nil
                    finish(.failure(CaptionError.recognition(error.localizedDescription)))
                    return
                }
                guard let result, result.isFinal else { return }
                guard box.claimFinish() else { return }
                box.task = nil; box.recognizer = nil
                let words = result.bestTranscription.segments.map {
                    SpeechCaptionWord(text: $0.substring, start: $0.timestamp, duration: $0.duration)
                }
                let captions = captionLines(from: words)
                if captions.isEmpty {
                    finish(.failure(CaptionError.noSpeech))
                } else {
                    finish(.success(captions))
                }
            }
        }
    }

    /// Async form of `transcribe` for callers already in a task context.
    static func transcribe(videoURL: URL, locale: Locale = .current) async throws -> [TimedCaption] {
        try await withCheckedThrowingContinuation { continuation in
            transcribe(videoURL: videoURL, locale: locale) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: Grouping (pure)

    /// Group recognizer words into readable caption lines: break on long silences, cap line
    /// length and on-screen seconds, then extend blink-length lines to a readable minimum
    /// without ever overlapping the next line.
    static func captionLines(from words: [SpeechCaptionWord]) -> [TimedCaption] {
        let clean = words
            .map { SpeechCaptionWord(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                     start: $0.start, duration: $0.duration) }
            .filter { !$0.text.isEmpty }
        guard !clean.isEmpty else { return [] }

        var lines: [TimedCaption] = []
        var lineWords: [SpeechCaptionWord] = []

        func flush() {
            guard let first = lineWords.first, let last = lineWords.last else { return }
            let text = lineWords.map(\.text).joined(separator: " ")
            lines.append(TimedCaption(text: text, start: first.start, end: max(last.end, first.start)))
            lineWords = []
        }

        for word in clean {
            if let first = lineWords.first, let last = lineWords.last {
                let candidateLength = lineWords.map(\.text).joined(separator: " ").count + 1 + word.text.count
                let candidateSeconds = word.end - first.start
                let gap = word.start - last.end
                if candidateLength > maxLineCharacters || candidateSeconds > maxLineSeconds || gap > silenceBreak {
                    flush()
                }
            }
            lineWords.append(word)
        }
        flush()

        // Give very short lines a readable floor, clamped so lines never overlap.
        for index in lines.indices {
            var end = max(lines[index].end, lines[index].start + minimumCaptionSeconds)
            if index + 1 < lines.count { end = min(end, lines[index + 1].start) }
            lines[index].end = max(end, lines[index].start + 0.2)
        }
        return lines
    }

    // MARK: SRT (pure serialization + save)

    /// Serialize captions as a standard SubRip (.srt) document.
    static func srt(from captions: [TimedCaption]) -> String {
        captions.enumerated().map { index, caption in
            "\(index + 1)\n\(srtTimestamp(caption.start)) --> \(srtTimestamp(caption.end))\n\(caption.text)\n"
        }.joined(separator: "\n")
    }

    static func srtTimestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, seconds)
        let ms = Int((total * 1000).rounded()) % 1000
        let s = Int(total) % 60
        let m = (Int(total) / 60) % 60
        let h = Int(total) / 3600
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    /// Write an .srt file (UTF-8) to a concrete destination. Throws on failure so callers
    /// can report honestly instead of pretending the sidecar exists.
    static func writeSRT(_ captions: [TimedCaption], to url: URL) throws {
        try Data(srt(from: captions).utf8).write(to: url, options: .atomic)
    }

    #if os(macOS)
    /// Save-panel export of the captions as .srt. Returns the written URL, or nil if the
    /// buyer cancelled. Throws if the chosen destination could not be written.
    @MainActor
    @discardableResult
    static func exportSRTWithPanel(_ captions: [TimedCaption],
                                   suggestedName: String = "captions.srt") throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        try? FileManager.default.removeItem(at: destination)
        try writeSRT(captions, to: destination)
        return destination
    }
    #endif
}
#endif // circuit-convert
