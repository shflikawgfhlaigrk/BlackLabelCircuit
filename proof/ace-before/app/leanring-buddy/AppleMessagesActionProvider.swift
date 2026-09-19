//
//  AppleMessagesActionProvider.swift
//  Ace
//
//  Deterministic, local-only Messages readiness and recipient resolution.
//  It prepares values for AppActionBroker; it never sends a message itself.
//

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

struct AppleMessagesRequest: Equatable {
    let handle: String
    let body: String
}

enum AppleMessagesPlan: Equatable {
    case needsSignIn
    case waitingForConnection
    case needsRecipientDisambiguation([String])
    case ready(AppleMessagesRequest)
    case blocked(String)
}

struct AppleMessagesRecipient: Equatable, Sendable {
    let displayName: String
    let handle: String
}

enum AppleMessagesAccountState: Equatable, Sendable {
    case signedOut
    case temporarilyUnavailable
    case connected
}

struct AppleMessagesSnapshot: Equatable, Sendable {
    let accountState: AppleMessagesAccountState
    let recipients: [AppleMessagesRecipient]
    let automationIsAvailable: Bool

    init(
        accountState: AppleMessagesAccountState,
        recipients: [AppleMessagesRecipient],
        automationIsAvailable: Bool = true
    ) {
        self.accountState = accountState
        self.recipients = recipients
        self.automationIsAvailable = automationIsAvailable
    }
}

struct AppleMessagesIntent: Equatable {
    let recipient: String
    let body: String
}

enum AppleMessagesIntentPolicy {
    private static let vetoPattern =
        #"(?i)^\s*(?:don['’]?t|do\s+not|did\s+you|have\s+you|why|how|when|where|who|what)\b"#
    private static let patterns = [
        #"(?is)^\s*(?:please[\s,]+)?(?:can|could|would|will)\s+you\s+(?:please\s+)?(?:message|text)\s+(.+?)\s+(?:saying|that\s+says|with(?:\s+the)?\s+(?:message|text))\s+(.+?)\s*$"#,
        #"(?is)^\s*(?:please[\s,]+)?(?:message|text)\s+([^:\n]+?)\s*:\s*(.+?)\s*$"#,
        #"(?is)^\s*(?:please[\s,]+)?(?:message|text)\s+(.+?)\s+(?:saying|that\s+says|with(?:\s+the)?\s+(?:message|text))\s+(.+?)\s*$"#,
        #"(?is)^\s*(?:please[\s,]+)?send\s+(?:a\s+)?message\s+to\s+(.+?)\s+(?:saying|that\s+says|with(?:\s+the)?\s+(?:message|text))\s+(.+?)\s*$"#,
    ]

    static func parse(_ text: String) -> AppleMessagesIntent? {
        guard text.range(
            of: vetoPattern,
            options: .regularExpression
        ) == nil else { return nil }
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: text,
                    range: NSRange(text.startIndex..., in: text)
                  ),
                  let recipientRange = Range(
                    match.range(at: 1),
                    in: text
                  ),
                  let bodyRange = Range(match.range(at: 2), in: text) else {
                continue
            }
            let recipient = text[recipientRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let body = text[bodyRange]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !recipient.isEmpty, !body.isEmpty else { return nil }
            return AppleMessagesIntent(
                recipient: recipient,
                body: body
            )
        }
        return nil
    }
}

struct PendingAppleMessagesIntent: Equatable {
    static let lifetime: TimeInterval = 5 * 60

    let id: UUID
    let turnID: UUID
    let intent: AppleMessagesIntent
    let createdAt: Date

    func isCurrent(at date: Date) -> Bool {
        let age = date.timeIntervalSince(createdAt)
        return age >= 0 && age <= Self.lifetime
    }
}

final class PendingAppleMessagesIntentStore {
    private(set) var pendingIntent: PendingAppleMessagesIntent?

    @discardableResult
    func retain(
        id: UUID = UUID(),
        turnID: UUID,
        intent: AppleMessagesIntent,
        createdAt: Date = Date()
    ) -> PendingAppleMessagesIntent {
        cancel()
        let pending = PendingAppleMessagesIntent(
            id: id,
            turnID: turnID,
            intent: intent,
            createdAt: createdAt
        )
        pendingIntent = pending
        return pending
    }

    func current(now: Date = Date()) -> PendingAppleMessagesIntent? {
        guard let pendingIntent else { return nil }
        guard pendingIntent.isCurrent(at: now) else {
            cancel()
            return nil
        }
        return pendingIntent
    }

    func cancel() {
        pendingIntent = nil
    }

    deinit {
        cancel()
    }
}

final class AppleMessagesActionProvider {
    typealias SnapshotProvider = @Sendable () async -> AppleMessagesSnapshot

    static let signInDestination = URL(
        fileURLWithPath: "/System/Applications/Messages.app"
    )
    static let automationUnavailableReason =
        "Messages Automation is unavailable."

    private let snapshotProvider: SnapshotProvider

    init(
        snapshotProvider: @escaping SnapshotProvider = {
            await AppleMessagesActionProvider.liveSnapshot()
        }
    ) {
        self.snapshotProvider = snapshotProvider
    }

