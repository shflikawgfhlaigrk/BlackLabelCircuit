// Black Label Marketing — lead-engine settings (merged from Black Label Leads, 2026-07).
// Everything the buyer tailors for the lead engine lives here: sending mailboxes (their OWN
// email), markets & verticals, outreach templates & cadence, deliverability params, Kanban
// stages, ICP, IMAP reply-detection, telephony, enrichment, and the CRM connector. Brand /
// appearance / motion are NOT here — Prefs owns those for the whole app. Persisted as a
// Codable snapshot blob in the app's own SQLite workspace. The SMTP app-password is stored
// in the macOS Keychain (never in plaintext JSON, never in the shipped bundle). Starts EMPTY.
// On-wire coding keys match the Leads app's settings document so a migrated buyer's
// settings.json decodes directly (dropped appearance keys are simply ignored).
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

// MARK: - sending mailbox (the client's OWN email, used to actually send outreach)
struct Mailbox: Codable, Hashable, Identifiable {
    var id = UUID()
    var fromName: String = ""          // "Jane at Acme"
    var fromEmail: String = ""         // jane@acme.com  (the client's own address)
    var host: String = ""              // smtp.gmail.com
    var port: Int = 465                // 465 implicit TLS, or 587 STARTTLS — both send
    var username: String = ""          // usually == fromEmail
    var useTLS: Bool = true
    /// app-password is NOT stored here — it lives in the Keychain keyed by username. This is a flag only.
    var hasPassword: Bool = false

    /// How this mailbox actually SENDS. `.smtp` (default) = app-password over SMTP 465. `.gmailAPI` /
    /// `.graphAPI` = the buyer authorized real provider OAuth (Connectors → Connect) and every send
    /// calls Gmail API / Microsoft Graph with their token — no SMTP, no app-password. The OAuth token
    /// itself lives in the data-protection Keychain (EmailTokenStore), keyed by fromEmail.
    var authKind: EmailAuthKind = .smtp

    /// One-line postal address required for CAN-SPAM completeness on every send.
    var physicalAddress: String = ""

    /// Per-mailbox warmup-friendly daily cap (rotation respects each mailbox's own limit).
    var dailyCap: Int = 50
    /// Buyer can pause a mailbox in the rotation without deleting it.
    var enabled: Bool = true

    var isConfigured: Bool {
        switch authKind {
        case .smtp:
            return !fromEmail.isEmpty && fromEmail.contains("@") && !host.isEmpty && !username.isEmpty && hasPassword
        case .gmailAPI, .graphAPI:
            // An OAuth mailbox is set up once the buyer authorized (a real address was returned).
            // Live token presence is checked at send time so a revoked token fails honestly, not silently.
            return !fromEmail.isEmpty && fromEmail.contains("@")
        }
    }
    /// True when this mailbox sends over a provider API (Gmail/Graph) rather than SMTP.
    var usesProviderAPI: Bool { authKind != .smtp }
    /// True when the configured port speaks implicit TLS from the first byte (465). False on 587,
    /// which greets in the clear and is upgraded in place by STARTTLS before AUTH.
    var usesImplicitTLS: Bool { port == 465 }
    /// True on 587, the STARTTLS submission port. Some providers publish ONLY this one.
    var usesSTARTTLS: Bool { port == 587 }
    /// The submission ports this app's SMTP client actually speaks. Anything else is refused with
    /// an actionable message rather than attempted and silently desynced.
    var usesSupportedSMTPPort: Bool { usesImplicitTLS || usesSTARTTLS }
    /// Common provider presets so the buyer doesn't have to know SMTP details.
    /// All use port 465 (implicit TLS) — every one of these providers supports it; a buyer whose
    /// server offers only 587 can type that port and the client negotiates STARTTLS instead.
    static let presets: [(name: String, host: String, port: Int)] = [
        ("Gmail / Google Workspace", "smtp.gmail.com", 465),
        ("Outlook / Microsoft 365", "smtp.office365.com", 465),
        ("iCloud Mail", "smtp.mail.me.com", 465),
        ("Fastmail", "smtp.fastmail.com", 465),
        ("Zoho Mail", "smtp.zoho.com", 465),
        ("Custom SMTP", "", 465),
    ]

    init() {}

