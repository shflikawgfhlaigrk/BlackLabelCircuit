// Black Label Marketing — explicit per-provider transmission consent.
//
// WHY THIS EXISTS: this app talks to a lot of machines that are not this Mac. Message bodies and
// recipient phone numbers go to Sendblue. Captions, images and videos go to eight social APIs.
// Lead names + company domains go to the buyer's email-finder vendor. Lead records go to the
// buyer's CRM. Search terms go to the Black Label lead catalog. Until now the *only* thing that
// stood between "the buyer pasted a key once" and "their customers' data is on someone else's
// server" was the act of pasting the key. That is implied consent, and it is not good enough for
// an App Store privacy review or for the buyer.
//
// AND ONE LANE HAD EVEN LESS THAN THAT. The client finder (MktFinder in Model.swift, LeadFinder in
// LeadEngines.swift) POSTs the buyer's typed business-name search to TWO volunteer public
// OpenStreetMap Overpass operators. It needs no key, so there was never even a paste to imply
// consent from — it just sent. Two consecutive audits of this app's "transmission lanes" missed it
// because both audits looked only at the messaging lanes. That is why the registry below is now
// enforced mechanically by Tests/outbound-host-registry-contract.sh rather than by remembering.
//
// THE RULE THIS FILE ENFORCES: before ANY buyer content or credential is transmitted to a named
// provider, that provider must carry a RECORDED, EXPLICIT consent for the CURRENT disclosure text.
// No consent → the call does not happen and the surface says so plainly. Consent is per provider
// (granting Sendblue never grants LinkedIn), it is withdrawable, and it is versioned: if the
// disclosure changes (a new host, new data leaving), every prior grant goes stale and must be
// re-taken.
//
// Everything here is Foundation-only and the decision is a PURE function over (record, version),
// so the whole gate is executed headlessly in Tests/ProviderConsentTests.swift. The store is a
// thin UserDefaults shell around it — a consent RECEIPT is not a secret (it is a date + a version
// number), so it deliberately does not occupy a Keychain slot.
import Foundation

// MARK: - the destinations

