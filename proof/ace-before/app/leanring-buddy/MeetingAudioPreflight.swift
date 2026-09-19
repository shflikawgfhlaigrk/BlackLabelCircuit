//
//  MeetingAudioPreflight.swift
//  Ace
//

import Foundation

/// Retains interruption history separately from current source availability.
/// Recovery restores capture but cannot recover words already missed.
nonisolated struct MeetingCaptureSourceGaps: Sendable {
    enum Source: String, CaseIterable, Sendable {
        case microphone = "Microphone"
        case systemAudio = "System audio"
    }

    private var interruptedSources: Set<Source> = []
    private var currentlyUnavailable: Set<Source> = []

    @discardableResult
    mutating func recordLoss(_ source: Source) -> Bool {
        interruptedSources.insert(source)
        return currentlyUnavailable.insert(source).inserted
    }

    mutating func recordRecovery(_ source: Source) {
        currentlyUnavailable.remove(source)
    }

    var descriptions: [String] {
        Source.allCases.filter { interruptedSources.contains($0) }.map {
            "\($0.rawValue) capture was interrupted during this meeting. "
                + "Words spoken during that interruption may be missing."
        }
    }

    mutating func discard() {
        interruptedSources.removeAll(keepingCapacity: false)
        currentlyUnavailable.removeAll(keepingCapacity: false)
    }
}

enum MeetingAudioSourceState: String, Codable, Equatable, Sendable {
    case unavailable
    case silent
    case active
}

struct MeetingAudioPreflightResult: Codable, Equatable, Sendable {
    let microphone: MeetingAudioSourceState
    let systemAudio: MeetingAudioSourceState
    let microphonePeak: Double
    let systemAudioPeak: Double

    var canStart: Bool {
        microphone != .unavailable || systemAudio != .unavailable
    }

    var summary: String {
        "Microphone \(description(microphone)); System audio "
            + description(systemAudio).lowercased() + "."
    }

    private func description(
        _ state: MeetingAudioSourceState
    ) -> String {
        switch state {
        case .active: return "is receiving sound"
        case .silent: return "is silent"
        case .unavailable: return "is unavailable"
        }
    }
}

enum MeetingAudioPreflight {
    static let audiblePeakThreshold = 0.003

    static func evaluate(
        microphoneAvailable: Bool,
        microphonePeak: Double,
        systemAudioAvailable: Bool,
        systemAudioPeak: Double
    ) -> MeetingAudioPreflightResult {
        MeetingAudioPreflightResult(
            microphone: sourceState(
                available: microphoneAvailable,
                peak: microphonePeak
            ),
            systemAudio: sourceState(
                available: systemAudioAvailable,
                peak: systemAudioPeak
            ),
            microphonePeak: max(0, microphonePeak),
            systemAudioPeak: max(0, systemAudioPeak)
        )
    }

    private static func sourceState(
        available: Bool,
        peak: Double
    ) -> MeetingAudioSourceState {
        guard available else { return .unavailable }
        return peak >= audiblePeakThreshold ? .active : .silent
    }
}

/// Thread-safe peak sampler shared by AVAudioEngine and ScreenCaptureKit
/// callbacks during the bounded start preflight.
final class MeetingAudioLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var maximumPeak: Float = 0

    func observe(_ samples: [Float]) {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        lock.lock()
        maximumPeak = max(maximumPeak, peak)
        lock.unlock()
    }

    var peak: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(maximumPeak)
    }
}
