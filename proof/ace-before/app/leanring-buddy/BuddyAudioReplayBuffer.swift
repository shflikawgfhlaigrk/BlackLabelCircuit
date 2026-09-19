#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  BuddyAudioReplayBuffer.swift
//  Ace
//
//  One-turn, in-process PCM retention for the single Apple Speech replay.
//

#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
import Foundation

nonisolated enum BuddyAudioReplayScrubBoundary:
    String,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case success
    case cancellation
    case failure
    case stop
    case providerSwitch
    case privateMode
    case timeout
    case replayCompletion
    case wrongTurn
    case deinitialization
}

nonisolated enum BuddyAudioReplayResult: Equatable, Sendable {
    case replayed(bufferCount: Int)
    case refused(BuddyAudioReplayEligibility)
}

/// Captured PCM is copied because AVAudioEngine reuses render buffers. The
/// copies never leave memory and are zeroed before every terminal removal.
nonisolated final class BuddyAudioReplayBuffer: @unchecked Sendable {
    private enum ReplayDecision {
        case replay([AVAudioPCMBuffer])
        case refuse(BuddyAudioReplayEligibility)
    }

    private let lock = NSLock()
    private let turnID: UUID
    private let maximumDurationSeconds: TimeInterval
    private let maximumAgeSeconds: TimeInterval
    private let zeroizationAudit:
        (@Sendable (BuddyAudioReplayScrubBoundary, [AVAudioPCMBuffer]) -> Void)?

    private var buffers: [AVAudioPCMBuffer] = []
    private var durationSeconds: TimeInterval = 0
    private var lastAppendUptime: TimeInterval?
    private var terminalEligibility: BuddyAudioReplayEligibility?
    private var hasDiscardedCapturedAudio = false

    init(
        turnID: UUID,
        maximumDurationSeconds: TimeInterval = 12,
        maximumAgeSeconds: TimeInterval = 12,
        zeroizationAudit:
            (@Sendable (BuddyAudioReplayScrubBoundary, [AVAudioPCMBuffer]) -> Void)? = nil
    ) {
        self.turnID = turnID
        self.maximumDurationSeconds = Self.finiteNonnegative(
            maximumDurationSeconds,
            fallback: 12
        )
        self.maximumAgeSeconds = Self.finiteNonnegative(
            maximumAgeSeconds,
            fallback: 12
        )
        self.zeroizationAudit = zeroizationAudit
    }

    deinit {
        lock.withLock {
            scrubLocked(.deinitialization)
        }
    }

    var bufferedDurationSeconds: TimeInterval {
        lock.withLock { durationSeconds }
    }

    var bufferedFrameCount: Int {
        lock.withLock {
            buffers.reduce(0) { $0 + Int($1.frameLength) }
        }
    }

    @discardableResult
    func append(
        _ buffer: AVAudioPCMBuffer,
        for requestedTurnID: UUID,
        atUptime: TimeInterval
    ) -> Bool {
        lock.withLock {
            guard terminalEligibility == nil,
                  requestedTurnID == turnID,
                  buffer.frameLength > 0,
                  buffer.format.sampleRate > 0,
                  let copy = Self.copyPCM(buffer) else {
                if requestedTurnID != turnID {
                    scrubLocked(.wrongTurn)
                }
                return false
            }

            let copiedDuration = Double(copy.frameLength)
                / copy.format.sampleRate
            buffers.append(copy)
            durationSeconds += copiedDuration
            lastAppendUptime = atUptime.isFinite
                ? max(atUptime, 0) : 0

            while durationSeconds > maximumDurationSeconds,
                  !buffers.isEmpty {
                let removed = buffers.removeFirst()
                hasDiscardedCapturedAudio = true
                durationSeconds -= Double(removed.frameLength)
                    / removed.format.sampleRate
                Self.zeroPCM(removed)
            }
            durationSeconds = max(durationSeconds, 0)
            // Retention limits govern recovery only. Normal live recognition
            // must continue receiving the complete microphone stream.
            return true
        }
    }

    func eligibility(
        for requestedTurnID: UUID,
        atUptime: TimeInterval,
        isCancelled: Bool
    ) -> BuddyAudioReplayEligibility {
        lock.withLock {
            if let terminalEligibility { return terminalEligibility }
            guard requestedTurnID == turnID else {
                scrubLocked(.wrongTurn)
                return .wrongTurn
            }
            guard !isCancelled else {
                scrubLocked(.cancellation)
                return .cancelled
            }
            guard !hasDiscardedCapturedAudio else { return .incomplete }
            guard !buffers.isEmpty, let lastAppendUptime else {
                return .missing
            }
            let boundedNow = atUptime.isFinite
                ? max(atUptime, 0) : lastAppendUptime + maximumAgeSeconds + 1
            guard boundedNow - lastAppendUptime <= maximumAgeSeconds else {
                scrubLocked(.timeout)
                return .expired
            }
            return .authorized
        }
    }

    /// Transfers the one authorized snapshot to a synchronous in-memory
    /// consumer, then zeroes every byte before returning. No caller can retain
    /// usable replay PCM after replay completion.
    @discardableResult
    func replayOnce(
        for requestedTurnID: UUID,
        atUptime: TimeInterval,
        isCancelled: Bool,
        consume: ([AVAudioPCMBuffer]) -> Void
    ) -> BuddyAudioReplayResult {
        let replayDecision: ReplayDecision = lock.withLock {
            if let terminalEligibility {
                return .refuse(terminalEligibility)
            }
            guard requestedTurnID == turnID else {
                scrubLocked(.wrongTurn)
                return .refuse(.wrongTurn)
            }
            guard !isCancelled else {
                scrubLocked(.cancellation)
                return .refuse(.cancelled)
            }
            guard !hasDiscardedCapturedAudio else { return .refuse(.incomplete) }
            guard !buffers.isEmpty, let lastAppendUptime else {
                return .refuse(.missing)
            }
            let boundedNow = atUptime.isFinite
                ? max(atUptime, 0) : lastAppendUptime + maximumAgeSeconds + 1
            guard boundedNow - lastAppendUptime <= maximumAgeSeconds else {
                scrubLocked(.timeout)
                return .refuse(.expired)
            }

            let transferred = buffers
            buffers.removeAll(keepingCapacity: false)
            durationSeconds = 0
            self.lastAppendUptime = nil
            terminalEligibility = .alreadyReplayed
            return .replay(transferred)
        }
        guard case .replay(let replayBuffers) = replayDecision else {
            guard case .refuse(let eligibility) = replayDecision else {
                return .refused(.missing)
            }
            return .refused(eligibility)
        }
        defer {
            for buffer in replayBuffers {
                Self.zeroPCM(buffer)
            }
            zeroizationAudit?(.replayCompletion, replayBuffers)
        }
        consume(replayBuffers)
        return .replayed(bufferCount: replayBuffers.count)
    }

    func scrub(_ boundary: BuddyAudioReplayScrubBoundary) {
        lock.withLock {
            scrubLocked(boundary)
        }
    }

    private func scrubLocked(
        _ boundary: BuddyAudioReplayScrubBoundary
    ) {
        let scrubbedBuffers = buffers
        for buffer in buffers {
            Self.zeroPCM(buffer)
        }
        zeroizationAudit?(boundary, scrubbedBuffers)
        buffers.removeAll(keepingCapacity: false)
        durationSeconds = 0
        lastAppendUptime = nil
        switch boundary {
        case .cancellation, .failure, .stop, .privateMode:
            terminalEligibility = .cancelled
        case .wrongTurn:
            terminalEligibility = .wrongTurn
        case .timeout:
            terminalEligibility = .expired
        case .replayCompletion:
            terminalEligibility = .alreadyReplayed
        case .success, .providerSwitch, .deinitialization:
            terminalEligibility = .missing
        }
    }

    private static func copyPCM(
        _ source: AVAudioPCMBuffer
    ) -> AVAudioPCMBuffer? {
        guard let destination = AVAudioPCMBuffer(
            pcmFormat: source.format,
            frameCapacity: source.frameLength
        ) else { return nil }
        destination.frameLength = source.frameLength

        let sourceList = UnsafeMutableAudioBufferListPointer(
            source.mutableAudioBufferList
        )
        let destinationList = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceList.count == destinationList.count else { return nil }

        for index in sourceList.indices {
            let sourceBuffer = sourceList[index]
            var destinationBuffer = destinationList[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData else {
                return nil
            }
            let byteCount = min(
                Int(sourceBuffer.mDataByteSize),
                Int(destinationBuffer.mDataByteSize)
            )
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffer.mDataByteSize = UInt32(byteCount)
            destinationList[index] = destinationBuffer
        }
        return destination
    }

    private static func zeroPCM(_ buffer: AVAudioPCMBuffer) {
        let list = UnsafeMutableAudioBufferListPointer(
            buffer.mutableAudioBufferList
        )
        for audioBuffer in list {
            guard let data = audioBuffer.mData else { continue }
            memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
    }

    private static func finiteNonnegative(
        _ value: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        value.isFinite ? max(value, 0) : fallback
    }
}
#endif // circuit-convert
