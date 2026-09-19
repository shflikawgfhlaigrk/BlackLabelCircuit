import Foundation

/// Advances a read cursor instead of moving the remaining audio on each emit.
/// Compaction is amortized; discard releases both consumed and pending samples.
nonisolated private struct MeetingSampleBuffer: Sendable {
    private var storage: [Float] = []
    private var readIndex = 0

    var count: Int { storage.count - readIndex }
    var isEmpty: Bool { count == 0 }

    func withReadableSamples<Result>(
        _ body: (UnsafeBufferPointer<Float>) -> Result
    ) -> Result {
        storage.withUnsafeBufferPointer { buffer in
            body(UnsafeBufferPointer(rebasing: buffer[readIndex...]))
        }
    }

    mutating func append(_ samples: [Float], silence: Bool = false) {
        if silence {
            storage.append(contentsOf: repeatElement(Float(0), count: samples.count))
        } else {
            storage.append(contentsOf: samples)
        }
    }

    mutating func consume(_ count: Int) {
        readIndex += min(count, self.count)
        if readIndex == storage.count {
            storage.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex >= 8192 && readIndex >= storage.count / 2 {
            storage.removeFirst(readIndex)
            readIndex = 0
        }
    }

    mutating func discard() {
        storage.removeAll(keepingCapacity: false)
        readIndex = 0
    }
}

/// Keeps Ace's acoustic speaker bleed out of the meeting microphone without
/// muting ScreenCaptureKit's independent system-audio lane.
nonisolated struct MeetingMicrophoneSelfVoiceSuppression: Sendable {
    private let tailSeconds: TimeInterval
    private var suppressedUntil = Date.distantPast

    init(tailSeconds: TimeInterval) {
        self.tailSeconds = max(0, tailSeconds)
    }

    mutating func observeAceSpeech(
        isActive: Bool,
        now: Date
    ) {
        guard isActive else { return }
        suppressedUntil = max(
            suppressedUntil,
            now.addingTimeInterval(tailSeconds)
        )
    }

    mutating func observeAceSpeechEnded(at speechEndedAt: Date) {
        guard speechEndedAt != .distantPast else { return }
        suppressedUntil = max(
            suppressedUntil,
            speechEndedAt.addingTimeInterval(tailSeconds)
        )
    }

    func shouldSuppressMicrophone(at now: Date) -> Bool {
        now < suppressedUntil
    }
}

/// FIFO-pairs meeting microphone and system audio while guaranteeing forward
/// progress when either real-time source stops delivering or leaves a short
/// tail. Missing samples are silence; a suppressed microphone therefore never
/// deletes the independent system-audio samples paired with it.
nonisolated struct MeetingAudioSamplePairer: Sendable {
    private let emitFrameCount: Int
    private let maximumPairingSkewFrameCount: Int
    private var microphoneSamples = MeetingSampleBuffer()
    private var systemSamples = MeetingSampleBuffer()

    init(
        emitFrameCount: Int,
        maximumPairingSkewFrameCount: Int
    ) {
        self.emitFrameCount = max(1, emitFrameCount)
        self.maximumPairingSkewFrameCount = max(
            self.emitFrameCount,
            maximumPairingSkewFrameCount
        )
    }

    mutating func appendMicrophone(
        _ samples: [Float],
        suppressForSelfVoice: Bool
    ) -> [[Float]] {
        microphoneSamples.append(samples, silence: suppressForSelfVoice)
        return drainReadySamples()
    }

    mutating func appendSystem(_ samples: [Float]) -> [[Float]] {
        systemSamples.append(samples)
        return drainReadySamples()
    }

    mutating func flush() -> [[Float]] {
        guard !microphoneSamples.isEmpty || !systemSamples.isEmpty else {
            return []
        }
        var outputBatches: [[Float]] = []
        while !microphoneSamples.isEmpty || !systemSamples.isEmpty {
            outputBatches.append(
                removeMixedPrefix(
                    count: min(
                        emitFrameCount,
                        max(microphoneSamples.count, systemSamples.count)
                    )
                )
            )
        }
        return outputBatches
    }

    mutating func discard() {
        microphoneSamples.discard()
        systemSamples.discard()
    }

    private mutating func drainReadySamples() -> [[Float]] {
        var outputBatches: [[Float]] = []
        while microphoneSamples.count >= emitFrameCount,
              systemSamples.count >= emitFrameCount {
            outputBatches.append(
                removeMixedPrefix(count: emitFrameCount)
            )
        }

        while microphoneSamples.count
                >= maximumPairingSkewFrameCount,
              systemSamples.count < emitFrameCount {
            outputBatches.append(
                removeMixedPrefix(count: emitFrameCount)
            )
        }
        while systemSamples.count
                >= maximumPairingSkewFrameCount,
              microphoneSamples.count < emitFrameCount {
            outputBatches.append(
                removeMixedPrefix(count: emitFrameCount)
            )
        }
        return outputBatches
    }

    private mutating func removeMixedPrefix(count: Int) -> [Float] {
        var mixed = [Float](repeating: 0, count: count)
        microphoneSamples.withReadableSamples { microphone in
            systemSamples.withReadableSamples { system in
                mixed.withUnsafeMutableBufferPointer { output in
                    let pairedCount = min(count, microphone.count, system.count)
                    for index in 0..<pairedCount {
                        output[index] = Self.mix(
                            microphoneSample: microphone[index],
                            systemSample: system[index]
                        )
                    }
                    for index in pairedCount..<min(count, microphone.count) {
                        output[index] = Self.mix(
                            microphoneSample: microphone[index], systemSample: 0
                        )
                    }
                    for index in pairedCount..<min(count, system.count) {
                        output[index] = system[index]
                    }
                }
            }
        }
        microphoneSamples.consume(count)
        systemSamples.consume(count)
        return mixed
    }

    private static func mix(
        microphoneSample: Float,
        systemSample: Float
    ) -> Float {
        if microphoneSample == 0 { return systemSample }
        if systemSample == 0 { return microphoneSample }
        return (microphoneSample + systemSample) * 0.5
    }
}

/// Holds the newest bounded meeting-audio window while push-to-talk owns the
/// process's sole on-device Speech recognizer, then drains it exactly once.
nonisolated struct MeetingPausedAudioQueue<Element> {
    private let maximumCount: Int
    private var elements: [Element] = []
    private var oldestIndex = 0

    init(maximumCount: Int) {
        self.maximumCount = max(1, maximumCount)
    }

    mutating func append(_ element: Element) {
        if elements.count < maximumCount {
            elements.append(element)
        } else {
            elements[oldestIndex] = element
            oldestIndex = (oldestIndex + 1) % maximumCount
        }
    }

    mutating func drain() -> [Element] {
        var drained: [Element]
        if oldestIndex == 0 {
            drained = elements
        } else {
            drained = []
            drained.reserveCapacity(elements.count)
            drained.append(contentsOf: elements[oldestIndex...])
            drained.append(contentsOf: elements[..<oldestIndex])
        }
        elements.removeAll(keepingCapacity: true)
        oldestIndex = 0
        return drained
    }

    mutating func discard() {
        elements.removeAll(keepingCapacity: false)
        oldestIndex = 0
    }
}