    // Resilient decode: tolerate legacy settings written by an earlier version that lacks the
    // newer fields (id / dailyCap / enabled). Missing keys fall back to defaults instead of failing.
    enum CodingKeys: String, CodingKey {
        case id, fromName, fromEmail, host, port, username, useTLS, hasPassword, physicalAddress, dailyCap, enabled, authKind
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        fromName = (try? c.decode(String.self, forKey: .fromName)) ?? ""
        fromEmail = (try? c.decode(String.self, forKey: .fromEmail)) ?? ""
        host = (try? c.decode(String.self, forKey: .host)) ?? ""
        port = (try? c.decode(Int.self, forKey: .port)) ?? 465
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        useTLS = (try? c.decode(Bool.self, forKey: .useTLS)) ?? true
        hasPassword = (try? c.decode(Bool.self, forKey: .hasPassword)) ?? false
        physicalAddress = (try? c.decode(String.self, forKey: .physicalAddress)) ?? ""
        dailyCap = (try? c.decode(Int.self, forKey: .dailyCap)) ?? 50
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        // New in v21 — legacy settings (SMTP-only) decode to .smtp, unchanged behavior.
        authKind = (try? c.decode(EmailAuthKind.self, forKey: .authKind)) ?? .smtp
    }
}

// MARK: - a saved outreach template (per business type, fully editable)
struct OutreachTemplate: Codable, Hashable, Identifiable {
    var id = UUID()
    var type: ProspectType = .other
    var subject: String = "Quick idea for {{company}}"
    var body: String = ""
    /// Tokens the buyer can use: {{first}} {{company}} {{type}} {{sender}} {{from_email}} {{address}} {{booking}}
    static let tokens = ["{{first}}", "{{company}}", "{{type}}", "{{sender}}", "{{from_email}}", "{{address}}", "{{booking}}"]
}

// MARK: - a custom market the buyer adds (beyond the built-in US metros)
struct CustomMarket: Codable, Hashable, Identifiable {
    var id = UUID()
    var city: String = ""
    var state: String = ""
    var lat: Double = 0
    var lon: Double = 0
    var metro: Metro { Metro(city: city, state: state, lat: lat, lon: lon) }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - the whole persisted lead-engine settings document
struct LeadEngineSettings: Codable {
    // Sending identity (primary mailbox kept for back-compat; `mailboxes` is the rotation pool)
    var mailbox = Mailbox()
    var extraMailboxes: [Mailbox] = []      // additional sending identities for multi-mailbox rotation

    // Booking — the buyer's meeting/scheduling link (Calendly, Cal.com, etc.) surfaced in outreach + a {{booking}} token
    var bookingLink: String = ""

    // Targeting defaults
    var defaultMarketLabel: String = ""     // remembered last metro
    var customMarkets: [CustomMarket] = []
    var customVerticals: [String] = []      // freeform vertical labels the buyer cares about

    // Outreach
    var templates: [OutreachTemplate] = []
    var dailySendCap: Int = 50              // deliverability: warmup-respecting daily cap
    var minSecondsBetweenSends: Int = 45    // throttle
    var suppressedEmails: [String] = []     // buyer-owned explicit do-not-email list

    // Deliverability params
    var requireMX: Bool = true              // never send to a domain with no MX
    var blockRoleAddresses: Bool = true     // skip info@/sales@/admin@ etc unless explicitly chosen
    var requirePhysicalAddress: Bool = true // CAN-SPAM hard precondition

    // CRM config (buyer-customizable Kanban pipeline)
    var stages: [DealStage] = DealStage.defaults

    // Lead scoring — the buyer's ideal-customer profile drives the FIT score.
    var icp = ICP()

    // Reply detection (IMAP) — read-only inbox check on the buyer's OWN mailbox to detect replies.
    var imapHost: String = ""
    var imapPort: Int = 993
    var imapUsername: String = ""
    var imapEnabled: Bool = false

    // Telephony (BYO provider) — click-to-call + call logging. Defaults to the zero-config system dialer.
    var telephony = TelephonyConfig()
    // Enrichment (BYO provider) — bulk email/phone discovery. Defaults to no provider (in-house only).
    var enrichment = EnrichmentConfig()
    // Custom DKIM selectors the buyer's provider uses (probed in the deliverability checker).
    var dkimSelectors: [String] = []
    // CRM connector (BYO-key) — Salesforce/HubSpot/Pipedrive field mapping + sync. Token in Keychain.
    var crmConnector = CRMConnectorConfig()

    init() {}

