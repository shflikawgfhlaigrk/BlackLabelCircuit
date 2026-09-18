//
//  AppleMailAccountProvider.swift
//  Ace
//
//  Local Apple Mail account discovery. This asks Mail only for enabled sender
//  addresses; it never reads messages, contacts Google, or stores credentials.
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

/// A fully bound owner-authored Mail request can bypass model planning and go
/// straight to AppActionBroker's exact, visible `email-draft` wrapper. Partial
/// requests intentionally do not parse: Gold still authors or clarifies those.
struct ExactAppleMailDraftRequest: Equatable, Sendable {
    let sender: String
    let recipient: String
    let subject: String
    let body: String

    static func explicitlyRequestsSending(_ request: String) -> Bool {
        request.range(of: #"(?i)^\s*(?:please\s+)?send\s+(?:an?\s+)?email\b"#,
                      options: .regularExpression) != nil
    }

    static func parse(_ request: String) -> Self? {
        guard let expression = try? NSRegularExpression(
            pattern:
                #"(?is)^\s*(?:please\s+)?(?:send|draft|compose|prepare|write|create)\s+(?:an?\s+)?email\s+from\s+([A-Z0-9._%+\-]+@[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)+)\s+to\s+([A-Z0-9._%+\-]+@[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)+)\s+(?:with\s+)?(?:the\s+)?subject(?:\s+(?:of|line))?\s*[:\-]?\s*(.+?)\s+and\s+(?:the\s+)?body\s*[:\-]?\s*(.+?)\s*$"#
        ), let match = expression.firstMatch(
            in: request,
            range: NSRange(request.startIndex..., in: request)
        ), let senderRange = Range(match.range(at: 1), in: request),
           let recipientRange = Range(match.range(at: 2), in: request),
           let subjectRange = Range(match.range(at: 3), in: request),
           let bodyRange = Range(match.range(at: 4), in: request) else {
            return nil
        }
        let subject = unquotedField(String(request[subjectRange]))
        let body = unquotedField(String(request[bodyRange]))
        guard !subject.isEmpty, !body.isEmpty else { return nil }
        return Self(
            sender: String(request[senderRange]).lowercased(),
            recipient: String(request[recipientRange]).lowercased(),
            subject: subject,
            body: body
        )
    }

