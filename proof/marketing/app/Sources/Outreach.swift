#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing (lead engine, merged from Black Label Leads) — real outreach send path + deliverability gate (in-house, no paid services).
//
//  * TemplateEngine   — renders the buyer's editable templates with token substitution.
//  * Deliverability   — syntax, role-address, MX (live DNS), and CAN-SPAM physical-address gate.
//                       A no-MX / role / bad-syntax / no-address recipient is NEVER sent to.
//  * SMTPClient       — sends through the buyer's OWN mailbox over real SMTP, AUTH LOGIN, on
//                       EITHER submission lane: 465 implicit TLS or 587 STARTTLS (in-place
//                       upgrade before any credential is written). No third-party SDK.
//
// All free, all on-device. Mirrors Utah's productized capability (enrich MX verify + queue gate).
import Foundation

// Brand isolation: buyer output must never carry the app-maker's brand. The sender identity
// in rendered mail comes from the buyer's own mailbox — display name first, then the
// from-address itself — never a Black Label string.
extension Mailbox {
    var resolvedSenderName: String {
        let name = fromName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let email = fromEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty { return email }
        return "The team"
    }
}

// MARK: - template rendering (token substitution over the buyer's editable templates)
enum TemplateEngine {
    /// Substitute {{first}} {{company}} {{type}} {{sender}} {{from_email}} {{address}} {{booking}} in a string.
    static func render(_ s: String, prospect p: Lead, mailbox: Mailbox, bookingLink: String = "") -> String {
        let first = p.name.split(separator: " ").first.map(String.init) ?? "there"
        let company = p.company.isEmpty ? "your team" : p.company
        let sender = mailbox.resolvedSenderName
        return s
            .replacingOccurrences(of: "{{first}}", with: first)
            .replacingOccurrences(of: "{{company}}", with: company)
            .replacingOccurrences(of: "{{type}}", with: p.type.label.lowercased())
            .replacingOccurrences(of: "{{sender}}", with: sender)
            .replacingOccurrences(of: "{{from_email}}", with: mailbox.fromEmail)
            .replacingOccurrences(of: "{{address}}", with: mailbox.physicalAddress)
            .replacingOccurrences(of: "{{booking}}", with: bookingLink)
    }

    /// Build the full body for a prospect from a template (or the type-aware default), with a
    /// CAN-SPAM footer (sender identity + physical address + opt-out) appended if not already present.
    static func body(for p: Lead, template t: OutreachTemplate?, mailbox: Mailbox, bookingLink: String = "") -> String {
        let raw = (t?.body.isEmpty ?? true) ? OutreachEngine.draftBody(for: p, senderName: mailbox.resolvedSenderName) : t!.body
        var rendered = render(raw, prospect: p, mailbox: mailbox, bookingLink: bookingLink)
        let lower = rendered.lowercased()
        if !lower.contains("opt out") && !lower.contains("unsubscribe") && !lower.contains("reply \"stop\"") {
            rendered += "\n\nIf you'd rather not hear from me, reply \"stop\" and I'll remove you."
        }
        let footerParts = [mailbox.fromName, mailbox.fromEmail, mailbox.physicalAddress]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        if !footerParts.isEmpty && !rendered.contains(mailbox.physicalAddress) {
            rendered += "\n\(footerParts)\nThis is a commercial message."
        }
        return rendered
    }

    static func subject(for p: Lead, template t: OutreachTemplate?, mailbox: Mailbox, bookingLink: String = "") -> String {
        let raw = (t?.subject.isEmpty ?? true) ? "Quick idea for {{company}}" : t!.subject
        return render(raw, prospect: p, mailbox: mailbox, bookingLink: bookingLink)
    }

    /// Render a body and sign it with the buyer's LOCKED brand kit (MK-16) — the kit's signature is
    /// read on EVERY compose, so a manually-composed touch carries the SAME brand identity the reel and
    /// the landing page do. The signature's {{sender}} token is filled from the buyer's own mailbox.
    static func bodySignedWithBrand(_ s: String, prospect p: Lead, mailbox: Mailbox,
                                    kit: BrandKit, bookingLink: String = "") -> String {
        let rendered = render(s, prospect: p, mailbox: mailbox, bookingLink: bookingLink)
        let sig = render(kit.emailSignature, prospect: p, mailbox: mailbox, bookingLink: bookingLink)
        if rendered.contains(kit.resolvedName) { return rendered }   // already brand-signed, don't double-sign
        return rendered + "\n\n" + sig
    }
}

