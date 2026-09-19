import Foundation

nonisolated enum GmailInboxRead {
    static func read(session: any GmailIMAPCommands, account: String, count: Int, unreadOnly: Bool, window: EmailReadWindow? = nil) throws -> String {
        let selection = try session.command("EXAMINE \"INBOX\"")
        let validities = selection.lines.compactMap {
            GmailIMAPSyntax.captures(#"\[UIDVALIDITY ([0-9]+)\]"#, in: $0)?.first.flatMap(UInt64.init)
        }
        guard validities.count == 1, validities[0] > 0 else { throw GmailBackendError.malformedResponse }
        let criteria = (unreadOnly ? "UNSEEN" : "ALL") + (window.map { " " + $0.imapCriteria } ?? "")
        let search = try session.command("UID SEARCH " + criteria)
        let lines = search.lines.filter { $0 == "* SEARCH" || $0.hasPrefix("* SEARCH ") }
        guard lines.count == 1 else { throw GmailBackendError.malformedResponse }
        let tokens = lines[0].split(separator: " ").dropFirst(2)
        let uids = tokens.compactMap { UInt64($0) }
        guard uids.count == tokens.count, Set(uids).count == uids.count,
              uids.allSatisfy({ $0 > 0 && $0 <= UInt32.max }) else { throw GmailBackendError.malformedResponse }
        let period = window.map { " " + $0.label } ?? ""
        if uids.isEmpty { return "No\(unreadOnly ? " unread" : "") email in \(account)'s Gmail inbox\(period)." }
        var messages: [String] = []
        for uid in uids.sorted(by: >).prefix(max(1, min(count, window == nil ? 20 : 100))) {
            let response = try session.command("UID FETCH \(uid) (UID BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.4096>)")
            guard let metadata = response.lines.first(where: { $0.uppercased().contains(" FETCH ") }),
                  response.lines.filter({ $0.uppercased().contains(" FETCH ") }).count == 1,
                  GmailIMAPSyntax.captures(#"\bUID ([0-9]+)\b"#, in: GmailIMAPSyntax.fieldsOutsideQuotes(metadata))?.first.flatMap(UInt64.init) == uid,
                  response.literals.count == 2 else { throw GmailBackendError.mailboxChanged }
            let sections = try response.headerAndTextLiterals()
            let fields = FloatingInboxMailText.headers(sections.headers)
            let sender = FloatingInboxMailText.header(fields["from"] ?? "Unknown sender")
            let subject = FloatingInboxMailText.header(fields["subject"] ?? "(No subject)")
            let date = FloatingInboxMailText.header(fields["date"] ?? "Date unavailable")
            let preview = FloatingInboxMailText.preview(headers: fields, body: sections.text)
            messages.append("\(messages.count + 1). \(date)\nFrom: \(sender)\nSubject: \(subject)\n\(preview)")
        }
        return "Newest \(messages.count) of \(uids.count)\(unreadOnly ? " unread" : "") messages in \(account)'s Gmail inbox\(period):\n\n" + messages.joined(separator: "\n\n")
    }
}
