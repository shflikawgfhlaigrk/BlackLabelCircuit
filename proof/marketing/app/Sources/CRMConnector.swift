// Black Label Marketing (lead engine, merged from Black Label Leads) — CRM connector (Tier-3 native connectors).
// A REAL field-mapping + two-way change-set engine for Salesforce / HubSpot / Pipedrive, gated behind
// a BYO-API-key "connect your CRM" state. We NEVER fake a sync: with no provider/credentials the UI
// shows an honest not-connected state and the always-available CSV export is the fallback. The pure
// mapping + diff layer (externalRecord / changeSet / exportCSV) is fully unit-tested, and the live
// push path now builds and executes real HTTPS requests against the buyer's selected CRM. The buyer's
// token is stored on-device; a status only turns connected after a real 2xx push succeeds. CSV export
// remains the no-credential fallback.
// TWO-WAY: the pull side (CRMPullClient/CRMPullEngine below) fetches remote contacts + deals from the
// buyer's own HubSpot / Pipedrive / Salesforce account, runs them through the SAME pure mapping +
// change-set engine, and merges with a never-destructive policy: create locally-missing, only apply a
// remote edit where the local value is untouched since the last sync (3-way snapshot base), fill empty
// local fields, NEVER delete locally, NEVER blank a local field. Every applied change-set is logged to
// the lead's activity timeline and an on-device JSONL ledger.
// On-device. The token lives in the Keychain (never in JSON, never shipped).
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension Notification.Name {
    static let blmLeadAdded = Notification.Name("com.blacklabel.marketing.leadAdded")
}

// MARK: - supported providers
enum CRMProvider: String, Codable, CaseIterable, Identifiable {
    case none, salesforce, hubspot, pipedrive
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "Not connected"; case .salesforce: return "Salesforce"
        case .hubspot: return "HubSpot"; case .pipedrive: return "Pipedrive"
        }
    }
    /// The consent identity for this CRM (see Sources/ProviderConsent.swift). `.none` has no
    /// destination, so it has nothing to disclose.
    var transmissionProvider: TransmissionProvider? {
        switch self {
        case .none: return nil
        case .salesforce: return .salesforce
        case .hubspot: return .hubspot
        case .pipedrive: return .pipedrive
        }
    }
    var icon: String {
        switch self {
        case .none: return "link.badge.plus"; case .salesforce: return "cloud.fill"
        case .hubspot: return "h.square.fill"; case .pipedrive: return "p.square.fill"
        }
    }
    /// Whether this provider needs an instance/portal URL (Salesforce instance, Pipedrive domain).
    var needsInstanceURL: Bool { self == .salesforce || self == .pipedrive }
    /// The doc URL the buyer follows to mint a personal API token (shown in the connect UI).
    var tokenHelp: String {
        switch self {
        case .salesforce: return "Setup → Create a Connected App / personal Access Token."
        case .hubspot:    return "Settings → Integrations → Private Apps → create an app, copy the token."
        case .pipedrive:  return "Settings → Personal preferences → API → copy your API token."
        case .none:       return ""
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - one field mapping (local prospect field → provider field name)
struct FieldMapping: Identifiable, Codable, Hashable {
    var id = UUID()
    var local: LocalField
    var remote: String        // the provider's field/property name
    var enabled: Bool = true

    enum LocalField: String, Codable, CaseIterable, Identifiable {
        case name, firstName, lastName, email, phone, company, domain, status, type, notes, address
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: return "Full name"; case .firstName: return "First name"; case .lastName: return "Last name"
            case .email: return "Email"; case .phone: return "Phone"; case .company: return "Company"
            case .domain: return "Domain"; case .status: return "Status"; case .type: return "Business type"
            case .notes: return "Notes"; case .address: return "Address"
            }
        }
        /// Extract the value of this local field from a prospect.
        func value(_ p: Lead) -> String {
            switch self {
            case .name:     return p.name
            case .firstName: return p.name.split(separator: " ").first.map(String.init) ?? ""
            case .lastName:
                let parts = p.name.split(separator: " ")
                return parts.count > 1 ? parts.dropFirst().joined(separator: " ") : p.name
            case .email:    return p.email
            case .phone:    return p.phone
            case .company:  return p.company
            case .domain:   return p.domain
            case .status:   return p.status.label
            case .type:     return p.type.label
            case .notes:    return p.notes
            case .address:  return p.address
            }
        }
    }
}
#endif // circuit-convert

// MARK: - a single detected change between local + remote (the 2-way diff unit)
struct CRMChange: Identifiable, Hashable {
    var id = UUID()
    let field: String       // remote field name
    let localValue: String
    let remoteValue: String
    var willPush: Bool = true   // direction: push local→remote (buyer can flip per change in the UI)
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - persisted connector config
struct CRMConnectorConfig: Codable, Hashable {
    var provider: CRMProvider = .none
    var instanceURL: String = ""        // e.g. https://acme.my.salesforce.com  or  acme.pipedrive.com
    var hasToken: Bool = false          // the token itself lives in the Keychain; this is a flag only
    var fieldMap: [FieldMapping] = []   // empty → use the provider default map
    var autoPushNewLeads: Bool = false  // push a lead to the CRM the moment it's created
    var lastSyncAt: Date? = nil
    var lastSyncCount: Int = 0          // real count from the last push (never fabricated)
    var lastPushOK: Bool? = nil         // nil until a live push has been attempted
    var lastPushMessage: String = ""
    // Two-way sync — pull side (all real, never fabricated).
    var autoPull: Bool = false          // pull remote changes automatically when the app foregrounds
    var lastPullAt: Date? = nil         // when the last pull completed (nil until one has run)
    var lastPullSummary: String = ""    // honest counts from that pull

    init() {}
    enum CodingKeys: String, CodingKey {
        case provider, instanceURL, hasToken, fieldMap, autoPushNewLeads, lastSyncAt, lastSyncCount, lastPushOK, lastPushMessage
        case autoPull, lastPullAt, lastPullSummary
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(CRMProvider.self, forKey: .provider)) ?? .none
        instanceURL = (try? c.decode(String.self, forKey: .instanceURL)) ?? ""
        hasToken = (try? c.decode(Bool.self, forKey: .hasToken)) ?? false
        fieldMap = (try? c.decode([FieldMapping].self, forKey: .fieldMap)) ?? []
        autoPushNewLeads = (try? c.decode(Bool.self, forKey: .autoPushNewLeads)) ?? false
        lastSyncAt = try? c.decode(Date.self, forKey: .lastSyncAt)
        lastSyncCount = (try? c.decode(Int.self, forKey: .lastSyncCount)) ?? 0
        lastPushOK = try? c.decode(Bool.self, forKey: .lastPushOK)
        lastPushMessage = (try? c.decode(String.self, forKey: .lastPushMessage)) ?? ""
        autoPull = (try? c.decode(Bool.self, forKey: .autoPull)) ?? false
        lastPullAt = try? c.decode(Date.self, forKey: .lastPullAt)
        lastPullSummary = (try? c.decode(String.self, forKey: .lastPullSummary)) ?? ""
    }