    func plan(recipient: String, body: String) async -> AppleMessagesPlan {
        let exactRecipient = recipient.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !exactRecipient.isEmpty,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.count <= 20_000 else {
            return .blocked("Messages needs one recipient and a nonblank body.")
        }

        let snapshot = await snapshotProvider()
        guard snapshot.automationIsAvailable else {
            return .blocked(Self.automationUnavailableReason)
        }
        switch snapshot.accountState {
        case .signedOut:
            return .needsSignIn
        case .temporarilyUnavailable:
            return .waitingForConnection
        case .connected:
            break
        }

        let recipients = Self.normalizedRecipients(snapshot.recipients)
        let handleMatches = recipients.filter {
            Self.handlesMatch($0.handle, exactRecipient)
        }
        if handleMatches.count == 1, let match = handleMatches.first {
            return .ready(
                AppleMessagesRequest(handle: match.handle, body: body)
            )
        }
        if handleMatches.count > 1 {
            return .needsRecipientDisambiguation(
                handleMatches.map(\.handle).sorted()
            )
        }

        let normalizedName = Self.normalizedName(exactRecipient)
        let nameMatches = recipients.filter {
            Self.normalizedName($0.displayName) == normalizedName
        }
        if nameMatches.count == 1, let match = nameMatches.first {
            return .ready(
                AppleMessagesRequest(handle: match.handle, body: body)
            )
        }
        if nameMatches.count > 1 {
            return .needsRecipientDisambiguation(
                nameMatches.map(\.handle).sorted()
            )
        }
        return .blocked("Messages could not resolve one exact recipient.")
    }

    private static func normalizedRecipients(
        _ recipients: [AppleMessagesRecipient]
    ) -> [AppleMessagesRecipient] {
        var seen: Set<String> = []
        return recipients.compactMap { recipient in
            let handle = recipient.handle.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !handle.isEmpty, handle.count <= 512 else { return nil }
            let identity = canonicalHandle(handle)
            guard !identity.isEmpty, seen.insert(identity).inserted else {
                return nil
            }
            return AppleMessagesRecipient(
                displayName: recipient.displayName.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
                handle: handle
            )
        }
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func handlesMatch(_ lhs: String, _ rhs: String) -> Bool {
        canonicalHandle(lhs) == canonicalHandle(rhs)
    }

    private static func canonicalHandle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            return trimmed.lowercased()
        }
        let digits = trimmed.filter(\.isNumber)
        let phonePunctuation = CharacterSet(
            charactersIn: "+-() ."
        )
        let isPhoneShape = trimmed.unicodeScalars.allSatisfy {
            CharacterSet.decimalDigits.contains($0)
                || phonePunctuation.contains($0)
        }
        return isPhoneShape && !digits.isEmpty
            ? digits : trimmed.lowercased()
    }

    private static func liveSnapshot() async -> AppleMessagesSnapshot {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.snapshotScript]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return unavailableSnapshot
        }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline, !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                break
            }
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(0.25)
            while process.isRunning, Date() < terminationDeadline {
                Darwin.usleep(10_000)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !Task.isCancelled,
              process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            return unavailableSnapshot
        }
        return decodeSnapshot(String(decoding: data, as: UTF8.self))
    }

    private static var unavailableSnapshot: AppleMessagesSnapshot {
        AppleMessagesSnapshot(
            accountState: .signedOut,
            recipients: [],
            automationIsAvailable: false
        )
    }

    private static func decodeSnapshot(_ output: String) -> AppleMessagesSnapshot {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first == "READY" else {
            return AppleMessagesSnapshot(
                accountState: lines.first == "DISCONNECTED"
                    ? .temporarilyUnavailable : .signedOut,
                recipients: []
            )
        }
        let separator = Character(String(UnicodeScalar(31)!))
        let recipients: [AppleMessagesRecipient] = lines.dropFirst().compactMap { line in
            let fields = line.split(
                separator: separator,
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard fields.count == 2, !fields[0].isEmpty else {
                return nil
            }
            return AppleMessagesRecipient(
                displayName: String(fields[1]),
                handle: String(fields[0])
            )
        }
        return AppleMessagesSnapshot(
            accountState: .connected,
            recipients: recipients
        )
    }

    private static let snapshotScript = #"""
        on cleanField(sourceText)
          set cleaned to sourceText as text
          set AppleScript's text item delimiters to {return, linefeed, tab, character id 31}
          set pieces to text items of cleaned
          set AppleScript's text item delimiters to " "
          set cleaned to pieces as text
          set AppleScript's text item delimiters to ""
          return cleaned
        end cleanField

        tell application "/System/Applications/Messages.app"
          set configuredAccounts to every account whose enabled is true and service type is iMessage
          if (count of configuredAccounts) is 0 then return "SIGNED_OUT"
          set activeAccounts to every account whose enabled is true and service type is iMessage and connection status is connected
          if (count of activeAccounts) is 0 then return "DISCONNECTED"
          set outputText to "READY"
          set emittedCount to 0
          repeat with activeAccount in activeAccounts
            repeat with candidate in every participant of activeAccount
              if emittedCount is greater than or equal to 100 then exit repeat
              try
                set candidateHandle to my cleanField(handle of candidate)
                set candidateName to ""
                try
                  set candidateName to my cleanField(full name of candidate)
                end try
                if candidateName is "" then
                  try
                    set candidateName to my cleanField(name of candidate)
                  end try
                end if
                if candidateHandle is not "" then
                  set outputText to outputText & linefeed & candidateHandle & (character id 31) & candidateName
                  set emittedCount to emittedCount + 1
                end if
              end try
            end repeat
            if emittedCount is greater than or equal to 100 then exit repeat
          end repeat
          return outputText
        end tell
        """#
}
