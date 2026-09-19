// Black Label Marketing — Cloudflare newsletter send path (own-it, no paid ESP).
//
// The Founder's directive: newsletters must send THROUGH Cloudflare, automatically on their
// cadence — NOT direct local SMTP. This file is the app side of that: it POSTs a rendered
// newsletter to a Cloudflare Worker (the buyer's own, backed by Cloudflare Email Sending — see
// cloudflare/newsletter-worker/ in this repo), and the in-app cadence runner fires the due sends.
//
// SHIP-NO-DATA / OWN-IT: the endpoint URL, the "from" identity, and the send token ALL ship EMPTY.
// The buyer pastes their own Worker URL + a shared secret in Connectors → Newsletters (Cloudflare).
// The secret lives in the data-protection Keychain, never in JSON, never in the shipped bundle.
// Nothing here talks to a Black Label mailbox or list — the recipient list is the buyer's OWN
// contacts, and the send happens on the buyer's own Cloudflare account.
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - config (all fields ship EMPTY; buyer fills them in the UI)

enum CloudflareEmailConfig {
    // UserDefaults keys (device-local, non-secret). Namespaced to avoid collision.
    static let endpointKey = "cf.newsletter.endpoint"     // https://newsletter.<buyer>.workers.dev/send
    static let fromEmailKey = "cf.newsletter.fromEmail"    // news@buyerdomain.com (a domain onboarded to CF Email Sending)
    static let fromNameKey  = "cf.newsletter.fromName"     // "Acme Studio"
    static let autoSendKey  = "cf.newsletter.autoSend"     // Bool — fire due newsletters automatically

    // Keychain (the shared secret the Worker checks in the Authorization: Bearer header).
    private static var keychainService: String {
        "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").cfemail"
    }
    private static let keychainAccount = "newsletter"
    private static var keychainBase: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    static var endpoint: String {
        get { (UserDefaults.standard.string(forKey: endpointKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: endpointKey) }
            else { UserDefaults.standard.set(v, forKey: endpointKey) }
        }
    }
    static var fromEmail: String {
        get { (UserDefaults.standard.string(forKey: fromEmailKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: fromEmailKey) }
            else { UserDefaults.standard.set(v, forKey: fromEmailKey) }
        }
    }
    static var fromName: String {
        get { UserDefaults.standard.string(forKey: fromNameKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: fromNameKey) }
    }
    static var autoSend: Bool {
        get { UserDefaults.standard.bool(forKey: autoSendKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoSendKey) }
    }

    // MARK: the shared secret (Keychain, data-protection, on-device only)
    static func setToken(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespaces)
        let base = keychainBase
        if t.isEmpty { MarketingKeychain.delete(base); return }
        MarketingKeychain.set(base, data: Data(t.utf8), accessible: kSecAttrAccessibleWhenUnlocked)
    }
    static var token: String? {
        let base = keychainBase
        guard let data = MarketingKeychain.copy(base, accessible: kSecAttrAccessibleWhenUnlocked,
                                                allowAuthenticationUI: false),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
    static var hasToken: Bool { token != nil }
    static var hasSavedTokenItem: Bool { MarketingKeychain.exists(keychainBase) }
    static var tokenNeedsReconnect: Bool { !hasToken && hasSavedTokenItem }
    static func migrateSavedToken() -> Bool {
        MarketingKeychain.migrate(keychainBase, accessible: kSecAttrAccessibleWhenUnlocked)
    }

    /// True only when every field needed for a real send is present. Pure over its inputs so the
    /// UI status chip and the auto-runner agree.
    static func isConfigured(endpoint: String, fromEmail: String, hasToken: Bool) -> Bool {
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
              scheme == "https", url.host != nil else { return false }
        guard EmailValidator.isValid(fromEmail) else { return false }
        return hasToken
    }
    static var isConfigured: Bool { isConfigured(endpoint: endpoint, fromEmail: fromEmail, hasToken: hasToken) }
}

// MARK: - durable per-recipient delivery progress

struct CloudflareRecipientResult: Codable, Equatable, Hashable {
    enum State: String, Codable { case sent, failed }
    var recipient: String
    var state: State
    var detail: String? = nil
    var idempotent: Bool? = nil
}