    /// Configured means the buyer selected a provider and supplied the fields needed to attempt a real API call.
    var isConfigured: Bool {
        guard provider != .none, hasToken else { return false }
        if provider.needsInstanceURL { return !instanceURL.trimmingCharacters(in: .whitespaces).isEmpty }
        return true
    }
    /// Honest connection check — green ONLY after a real live push returned 2xx.
    var isConnected: Bool { isConfigured && lastPushOK == true }
    /// The effective mapping (configured, or the provider default).
    var effectiveMap: [FieldMapping] { fieldMap.isEmpty ? CRMMapping.defaultMap(for: provider) : fieldMap }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - the pure mapping + diff + export engine (no network — fully testable)
enum CRMMapping {
    /// Sensible per-provider default field map (the real field/property names each CRM expects).
    static func defaultMap(for provider: CRMProvider) -> [FieldMapping] {
        switch provider {
        case .salesforce:
            return [ FieldMapping(local: .firstName, remote: "FirstName"), FieldMapping(local: .lastName, remote: "LastName"),
                     FieldMapping(local: .email, remote: "Email"),
                     FieldMapping(local: .phone, remote: "Phone"), FieldMapping(local: .company, remote: "Company"),
                     FieldMapping(local: .notes, remote: "Description") ]
        case .hubspot:
            return [ FieldMapping(local: .firstName, remote: "firstname"), FieldMapping(local: .lastName, remote: "lastname"),
                     FieldMapping(local: .email, remote: "email"), FieldMapping(local: .phone, remote: "phone"),
                     FieldMapping(local: .company, remote: "company"), FieldMapping(local: .domain, remote: "website") ]
        case .pipedrive:
            return [ FieldMapping(local: .name, remote: "name"), FieldMapping(local: .email, remote: "email"),
                     FieldMapping(local: .phone, remote: "phone"), FieldMapping(local: .company, remote: "org_name") ]
        case .none:
            return []
        }
    }

    /// Build the external record (provider-field → value) for a prospect under a mapping.
    static func externalRecord(for p: Lead, mapping: [FieldMapping], provider: CRMProvider) -> [String: String] {
        let map = mapping.isEmpty ? defaultMap(for: provider) : mapping
        var rec: [String: String] = [:]
        for m in map where m.enabled {
            let v = m.local.value(p)
            if !v.isEmpty { rec[m.remote] = v }
        }
        return rec
    }

    /// Compute the grounded change-set between a local prospect and a remote record. Only real
    /// differences are returned — identical values produce NO change (no fabricated/no-op syncs).
    static func changeSet(local p: Lead, remote: [String: String], mapping: [FieldMapping], provider: CRMProvider) -> [CRMChange] {
        let mine = externalRecord(for: p, mapping: mapping, provider: provider)
        var out: [CRMChange] = []
        for (field, localVal) in mine {
            let remoteVal = remote[field] ?? ""
            if localVal != remoteVal { out.append(CRMChange(field: field, localValue: localVal, remoteValue: remoteVal)) }
        }
        return out.sorted { $0.field < $1.field }
    }