    private static func unquotedField(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"")
                || (first == "'" && last == "'") else {
            return value
        }
        return String(value.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Private authoring results stay in memory and can only prepare a draft.
/// Sender authority comes from the account binding, never from the model.
struct PrivateMailDraftPlanningResponse: Decodable {
    enum Kind: String, Decodable { case draft, clarify }
    enum Delivery: String, Decodable { case draft, send }
    enum ValidationError: Error { case invalidResponse }

    let kind: Kind
    let recipient: String?
    let subject: String?
    let body: String?
    let question: String?
    let delivery: Delivery?

    static let clarificationText =
        "What missing recipient, subject, or message would you like to add? I'll keep the details you've already given me. Nothing was sent."

    static let systemPrompt = """
    Prepare the owner's requested email. Return only JSON with keys kind, delivery, recipient, subject, body, question. kind is "draft" or "clarify". delivery is "send" when the owner asks to send, email, reply, or forward a message; it is "draft" when the owner asks only to draft, compose, prepare, or leave it unsent. Use null for unused fields. Never claim anything was sent or created: Ace owns execution and displays the final message before a send. The app binds the sender separately. Never invent a recipient: the exact email address must occur in this request. Preserve explicitly quoted subject and body exactly. You may author wording when asked to write it. If recipient, subject, or body is missing or ambiguous, return kind "clarify" asking for the missing details. Otherwise return kind "draft" with delivery and the exact recipient, subject and body. No tools, file access, screenshots, or outside lookups are needed.
    """

    func clarification() throws -> String {
        guard kind == .clarify, let question,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.count <= 1_000 else { throw ValidationError.invalidResponse }
        // A planner's question may repeat private authoring input. Only this
        // content-free instruction may enter the ordinary spoken status path.
        return Self.clarificationText
    }

    func exactDraft(
        sender: String,
        ownerRequest: String
    ) throws -> ExactAppleMailDraftRequest {
        guard kind == .draft, let recipient, let subject, let body,
              let normalizedRecipient = AppleMailAccountPolicy
                .normalizedSenderAddresses([recipient]).first,
              normalizedRecipient == recipient.lowercased(),
              ownerRequest.range(
                of: #"(?i)(?<![A-Z0-9._%+\-])"#
                    + NSRegularExpression.escapedPattern(for: recipient)
                    + #"(?![A-Z0-9._%+\-])"#,
                options: .regularExpression
              ) != nil,
              !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              subject.count <= 998, !subject.contains("\n"), !subject.contains("\r"),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.count <= 200_000 else { throw ValidationError.invalidResponse }
        return ExactAppleMailDraftRequest(
            sender: sender, recipient: normalizedRecipient,
            subject: subject, body: body
        )
    }
}

enum AppleMailAccountPolicy {
    enum NextStep: Equatable, Sendable {
        case connectAppleMail
        case bindSender(String)
        case chooseSender([String])
    }

    static func nextStep(for rawAddresses: [String]) -> NextStep {
        let addresses = normalizedSenderAddresses(rawAddresses)
        switch addresses.count {
        case 0:
            return .connectAppleMail
        case 1:
            return .bindSender(addresses[0])
        default:
            return .chooseSender(addresses)
        }
    }

    /// An exact sender named by the owner is already the native identity
    /// choice. Bind it only when the same normalized address is enabled in
    /// Apple Mail; otherwise preserve the existing connect/choose flow.
    static func nextStep(
        for rawAddresses: [String],
        requestedBy exactRequest: String
    ) -> NextStep {
        let addresses = normalizedSenderAddresses(rawAddresses)
        if let requested = requestedSenderAddress(in: exactRequest),
           addresses.contains(requested) {
            return .bindSender(requested)
        }
        return nextStep(for: addresses)
    }

    static func requestedSenderAddress(in exactRequest: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern:
                #"(?i)\bfrom\s+([A-Z0-9._%+\-]+@[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)+)(?=\s+(?:to|with|and|subject|body)\b|[,.]|$)"#
        ), let match = expression.firstMatch(
            in: exactRequest,
            range: NSRange(exactRequest.startIndex..., in: exactRequest)
        ), let addressRange = Range(match.range(at: 1), in: exactRequest)
        else { return nil }
        return String(exactRequest[addressRange]).lowercased()
    }

    static func normalizedSenderAddresses(_ rawAddresses: [String]) -> [String] {
        var seen = Set<String>()
        return rawAddresses.compactMap { rawAddress in
            let trimmed = rawAddress
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Apple Mail returns the account "Email Address" field verbatim,
            // which commonly carries a display name ("Name <addr@host>").
            // Dropping those silently left a fully configured Mac with zero
            // senders — or auto-bound the one plainly-formatted account.
            // tools/email-draft extracts the bare address the same way.
            let bareCandidate: String
            if let open = trimmed.range(of: "<", options: .backwards),
               let close = trimmed.range(of: ">", options: .backwards),
               open.upperBound <= close.lowerBound {
                bareCandidate = String(
                    trimmed[open.upperBound..<close.lowerBound]
                )
            } else {
                bareCandidate = trimmed
            }
            let address = bareCandidate
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard address.range(
                of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9\-]+(?:\.[A-Za-z0-9\-]+)+$"#,
                options: .regularExpression
            ) != nil,
            seen.insert(address).inserted else {
                return nil
            }
            return address
        }
    }
}

enum AppleMailAccountSnapshot: Equatable, Sendable {
    case available([String])
    case unavailable
}

@MainActor
final class AppleMailAccountProvider {
    private static let enumerationScript = """
    tell application "/System/Applications/Mail.app"
      set readyAccounts to every account whose enabled is true
      set senderAddresses to {}
      repeat with readyAccount in readyAccounts
        set accountAddresses to get email addresses of readyAccount
        repeat with accountAddress in accountAddresses
          set end of senderAddresses to (get accountAddress) as text
        end repeat
      end repeat
      set AppleScript's text item delimiters to linefeed
      return senderAddresses as text
    end tell
    """

    /// Reads enabled Apple Mail account addresses on this Mac. The caller owns
    /// presentation and must treat `.unavailable` as no actionable identity.
    func enabledSenderAddresses() async -> AppleMailAccountSnapshot {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "AppleScript", "-e", Self.enumerationScript]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .unavailable
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
        guard !Task.isCancelled,
              process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            return .unavailable
        }
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        return .available(
            AppleMailAccountPolicy.normalizedSenderAddresses(
                text.components(separatedBy: .newlines)
            )
        )
    }
}
