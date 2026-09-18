// Black Label Real Estate — BRING-YOUR-OWN skip-trace provider (on-device owner phone/email).
//
// The parity gap this closes: every competitor attaches a skip-traced phone + email to a saved
// lead. We refuse to fabricate contact info and we refuse to hold a buyer's owner-PII server-side
// (county OPTION A — the index ships public records only, no phone/email anywhere). This file is
// the honest, structural answer to both:
//
//   • The buyer connects THEIR OWN skip-trace provider key (BatchData's documented REST shape is
//     implemented today). Until a key is connected, the tier shows an honest "not configured"
//     state — never a faked number.
//   • Enrichment runs ON-DEVICE: the request goes straight to the buyer's provider host
//     (api.batchdata.com), authed with the buyer's own key. The resolved phone/email is appended
//     to the SAVED LEAD in the local store ONLY. It is never serialized into any request to
//     APIConfig.baseURL (api.blbestate.com) — see `SkipTraceProvider.egressHost` and the
//     `testNoPIIEgressToIndex` contract test. This converts the parity gap into the
//     LOCAL-PII-CUSTODY wedge: the buyer's owner contacts live on the buyer's machine, full stop.
//
// The request-builder and response-parser are PURE (no I/O), so the whole path is unit-tested with
// canned fixtures; only the transport is injected. Zero fabrication: an empty/failed trace yields
// no contact and an honest note — it never invents a phone, an email, or a match.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Vendor (the buyer's provider). Only real, documented shapes are wired.
// Two providers are wired so the waterfall (RE-15, SkipTraceWaterfall) can chain them under the
// buyer's OWN keys: BatchData first, then RocketSkip. Both authenticate a Bearer header on a JSON
// POST — but each has its own documented body shape, so buildRequest switches per vendor.
enum SkipTraceVendor: String, Codable, CaseIterable, Identifiable {
    case batchData
    case rocketSkip
    var id: String { rawValue }
    var label: String { switch self { case .batchData: return "BatchData"; case .rocketSkip: return "RocketSkip" } }
    /// The provider host every request is sent to. Deliberately NOT APIConfig.baseURL — a buyer's
    /// owner-PII trace never touches our index.
    var host: String {
        switch self { case .batchData: return "api.batchdata.com"; case .rocketSkip: return "api.rocketskip.com" }
    }
    var endpoint: URL {
        switch self {
        case .batchData: return URL(string: "https://api.batchdata.com/api/v1/property/skip-trace")!
        // RocketSkip documented endpoint (docs.rocketskip.com): POST /api/v1/property/skiptrace,
        // Bearer-authed, flat body {first_name,last_name,street_address,city,state,zip_code}.
        case .rocketSkip: return URL(string: "https://api.rocketskip.com/api/v1/property/skiptrace")!
        }
    }
    var signupHint: String {
        switch self {
        case .batchData: return "Create an API token in your BatchData dashboard (Settings → API), then paste it here."
        case .rocketSkip: return "Create an API token in your RocketSkip dashboard (API Keys), then paste it here."
        }
    }
}