    /// Older merged Leads state can carry `imapEnabled=true` with no host/user. That is not a
    /// configured account; it is a stale toggle that makes new-user proof look broken. Keep real
    /// IMAP configs intact, but normalize a completely empty enabled IMAP block back to Off.
    mutating func normalizeStaleEmptyConnectors() -> Bool {
        let emptyIMAP = imapHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && imapUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if imapEnabled && emptyIMAP {
            imapEnabled = false
            return true
        }
        return false
    }

    // Resilient decode so a legacy/migrated settings document (including the Leads app's, whose
    // appearance keys we drop) still loads.
    enum CodingKeys: String, CodingKey {
        case mailbox, extraMailboxes, bookingLink
        case defaultMarketLabel, customMarkets, customVerticals
        case templates, dailySendCap, minSecondsBetweenSends, suppressedEmails
        case requireMX, blockRoleAddresses, requirePhysicalAddress, stages
        case icp, imapHost, imapPort, imapUsername, imapEnabled
        case telephony, enrichment, dkimSelectors, crmConnector
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mailbox = (try? c.decode(Mailbox.self, forKey: .mailbox)) ?? Mailbox()
        extraMailboxes = (try? c.decode([Mailbox].self, forKey: .extraMailboxes)) ?? []
        bookingLink = (try? c.decode(String.self, forKey: .bookingLink)) ?? ""
        defaultMarketLabel = (try? c.decode(String.self, forKey: .defaultMarketLabel)) ?? ""
        customMarkets = (try? c.decode([CustomMarket].self, forKey: .customMarkets)) ?? []
        customVerticals = (try? c.decode([String].self, forKey: .customVerticals)) ?? []
        templates = (try? c.decode([OutreachTemplate].self, forKey: .templates)) ?? []
        dailySendCap = (try? c.decode(Int.self, forKey: .dailySendCap)) ?? 50
        minSecondsBetweenSends = (try? c.decode(Int.self, forKey: .minSecondsBetweenSends)) ?? 45
        suppressedEmails = (try? c.decode([String].self, forKey: .suppressedEmails)) ?? []
        requireMX = (try? c.decode(Bool.self, forKey: .requireMX)) ?? true
        blockRoleAddresses = (try? c.decode(Bool.self, forKey: .blockRoleAddresses)) ?? true
        requirePhysicalAddress = (try? c.decode(Bool.self, forKey: .requirePhysicalAddress)) ?? true
        let s = (try? c.decode([DealStage].self, forKey: .stages)) ?? []
        stages = s.isEmpty ? DealStage.defaults : s
        icp = (try? c.decode(ICP.self, forKey: .icp)) ?? ICP()
        imapHost = (try? c.decode(String.self, forKey: .imapHost)) ?? ""
        imapPort = (try? c.decode(Int.self, forKey: .imapPort)) ?? 993
        imapUsername = (try? c.decode(String.self, forKey: .imapUsername)) ?? ""
        imapEnabled = (try? c.decode(Bool.self, forKey: .imapEnabled)) ?? false
        telephony = (try? c.decode(TelephonyConfig.self, forKey: .telephony)) ?? TelephonyConfig()
        enrichment = (try? c.decode(EnrichmentConfig.self, forKey: .enrichment)) ?? EnrichmentConfig()
        dkimSelectors = (try? c.decode([String].self, forKey: .dkimSelectors)) ?? []
        crmConnector = (try? c.decode(CRMConnectorConfig.self, forKey: .crmConnector)) ?? CRMConnectorConfig()
    }

    /// Template for a given type, falling back to a generated default.
    func template(for type: ProspectType) -> OutreachTemplate? {
        templates.first { $0.type == type }
    }