struct NewsletterRecipientProgress: Codable, Hashable {
    enum State: String, Codable { case pending, sent, failed, suppressed }
    var state: State = .pending
    var attempts: Int = 0
    var detail: String = ""
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Persisted inside the buyer's existing on-device newsletter record. The recipient snapshot and
/// stable delivery id survive app restarts, so each cadence run resumes only unsent recipients.
struct NewsletterDeliveryProgress: Codable, Hashable {
    var deliveryID: String
    var startedAt = Date()
    var recipients: [String]
    var byRecipient: [String: NewsletterRecipientProgress]

    init(recipients: [String], deliveryID: String = UUID().uuidString, startedAt: Date = Date()) {
        self.deliveryID = deliveryID
        self.startedAt = startedAt
        self.recipients = recipients
        self.byRecipient = Dictionary(uniqueKeysWithValues: recipients.map {
            (EmailSuppression.normalized($0), NewsletterRecipientProgress())
        })
    }

    /// Stable even if the local write immediately after creation is interrupted: lastSentAt does
    /// not change until the whole audience resolves, so retries reconstruct the same Worker key.
    static func stableDeliveryID(newsletterID: UUID, lastSentAt: Date?) -> String {
        let anchor = lastSentAt.map { Int($0.timeIntervalSince1970) } ?? 0
        return "\(newsletterID.uuidString)-\(anchor)"
    }

    var completedCount: Int { byRecipient.values.filter { $0.state == .sent }.count }
    var suppressedCount: Int { byRecipient.values.filter { $0.state == .suppressed }.count }
    var resolvedCount: Int { completedCount + suppressedCount }
    var remainingCount: Int { max(0, recipients.count - resolvedCount) }
    var isComplete: Bool { !recipients.isEmpty && resolvedCount == recipients.count }
    var retryableRecipients: [String] {
        recipients.filter {
            let state = byRecipient[EmailSuppression.normalized($0)]?.state
            return state != .sent && state != .suppressed
        }
    }

    mutating func markSuppressed(_ keys: Set<String>) {
        for email in recipients {
            let key = EmailSuppression.normalized(email)
            guard keys.contains(key), byRecipient[key]?.state != .sent else { continue }
            var progress = byRecipient[key] ?? NewsletterRecipientProgress()
            progress.state = .suppressed
            progress.detail = "Suppressed before delivery"
            byRecipient[key] = progress
        }
    }

    mutating func record(email: String, landed: Bool, detail: String) {
        let key = EmailSuppression.normalized(email)
        var progress = byRecipient[key] ?? NewsletterRecipientProgress()
        if progress.state == .sent || progress.state == .suppressed { return }
        progress.attempts += 1
        progress.state = landed ? .sent : .failed
        progress.detail = detail
        byRecipient[key] = progress
    }

    /// Apply only the attempted chunk. Missing/malformed per-recipient results are failures, never
    /// inferred successes. Already-sent entries remain sent, making response replay idempotent.
    mutating func apply(_ result: CloudflareMailer.SendResult, attempted: [String]) {
        var outcomes: [String: CloudflareRecipientResult] = [:]
        for outcome in result.outcomes {
            let key = EmailSuppression.normalized(outcome.recipient)
            if outcomes[key] == nil { outcomes[key] = outcome }
        }
        for email in attempted {
            let key = EmailSuppression.normalized(email)
            if let outcome = outcomes[key], outcome.state == .sent {
                record(email: email, landed: true, detail: outcome.detail ?? "Provider accepted")
            } else {
                record(email: email, landed: false, detail: outcomes[key]?.detail ?? result.detail)
            }
        }
    }
}
#endif // circuit-convert

// MARK: - the Worker request (pure builder + async transport)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum CloudflareMailer {
    static let protocolVersion = 2
    static let maxRecipientsPerRequest = 100

    struct SendResult {
        var ok: Bool
        var accepted: Int
        var failed: Int
        var truncated: Bool
        var outcomes: [CloudflareRecipientResult]
        var detail: String
    }

    struct CompatibilityResult: Equatable {
        var ok: Bool
        var detail: String
    }

    /// The JSON body we POST to the Worker. Deterministic + Codable so it's unit-tested without a socket.
    struct Payload: Codable, Equatable {
        var from: String
        var fromName: String
        var subject: String
        var text: String
        var html: String
        var recipients: [String]
        var deliveryID: String = ""
        var protocolVersion: Int = CloudflareMailer.protocolVersion
    }