// MARK: - Keychain store for the buyer's skip-trace key (secret at rest, never in the model/bundle).
// Mirrors ProviderKeychain (OutreachScreens): routes through RealEstateKeychain so the key lands in
// the DATA-PROTECTION keychain, keyed to the stable app identifier (no per-rebuild password prompt).
enum SkipTraceKeychain {
    // Per-vendor accounts so the buyer can connect MULTIPLE provider keys for the waterfall.
    // The pre-waterfall build stored the single BatchData key under `legacyAccount`; get(.batchData)
    // falls back to (and RealEstateKeychain.copy migrates forward) that legacy item so existing
    // buyers keep their key with no re-entry.
    private static let legacyAccount = "com.blacklabel.realestate.skiptrace"
    private static func account(_ vendor: SkipTraceVendor) -> String {
        "com.blacklabel.realestate.skiptrace.\(vendor.rawValue)"
    }
    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }

    static func set(_ key: String, vendor: SkipTraceVendor) {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = base(account(vendor))
        if t.isEmpty { RealEstateKeychain.delete(b) } else { RealEstateKeychain.set(b, data: Data(t.utf8)) }
    }
    static func get(vendor: SkipTraceVendor) -> String? {
        if let d = RealEstateKeychain.copy(base(account(vendor))), let s = String(data: d, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        // BatchData: migrate the legacy single-key account forward the first time it's read.
        if vendor == .batchData, let d = RealEstateKeychain.copy(base(legacyAccount)),
           let s = String(data: d, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { RealEstateKeychain.delete(base(legacyAccount)); set(t, vendor: .batchData); return t }
        }
        return nil
    }
    static func hasKey(vendor: SkipTraceVendor) -> Bool { get(vendor: vendor) != nil }
    static func clear(vendor: SkipTraceVendor) { RealEstateKeychain.delete(base(account(vendor))) }
    /// DESTRUCTIVE — removes EVERY connected skip-trace credential: each per-vendor item plus the
    /// pre-waterfall legacy single-key item (which `get` would otherwise migrate forward, silently
    /// resurrecting a key the user asked to delete). Backs account deletion.
    static func clearAll() {
        for vendor in SkipTraceVendor.allCases { clear(vendor: vendor) }
        RealEstateKeychain.delete(base(legacyAccount))
    }
    /// The provider chain the waterfall runs — every vendor with a connected key, in enum order.
    static func connectedVendors() -> [SkipTraceVendor] { SkipTraceVendor.allCases.filter { hasKey(vendor: $0) } }
    /// keyFor closure the waterfall injects (nil → that vendor is SKIPPED, never a miss).
    static func keyFor(_ vendor: SkipTraceVendor) -> String? { get(vendor: vendor) }

    // Legacy no-arg shims (default to BatchData) so pre-waterfall call sites keep compiling.
    static func set(_ key: String) { set(key, vendor: .batchData) }
    static func get() -> String? { get(vendor: .batchData) }
    static func hasKey() -> Bool { hasKey(vendor: .batchData) }
    static func clear() { clear(vendor: .batchData) }
}

// MARK: - What a provider trace produced (honest, may be empty).
struct SkipTraceContact: Hashable {
    var phones: [String] = []
    var emails: [String] = []
    var matchedName = ""
    var primaryPhone: String? { phones.first }
    var primaryEmail: String? { emails.first }
    var isEmpty: Bool { phones.isEmpty && emails.isEmpty }
}

