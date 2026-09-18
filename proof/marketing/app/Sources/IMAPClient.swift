// Black Label Marketing (lead engine, merged from Black Label Leads) — real IMAP reply-detection client (in-house, no paid services, no SDK).
//
// Read-ONLY poll of the buyer's OWN mailbox over implicit TLS (port 993) using Network.framework,
// mirroring the SMTP send path. It LOGINs, SELECTs INBOX, SEARCHes for recent mail, FETCHes the
// envelope (From / Subject / Date) of each, and returns `InboxMessage` records for the CRM to fold
// in (see Inbox.swift). It never deletes, moves, or marks mail — purely observational.
//
// The wire-protocol PARSING is pure and unit-tested (`parseEnvelopeLine`, `parseSearchResult`,
// `decodeMIMEHeader`); the network transport talks to the buyer's real server.
import Foundation

// MARK: - config for the buyer's mailbox (host/port/user from Settings; password from Keychain)
struct IMAPConfig {
    var host: String
    var port: UInt16 = 993
    var username: String
    var password: String
    var isConfigured: Bool { !host.isEmpty && !username.isEmpty && !password.isEmpty }
}

enum IMAPError: LocalizedError {
    case notConfigured, connection(String), authFailed(String), badResponse(String), timeout
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Reply detection isn't configured. Add your IMAP details in Connectors → Inbox."
        case .connection(let m): return "Couldn't reach your IMAP server: \(m)"
        case .authFailed(let m): return "IMAP login failed (check the app password): \(m)"
        case .badResponse(let m): return "Your IMAP server returned an unexpected response: \(m)"
        case .timeout: return "The IMAP server timed out."
        }
    }
}

// MARK: - pure IMAP response parsing (unit-tested; no network)
enum IMAPParse {
    /// Split a string into lines on the bare LF *scalar*. In Swift "\r\n" is a SINGLE Character
    /// (grapheme cluster), so a Character-level split never breaks on CRLF — the universal IMAP/SMTP
    /// terminator. Scanning unicode scalars splits correctly; each line is then trimmed of CR/space.
    static func lines(_ s: String) -> [String] {
        s.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Parse the result of `SEARCH` — a line like "* SEARCH 12 47 48 91" → [12,47,48,91].
    static func parseSearchResult(_ response: String) -> [Int] {
        for t in lines(response) {
            guard t.uppercased().hasPrefix("* SEARCH") else { continue }
            return t.dropFirst("* SEARCH".count).split(separator: " ").compactMap { Int($0) }
        }
        return []
    }

    /// Decode an RFC 2047 encoded-word header value ("=?UTF-8?B?...?=" or "=?UTF-8?Q?...?=").
    /// Falls back to the raw string if it isn't encoded or can't be decoded. Handles multiple words.
    static func decodeMIMEHeader(_ raw: String) -> String {
        guard raw.contains("=?") else { return raw }
        var result = ""
        var rest = Substring(raw)
        while let start = rest.range(of: "=?") {
            result += rest[rest.startIndex..<start.lowerBound]
            let after = rest[start.upperBound...]
            // charset?enc?text?=
            guard let cs = after.range(of: "?"), // end of charset
                  let encEnd = after[cs.upperBound...].range(of: "?"),
                  let close = after[encEnd.upperBound...].range(of: "?=")
            else { result += "=?"; rest = after; continue }
            let enc = after[cs.upperBound..<encEnd.lowerBound].uppercased()
            let text = String(after[encEnd.upperBound..<close.lowerBound])
            var decoded = text
            if enc == "B" {
                if let d = Data(base64Encoded: text), let s = String(data: d, encoding: .utf8) { decoded = s }
            } else if enc == "Q" {
                decoded = decodeQ(text)
            }
            result += decoded
            rest = after[close.upperBound...]
            // RFC 2047: whitespace between adjacent encoded-words is ignored.
            while rest.first == " " || rest.first == "\t" {
                let peek = rest.drop { $0 == " " || $0 == "\t" }
                if peek.hasPrefix("=?") { rest = peek } else { break }
            }
        }
        result += rest
        return result.isEmpty ? raw : result
    }

    /// Decode RFC 2047 "Q" (quoted-printable-ish) encoding for a header word.
    private static func decodeQ(_ s: String) -> String {
        var bytes = [UInt8]()
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "_" { bytes.append(0x20); i += 1 }
            else if c == "=" && i + 2 < chars.count, let b = UInt8(String(chars[i+1...i+2]), radix: 16) {
                bytes.append(b); i += 3
            } else { bytes.append(contentsOf: Array(String(c).utf8)); i += 1 }
        }
        return String(bytes: bytes, encoding: .utf8) ?? s
    }