// MARK: - deliverability gate (in-house: syntax, role, MX via live DNS, CAN-SPAM precondition)
struct DeliverabilityResult {
    var canSend: Bool
    var reasons: [String]          // why it was blocked (empty when canSend)
    var checks: [(label: String, ok: Bool)]
}

enum Deliverability {
    static let roleLocals: Set<String> = ["info", "sales", "admin", "support", "contact", "hello",
                                          "office", "billing", "help", "team", "marketing", "noreply",
                                          "no-reply", "postmaster", "webmaster", "enquiries", "inquiries"]

    /// HTML/JSON entity artifacts of an angle bracket that leak from a scraped "Name <addr>"
    /// string — literal `<`/`>`, escaped `>`, the surviving decoded `u003e`, or `&gt;`.
    /// A real address never contains these; catching them stops the `u003erecruitment@…`
    /// malformed-recipient bug at the send gate.
    static let addrPoison: [String] = ["<", ">", "\\u003e", "\\u003c", "u003e", "u003c",
                                       "&gt;", "&lt;", "&#62;", "&#60;"]

    /// RFC-5321-ish syntax check: one @, an anchored local part, a dotted domain, no spaces,
    /// and no angle-bracket poisoning artifacts.
    static func validSyntax(_ email: String) -> Bool {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty, e.count <= 254, !e.contains(" ") else { return false }
        let low = e.lowercased()
        for p in addrPoison where low.contains(p) { return false }
        guard e.filter({ $0 == "@" }).count == 1 else { return false }
        let parts = e.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = parts[0], domain = parts[1]
        // Anchor the local part to a real address char class (rejects a glued `u003e…` prefix
        // only via the poison list above; here we reject any other stray punctuation).
        let localOK = !local.isEmpty && local.allSatisfy {
            $0.isLetter || $0.isNumber || "._%+-".contains($0)
        }
        let domainOK = domain.allSatisfy { $0.isLetter || $0.isNumber || ".-".contains($0) }
        guard localOK, domainOK else { return false }
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    static func isRoleAddress(_ email: String) -> Bool {
        guard let local = email.split(separator: "@").first?.lowercased() else { return false }
        return roleLocals.contains(local)
    }

    static func domain(of email: String) -> String {
        String(email.split(separator: "@").last ?? "").lowercased()
    }

    /// Live MX lookup via the system resolver (in-house, no paid API). Returns true if the domain
    /// publishes at least one MX record (or, RFC-5321 fallback, an A record that accepts mail).
    static func domainAcceptsMail(_ domain: String) async -> Bool {
        guard !domain.isEmpty else { return false }
        // The resolver query is egress too, so it leaves through the choke point on the declared
        // `dnsRecordLookup` lane — this file owns no resolver of its own.
        if await ConsentedEgress.hasDNSRecord(domain, type: .mailExchange) { return true }
        // RFC 5321 implicit-MX fallback: a bare A record means the host itself accepts mail.
        return await ConsentedEgress.hasDNSRecord(domain, type: .address)
    }

    /// Full gate for one recipient. Combines all checks honoring the buyer's deliverability settings.
    static func gate(email: String, settings: LeadEngineSettings, allowRole: Bool = false) async -> DeliverabilityResult {
        var reasons: [String] = []
        var checks: [(String, Bool)] = []

        let syntaxOK = validSyntax(email)
        checks.append(("Valid email syntax", syntaxOK))
        if !syntaxOK { reasons.append("invalid email syntax") }

        let role = isRoleAddress(email)
        let roleOK = !(settings.blockRoleAddresses && role && !allowRole)
        checks.append(("Not a role address (info@, sales@…)", !role))
        if !roleOK { reasons.append("role address blocked by your settings") }

        var mxOK = true
        if settings.requireMX && syntaxOK {
            mxOK = await domainAcceptsMail(domain(of: email))
            checks.append(("Domain accepts mail (MX)", mxOK))
            if !mxOK { reasons.append("domain has no mail server (MX)") }
        }

        let addrOK = !settings.requirePhysicalAddress || !settings.mailbox.physicalAddress.isEmpty
        checks.append(("Your physical address set (CAN-SPAM)", addrOK))
        if !addrOK { reasons.append("set your physical mailing address in Settings (CAN-SPAM)") }

        let mailboxOK = settings.mailbox.isConfigured
        checks.append(("Sending mailbox configured", mailboxOK))
        if !mailboxOK { reasons.append("configure your sending mailbox in Connectors → Mailboxes") }

        // Anti-footgun HARD FLOOR: a disposable/burner recipient domain is never sendable, no matter
        // the buyer's toggles. The mailbox is throwaway and many such domains seed spam traps —
        // sending there only burns sender reputation. (Not toggleable, on purpose.)
        let disposable = syntaxOK && DisposableDomains.contains(domain(of: email))
        checks.append(("Not a disposable/burner domain", !disposable))
        if disposable { reasons.append("disposable/burner domain — throwaway mailbox / spam-trap risk") }

        let canSend = syntaxOK && roleOK && mxOK && addrOK && mailboxOK && !disposable
        return DeliverabilityResult(canSend: canSend, reasons: reasons, checks: checks)
    }

}

// MARK: - SMTP client (real send through the buyer's OWN mailbox; STARTTLS / implicit TLS, AUTH LOGIN)
enum SMTPError: LocalizedError {
    case notConfigured, connection(String), badGreeting(String), authFailed(String), rejected(String), timeout
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Your sending mailbox isn't configured. Add it in Connectors → Mailboxes."
        case .connection(let m): return "Couldn't reach your mail server: \(m)"
        case .badGreeting(let m): return "Mail server refused the connection: \(m)"
        case .authFailed(let m): return "Mailbox login failed (check the app password): \(m)"
        case .rejected(let m): return "The message was rejected: \(m)"
        case .timeout: return "The mail server timed out."
        }
    }
}

