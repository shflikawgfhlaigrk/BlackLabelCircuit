// Black Label Marketing — Sendblue messaging client (iMessage / RCS / SMS), BYO provider.
//
// The buyer connects their OWN Sendblue account (API key id + secret) in Connectors. Nothing is
// baked into the bundle: no key, no from-number, no endpoint override, no contacts. With no
// credential the app says "not connected" and every send is reported as simulated — it never
// fabricates a delivery.
//
// Reverse-engineered from Sendblue's public API surface (docs.sendblue.com, 2026-08-01) — see
// docs/SENDBLUE-INTEGRATION-SPEC.md. We implement the protocol against the buyer's own account;
// no Black Label relay, no Black Label number, no shared credential (CHARTER §5.2 / §5.5).
//
// EVERYTHING in this file is Foundation-only and pure where it can be, so the request builders,
// the status/service parsers, the E.164 normalizer, the opt-out detector and the TCPA gate are
// unit-tested headlessly in Tests/SendblueTests.swift + Tests/MessagingSafetyTests.swift. The
// one non-pure dependency is `MarketingKeychain` (the app's data-protection Keychain router),
// which the suites stand in for exactly the way Tests/EmailAPITests.swift does for EmailAPI.swift.
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - service + status enums (exact Sendblue vocabulary)

/// The transport Sendblue actually used for a message. Fallback (iMessage → RCS → SMS) is decided
/// server-side; we report what came back rather than predicting it.
enum SendblueService: String, Codable, CaseIterable, Identifiable {
    case iMessage = "iMessage"
    case SMS = "SMS"
    case RCS = "RCS"
    var id: String { rawValue }

    var label: String { rawValue }

    /// Case-insensitive parse of whatever the API/webhook put in `service`. Unknown → nil (never
    /// silently coerced to iMessage, which would paint a green bubble on an SMS).
    static func parse(_ raw: String?) -> SendblueService? {
        guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !key.isEmpty else { return nil }
        switch key {
        case "imessage": return .iMessage
        case "sms": return .SMS
        case "rcs": return .RCS
        default: return nil
        }
    }
}

/// Sendblue's message status enum, verbatim. Ordered roughly by lifecycle.
enum SendblueMessageStatus: String, Codable, CaseIterable, Identifiable {
    case registered = "REGISTERED"
    case pending = "PENDING"
    case queued = "QUEUED"
    case accepted = "ACCEPTED"
    case sent = "SENT"
    case delivered = "DELIVERED"
    case read = "READ"
    case declined = "DECLINED"
    case error = "ERROR"
    var id: String { rawValue }

    static func parse(_ raw: String?) -> SendblueMessageStatus? {
        guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !key.isEmpty else { return nil }
        return SendblueMessageStatus(rawValue: key)
    }

    var label: String {
        switch self {
        case .registered: return "Registered"
        case .pending: return "Pending"
        case .queued: return "Queued"
        case .accepted: return "Accepted"
        case .sent: return "Sent"
        case .delivered: return "Delivered"
        case .read: return "Read"
        case .declined: return "Declined"
        case .error: return "Error"
        }
    }

    /// The provider has taken responsibility for the message. NOT the same as delivered — an
    /// accepted message can still end in DECLINED/ERROR, so the UI must not claim delivery here.
    var isAccepted: Bool {
        switch self {
        case .accepted, .sent, .delivered, .read: return true
        case .registered, .pending, .queued, .declined, .error: return false
        }
    }
    /// Confirmed on the handset. Only DELIVERED/READ earn this.
    var isDelivered: Bool { self == .delivered || self == .read }
    /// A terminal failure the buyer must see.
    var isFailure: Bool { self == .declined || self == .error }
}

/// The 13 iMessage expressive send styles Sendblue exposes on `send_style`. iMessage only —
/// an SMS/RCS fallback drops the effect, which is why the UI labels it "iMessage only".
enum SendblueSendStyle: String, Codable, CaseIterable, Identifiable {
    case celebration, shooting_star, fireworks, lasers, love, confetti, balloons
    case spotlight, echo, invisible, gentle, loud, slam
    var id: String { rawValue }
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}

/// Tapback reactions Sendblue accepts on `/api/send-reaction`.
enum SendblueReaction: String, Codable, CaseIterable, Identifiable {
    case love, like, dislike, laugh, emphasize, question
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

// MARK: - phone-number normalization (E.164)

enum PhoneNumber {
    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let value = character.unicodeScalars.first?.value else { return false }
        return value >= 48 && value <= 57
    }