    /// Every configured, enabled sending identity (primary first), for rotation.
    var allMailboxes: [Mailbox] {
        ([mailbox] + extraMailboxes).filter { $0.isConfigured && $0.enabled }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - persistence + live store
final class LeadEngineStore: ObservableObject {
    static let blobName = "leadEngine"
    @Published var settings: LeadEngineSettings { didSet { save() } }

    private var database: WorkspaceDatabase
    /// Demo/guest mode: when true, settings (the sample sending identity, targeting) live ONLY in
    /// memory — saves are no-ops so demo config never overwrites the buyer's real workspace database.
    var demoMode = false

    init() {
        database = WorkspaceDatabase(demo: DemoMode.active)
        if let data = try? database.readBlob(named: Self.blobName),
           var s = try? JSONDecoder().decode(LeadEngineSettings.self, from: data) {
            let changed = s.normalizeStaleEmptyConnectors()
            settings = s
            if changed { save() }
        } else {
            settings = LeadEngineSettings()
        }
    }

    /// Re-read the real on-disk settings into memory (used when leaving demo mode). If no blob
    /// exists — the buyer's untouched store — this restores clean defaults.
    func reloadFromDisk() {
        database = WorkspaceDatabase(demo: false)
        if let data = try? database.readBlob(named: Self.blobName),
           var s = try? JSONDecoder().decode(LeadEngineSettings.self, from: data) {
            let changed = s.normalizeStaleEmptyConnectors()
            settings = s
            if changed { save() }
        } else {
            settings = LeadEngineSettings()
        }
    }

    private func save() {
        guard !demoMode else { return }   // demo settings are in-memory only — never touch the real store
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? database.writeBlob(data, named: Self.blobName)
    }

    // Export / import a saved profile (markets, verticals, templates — NOT the password).
    func exportProfile() -> Data? { try? JSONEncoder().encode(settings) }
    func importProfile(_ data: Data) -> Bool {
        guard let s = try? JSONDecoder().decode(LeadEngineSettings.self, from: data) else { return false }
        var merged = s; merged.mailbox.hasPassword = settings.mailbox.hasPassword
        settings = merged; return true
    }
}
#endif // circuit-convert

// MARK: - Keychain (SMTP app-password — on-device only, never shipped)
// Reads fall back to the retired Black Label Leads service and opportunistically re-key the
// item under this app's service, so a migrated buyer's mailbox keeps sending without re-entry
// (when macOS grants the read; on ACL denial the UI shows an honest re-enter prompt instead).
enum SendKeychain {
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").smtp"
    }
    private static var legacyServices: [String] {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing"
        return bundleID == "com.blacklabel.marketing" ? ["com.blacklabel.leads.smtp"] : []
    }

    static func setPassword(_ pw: String, account: String) {
        guard !pw.isEmpty, !account.isEmpty else { delete(account: account); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Data-protection keychain (stable across ad-hoc re-signs). set() clears both keychains
        // first, keeping the write idempotent.
        MarketingKeychain.set(base, data: Data(pw.utf8), accessible: kSecAttrAccessibleWhenUnlocked)
    }
    static func password(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        if let pw = read(service: service, account: account, allowAuthenticationUI: false) { return pw }
        // Legacy Leads-app item: Marketing re-keys under its current service on first successful
        // read. Branded companion apps keep their own bundle-scoped item and do not touch
        // Marketing's service, which avoids cross-app Keychain ACL prompts in headless sends.
        for legacyService in legacyServices {
            if let pw = read(service: legacyService, account: account, allowAuthenticationUI: false) {
                setPassword(pw, account: account)
                return pw
            }
        }
        return nil
    }
    static func hasReadablePassword(account: String) -> Bool {
        password(account: account) != nil
    }
    static func hasSavedPasswordItem(account: String) -> Bool {
        guard !account.isEmpty else { return false }
        if exists(service: service, account: account) { return true }
        return legacyServices.contains { exists(service: $0, account: account) }
    }
    static func migrateSavedPassword(account: String) -> Bool {
        guard !account.isEmpty else { return false }
        if let pw = read(service: service, account: account, allowAuthenticationUI: true) {
            setPassword(pw, account: account)
            return hasReadablePassword(account: account)
        }
        for legacyService in legacyServices {
            if let pw = read(service: legacyService, account: account, allowAuthenticationUI: true) {
                setPassword(pw, account: account)
                return hasReadablePassword(account: account)
            }
        }
        return false
    }
    private static func exists(service: String, account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return MarketingKeychain.exists(base)
    }
    private static func read(service: String, account: String, allowAuthenticationUI: Bool) -> String? {
        // service is either this app's own service or the retired Leads legacyService; either way
        // MarketingKeychain.copy prefers the data-protection keychain. Reads intentionally suppress
        // authentication UI so connector chips and background sends never hang behind a Keychain prompt.
        // If an old legacy item is not readable under the current app identity, the UI asks the buyer
        // to re-enter the app password instead of overclaiming Connected.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard let data = MarketingKeychain.copy(base, accessible: kSecAttrAccessibleWhenUnlocked,
                                                allowAuthenticationUI: allowAuthenticationUI),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
    static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        MarketingKeychain.delete(q)
    }
}