enum SkipTraceProviderError: LocalizedError, Equatable {
    case notConfigured
    case badAddress
    case transport(String)
    case http(Int, String)
    case decode(String)
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No skip-trace provider connected. Add your provider API key in Settings to trace owner phone/email."
        case .badAddress: return "This lead has no mailing or property address to trace — resolve the parcel first."
        case .transport(let m): return "Couldn't reach your skip-trace provider (\(m)). Nothing was invented."
        case .http(let code, let body):
            if code == 401 || code == 403 { return "Your provider rejected the API key (HTTP \(code)). Check the key in Settings." }
            if (400...499).contains(code) { return "Your provider couldn't run that trace (HTTP \(code))." }
            return "Your provider had a temporary problem (HTTP \(code)). Try again shortly.\(body.isEmpty ? "" : "")"
        case .decode(let m): return "Your provider's response wasn't understood (\(m)). No contact was attached."
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum SkipTraceProvider {
    /// The host a provider trace is ALLOWED to reach. A trace request whose host is not this vendor
    /// host is a bug — owner PII must never leave for anywhere but the buyer's own provider.
    static func egressHost(_ vendor: SkipTraceVendor) -> String { vendor.host }

    typealias Send = (URLRequest) async throws -> (Data, URLResponse)
    static let liveSend: Send = { req in try await URLSession.shared.data(for: req) }

    // MARK: Request builder (pure). Sends ONLY to the buyer's vendor, Bearer-authed with their key.
    static func buildRequest(lead: Lead, vendor: SkipTraceVendor, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SkipTraceProviderError.notConfigured }
        let raw = lead.mailingAddress.trimmingCharacters(in: .whitespaces).isEmpty
            ? lead.propertyAddress : lead.mailingAddress
        let addr = raw.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty else { throw SkipTraceProviderError.badAddress }

        var req = URLRequest(url: vendor.endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BlackLabelRealEstate/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        let parts = AddressParts.parse(addr)
        let name = (lead.ownerName.isEmpty ? lead.name : lead.ownerName).trimmingCharacters(in: .whitespaces)
        let toks = name.split(separator: " ").map(String.init)
        let first = toks.count >= 2 ? toks.first! : ""
        let last = toks.count >= 2 ? toks.dropFirst().joined(separator: " ") : name

        switch vendor {
        case .batchData:
            var propertyAddress: [String: String] = [:]
            if !parts.street.isEmpty { propertyAddress["street"] = parts.street }
            if !parts.city.isEmpty { propertyAddress["city"] = parts.city }
            if !parts.state.isEmpty { propertyAddress["state"] = parts.state }
            if !parts.zip.isEmpty { propertyAddress["zip"] = parts.zip }
            var request: [String: Any] = ["propertyAddress": propertyAddress]
            if !name.isEmpty {
                request["name"] = first.isEmpty ? ["last": last] : ["first": first, "last": last]
            }
            // BatchData property/skip-trace body shape: {"requests":[{ propertyAddress, name }]}.
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["requests": [request]], options: [])
        case .rocketSkip:
            // RocketSkip documented flat body: {first_name,last_name,street_address,city,state,zip_code}.
            var body: [String: Any] = [:]
            if !parts.street.isEmpty { body["street_address"] = parts.street }
            if !parts.city.isEmpty { body["city"] = parts.city }
            if !parts.state.isEmpty { body["state"] = parts.state }
            if !parts.zip.isEmpty { body["zip_code"] = parts.zip }
            if !first.isEmpty { body["first_name"] = first }
            if !last.isEmpty { body["last_name"] = last }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        }
        return req
    }