    private struct WorkerEnvelope: Decodable {
        var ok: Bool?
        var protocolVersion: Int?
        var sent: Int?
        var failed: Int?
        var truncated: Bool?
        var error: String?
        var results: [CloudflareRecipientResult]?
    }

    private struct WorkerCapabilities: Decodable {
        var ok: Bool
        var protocolVersion: Int
        var durableProgress: Bool
        var maxRecipientsPerRequest: Int
    }

    /// Build the signed POST request. Returns nil when the endpoint isn't a valid https URL — so a
    /// misconfigured Worker URL fails loudly at build time, never a silent no-op.
    static func buildRequest(endpoint: String, token: String, payload: Payload) -> URLRequest? {
        guard let url = URL(string: endpoint), (url.scheme?.lowercased() == "https") else { return nil }
        guard !payload.deliveryID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.protocolVersion == protocolVersion,
              !payload.recipients.isEmpty,
              payload.recipients.count <= maxRecipientsPerRequest,
              Set(payload.recipients.map(EmailSuppression.normalized)).count == payload.recipients.count else { return nil }
        guard let body = try? JSONEncoder().encode(payload) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.httpBody = body
        req.timeoutInterval = 30
        return req
    }

    /// Build a signed, no-recipient capability probe from the configured `/send` endpoint. This is
    /// required before delivery so an older Worker cannot send a chunk and only then reveal that it
    /// lacks durable receipts.
    static func buildCapabilitiesRequest(endpoint: String, token: String) -> URLRequest? {
        guard var components = URLComponents(string: endpoint),
              components.scheme?.lowercased() == "https", components.host != nil else { return nil }
        var path = components.path.split(separator: "/").map(String.init)
        if path.last?.lowercased() == "send" { path.removeLast() }
        path.append("capabilities")
        components.path = "/" + path.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        return request
    }

    static func parseCapabilities(statusCode: Int, data: Data) -> CompatibilityResult {
        guard statusCode == 200,
              let capabilities = try? JSONDecoder().decode(WorkerCapabilities.self, from: data),
              capabilities.ok,
              capabilities.protocolVersion == protocolVersion,
              capabilities.durableProgress,
              capabilities.maxRecipientsPerRequest >= maxRecipientsPerRequest else {
            return CompatibilityResult(
                ok: false,
                detail: "Cloudflare Newsletter Worker v\(protocolVersion) with durable progress is required before any recipients can be sent. Redeploy the packaged Worker."
            )
        }
        return CompatibilityResult(ok: true, detail: "Compatible durable newsletter Worker")
    }

    static func verifyCompatibility(endpoint: String, token: String) async -> CompatibilityResult {
        guard let request = buildCapabilitiesRequest(endpoint: endpoint, token: token) else {
            return CompatibilityResult(ok: false, detail: "The Cloudflare newsletter endpoint is invalid.")
        }
        do {
            let (data, response) = try await ConsentedEgress.sendUngated(request, lane: .ownAccountAPI)
            return parseCapabilities(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, data: data)
        } catch {
            return CompatibilityResult(ok: false, detail: "Couldn't verify the Cloudflare Newsletter Worker: \(error.localizedDescription)")
        }
    }