    /// Normalize to E.164 (`+` + digits). US/CA 10-digit and 1-prefixed 11-digit inputs get a `+1`;
    /// anything already carrying `+` keeps its country code. Returns nil when the input cannot be a
    /// dialable number — we never send to a guess.
    static func e164(_ raw: String, defaultCountryCode: String = "1") -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // E.164 accepts ASCII digits only. Character.isNumber also accepts fullwidth,
        // Arabic-indic, superscript, and other Unicode numerals that are not dialable.
        guard !trimmed.contains(where: { $0.isNumber && !isASCIIDigit($0) }) else { return nil }
        let hadPlus = trimmed.hasPrefix("+")
        let digits = trimmed.filter(isASCIIDigit)
        guard !digits.isEmpty else { return nil }
        if hadPlus {
            guard digits.count >= 8, digits.count <= 15 else { return nil }
            return "+" + digits
        }
        if defaultCountryCode == "1" {
            if digits.count == 10 { return "+1" + digits }
            if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
            return nil
        }
        guard digits.count >= 8, digits.count <= 15 else { return nil }
        return "+" + digits
    }

    static func isE164(_ raw: String) -> Bool {
        guard raw.hasPrefix("+") else { return false }
        let digits = raw.dropFirst()
        return digits.count >= 8 && digits.count <= 15 && digits.allSatisfy(isASCIIDigit)
    }

    /// Stable key for grouping a thread / keying a ledger, independent of formatting.
    static func key(_ raw: String) -> String { e164(raw) ?? raw.filter { $0.isNumber || $0 == "+" } }
}

// MARK: - config (ships EMPTY; buyer fills it in Connectors → Messaging)

enum SendblueConfig {
    /// Sendblue's documented API host. Kept overridable (their send host was historically
    /// `api.sendblue.co`) but DEFAULTS to the documented `.com` and ships with nothing stored.
    static let defaultBaseURL = "https://api.sendblue.com"

    // Non-secret, device-local config — namespaced UserDefaults, same posture as `cf.newsletter.*`.
    static let baseURLKey = "sendblue.baseURL"
    static let fromNumberKey = "sendblue.fromNumber"
    static let statusCallbackKey = "sendblue.statusCallback"
    static let defaultCountryCodeKey = "sendblue.defaultCountryCode"
    static let dailyLineCapKey = "sendblue.dailyLineCap"

    static var baseURL: String {
        get {
            let v = (UserDefaults.standard.string(forKey: baseURLKey) ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? defaultBaseURL : v
        }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty || v == defaultBaseURL { UserDefaults.standard.removeObject(forKey: baseURLKey) }
            else { UserDefaults.standard.set(v, forKey: baseURLKey) }
        }
    }
    /// The buyer's own Sendblue line. Empty = let the account's default line answer for it.
    static var fromNumber: String {
        get { (UserDefaults.standard.string(forKey: fromNumberKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = PhoneNumber.e164(newValue) ?? newValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: fromNumberKey) }
            else { UserDefaults.standard.set(v, forKey: fromNumberKey) }
        }
    }
    /// Optional public callback the buyer owns (a Worker relay — never this app's process).
    static var statusCallback: String {
        get { (UserDefaults.standard.string(forKey: statusCallbackKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: statusCallbackKey) }
            else { UserDefaults.standard.set(v, forKey: statusCallbackKey) }
        }
    }
    static var defaultCountryCode: String {
        get {
            let v = (UserDefaults.standard.string(forKey: defaultCountryCodeKey) ?? "").filter { $0.isNumber }
            return v.isEmpty ? "1" : v
        }
        set { UserDefaults.standard.set(newValue.filter { $0.isNumber }, forKey: defaultCountryCodeKey) }
    }
    /// Buyer-set per-line daily send cap. 0 (the shipped default) means "no cap the app enforces".
    static var dailyLineCap: Int {
        get { max(0, UserDefaults.standard.integer(forKey: dailyLineCapKey)) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: dailyLineCapKey) }
    }

    // MARK: the credential (BOTH halves in the data-protection Keychain, never UserDefaults)

    private static var keychainService: String {
        "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").sendblue"
    }
    private static let keychainAccount = "api"
    private static var keychainBase: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
    }

    struct Credential: Codable, Equatable {
        var keyID: String
        var secret: String
        var isComplete: Bool { !keyID.isEmpty && !secret.isEmpty }
    }

    static func setCredential(keyID: String, secret: String) {
        let id = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = keychainBase
        guard !id.isEmpty, !sec.isEmpty, let data = try? JSONEncoder().encode(Credential(keyID: id, secret: sec)) else {
            MarketingKeychain.delete(base)
            return
        }
        MarketingKeychain.set(base, data: data, accessible: kSecAttrAccessibleWhenUnlocked)
    }

    static func clearCredential() { MarketingKeychain.delete(keychainBase) }

    static var credential: Credential? {
        guard let data = MarketingKeychain.copy(keychainBase, accessible: kSecAttrAccessibleWhenUnlocked,
                                                allowAuthenticationUI: false),
              let c = try? JSONDecoder().decode(Credential.self, from: data), c.isComplete else { return nil }
        return c
    }
    static var hasCredential: Bool { credential != nil }
    static var hasSavedCredentialItem: Bool { MarketingKeychain.exists(keychainBase) }
    /// A saved-but-unreadable Keychain row (ACL bound to an older signature) — the buyer must
    /// re-enter or reconnect. Reported honestly instead of reading as "not connected".
    static var credentialNeedsReconnect: Bool { !hasCredential && hasSavedCredentialItem }
    static func migrateSavedCredential() -> Bool {
        MarketingKeychain.migrate(keychainBase, accessible: kSecAttrAccessibleWhenUnlocked)
    }

    /// Everything a real send needs. The from-number is optional (Sendblue resolves the account's
    /// line), so the credential alone decides configured-ness.
    static var isConfigured: Bool { hasCredential }
}

