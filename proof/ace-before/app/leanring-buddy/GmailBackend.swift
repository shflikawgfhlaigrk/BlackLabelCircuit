import Foundation

nonisolated enum GmailBackendError: Error, Equatable {
    case invalidRequest, transport, malformedResponse, refused, missingAccount, accountMismatch
    case mailboxChanged, unconfirmedMutation
}

nonisolated struct GmailBackendRequest: Codable {
    enum Operation: String, Codable { case account, mailboxes, search, fetch, createLabel, addLabel }
    let operation: Operation
    var account: String? = nil
    var mailbox: String? = nil
    var query: String? = nil
    var uidValidity: UInt64? = nil
    var uids: [UInt64]? = nil
    var label: String? = nil
    var afterUID: UInt64? = nil
    var limit: Int? = nil

    func validate() throws {
        for value in [account, mailbox, query, label].compactMap({ $0 }) {
            guard !value.isEmpty, value.utf8.count <= 2048,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { throw GmailBackendError.invalidRequest }
        }
        guard (1...200).contains(limit ?? 100),
              (uids ?? []).allSatisfy({ $0 > 0 && $0 <= UInt32.max }),
              (uids ?? []).count <= 50,
              Set(uids ?? []).count == (uids ?? []).count,
              (afterUID ?? 0) <= UInt32.max else { throw GmailBackendError.invalidRequest }
        if operation != .account && account == nil { throw GmailBackendError.invalidRequest }
        if [.search, .fetch, .addLabel].contains(operation), mailbox == nil {
            throw GmailBackendError.invalidRequest
        }
        if [.fetch, .addLabel].contains(operation),
           (uidValidity ?? 0) == 0 || (uids ?? []).isEmpty { throw GmailBackendError.invalidRequest }
        if [.createLabel, .addLabel].contains(operation) {
            guard let label, label.utf8.count <= 128,
                  label.unicodeScalars.allSatisfy({ $0.isASCII }),
                  !label.contains("*"), !label.contains("%"),
                  !label.hasPrefix("\\"), !label.hasPrefix("[Gmail]"),
                  label.caseInsensitiveCompare("INBOX") != .orderedSame
            else { throw GmailBackendError.invalidRequest }
        }
    }
}

nonisolated struct GmailIMAPResponse {
    var lines: [String] = []
    var literals: [Data] = []

    func headerAndTextLiterals() throws -> (headers: Data, text: Data) {
        // IMAP servers may return requested FETCH sections in either order.
        // Bind bytes to each response section instead of the request's order.
        let markers = lines.filter { GmailIMAPSyntax.captures(#"\{([0-9]+)\}$"#, in: $0) != nil }
        guard markers.count == 2, literals.count == 2 else { throw GmailBackendError.malformedResponse }
        var headers: Data?
        var text: Data?
        for (marker, literal) in zip(markers, literals) {
            guard let section = GmailIMAPSyntax.captures(
                #"\bBODY\[(HEADER(?:\.FIELDS \([^\]]*\))?|TEXT)\]((?:<[0-9]+>)?) \{([0-9]+)\}$"#,
                in: marker), section.count == 3,
                Int(section[2]) == literal.count else { throw GmailBackendError.malformedResponse }
            if section[0].uppercased() == "TEXT" {
                guard text == nil, section[1].isEmpty || section[1] == "<0>" else { throw GmailBackendError.malformedResponse }
                text = literal
            } else {
                guard headers == nil, section[1].isEmpty else { throw GmailBackendError.malformedResponse }
                headers = literal
            }
        }
        guard let headers, let text else { throw GmailBackendError.malformedResponse }
        return (headers, text)
    }
}

nonisolated protocol GmailIMAPCommands: AnyObject {
    func command(_ command: String) throws -> GmailIMAPResponse
}

nonisolated enum GmailIMAPSyntax {
    static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]) }
        }
    }

    static func fieldsOutsideQuotes(_ value: String) -> String {
        var result = "", quoted = false, escaped = false
        for c in value {
            if escaped { escaped = false; result.append(" "); continue }
            if quoted && c == "\\" { escaped = true; result.append(" "); continue }
            if c == "\"" { quoted.toggle(); result.append(" "); continue }
            result.append(quoted ? " " : c)
        }
        return result
    }

    static func labels(_ value: String) throws -> [String] {
        var result: [String] = [], current = ""
        var quoted = false, escaped = false, started = false
        for c in value {
            if escaped { current.append(c); escaped = false; continue }
            if quoted && c == "\\" { escaped = true; continue }
            if c == "\"" { quoted.toggle(); started = true; continue }
            if !quoted && c.isWhitespace {
                if started { result.append(current); current = ""; started = false }
            } else {
                if !quoted && (c == "(" || c == ")" || c == "{") { throw GmailBackendError.malformedResponse }
                current.append(c); started = true
            }
        }
        guard !quoted, !escaped else { throw GmailBackendError.malformedResponse }
        if started { result.append(current) }
        return result
    }

    static func fetchLabelList(_ line: String) throws -> [String] {
        guard let start = line.range(of: "X-GM-LABELS (", options: .caseInsensitive)
        else { throw GmailBackendError.malformedResponse }
        var quoted = false, escaped = false
        for index in line[start.upperBound...].indices {
            let c = line[index]
            if escaped { escaped = false; continue }
            if quoted && c == "\\" { escaped = true; continue }
            if c == "\"" { quoted.toggle(); continue }
            if !quoted && c == ")" { return try labels(String(line[start.upperBound..<index])) }
        }
        throw GmailBackendError.malformedResponse
    }
}

