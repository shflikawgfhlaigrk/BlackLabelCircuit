// Black Label Marketing — BRING-YOUR-OWN email-finder provider (on-device "find missing emails").
//
// The parity gap this closes: every competitor "enriches" a lead by attaching a discovered work
// email. We refuse to fabricate an address, and we refuse to route a buyer's lead PII through OUR
// servers to do it. This file is the honest, structural answer to both — a direct mirror of Real
// Estate's SkipTraceProvider (BYO owner phone/email), adapted to name+domain → work email:
//
//   • The buyer connects THEIR OWN provider API key (Hunter's + Apollo's documented REST shapes are
//     implemented today). Until a key is connected, the tier shows an honest "not configured" state
//     — never a faked address (the Connectors chip only reads Connected with a real keyed provider).
//   • Enrichment runs ON-DEVICE: the request goes straight to the buyer's provider host
//     (api.hunter.io / api.apollo.io), authed with the buyer's own key. The resolved email is
//     appended to the SAVED LEAD in the local store ONLY. It is NEVER serialized into any request to
//     our own leads API — see `EnrichmentProviderClient.egressHost` and the no-PII-egress contract
//     test (a source scan that fails if any our-API host or lead-index client reference appears in
//     this file). This turns the parity gap into the LOCAL-PII-CUSTODY wedge: the buyer's lead
//     contacts live on the buyer's machine, full stop.
//
// The request-builder and response-parser are PURE (no I/O), so the whole path is unit-tested with
// canned fixtures; only the transport is injected. Zero fabrication: an empty/failed find yields no
// email and an honest note — it never invents an address, a score, or a match.
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Vendor (the buyer's provider). Only real, documented email-finder shapes are wired.
enum EnrichmentVendor: String, Codable, CaseIterable, Identifiable {
    case hunter
    case apollo
    case prospeo
    var id: String { rawValue }
    var label: String {
        switch self { case .hunter: return "Hunter.io"; case .apollo: return "Apollo"; case .prospeo: return "Prospeo" }
    }
    /// The provider host every request is sent to. Deliberately NOT our own leads API — a buyer's
    /// lead PII never touches our servers to enrich.
    var host: String {
        switch self {
        case .hunter: return "api.hunter.io"; case .apollo: return "api.apollo.io"; case .prospeo: return "api.prospeo.io"
        }
    }
    /// Hunter takes the key as a GET query arg; Apollo + Prospeo authenticate a header + JSON POST body.
    var usesPostBody: Bool { self != .hunter }
    /// The consent identity for this vendor (see Sources/ProviderConsent.swift). Lives here so
    /// adding a vendor is a compile error until its transmission disclosure exists.
    var transmissionProvider: TransmissionProvider {
        switch self {
        case .hunter:  return .hunter
        case .apollo:  return .apollo
        case .prospeo: return .prospeo
        }
    }
    var signupHint: String {
        switch self {
        case .hunter: return "Create an API key in your Hunter dashboard (Dashboard → API), then paste it here."
        case .apollo: return "Create an API key in your Apollo account (Settings → Integrations → API), then paste it here."
        case .prospeo: return "Create an API key in your Prospeo account (Dashboard → API), then paste it here."
        }
    }

    /// The vendor's API-key page itself. `signupHint` names the click-path; naming it is not the
    /// same as reaching it, so the panel opens this directly rather than leaving the buyer to find
    /// a settings screen on a marketing site. Verified 2026-08-12 — each resolves to the key page
    /// or the vendor's sign-in with a return link to it.
    var apiKeyURL: URL {
        switch self {
        case .hunter:  return URL(string: "https://hunter.io/api-keys")!
        case .apollo:  return URL(string: "https://app.apollo.io/#/settings/integrations/api")!
        case .prospeo: return URL(string: "https://app.prospeo.io/api")!
        }
    }
}

/// Map the buyer's chosen provider (EnrichmentConfig) to a wired finder vendor. Clearbit has no
/// documented name+domain → email finder, so it maps to nil — the action honestly says so rather
/// than fabricate a lookup it can't perform.
extension EnrichmentProvider {
    var finderVendor: EnrichmentVendor? {
        switch self { case .hunter: return .hunter; case .apollo: return .apollo; case .prospeo: return .prospeo; case .none, .clearbit: return nil }
    }
}

// MARK: - Keychain store for the buyer's enrichment key (secret at rest, never in the model/bundle).
// Routes through MarketingKeychain so the key lands in the data-protection keychain, keyed by vendor
// (stable across ad-hoc re-signs — no per-rebuild password prompt).
enum EnrichmentKeychain {
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").enrichment"
    }
    private static func base(_ vendor: EnrichmentVendor) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: vendor.rawValue]
    }
    static func set(_ key: String, vendor: EnrichmentVendor) {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { MarketingKeychain.delete(base(vendor)) }
        else { MarketingKeychain.set(base(vendor), data: Data(t.utf8), accessible: kSecAttrAccessibleWhenUnlocked) }
    }
    static func get(_ vendor: EnrichmentVendor) -> String? {
        guard let d = MarketingKeychain.copy(base(vendor), accessible: kSecAttrAccessibleWhenUnlocked,
                                             allowAuthenticationUI: false),
              let s = String(data: d, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    static func hasKey(_ vendor: EnrichmentVendor) -> Bool { get(vendor) != nil }
    static func clear(_ vendor: EnrichmentVendor) { MarketingKeychain.delete(base(vendor)) }
}

// MARK: - What a provider find produced (honest, may be empty).
struct EnrichmentResult: Hashable {
    var email = ""
    var confidence: Int?    // provider-reported 0–100 (Hunter score); nil when the provider gives none
    var vendorLabel = ""
    var isEmpty: Bool { email.isEmpty }
}

enum EnrichmentProviderError: LocalizedError, Equatable {
    case notConfigured
    case unsupportedProvider(String)
    case missingDomain
    case transport(String)
    case http(Int, String)
    case decode(String)
    case noMatch
    /// No recorded consent to send this lead's name + domain to the vendor.
    case consentRequired(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No enrichment provider connected. Paste your Hunter or Apollo API key in Connectors → Enrichment to find missing emails."
        case .unsupportedProvider(let p): return "\(p) doesn't offer a name→email finder. Switch to Hunter or Apollo in Connectors → Enrichment."
        case .missingDomain: return "This lead has no company domain to search — add a website/domain first. Nothing was invented."
        case .transport(let m): return "Couldn't reach your enrichment provider (\(m)). Nothing was invented."
        case .http(let code, _):
            if code == 401 || code == 403 { return "Your provider rejected the API key (HTTP \(code)). Check the key in Connectors → Enrichment." }
            if code == 429 { return "Your provider is rate-limiting (HTTP 429). Try again shortly." }
            if (400...499).contains(code) { return "Your provider couldn't run that lookup (HTTP \(code))." }
            return "Your provider had a temporary problem (HTTP \(code)). Try again shortly."
        case .decode(let m): return "Your provider's response wasn't understood (\(m)). No email was attached."
        case .noMatch: return "Your provider found no email for this contact. Nothing was invented."
        case .consentRequired(let refusal): return refusal
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum EnrichmentProviderClient {
    /// The host a find request is ALLOWED to reach. A request whose host is not this vendor host is a
    /// bug — lead PII must never leave for anywhere but the buyer's own provider.
    static func egressHost(_ vendor: EnrichmentVendor) -> String { vendor.host }

    typealias Send = (URLRequest) async throws -> (Data, URLResponse)
    /// Adapter so an injected `Send` (a test double, or the live one) is still reached THROUGH the
    /// egress choke point rather than instead of it — the consent decision happens above this.
    struct SendTransport: OutboundTransport {
        let send: Send
        func perform(_ request: URLRequest) async throws -> (Data, URLResponse) { try await send(request) }
    }
    /// The live sender is the choke point's own transport — this file constructs none.
    static let liveSend: Send = { req in try await ConsentedEgress.transport.perform(req) }

    // MARK: Request builder (pure). Sends ONLY to the buyer's vendor, authed with their key.
    static func buildRequest(name: String, domain rawDomain: String, vendor: EnrichmentVendor, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw EnrichmentProviderError.notConfigured }
        let domain = EmailEngine.normalizeDomain(rawDomain)
        guard !domain.isEmpty else { throw EnrichmentProviderError.missingDomain }
        let (first, last) = EmailEngine.splitName(name)

        switch vendor {
        case .hunter:
            var comps = URLComponents(string: "https://api.hunter.io/v2/email-finder")!
            var q = [URLQueryItem(name: "domain", value: domain), URLQueryItem(name: "api_key", value: key)]
            if !first.isEmpty { q.append(.init(name: "first_name", value: first)) }
            if !last.isEmpty { q.append(.init(name: "last_name", value: last)) }
            if first.isEmpty && last.isEmpty { q.append(.init(name: "full_name", value: name)) }
            comps.queryItems = q
            var req = URLRequest(url: comps.url!)
            req.timeoutInterval = 30
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("BlackLabelMarketing/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            return req
        case .apollo:
            var req = URLRequest(url: URL(string: "https://api.apollo.io/api/v1/people/match")!)
            req.timeoutInterval = 30
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "X-Api-Key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("BlackLabelMarketing/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            var body: [String: Any] = ["domain": domain, "reveal_personal_emails": false]
            if !first.isEmpty { body["first_name"] = first }
            if !last.isEmpty { body["last_name"] = last }
            if first.isEmpty && last.isEmpty { body["name"] = name }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
            return req
        case .prospeo:
            // Prospeo's Email Finder: POST with the key in X-KEY; `company` accepts a bare domain.
            var req = URLRequest(url: URL(string: "https://api.prospeo.io/email-finder")!)
            req.timeoutInterval = 30
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "X-KEY")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("BlackLabelMarketing/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            var body: [String: Any] = ["company": domain]
            if !first.isEmpty { body["first_name"] = first }
            if !last.isEmpty { body["last_name"] = last }
            if first.isEmpty && last.isEmpty { body["full_name"] = name }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
            return req
        }
    }

    // MARK: Response parser (pure). Tolerant of each vendor's shape; NEVER fabricates an address.
    static func parse(_ data: Data, vendor: EnrichmentVendor) throws -> EnrichmentResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EnrichmentProviderError.decode("not JSON")
        }
        var out = EnrichmentResult(vendorLabel: vendor.label)
        switch vendor {
        case .hunter:
            // { "data": { "email": "jane@acme.com", "score": 95 } }  — email is null on no match.
            guard let d = root["data"] as? [String: Any] else { throw EnrichmentProviderError.decode("no data object") }
            if let e = (d["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), e.contains("@") {
                out.email = e.lowercased()
                if let s = d["score"] as? Int { out.confidence = s }
                else if let s = d["score"] as? Double { out.confidence = Int(s) }
            }
        case .apollo:
            // { "person": { "email": "jane@acme.com" } }
            if let p = root["person"] as? [String: Any],
               let e = (p["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), e.contains("@") {
                out.email = e.lowercased()
            }
        case .prospeo:
            // { "error": false, "response": { "email": "jane@acme.com", "email_status": "VALID" } }
            // A miss yields `error:true` (or a null email); we surface no address then — never fabricated.
            if let resp = root["response"] as? [String: Any],
               let e = (resp["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), e.contains("@") {
                out.email = e.lowercased()
            }
        }
        // Reject provider "not-unlocked"/placeholder tokens — never surface a non-address as an email.
        if out.email.contains("email_not_unlocked") || out.email.hasPrefix("domain.com") { out.email = "" }
        return out
    }

    // MARK: On-device find (build → send → parse). Result may be empty (honest).
    static func find(name: String, domain: String, vendor: EnrichmentVendor, apiKey: String,
                     send: @escaping Send = liveSend) async throws -> EnrichmentResult {
        // Transmission consent: the contact's name and their company domain are lead PII about to
        // leave this Mac for a third-party vendor. No current recorded grant → no request is built
        // and nothing is sent. (Sources/ProviderConsent.swift.)
        if let refusal = TransmissionConsentStore.refusal(for: vendor.transmissionProvider) {
            throw EnrichmentProviderError.consentRequired(refusal)
        }
        let req = try buildRequest(name: name, domain: domain, vendor: vendor, apiKey: apiKey)
        // Hard invariant: never send lead PII anywhere but the buyer's own provider host.
        guard req.url?.host == egressHost(vendor) else {
            throw EnrichmentProviderError.transport("blocked: enrichment host mismatch")
        }
        let data: Data, resp: URLResponse
        // Through the choke point (Sources/ConsentedEgress.swift): it re-checks the grant itself,
        // and refuses outright if `req` somehow points anywhere but a host this vendor's registry
        // entry authorises. The check above is the caller-facing error; this one is the wall.
        do { (data, resp) = try await ConsentedEgress.send(req, to: vendor.transmissionProvider,
                                                           via: SendTransport(send: send)) }
        catch let refusal as ConsentedEgressError {
            throw EnrichmentProviderError.consentRequired(refusal.errorDescription ?? "Nothing was sent.")
        }
        catch {
            ConnectorVerificationStore.record(ConnectorVerificationStore.enrichment(vendor.rawValue), ok: false, detail: error.localizedDescription)
            throw EnrichmentProviderError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            ConnectorVerificationStore.record(ConnectorVerificationStore.enrichment(vendor.rawValue), ok: false, detail: "No HTTP response")
            throw EnrichmentProviderError.transport("no response")
        }
        guard (200...299).contains(http.statusCode) else {
            ConnectorVerificationStore.record(ConnectorVerificationStore.enrichment(vendor.rawValue), ok: false, detail: "HTTP \(http.statusCode)")
            throw EnrichmentProviderError.http(http.statusCode, String((String(data: data, encoding: .utf8) ?? "").prefix(160)))
        }
        let result = try parse(data, vendor: vendor)
        // A valid provider response proves the connector even when the person has no match.
        ConnectorVerificationStore.record(ConnectorVerificationStore.enrichment(vendor.rawValue), ok: true, detail: "Provider accepted the request")
        if result.isEmpty { throw EnrichmentProviderError.noMatch }
        return result
    }

    /// The on-device provenance note stamped into a lead when an email is attached (also the string
    /// a caller writes to the Activity timeline as `.enriched`). Pure so the UI + tests agree.
    static func provenanceNote(_ result: EnrichmentResult) -> String {
        let conf = result.confidence.map { " (confidence \($0)%)" } ?? ""
        return "Found email via \(result.vendorLabel) (your provider key)\(conf) — attached. Stored locally only, never sent to our servers."
    }

    // MARK: Attach to a lead LOCALLY (only fills a blank email; records provenance in `notes`). Stays
    // on device — the caller also logs an `.enriched` Activity. Returns (updatedLead, didFill).
    static func attach(_ result: EnrichmentResult, to lead: Lead) -> (lead: Lead, filled: Bool) {
        var l = lead
        guard l.email.isEmpty, !result.email.isEmpty else { return (l, false) }
        l.email = result.email
        let note = provenanceNote(result)
        l.notes = l.notes.isEmpty ? note : l.notes + "\n" + note
        return (l, true)
    }
}
#endif // circuit-convert
