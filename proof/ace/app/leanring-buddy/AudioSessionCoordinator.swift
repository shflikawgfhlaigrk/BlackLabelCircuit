//
//  AudioSessionCoordinator.swift
//  Ace
//
//  One process-wide ownership ledger for every microphone and speech path.
//  Native engines remain in their focused components, but none may open or
//  remain open without holding the corresponding coordinator lease.
//

import Foundation

enum AudioCaptureOwner: String, Codable, Sendable {
    case pushToTalk
    case stealthExitOnly
    case partner
    case meetingNotes
}

enum AudioSessionDecision: Equatable, Sendable {
    case acquired
    case alreadyOwned
    case released
    case interruptedMeetingNotes
    case resumedMeetingNotes
    case refused(reason: String)

    var visibleFailure: String? {
        guard case let .refused(reason) = self else { return nil }
        return reason
    }
}

struct AudioSessionSnapshot: Equatable, Sendable {
    let captureOwner: AudioCaptureOwner?
    let speechIsActive: Bool
    let meetingNotesAreSuspended: Bool
}

final class AudioSessionCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var captureOwner: AudioCaptureOwner?
    private var speechIsActive = false
    private var meetingNotesAreSuspended = false

    var snapshot: AudioSessionSnapshot {
        lock.withLock {
            AudioSessionSnapshot(
                captureOwner: captureOwner,
                speechIsActive: speechIsActive,
                meetingNotesAreSuspended: meetingNotesAreSuspended
            )
        }
    }

    func acquireCapture(
        _ owner: AudioCaptureOwner
    ) -> AudioSessionDecision {
        lock.withLock {
            if captureOwner == owner {
                return .alreadyOwned
            }
            if speechIsActive {
                // BARGE-IN. A push-to-talk press mid-answer IS the owner
                // claiming the floor — refusing it is the bug, not the guard.
                // The press produced no recording at all: the caller
                // (BuddyDictationManager) treats a refusal as a hard stop, so
                // the very first attempt to interrupt Ace silently did nothing
                // and the owner had to press a second time. Every other claimant
                // still waits for playback to finish, because only push to talk
                // is a deliberate human interrupt.
                //
                // Taking the floor also ENDS the speech claim. Leaving
                // `speechIsActive` set would let the next `beginSpeech` see
                // `.alreadyOwned` and start talking straight over a live
                // push-to-talk recording — the exact "Ace's voice is coming in
                // on the mic" failure the lease exists to prevent.
                guard owner == .pushToTalk else {
                    return .refused(
                        reason:
                            "Voice playback is finishing. Voice input did not start; try again when the response ends."
                    )
                }
                speechIsActive = false
            }
            guard let current = captureOwner else {
                captureOwner = owner
                return .acquired
            }
            if current == .meetingNotes, owner == .pushToTalk {
                captureOwner = .pushToTalk
                meetingNotesAreSuspended = true
                return .interruptedMeetingNotes
            }
            return .refused(
                reason:
                    "\(displayName(current)) is using voice input. \(displayName(owner)) did not start."
            )
        }
    }

    func releaseCapture(
        _ owner: AudioCaptureOwner
    ) -> AudioSessionDecision {
        lock.withLock {
            guard captureOwner == owner else {
                return .refused(
                    reason:
                        "\(displayName(owner)) did not own voice input, so no audio session was changed."
                )
            }
            if owner == .pushToTalk, meetingNotesAreSuspended {
                captureOwner = .meetingNotes
                meetingNotesAreSuspended = false
                return .resumedMeetingNotes
            }
            captureOwner = nil
            return .released
        }
    }

    /// Removes an owner's standing claim even when another owner temporarily
    /// interrupted it. Meeting Notes uses this when it is stopped from a UI
    /// control while push to talk is still holding the microphone.
    func withdrawCapture(
        _ owner: AudioCaptureOwner
    ) -> AudioSessionDecision {
        lock.withLock {
            if captureOwner == owner {
                captureOwner = nil
                return .released
            }
            if owner == .meetingNotes, meetingNotesAreSuspended {
                meetingNotesAreSuspended = false
                return .released
            }
            return .refused(
                reason:
                    "\(displayName(owner)) had no active or suspended voice-input claim."
            )
        }
    }

    func beginSpeech() -> AudioSessionDecision {
        lock.withLock {
            if speechIsActive { return .alreadyOwned }
            if let captureOwner {
                return .refused(
                    reason:
                        "\(displayName(captureOwner)) still owns the microphone. Speech did not start."
                )
            }
            speechIsActive = true
            return .acquired
        }
    }

    func endSpeech() -> AudioSessionDecision {
        lock.withLock {
            guard speechIsActive else {
                return .refused(
                    reason:
                        "Speech was not active, so no audio session was changed."
                )
            }
            speechIsActive = false
            return .released
        }
    }

    func reset() {
        lock.withLock {
            captureOwner = nil
            speechIsActive = false
            meetingNotesAreSuspended = false
        }
    }

    private func displayName(_ owner: AudioCaptureOwner) -> String {
        switch owner {
        case .pushToTalk: return "Push to Talk"
        case .stealthExitOnly: return "Private Mode Exit"
        case .partner: return "Partner Mode"
        case .meetingNotes: return "Meeting Notes"
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
