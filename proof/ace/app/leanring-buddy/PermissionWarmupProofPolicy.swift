//
//  PermissionWarmupProofPolicy.swift
//  Ace
//
//  Pure, deterministic policy for the live Automation proof. The UI/process
//  runner lives in PermissionWarmup; this file makes it impossible for a stale
//  preference bit, a partial run, or a Mail account configuration issue to
//  masquerade as current Automation evidence.
//

import Foundation

enum PermissionAutomationTarget: String, CaseIterable, Hashable, Sendable {
    case systemEvents = "system events"
    case finder
    case notes
    case calendar
    case reminders
    case contacts
    case mail
    case messages
    case music

    var usesNativePermissionRequest: Bool {
        self == .reminders || self == .contacts
    }

    var ownerFacingName: String {
        switch self {
        case .systemEvents: return "System Events"
        case .finder: return "Finder"
        case .notes: return "Notes"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .contacts: return "Contacts"
        case .mail: return "Mail"
        case .messages: return "Messages"
        case .music: return "Music"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .systemEvents: return "com.apple.systemevents"
        case .finder: return "com.apple.finder"
        case .notes: return "com.apple.Notes"
        case .calendar: return "com.apple.iCal"
        case .reminders: return "com.apple.reminders"
        case .contacts: return "com.apple.AddressBook"
        case .mail: return "com.apple.mail"
        case .messages: return "com.apple.MobileSMS"
        case .music: return "com.apple.Music"
        }
    }

    /// Exact Apple-owned target. Revalidation never asks Launch Services to
    /// choose among apps that merely claim the same bundle identifier.
    var applicationPath: String {
        switch self {
        case .systemEvents:
            return "/System/Library/CoreServices/System Events.app"
        case .finder:
            return "/System/Library/CoreServices/Finder.app"
        case .notes:
            return "/System/Applications/Notes.app"
        case .calendar:
            return "/System/Applications/Calendar.app"
        case .reminders:
            return "/System/Applications/Reminders.app"
        case .contacts:
            return "/System/Applications/Contacts.app"
        case .mail:
            return "/System/Applications/Mail.app"
        case .messages:
            return "/System/Applications/Messages.app"
        case .music:
            return "/System/Applications/Music.app"
        }
    }
}

enum PermissionAutomationTargetStatus: Equatable, Sendable {
    case notRequested
    case checking
    case allowed
    case denied
    case targetCrashed
    case checkFailed
}

struct PermissionAutomationTargetPresentation: Equatable, Sendable {
    let isGranted: Bool
    let status: String
    let actionTitle: String
}

enum PermissionWarmupProgressPolicy {
    static func detail(
        isRunning: Bool,
        currentTarget: PermissionAutomationTarget?,
        completedTargetCount: Int,
        totalTargetCount: Int
    ) -> String {
        guard isRunning, let currentTarget else {
            return "Ace will request \(totalTargetCount) macOS prompts, one at a time. Click Allow on every prompt."
        }

        let position = min(
            max(completedTargetCount + 1, 1),
            max(totalTargetCount, 1)
        )
        return "Waiting for macOS: Click Allow for Ace → \(currentTarget.ownerFacingName) "
            + "(\(position) of \(totalTargetCount)). Prompts appear one at a time."
    }
}

struct PermissionAutomationEvidence: Equatable, Sendable {
    let target: PermissionAutomationTarget
    let automationAllowed: Bool
    /// `nil` for every non-Mail target and when Mail could not be queried.
    /// A known `false` never blocks the core Automation proof: configuring an
    /// email account is required only when the owner actually asks for email.
    let hasEnabledMailAccount: Bool?
    /// The probed app itself CRASHED answering (fresh crash report during the
    /// probe window). This distinguishes a target defect from a denial, but it
    /// is not functional proof and therefore can never make setup green.
    var targetCrashed: Bool = false
    var failure: PermissionAutomationFailure? = nil
}

struct PermissionAutomationFailure: Equatable, Sendable {
    let code: String
    let message: String
    let isPermissionDenied: Bool
}