    /// Minimal, plain-text → HTML wrap so the newsletter body renders in HTML clients while the
    /// text/plain alternative stays readable (deliverability best-practice: always ship both).
    static func htmlWrap(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let paragraphs = escaped
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { "<p>\($0.replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined(separator: "\n")
        return "<!doctype html><html><body style=\"font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color:#111;\">\n\(paragraphs)\n</body></html>"
    }

    /// Decode the Worker's explicit contract. A 2xx is not success by itself: `ok` must be true,
    /// truncation false, and every expected recipient must have one `sent` outcome.
    static func parseResponse(statusCode: Int, data: Data, expectedRecipients: [String]) -> SendResult {
        let envelope = try? JSONDecoder().decode(WorkerEnvelope.self, from: data)
        let outcomes = envelope?.results ?? []
        let expected = Set(expectedRecipients.map(EmailSuppression.normalized))
        let sentKeys = Set(outcomes.filter { $0.state == .sent }.map { EmailSuppression.normalized($0.recipient) })
        let duplicateResultKeys = outcomes.map { EmailSuppression.normalized($0.recipient) }.count
            != Set(outcomes.map { EmailSuppression.normalized($0.recipient) }).count
        let unknownResults = outcomes.contains { !expected.contains(EmailSuppression.normalized($0.recipient)) }
        let accepted = expected.intersection(sentKeys).count
        let failed = max(0, expected.count - accepted)
        let truncated = envelope?.truncated ?? false
        let contractComplete = !duplicateResultKeys && !unknownResults && outcomes.count == expected.count
            && accepted == expected.count && envelope?.sent == expected.count && envelope?.failed == 0
            && envelope?.truncated == false && envelope?.protocolVersion == protocolVersion
        let ok = (200...299).contains(statusCode) && envelope?.ok == true && contractComplete

        let detail: String
        if ok {
            detail = "Cloudflare accepted all \(accepted) message\(accepted == 1 ? "" : "s")."
        } else if let error = envelope?.error, !error.isEmpty {
            detail = "The send didn't go through — your Cloudflare Worker answered HTTP \(statusCode): \(error)."
        } else if truncated {
            detail = "Cloudflare rejected a truncated delivery response; no cadence progress was inferred."
        } else if envelope == nil {
            detail = "The send couldn't be confirmed — your Cloudflare Worker answered HTTP \(statusCode) without a valid per-recipient receipt."
        } else {
            detail = "Cloudflare accepted \(accepted) of \(expected.count); \(failed) remain due."
        }
        return SendResult(ok: ok, accepted: accepted, failed: failed, truncated: truncated,
                          outcomes: outcomes, detail: detail)
    }

    /// POST a rendered newsletter to the buyer's Worker. Honest: any non-2xx or transport error is
    /// reported as a failure with the server's own reason — never logged as sent.
    static func send(endpoint: String, token: String, payload: Payload) async -> SendResult {
        guard let req = buildRequest(endpoint: endpoint, token: token, payload: payload) else {
            ConnectorVerificationStore.record(ConnectorVerificationStore.cloudflareNewsletter, ok: false, detail: "Invalid endpoint or delivery chunk")
            return SendResult(ok: false, accepted: 0, failed: payload.recipients.count, truncated: false, outcomes: [],
                              detail: "The Cloudflare endpoint, delivery id, or recipient chunk is invalid (maximum \(maxRecipientsPerRequest)).")
        }
        do {
            let (data, resp) = try await ConsentedEgress.sendUngated(req, lane: .ownAccountAPI)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let result = parseResponse(statusCode: code, data: data, expectedRecipients: payload.recipients)
            ConnectorVerificationStore.record(ConnectorVerificationStore.cloudflareNewsletter, ok: result.ok,
                                              detail: result.ok ? "Worker accepted the full delivery chunk" : result.detail)
            return result
        } catch {
            ConnectorVerificationStore.record(ConnectorVerificationStore.cloudflareNewsletter, ok: false, detail: error.localizedDescription)
            return SendResult(ok: false, accepted: 0, failed: payload.recipients.count, truncated: false, outcomes: [],
                              detail: "Couldn't reach the Cloudflare Worker: \(error.localizedDescription)")
        }
    }
}
#endif // circuit-convert

// MARK: - the automatic cadence dispatcher (pure due-selection + the live runner)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum NewsletterDispatch {
    struct Report {
        var attempted = 0
        var sent = 0
        var failed = 0
        var messages: [String] = []
    }

    /// Pure: which newsletters are due to go out at `now`. Kept separate from the runner so the
    /// cadence logic is unit-tested without a network or a live model.
    static func due(_ newsletters: [Newsletter], now: Date) -> [Newsletter] {
        newsletters.filter { $0.isDue(now: now) }
    }

    /// Pure: the deliverable recipient set (valid, de-duplicated emails) for a newsletter drawn from
    /// the buyer's OWN contacts. Honors an optional segment filter by tag id match is done by caller;
    /// here we just clean + de-dupe the emails so no address is mailed twice.
    static func recipients(from contacts: [Contact], suppressed: Set<String> = []) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for c in contacts {
            let e = c.email.trimmingCharacters(in: .whitespaces).lowercased()
            guard EmailValidator.isValid(e), !seen.contains(e), !suppressed.contains(e) else { continue }
            seen.insert(e); out.append(e)
        }
        return out
    }
}
#endif // circuit-convert