// MARK: - pure request builders (unit-tested — no network in this file)

/// One outbound `/api/send-message` body, kept as a value so the MCP dry-run and the app send the
/// byte-identical payload.
struct SendbluePayload: Equatable {
    var number: String                 // E.164 recipient
    var fromNumber: String = ""        // E.164 sending line ("" = account default)
    var content: String = ""
    var mediaURL: String = ""
    var sendStyle: SendblueSendStyle? = nil
    var statusCallback: String = ""

    /// The exact JSON object Sendblue receives. Empty optionals are OMITTED (not sent as ""),
    /// because an empty `media_url` is a different request than no media at all.
    var json: [String: Any] {
        var out: [String: Any] = ["number": number]
        if !fromNumber.isEmpty { out["from_number"] = fromNumber }
        if !content.isEmpty { out["content"] = content }
        if !mediaURL.isEmpty { out["media_url"] = mediaURL }
        if let sendStyle { out["send_style"] = sendStyle.rawValue }
        if !statusCallback.isEmpty { out["status_callback"] = statusCallback }
        return out
    }
}

/// What a send attempt actually produced — parsed from the API response, never assumed.
struct SendblueSendResult: Equatable {
    var ok: Bool
    var status: SendblueMessageStatus?
    var service: SendblueService?
    var messageHandle: String = ""
    var errorCode: String = ""
    var detail: String = ""
}

/// Result of `/api/evaluate-service` — whether a number can receive iMessage.
struct SendblueServiceEvaluation: Equatable {
    var ok: Bool
    var number: String = ""
    var service: SendblueService?
    var detail: String = ""
}

enum SendblueAPI {
    /// Sendblue's documented content ceiling for one message.
    static let contentCharacterLimit = 18_996
    /// Documented media ceilings (bytes) — surfaced so the UI can warn before an upload fails.
    static let iMessageMediaByteLimit = 100 * 1024 * 1024
    static let smsMediaByteLimit = 5 * 1024 * 1024

    static let sendMessagePath = "/api/send-message"
    static let evaluateServicePath = "/api/evaluate-service"
    static let typingIndicatorPath = "/api/send-typing-indicator"
    static let reactionPath = "/api/send-reaction"
    static let groupMessagePath = "/api/send-group-message"
    static let messagesPath = "/api/v2/messages"
    static let contactsPath = "/api/v2/contacts"
    static let linesPath = "/api/accounts/lines"
    static let webhooksPath = "/api/account/webhooks"