enum PermissionWarmupProofPolicy {
    static let mailAutomationReadySentinel =
        "ACE_MAIL_AUTOMATION_READY"

    static func presentation(
        for status: PermissionAutomationTargetStatus
    ) -> PermissionAutomationTargetPresentation {
        switch status {
        case .notRequested:
            return PermissionAutomationTargetPresentation(
                isGranted: false,
                status: "Optional",
                actionTitle: "Connect"
            )
        case .checking:
            return PermissionAutomationTargetPresentation(
                isGranted: false,
                status: "Checking…",
                actionTitle: "Checking"
            )
        case .allowed:
            return PermissionAutomationTargetPresentation(
                isGranted: true,
                status: "Granted",
                actionTitle: "Recheck"
            )
        case .denied:
            return PermissionAutomationTargetPresentation(
                isGranted: false,
                status: "Blocked",
                actionTitle: "Repair"
            )
        case .targetCrashed:
            return PermissionAutomationTargetPresentation(
                isGranted: false,
                status: "Target unavailable",
                actionTitle: "Retry"
            )
        case .checkFailed:
            return PermissionAutomationTargetPresentation(
                isGranted: false,
                status: "Check failed",
                actionTitle: "Retry"
            )
        }
    }

    /// Tahoe does not reliably auto-launch Calendar or Contacts when the
    /// first command is a read. Explicitly launch every exact Apple bundle so
    /// a clean Mac reaches the consent prompt and then performs the same
    /// harmless proof read instead of returning application-not-running.
    static func warmupScript(
        for target: PermissionAutomationTarget
    ) -> String {
        let readCommand: String
        switch target {
        case .systemEvents:
            readCommand = "count processes"
        case .finder:
            readCommand = "get name of startup disk"
        case .notes:
            readCommand = "count notes"
        case .calendar:
            readCommand = "count calendars"
        case .reminders:
            readCommand = "get version"
        case .contacts:
            readCommand = "get version"
        case .mail:
            readCommand = """
                get version
                return "\(mailAutomationReadySentinel)"
                """
        case .messages:
            readCommand = "get version"
        case .music:
            readCommand = "get player state"
        }
        return """
            tell application "\(target.applicationPath)"
              launch
              \(readCommand)
            end tell
            """
    }

    static func noninteractiveEvidence(
        target: PermissionAutomationTarget,
        appleEventPermissionStatus: Int32?
    ) -> PermissionAutomationEvidence {
        PermissionAutomationEvidence(
            target: target,
            automationAllowed: appleEventPermissionStatus == 0,
            // AEDeterminePermissionToAutomateTarget proves TCC only. Account
            // readiness stays unknown and, by design, is not a setup gate.
            hasEnabledMailAccount: nil,
            failure: permissionFailure(status: appleEventPermissionStatus)
        )
    }

    static func permissionFailure(status: Int32?) -> PermissionAutomationFailure? {
        switch status {
        case 0:
            return nil
        case -1743:
            return PermissionAutomationFailure(
                code: "automation.denied.-1743",
                message: "Access is off. Enable this app under Ace in System Settings → Privacy & Security → Automation.",
                isPermissionDenied: true
            )
        case -1744:
            return PermissionAutomationFailure(
                code: "automation.consent_required.-1744",
                message: "macOS still requires permission. Choose Grant and respond to the system prompt.",
                isPermissionDenied: false
            )
        case -1712:
            return PermissionAutomationFailure(
                code: "automation.check_timed_out.-1712",
                message: "macOS did not finish its permission check. Respond to any open permission prompt, then retry. Other apps can still be used.",
                isPermissionDenied: false
            )
        case .some(let status):
            return PermissionAutomationFailure(
                code: "automation.check_failed.\(status)",
                message: "macOS could not verify access (error \(status)). Retry this app's check.",
                isPermissionDenied: false
            )
        case nil:
            return PermissionAutomationFailure(
                code: "automation.target_unavailable",
                message: "The app could not be reached. Open it once, then retry its check.",
                isPermissionDenied: false
            )
        }
    }