/// Builds an RFC-5322 message and delivers it over SMTP. Pure message building is unit-testable
/// (`buildMessage`); the network send (`send`) talks to the buyer's real server.
struct SMTPClient {
    let mailbox: Mailbox
    let password: String

    /// EHLO hostname derived from the buyer's own from-address domain. Relays commonly copy
    /// the EHLO name into the Received: headers recipients can read, so it must identify the
    /// buyer — never an app-maker hostname.
    var ehloHost: String {
        let domain = mailbox.fromEmail.split(separator: "@").last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return (domain.isEmpty || !domain.contains(".")) ? "localhost" : domain
    }

    /// Construct the raw RFC-5322 message (headers + body). Deterministic, unit-tested.
    /// `extraHeaders` (default empty → the outreach path is byte-unchanged) injects additional headers
    /// such as `List-Unsubscribe` / `List-Unsubscribe-Post` for a CAN-SPAM/RFC-8058-compliant
    /// newsletter send. Header names/values are sanitized (CR/LF stripped) so a value can't inject.
    static func buildMessage(from: String, fromName: String, to: String, subject: String, body: String,
                             extraHeaders: [(name: String, value: String)] = [], date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let fromHeader = fromName.isEmpty ? from : "\(encodeHeader(fromName)) <\(from)>"
        let msgID = "<\(UUID().uuidString)@\(from.split(separator: "@").last.map(String.init) ?? "localhost")>"
        // Normalize bare LF to CRLF and dot-stuff lines beginning with '.'
        let normalized = body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        let dotStuffed = normalized.split(separator: "\r\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(".") ? "." + $0 : String($0) }.joined(separator: "\r\n")
        func sanitize(_ s: String) -> String {
            s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
        }
        var lines = [
            "From: \(fromHeader)",
            "To: \(to)",
            "Subject: \(encodeHeader(subject))",
            "Date: \(df.string(from: date))",
            "Message-ID: \(msgID)"
        ]
        for h in extraHeaders {
            let n = sanitize(h.name).trimmingCharacters(in: .whitespaces)
            let v = sanitize(h.value).trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, !v.isEmpty else { continue }
            lines.append("\(n): \(v)")
        }
        lines.append(contentsOf: [
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
            "Content-Transfer-Encoding: 8bit",
            "",
            dotStuffed
        ])
        return lines.joined(separator: "\r\n")
    }

    /// RFC 2047 encode a header value if it contains non-ASCII; otherwise pass through.
    static func encodeHeader(_ s: String) -> String {
        if s.allSatisfy({ $0.isASCII }) { return s }
        let b64 = Data(s.utf8).base64EncodedString()
        return "=?UTF-8?B?\(b64)?="
    }

    /// Send to one recipient. Throws SMTPError on any failure (so the UI can show an honest reason).
    ///
    /// Transport: BOTH submission lanes, chosen by the port the buyer configured.
    ///   * 465 — IMPLICIT TLS: the connection is encrypted from the first byte, then EHLO → AUTH.
    ///   * 587 — STARTTLS: greet in the clear, EHLO, STARTTLS, upgrade the SAME socket to TLS,
    ///           EHLO again, then AUTH. Nothing secret crosses the wire before the upgrade, and
    ///           `SMTPConnection.startTLS` refuses to continue if the server does not offer it.
    /// 587 exists because plenty of mailbox providers publish ONLY 587 for submission; without it
    /// those buyers cannot send at all. Any other port is refused with an actionable message rather
    /// than a silently desynced session.
    func send(to recipient: String, subject: String, body: String,
              extraHeaders: [(name: String, value: String)] = []) async throws {
        guard mailbox.isConfigured, !password.isEmpty else { throw SMTPError.notConfigured }
        guard mailbox.usesSupportedSMTPPort else {
            throw SMTPError.connection(
                "port \(mailbox.port) isn't an SMTP submission port this app can use — set 465 (SSL) or " +
                "587 (STARTTLS) in Connectors → Mailboxes. Your provider publishes at least one of them.")
        }
        let message = Self.buildMessage(from: mailbox.fromEmail, fromName: mailbox.fromName,
                                        to: recipient, subject: subject, body: body, extraHeaders: extraHeaders)
        let conn = try SMTPConnection(host: mailbox.host, port: UInt16(mailbox.port),
                                      implicitTLS: mailbox.usesImplicitTLS)
        try await conn.open()
        defer { conn.close() }
        try await conn.expect(220)                                   // greeting
        if mailbox.usesImplicitTLS {
            try await conn.command("EHLO \(ehloHost)", expect: 250)  // already on TLS
        } else {
            try await conn.startTLS(ehloHost: ehloHost)              // EHLO → STARTTLS → TLS → EHLO
        }
        try await conn.command("AUTH LOGIN", expect: 334)
        try await conn.command(Data(mailbox.username.utf8).base64EncodedString(), expect: 334)
        do { try await conn.command(Data(password.utf8).base64EncodedString(), expect: 235) }
        catch { throw SMTPError.authFailed((error as? SMTPError)?.errorDescription ?? "auth rejected") }
        try await conn.command("MAIL FROM:<\(mailbox.fromEmail)>", expect: 250)
        try await conn.command("RCPT TO:<\(recipient)>", expect: 250)
        try await conn.command("DATA", expect: 354)
        try await conn.command(message + "\r\n.", expect: 250)
        _ = try? await conn.command("QUIT", expect: 221)
    }

    /// "Test connection": a REAL SMTP auth round-trip (greeting → EHLO → [STARTTLS] → AUTH LOGIN → QUIT) that
    /// proves the host/port/username/app-password actually log in — WITHOUT sending any mail (no
    /// MAIL/RCPT/DATA). Returns an honest pass/fail with the server's own reason. Used by the
    /// per-mailbox "Test connection" button in Connectors so a buyer can confirm a mailbox works
    /// before the first real send instead of discovering a bad password mid-campaign.
    func verify() async -> (ok: Bool, message: String) {
        guard mailbox.host.trimmingCharacters(in: .whitespaces).isEmpty == false,
              mailbox.username.trimmingCharacters(in: .whitespaces).isEmpty == false,
              !password.isEmpty else {
            return (false, "Add the host, username, and app password first.")
        }
        guard mailbox.usesSupportedSMTPPort else {
            return (false, "Set the SMTP port to 465 (SSL) or 587 (STARTTLS) — port \(mailbox.port) isn't a submission port this app can use.")
        }
        do {
            let conn = try SMTPConnection(host: mailbox.host, port: UInt16(mailbox.port),
                                          implicitTLS: mailbox.usesImplicitTLS)
            try await conn.open()
            defer { conn.close() }
            try await conn.expect(220)
            if mailbox.usesImplicitTLS {
                try await conn.command("EHLO \(ehloHost)", expect: 250)
            } else {
                try await conn.startTLS(ehloHost: ehloHost)
            }
            try await conn.command("AUTH LOGIN", expect: 334)
            try await conn.command(Data(mailbox.username.utf8).base64EncodedString(), expect: 334)
            do { try await conn.command(Data(password.utf8).base64EncodedString(), expect: 235) }
            catch { return (false, "Login was rejected — check the app password. (\((error as? SMTPError)?.errorDescription ?? "auth failed"))") }
            _ = try? await conn.command("QUIT", expect: 221)
            return (true, "Connected and signed in to \(mailbox.host) as \(mailbox.username).")
        } catch let e as SMTPError {
            return (false, e.errorDescription ?? "Couldn't connect.")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

// MARK: - send coordinator (gate → render → SMTP) used by the UI's "Send now" button
struct OutreachSendResult {
    var sent: Bool
    var message: String                 // honest, human-readable outcome
    var checks: [(label: String, ok: Bool)]
    var subject: String
    var body: String
}

enum OutreachSender {
    /// Run the full real send for one prospect through the buyer's OWN mailbox:
    /// 1) deliverability + CAN-SPAM gate (syntax/role/MX/address/mailbox),
    /// 2) render the buyer's template (or type-aware default) with tokens + compliant footer,
    /// 3) deliver over SMTP. Never sends if the gate fails — returns the blocking reasons instead.
    static func send(to prospect: Lead, settings: LeadEngineSettings, allowRole: Bool = false) async -> OutreachSendResult {
        let template = settings.template(for: prospect.type)
        let subject = TemplateEngine.subject(for: prospect, template: template, mailbox: settings.mailbox, bookingLink: settings.bookingLink)
        let body = TemplateEngine.body(for: prospect, template: template, mailbox: settings.mailbox, bookingLink: settings.bookingLink)

        // DEMO MODE: never open a socket, never send a real email, never run a live DNS lookup against
        // the synthetic .test/.example domains. Show the deliverability checklist (passing on the demo
        // mailbox) and return a clearly-labeled simulated result. No mailbox login required.
        if DemoMode.active {
            let checks: [(label: String, ok: Bool)] = [
                ("Valid email syntax", Deliverability.validSyntax(prospect.email)),
                ("Not a role address (info@, sales@…)", !Deliverability.isRoleAddress(prospect.email)),
                ("Domain accepts mail (MX)", true),
                ("Your physical address set (CAN-SPAM)", !settings.mailbox.physicalAddress.isEmpty),
                ("Sending mailbox configured", settings.mailbox.isConfigured),
            ]
            return OutreachSendResult(
                sent: true,
                message: "Demo mode — send simulated to \(prospect.email). No real email was sent.",
                checks: checks, subject: subject, body: body)
        }

        // 1) gate
        let gate = await Deliverability.gate(email: prospect.email, settings: settings, allowRole: allowRole)
        guard gate.canSend else {
            return OutreachSendResult(sent: false,
                                      message: "Held back — " + gate.reasons.joined(separator: "; ") + ".",
                                      checks: gate.checks, subject: subject, body: body)
        }
        // 2) password from Keychain (never from disk/JSON)
        let pw = SendKeychain.password(account: settings.mailbox.username) ?? ""
        guard !pw.isEmpty else {
            return OutreachSendResult(sent: false, message: "No app password saved for your mailbox — add it in Connectors → Mailboxes.",
                                      checks: gate.checks, subject: subject, body: body)
        }
        // 3) real SMTP send
        let client = SMTPClient(mailbox: settings.mailbox, password: pw)
        do {
            try await client.send(to: prospect.email, subject: subject, body: body)
            return OutreachSendResult(sent: true, message: "Sent to \(prospect.email) from \(settings.mailbox.fromEmail).",
                                      checks: gate.checks, subject: subject, body: body)
        } catch let e as SMTPError {
            return OutreachSendResult(sent: false, message: e.errorDescription ?? "Send failed.", checks: gate.checks, subject: subject, body: body)
        } catch {
            return OutreachSendResult(sent: false, message: error.localizedDescription, checks: gate.checks, subject: subject, body: body)
        }
    }
}

// MARK: - low-level SMTP connection (Network.framework, async/await, with timeouts)
// The socket itself is NOT owned here: `ConsentedEgress.openStream` hands back a RawEgressStream
// on the declared `buyerMailServer` lane, so every line of SMTP protocol logic below stays put
// while this file owns no transport of its own. See Sources/ConsentedEgress.swift.
final class SMTPConnection: @unchecked Sendable {
    /// The two submission transports. 465 is encrypted from the first byte; 587 opens in the clear
    /// and is upgraded in place by `startTLS`. Every line of protocol logic below is shared.
    private enum Transport {
        case implicitTLS(RawEgressStream)
        case startTLS(StartTLSEgressStream)
    }
    private let transport: Transport
    private let host: String, port: UInt16, implicitTLS: Bool
    init(host: String, port: UInt16, implicitTLS: Bool) throws {
        self.host = host; self.port = port; self.implicitTLS = implicitTLS
        do {
            if implicitTLS {
                transport = .implicitTLS(try ConsentedEgress.openStream(host: host, port: port, tls: true,
                                                                        lane: .buyerMailServer, label: "bll.smtp"))
            } else {
                transport = .startTLS(try ConsentedEgress.openStartTLSStream(host: host, port: port,
                                                                             lane: .buyerMailServer, label: "bll.smtp"))
            }
        } catch let refusal as RawEgressError {
            throw SMTPError.connection(refusal.errorDescription ?? "The connection was refused.")
        }
    }
    func open() async throws {
        do {
            switch transport {
            case .implicitTLS(let s): try await s.open(timeout: 20)
            case .startTLS(let s): try await s.open(timeout: 20)
            }
        } catch { throw Self.smtpError(error) }
    }
    func close() {
        switch transport {
        case .implicitTLS(let s): s.close()
        case .startTLS(let s): s.close()
        }
    }

    /// Bring a cleartext submission session (587) up to TLS before anything secret is written:
    /// EHLO → the server must ADVERTISE STARTTLS → STARTTLS (220) → upgrade this same socket →
    /// EHLO again over TLS.
    ///
    /// The second EHLO is not ceremony: RFC 3207 requires the client to discard everything it
    /// learned in the clear, because a cleartext capability list (and any bytes an attacker
    /// pipelined behind the 220) is not evidence of anything. So the receive buffer is dropped and
    /// the capabilities — including which AUTH mechanisms exist — are re-read over TLS.
    ///
    /// Fails closed at every step: a server that does not offer STARTTLS, or a refused upgrade,
    /// throws HERE, before AUTH LOGIN could put an app password on a plaintext socket.
    func startTLS(ehloHost: String) async throws {
        guard case .startTLS(let stream) = transport else { return }
        let capabilities = try await command("EHLO \(ehloHost)", expect: 250)
        guard capabilities.uppercased().contains("STARTTLS") else {
            throw SMTPError.connection(
                "\(host) doesn't offer STARTTLS on port \(port), so your password would travel unencrypted. " +
                "Nothing was sent — use port 465 (SSL) instead.")
        }
        try await command("STARTTLS", expect: 220)
        do { try await stream.upgradeToTLS() } catch { throw Self.smtpError(error) }
        rxBuffer = ""                                                // discard the cleartext session
        try await command("EHLO \(ehloHost)", expect: 250)
        guard stream.isSecure else { throw SMTPError.connection("the TLS upgrade did not complete") }
    }

    /// Translate the choke point's stream failures into this client's own protocol errors, so the
    /// "Send now" surface keeps saying exactly what it said before.
    static func smtpError(_ error: Error) -> SMTPError {
        switch error as? RawEgressError {
        case .timeout: return .timeout
        case .closedByPeer: return .connection("server closed the connection")
        case .connection(let detail): return .connection(detail)
        case .registeredHost(_, _): return .connection((error as? RawEgressError)?.errorDescription ?? "refused")
        case nil: return .connection(error.localizedDescription)
        }
    }

    @discardableResult
    func command(_ line: String, expect code: Int) async throws -> String {
        try await write(line + "\r\n")
        return try await expect(code)
    }
    func write(_ s: String) async throws {
        do {
            switch transport {
            case .implicitTLS(let st): try await st.write(Data(s.utf8))
            case .startTLS(let st): try await st.write(Data(s.utf8))
            }
        } catch { throw Self.smtpError(error) }
    }

    /// Read one COMPLETE SMTP reply and assert its status code.
    ///
    /// SMTP replies are multi-line: continuation lines use "NNN-" (dash after the
    /// 3-digit code), the final line uses "NNN " (space). A single TCP segment may
    /// carry a partial reply, several lines, or bytes that belong to the next reply.
    /// We therefore accumulate received bytes into a line buffer until we see the
    /// final line ("NNN " or a bare "NNN"), and keep any trailing bytes for the next
    /// reply. Without this, a partial multi-line EHLO desyncs every later command.
    @discardableResult
    func expect(_ code: Int) async throws -> String {
        let reply = try await readReply()
        guard Self.statusCode(of: reply) == code else {
            throw SMTPError.rejected(reply.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return reply
    }

    /// The status code of a (possibly multi-line) SMTP reply = leading 3 digits of the
    /// final non-empty line. Scalar-based so CRLF (one grapheme cluster in Swift) parses.
    static func statusCode(of reply: String) -> Int? {
        let lines = reply.unicodeScalars.split(separator: "\n")
            .map { String(String.UnicodeScalarView($0)).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Int(String((lines.last ?? reply).prefix(3)))
    }

    /// Buffer of bytes received but not yet consumed by a completed reply.
    private var rxBuffer = ""

    /// Pull a single complete SMTP reply (one or more lines, ending at the final-line
    /// marker), reading more from the socket as needed and stashing any overflow.
    private func readReply() async throws -> String {
        while true {
            if let (reply, rest) = Self.extractReply(from: rxBuffer) {
                rxBuffer = rest
                return reply
            }
            rxBuffer += try await recvChunk()
        }
    }

    /// Split a buffer into (one complete reply, remaining bytes) if a reply is fully
    /// present, else nil (caller reads more). A reply is complete at the first line
    /// whose 4th char is NOT '-' ("NNN " final line). Any bytes after that line belong
    /// to the next reply and are returned as `rest`.
    ///
    /// Scalar-based: in Swift "\r\n" is a SINGLE Character (grapheme cluster), so a
    /// Character-level `firstIndex(of: "\n")` never matches CRLF line endings — the
    /// universal SMTP terminator — and would wrongly report every reply incomplete.
    /// We scan Unicode scalars and split on the bare LF scalar instead.
    static func extractReply(from buffer: String) -> (reply: String, rest: String)? {
        let scalars = Array(buffer.unicodeScalars)
        let LF: Unicode.Scalar = "\n"
        var lineStart = 0
        var i = 0
        while i < scalars.count {
            if scalars[i] == LF {
                let line = String(String.UnicodeScalarView(scalars[lineStart...i]))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let chars = Array(line.unicodeScalars)
                let isContinuation = chars.count >= 4 && chars[3] == "-"
                if !isContinuation {
                    let reply = String(String.UnicodeScalarView(scalars[0...i]))
                    let rest = i + 1 < scalars.count ? String(String.UnicodeScalarView(scalars[(i + 1)...])) : ""
                    return (reply, rest)
                }
                lineStart = i + 1
            }
            i += 1
        }
        return nil
    }

    /// One read from the socket, bounded by the choke point's stream. A silent server (accepts the
    /// socket then never replies) times out instead of leaving the Task pending forever.
    private func recvChunk() async throws -> String {
        do {
            let data: Data
            switch transport {
            case .implicitTLS(let st): data = try await st.read(maximumLength: 8192, timeout: 20)
            case .startTLS(let st): data = try await st.read(maximumLength: 8192, timeout: 20)
            }
            guard let s = String(data: data, encoding: .utf8) else {
                throw SMTPError.connection("server sent a reply this app could not decode")
            }
            return s
        } catch { throw Self.smtpError(error) }
    }
}
#endif // circuit-convert