    // MARK: Response parser (pure). Tolerant of BatchData's nested shape; never fabricates.
    static func parse(_ data: Data, vendor: SkipTraceVendor) throws -> SkipTraceContact {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SkipTraceProviderError.decode("not JSON")
        }
        var contact = SkipTraceContact()
        // Persons can appear at results.persons, results[].persons, or a bare persons[].
        let persons = collectPersons(root)
        for p in persons {
            if contact.matchedName.isEmpty, let nm = personName(p) { contact.matchedName = nm }
            for phone in stringsFrom(p["phoneNumbers"] ?? p["phones"], keys: ["number", "phone"]) {
                let clean = normalizePhone(phone)
                if !clean.isEmpty, !contact.phones.contains(clean) { contact.phones.append(clean) }
            }
            for email in stringsFrom(p["emails"], keys: ["email", "address"]) {
                let clean = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if clean.contains("@"), !contact.emails.contains(clean) { contact.emails.append(clean) }
            }
        }
        return contact
    }

    // MARK: On-device enrich (build → send → parse). Contacts may be empty (honest).
    static func enrich(lead: Lead, vendor: SkipTraceVendor, apiKey: String,
                       send: Send = liveSend) async throws -> SkipTraceContact {
        let req = try buildRequest(lead: lead, vendor: vendor, apiKey: apiKey)
        // Hard invariant: never send owner-address PII anywhere but the buyer's own provider host.
        guard req.url?.host == egressHost(vendor) else {
            throw SkipTraceProviderError.transport("blocked: trace host mismatch")
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await send(req) }
        catch { throw SkipTraceProviderError.transport(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw SkipTraceProviderError.transport("no response") }
        guard (200...299).contains(http.statusCode) else {
            throw SkipTraceProviderError.http(http.statusCode, String((String(data: data, encoding: .utf8) ?? "").prefix(160)))
        }
        return try parse(data, vendor: vendor)
    }

    // MARK: Attach to a lead LOCALLY (only fills blank contact fields; logs provenance).
    static func attach(_ contact: SkipTraceContact, to lead: Lead, vendorLabel: String) -> Lead {
        var l = lead
        var filled: [String] = []
        if l.phone.isEmpty, let p = contact.primaryPhone { l.phone = p; filled.append("phone") }
        if l.email.isEmpty, let e = contact.primaryEmail { l.email = e; filled.append("email") }
        if !filled.isEmpty {
            l.log(.note, "Skip-traced via \(vendorLabel) (your provider key) — attached \(filled.joined(separator: " + ")). Stored locally only.")
        }
        return l
    }

    // MARK: - parse helpers
    private static func collectPersons(_ root: [String: Any]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func harvest(_ any: Any?) {
            if let arr = any as? [[String: Any]] { out.append(contentsOf: arr) }
            else if let one = any as? [String: Any] { out.append(one) }
        }
        if let results = root["results"] as? [String: Any] {
            harvest(results["persons"])
            if let matches = results["matches"] as? [[String: Any]] { for m in matches { harvest(m["persons"]) } }
        }
        // RocketSkip: `results` is an ARRAY of person-like objects that carry the phones/emails
        // directly (no nested `persons`); append the result object itself so its contact fields parse.
        if let resultsArr = root["results"] as? [[String: Any]] {
            for r in resultsArr { harvest(r["persons"]); harvest(r["contacts"]); out.append(r) }
        }
        harvest(root["persons"])
        return out
    }
    private static func personName(_ p: [String: Any]) -> String? {
        if let n = p["name"] as? [String: Any] {
            let parts = ["first", "middle", "last"].compactMap { (n[$0] as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " ") }
        }
        if let s = p["name"] as? String, !s.isEmpty { return s }
        return nil
    }
    private static func stringsFrom(_ any: Any?, keys: [String]) -> [String] {
        guard let any else { return [] }
        var out: [String] = []
        if let arr = any as? [[String: Any]] {
            for item in arr { for k in keys { if let s = item[k] as? String { out.append(s) } } }
        } else if let arr = any as? [String] {
            out.append(contentsOf: arr)
        } else if let s = any as? String {
            out.append(s)
        }
        return out
    }
    private static func normalizePhone(_ s: String) -> String {
        let digits = s.filter { $0.isNumber }
        if digits.count == 11, digits.first == "1" { return String(digits.dropFirst()) }
        return digits.count >= 10 ? String(digits.suffix(10)) : (digits.isEmpty ? "" : digits)
    }
}
#endif // circuit-convert

// MARK: - Minimal US address splitter ("<street>, <city>, GA 30301" → parts). Tolerant.
struct AddressParts: Hashable {
    var street = ""
    var city = ""
    var state = ""
    var zip = ""
    static func parse(_ address: String) -> AddressParts {
        var p = AddressParts()
        let comps = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if comps.count >= 1 { p.street = comps[0] }
        if comps.count >= 3 {
            p.city = comps[1]
            let tail = comps[2].split(separator: " ").map(String.init)
            if let st = tail.first(where: { $0.count == 2 && $0.allSatisfy { $0.isLetter } }) { p.state = st.uppercased() }
            if let zip = tail.first(where: { $0.contains(where: { $0.isNumber }) && $0.count >= 5 }) { p.zip = String(zip.prefix(5)) }
        } else if comps.count == 2 {
            // "<street>, <city>" — no state/zip.
            p.city = comps[1]
        }
        return p
    }
}
