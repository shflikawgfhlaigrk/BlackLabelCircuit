#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation

nonisolated final class FloatingInboxCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var wire: GmailNetworkWire?

    func register(_ wire: GmailNetworkWire) throws {
        lock.lock()
        if cancelled { lock.unlock(); wire.cancel(); throw CancellationError() }
        self.wire = wire
        lock.unlock()
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let activeWire = wire
        wire = nil
        lock.unlock()
        activeWire?.cancel()
    }
}

nonisolated enum FloatingInboxGmail {
    static func snapshot(session: any GmailIMAPCommands, account: String) throws -> FloatingInboxSnapshot {
        let validity = try selectInbox(session, writable: false)
        let search = try session.command("UID SEARCH UNSEEN")
        let lines = search.lines.filter { $0 == "* SEARCH" || $0.hasPrefix("* SEARCH ") }
        guard lines.count == 1 else { throw GmailBackendError.malformedResponse }
        let tokens = lines[0].split(separator: " ").dropFirst(2)
        let uids = tokens.compactMap { UInt64($0) }
        guard uids.count == tokens.count, Set(uids).count == uids.count,
              uids.allSatisfy({ $0 > 0 && $0 <= UInt32.max }) else { throw GmailBackendError.malformedResponse }
        var messages: [FloatingEmail] = []
        // Individual FETCH commands bind each literal pair to one exact UID.
        // A batch's separate lines/literals arrays cannot safely establish that.
        for uid in uids.sorted(by: >).prefix(20) {
            let response = try session.command("UID FETCH \(uid) (UID X-GM-MSGID FLAGS BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.4096>)")
            guard let metadata = response.lines.first(where: { $0.uppercased().contains(" FETCH ") }) else {
                continue // Removed between SEARCH and FETCH; the next poll reconciles count.
            }
            let fields = GmailIMAPSyntax.fieldsOutsideQuotes(metadata)
            guard response.lines.filter({ $0.uppercased().contains(" FETCH ") }).count == 1,
                  GmailIMAPSyntax.captures(#"\bUID ([0-9]+)\b"#, in: fields)?.first.flatMap(UInt64.init) == uid,
                  let messageID = GmailIMAPSyntax.captures(#"\bX-GM-MSGID ([0-9]+)\b"#, in: fields)?.first.flatMap(UInt64.init),
                  messageID > 0, response.literals.count == 2 else { throw GmailBackendError.malformedResponse }
            if fields.uppercased().contains("\\SEEN") { continue }
            let sections = try response.headerAndTextLiterals()
            let headers = FloatingInboxMailText.headers(sections.headers)
            let sender = FloatingInboxMailText.header(headers["from"] ?? "Unknown sender")
            let subject = FloatingInboxMailText.header(headers["subject"] ?? "(No subject)")
            messages.append(FloatingEmail(account: account, uidValidity: validity, uid: uid, gmailID: messageID,
                sender: sender.isEmpty ? "Unknown sender" : sender,
                subject: subject.isEmpty ? "(No subject)" : subject,
                preview: FloatingInboxMailText.preview(headers: headers, body: sections.text),
                date: FloatingInboxMailText.header(headers["date"] ?? "")))
        }
        return FloatingInboxSnapshot(messages: messages, unreadCount: uids.count)
    }

    static func markRead(_ email: FloatingEmail, session: any GmailIMAPCommands) throws {
        guard try selectInbox(session, writable: true) == email.uidValidity else { throw GmailBackendError.mailboxChanged }
        let before = try identity(email, session: session)
        if before { return }
        do {
            _ = try session.command("UID STORE \(email.uid) +FLAGS.SILENT (\\Seen)")
            guard try identity(email, session: session) else { throw GmailBackendError.unconfirmedMutation }
        } catch { throw GmailBackendError.unconfirmedMutation }
    }

    private static func selectInbox(_ session: any GmailIMAPCommands, writable: Bool) throws -> UInt64 {
        let response = try session.command((writable ? "SELECT" : "EXAMINE") + " \"INBOX\"")
        let validities = response.lines.compactMap {
            GmailIMAPSyntax.captures(#"\[UIDVALIDITY ([0-9]+)\]"#, in: $0)?.first.flatMap(UInt64.init)
        }
        guard validities.count == 1, let validity = validities.first, validity > 0 else { throw GmailBackendError.malformedResponse }
        return validity
    }

    private static func identity(_ email: FloatingEmail, session: any GmailIMAPCommands) throws -> Bool {
        let response = try session.command("UID FETCH \(email.uid) (UID X-GM-MSGID FLAGS)")
        let records = response.lines.filter { $0.uppercased().contains(" FETCH ") }
        guard records.count == 1, let record = records.first else { throw GmailBackendError.mailboxChanged }
        let fields = GmailIMAPSyntax.fieldsOutsideQuotes(record)
        guard GmailIMAPSyntax.captures(#"\bUID ([0-9]+)\b"#, in: fields)?.first.flatMap(UInt64.init) == email.uid,
              GmailIMAPSyntax.captures(#"\bX-GM-MSGID ([0-9]+)\b"#, in: fields)?.first.flatMap(UInt64.init) == email.gmailID,
              let flags = GmailIMAPSyntax.captures(#"\bFLAGS \(([^)]*)\)"#, in: fields)?.first else { throw GmailBackendError.mailboxChanged }
        return flags.split(separator: " ").contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame }
    }

    static func connect(address: String, password: String, usesOAuth: Bool = false, cancellation: FloatingInboxCancellation) throws -> GmailIMAPSession {
        try cancellation.check()
        let wire = try GmailNetworkWire()
        try cancellation.register(wire)
        return try GmailIMAPSession(wire: wire, address: address, password: password, usesOAuth: usesOAuth, beforeCommand: cancellation.check)
    }
}
#endif // circuit-convert