/// One authenticated, selected IMAP session owns each UID-based operation.
/// Label changes preserve messages, unread state, and every existing label.
nonisolated final class GmailBackend {
    private let session: any GmailIMAPCommands
    init(session: any GmailIMAPCommands) { self.session = session }

    func execute(_ request: GmailBackendRequest) throws -> [String: Any] {
        try request.validate()
        if request.operation == .mailboxes {
            let reply = try session.command("LIST \"\" \"*\"")
            return ["status": "observed", "mailboxes": reply.lines]
        }
        if request.operation == .createLabel {
            let label = request.label!
            let listed = try session.command("LIST \"\" " + GmailIMAPSyntax.quoted(label))
            if !listed.lines.contains(where: { $0.uppercased().hasPrefix("* LIST ") }) {
                _ = try session.command("CREATE " + GmailIMAPSyntax.quoted(label))
            }
            let verified = try session.command("LIST \"\" " + GmailIMAPSyntax.quoted(label))
            guard verified.lines.contains(where: { $0.uppercased().hasPrefix("* LIST ") })
            else { throw GmailBackendError.unconfirmedMutation }
            return ["status": "verified", "label": label]
        }
        guard let mailbox = request.mailbox else { throw GmailBackendError.invalidRequest }
        let selectionVerb = request.operation == .addLabel ? "SELECT " : "EXAMINE "
        let selection = try session.command(selectionVerb + GmailIMAPSyntax.quoted(mailbox))
        guard let validity = selection.lines.compactMap({ line in
            GmailIMAPSyntax.captures(#"\[UIDVALIDITY ([0-9]+)\]"#, in: line)?.first.flatMap(UInt64.init)
        }).first, validity > 0 else { throw GmailBackendError.malformedResponse }
        if let expected = request.uidValidity, expected != validity { throw GmailBackendError.mailboxChanged }
        if request.operation == .search {
            let query = request.query ?? "in:anywhere -in:trash -in:spam"
            let response = try session.command("UID SEARCH X-GM-RAW " + GmailIMAPSyntax.quoted(query))
            let searchLines = response.lines.filter { $0.uppercased() == "* SEARCH" || $0.uppercased().hasPrefix("* SEARCH ") }
            guard searchLines.count == 1 else { throw GmailBackendError.malformedResponse }
            let tokens = searchLines[0].split(separator: " ").dropFirst(2)
            let all = tokens.compactMap { UInt64($0) }
            guard all.count == tokens.count, all.allSatisfy({ $0 > 0 && $0 <= UInt32.max }),
                  Set(all).count == all.count else { throw GmailBackendError.malformedResponse }
            let remaining = all.sorted().filter { $0 > (request.afterUID ?? 0) }
            let page = Array(remaining.prefix(request.limit ?? 100))
            return ["status": "observed", "mailbox": mailbox, "uidValidity": validity,
                    "uids": page, "totalMatches": all.count, "hasMore": remaining.count > page.count,
                    "nextAfterUID": page.last ?? (request.afterUID ?? 0)]
        }
        let uids = request.uids!
        let uidSet = uids.map(String.init).joined(separator: ",")
        if request.operation == .fetch {
            let response = try session.command("UID FETCH " + uidSet + " (UID X-GM-MSGID X-GM-LABELS BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)] BODY.PEEK[TEXT]<0.4096>)")
            let returned = response.lines.compactMap {
                GmailIMAPSyntax.captures(#"\bUID ([0-9]+)\b"#, in: GmailIMAPSyntax.fieldsOutsideQuotes($0))?.first.flatMap(UInt64.init)
            }
            guard Set(returned) == Set(uids) else { throw GmailBackendError.mailboxChanged }
            return ["status": "observed", "mailbox": mailbox, "uidValidity": validity,
                    "responseLines": response.lines,
                    "contentLiterals": response.literals.map { String(decoding: $0, as: UTF8.self) },
                    "contentIsUntrusted": true, "bodyExcerptBytes": 4096]
        }
        guard request.operation == .addLabel else { throw GmailBackendError.invalidRequest }
        let label = request.label!
        let before = try fetchLabels(uidSet: uidSet)
        guard Set(before.keys) == Set(uids) else { throw GmailBackendError.mailboxChanged }
        // No automatic retry follows a mutation. An ambiguous result requires
        // a fresh read of the same UIDs and UIDVALIDITY before any next write.
        do {
            _ = try session.command("UID STORE " + uidSet + " +X-GM-LABELS.SILENT (" + GmailIMAPSyntax.quoted(label) + ")")
            let after = try fetchLabels(uidSet: uidSet)
            guard Set(after.keys) == Set(uids), uids.allSatisfy({ uid in
                let labels = Set(after[uid] ?? [])
                return labels.contains(label) && labels.isSuperset(of: before[uid] ?? [])
            }) else { throw GmailBackendError.unconfirmedMutation }
            return ["status": "verified", "mailbox": mailbox, "uidValidity": validity,
                    "label": label, "verifiedUIDs": uids, "verifiedCount": uids.count]
        } catch { throw GmailBackendError.unconfirmedMutation }
    }

    private func fetchLabels(uidSet: String) throws -> [UInt64: [String]] {
        let reply = try session.command("UID FETCH " + uidSet + " (UID X-GM-LABELS)")
        var result: [UInt64: [String]] = [:]
        for line in reply.lines where line.uppercased().contains(" FETCH ") {
            guard let uidText = GmailIMAPSyntax.captures(#"\bUID ([0-9]+)\b"#, in: GmailIMAPSyntax.fieldsOutsideQuotes(line))?.first,
                  let uid = UInt64(uidText), result[uid] == nil
            else { throw GmailBackendError.malformedResponse }
            result[uid] = try GmailIMAPSyntax.fetchLabelList(line)
        }
        return result
    }
}