/// Every off-device destination this app can transmit buyer content or credentials to.
/// `isFirstParty` marks Black Label's own hosted services — they are disclosed and gated exactly
/// like everyone else, because "we operate the server" is not a reason to skip asking.
enum TransmissionProvider: String, Codable, CaseIterable, Identifiable {
    // Messaging
    case sendblue
    // Social publishing
    case x, linkedin, facebook, instagram, threads, youtube, tiktok, pinterest
    // Email-finder / enrichment vendors
    case hunter, apollo, prospeo
    // CRM
    case hubspot, salesforce, pipedrive
    // Open-map business discovery (keyless public Overpass instances).
    // TWO providers, not one, because these are two INDEPENDENT operators that each receive the
    // full query. The finder falls through from the first to the second on a 429/5xx, so a single
    // shared grant would silently hand the buyer's typed search to a second company they never
    // agreed to. Consent is per operator; a refusal on one only skips that one.
    case bluesky, mastodon, discord
    case overpassMain, overpassPrivateCoffee
    // Google Search Console (the buyer's own verified site, read-only)
    case searchConsole
    // First-party hosted services
    case blackLabelLeads

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sendblue:   return "Sendblue"
        case .x:          return "X"
        case .linkedin:   return "LinkedIn"
        case .facebook:   return "Facebook"
        case .instagram:  return "Instagram"
        case .threads:    return "Threads"
        case .youtube:    return "YouTube"
        case .tiktok:     return "TikTok"
        case .pinterest:  return "Pinterest"
        case .hunter:     return "Hunter.io"
        case .apollo:     return "Apollo"
        case .prospeo:    return "Prospeo"
        case .hubspot:    return "HubSpot"
        case .salesforce: return "Salesforce"
        case .pipedrive:  return "Pipedrive"
        case .bluesky:    return "Bluesky"
        case .mastodon:   return "Mastodon"
        case .discord:    return "Discord"
        case .overpassMain:          return "OpenStreetMap Overpass (overpass-api.de)"
        case .overpassPrivateCoffee: return "Overpass mirror (overpass.private.coffee)"
        case .searchConsole: return "Google Search Console"
        case .blackLabelLeads: return "Black Label lead catalog"
        }
    }

    var isFirstParty: Bool { self == .blackLabelLeads }

    /// The hostnames a granted consent authorizes traffic to. These are the SAME hosts the
    /// request builders in Sendblue.swift / SocialPublishClient.swift / EnrichmentProvider.swift /
    /// CRMConnector.swift / LeadDatabase.swift / Model.swift / LeadEngines.swift actually target —
    /// the privacy manifest and the consent sheet are generated from this one list so they cannot
    /// drift apart. Tests/outbound-host-registry-contract.sh fails the build if a hostname appears
    /// in Sources/ that is not accounted for here (or classified as non-transmitting on purpose).
    var hosts: [String] {
        switch self {
        case .sendblue:   return ["api.sendblue.com"]
        case .x:          return ["api.x.com", "upload.twitter.com"]
        case .linkedin:   return ["api.linkedin.com"]
        case .facebook:   return ["graph.facebook.com"]
        case .instagram:  return ["graph.facebook.com", "graph.instagram.com"]
        case .threads:    return ["graph.threads.net"]
        case .youtube:    return ["www.googleapis.com"]
        case .tiktok:     return ["open.tiktokapis.com"]
        case .pinterest:  return ["api.pinterest.com"]
        case .hunter:     return ["api.hunter.io"]
        case .apollo:     return ["api.apollo.io"]
        case .prospeo:    return ["api.prospeo.io"]
        case .hubspot:    return ["api.hubapi.com"]
        case .salesforce: return ["salesforce.com"]
        case .pipedrive:  return ["pipedrive.com"]
        // Bluesky's public PDS. A buyer on a self-hosted PDS supplies their own host, which is
        // why the request builders take `host` rather than hardcoding one.
        case .bluesky:    return ["bsky.social"]
        // Mastodon is federated: there is NO central host, so the instance is always the
        // buyer's own and is named here as such rather than pretending to a fixed domain.
        case .mastodon:   return ["your Mastodon instance"]
        case .discord:    return ["discord.com", "discordapp.com"]
        case .overpassMain:          return ["overpass-api.de"]
        case .overpassPrivateCoffee: return ["overpass.private.coffee"]
        case .searchConsole: return ["www.googleapis.com"]
        case .blackLabelLeads: return ["blacklabel-leads-api.michael-070.workers.dev"]
        }
    }

    /// Exactly what leaves this device for this provider. Written to be shown VERBATIM to the
    /// buyer — no euphemism, and no claim smaller than what the code actually sends.
    var whatLeaves: String {
        switch self {
        case .sendblue:
            return "The recipient's phone number, your sending line, the full text of every message, and any media URL you attach — plus your Sendblue API key id and secret to authenticate."
        case .x, .linkedin, .facebook, .instagram, .threads, .youtube, .tiktok, .pinterest:
            return "The post text or caption you wrote, any image or video file attached to it, and your \(displayName) access token."
        case .hunter, .apollo, .prospeo:
            return "The contact's first and last name and their company domain — the two fields the finder needs — plus your \(displayName) API key. No other lead field is sent."
        case .hubspot, .salesforce, .pipedrive:
            return "The lead record you push: name, email, phone, company, and your notes on that lead — plus your \(displayName) access token."
        case .overpassMain, .overpassPrivateCoffee:
            return "The business search you run: the industry you picked, the map bounding box of the metro you chose from this app's built-in city list — never your device's location — and, when you type a business name, the letters and digits of that name. This operator is a volunteer public map service, so it also sees your IP address and this app's user-agent. No API key is sent (the service is keyless) and none of your leads, contacts, messages or files are ever included."
        case .bluesky:
            return "The post text you wrote and your Bluesky handle, plus the APP PASSWORD you issued in Bluesky's own settings — never your account password. The app password is exchanged for a short-lived session token per publish and is not stored on their side by this app."
        case .mastodon:
            return "The post text you wrote and the access token you issued yourself in your instance's Preferences → Development. It goes ONLY to the instance host you entered — Mastodon is federated, so there is no central server and this app never picks one for you."
        case .discord:
            return "The message text you wrote, posted to the webhook URL you created in your own server's channel settings. The URL itself IS the credential, so it is stored like one and never written to a log. No token, no lead, and no file is sent."
        case .searchConsole:
            return "The exact Search Console property you picked (your site's URL prefix or sc-domain: name), the date ranges you ask about, and your Google access token. Google returns your own search-performance rows; no lead, contact, message or file is ever sent."
        case .blackLabelLeads:
            return "Your catalog search terms (query, industry, state) and your subscription key. Your own leads, contacts and messages are never uploaded to it."
        }
    }
}

// MARK: - the record

/// A consent receipt. Not a secret: a provider id, when it was granted, and which disclosure
/// version the buyer actually read.
struct TransmissionConsentRecord: Codable, Equatable {
    var provider: String
    var grantedAt: Date
    var disclosureVersion: Int
}

/// The outcome of asking "may we transmit to this provider right now?".
enum TransmissionConsentDecision: Equatable {
    /// A current grant is on file.
    case granted
    /// Nothing was ever granted for this provider.
    case missing
    /// A grant exists but predates the current disclosure — the buyer never saw what we now send.
    case stale(recordedVersion: Int)

    var allowsTransmission: Bool { self == .granted }
}

// MARK: - the pure gate

