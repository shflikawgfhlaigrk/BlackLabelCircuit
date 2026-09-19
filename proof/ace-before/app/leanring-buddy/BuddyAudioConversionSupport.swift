//
//  BuddyAudioConversionSupport.swift
//  leanring-buddy
//
//  Shared audio conversion helpers for voice transcription providers.
//

#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
import Foundation

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated private final class BuddyPCM16SourceBufferBox:
    @unchecked Sendable
{
    private let lock = NSLock()
    private let audioBuffer: AVAudioPCMBuffer
    private var consumedFrames: AVAudioFrameCount = 0

    init(audioBuffer: AVAudioPCMBuffer) {
        self.audioBuffer = audioBuffer
    }

    func nextBuffer(
        requestedFrames: AVAudioPacketCount,
        status: UnsafeMutablePointer<AVAudioConverterInputStatus>
    ) -> AVAudioBuffer? {
        lock.withLock { () -> AVAudioBuffer? in
            let remainingFrames = audioBuffer.frameLength - consumedFrames
            guard remainingFrames > 0, requestedFrames > 0 else {
                status.pointee = .noDataNow
                return nil
            }
            let frameCount = min(remainingFrames, requestedFrames)
            guard let portion = AVAudioPCMBuffer(
                pcmFormat: audioBuffer.format,
                frameCapacity: frameCount
            ) else {
                status.pointee = .noDataNow
                return nil
            }
            portion.frameLength = frameCount
            let bytesPerFrame = Int(audioBuffer.format.streamDescription.pointee.mBytesPerFrame)
            let sources = UnsafeMutableAudioBufferListPointer(audioBuffer.mutableAudioBufferList)
            let destinations = UnsafeMutableAudioBufferListPointer(portion.mutableAudioBufferList)
            for index in sources.indices {
                guard let source = sources[index].mData,
                      let destination = destinations[index].mData else { continue }
                memcpy(destination, source.advanced(by: Int(consumedFrames) * bytesPerFrame), Int(frameCount) * bytesPerFrame)
            }
            consumedFrames += frameCount
            status.pointee = .haveData
            return portion
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated final class BuddyPCM16AudioConverter {
    private let targetAudioFormat: AVAudioFormat
    private let primeMethod: AVAudioConverterPrimeMethod
    private var audioConverter: AVAudioConverter?
    private var currentInputFormatDescription: String?

    init(targetSampleRate: Double, primeMethod: AVAudioConverterPrimeMethod = .normal) {
        self.primeMethod = primeMethod
        self.targetAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    func convertToPCM16Data(from audioBuffer: AVAudioPCMBuffer) -> Data? {
        let inputFormatDescription = audioBuffer.format.settings.description

        if currentInputFormatDescription != inputFormatDescription {
            audioConverter = AVAudioConverter(from: audioBuffer.format, to: targetAudioFormat)
            audioConverter?.primeMethod = primeMethod
            currentInputFormatDescription = inputFormatDescription
        }

        guard let audioConverter else { return nil }

        let sampleRateRatio = targetAudioFormat.sampleRate / audioBuffer.format.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(
            (Double(audioBuffer.frameLength) * sampleRateRatio).rounded(.up) + 32
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        let sourceBufferBox = BuddyPCM16SourceBufferBox(
            audioBuffer: audioBuffer
        )
        var conversionError: NSError?

        let conversionStatus = audioConverter.convert(to: outputBuffer, error: &conversionError) { requestedFrames, outStatus in
            sourceBufferBox.nextBuffer(requestedFrames: requestedFrames, status: outStatus)
        }

        guard conversionStatus != .error else { return nil }
        guard let pcmDataPointer = outputBuffer.audioBufferList.pointee.mBuffers.mData else { return nil }

        let bytesPerFrame = Int(targetAudioFormat.streamDescription.pointee.mBytesPerFrame)
        let byteCount = Int(outputBuffer.frameLength) * bytesPerFrame
        guard byteCount > 0 else { return nil }

        return Data(bytes: pcmDataPointer, count: byteCount)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// One recognition request must retain one PCM format even when Bluetooth
/// changes profile or the owner selects a different microphone mid-turn.
nonisolated final class BuddySpeechAudioNormalizer {
    private let converter = BuddyPCM16AudioConverter(targetSampleRate: 16_000, primeMethod: .none)
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16_000,
        channels: 1,
        interleaved: true
    )!

    func normalize(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let data = converter.convertToPCM16Data(from: buffer),
              let normalized = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
              ),
              let destination = normalized.mutableAudioBufferList.pointee.mBuffers.mData
        else { return nil }
        normalized.frameLength = normalized.frameCapacity
        data.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: data.count)
        return normalized
    }
}
#endif // circuit-convert

nonisolated enum BuddyWAVFileBuilder {
    static func buildWAVData(
        fromPCM16MonoAudio pcm16AudioData: Data,
        sampleRate: Int,
        channelCount: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        let byteRate = sampleRate * channelCount * bitsPerSample / 8
        let blockAlign = channelCount * bitsPerSample / 8
        let dataChunkSize = UInt32(pcm16AudioData.count)
        let fileSize = UInt32(36) + dataChunkSize

        var wavData = Data()

        wavData.append("RIFF".data(using: .ascii)!)
        wavData.append(littleEndianData(from: fileSize))
        wavData.append("WAVE".data(using: .ascii)!)
        wavData.append("fmt ".data(using: .ascii)!)
        wavData.append(littleEndianData(from: UInt32(16)))
        wavData.append(littleEndianData(from: UInt16(1)))
        wavData.append(littleEndianData(from: UInt16(channelCount)))
        wavData.append(littleEndianData(from: UInt32(sampleRate)))
        wavData.append(littleEndianData(from: UInt32(byteRate)))
        wavData.append(littleEndianData(from: UInt16(blockAlign)))
        wavData.append(littleEndianData(from: UInt16(bitsPerSample)))
        wavData.append("data".data(using: .ascii)!)
        wavData.append(littleEndianData(from: dataChunkSize))
        wavData.append(pcm16AudioData)

        return wavData
    }

    private static func littleEndianData<T: FixedWidthInteger>(from value: T) -> Data {
        var littleEndianValue = value.littleEndian
        return Data(bytes: &littleEndianValue, count: MemoryLayout<T>.size)
    }
}
