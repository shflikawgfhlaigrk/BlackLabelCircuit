#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
import Foundation

@MainActor
protocol BuddyDictationAudioCapturing: AnyObject {
    var inputFormat: AVAudioFormat { get }
    var configurationChangeNotificationObject: AnyObject? { get }
    var synchronousAudioEngine: AVAudioEngine? { get }
    var needsConfigurationRecovery: Bool { get }
    func installTap(
        bufferSize: AVAudioFrameCount,
        handler: @escaping AVAudioNodeTapBlock
    )
    func start() throws
    func stop()
}

extension BuddyDictationAudioCapturing {
    var needsConfigurationRecovery: Bool { true }
}

enum BuddyDictationAudioCaptureError: LocalizedError {
    case unusableInputFormat(sampleRate: Double, channels: AVAudioChannelCount)

    var errorDescription: String? {
        switch self {
        case .unusableInputFormat(let sampleRate, let channels):
            return "the selected microphone has no usable audio format "
                + "(\(Int(sampleRate)) Hz / \(channels) channels)."
        }
    }
}

/// Owns one AVAudioEngine for one dictation capture. A new lease is created
/// after the transcription provider is ready, so its input node is bound to the
/// microphone that is current at that moment instead of the device that was
/// current when Ace launched.
@MainActor
final class BuddyDictationAudioCaptureLease: BuddyDictationAudioCapturing {
    let engine: AVAudioEngine
    let inputNode: AVAudioInputNode
    let inputFormat: AVAudioFormat

    private var tapIsInstalled = false

    var configurationChangeNotificationObject: AnyObject? { engine }
    var synchronousAudioEngine: AVAudioEngine? { engine }
    var needsConfigurationRecovery: Bool {
        !engine.isRunning || !inputNode.outputFormat(forBus: 0).isEqual(inputFormat)
    }

    init() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0 else {
            throw BuddyDictationAudioCaptureError.unusableInputFormat(
                sampleRate: inputFormat.sampleRate,
                channels: inputFormat.channelCount
            )
        }

        self.engine = engine
        self.inputNode = inputNode
        self.inputFormat = inputFormat
    }

    func installTap(
        bufferSize: AVAudioFrameCount,
        handler: @escaping AVAudioNodeTapBlock
    ) {
        if tapIsInstalled {
            inputNode.removeTap(onBus: 0)
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: bufferSize,
            format: inputFormat,
            block: handler
        )
        tapIsInstalled = true
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
        if tapIsInstalled {
            inputNode.removeTap(onBus: 0)
            tapIsInstalled = false
        }
    }
}
#endif // circuit-convert