    static func scriptFailure(
        terminationStatus: Int32?, standardError: String
    ) -> PermissionAutomationFailure? {
        guard terminationStatus != 0 else { return nil }
        let expression = try? NSRegularExpression(pattern: #"\((-?\d+)\)\s*$"#)
        let range = NSRange(standardError.startIndex..., in: standardError)
        if let match = expression?.firstMatch(in: standardError, range: range),
           let codeRange = Range(match.range(at: 1), in: standardError),
           let code = Int32(standardError[codeRange]) {
            return permissionFailure(status: code)
        }
        return PermissionAutomationFailure(
            code: "automation.process_failed.\(terminationStatus.map(String.init) ?? "unavailable")",
            message: "The app's check did not finish successfully. Retry this app's check.",
            isPermissionDenied: false
        )
    }

    static func evidence(
        target: PermissionAutomationTarget,
        terminationStatus: Int32?,
        standardOutput: String = "",
        standardError: String = ""
    ) -> PermissionAutomationEvidence {
        guard terminationStatus == 0 else {
            return PermissionAutomationEvidence(
                target: target,
                automationAllowed: false,
                hasEnabledMailAccount: nil,
                failure: standardError.isEmpty && terminationStatus == -1743
                    ? permissionFailure(status: -1743)
                    : scriptFailure(terminationStatus: terminationStatus, standardError: standardError)
            )
        }

        guard target == .mail else {
            return PermissionAutomationEvidence(
                target: target,
                automationAllowed: true,
                hasEnabledMailAccount: nil
            )
        }

        switch standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) {
        case mailAutomationReadySentinel:
            return PermissionAutomationEvidence(
                target: target,
                automationAllowed: true,
                // This is a TCC proof only. Mail account readiness is checked
                // when an email action actually needs an account.
                hasEnabledMailAccount: nil
            )
        default:
            // A zero exit with no known sentinel is not proof that the exact
            // Mail read ran. Treat a changed/broken script as denied.
            return PermissionAutomationEvidence(
                target: target,
                automationAllowed: false,
                hasEnabledMailAccount: nil
            )
        }
    }

    /// True only for one complete, duplicate-free set of successful evidence
    /// produced by the current in-memory run.
    /// A target that CRASHED during its own functional check cannot be required.
    ///
    /// Build 64 demanded evidence for all eight targets, and a crashed target is
    /// dropped from the evidence array — so a single third-party crash (Apple's
    /// Reminders is the common one) made the count permanently short, this
    /// returned false forever, the App Automation row could never go green, and
    /// "Continue" stayed locked for the rest of setup. A buyer was held hostage
    /// by someone else's crash with no way forward and no explanation. Ace still
    /// proves automation for every target it could actually reach; it just stops
    /// treating an unreachable one as a failure the owner can fix.
    static func completesCurrentRun(
        _ evidence: [PermissionAutomationEvidence],
        crashedTargets: Set<PermissionAutomationTarget> = []
    ) -> Bool {
        let requiredTargets = Set(PermissionAutomationTarget.allCases)
            .subtracting(crashedTargets)
        // If every target crashed there is nothing to prove from.
        guard !requiredTargets.isEmpty else { return false }
        let reachableEvidence = evidence.filter {
            requiredTargets.contains($0.target)
        }
        guard Set(reachableEvidence.map(\.target)) == requiredTargets else {
            return false
        }
        return reachableEvidence.allSatisfy { $0.automationAllowed }
    }

    /// Produces one explicit state for every optional target. Missing evidence
    /// remains `.notRequested`; a denial or target crash never rewrites any
    /// sibling target's state.
    static func statuses(
        from evidence: [PermissionAutomationEvidence]
    ) -> [PermissionAutomationTarget: PermissionAutomationTargetStatus] {
        var result = Dictionary(
            uniqueKeysWithValues: PermissionAutomationTarget.allCases.map {
                ($0, PermissionAutomationTargetStatus.notRequested)
            }
        )
        for item in evidence {
            result[item.target] = if item.targetCrashed {
                .targetCrashed
            } else if item.automationAllowed {
                .allowed
            } else if let failure = item.failure, !failure.isPermissionDenied {
                .checkFailed
            } else {
                .denied
            }
        }
        return result
    }
}