    /// Parse the header block returned by `FETCH (BODY[HEADER.FIELDS (FROM SUBJECT DATE)])` into an
    /// InboxMessage envelope. `uid` makes the stable id. Header folding (continuation lines starting
    /// with whitespace) is unfolded first. Deterministic; classification is applied by the caller.
    static func parseEnvelope(uid: Int, headerBlock: String) -> InboxMessage {
        var from = "", subject = "", dateStr = ""
        for l in unfoldHeaders(headerBlock) {
            let lower = l.lowercased()
            if lower.hasPrefix("from:") { from = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            else if lower.hasPrefix("subject:") { subject = String(l.dropFirst(8)).trimmingCharacters(in: .whitespaces) }
            else if lower.hasPrefix("date:") { dateStr = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        }
        let (name, email) = InboxClassifier.parseAddress(decodeMIMEHeader(from))
        let subj = decodeMIMEHeader(subject)
        let date = parseDate(dateStr) ?? Date()
        return InboxMessage(id: "INBOX:\(uid)", fromEmail: email, fromName: name,
                            subject: subj, date: date)
    }

    /// Unfold RFC 5322 folded headers into one entry per logical header (a line beginning with SP/TAB
    /// continues the previous one). Scalar-split on LF so CRLF endings break correctly (see `lines`).
    static func unfoldHeaders(_ block: String) -> [String] {
        var out: [String] = []
        for rawLine in block.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(String.UnicodeScalarView(rawLine)).replacingOccurrences(of: "\r", with: "")
            if (line.first == " " || line.first == "\t"), !out.isEmpty {
                out[out.count - 1] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if !line.isEmpty { out.append(line) }
        }
        return out
    }

    /// Parse an RFC 5322 Date header. Tolerant of the common variants servers emit.
    static func parseDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let cleaned = s.replacingOccurrences(of: "  ", with: " ")
        let fmts = ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z",
                    "EEE, dd MMM yyyy HH:mm:ss", "EEE, d MMM yyyy HH:mm:ss Z"]
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        for f in fmts { df.dateFormat = f; if let d = df.date(from: cleaned) { return d } }
        return nil
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - the network client (real IMAP over implicit TLS; read-only)
struct IMAPClient {
    let config: IMAPConfig
    /// How many of the most-recent messages to inspect each poll (keeps it light + fast).
    var fetchLimit: Int = 40
    /// Only consider mail newer than this many days (SEARCH SINCE) — recent replies are what matter.
    var sinceDays: Int = 30

    /// Connect, authenticate, and fetch recent envelopes. Returns parsed (unclassified) messages.
    /// The caller (AppModel.ingestInbox) classifies + folds them into prospect state.
    func fetchRecent() async throws -> [InboxMessage] {
        guard config.isConfigured else { throw IMAPError.notConfigured }
        let conn = try IMAPConnection(host: config.host, port: config.port)
        try await conn.open()
        defer { conn.close() }
        _ = try await conn.readUntaggedGreeting()                 // "* OK ..."

        // LOGIN (quote the args; servers accept quoted literals for AUTH=PLAIN-class logins).
        let loginTag = "a1"
        let login = "\(loginTag) LOGIN \(IMAPConnection.quote(config.username)) \(IMAPConnection.quote(config.password))"
        let loginResp = try await conn.send(tag: loginTag, command: login)
        guard loginResp.uppercased().contains("\(loginTag) OK".uppercased()) else {
            throw IMAPError.authFailed(IMAPConnection.firstLine(loginResp))
        }

        // SELECT INBOX (read-only via EXAMINE so we never mark mail seen).
        let selTag = "a2"
        let sel = try await conn.send(tag: selTag, command: "\(selTag) EXAMINE INBOX")
        guard sel.uppercased().contains("\(selTag) OK".uppercased()) else {
            throw IMAPError.badResponse(IMAPConnection.firstLine(sel))
        }

        // SEARCH recent.
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "dd-MMM-yyyy"
        let since = Calendar.current.date(byAdding: .day, value: -sinceDays, to: Date()) ?? Date()
        let searchTag = "a3"
        let searchResp = try await conn.send(tag: searchTag, command: "\(searchTag) SEARCH SINCE \(df.string(from: since))")
        var uids = IMAPParse.parseSearchResult(searchResp)
        guard !uids.isEmpty else { return [] }
        if uids.count > fetchLimit { uids = Array(uids.suffix(fetchLimit)) }   // most recent N

        // FETCH each message's envelope headers. (Sequential keeps the single connection in lockstep.)
        var out: [InboxMessage] = []
        for (i, seq) in uids.enumerated() {
            let tag = "f\(i)"
            let cmd = "\(tag) FETCH \(seq) (BODY.PEEK[HEADER.FIELDS (FROM SUBJECT DATE)])"
            guard let resp = try? await conn.send(tag: tag, command: cmd) else { continue }
            let header = IMAPConnection.extractLiteral(from: resp)
            guard !header.isEmpty else { continue }
            out.append(IMAPParse.parseEnvelope(uid: seq, headerBlock: header))
        }
        _ = try? await conn.send(tag: "z", command: "z LOGOUT")
        return out
    }

    /// Lightweight connectivity + auth check for the Settings "Test" button. Returns a human message.
    func test() async -> (ok: Bool, message: String) {
        guard config.isConfigured else { return (false, "Add host, username, and app password first.") }
        do {
            let conn = try IMAPConnection(host: config.host, port: config.port)
            try await conn.open(); defer { conn.close() }
            _ = try await conn.readUntaggedGreeting()
            let r = try await conn.send(tag: "t1", command: "t1 LOGIN \(IMAPConnection.quote(config.username)) \(IMAPConnection.quote(config.password))")
            _ = try? await conn.send(tag: "t2", command: "t2 LOGOUT")
            if r.uppercased().contains("T1 OK") { return (true, "Connected and signed in to \(config.host).") }
            return (false, "Login rejected: \(IMAPConnection.firstLine(r))")
        } catch let e as IMAPError { return (false, e.errorDescription ?? "Failed.") }
        catch { return (false, error.localizedDescription) }
    }
}
#endif // circuit-convert

/// Ensures a continuation resumes EXACTLY once across the receive callback + the timeout timer
/// (resuming a CheckedContinuation twice traps). `fire()` returns true only for the first caller.
final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - low-level IMAP connection (Network.framework, async/await, tagged-response aware)
// The socket itself is NOT owned here: `ConsentedEgress.openStream` hands back a RawEgressStream
// on the declared `buyerMailServer` lane, so every line of IMAP protocol logic below stays put
// while this file owns no transport of its own. See Sources/ConsentedEgress.swift.
final class IMAPConnection {
    private let stream: RawEgressStream
    init(host: String, port: UInt16) throws {
        do {
            stream = try ConsentedEgress.openStream(host: host, port: port, tls: true,
                                                    lane: .buyerMailServer, label: "bll.imap")
        } catch let refusal as RawEgressError {
            throw IMAPError.connection(refusal.errorDescription ?? "The connection was refused.")
        }
    }
    /// DNS, TCP, or TLS negotiation can otherwise remain in `.preparing` forever. The choke point's
    /// stream matches the command/read ceiling, so every user-initiated connector check returns.
    func open() async throws {
        do { try await stream.open(timeout: 20) }
        catch { throw Self.imapError(error) }
    }
    func close() { stream.close() }

    /// Translate the choke point's stream failures into this client's own protocol errors, so the
    /// connector surface keeps saying exactly what it said before.
    static func imapError(_ error: Error) -> IMAPError {
        switch error as? RawEgressError {
        case .timeout: return .timeout
        case .closedByPeer: return .connection("server closed the connection")
        case .connection(let detail): return .connection(detail)
        case .registeredHost(_, _): return .connection(( error as? RawEgressError)?.errorDescription ?? "refused")
        case nil: return .connection(error.localizedDescription)
        }
    }

    /// Send a tagged command and read until the matching tagged completion line ("tag OK/NO/BAD").
    @discardableResult
    func send(tag: String, command: String) async throws -> String {
        try await write(command + "\r\n")
        return try await readUntilTagged(tag)
    }

    /// Read the server greeting (single untagged "* OK ..." line set, no tag to wait on).
    func readUntaggedGreeting() async throws -> String {
        // The greeting is the first chunk; read once.
        return try await recvChunk()
    }

    private func write(_ s: String) async throws {
        do { try await stream.write(Data(s.utf8)) }
        catch { throw Self.imapError(error) }
    }

    private var rxBuffer = ""
    /// Hard ceiling on how long one command may take to produce its tagged completion. Prevents a
    /// stalled or desynced server from hanging the async call forever.
    private let commandDeadline: TimeInterval = 20

    /// Accumulate until we see a line beginning with `tag ` (the tagged completion). Returns the
    /// whole accumulated response (untagged lines + the tagged line). Stashes any overflow.
    /// Throws `IMAPError.timeout` if the completion doesn't arrive within `commandDeadline`.
    private func readUntilTagged(_ tag: String) async throws -> String {
        let needle = tag + " "
        let deadline = Date().addingTimeInterval(commandDeadline)
        while true {
            // Is a complete tagged response already buffered?
            if let range = Self.taggedCompletionRange(in: rxBuffer, tag: needle) {
                let resp = String(rxBuffer[..<range.upperBound])
                rxBuffer = String(rxBuffer[range.upperBound...])
                return resp
            }
            if Date() >= deadline { throw IMAPError.timeout }
            rxBuffer += try await recvChunk(within: deadline.timeIntervalSinceNow)
        }
    }

    /// Find the end-index range of the first line that starts (at a line boundary) with `tag `.
    static func taggedCompletionRange(in buffer: String, tag: String) -> Range<String.Index>? {
        var searchStart = buffer.startIndex
        while let r = buffer.range(of: tag, range: searchStart..<buffer.endIndex) {
            let atLineStart = r.lowerBound == buffer.startIndex || buffer[buffer.index(before: r.lowerBound)] == "\n"
            if atLineStart {
                // Find end of this line.
                if let nl = buffer[r.upperBound...].firstIndex(of: "\n") {
                    return r.lowerBound..<buffer.index(after: nl)
                }
                return r.lowerBound..<buffer.endIndex
            }
            searchStart = r.upperBound
        }
        return nil
    }

    /// One read from the socket, bounded by `seconds` (a stalled server throws `.timeout` instead of
    /// hanging). `String(decoding:as:)` is used so a chunk that splits a UTF-8 sequence still decodes
    /// (the multi-byte boundary is healed once the rest arrives in the next chunk via the byte buffer).
    private func recvChunk(within seconds: TimeInterval = 20) async throws -> String {
        do { return String(decoding: try await stream.read(maximumLength: 65536, timeout: seconds), as: UTF8.self) }
        catch { throw Self.imapError(error) }
    }

    // MARK: - small helpers (pure)
    /// Quote a string for an IMAP atom argument (escape backslash + quote, wrap in dquotes).
    static func quote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
    static func firstLine(_ s: String) -> String {
        IMAPParse.lines(s).first(where: { !$0.isEmpty }) ?? s
    }
    /// Extract an IMAP literal payload ("{123}\r\n<123 OCTETS>") from a FETCH response.
    ///
    /// IMPORTANT: the IMAP `{N}` literal count is N OCTETS (bytes), not characters/scalars. A header
    /// with any UTF-8 multi-byte char (an é, an emoji, an RFC-2047 word…) has more bytes than scalars,
    /// so a scalar-based slice would cut the payload short and leave trailing bytes (incl. the tagged
    /// completion line) in the buffer, desyncing every later FETCH. We therefore slice the raw UTF-8
    /// bytes and decode. Works on the byte representation throughout.
    static func extractLiteral(from response: String) -> String {
        let bytes = Array(response.utf8)
        // Find "{", then the matching "}", parse the octet count between them.
        guard let open = bytes.firstIndex(of: UInt8(ascii: "{")) else { return "" }
        var i = open + 1
        var digits = [UInt8]()
        while i < bytes.count, bytes[i] >= UInt8(ascii: "0"), bytes[i] <= UInt8(ascii: "9") { digits.append(bytes[i]); i += 1 }
        guard i < bytes.count, bytes[i] == UInt8(ascii: "}"),
              let count = Int(String(decoding: digits, as: UTF8.self)), count > 0 else { return "" }
        // Payload begins after the CRLF (or bare LF) following "}".
        var p = i + 1
        if p < bytes.count, bytes[p] == UInt8(ascii: "\r") { p += 1 }
        if p < bytes.count, bytes[p] == UInt8(ascii: "\n") { p += 1 } else { return "" }
        let end = min(p + count, bytes.count)
        return String(decoding: bytes[p..<end], as: UTF8.self)
    }
}
#endif // circuit-convert