    static func url(base: String, path: String, query: [URLQueryItem] = []) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        guard var c = URLComponents(string: trimmed.isEmpty ? SendblueConfig.defaultBaseURL : trimmed),
              let scheme = c.scheme?.lowercased(), scheme == "https", c.host != nil else { return nil }
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + path
        // Encode the query OURSELVES. `URLComponents.queryItems` leaves `+` literal, and every
        // Sendblue value here is an E.164 number that starts with one — a literal `+` is decoded
        // server-side as a space, so `?number=+1555…` silently asks about the wrong number.
        if !query.isEmpty {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            c.percentEncodedQuery = query.map { item in
                let k = item.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? item.name
                let v = (item.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(k)=\(v)"
            }.joined(separator: "&")
        }
        return c.url
    }

    /// Every Sendblue call carries the same two headers. Backend-only by design — Sendblue blocks
    /// browser origins, which a native app is not.
    static func authorized(_ url: URL, method: String, keyID: String, secret: String,
                           body: Data? = nil, timeout: TimeInterval = 30) -> URLRequest? {
        let id = keyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let sec = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !sec.isEmpty else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue(id, forHTTPHeaderField: "sb-api-key-id")
        r.setValue(sec, forHTTPHeaderField: "sb-api-secret-key")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    /// POST /api/send-message. Returns nil when the recipient is not E.164, the message is empty
    /// (no content AND no media), the content exceeds the documented ceiling, or creds are blank —
    /// a request we know the API will reject is not built.
    static func sendMessageRequest(base: String = SendblueConfig.defaultBaseURL,
                                   keyID: String, secret: String, payload: SendbluePayload) -> URLRequest? {
        guard PhoneNumber.isE164(payload.number) else { return nil }
        guard !payload.content.isEmpty || !payload.mediaURL.isEmpty else { return nil }
        guard payload.content.count <= contentCharacterLimit else { return nil }
        guard let u = url(base: base, path: sendMessagePath),
              let body = try? JSONSerialization.data(withJSONObject: payload.json) else { return nil }
        return authorized(u, method: "POST", keyID: keyID, secret: secret, body: body)
    }

    /// GET /api/evaluate-service?number=+1E164 — the iMessage capability check.
    /// Separate, tight rate limit upstream (30/hr, 100/day per line), so callers cache the answer.
    static func evaluateServiceRequest(base: String = SendblueConfig.defaultBaseURL,
                                       keyID: String, secret: String, number: String) -> URLRequest? {
        guard PhoneNumber.isE164(number),
              let u = url(base: base, path: evaluateServicePath, query: [URLQueryItem(name: "number", value: number)])
        else { return nil }
        return authorized(u, method: "GET", keyID: keyID, secret: secret, timeout: 20)
    }

    /// POST /api/send-typing-indicator — iMessage only.
    static func typingIndicatorRequest(base: String = SendblueConfig.defaultBaseURL,
                                       keyID: String, secret: String, number: String) -> URLRequest? {
        guard PhoneNumber.isE164(number), let u = url(base: base, path: typingIndicatorPath),
              let body = try? JSONSerialization.data(withJSONObject: ["number": number]) else { return nil }
        return authorized(u, method: "POST", keyID: keyID, secret: secret, body: body, timeout: 20)
    }

    /// POST /api/send-reaction — tapback on a prior message handle.
    static func reactionRequest(base: String = SendblueConfig.defaultBaseURL,
                                keyID: String, secret: String, number: String,
                                messageHandle: String, reaction: SendblueReaction) -> URLRequest? {
        let handle = messageHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PhoneNumber.isE164(number), !handle.isEmpty, let u = url(base: base, path: reactionPath),
              let body = try? JSONSerialization.data(withJSONObject: [
                  "number": number, "message_handle": handle, "reaction": reaction.rawValue
              ]) else { return nil }
        return authorized(u, method: "POST", keyID: keyID, secret: secret, body: body, timeout: 20)
    }

    /// GET /api/v2/messages — history/status polling. `limit` is clamped to Sendblue's 100/page.
    static func listMessagesRequest(base: String = SendblueConfig.defaultBaseURL,
                                    keyID: String, secret: String,
                                    number: String? = nil, limit: Int = 50, offset: Int = 0) -> URLRequest? {
        var query = [URLQueryItem(name: "limit", value: String(min(max(1, limit), 100))),
                     URLQueryItem(name: "offset", value: String(max(0, offset)))]
        if let number, PhoneNumber.isE164(number) { query.append(URLQueryItem(name: "number", value: number)) }
        guard let u = url(base: base, path: messagesPath, query: query) else { return nil }
        return authorized(u, method: "GET", keyID: keyID, secret: secret, timeout: 20)
    }

    /// GET /api/accounts/lines — the cheapest authenticated read, used as the credential probe.
    static func linesRequest(base: String = SendblueConfig.defaultBaseURL,
                             keyID: String, secret: String) -> URLRequest? {
        guard let u = url(base: base, path: linesPath) else { return nil }
        return authorized(u, method: "GET", keyID: keyID, secret: secret, timeout: 20)
    }

    // MARK: response parsing

    /// Sendblue's envelope carries the human message under `message`; errors add `error_code`.
    /// Mirrors the `apiMessage(_:)` extractor the other clients use.
    static func apiMessage(_ json: [String: Any]?) -> String {
        guard let json else { return "" }
        for key in ["message", "error_message", "error", "detail"] {
            if let s = json[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        return ""
    }

    static func jsonObject(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Parse a `/api/send-message` response. A 2xx with a FAILURE status is still a failure — the
    /// HTTP code alone never decides, because ERROR/DECLINED come back on a 200.
    static func parseSendResponse(statusCode: Int, data: Data?) -> SendblueSendResult {
        let json = jsonObject(data)
        let payload = (json?["data"] as? [String: Any]) ?? json
        let status = SendblueMessageStatus.parse(payload?["status"] as? String)
        let service = SendblueService.parse(payload?["service"] as? String)
        let handle = (payload?["message_handle"] as? String) ?? (payload?["messageHandle"] as? String) ?? ""
        let errorCode = (json?["error_code"] as? String) ?? (payload?["error_code"] as? String) ?? ""
        let message = apiMessage(json)
        guard (200...299).contains(statusCode) else {
            return SendblueSendResult(ok: false, status: status, service: service, messageHandle: handle,
                                      errorCode: errorCode,
                                      detail: message.isEmpty ? "Sendblue returned HTTP \(statusCode)." : "HTTP \(statusCode): \(message)")
        }
        if let status, status.isFailure {
            return SendblueSendResult(ok: false, status: status, service: service, messageHandle: handle,
                                      errorCode: errorCode,
                                      detail: message.isEmpty ? "Sendblue reported \(status.rawValue)." : message)
        }
        guard let status else {
            return SendblueSendResult(ok: false, status: nil, service: service, messageHandle: handle,
                                      errorCode: errorCode,
                                      detail: "Sendblue returned HTTP \(statusCode) with no status field — the outcome is unknown, so this is not reported as sent.")
        }
        return SendblueSendResult(ok: true, status: status, service: service, messageHandle: handle,
                                  errorCode: errorCode,
                                  detail: message.isEmpty ? "Sendblue accepted the message (\(status.rawValue))." : message)
    }

    /// Parse `/api/evaluate-service`. Sendblue answers with the service the number supports.
    static func parseEvaluateService(statusCode: Int, data: Data?) -> SendblueServiceEvaluation {
        let json = jsonObject(data)
        let payload = (json?["data"] as? [String: Any]) ?? json
        let number = (payload?["number"] as? String) ?? ""
        let service = SendblueService.parse(payload?["service"] as? String)
        let message = apiMessage(json)
        guard (200...299).contains(statusCode) else {
            return SendblueServiceEvaluation(ok: false, number: number, service: nil,
                                             detail: message.isEmpty ? "HTTP \(statusCode)" : "HTTP \(statusCode): \(message)")
        }
        guard let service else {
            return SendblueServiceEvaluation(ok: false, number: number, service: nil,
                                             detail: "Sendblue returned no service for this number — capability unknown.")
        }
        return SendblueServiceEvaluation(ok: true, number: number, service: service,
                                         detail: "\(number.isEmpty ? "This number" : number) supports \(service.label).")
    }

    /// Truthful verify detail for the connector probe. A 401/403 is a bad credential, not a network
    /// blip, and is worded that way.
    static func probeDetail(statusCode: Int, data: Data?) -> (ok: Bool, detail: String) {
        let message = apiMessage(jsonObject(data))
        switch statusCode {
        case 200...299: return (true, message.isEmpty ? "Sendblue accepted this credential." : message)
        case 401, 403:  return (false, "Sendblue rejected this credential (HTTP \(statusCode)). Check the API key id and secret.")
        case 429:       return (false, "Sendblue rate-limited the check (HTTP 429). Wait and retry — this says nothing about the credential.")
        default:        return (false, message.isEmpty ? "Sendblue returned HTTP \(statusCode)." : "HTTP \(statusCode): \(message)")
        }
    }
}

// MARK: - opt-out detection (Sendblue detects STOP upstream; we enforce it locally too)

enum SendblueOptOut {
    /// The carrier/TCPA stop keywords. Matched on the WHOLE normalized body only — a message that
    /// merely contains "stop" ("don't stop the campaign") is not an opt-out.
    static let stopKeywords: Set<String> = [
        "stop", "stopall", "unsubscribe", "cancel", "end", "quit", "revoke", "optout", "opt out", "opt-out"
    ]
    /// Opt-BACK-in keywords, so a buyer's contact can resubscribe.
    static let startKeywords: Set<String> = ["start", "unstop", "yes", "optin", "opt in", "opt-in"]

    private static func normalize(_ body: String) -> String {
        let stripped = body.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-"
        }
        return String(String.UnicodeScalarView(stripped)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isOptOut(_ body: String) -> Bool { stopKeywords.contains(normalize(body)) }
    static func isOptIn(_ body: String) -> Bool { startKeywords.contains(normalize(body)) }
}

// MARK: - the TCPA / suppression gate (pure; the chokepoint in Messaging.swift calls exactly this)

/// Why a message may not be sent. Every case is a truthful refusal the UI shows verbatim — none of
/// them is ever converted into a fake success.
enum MessageBlockReason: String, Equatable {
    case invalidNumber
    case emptyBody
    case tooLong
    case optedOut
    case suppressed
    case noConsent
    case quietHours
    case lineCapReached

    var detail: String {
        switch self {
        case .invalidNumber:  return "Not a dialable number — enter it in E.164 form (e.g. +15551234567)."
        case .emptyBody:      return "Nothing to send — the message body is empty."
        case .tooLong:        return "Over Sendblue's \(SendblueAPI.contentCharacterLimit)-character limit for one message."
        case .optedOut:       return "This number replied STOP. Texting it again is a TCPA violation, so the send is blocked."
        case .suppressed:     return "This contact is on your do-not-contact list."
        case .noConsent:      return "No recorded consent for this number. TCPA requires prior express consent before a marketing text — record it on the lead first."
        case .quietHours:     return "Outside the 8am–9pm local calling window (TCPA quiet hours). Schedule it for the morning."
        case .lineCapReached: return "This line hit the daily cap you set. Nothing was sent."
        }
    }
}

/// The facts a caller must supply for the gate. Explicit rather than reached-for, so the exact rule
/// is executable headlessly (same shape as `EmailSuppression.isSuppressed`).
struct MessageConsentFacts: Equatable {
    /// The buyer recorded prior express consent for this number (a CRM tag / opt-in record).
    var hasConsent: Bool = false
    /// This number sent a STOP (locally recorded, or seen on a Sendblue inbound webhook).
    var optedOut: Bool = false
    /// The buyer's do-not-contact list contains this number.
    var suppressed: Bool = false
    /// Sends already made on this line today, and the buyer's cap (0 = uncapped).
    var sentOnLineToday: Int = 0
    var dailyLineCap: Int = 0
}

enum MessagingGate {
    /// TCPA quiet hours: 8am–9pm in the recipient's local time. We only know the device's local
    /// hour, so this is the conservative approximation the UI states plainly.
    static let earliestHour = 8
    static let latestHour = 21

    static func withinCallingWindow(hour: Int) -> Bool { hour >= earliestHour && hour < latestHour }

    static func localHour(_ date: Date, calendar: Calendar = .current) -> Int {
        calendar.component(.hour, from: date)
    }

    /// The single decision. Returns nil when the send may proceed; otherwise the FIRST blocking
    /// reason, ordered most-serious-first so the message the buyer sees is the one that matters.
    static func block(number: String, body: String, facts: MessageConsentFacts,
                      now: Date = Date(), calendar: Calendar = .current,
                      enforceQuietHours: Bool = true) -> MessageBlockReason? {
        guard let e164 = PhoneNumber.e164(number), PhoneNumber.isE164(e164) else { return .invalidNumber }
        if facts.optedOut { return .optedOut }
        if facts.suppressed { return .suppressed }
        if !facts.hasConsent { return .noConsent }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .emptyBody }
        if body.count > SendblueAPI.contentCharacterLimit { return .tooLong }
        if facts.dailyLineCap > 0, facts.sentOnLineToday >= facts.dailyLineCap { return .lineCapReached }
        if enforceQuietHours, !withinCallingWindow(hour: localHour(now, calendar: calendar)) { return .quietHours }
        return nil
    }
}