    /// RFC 4180 CSV export — the always-available fallback that needs NO provider/credentials.
    static func exportCSV(_ leads: [Lead]) -> String {
        let headers = ["name", "company", "email", "phone", "domain", "status", "type", "address", "tags", "notes"]
        func esc(_ s: String) -> String {
            if s.contains(",") || s.contains("\"") || s.contains("\n") {
                return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return s
        }
        var rows = [headers.joined(separator: ",")]
        for p in leads {
            let cells = [p.name, p.company, p.email, p.phone, p.domain, p.status.label, p.type.label,
                         p.address, p.tags.joined(separator: "|"), p.notes]
            rows.append(cells.map(esc).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
}
#endif // circuit-convert

// MARK: - live CRM push client
struct CRMPushResult: Hashable {
    let provider: CRMProvider
    let statusCode: Int
    let remoteID: String?
    let detail: String
}

enum CRMConnectorError: LocalizedError {
    case notConfigured
    case missingToken
    case badRequest(String)
    case transport(String)
    case http(Int, String)
    case decode(String)
    /// No recorded consent to transmit lead records to this CRM.
    case consentRequired(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Choose a CRM provider and save its required settings first."
        case .missingToken:
            return "Paste and save the CRM API token first."
        case .badRequest(let message), .transport(let message), .decode(let message),
             .consentRequired(let message):
            return message
        case .http(let code, let message):
            return "CRM returned HTTP \(code)\(message.isEmpty ? "" : ": \(message)")"
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum CRMConnectorClient {
    private static let salesforceAPIVersion = "v61.0"

    /// A lead push/pull ships real people's names, emails, phones, companies and your notes to a
    /// third party (and the access token with them). Every networked CRM entry point calls this
    /// first: no explicit, current grant → nothing leaves. (Sources/ProviderConsent.swift.)
    static func requireTransmissionConsent(_ config: CRMConnectorConfig) throws {
        guard let provider = config.provider.transmissionProvider else { return }
        if let refusal = TransmissionConsentStore.refusal(for: provider) {
            throw CRMConnectorError.consentRequired(refusal)
        }
    }

    static func buildCreateLeadRequest(for lead: Lead, config: CRMConnectorConfig, token: String) -> URLRequest? {
        buildCreateRequest(provider: config.provider,
                           instanceURL: config.instanceURL,
                           token: token,
                           record: CRMMapping.externalRecord(for: lead, mapping: config.effectiveMap, provider: config.provider))
    }

    static func buildCreateRequest(provider: CRMProvider,
                                   instanceURL: String,
                                   token rawToken: String,
                                   record rawRecord: [String: String]) -> URLRequest? {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard provider != .none, !token.isEmpty else { return nil }
        let record = rawRecord.filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        switch provider {
        case .hubspot:
            guard let url = URL(string: "https://api.hubapi.com/crm/v3/objects/contacts") else { return nil }
            return jsonRequest(url: url, bearer: token, body: ["properties": record])

        case .salesforce:
            guard let base = normalizedBaseURL(instanceURL),
                  var comps = URLComponents(url: base.appendingPathComponent("services")
                                                    .appendingPathComponent("data")
                                                    .appendingPathComponent(salesforceAPIVersion)
                                                    .appendingPathComponent("sobjects")
                                                    .appendingPathComponent("Lead"),
                                            resolvingAgainstBaseURL: false),
                  comps.scheme == "https",
                  let url = comps.url,
                  let lastName = record["LastName"], !lastName.isEmpty,
                  let company = record["Company"], !company.isEmpty else { return nil }
            comps.queryItems = nil
            return jsonRequest(url: url, bearer: token, body: record)

        case .pipedrive:
            guard let base = normalizedBaseURL(instanceURL),
                  var comps = URLComponents(url: base.appendingPathComponent("api")
                                                    .appendingPathComponent("v1")
                                                    .appendingPathComponent("persons"),
                                            resolvingAgainstBaseURL: false),
                  comps.scheme == "https" else { return nil }
            comps.queryItems = [URLQueryItem(name: "api_token", value: token)]
            guard let url = comps.url, !record.isEmpty else { return nil }
            return jsonRequest(url: url, bearer: nil, body: record)

        case .none:
            return nil
        }
    }

    static func pushLead(_ lead: Lead, config: CRMConnectorConfig) async throws -> CRMPushResult {
        guard config.isConfigured else { throw CRMConnectorError.notConfigured }
        try requireTransmissionConsent(config)
        let account = CRMConnectorKeychain.account(for: config)
        guard let token = CRMConnectorKeychain.token(account: account) else { throw CRMConnectorError.missingToken }
        guard let request = buildCreateLeadRequest(for: lead, config: config, token: token) else {
            throw CRMConnectorError.badRequest("Couldn't build the CRM request. Check required fields for \(config.provider.label).")
        }

        let data: Data
        let response: URLResponse
        do {
            // Through the choke point: it consults the consent gate itself, and refuses if the
            // buyer-typed instance host is not under the suffix their grant disclosed.
            (data, response) = try await ConsentedEgress.send(request, to: config.provider.transmissionProvider)
        } catch let refusal as ConsentedEgressError {
            throw CRMConnectorError.consentRequired(refusal.errorDescription ?? "Nothing was sent.")
        } catch {
            throw CRMConnectorError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CRMConnectorError.transport("CRM did not return an HTTP response.")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200...299).contains(http.statusCode) else {
            throw CRMConnectorError.http(http.statusCode, String(body.prefix(240)))
        }
        return CRMPushResult(provider: config.provider,
                             statusCode: http.statusCode,
                             remoteID: remoteID(from: data, provider: config.provider),
                             detail: body.isEmpty ? "Created in \(config.provider.label)." : String(body.prefix(240)))
    }

    static func normalizedBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: withScheme), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func jsonRequest(url: URL, bearer: String?, body: Any) -> URLRequest? {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: []) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BlackLabelMarketing/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = data
        return request
    }

    private static func remoteID(from data: Data, provider: CRMProvider) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let id = json["id"] as? String { return id }
        if let id = json["id"] as? Int { return String(id) }
        if let data = json["data"] as? [String: Any] {
            if let id = data["id"] as? String { return id }
            if let id = data["id"] as? Int { return String(id) }
        }
        if let success = json["success"] as? Bool, success == true { return provider.label }
        return nil
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Keychain for the connector token (on-device only, never shipped)
enum CRMConnectorKeychain {
    private static let service = "com.blacklabel.leads.crmconnector"
    static func account(for config: CRMConnectorConfig) -> String {
        account(provider: config.provider, instanceURL: config.instanceURL)
    }
    static func account(provider: CRMProvider, instanceURL: String = "") -> String {
        let normalizedInstance = instanceURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedInstance.isEmpty ? provider.rawValue : "\(provider.rawValue):\(normalizedInstance)"
    }
    static func setToken(_ token: String, account: String) {
        guard !token.isEmpty, !account.isEmpty else { delete(account: account); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account ]
        // Data-protection keychain (stable across ad-hoc re-signs); set() clears both first.
        MarketingKeychain.set(base, data: Data(token.utf8), accessible: kSecAttrAccessibleWhenUnlocked)
    }
    static func token(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account ]
        guard let data = MarketingKeychain.copy(base, accessible: kSecAttrAccessibleWhenUnlocked,
                                                allowAuthenticationUI: false),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
    static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account ]
        MarketingKeychain.delete(q)
    }
}
#endif // circuit-convert

// MARK: ==================== TWO-WAY SYNC — THE PULL SIDE ====================
// Everything below reads the buyer's OWN CRM over their token and merges into the local
// workspace with a never-destructive policy. No fabricated records: every lead/deal that
// appears locally is a real remote record, and every applied change is logged + ledgered.

// MARK: - remote records (provider-field namespace, same one the push mapping uses)
struct CRMRemoteContact: Hashable {
    let remoteID: String
    /// Provider field name → value, restricted to the buyer's enabled field map — so the
    /// EXISTING pure change-set engine (CRMMapping.changeSet) can diff a remote contact
    /// against a local lead with zero translation.
    let fields: [String: String]
    let updatedAt: Date?
}

struct CRMRemoteDeal: Hashable {
    let remoteID: String
    let title: String
    let value: Double?
    let contactRemoteIDs: [String]   // remote contact/person ids this deal is attached to
    let updatedAt: Date?
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - live pull client (real paged HTTPS GETs against the buyer's CRM)
enum CRMPullClient {
    static let pageSize = 100
    /// Hard page cap so one pull can never spin unbounded on a huge CRM. When the cap is
    /// hit the plan says so and the sync cursor is NOT advanced (nothing silently missed).
    static let maxPages = 25
    private static let salesforceAPIVersion = "v61.0"

    // MARK: date parsing (HubSpot ISO8601(.sss), Salesforce ISO+offset, Pipedrive "yyyy-MM-dd HH:mm:ss")
    private static let isoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static let iso = ISO8601DateFormatter()
    private static let salesforceTime: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"; return f
    }()
    private static let pipedriveTime: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()
    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return isoFraction.date(from: s) ?? iso.date(from: s) ?? salesforceTime.date(from: s) ?? pipedriveTime.date(from: s)
    }
    static func soqlDate(_ d: Date) -> String { iso.string(from: d) }

    // MARK: JSON value flattening (Pipedrive email/phone are [{value:,primary:}] arrays; org/person are objects)
    static func flatten(_ raw: Any?) -> String {
        switch raw {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        case let arr as [[String: Any]]:
            let primary = arr.first { ($0["primary"] as? Bool) == true } ?? arr.first
            return flatten(primary?["value"] ?? primary?["name"])
        case let dict as [String: Any]:
            return flatten(dict["name"] ?? dict["value"])
        default: return ""
        }
    }
    static func flattenID(_ raw: Any?) -> String? {
        if let s = raw as? String, !s.isEmpty { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: shared GET
    /// Every CRM read goes through here, and `provider` is REQUIRED — the choke point refuses an
    /// unattributed request rather than letting it through, so a future pull path cannot reach the
    /// network by simply forgetting to say whose CRM it is talking to.
    private static func getJSON(_ url: URL, bearer: String?,
                                provider: TransmissionProvider?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("BlackLabelMarketing/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await ConsentedEgress.send(request, to: provider) }
        catch let refusal as ConsentedEgressError { throw CRMConnectorError.consentRequired(refusal.errorDescription ?? "Nothing was sent.") }
        catch { throw CRMConnectorError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else {
            throw CRMConnectorError.transport("CRM did not return an HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CRMConnectorError.http(http.statusCode, String(body.prefix(240)))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CRMConnectorError.decode("Couldn't decode the CRM response as JSON.")
        }
        return json
    }

    // MARK: - contacts / persons
    static func fetchContacts(config: CRMConnectorConfig, token: String,
                              updatedAfter: Date?) async throws -> (contacts: [CRMRemoteContact], truncated: Bool) {
        let mapping = config.effectiveMap.filter { $0.enabled }
        switch config.provider {
        case .hubspot:    return try await hubspotContacts(mapping: mapping, token: token, updatedAfter: updatedAfter)
        case .pipedrive:  return try await pipedrivePersons(config: config, mapping: mapping, token: token, updatedAfter: updatedAfter)
        case .salesforce: return try await salesforceContacts(config: config, mapping: mapping, token: token, updatedAfter: updatedAfter)
        case .none:       throw CRMConnectorError.notConfigured
        }
    }

    // MARK: - deals / opportunities
    static func fetchDeals(config: CRMConnectorConfig, token: String,
                           updatedAfter: Date?) async throws -> (deals: [CRMRemoteDeal], truncated: Bool) {
        switch config.provider {
        case .hubspot:    return try await hubspotDeals(token: token, updatedAfter: updatedAfter)
        case .pipedrive:  return try await pipedriveDeals(config: config, token: token, updatedAfter: updatedAfter)
        case .salesforce: return try await salesforceOpportunities(config: config, token: token, updatedAfter: updatedAfter)
        case .none:       throw CRMConnectorError.notConfigured
        }
    }

    // MARK: HubSpot — GET /crm/v3/objects/contacts with paging; updatedAfter applied on updatedAt
    private static func hubspotContacts(mapping: [FieldMapping], token: String,
                                        updatedAfter: Date?) async throws -> ([CRMRemoteContact], Bool) {
        let props = Set(mapping.map(\.remote)).sorted().joined(separator: ",")
        var out: [CRMRemoteContact] = []
        var after: String? = nil
        var pages = 0
        var truncated = false
        repeat {
            guard var comps = URLComponents(string: "https://api.hubapi.com/crm/v3/objects/contacts") else {
                throw CRMConnectorError.badRequest("Couldn't build the HubSpot contacts URL.")
            }
            var items = [URLQueryItem(name: "limit", value: "\(pageSize)"),
                         URLQueryItem(name: "archived", value: "false"),
                         URLQueryItem(name: "properties", value: props)]
            if let after { items.append(URLQueryItem(name: "after", value: after)) }
            comps.queryItems = items
            guard let url = comps.url else { throw CRMConnectorError.badRequest("Couldn't build the HubSpot contacts URL.") }
            let root = try await getJSON(url, bearer: token, provider: .hubspot)
            for r in (root["results"] as? [[String: Any]]) ?? [] {
                guard let id = flattenID(r["id"]) else { continue }
                let properties = r["properties"] as? [String: Any] ?? [:]
                var fields: [String: String] = [:]
                for m in mapping {
                    let v = flatten(properties[m.remote])
                    if !v.isEmpty { fields[m.remote] = v }
                }
                let updated = parseDate(r["updatedAt"] as? String)
                if let updatedAfter, let updated, updated <= updatedAfter { continue }
                out.append(CRMRemoteContact(remoteID: id, fields: fields, updatedAt: updated))
            }
            after = ((root["paging"] as? [String: Any])?["next"] as? [String: Any])?["after"] as? String
            pages += 1
            if pages >= maxPages && after != nil { truncated = true; after = nil }
        } while after != nil
        return (out, truncated)
    }

    private static func hubspotDeals(token: String, updatedAfter: Date?) async throws -> ([CRMRemoteDeal], Bool) {
        var out: [CRMRemoteDeal] = []
        var after: String? = nil
        var pages = 0
        var truncated = false
        repeat {
            guard var comps = URLComponents(string: "https://api.hubapi.com/crm/v3/objects/deals") else {
                throw CRMConnectorError.badRequest("Couldn't build the HubSpot deals URL.")
            }
            var items = [URLQueryItem(name: "limit", value: "\(pageSize)"),
                         URLQueryItem(name: "archived", value: "false"),
                         URLQueryItem(name: "properties", value: "dealname,amount"),
                         URLQueryItem(name: "associations", value: "contacts")]
            if let after { items.append(URLQueryItem(name: "after", value: after)) }
            comps.queryItems = items
            guard let url = comps.url else { throw CRMConnectorError.badRequest("Couldn't build the HubSpot deals URL.") }
            let root = try await getJSON(url, bearer: token, provider: .hubspot)
            for r in (root["results"] as? [[String: Any]]) ?? [] {
                guard let id = flattenID(r["id"]) else { continue }
                let properties = r["properties"] as? [String: Any] ?? [:]
                let contactIDs = ((((r["associations"] as? [String: Any])?["contacts"] as? [String: Any])?["results"] as? [[String: Any]]) ?? [])
                    .compactMap { flattenID($0["id"]) }
                let updated = parseDate(r["updatedAt"] as? String)
                if let updatedAfter, let updated, updated <= updatedAfter { continue }
                out.append(CRMRemoteDeal(remoteID: id,
                                         title: flatten(properties["dealname"]),
                                         value: Double(flatten(properties["amount"])),
                                         contactRemoteIDs: contactIDs,
                                         updatedAt: updated))
            }
            after = ((root["paging"] as? [String: Any])?["next"] as? [String: Any])?["after"] as? String
            pages += 1
            if pages >= maxPages && after != nil { truncated = true; after = nil }
        } while after != nil
        return (out, truncated)
    }

    // MARK: Pipedrive — GET /api/v1/persons + /deals with start/limit paging; updatedAfter on update_time
    private static func pipedriveURL(config: CRMConnectorConfig, token: String, path: String,
                                     start: Int) throws -> URL {
        guard let base = CRMConnectorClient.normalizedBaseURL(config.instanceURL) else {
            throw CRMConnectorError.badRequest("Add your Pipedrive domain first.")
        }
        guard var comps = URLComponents(url: base.appendingPathComponent("api")
                                                .appendingPathComponent("v1")
                                                .appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false),
              comps.scheme == "https" else {
            throw CRMConnectorError.badRequest("Couldn't build the Pipedrive URL.")
        }
        comps.queryItems = [URLQueryItem(name: "start", value: "\(start)"),
                            URLQueryItem(name: "limit", value: "\(pageSize)"),
                            URLQueryItem(name: "api_token", value: token)]
        guard let url = comps.url else { throw CRMConnectorError.badRequest("Couldn't build the Pipedrive URL.") }
        return url
    }

    private static func pipedrivePersons(config: CRMConnectorConfig, mapping: [FieldMapping], token: String,
                                         updatedAfter: Date?) async throws -> ([CRMRemoteContact], Bool) {
        var out: [CRMRemoteContact] = []
        var start = 0
        var more = true
        var pages = 0
        var truncated = false
        while more {
            let root = try await getJSON(try pipedriveURL(config: config, token: token, path: "persons", start: start), bearer: nil, provider: .pipedrive)
            for r in (root["data"] as? [[String: Any]]) ?? [] {
                guard let id = flattenID(r["id"]) else { continue }
                var fields: [String: String] = [:]
                for m in mapping {
                    let v = flatten(r[m.remote])
                    if !v.isEmpty { fields[m.remote] = v }
                }
                let updated = parseDate(r["update_time"] as? String)
                if let updatedAfter, let updated, updated <= updatedAfter { continue }
                out.append(CRMRemoteContact(remoteID: id, fields: fields, updatedAt: updated))
            }
            let pagination = (root["additional_data"] as? [String: Any])?["pagination"] as? [String: Any]
            more = (pagination?["more_items_in_collection"] as? Bool) ?? false
            start = (pagination?["next_start"] as? Int) ?? (start + pageSize)
            pages += 1
            if pages >= maxPages && more { truncated = true; more = false }
        }
        return (out, truncated)
    }

    private static func pipedriveDeals(config: CRMConnectorConfig, token: String,
                                       updatedAfter: Date?) async throws -> ([CRMRemoteDeal], Bool) {
        var out: [CRMRemoteDeal] = []
        var start = 0
        var more = true
        var pages = 0
        var truncated = false
        while more {
            let root = try await getJSON(try pipedriveURL(config: config, token: token, path: "deals", start: start), bearer: nil, provider: .pipedrive)
            for r in (root["data"] as? [[String: Any]]) ?? [] {
                guard let id = flattenID(r["id"]) else { continue }
                var contactIDs: [String] = []
                if let n = r["person_id"] as? NSNumber { contactIDs = [n.stringValue] }
                else if let d = r["person_id"] as? [String: Any], let v = flattenID(d["value"]) { contactIDs = [v] }
                let updated = parseDate(r["update_time"] as? String)
                if let updatedAfter, let updated, updated <= updatedAfter { continue }
                out.append(CRMRemoteDeal(remoteID: id,
                                         title: flatten(r["title"]),
                                         value: (r["value"] as? NSNumber)?.doubleValue,
                                         contactRemoteIDs: contactIDs,
                                         updatedAt: updated))
            }
            let pagination = (root["additional_data"] as? [String: Any])?["pagination"] as? [String: Any]
            more = (pagination?["more_items_in_collection"] as? Bool) ?? false
            start = (pagination?["next_start"] as? Int) ?? (start + pageSize)
            pages += 1
            if pages >= maxPages && more { truncated = true; more = false }
        }
        return (out, truncated)
    }

    // MARK: Salesforce — query API on Contact / Opportunity with a SystemModstamp filter
    /// Only bare SOQL identifiers from the buyer's field map are allowed into the SELECT list —
    /// anything else (spaces, quotes, dots) is dropped, so a hand-edited mapping can't inject SOQL.
    private static func soqlIdentifier(_ s: String) -> String? {
        s.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil ? s : nil
    }

    private static func salesforceQuery(config: CRMConnectorConfig, token: String,
                                        soql: String) async throws -> ([[String: Any]], Bool) {
        guard let base = CRMConnectorClient.normalizedBaseURL(config.instanceURL) else {
            throw CRMConnectorError.badRequest("Add your Salesforce instance URL first.")
        }
        var records: [[String: Any]] = []
        var nextPath: String? = nil
        var pages = 0
        var truncated = false
        repeat {
            let url: URL
            if let p = nextPath {
                guard let u = URL(string: p, relativeTo: base)?.absoluteURL else {
                    throw CRMConnectorError.decode("Salesforce returned an unusable next-page URL.")
                }
                url = u
            } else {
                guard var comps = URLComponents(url: base.appendingPathComponent("services")
                                                        .appendingPathComponent("data")
                                                        .appendingPathComponent(salesforceAPIVersion)
                                                        .appendingPathComponent("query"),
                                                resolvingAgainstBaseURL: false),
                      comps.scheme == "https" else {
                    throw CRMConnectorError.badRequest("Couldn't build the Salesforce query URL.")
                }
                comps.queryItems = [URLQueryItem(name: "q", value: soql)]
                guard let u = comps.url else { throw CRMConnectorError.badRequest("Couldn't build the Salesforce query URL.") }
                url = u
            }
            let root = try await getJSON(url, bearer: token, provider: .salesforce)
            records.append(contentsOf: (root["records"] as? [[String: Any]]) ?? [])
            let done = (root["done"] as? Bool) ?? true
            nextPath = done ? nil : root["nextRecordsUrl"] as? String
            pages += 1
            if pages >= maxPages && nextPath != nil { truncated = true; nextPath = nil }
        } while nextPath != nil
        return (records, truncated)
    }

    private static func salesforceContacts(config: CRMConnectorConfig, mapping: [FieldMapping], token: String,
                                           updatedAfter: Date?) async throws -> ([CRMRemoteContact], Bool) {
        // The push maps "Company" onto the Lead sobject; on Contact the equivalent is the related
        // Account's name — pulled as Account.Name and stored back under the mapping's "Company"
        // key so the diff engine keeps one field namespace.
        var select = ["Id", "SystemModstamp"]
        var companyViaAccount = false
        for m in mapping {
            if m.remote == "Company" { companyViaAccount = true; continue }
            if let f = soqlIdentifier(m.remote), !select.contains(f) { select.append(f) }
        }
        if companyViaAccount { select.append("Account.Name") }
        var soql = "SELECT \(select.joined(separator: ", ")) FROM Contact"
        if let updatedAfter { soql += " WHERE SystemModstamp > \(soqlDate(updatedAfter))" }
        soql += " ORDER BY SystemModstamp ASC"

        let (records, truncated) = try await salesforceQuery(config: config, token: token, soql: soql)
        var out: [CRMRemoteContact] = []
        for r in records {
            guard let id = r["Id"] as? String else { continue }
            var fields: [String: String] = [:]
            for m in mapping {
                let v: String
                if m.remote == "Company" { v = flatten((r["Account"] as? [String: Any])?["Name"]) }
                else { v = flatten(r[m.remote]) }
                if !v.isEmpty { fields[m.remote] = v }
            }
            out.append(CRMRemoteContact(remoteID: id, fields: fields,
                                        updatedAt: parseDate(r["SystemModstamp"] as? String)))
        }
        return (out, truncated)
    }

    private static func salesforceOpportunities(config: CRMConnectorConfig, token: String,
                                                updatedAfter: Date?) async throws -> ([CRMRemoteDeal], Bool) {
        var soql = "SELECT Id, Name, Amount, SystemModstamp, (SELECT ContactId FROM OpportunityContactRoles) FROM Opportunity"
        if let updatedAfter { soql += " WHERE SystemModstamp > \(soqlDate(updatedAfter))" }
        soql += " ORDER BY SystemModstamp ASC"
        let (records, truncated) = try await salesforceQuery(config: config, token: token, soql: soql)
        var out: [CRMRemoteDeal] = []
        for r in records {
            guard let id = r["Id"] as? String else { continue }
            let roles = ((r["OpportunityContactRoles"] as? [String: Any])?["records"] as? [[String: Any]]) ?? []
            out.append(CRMRemoteDeal(remoteID: id,
                                     title: flatten(r["Name"]),
                                     value: (r["Amount"] as? NSNumber)?.doubleValue,
                                     contactRemoteIDs: roles.compactMap { $0["ContactId"] as? String },
                                     updatedAt: parseDate(r["SystemModstamp"] as? String)))
        }
        return (out, truncated)
    }
}
#endif // circuit-convert

// MARK: - persisted per-provider sync state: remote-id ↔ local-id links + cursors
// Lead deliberately has NO remote-id field (LeadDomain is untouched) — the mapping lives here,
// in an on-device JSON index keyed by the same Keychain account string the token uses.
struct CRMContactLink: Codable, Hashable {
    var remoteID: String
    var localID: UUID
    /// The remote record's mapped fields as of the last sync — the 3-way merge base. A pull only
    /// overwrites a local field whose value still equals this base (the buyer hasn't edited it
    /// since); everything else keeps the local edit.
    var snapshot: [String: String] = [:]
    var lastSyncedAt: Date = Date()
}

struct CRMDealLink: Codable, Hashable {
    var remoteID: String
    var localID: UUID
    var lastSyncedAt: Date = Date()
}

struct CRMSyncState: Codable {
    var contactCursor: Date? = nil     // max remote updatedAt seen → next pull's updatedAfter
    var dealCursor: Date? = nil
    var contactLinks: [CRMContactLink] = []
    var dealLinks: [CRMDealLink] = []

    init() {}
    enum CodingKeys: String, CodingKey { case contactCursor, dealCursor, contactLinks, dealLinks }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        contactCursor = try? c.decode(Date.self, forKey: .contactCursor)
        dealCursor = try? c.decode(Date.self, forKey: .dealCursor)
        contactLinks = (try? c.decode([CRMContactLink].self, forKey: .contactLinks)) ?? []
        dealLinks = (try? c.decode([CRMDealLink].self, forKey: .dealLinks)) ?? []
    }
}

enum CRMSyncStore {
    private static var baseDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static func sanitized(_ account: String) -> String {
        String(account.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }
    static func stateURL(account: String) -> URL {
        baseDir.appendingPathComponent("crm-sync-\(sanitized(account)).json")
    }
    static func ledgerURL(account: String) -> URL {
        baseDir.appendingPathComponent("crm-pull-ledger-\(sanitized(account)).jsonl")
    }
    static func state(account: String) -> CRMSyncState {
        guard let data = try? Data(contentsOf: stateURL(account: account)),
              let s = try? JSONDecoder().decode(CRMSyncState.self, from: data) else { return CRMSyncState() }
        return s
    }
    static func save(_ state: CRMSyncState, account: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL(account: account), options: .atomic)
    }
    /// Append applied change-set lines (JSONL) — the pull traceability ledger, bounded to 1000 lines.
    static func appendLedger(_ lines: [String], account: String) {
        guard !lines.isEmpty else { return }
        let url = ledgerURL(account: account)
        var existing = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        existing.append(contentsOf: lines)
        if existing.count > 1000 { existing = Array(existing.suffix(1000)) }
        try? existing.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
    }
    /// Forget all links + cursors for an account. Never touches local leads.
    static func reset(account: String) {
        try? FileManager.default.removeItem(at: stateURL(account: account))
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - the pull plan (a dry-run preview IS this plan, unapplied)
struct CRMPlannedContactCreate: Identifiable, Hashable {
    let id = UUID()
    let remoteID: String
    let lead: Lead                        // fully built, ready to insert
    let remoteFields: [String: String]    // becomes the link snapshot on apply
}
#endif // circuit-convert

struct CRMPlannedContactUpdate: Identifiable, Hashable {
    let id = UUID()
    let remoteID: String
    let localID: UUID
    let displayName: String
    let changes: [CRMChange]              // remote → local applications (diff-engine rows)
    let keptLocal: [CRMChange]            // local edits preserved (incl. conflicts) — shown, never applied
    let remoteFields: [String: String]
}

struct CRMLinkRefresh: Hashable {
    let remoteID: String
    let localID: UUID
    let remoteFields: [String: String]
}

struct CRMPlannedDealCreate: Identifiable, Hashable {
    let id = UUID()
    let remoteID: String
    let leadID: UUID
    let title: String
    let value: Double
    let updatedAt: Date?
}

struct CRMPlannedDealUpdate: Identifiable, Hashable {
    let id = UUID()
    let remoteID: String
    let dealID: UUID
    let title: String
    let value: Double?
    let updatedAt: Date?
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct CRMPullPlan {
    let provider: CRMProvider
    var creates: [CRMPlannedContactCreate] = []
    var updates: [CRMPlannedContactUpdate] = []
    var refreshes: [CRMLinkRefresh] = []
    var dealCreates: [CRMPlannedDealCreate] = []
    var dealUpdates: [CRMPlannedDealUpdate] = []
    var unchanged = 0
    var notes: [String] = []               // honest skip/truncation reasons
    var newContactCursor: Date? = nil      // nil ⇒ don't advance (e.g. truncated page cap)
    var newDealCursor: Date? = nil

    var updatedCount: Int { updates.filter { !$0.changes.isEmpty }.count }
    var keptLocalCount: Int { updates.reduce(0) { $0 + $1.keptLocal.count } }
    var applyCount: Int { creates.count + updatedCount + dealCreates.count + dealUpdates.count }
    var isEmpty: Bool { applyCount == 0 }
    var summary: String {
        var parts: [String] = []
        if !creates.isEmpty { parts.append("\(creates.count) new lead\(creates.count == 1 ? "" : "s")") }
        if updatedCount > 0 { parts.append("\(updatedCount) lead\(updatedCount == 1 ? "" : "s") updated") }
        if !dealCreates.isEmpty { parts.append("\(dealCreates.count) new deal\(dealCreates.count == 1 ? "" : "s")") }
        if !dealUpdates.isEmpty { parts.append("\(dealUpdates.count) deal update\(dealUpdates.count == 1 ? "" : "s")") }
        if unchanged > 0 { parts.append("\(unchanged) unchanged") }
        if keptLocalCount > 0 { parts.append("\(keptLocalCount) local edit\(keptLocalCount == 1 ? "" : "s") kept") }
        return parts.isEmpty ? "nothing to pull — local and \(provider.label) already match" : parts.joined(separator: ", ")
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - pull engine: merge policy + plan + apply
enum CRMPullEngine {

    /// 3-way merge for one linked contact. Base = the remote snapshot from the last sync.
    /// Never destructive:
    ///  • a remote value only overwrites a local value the buyer hasn't touched since the last
    ///    sync (local == base) — an edited local field is never clobbered by a pull
    ///  • an empty local field is always safe to fill from the remote
    ///  • a pull never blanks a non-empty local field (a missing remote property is
    ///    indistinguishable from an unset one, so wiping local data on "" would be destructive)
    ///  • with no base (first-time email-match adoption) only empty local fields are filled
    static func mergeChanges(local: Lead, remoteFields: [String: String], base: [String: String]?,
                             mapping: [FieldMapping], provider: CRMProvider) -> (apply: [CRMChange], keptLocal: [CRMChange]) {
        var apply: [CRMChange] = []
        var kept: [CRMChange] = []
        // 1) both sides non-empty and different — straight from the EXISTING pure diff engine.
        for change in CRMMapping.changeSet(local: local, remote: remoteFields, mapping: mapping, provider: provider) {
            if change.remoteValue.isEmpty { kept.append(change); continue }        // never blank local
            if let base, base[change.field] == change.localValue { apply.append(change) }  // local untouched → remote wins
            else { kept.append(change) }   // local edited (or no base) → keep the local edit
        }
        // 2) remote values for fields the local lead has empty — the diff engine drops empty local
        //    values from its record, so the always-safe fill-ins are added here.
        let mine = CRMMapping.externalRecord(for: local, mapping: mapping, provider: provider)
        var seen = Set(apply.map(\.field))
        for m in mapping where m.enabled {
            if !seen.contains(m.remote), mine[m.remote] == nil,
               let v = remoteFields[m.remote], !v.isEmpty {
                apply.append(CRMChange(field: m.remote, localValue: "", remoteValue: v))
                seen.insert(m.remote)
            }
        }
        return (apply.sorted { $0.field < $1.field }, kept.sorted { $0.field < $1.field })
    }

    /// Write remote values into a Lead through the buyer's field map (the reverse of
    /// LocalField.value). Returns human-readable "field: old → new" descriptions of what was
    /// actually applied. Enum-backed fields (status/type) only apply when the remote string
    /// matches a known label — an unmappable value leaves the local field untouched.
    @discardableResult
    static func applyRemoteValues(_ changes: [CRMChange], mapping: [FieldMapping], to lead: inout Lead) -> [String] {
        var applied: [String] = []
        var newFirst: String? = nil
        var newLast: String? = nil
        for change in changes {
            guard let localField = mapping.first(where: { $0.enabled && $0.remote == change.field })?.local else { continue }
            let v = change.remoteValue
            switch localField {
            case .firstName: newFirst = v; continue   // composed into `name` below
            case .lastName:  newLast = v; continue
            case .name:      lead.name = v
            case .email:     lead.email = v
            case .phone:     lead.phone = v
            case .company:   lead.company = v
            case .domain:    lead.domain = v
            case .notes:     lead.notes = v
            case .address:   lead.address = v
            case .status:
                guard let s = ProspectStatus.allCases.first(where: {
                    $0.label.caseInsensitiveCompare(v) == .orderedSame || $0.rawValue.caseInsensitiveCompare(v) == .orderedSame
                }) else { continue }
                lead.status = s
            case .type:
                guard let t = ProspectType.allCases.first(where: {
                    $0.label.caseInsensitiveCompare(v) == .orderedSame || $0.rawValue.caseInsensitiveCompare(v) == .orderedSame
                }) else { continue }
                lead.type = t
            }
            applied.append("\(change.field): \(change.localValue.isEmpty ? "(empty)" : "\"\(change.localValue)\"") → \"\(v)\"")
        }
        if newFirst != nil || newLast != nil {
            let parts = lead.name.split(separator: " ")
            let currentFirst = parts.first.map(String.init) ?? ""
            let currentLast = parts.count > 1 ? parts.dropFirst().joined(separator: " ") : ""
            let name = [newFirst ?? currentFirst, newLast ?? currentLast]
                .filter { !$0.isEmpty }.joined(separator: " ")
            if !name.isEmpty, name != lead.name {
                let old = lead.name
                lead.name = name
                applied.append("name: \(old.isEmpty ? "(empty)" : "\"\(old)\"") → \"\(name)\"")
            }
        }
        return applied
    }

    /// Build the pull plan — PURE: no network, no mutation. This exact structure is what the
    /// dry-run preview renders and what apply() executes, so preview and apply can't diverge.
    static func plan(provider: CRMProvider, mapping: [FieldMapping],
                     contacts: [CRMRemoteContact], deals: [CRMRemoteDeal],
                     localLeads: [Lead], localDeals: [Deal],
                     state: CRMSyncState) -> CRMPullPlan {
        var plan = CRMPullPlan(provider: provider)
        let linkByRemote = Dictionary(state.contactLinks.map { ($0.remoteID, $0) }, uniquingKeysWith: { a, _ in a })
        let leadByID = Dictionary(localLeads.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let linkedLocalIDs = Set(state.contactLinks.map(\.localID))

        // Email → unlinked local lead, so a remote contact adopts an existing lead instead of duplicating it.
        var emailIndex: [String: UUID] = [:]
        for lead in localLeads where !linkedLocalIDs.contains(lead.id) {
            let e = lead.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !e.isEmpty, emailIndex[e] == nil { emailIndex[e] = lead.id }
        }
        let emailRemoteKey = mapping.first(where: { $0.enabled && $0.local == .email })?.remote

        // contact remoteID → local lead id (existing valid links + adoptions + creates), for deal attachment.
        var resolved: [String: UUID] = [:]
        for link in state.contactLinks where leadByID[link.localID] != nil { resolved[link.remoteID] = link.localID }

        for contact in contacts {
            if let u = contact.updatedAt { plan.newContactCursor = max(plan.newContactCursor ?? u, u) }
            if let link = linkByRemote[contact.remoteID] {
                guard let lead = leadByID[link.localID] else {
                    plan.notes.append("\(provider.label) #\(contact.remoteID) was deleted locally — not re-created (a pull never resurrects a local delete).")
                    continue
                }
                let (apply, kept) = mergeChanges(local: lead, remoteFields: contact.fields,
                                                 base: link.snapshot, mapping: mapping, provider: provider)
                if apply.isEmpty && kept.isEmpty {
                    plan.unchanged += 1
                    plan.refreshes.append(CRMLinkRefresh(remoteID: contact.remoteID, localID: lead.id, remoteFields: contact.fields))
                } else {
                    plan.updates.append(CRMPlannedContactUpdate(remoteID: contact.remoteID, localID: lead.id,
                                                                displayName: lead.displayName,
                                                                changes: apply, keptLocal: kept,
                                                                remoteFields: contact.fields))
                }
            } else if let key = emailRemoteKey,
                      let remoteEmail = contact.fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      !remoteEmail.isEmpty,
                      let matchID = emailIndex[remoteEmail],
                      let lead = leadByID[matchID] {
                // Adoption: same email, never linked — link it; with no base only empty fields fill.
                let (apply, kept) = mergeChanges(local: lead, remoteFields: contact.fields,
                                                 base: nil, mapping: mapping, provider: provider)
                plan.updates.append(CRMPlannedContactUpdate(remoteID: contact.remoteID, localID: lead.id,
                                                            displayName: lead.displayName,
                                                            changes: apply, keptLocal: kept,
                                                            remoteFields: contact.fields))
                emailIndex[remoteEmail] = nil   // consumed — one remote contact per local lead
                resolved[contact.remoteID] = lead.id
            } else {
                // Locally missing → create. Built through the same reverse mapping as updates.
                var lead = Lead()
                lead.source = .imported
                let seedChanges = contact.fields
                    .filter { !$0.value.isEmpty }
                    .map { CRMChange(field: $0.key, localValue: "", remoteValue: $0.value) }
                applyRemoteValues(seedChanges, mapping: mapping, to: &lead)
                guard !(lead.name.isEmpty && lead.company.isEmpty && lead.email.isEmpty) else {
                    plan.notes.append("\(provider.label) #\(contact.remoteID) skipped — no mapped name/company/email in the remote record.")
                    continue
                }
                plan.creates.append(CRMPlannedContactCreate(remoteID: contact.remoteID, lead: lead, remoteFields: contact.fields))
                resolved[contact.remoteID] = lead.id
            }
        }

        // Deals / opportunities. Deal.updated exists locally, so the timestamp rule applies directly:
        // update only when remote.updatedAt > local.updated. Never deleted, never detached.
        let dealLinkByRemote = Dictionary(state.dealLinks.map { ($0.remoteID, $0) }, uniquingKeysWith: { a, _ in a })
        let dealByID = Dictionary(localDeals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for rdeal in deals {
            if let u = rdeal.updatedAt { plan.newDealCursor = max(plan.newDealCursor ?? u, u) }
            if let link = dealLinkByRemote[rdeal.remoteID] {
                guard let local = dealByID[link.localID] else {
                    plan.notes.append("\(provider.label) deal #\(rdeal.remoteID) was deleted locally — not re-created.")
                    continue
                }
                guard let ru = rdeal.updatedAt, ru > local.updated else { plan.unchanged += 1; continue }
                let newTitle = rdeal.title.isEmpty ? local.title : rdeal.title
                let valueDiffers = rdeal.value.map { $0 != local.value } ?? false
                if newTitle != local.title || valueDiffers {
                    plan.dealUpdates.append(CRMPlannedDealUpdate(remoteID: rdeal.remoteID, dealID: local.id,
                                                                 title: newTitle, value: rdeal.value, updatedAt: ru))
                } else {
                    plan.unchanged += 1
                }
            } else {
                guard let leadID = rdeal.contactRemoteIDs.compactMap({ resolved[$0] }).first else {
                    plan.notes.append("\(provider.label) deal \"\(rdeal.title)\" (#\(rdeal.remoteID)) skipped — its contact isn't synced locally yet.")
                    continue
                }
                plan.dealCreates.append(CRMPlannedDealCreate(remoteID: rdeal.remoteID, leadID: leadID,
                                                             title: rdeal.title.isEmpty ? "CRM deal #\(rdeal.remoteID)" : rdeal.title,
                                                             value: rdeal.value ?? 0, updatedAt: rdeal.updatedAt))
            }
        }
        return plan
    }

    /// Fetch remote state and compute the plan (the network step). The returned plan IS the
    /// dry-run preview — nothing has been written until apply() runs it.
    static func fetchPlan(config: CRMConnectorConfig, localLeads: [Lead], localDeals: [Deal],
                          progress: ((String) -> Void)? = nil) async throws -> CRMPullPlan {
        guard config.isConfigured else { throw CRMConnectorError.notConfigured }
        try CRMConnectorClient.requireTransmissionConsent(config)
        let account = CRMConnectorKeychain.account(for: config)
        guard let token = CRMConnectorKeychain.token(account: account) else { throw CRMConnectorError.missingToken }
        let state = CRMSyncStore.state(account: account)
        let mapping = config.effectiveMap.filter { $0.enabled }

        progress?("Fetching \(config.provider.label) contacts…")
        let (contacts, contactsTruncated) = try await CRMPullClient.fetchContacts(config: config, token: token,
                                                                                  updatedAfter: state.contactCursor)
        progress?("Fetching \(config.provider.label) deals…")
        var deals: [CRMRemoteDeal] = []
        var dealsTruncated = false
        var dealError: String? = nil
        do {
            (deals, dealsTruncated) = try await CRMPullClient.fetchDeals(config: config, token: token,
                                                                         updatedAfter: state.dealCursor)
        } catch {
            // Contacts still sync when the token lacks deal scope — said plainly, never silently.
            dealError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }

        progress?("Computing the change-set…")
        var plan = CRMPullEngine.plan(provider: config.provider, mapping: mapping,
                                      contacts: contacts, deals: deals,
                                      localLeads: localLeads, localDeals: localDeals, state: state)
        let cap = CRMPullClient.maxPages * CRMPullClient.pageSize
        if contactsTruncated {
            plan.newContactCursor = nil   // don't advance past unseen records
            plan.notes.append("Contact list stopped at \(cap) records this pull — the sync cursor was not advanced, so nothing is missed; run Pull again to continue.")
        }
        if dealsTruncated {
            plan.newDealCursor = nil
            plan.notes.append("Deal list stopped at \(cap) records this pull — run Pull again to continue.")
        }
        if let dealError { plan.notes.append("Deals were not pulled: \(dealError)") }
        return plan
    }

    /// Apply a plan: mutate the AppModel (one batched save), persist links + cursors, and write
    /// the traceability ledger. Returns the honest summary string. Never deletes anything.
    @MainActor
    @discardableResult
    static func apply(_ plan: CRMPullPlan, model: AppModel, stages: [DealStage], config: CRMConnectorConfig) -> String {
        let account = CRMConnectorKeychain.account(for: config)
        var state = CRMSyncStore.state(account: account)
        let mapping = config.effectiveMap.filter { $0.enabled }
        var ledger: [String] = []
        let stamp = ISO8601DateFormatter().string(from: Date())
        func ledgerLine(_ kind: String, _ remoteID: String, _ localID: UUID, _ detail: String) {
            let obj: [String: Any] = ["at": stamp, "provider": plan.provider.rawValue, "kind": kind,
                                      "remoteID": remoteID, "localID": localID.uuidString, "detail": detail]
            if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
               let s = String(data: d, encoding: .utf8) { ledger.append(s) }
        }
        var linkIndex: [String: Int] = [:]
        for (i, l) in state.contactLinks.enumerated() { linkIndex[l.remoteID] = i }
        func upsertLink(remoteID: String, localID: UUID, snapshot: [String: String]) {
            if let i = linkIndex[remoteID] {
                state.contactLinks[i].localID = localID
                state.contactLinks[i].snapshot = snapshot
                state.contactLinks[i].lastSyncedAt = Date()
            } else {
                state.contactLinks.append(CRMContactLink(remoteID: remoteID, localID: localID, snapshot: snapshot))
                linkIndex[remoteID] = state.contactLinks.count - 1
            }
        }

        model.batch {
            for c in plan.creates {
                model.leads.insert(c.lead, at: 0)
                model.log(c.lead.id, .imported, "Pulled from \(plan.provider.label) (#\(c.remoteID)).")
                upsertLink(remoteID: c.remoteID, localID: c.lead.id, snapshot: c.remoteFields)
                ledgerLine("create", c.remoteID, c.lead.id, c.lead.displayName)
            }
            for u in plan.updates {
                if !u.changes.isEmpty, let i = model.leads.firstIndex(where: { $0.id == u.localID }) {
                    var lead = model.leads[i]
                    let applied = applyRemoteValues(u.changes, mapping: mapping, to: &lead)
                    if !applied.isEmpty {
                        model.leads[i] = lead
                        let detail = applied.joined(separator: "; ")
                        model.log(lead.id, .imported, "CRM pull from \(plan.provider.label) (#\(u.remoteID)): \(detail)")
                        ledgerLine("update", u.remoteID, u.localID, detail)
                    }
                }
                if !u.keptLocal.isEmpty {
                    ledgerLine("kept-local", u.remoteID, u.localID,
                               u.keptLocal.map { "\($0.field) stays \"\($0.localValue)\"" }.joined(separator: "; "))
                }
                upsertLink(remoteID: u.remoteID, localID: u.localID, snapshot: u.remoteFields)
            }
            for r in plan.refreshes {
                upsertLink(remoteID: r.remoteID, localID: r.localID, snapshot: r.remoteFields)
            }
            if !plan.dealCreates.isEmpty || !plan.dealUpdates.isEmpty {
                let firstStage = stages.first(where: { $0.terminal == .open })?.id ?? stages.first?.id ?? UUID()
                var nextSort = (model.deals.map { $0.sort }.max() ?? 0) + 1
                for d in plan.dealCreates {
                    let deal = Deal(prospectID: d.leadID, title: d.title, stageID: firstStage,
                                    value: d.value, sort: nextSort)
                    nextSort += 1
                    model.deals.append(deal)
                    model.log(d.leadID, .imported, "Deal \"\(d.title)\" pulled from \(plan.provider.label) (#\(d.remoteID)).")
                    state.dealLinks.append(CRMDealLink(remoteID: d.remoteID, localID: deal.id))
                    ledgerLine("deal-create", d.remoteID, deal.id, d.title)
                }
                for d in plan.dealUpdates {
                    guard let i = model.deals.firstIndex(where: { $0.id == d.dealID }) else { continue }
                    var detailParts: [String] = []
                    if model.deals[i].title != d.title {
                        detailParts.append("title \"\(model.deals[i].title)\" → \"\(d.title)\"")
                        model.deals[i].title = d.title
                    }
                    if let v = d.value, model.deals[i].value != v {
                        detailParts.append("value \(model.deals[i].value) → \(v)")
                        model.deals[i].value = v
                    }
                    model.deals[i].updated = d.updatedAt ?? Date()
                    if let j = state.dealLinks.firstIndex(where: { $0.remoteID == d.remoteID }) {
                        state.dealLinks[j].lastSyncedAt = Date()
                    }
                    let detail = detailParts.joined(separator: "; ")
                    model.log(model.deals[i].prospectID, .imported, "Deal updated from \(plan.provider.label) (#\(d.remoteID)): \(detail)")
                    ledgerLine("deal-update", d.remoteID, d.dealID, detail)
                }
            }
        }

        if let c = plan.newContactCursor { state.contactCursor = max(state.contactCursor ?? c, c) }
        if let c = plan.newDealCursor { state.dealCursor = max(state.dealCursor ?? c, c) }
        CRMSyncStore.save(state, account: account)
        CRMSyncStore.appendLedger(ledger, account: account)
        return plan.summary
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - auto-pull on app foreground (clean entry symbol — callable from any foreground hook)
enum CRMAutoPull {
    /// The platform "app became active" notification. ConnectorsScreen observes it; the app-level
    /// scene can call pullIfEnabled from its own foreground handler for app-wide coverage.
    static var foregroundNotification: Notification.Name {
        #if os(macOS)
        NSApplication.didBecomeActiveNotification
        #else
        UIApplication.didBecomeActiveNotification
        #endif
    }

    @MainActor private static var lastRunAt: Date? = nil
    @MainActor private static var running = false
    /// Minimum spacing between automatic pulls so re-activating the app can't hammer the CRM.
    static let minInterval: TimeInterval = 5 * 60

    /// Pull remote CRM changes if the buyer enabled auto-pull. Safe to call from any foreground
    /// hook: no-ops unless configured + enabled, never runs in demo mode, throttles itself, and
    /// applies with the same honest merge as Pull now.
    @MainActor
    static func pullIfEnabled(model: AppModel, leadEngine: LeadEngineStore, onDone: ((String) -> Void)? = nil) {
        let config = leadEngine.settings.crmConnector
        guard config.autoPull, config.isConfigured, !DemoMode.active, !running else { return }
        if let last = lastRunAt, Date().timeIntervalSince(last) < minInterval { return }
        running = true
        lastRunAt = Date()
        let leads = model.leads
        let deals = model.deals
        Task {
            do {
                let plan = try await CRMPullEngine.fetchPlan(config: config, localLeads: leads, localDeals: deals)
                await MainActor.run {
                    let summary = CRMPullEngine.apply(plan, model: model, stages: leadEngine.settings.stages, config: config)
                    var updated = leadEngine.settings.crmConnector
                    updated.lastPullAt = Date()
                    updated.lastPullSummary = summary
                    leadEngine.settings.crmConnector = updated
                    running = false
                    onDone?(summary)
                }
            } catch {
                await MainActor.run {
                    let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                    var updated = leadEngine.settings.crmConnector
                    updated.lastPullSummary = "Auto-pull failed: \(msg)"
                    leadEngine.settings.crmConnector = updated
                    running = false
                    onDone?("✗ " + msg)
                }
            }
        }
    }
}
#endif // circuit-convert