enum TransmissionConsent {
    /// Bumped whenever `whatLeaves`/`hosts` change for ANY provider. A bump invalidates every
    /// grant taken under the old text — the buyer re-consents to the disclosure they can read.
    /// v2: the two public Overpass map operators joined the registry. They were transmitting the
    /// buyer's typed business searches with no entry and no gate at all; a buyer who consented
    /// under v1 was shown a disclosure that did not mention them, so v1 grants go stale.
    /// v3: Google Search Console joined the registry. Its reads go to www.googleapis.com — a host
    /// the registry already listed, but only under the YouTube upload disclosure, which says
    /// nothing about a property name or search-performance data. Routing that lane through
    /// Sources/ConsentedEgress.swift made the omission a build failure instead of a footnote.
    static let disclosureVersion = 3

    /// THE decision. Pure over its inputs, so the rule is executable in a headless suite.
    static func decide(record: TransmissionConsentRecord?,
                       currentVersion: Int = disclosureVersion) -> TransmissionConsentDecision {
        guard let record else { return .missing }
        guard record.disclosureVersion >= currentVersion else {
            return .stale(recordedVersion: record.disclosureVersion)
        }
        return .granted
    }

    /// The refusal the caller must show the buyer verbatim, or nil when the send may proceed.
    /// Never softened into a warning: the caller treats a non-nil return as "nothing was sent".
    static func refusal(for provider: TransmissionProvider,
                        record: TransmissionConsentRecord?,
                        currentVersion: Int = disclosureVersion) -> String? {
        switch decide(record: record, currentVersion: currentVersion) {
        case .granted:
            return nil
        case .missing:
            return "\(provider.displayName) hasn't been authorized to receive your data yet. "
                 + "Open Connectors → Data sharing, read what leaves this device, and allow "
                 + "\(provider.displayName) before sending. Nothing was sent."
        case .stale:
            return "What this app sends to \(provider.displayName) has changed since you allowed it. "
                 + "Re-read the disclosure in Connectors → Data sharing and allow it again. Nothing was sent."
        }
    }
}

// MARK: - the store (persisted receipts)

/// Persisted consent receipts. Deliberately device-local and deliberately NOT part of the
/// workspace snapshot that gets exported/imported — importing a workspace must never import
/// somebody else's consent.
enum TransmissionConsentStore {
    static let defaultsKey = "blm.transmissionConsent.v1"

    static func all(defaults: UserDefaults = .standard) -> [String: TransmissionConsentRecord] {
        guard let data = defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([String: TransmissionConsentRecord].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func write(_ records: [String: TransmissionConsentRecord], defaults: UserDefaults) {
        if records.isEmpty { defaults.removeObject(forKey: defaultsKey); return }
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: defaultsKey) }
    }

    static func record(for provider: TransmissionProvider,
                       defaults: UserDefaults = .standard) -> TransmissionConsentRecord? {
        all(defaults: defaults)[provider.rawValue]
    }

    /// Record an explicit grant. Only ever called from a control the buyer pressed.
    static func grant(_ provider: TransmissionProvider, at: Date = Date(),
                      version: Int = TransmissionConsent.disclosureVersion,
                      defaults: UserDefaults = .standard) {
        var records = all(defaults: defaults)
        records[provider.rawValue] = TransmissionConsentRecord(provider: provider.rawValue,
                                                               grantedAt: at,
                                                               disclosureVersion: version)
        write(records, defaults: defaults)
    }

    static func withdraw(_ provider: TransmissionProvider, defaults: UserDefaults = .standard) {
        var records = all(defaults: defaults)
        records.removeValue(forKey: provider.rawValue)
        write(records, defaults: defaults)
    }

    /// Delete-all-data / sign-out clears every receipt: a fresh install must ask again.
    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }

    static func decision(for provider: TransmissionProvider,
                         defaults: UserDefaults = .standard) -> TransmissionConsentDecision {
        TransmissionConsent.decide(record: record(for: provider, defaults: defaults))
    }

    /// The one call every transmit path makes. nil = proceed; a string = refuse and show it.
    static func refusal(for provider: TransmissionProvider,
                        defaults: UserDefaults = .standard) -> String? {
        TransmissionConsent.refusal(for: provider, record: record(for: provider, defaults: defaults))
    }

    static func isGranted(_ provider: TransmissionProvider, defaults: UserDefaults = .standard) -> Bool {
        decision(for: provider, defaults: defaults).allowsTransmission
    }
}

// The mappings from the app's own enums onto this registry live NEXT TO THOSE ENUMS
// (`SocialPlatform.transmissionProvider` in Social.swift, `EnrichmentVendor.transmissionProvider`
// in EnrichmentProvider.swift) so this file stays Foundation-only and compiles standalone in the
// headless suite. Adding a platform or a vendor is then a compile error until its disclosure
// exists here.
