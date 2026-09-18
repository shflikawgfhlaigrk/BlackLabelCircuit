#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — backend: domain models, persistence, auth, and marketing generators.
// Standalone. No network, no external deps. App Sandbox-safe (writes to the app container).
import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Small helpers

extension String {
    /// Capitalize only the first character, leaving the rest as typed.
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return String(f).uppercased() + dropFirst()
    }
}

// MARK: - Domain models

struct SiteProject: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var businessType: String = ""
    var city: String = ""
    var phone: String = ""
    var html: String = ""
    var content = SiteContent()   // the buyer's optional copy slots, persisted so they can re-edit
    var created = Date()
}

// Robust decode: `content` was added after SiteProject first shipped; default it so an older saved
// site still loads (synthesized Codable would throw keyNotFound on the missing key).
extension SiteProject {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        businessType = (try? c.decode(String.self, forKey: .businessType)) ?? ""
        city = (try? c.decode(String.self, forKey: .city)) ?? ""
        phone = (try? c.decode(String.self, forKey: .phone)) ?? ""
        html = (try? c.decode(String.self, forKey: .html)) ?? ""
        content = (try? c.decodeIfPresent(SiteContent.self, forKey: .content)) ?? SiteContent()
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
    }
}

struct Caption: Identifiable, Codable, Hashable {
    var id = UUID()
    var topic: String = ""
    var text: String = ""
    var created = Date()
}

/// One saved piece of generated content (any format) in the unified Content Library.
/// Persists blog/ad/email/landing/SMS/social/per-lane drafts — not just captions —
/// so the next draft builds on the last. Real text the buyer generated; never fabricated.
struct ContentItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var format: String = ""     // ContentFormat.rawValue, "Social — Instagram", etc. (the lane/format label)
    var topic: String = ""
    var title: String = ""      // short human label (first line / headline) for the library list
    var body: String = ""       // the full generated text
    var created = Date()
}

/// A real multi-touch conversion journey the operator logged: an ORDERED list of channels that
/// led to one conversion. Feeds true multi-touch + data-driven attribution. Never inferred.
struct ConversionPath: Identifiable, Codable, Hashable {
    var id = UUID()
    var label: String = ""        // optional note ("Q2 webinar lead")
    var steps: [String] = []      // ordered channel names, first → last touch
    var created = Date()
}

struct UTMLink: Identifiable, Codable, Hashable {
    var id = UUID()
    var label: String = ""
    var url: String = ""        // fully-built URL with UTM params
    var source: String = ""
    var medium: String = ""
    var campaign: String = ""
    var created = Date()
    /// Real, operator-logged engagement — clicks the buyer actually observed in their
    /// own analytics and recorded here. Never auto-incremented or fabricated.
    var clicks: Int = 0
    /// Conversions (form fills / sales) the buyer attributed to this link. Real, logged.
    var conversions: Int = 0
}

/// A lead captured from a generated landing page form, or entered manually. Feeds the CRM.
struct CapturedLead: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var email: String = ""
    var phone: String = ""
    var message: String = ""
    var sourceCampaign: String = ""    // which campaign/site it came from
    var created = Date()
}

// A drafted or automatically queued social post. New queue fields are optional so workspaces
// created by older builds decode without migration or data loss.
struct ScheduledPost: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var body: String = ""
    var channel: String = "Instagram"   // intended channel (operator copies & posts)
    var scheduledAt: Date = Date()
    var created = Date()
    var platformRaw: String? = nil
    var mediaPath: String? = nil
    var mediaPublicURL: String? = nil
    var mediaIsVideo: Bool? = nil
    var autoPublish: Bool? = nil
    var publishState: String? = nil       // scheduled | publishing | published | failed
    var publishDetail: String? = nil
    var publishedAt: Date? = nil
}

// The marketing channels the pipeline drafts copy for (operator copies & posts manually).
enum MarketingChannel: String, CaseIterable, Identifiable {
    case instagram = "Instagram", tiktok = "TikTok", x = "X",
         facebook = "Facebook", linkedin = "LinkedIn", threads = "Threads"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .instagram: return "camera.fill"
        case .tiktok: return "music.note"
        case .x: return "xmark"
        case .facebook: return "f.circle.fill"
        case .linkedin: return "briefcase.fill"
        case .threads: return "at"
        }
    }
}

// A business found via the area finder and saved as a client to pitch.
struct ClientLead: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var domain: String = ""
    var phone: String = ""
    var email: String = ""
    var address: String = ""
    var industry: String = ""
    var created = Date()
}

// A spotlight email actually composed and handed to the buyer's mail client.
// We log it ONLY when the compose step is opened — never a fabricated "delivered".
struct SpotlightRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var client: String = ""
    var subject: String = ""
    var to: String = ""
    var status: String = "Composed"     // honest: "Composed" (handed to Mail), never "Delivered"
    var created = Date()
}

// MARK: - Persistence (real backend — SQLite in the sandbox container)
final class AppModel: ObservableObject {
    @Published var sites: [SiteProject] = []    { didSet { save() } }
    @Published var captions: [Caption] = []     { didSet { save() } }
    @Published var contentLibrary: [ContentItem] = [] { didSet { save() } }
    @Published var creativeIdeations: [CreativeIdeationBatch] = [] { didSet { save() } }
    @Published var conversionPaths: [ConversionPath] = [] { didSet { save() } }
    @Published var links: [UTMLink] = []        { didSet { save() } }
    @Published var posts: [ScheduledPost] = []  { didSet { save() } }
    @Published var spotlights: [SpotlightRecord] = [] { didSet { save() } }
    @Published var reels: [ReelProject] = []    { didSet { save() } }
    /// The ONE lead pool (unified 2026-07 merge): site-form captures, finder hits, Lead-Database
    /// imports, CSV imports, and manual adds all live here as `Lead` records.
    @Published var leads: [Lead] = []           { didSet { contactsGeneration &+= 1; scoreEpoch &+= 1; save() } }
    // Pipeline / CRM domain (merged from Black Label Leads)
    @Published var deals: [Deal] = []           { didSet { save() } }
    @Published var tasks: [LeadTask] = []       { didSet { save() } }
    @Published var activities: [Activity] = []  { didSet { scoreEpoch &+= 1; save() } }
    @Published var lists: [LeadList] = []       { didSet { save() } }
    @Published var sequences: [OutreachSequence] = [] { didSet { save() } }
    @Published var enrollments: [Enrollment] = [] { didSet { save() } }
    @Published var sendDays: [SendDay] = []     { didSet { save() } }
    @Published var savedSearches: [SavedSearch] = [] { didSet { save() } }
    @Published var inbox: [InboxMessage] = []   { didSet { save() } }
    @Published var callLogs: [CallLog] = []     { didSet { save() } }
    @Published var workflowRules: [WorkflowRule] = [] { didSet { save() } }
    // Score-cache invalidation token (merged from Leads): any change to leads or activities (the
    // only inputs to a LeadScore besides the buyer's ICP) bumps this; the memoized score cache
    // rebuilds lazily on the next read whose (epoch, icp) differs. `&+=` wraps without trapping.
    var scoreEpoch: Int = 0
    var scoreCacheStore: [UUID: LeadScore] = [:]
    var scoreCacheEpoch: Int = -1
    var scoreCacheICP: ICP? = nil
    @Published var segments: [Segment] = []     { didSet { save() } }
    @Published var campaigns: [EmailCampaign] = [] { didSet { save() } }
    @Published var audits: [AuditRecord] = []   { didSet { save() } }
    @Published var socialProfiles: [SocialProfile] = [] { didSet { save() } }
    @Published var adCampaigns: [AdCampaign] = [] { didSet { save() } }
    @Published var journeys: [Journey] = []     { didSet { save() } }
    @Published var journeyRuns: [JourneyRun] = [] { didSet { save() } }
    @Published var senders: [SenderIdentity] = [] { didSet { save() } }
    @Published var newsletters: [Newsletter] = [] { didSet { save() } }
    @Published var postStats: [PostEngagement] = [] { didSet { contactsGeneration &+= 1; save() } }
    @Published var influencers: [Influencer] = [] { didSet { save() } }
    @Published var landingTests: [LandingTest] = [] { didSet { save() } }
    @Published var workflows: [Workflow] = []   { didSet { save() } }
    // PASS 5 — tier 3/4 collections (all on the buyer's OWN data)
    @Published var mcampaigns: [MCampaign] = [] { didSet { save() } }
    @Published var abmAccounts: [ABMAccount] = [] { didSet { save() } }
    @Published var referralPrograms: [ReferralProgram] = [] { didSet { save() } }
    @Published var roadItems: [RoadItem] = []   { didSet { save() } }
    @Published var auditLog: [AuditEvent] = []  { didSet { save() } }

    // Persistence-integrity state (session-only — not in Box, no save() didSet).
    // `storeRecoveryNotice`: load() found a workspace store it could not read or decode; the
    // original payload is preserved on disk before anything may overwrite it, and this notice
    // stays up until dismissed. `saveFailureNotice`: the latest save landed NOWHERE; it clears
    // itself on the next save that reaches disk. The shell surfaces both — a save that silently
    // vanishes or a store that silently opens empty are never acceptable states.
    @Published var storeRecoveryNotice: String? = nil
    @Published var saveFailureNotice: String? = nil

    // MARK: - Contact-pool cache (perf)
    // `allContacts` rebuilds + dedupes the whole pool from `leads` + `clients`; with a large
    // Lead-Database import this is O(n) and was re-run several times per render on the Audience,
    // Workflows, Lookalike, Email-Builder and Lead-Scoring screens (some O(segments × contacts)).
    // We cache the rebuilt pool — and a derived per-contact touch-count index + lower-cased
    // postStats-channel list — keyed on a generation counter that bumps whenever `leads`,
    // `clients`, or `postStats` change. Reads become O(1) until the underlying data mutates.
    // `internal` (not private) so the cache lives on the same actor; never persisted.
    // Module-internal (not fileprivate) so the extensions in Audience.swift / GrowthEngine.swift
    // that own `allContacts` and `scoredContacts` can read+write the cache. The leading underscore
    // marks them as cache internals not meant for screen code. Never persisted (not in Box).
    var contactsGeneration: Int = 0
    var _contactsCache: [Contact]? = nil
    var _contactsCacheGen: Int = -1
    var _touchChannelsLowered: [String]? = nil   // postStats channels, lowercased once
    var _touchIndexGen: Int = -1

    private struct Box: Codable {
        var sites: [SiteProject]; var captions: [Caption]; var links: [UTMLink]
        var contentLibrary: [ContentItem]?
        var creativeIdeations: [CreativeIdeationBatch]?
        var conversionPaths: [ConversionPath]?
        var posts: [ScheduledPost]?
        // Legacy (pre-merge) collections — DECODE ONLY; save() writes unifiedLeads instead.
        var clients: [ClientLead]?
        var leads: [CapturedLead]?
        var spotlights: [SpotlightRecord]?
        var reels: [ReelProject]?
        // v2 (2026-07 Leads merge): the unified pool + pipeline collections.
        var unifiedLeads: [Lead]?
        var deals: [Deal]?
        var tasks: [LeadTask]?
        var activities: [Activity]?
        var lists: [LeadList]?
        var sequences: [OutreachSequence]?
        var enrollments: [Enrollment]?
        var sendDays: [SendDay]?
        var savedSearches: [SavedSearch]?
        var inbox: [InboxMessage]?
        var callLogs: [CallLog]?
        var workflowRules: [WorkflowRule]?
        var segments: [Segment]?
        var campaigns: [EmailCampaign]?
        var audits: [AuditRecord]?
        var socialProfiles: [SocialProfile]?
        var adCampaigns: [AdCampaign]?
        var journeys: [Journey]?
        var journeyRuns: [JourneyRun]?
        var senders: [SenderIdentity]?
        var newsletters: [Newsletter]?
        var postStats: [PostEngagement]?
        var influencers: [Influencer]?
        var landingTests: [LandingTest]?
        var workflows: [Workflow]?
        var mcampaigns: [MCampaign]?
        var abmAccounts: [ABMAccount]?
        var referralPrograms: [ReferralProgram]?
        var roadItems: [RoadItem]?
        var auditLog: [AuditEvent]?
    }
    private var database: WorkspaceDatabase
    private var legacyURL: URL
    private var loading = false
    private var batching = false     // suppress per-mutation saves inside batch { } — save once at the end
    /// True when load() found the appData blob PRESENT but unreadable (SQLite error, not absence).
    /// The row may still be intact on disk, so save() must not overwrite it — the only copy that
    /// might be recovered — and routes to the legacy JSON fallback instead for this session.
    private var protectUnreadableBlob = false
    /// Sidecar marker: exists while the legacy JSON fallback holds a NEWER workspace than the
    /// SQLite blob (a save whose blob write failed). load() prefers the fallback while the marker
    /// exists — without it, the next launch silently rolls back to the stale blob.
    private var legacyNewerMarkerURL: URL { legacyURL.appendingPathExtension("newer") }

    /// Run a bulk mutation (CSV import, dedupe, bulk enrich/tag/delete) with per-mutation saves
    /// suppressed, then persist exactly once. Without this, looping `upsert`/`log` over thousands
    /// of rows triggers one full-store JSON encode PER row on the main thread.
    func batch(_ body: () -> Void) {
        let wasBatching = batching
        batching = true
        body()
        if !wasBatching { batching = false; save() }
    }

    /// Legacy JSON filename used only for first-run migration/fallback. Real buyer data
    /// vs isolated demo data still stay separate so demo cannot overwrite buyer data.
    private static func legacyStoreURL(demo: Bool) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(demo ? "data-demo.json" : "data.json")
    }

    init() {
        database = WorkspaceDatabase(demo: DemoMode.active)
        legacyURL = AppModel.legacyStoreURL(demo: DemoMode.active)
        load()
    }

    /// Repoint this store at the isolated demo file, wipe any prior demo contents,
    /// and re-seed a fresh sample workspace. Used by the "Explore with sample data"
    /// entry. Never touches the real workspace database.
    func enterDemo(prefs: Prefs) {
        DemoMode.enable()
        database = WorkspaceDatabase(demo: true)
        legacyURL = AppModel.legacyStoreURL(demo: true)
        protectUnreadableBlob = false; storeRecoveryNotice = nil; saveFailureNotice = nil   // per-store state — reset on repoint
        try? database.deleteBlob(named: WorkspaceDatabase.appDataBlobName)
        try? FileManager.default.removeItem(at: legacyURL)   // migrate/fallback file, if one exists
        try? FileManager.default.removeItem(at: legacyNewerMarkerURL)
        loading = true
        sites = []; captions = []; contentLibrary = []; creativeIdeations = []; conversionPaths = []; links = []; posts = []
        spotlights = []; reels = []; leads = []; segments = []; campaigns = []
        deals = []; tasks = []; activities = []; lists = []; sequences = []; enrollments = []
        sendDays = []; savedSearches = []; inbox = []; callLogs = []; workflowRules = []
        audits = []; socialProfiles = []; adCampaigns = []; journeys = []
        journeyRuns = []; senders = []; newsletters = []
        postStats = []; influencers = []; landingTests = []; workflows = []
        mcampaigns = []; abmAccounts = []; referralPrograms = []; roadItems = []
        auditLog = []
        loading = false
        prefs.enterDemo()                 // demo brand into the isolated prefs store
        DemoData.seed(model: self, prefs: prefs)   // populate every collection (triggers save)
    }

    /// Leave reviewer/demo mode and switch to the buyer's REAL workspace. Turns off the
    /// demo flag, repoints this store at the real SQLite file (the buyer's own data —
    /// empty on first run), and loads it. The isolated demo database is left untouched on
    /// disk so a later demo re-entry stays clean; nothing demo bleeds into real.
    /// One obvious path from "trying it" to "using it for real" (Connect your own & go live).
    func exitDemo(prefs: Prefs) {
        DemoMode.disable()
        prefs.exitDemo()                       // restore the buyer's real (empty) brand prefs
        database = WorkspaceDatabase(demo: false)   // back to the real store
        legacyURL = AppModel.legacyStoreURL(demo: false)
        protectUnreadableBlob = false; storeRecoveryNotice = nil; saveFailureNotice = nil   // per-store state — load() below re-derives it
        loading = true
        sites = []; captions = []; contentLibrary = []; creativeIdeations = []; conversionPaths = []; links = []; posts = []
        spotlights = []; reels = []; leads = []; segments = []; campaigns = []
        deals = []; tasks = []; activities = []; lists = []; sequences = []; enrollments = []
        sendDays = []; savedSearches = []; inbox = []; callLogs = []; workflowRules = []
        audits = []; socialProfiles = []; adCampaigns = []; journeys = []
        journeyRuns = []; senders = []; newsletters = []
        postStats = []; influencers = []; landingTests = []; workflows = []
        mcampaigns = []; abmAccounts = []; referralPrograms = []; roadItems = []
        auditLog = []
        loading = false
        load()                                 // load the buyer's real data (empty on first run)
    }

    private func load() {
        // The ONE legacy-JSON read (a workspace file this app wrote, egress-surface declared):
        // shared by the newer-fallback marker path and the first-run migration fallback below.
        let legacyData = try? Data(contentsOf: legacyURL)
        // A save() that could not reach SQLite left its data in the legacy JSON plus a marker;
        // that fallback is NEWER than the blob and must win this load. It is folded back into
        // the blob, and the marker cleared, only once that write succeeds.
        if FileManager.default.fileExists(atPath: legacyNewerMarkerURL.path),
           let data = legacyData,
           let box = try? JSONDecoder().decode(Box.self, from: data) {
            apply(box)
            if (try? database.writeBlob(data, named: WorkspaceDatabase.appDataBlobName)) != nil {
                try? FileManager.default.removeItem(at: legacyNewerMarkerURL)
            }
            return
        }
        // Three blob states, on purpose: absent (nil) falls through to the legacy migration
        // file; unreadable (SQLite throw) and present-but-undecodable are surfaced and the
        // payload protected — never treated as a fresh install, where the first edit's save()
        // would overwrite the only recoverable copy of the workspace.
        let blob: Data?
        do { blob = try database.readBlob(named: WorkspaceDatabase.appDataBlobName) }
        catch {
            protectUnreadableBlob = true
            storeRecoveryNotice = "Your workspace store couldn't be opened (\(error.localizedDescription)). "
                + "Your data is still on disk, untouched — quit and reopen to retry. Anything you change now is kept in a separate fallback file."
            return   // no legacy fallback here: it is older data and loading it would silently roll the workspace back
        }
        if let data = blob {
            if let box = try? JSONDecoder().decode(Box.self, from: data) {
                apply(box)
                return
            }
            preserveUndecodableStore(data)
        }
        guard let data = legacyData,
              let box = try? JSONDecoder().decode(Box.self, from: data) else { return }
        apply(box)
        try? database.writeBlob(data, named: WorkspaceDatabase.appDataBlobName)
    }

    /// Copy an appData payload that exists but no longer decodes to a timestamped file beside the
    /// legacy JSON, then surface a recovery notice. Only after the copy is safe may the session
    /// continue (older legacy data or empty) — later saves can then overwrite the blob row without
    /// destroying the one recoverable original.
    private func preserveUndecodableStore(_ data: Data) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = legacyURL.deletingLastPathComponent()
            .appendingPathComponent("appData.corrupt-\(stamp).json")
        if (try? data.write(to: dest, options: .atomic)) != nil {
            storeRecoveryNotice = "Your saved workspace couldn't be read. The unreadable file was preserved as \(dest.lastPathComponent) in Application Support, and the app opened from the most recent readable copy (empty if none). Contact support to recover the preserved file."
        } else {
            // The aside copy failed too — the blob row is now the only copy of the payload,
            // so protect it from save() exactly like the unreadable case.
            protectUnreadableBlob = true
            storeRecoveryNotice = "Your saved workspace couldn't be read, and a backup copy couldn't be written. The original is untouched on disk; anything you change now is kept in a separate fallback file. Contact support to recover it."
        }
    }

    private func apply(_ box: Box) {
        loading = true
        var migratedLegacyWebsiteData = false
        sites = box.sites; captions = box.captions; links = box.links; posts = box.posts ?? []
        contentLibrary = box.contentLibrary ?? []
        creativeIdeations = box.creativeIdeations ?? []
        conversionPaths = box.conversionPaths ?? []
        spotlights = box.spotlights ?? []
        reels = box.reels ?? []
        // Unified pool: v2 data loads directly; a pre-merge box upgrades its captured leads
        // (site forms) + finder clients into Lead records once, preserving IDs and dates.
        if let unified = box.unifiedLeads {
            leads = unified.map { lead in
                var fixed = lead
                if fixed.source == .siteForm && fixed.sourceCampaign.localizedCaseInsensitiveContains("apollo") {
                    fixed.source = .imported
                    migratedLegacyWebsiteData = true
                }
                return fixed
            }
        } else {
            leads = (box.leads ?? []).map(Lead.init(legacy:)) + (box.clients ?? []).map(Lead.init(legacy:))
        }

        // Upgrade only the tagged machine-generated records created by the retired website feed.
        // Buyer-created sites, copy, reels, IDs, and all unrelated fields stay untouched.
        let retiredMarketingCopy = "Coming Soon — Marketing Engine not publicly live"
        let liveMarketingCopy = "Marketing is live with promo reels, landing pages, email, CRM tools, and the included U.S. lead database. Direct posting remains connector-gated."
        sites = sites.map { project in
            guard project.name.hasPrefix("[BlackLabelWebsiteLive]") else { return project }
            var fixed = project
            if fixed.city.localizedCaseInsensitiveCompare("blacklabelbots.com") == .orderedSame {
                fixed.city = ""
                migratedLegacyWebsiteData = true
            }
            let oldContent = fixed.content
            // The retired feed's about text announced operator status (a "coming soon" notice with
            // operator-DB post counts). That sentence must not ship verbatim inside the customer
            // binary (DOD-10.4 — operator copy in the artifact), so the tagged records are matched
            // on its two stable fragments instead of the whole operator string. Only records with
            // the [BlackLabelWebsiteLive] machine prefix reach this branch, so no buyer-authored
            // about text can ever match.
            if fixed.content.about.localizedCaseInsensitiveContains("coming soon"),
               fixed.content.about.localizedCaseInsensitiveContains("operator") {
                fixed.content.about = liveMarketingCopy
            }
            fixed.content.services = fixed.content.services.map { service in
                var updated = service
                if updated.detail.localizedCaseInsensitiveContains(retiredMarketingCopy) {
                    updated.detail = liveMarketingCopy
                }
                return updated
            }
            if fixed.content != oldContent || fixed.html.localizedCaseInsensitiveContains(retiredMarketingCopy) || fixed.html.contains("maps.google.com/?q=blacklabelbots.com") {
                fixed.html = Studio.landingPage(name: "Black Label Bots Live Snapshot",
                                                type: fixed.businessType,
                                                city: "",
                                                phone: fixed.phone,
                                                template: .bold,
                                                palette: .gold,
                                                headline: fixed.content.services.first?.detail ?? "Black Label Bots live data",
                                                subheadOverride: liveMarketingCopy,
                                                content: fixed.content)
                migratedLegacyWebsiteData = true
            }
            return fixed
        }
        captions = captions.map { caption in
            guard caption.topic.hasPrefix("[BlackLabelWebsiteLive]"),
                  caption.text.localizedCaseInsensitiveContains(retiredMarketingCopy) else { return caption }
            var fixed = caption
            fixed.text = liveMarketingCopy
            migratedLegacyWebsiteData = true
            return fixed
        }
        reels = reels.map { reel in
            guard reel.name.hasPrefix("[BlackLabelWebsiteLive]") else { return reel }
            var fixed = reel
            fixed.scenes = fixed.scenes.map { scene in
                var updated = scene
                if updated.headline.localizedCaseInsensitiveContains(retiredMarketingCopy) {
                    updated.headline = "Marketing is live"
                    updated.subtitle = liveMarketingCopy
                    updated.voiceScript = ""
                    migratedLegacyWebsiteData = true
                }
                return updated
            }
            return fixed
        }
        deals = box.deals ?? []; tasks = box.tasks ?? []; activities = box.activities ?? []
        lists = box.lists ?? []; sequences = box.sequences ?? []; enrollments = box.enrollments ?? []
        sendDays = box.sendDays ?? []; savedSearches = box.savedSearches ?? []
        inbox = box.inbox ?? []; callLogs = box.callLogs ?? []; workflowRules = box.workflowRules ?? []
        segments = box.segments ?? []; campaigns = box.campaigns ?? []
        audits = box.audits ?? []
        socialProfiles = box.socialProfiles ?? []; adCampaigns = box.adCampaigns ?? []
        refreshSocialCredentialFlags()
        journeys = box.journeys ?? []; postStats = box.postStats ?? []
        journeyRuns = box.journeyRuns ?? []; senders = box.senders ?? []; newsletters = box.newsletters ?? []
        influencers = box.influencers ?? []
        landingTests = box.landingTests ?? []; workflows = box.workflows ?? []
        mcampaigns = box.mcampaigns ?? []; abmAccounts = box.abmAccounts ?? []
        referralPrograms = box.referralPrograms ?? []; roadItems = box.roadItems ?? []
        auditLog = box.auditLog ?? []
        loading = false
        if migratedLegacyWebsiteData { save() }
    }

    private func save() {
        guard !loading, !batching else { return }
        let box = Box(sites: sites, captions: captions, links: links, contentLibrary: contentLibrary, creativeIdeations: creativeIdeations, conversionPaths: conversionPaths, posts: posts, clients: nil,
                      leads: nil,   // legacy keys retired — the unified pool is the record
                      spotlights: spotlights, reels: reels,
                      unifiedLeads: leads, deals: deals, tasks: tasks, activities: activities,
                      lists: lists, sequences: sequences, enrollments: enrollments, sendDays: sendDays,
                      savedSearches: savedSearches, inbox: inbox, callLogs: callLogs, workflowRules: workflowRules,
                      segments: segments, campaigns: campaigns, audits: audits,
                      socialProfiles: socialProfiles, adCampaigns: adCampaigns,
                      journeys: journeys, journeyRuns: journeyRuns, senders: senders, newsletters: newsletters,
                      postStats: postStats, influencers: influencers,
                      landingTests: landingTests, workflows: workflows,
                      mcampaigns: mcampaigns, abmAccounts: abmAccounts,
                      referralPrograms: referralPrograms, roadItems: roadItems, auditLog: auditLog)
        guard let data = try? JSONEncoder().encode(box) else {
            saveFailureNotice = "Your latest changes couldn't be prepared for saving — they are NOT on disk yet."
            return
        }
        // While the blob row is protected (present but unreadable at load), overwriting it would
        // destroy the copy that might still be recovered — route straight to the fallback.
        if !protectUnreadableBlob {
            do {
                try database.writeBlob(data, named: WorkspaceDatabase.appDataBlobName)
                // The blob now holds the newest workspace — an older fallback must not shadow it.
                try? FileManager.default.removeItem(at: legacyNewerMarkerURL)
                saveFailureNotice = nil
                return
            } catch { /* fall through to the legacy fallback */ }
        }
        do {
            try data.write(to: legacyURL, options: .atomic)
            // Marker: the fallback is now NEWER than the blob; load() prefers it until the
            // data is folded back into a working blob. Written strictly AFTER the payload —
            // a marker pointing at stale legacy data would itself cause a rollback.
            do {
                try Data().write(to: legacyNewerMarkerURL)
                saveFailureNotice = nil
            } catch {
                saveFailureNotice = "Your changes were saved to a fallback file, but its marker couldn't be written (\(error.localizedDescription)) — they may not load on the next launch. Keep the app open and retry with any small edit."
            }
        } catch {
            saveFailureNotice = "Saving failed — your latest changes are NOT on disk (\(error.localizedDescription)). Check free disk space, then make any small edit to retry."
        }
    }

    /// App Store 5.1.1(v): in-account deletion. Clears EVERY collection on the buyer's
    /// own data, removes the on-disk store, and resets in memory. (auditLog is kept
    /// in memory through this call only long enough to record the deletion, then wiped.)
    func deleteAllData() {
        loading = true
        sites = []; captions = []; contentLibrary = []; creativeIdeations = []; conversionPaths = []; links = []; posts = []
        spotlights = []; reels = []; leads = []; segments = []; campaigns = []
        deals = []; tasks = []; activities = []; lists = []; sequences = []; enrollments = []
        sendDays = []; savedSearches = []; inbox = []; callLogs = []; workflowRules = []
        audits = []; socialProfiles = []; adCampaigns = []; journeys = []
        journeyRuns = []; senders = []; newsletters = []
        postStats = []; influencers = []; landingTests = []; workflows = []
        mcampaigns = []; abmAccounts = []; referralPrograms = []; roadItems = []
        auditLog = []
        loading = false
        // An explicit delete-everything overrides blob protection: the buyer chose deletion,
        // so the trailing save() may write the (now empty) blob row.
        protectUnreadableBlob = false; storeRecoveryNotice = nil; saveFailureNotice = nil
        try? database.deleteBlob(named: WorkspaceDatabase.appDataBlobName)
        try? FileManager.default.removeItem(at: legacyURL)
        try? FileManager.default.removeItem(at: legacyNewerMarkerURL)
        SessionStore.clear()   // delete-all-data also forgets any remembered Keychain session
        SocialCredentialStore.clearAll()
        save()
    }

    // Reel projects CRUD
    func upsertReel(_ r: ReelProject) {
        if let i = reels.firstIndex(where: { $0.id == r.id }) { reels[i] = r } else { reels.insert(r, at: 0) }
    }
    func deleteReel(_ r: ReelProject) { reels.removeAll { $0.id == r.id } }

    // Lead CRUD (unified pool)
    func addLead(_ l: Lead) {
        leads.insert(l, at: 0)
        NotificationCenter.default.post(name: .blmLeadAdded, object: nil, userInfo: ["lead": l])
    }
    func deleteLead(_ l: Lead) { leads.removeAll { $0.id == l.id } }

    // Real engagement logging (operator-recorded; never fabricated)
    func logClicks(_ link: UTMLink, add: Int) {
        guard let i = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[i].clicks = max(0, links[i].clicks + add)
    }
    func logConversions(_ link: UTMLink, add: Int) {
        guard let i = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[i].conversions = max(0, links[i].conversions + add)
    }

    /// Aggregate analytics from REAL stored data only (no invented reach).
    var totalLoggedClicks: Int { links.reduce(0) { $0 + $1.clicks } }
    var totalLoggedConversions: Int { links.reduce(0) { $0 + $1.conversions } }
    // Spotlight log (honest record of composed emails)
    func logSpotlight(_ s: SpotlightRecord) { spotlights.insert(s, at: 0) }
    func deleteSpotlight(_ s: SpotlightRecord) { spotlights.removeAll { $0.id == s.id } }
    // Finder-sourced lead CRUD (businesses found by area to pitch) — stored in the unified pool.
    func addClient(_ c: Lead) {
        let key = c.company.isEmpty ? c.name : c.company
        guard !leads.contains(where: {
            ($0.company.isEmpty ? $0.name : $0.company).caseInsensitiveCompare(key) == .orderedSame && $0.domain == c.domain
        }) else { return }
        leads.insert(c, at: 0)
    }
    func deleteClient(_ c: Lead) { leads.removeAll { $0.id == c.id } }
    /// Finder-sourced slice of the unified pool (the old "saved clients" view).
    var clientLeads: [Lead] { leads.filter { $0.source == .finder } }

    // Site projects CRUD
    func upsert(_ s: SiteProject) {
        if let i = sites.firstIndex(where: { $0.id == s.id }) { sites[i] = s } else { sites.insert(s, at: 0) }
    }
    func deleteSite(_ s: SiteProject) { sites.removeAll { $0.id == s.id } }

    // Captions CRUD
    func addCaption(_ c: Caption) { captions.insert(c, at: 0) }
    func deleteCaption(_ c: Caption) { captions.removeAll { $0.id == c.id } }

    // Content Library CRUD (all generated formats persist here, newest first)
    func addContentItem(_ c: ContentItem) { contentLibrary.insert(c, at: 0) }
    func deleteContentItem(_ c: ContentItem) { contentLibrary.removeAll { $0.id == c.id } }

    // Creative ideation CRUD (each generated turn persists, newest first)
    func saveCreativeIdeation(brand: String, does: String, audience: String, goal: String, concepts: [CreativeConcept], usedAI: Bool) {
        guard !concepts.isEmpty else { return }
        let batch = CreativeIdeationBatch(brand: brand, does: does, audience: audience, goal: goal, concepts: concepts, usedAI: usedAI)
        creativeIdeations.insert(batch, at: 0)
    }
    func clearCreativeIdeations() { creativeIdeations.removeAll() }

    // Conversion-journey CRUD (operator-logged ordered paths for multi-touch attribution)
    func addConversionPath(_ p: ConversionPath) { conversionPaths.insert(p, at: 0) }
    func deleteConversionPath(_ p: ConversionPath) { conversionPaths.removeAll { $0.id == p.id } }

    // Links CRUD
    func addLink(_ l: UTMLink) { links.insert(l, at: 0) }
    func deleteLink(_ l: UTMLink) { links.removeAll { $0.id == l.id } }

    // Scheduled posts CRUD (content pipeline)
    func schedule(_ p: ScheduledPost) { posts.insert(p, at: 0); posts.sort { $0.scheduledAt < $1.scheduledAt } }
    func deletePost(_ p: ScheduledPost) { posts.removeAll { $0.id == p.id } }
    func updatePost(_ id: UUID, _ change: (inout ScheduledPost) -> Void) {
        guard let index = posts.firstIndex(where: { $0.id == id }) else { return }
        change(&posts[index])
    }
}

// MARK: - Portable workspace backup / restore

struct MarketingDataSnapshot: Codable, Hashable {
    var sites: [SiteProject]
    var captions: [Caption]
    var contentLibrary: [ContentItem] = []   // default → older backups without it still decode
    var creativeIdeations: [CreativeIdeationBatch]?
    var conversionPaths: [ConversionPath] = []
    var links: [UTMLink]
    var posts: [ScheduledPost]
    // Legacy (schema v1) collections — decode-only; v2 writes unifiedLeads instead.
    var clients: [ClientLead] = []
    var spotlights: [SpotlightRecord]
    var reels: [ReelProject]
    var leads: [CapturedLead] = []
    // v2 (2026-07 Leads merge)
    var unifiedLeads: [Lead] = []
    var deals: [Deal] = []
    var crmTasks: [LeadTask] = []
    var activities: [Activity] = []
    var lists: [LeadList] = []
    var sequences: [OutreachSequence] = []
    var enrollments: [Enrollment] = []
    var sendDays: [SendDay] = []
    var savedSearches: [SavedSearch] = []
    var inboxMessages: [InboxMessage] = []
    var callLogs: [CallLog] = []
    var workflowRules: [WorkflowRule] = []
    var segments: [Segment]
    var campaigns: [EmailCampaign]
    var audits: [AuditRecord]
    var socialProfiles: [SocialProfile]
    var adCampaigns: [AdCampaign]
    var journeys: [Journey]
    var journeyRuns: [JourneyRun] = []
    var senders: [SenderIdentity] = []
    var newsletters: [Newsletter] = []
    var postStats: [PostEngagement]
    var influencers: [Influencer]
    var landingTests: [LandingTest]
    var workflows: [Workflow]
    var mcampaigns: [MCampaign]
    var abmAccounts: [ABMAccount]
    var referralPrograms: [ReferralProgram]
    var roadItems: [RoadItem]
    var auditLog: [AuditEvent]

    init(model: AppModel) {
        sites = model.sites
        captions = model.captions
        contentLibrary = model.contentLibrary
        creativeIdeations = model.creativeIdeations
        conversionPaths = model.conversionPaths
        links = model.links
        posts = model.posts
        spotlights = model.spotlights
        reels = model.reels
        unifiedLeads = model.leads
        deals = model.deals; crmTasks = model.tasks; activities = model.activities
        lists = model.lists; sequences = model.sequences; enrollments = model.enrollments
        sendDays = model.sendDays; savedSearches = model.savedSearches
        inboxMessages = model.inbox; callLogs = model.callLogs; workflowRules = model.workflowRules
        segments = model.segments
        campaigns = model.campaigns
        audits = model.audits
        socialProfiles = model.socialProfiles
        adCampaigns = model.adCampaigns
        journeys = model.journeys
        journeyRuns = model.journeyRuns; senders = model.senders; newsletters = model.newsletters
        postStats = model.postStats
        influencers = model.influencers
        landingTests = model.landingTests
        workflows = model.workflows
        mcampaigns = model.mcampaigns
        abmAccounts = model.abmAccounts
        referralPrograms = model.referralPrograms
        roadItems = model.roadItems
        auditLog = model.auditLog
    }
}

struct MarketingPrefsSnapshot: Codable, Hashable {
    var brandName: String
    var tagline: String
    var accent: AccentChoice
    var logoData: Data?
    var defaultMarket: String
    var defaultVertical: String
    var siteTemplate: SiteTemplate
    var sitePalette: SitePalette
    var captionTone: CaptionTone
    var captionHashtag: String
    var senderName: String
    var senderEmail: String
    var formEndpoint: String
    var contactEmail: String
    var motionEnabled: Bool
    var leadScoreWeights: LeadScoreWeights
    var holoTheme: HoloTheme
    var holoBackgroundData: Data?
    var holoPresets: [HoloPreset]
    var profiles: [BrandProfile]

    init(prefs: Prefs) {
        brandName = prefs.brandName
        tagline = prefs.tagline
        accent = prefs.accent
        logoData = prefs.logoData
        defaultMarket = prefs.defaultMarket
        defaultVertical = prefs.defaultVertical
        siteTemplate = prefs.siteTemplate
        sitePalette = prefs.sitePalette
        captionTone = prefs.captionTone
        captionHashtag = prefs.captionHashtag
        senderName = prefs.senderName
        senderEmail = prefs.senderEmail
        formEndpoint = prefs.formEndpoint
        contactEmail = prefs.contactEmail
        motionEnabled = prefs.motionEnabled
        leadScoreWeights = prefs.leadScoreWeights
        holoTheme = prefs.holoTheme
        holoBackgroundData = prefs.holoBackgroundData
        holoPresets = prefs.holoPresets
        profiles = prefs.profiles
    }
}

enum MarketingWorkspaceBackupError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalid([String])

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported workspace backup version \(version)."
        case .invalid(let issues):
            return "Workspace backup rejected: \(issues.joined(separator: "; "))"
        }
    }
}

struct MarketingWorkspaceBackup: Codable, Hashable {
    static let currentSchemaVersion = 2   // v2: unified Lead pool + pipeline collections (2026-07 merge)

    var schemaVersion: Int = MarketingWorkspaceBackup.currentSchemaVersion
    var exportedAt: Date = Date()
    var appName: String = AppBrand.displayName
    var credentialPolicy: String = "Excludes Google OAuth client IDs, Lead Database keys, social access tokens, Keychain sessions, and UserDefaults credentials."
    var data: MarketingDataSnapshot
    var prefs: MarketingPrefsSnapshot

    init(data: MarketingDataSnapshot, prefs: MarketingPrefsSnapshot, exportedAt: Date = Date()) {
        self.exportedAt = exportedAt
        self.data = data
        self.prefs = prefs
    }

    var summary: String {
        "\(data.unifiedLeads.count + data.clients.count + data.leads.count) leads, \(data.deals.count) deals, \(data.sequences.count) sequences, \(data.sites.count) sites, \(data.campaigns.count) email campaigns, \(data.posts.count) scheduled posts, \(data.reels.count) reels, \(data.audits.count) audits, \(data.workflows.count) workflows. Credentials excluded."
    }

    func validate() throws {
        guard schemaVersion == MarketingWorkspaceBackup.currentSchemaVersion || schemaVersion == 1 else {
            throw MarketingWorkspaceBackupError.unsupportedVersion(schemaVersion)
        }
        let issues = validationIssues()
        guard issues.isEmpty else { throw MarketingWorkspaceBackupError.invalid(issues) }
    }

    func validationIssues() -> [String] {
        var issues: [String] = []
        issues += duplicateIDs(data.sites, "sites")
        issues += duplicateIDs(data.captions, "captions")
        issues += duplicateIDs(data.creativeIdeations ?? [], "creative ideations")
        issues += duplicateIDs(data.links, "links")
        issues += duplicateIDs(data.posts, "scheduled posts")
        issues += duplicateIDs(data.clients, "clients")
        issues += duplicateIDs(data.spotlights, "spotlights")
        issues += duplicateIDs(data.reels, "reels")
        issues += duplicateIDs(data.leads, "leads")
        issues += duplicateIDs(data.unifiedLeads, "unified leads")
        issues += duplicateIDs(data.deals, "deals")
        issues += duplicateIDs(data.crmTasks, "CRM tasks")
        issues += duplicateIDs(data.activities, "activities")
        issues += duplicateIDs(data.lists, "lead lists")
        issues += duplicateIDs(data.sequences, "sequences")
        issues += duplicateIDs(data.enrollments, "enrollments")
        issues += duplicateIDs(data.savedSearches, "saved searches")
        do {   // InboxMessage ids are String ("<folder>:<uid>"), not UUID
            var seen = Set<String>(); var dup = false
            for m in data.inboxMessages where !seen.insert(m.id).inserted { dup = true }
            if dup { issues.append("duplicate inbox message IDs") }
        }
        issues += duplicateIDs(data.callLogs, "call logs")
        issues += duplicateIDs(data.workflowRules, "workflow rules")
        issues += duplicateIDs(data.segments, "segments")
        issues += duplicateIDs(data.campaigns, "email campaigns")
        issues += duplicateIDs(data.audits, "audits")
        issues += duplicateIDs(data.socialProfiles, "social profiles")
        issues += duplicateIDs(data.adCampaigns, "ad campaigns")
        issues += duplicateIDs(data.journeys, "journeys")
        issues += duplicateIDs(data.postStats, "post stats")
        issues += duplicateIDs(data.influencers, "influencers")
        issues += duplicateIDs(data.landingTests, "landing tests")
        issues += duplicateIDs(data.workflows, "workflows")
        issues += duplicateIDs(data.mcampaigns, "multichannel campaigns")
        issues += duplicateIDs(data.abmAccounts, "ABM accounts")
        issues += duplicateIDs(data.referralPrograms, "referral programs")
        issues += duplicateIDs(data.roadItems, "roadmap items")
        issues += duplicateIDs(data.auditLog, "audit log")
        issues += duplicateIDs(prefs.profiles, "brand profiles")
        issues += duplicateIDs(prefs.holoPresets, "theme presets")

        let segmentIDs = Set(data.segments.map(\.id))
        let campaignIDs = Set(data.campaigns.map(\.id))
        let siteIDs = Set(data.sites.map(\.id))

        for c in data.campaigns {
            if let id = c.segmentID, !segmentIDs.contains(id) {
                issues.append("email campaign '\(c.name)' references missing segment")
            }
        }
        for j in data.journeys {
            if let id = j.segmentID, !segmentIDs.contains(id) {
                issues.append("journey '\(j.name)' references missing segment")
            }
            for step in j.steps {
                if let id = step.campaignID, !campaignIDs.contains(id) {
                    issues.append("journey '\(j.name)' references missing email campaign")
                }
            }
        }
        for test in data.landingTests {
            for variant in test.variants {
                if let id = variant.siteID, !siteIDs.contains(id) {
                    issues.append("landing test '\(test.name)' references missing site")
                }
            }
        }
        for workflow in data.workflows {
            if let id = workflow.triggerSegmentID, !segmentIDs.contains(id) {
                issues.append("workflow '\(workflow.name)' references missing trigger segment")
            }
        }
        if !SecurityLog.verify(data.auditLog) {
            issues.append("security audit log hash chain is invalid")
        }
        return issues
    }

    static func encode(model: AppModel, prefs: Prefs) throws -> Data {
        let backup = MarketingWorkspaceBackup(data: model.workspaceSnapshot(), prefs: prefs.workspaceSnapshot())
        try backup.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    static func decode(_ data: Data) throws -> MarketingWorkspaceBackup {
        let backup = try JSONDecoder().decode(MarketingWorkspaceBackup.self, from: data)
        try backup.validate()
        return backup
    }

    private func duplicateIDs<T: Identifiable>(_ values: [T], _ label: String) -> [String] where T.ID == UUID {
        var seen = Set<UUID>()
        var duplicates = Set<UUID>()
        for value in values {
            if !seen.insert(value.id).inserted { duplicates.insert(value.id) }
        }
        return duplicates.isEmpty ? [] : ["duplicate \(label) IDs"]
    }
}

extension AppModel {
    func workspaceSnapshot() -> MarketingDataSnapshot {
        MarketingDataSnapshot(model: self)
    }

    func applyWorkspaceData(_ snapshot: MarketingDataSnapshot) {
        loading = true
        sites = snapshot.sites
        captions = snapshot.captions
        contentLibrary = snapshot.contentLibrary
        creativeIdeations = snapshot.creativeIdeations ?? []
        conversionPaths = snapshot.conversionPaths
        links = snapshot.links
        posts = snapshot.posts
        spotlights = snapshot.spotlights
        reels = snapshot.reels
        leads = snapshot.unifiedLeads.isEmpty
            ? snapshot.leads.map(Lead.init(legacy:)) + snapshot.clients.map(Lead.init(legacy:))
            : snapshot.unifiedLeads
        deals = snapshot.deals; tasks = snapshot.crmTasks; activities = snapshot.activities
        lists = snapshot.lists; sequences = snapshot.sequences; enrollments = snapshot.enrollments
        sendDays = snapshot.sendDays; savedSearches = snapshot.savedSearches
        inbox = snapshot.inboxMessages; callLogs = snapshot.callLogs; workflowRules = snapshot.workflowRules
        segments = snapshot.segments
        campaigns = snapshot.campaigns
        audits = snapshot.audits
        socialProfiles = snapshot.socialProfiles
        refreshSocialCredentialFlags()
        adCampaigns = snapshot.adCampaigns
        journeys = snapshot.journeys
        journeyRuns = snapshot.journeyRuns; senders = snapshot.senders; newsletters = snapshot.newsletters
        postStats = snapshot.postStats
        influencers = snapshot.influencers
        landingTests = snapshot.landingTests
        workflows = snapshot.workflows
        mcampaigns = snapshot.mcampaigns
        abmAccounts = snapshot.abmAccounts
        referralPrograms = snapshot.referralPrograms
        roadItems = snapshot.roadItems
        auditLog = snapshot.auditLog
        _contactsCache = nil
        _contactsCacheGen = -1
        _touchChannelsLowered = nil
        _touchIndexGen = -1
        contactsGeneration &+= 1
        loading = false
        save()
    }

    func exportWorkspace(to url: URL, prefs: Prefs) throws {
        let data = try MarketingWorkspaceBackup.encode(model: self, prefs: prefs)
        try data.write(to: url, options: .atomic)
        logSecurity("export", "workspace -> \(url.lastPathComponent)")
    }

    @discardableResult
    func importWorkspace(from url: URL, prefs: Prefs) throws -> String {
        let backup = try MarketingWorkspaceBackup.decode(try Data(contentsOf: url))
        prefs.applyWorkspacePrefs(backup.prefs)
        applyWorkspaceData(backup.data)
        logSecurity("import", "workspace <- \(url.lastPathComponent)")
        return backup.summary
    }
}

/// A client-ready campaign bundle assembled from the same shipped engines the app
/// uses for landing pages, copy, UTM links, and schema. It is a handoff artifact:
/// no reach, clicks, or conversion numbers are invented.
struct CampaignPack: Codable, Hashable {
    var title: String
    var business: String
    var topic: String
    var channel: String
    var generatedAt: Date = Date()
    var landingHTML: String
    var socialPost: String
    var captions: [String]
    var emailSubject: String
    var emailBody: String
    var sms: String
    var schemaJSONLD: String
    var utmURL: String
    var checklist: [String]

    var markdown: String {
        let captionLines = captions.enumerated().map { idx, caption in
            "\(idx + 1). \(plain(caption))"
        }.joined(separator: "\n")
        let checklistLines = checklist.map { "- [ ] \(plain($0))" }.joined(separator: "\n")
        let utm = utmURL.isEmpty ? "No campaign URL supplied." : utmURL
        return """
        # \(plain(title))

        Business: \(plain(business))
        Campaign: \(plain(topic))
        Channel: \(plain(channel))

        ## Launch Link
        \(utm)

        ## Social Post
        \(plain(socialPost))

        ## Captions
        \(captionLines)

        ## Email
        Subject: \(plain(emailSubject))

        \(plain(emailBody))

        ## SMS
        \(plain(sms))

        ## LocalBusiness Schema
        ```html
        \(schemaJSONLD)
        ```

        ## Launch Checklist
        \(checklistLines)
        """
    }

    private func plain(_ value: String) -> String {
        value.replacingOccurrences(of: "<", with: "&lt;")
             .replacingOccurrences(of: ">", with: "&gt;")
             .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Marketing generators (real, deterministic output — no network, no placeholders)
enum Studio {

    /// Build a complete, modern, responsive multi-section site from real inputs. Sections beyond the
    /// hero/services/contact appear ONLY when the buyer supplies their content (honest empty state) —
    /// no fabricated testimonials, ratings, or stats. Every injected value is HTML- or URL-escaped.
    /// `template`/`palette` are buyer-customizable; `content` carries the optional copy slots.
    /// Which page of a generated site to render. `.single` is the classic one-pager; the other
    /// kinds compose the SAME honest sections into a linked multi-page site (index/services/
    /// about/contact) — no section is fabricated to pad a thinner page.
    enum SitePageKind { case single, home, about, services, contact, projects }

    /// Render the buyer's landing page from their LOCKED brand kit (MK-16). Palette, template, name,
    /// city, and contact all read from ONE kit on every call — so the site's brand can never drift
    /// away from the reel's or the email's. Delegates to the XSS-safe `landingPage(name:...)` below.
    static func landingPage(kit: BrandKit, type: String, page: SitePageKind = .single,
                            content: SiteContent = SiteContent(), galleryImages: [String] = []) -> String {
        let palette = SitePalette(rawValue: kit.paletteName) ?? .gold
        let template = SiteTemplate(rawValue: kit.siteTemplateName) ?? .bold
        return landingPage(name: kit.resolvedName, type: type, city: kit.city, phone: "",
                           template: template, palette: palette,
                           contactEmail: kit.contactEmail, content: content,
                           page: page, galleryImages: galleryImages)
    }

    static func landingPage(name: String, type: String, city: String, phone: String,
                            template: SiteTemplate = .bold, palette: SitePalette = .gold,
                            formEndpoint: String = "", contactEmail: String = "",
                            headline: String = "", subheadOverride: String = "", funnel: Bool = false,
                            content: SiteContent = SiteContent(),
                            page: SitePageKind = .single,
                            galleryImages: [String] = []) -> String {
        let n = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Your Business" : name.trimmingCharacters(in: .whitespaces)
        let t = type.trimmingCharacters(in: .whitespaces).isEmpty ? "Local Services" : type.trimmingCharacters(in: .whitespaces)
        let c = city.trimmingCharacters(in: .whitespaces)
        let p = phone.trimmingCharacters(in: .whitespaces)
        let locLine = c.isEmpty ? "Trusted \(t.lowercased())" : "\(t) in \(c)"
        let telHref = p.filter { $0.isNumber || $0 == "+" }
        let telURL = telHref.isEmpty ? "" : safeURL("tel:" + telHref)
        let year = Calendar.current.component(.year, from: Date())
        let (acc, acc2, bg, panel) = palette.hexes

        // Template tunables — real layout/type differences, not cosmetic.
        let displayFamily: String, h1Max: String, heroSplit: Bool, headTracking: String
        switch template {
        case .bold:    displayFamily = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"; h1Max = "66px"; heroSplit = true;  headTracking = "-0.02em"
        case .classic: displayFamily = "Georgia,'Times New Roman',serif"; h1Max = "64px"; heroSplit = true;  headTracking = "-0.005em"
        case .minimal: displayFamily = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif"; h1Max = "52px"; heroSplit = false; headTracking = "0em"
        }

        // Favicon: a monogram tile from the FIRST alphanumeric of the name (sanitized → XSS-safe),
        // percent-encoded so the data URI is valid and can never break out of the attribute.
        let mono = String(n.uppercased().first(where: { $0.isLetter || $0.isNumber }) ?? "•")
        let rawSVG = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 100 100\"><rect width=\"100\" height=\"100\" rx=\"24\" fill=\"\(acc)\"/><text x=\"50\" y=\"71\" font-family=\"Georgia,serif\" font-size=\"58\" fill=\"#0b0b0d\" text-anchor=\"middle\">\(esc(mono))</text></svg>"
        let favicon = "data:image/svg+xml," + (rawSVG.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")

        // Lead-capture route: post to the buyer's own endpoint, else a mailto to their address.
        let ep = formEndpoint.trimmingCharacters(in: .whitespaces)
        let ce = contactEmail.trimmingCharacters(in: .whitespaces).isEmpty ? content.email.trimmingCharacters(in: .whitespaces) : contactEmail.trimmingCharacters(in: .whitespaces)
        let hasLeadRoute = !ep.isEmpty || !ce.isEmpty
        // On multi-page sites, cross-page CTAs land on the real page; same-page ones stay anchors.
        let contactTarget = (page == .single || page == .contact) ? "#contact" : "contact.html"
        let servicesTarget = (page == .single || page == .services) ? "#services" : "services.html"
        let primaryHref = hasLeadRoute ? contactTarget : (telURL.isEmpty ? servicesTarget : telURL)
        let ctaOverride = content.ctaLabel.trimmingCharacters(in: .whitespaces)
        let primaryLabel = !ctaOverride.isEmpty ? ctaOverride : (hasLeadRoute ? "Get a Free Quote" : (telURL.isEmpty ? "View Services" : "Call Now"))
        let heroCall = (!telURL.isEmpty && primaryHref != telURL) ? "<a class=\"btn ghost\" href=\"\(telURL)\">Call \(esc(p))</a>" : ""

        let hOverride = headline.trimmingCharacters(in: .whitespaces)
        let sOverride = subheadOverride.trimmingCharacters(in: .whitespaces)
        let baseHeroTitle = !hOverride.isEmpty ? hOverride : (c.isEmpty ? n : "\(n) in \(c)")
        let baseSubhead = !sOverride.isEmpty ? sOverride
            : (funnel ? "One offer, one page, one clear next step — designed to turn a click into a booked job."
                      : "Fast local service, clean workmanship, and a page built to turn visits into calls.")
        // Sub-pages get focused hero copy; buyer overrides apply to the home/one-pager hero.
        let heroTitle: String, subhead: String
        switch page {
        case .about:    heroTitle = "About \(n)";   subhead = "The people and the standards behind the work."
        case .services: heroTitle = "Services";      subhead = "Everything we do — and the fastest way to get it."
        case .contact:  heroTitle = "Contact \(n)"; subhead = c.isEmpty ? "Tell us what you need and we'll follow up fast." : "Serving \(c) — tell us what you need and we'll follow up fast."
        case .projects: heroTitle = "Our Work";      subhead = "Real jobs, photographed on site — no stock imagery."
        default:        heroTitle = baseHeroTitle;   subhead = baseSubhead
        }
        // Gallery photos are the buyer's own files (copied into images/ by the exporter). The
        // Projects page and its nav link exist ONLY when real photos were supplied.
        let hasGallery = !galleryImages.isEmpty

        // ---- Sections (each honest-empty: omitted when the buyer supplies nothing) ----

        // Stats / trust bar — buyer's OWN real numbers only.
        let statsBar: String = {
            let stats = content.cleanStats
            guard !stats.isEmpty else { return "" }
            let cells = stats.prefix(4).map { "<div class=\"stat\"><strong>\(esc($0.value))</strong><span>\(esc($0.label))</span></div>" }.joined()
            return "<section class=\"stats reveal\"><div class=\"wrap stat-grid\">\(cells)</div></section>"
        }()

        // Services — the buyer's custom list, else a real type-matched default trio.
        let servicesInner: String = {
            let custom = content.cleanServices
            if custom.isEmpty { return serviceCards(for: t) }
            return custom.prefix(6).enumerated().map { idx, s in
                "<article class=\"action reveal\"><span>0\(idx + 1)</span><h3>\(esc(s.title))</h3><p>\(esc(s.detail))</p></article>"
            }.joined(separator: "\n                  ")
        }()
        let servicesSection = """
            <section id="services">
              <div class="wrap">
                <div class="section-head reveal">
                  <h2>What we do</h2>
                  <p class="lead">A clear path from visit to action, without clutter or guesswork.</p>
                </div>
                <div class="action-grid">
                  \(servicesInner)
                </div>
              </div>
            </section>
        """

        // About — buyer's story, else an honest generic value section (no fabricated facts/numbers).
        let aboutBody = content.about.trimmingCharacters(in: .whitespacesAndNewlines)
        let aboutSection: String = {
            if aboutBody.isEmpty {
                return """
                    <section id="about" class="band">
                      <div class="wrap about-grid reveal">
                        <div>
                          <h2>Built for local trust</h2>
                          <p class="lead">Service details, contact paths, and a simple callback flow stay visible from phone to desktop — so the right next step is always one tap away.</p>
                        </div>
                        <ul class="trust-list">
                          <li><strong>Direct contact</strong><p>\(p.isEmpty ? "Add a phone number to make calling one tap." : "Call " + esc(p) + " from the header or hero.")</p></li>
                          <li><strong>Local context</strong><p>\(c.isEmpty ? "Add a city to localize the page." : "Serving " + esc(c) + " and the surrounding area.")</p></li>
                          <li><strong>Simple request</strong><p>The form asks only for the basics so the business can follow up fast.</p></li>
                        </ul>
                      </div>
                    </section>
                """
            }
            let paras = aboutBody.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .map { "<p>\(esc($0))</p>" }.joined()
            return """
                <section id="about" class="band">
                  <div class="wrap about-grid reveal">
                    <div>
                      <h2>About \(esc(n))</h2>
                      <div class="prose">\(paras)</div>
                    </div>
                    <ul class="trust-list">
                      <li><strong>Local context</strong><p>\(c.isEmpty ? "Independent, locally operated." : "Serving " + esc(c) + " and nearby.")</p></li>
                      <li><strong>Direct contact</strong><p>\(p.isEmpty ? "Reach us through the form." : "Call " + esc(p) + " any time.")</p></li>
                    </ul>
                  </div>
                </section>
            """
        }()

        // Testimonials — ONLY real, buyer-entered reviews. Omitted entirely when there are none.
        let testimonials = content.cleanTestimonials
        let hasReviews = !testimonials.isEmpty
        let testimonialsSection: String = {
            guard hasReviews else { return "" }
            let cards = testimonials.prefix(6).map { r in
                let by = r.author.trimmingCharacters(in: .whitespaces)
                return "<figure class=\"quote reveal\"><blockquote>\(esc(r.quote))</blockquote>\(by.isEmpty ? "" : "<figcaption>— \(esc(by))</figcaption>")</figure>"
            }.joined(separator: "\n                  ")
            return """
                <section id="reviews">
                  <div class="wrap">
                    <div class="section-head reveal"><h2>What clients say</h2><p class="lead">In their words.</p></div>
                    <div class="quote-grid">
                      \(cards)
                    </div>
                  </div>
                </section>
            """
        }()

        // FAQ — buyer-supplied Q&A as native <details> accordions. Omitted when empty.
        let faqs = content.cleanFAQs
        let hasFAQ = !faqs.isEmpty
        let faqSection: String = {
            guard hasFAQ else { return "" }
            let items = faqs.prefix(10).map { f in
                "<details class=\"faq\"><summary>\(esc(f.q))</summary><div class=\"faq-a\">\(esc(f.a))</div></details>"
            }.joined(separator: "\n                  ")
            return """
                <section id="faq" class="band">
                  <div class="wrap narrow">
                    <div class="section-head reveal"><h2>Common questions</h2></div>
                    \(items)
                  </div>
                </section>
            """
        }()

        // Contact — hours, service area, a map link (no paid embed), and the lead form.
        let hours = content.hours.trimmingCharacters(in: .whitespacesAndNewlines)
        let area = content.serviceArea.trimmingCharacters(in: .whitespaces).isEmpty ? c : content.serviceArea.trimmingCharacters(in: .whitespaces)
        let mapLink = area.isEmpty ? "" : "<a class=\"chip\" href=\"\(safeURL("https://www.google.com/maps/search/?api=1&query=" + (area.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? area)))\" target=\"_blank\" rel=\"noopener\">Get directions</a>"
        let formBlock: String = {
            if hasLeadRoute {
                let action = ep.isEmpty ? safeURL("mailto:" + ce) : safeURL(ep)
                let method = ep.isEmpty ? "get" : "post"
                return """
                    <form class="lead-form" action="\(action)" method="\(method)" aria-label="Request a callback">
                        <h3>Request a callback</h3>
                        <input type="text" name="name" placeholder="Your name" required aria-label="Your name">
                        <input type="email" name="email" placeholder="Your email" required aria-label="Your email">
                        <input type="tel" name="phone" placeholder="Phone (optional)" aria-label="Phone">
                        <textarea name="message" placeholder="How can we help?" rows="3" aria-label="Message"></textarea>
                        <button type="submit" class="btn full">\(esc(primaryLabel))</button>
                    </form>
                """
            }
            return """
                <div class="lead-form fallback">
                    <h3>Get in touch</h3>
                    <p>\(telURL.isEmpty ? "Review the services and reach the business through your preferred channel." : "Tap once to call and describe what you need.")</p>
                    \(telURL.isEmpty ? "<a class=\"btn full\" href=\"\(servicesTarget)\">View Services</a>" : "<a class=\"btn full\" href=\"\(telURL)\">Call \(esc(p))</a>")
                </div>
            """
        }()
        let contactMeta = [
            hours.isEmpty ? "" : "<li><strong>Hours</strong><p>\(esc(hours).replacingOccurrences(of: "\n", with: "<br>"))</p></li>",
            area.isEmpty ? "" : "<li><strong>Service area</strong><p>\(esc(area)) \(mapLink)</p></li>",
            p.isEmpty ? "" : "<li><strong>Phone</strong><p><a href=\"\(telURL)\">\(esc(p))</a></p></li>",
            ce.isEmpty ? "" : "<li><strong>Email</strong><p><a href=\"\(safeURL("mailto:" + ce))\">\(esc(ce))</a></p></li>"
        ].filter { !$0.isEmpty }.joined()
        let contactSection = """
            <section id="contact" class="band">
              <div class="wrap contact-layout">
                <div class="reveal">
                  <h2>\(funnel ? "Claim your spot" : "Contact")</h2>
                  <p class="lead">\(c.isEmpty ? "Tell us what you need and we'll follow up fast." : "Serving " + esc(c) + " — tell us what you need and we'll follow up fast.")</p>
                  <ul class="trust-list">\(contactMeta.isEmpty ? "<li><strong>Direct</strong><p>Use the form and we'll be in touch.</p></li>" : contactMeta)</ul>
                </div>
                <div class="reveal">\(formBlock)</div>
              </div>
            </section>
        """

        // Funnel mode: an offer/urgency band right under the hero, straight to the form.
        let funnelBand = funnel ? """
            <section class="band offer reveal"><div class="wrap" style="text-align:center">
              <h2>Limited availability\(c.isEmpty ? "" : " in " + esc(c)) — book this week</h2>
              <p class="lead" style="margin:10px auto 18px">Tell us what you need and we'll get back fast. No call centers, no runaround.</p>
              <a class="btn" href="\(hasLeadRoute ? "#contact" : primaryHref)">\(esc(hasLeadRoute ? "Claim Your Free Quote" : primaryLabel))</a>
            </div></section>
        """ : ""

        // Nav — one-pager: anchors only for sections that exist. Multi-page: real page links
        // with the current page marked (aria-current for a11y + a visible active state).
        let navLinks: String = {
            if page == .single {
                return content.orderedSections.compactMap { section -> String? in
                    switch section {
                    case .stats: return nil
                    case .services: return "<a href=\"#services\">Services</a>"
                    case .about: return "<a href=\"#about\">About</a>"
                    case .testimonials: return hasReviews ? "<a href=\"#reviews\">Reviews</a>" : nil
                    case .faq: return hasFAQ ? "<a href=\"#faq\">FAQ</a>" : nil
                    case .contact: return "<a href=\"#contact\">Contact</a>"
                    }
                }.joined(separator: "\n                ")
            }
            func link(_ label: String, _ href: String, _ kind: SitePageKind) -> String {
                page == kind
                    ? "<a href=\"\(href)\" aria-current=\"page\" style=\"color:var(--text)\">\(label)</a>"
                    : "<a href=\"\(href)\">\(label)</a>"
            }
            var items = [link("Home", "index.html", .home),
                         link("Services", "services.html", .services)]
            if hasGallery { items.append(link("Projects", "projects.html", .projects)) }
            items.append(link("About", "about.html", .about))
            items.append(link("Contact", "contact.html", .contact))
            return items.joined(separator: "\n                ")
        }()

        // Projects gallery — the buyer's OWN photos only, lazy-loaded, no stock filler.
        let gallerySection: String = {
            guard hasGallery else { return "" }
            let figs = galleryImages.map { img -> String in
                let stem = (img as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ")
                return "<figure><img src=\"images/\(esc(img))\" alt=\"\(esc(stem))\" loading=\"lazy\"></figure>"
            }.joined(separator: "\n                  ")
            return """
                <section id="projects">
                  <div class="wrap">
                    <div class="section-head reveal"><h2>Recent projects</h2><p class="lead">Straight from our own job sites.</p></div>
                    <div class="gallery-grid reveal">
                      \(figs)
                    </div>
                  </div>
                </section>
            """
        }()

        let heroVisual = heroSplit ? """
                <div class="media-frame" aria-hidden="true">
                  <div class="mono-badge">\(esc(mono))</div>
                  <div class="service-mark"><span>\(esc(locLine))</span><strong>\(esc(t))</strong></div>
                </div>
        """ : ""

        // Sub-pages end on a cross-page CTA band so every page has a clear next step.
        let crossCTA: String = (page == .single || page == .contact) ? "" : """
            <section class="band reveal"><div class="wrap" style="text-align:center">
              <h2>Ready when you are\(c.isEmpty ? "" : " in " + esc(c))</h2>
              <p class="lead" style="margin:10px auto 18px">\(hasLeadRoute ? "Tell us what you need and we'll follow up fast." : (p.isEmpty ? "Browse the services and get in touch." : "Call " + esc(p) + " — or send a note and we'll call you."))</p>
              <a class="btn" href="contact.html">\(esc(primaryLabel))</a>
            </div></section>
        """

        let movableSections: [SiteSection: String] = [
            .stats: statsBar, .services: servicesSection, .about: aboutSection,
            .testimonials: testimonialsSection, .faq: faqSection, .contact: contactSection
        ]
        func orderedSections(_ allowed: [SiteSection]) -> String {
            let allowedSet = Set(allowed)
            return content.orderedSections
                .filter { allowedSet.contains($0) }
                .compactMap { movableSections[$0] }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        // Page composition: user-defined order drives every page while fixed hero-adjacent funnel
        // and closing CTA bands keep their structural positions. Honest-empty sections stay omitted.
        let bodySections: String = {
            switch page {
            case .single:   return [funnelBand, orderedSections(SiteSection.defaultOrder)].filter { !$0.isEmpty }.joined(separator: "\n")
            case .home:     return [funnelBand, orderedSections([.stats, .services, .testimonials]), crossCTA].filter { !$0.isEmpty }.joined(separator: "\n")
            case .services: return [orderedSections([.services, .faq]), crossCTA].filter { !$0.isEmpty }.joined(separator: "\n")
            case .about:    return [orderedSections([.about, .testimonials]), crossCTA].filter { !$0.isEmpty }.joined(separator: "\n")
            case .contact:  return orderedSections([.stats, .contact])
            case .projects: return [gallerySection, crossCTA].joined(separator: "\n")
            }
        }()

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>\({ switch page { case .about: return "About — "; case .services: return "Services — "; case .contact: return "Contact — "; default: return "" } }())\(esc(n)) — \(esc(t))\(c.isEmpty ? "" : " in " + esc(c))</title>
        <meta name="description" content="\(esc(n)) — \(esc(locLine)). \(esc(subhead))">
        <meta name="theme-color" content="\(acc)">
        <meta property="og:type" content="website">
        <meta property="og:title" content="\(esc(n)) — \(esc(t))">
        <meta property="og:description" content="\(esc(subhead))">
        <meta name="twitter:card" content="summary_large_image">
        <link rel="icon" href="\(favicon)">
        \(Studio.localBusinessJSONLD(name: n, type: t, city: c, phone: p, email: ce))
        <style>
          :root{ --gold:\(acc); --gold2:\(acc2); --bg:\(bg); --panel:\(panel); --text:#F7F4EC; --sub:#B2AEA4; --line:rgba(255,255,255,.09); --maxw:1120px; --pad:clamp(18px,5vw,40px); --h1:clamp(38px,7.4vw,\(h1Max)); --h2:clamp(26px,4vw,40px); --radius:14px; }
          *{ box-sizing:border-box; margin:0; padding:0; }
          html{ scroll-behavior:smooth; }
          body{ font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif; background:radial-gradient(1200px 600px at 50% -10%, color-mix(in srgb, var(--gold) 10%, var(--bg)), transparent 60%), linear-gradient(180deg,#050506,var(--bg) 40%,#050506); color:var(--text); line-height:1.6; -webkit-font-smoothing:antialiased; }
          a{ text-decoration:none; color:inherit; }
          img{ max-width:100%; display:block; }
          .wrap{ width:min(var(--maxw), 100% - var(--pad)*2); margin-inline:auto; }
          .wrap.narrow{ max-width:760px; } .wrap.narrow{ width:min(760px, 100% - var(--pad)*2); }
          :focus-visible{ outline:2px solid var(--gold); outline-offset:3px; border-radius:6px; }
          header{ position:sticky; top:0; z-index:20; backdrop-filter:blur(16px); background:rgba(6,6,7,.72); border-bottom:1px solid var(--line); transition:box-shadow .25s, background .25s; }
          header.scrolled{ box-shadow:0 10px 40px rgba(0,0,0,.5); background:rgba(6,6,7,.9); }
          .nav{ display:flex; align-items:center; justify-content:space-between; gap:22px; min-height:66px; }
          .brand{ display:flex; align-items:center; gap:10px; font-weight:800; font-size:18px; letter-spacing:-.01em; }
          .brand .mk{ width:30px; height:30px; border-radius:9px; display:grid; place-items:center; background:linear-gradient(135deg,var(--gold),var(--gold2)); color:#0b0b0d; font-weight:900; font-family:Georgia,serif; }
          nav.links{ display:flex; gap:26px; color:var(--sub); font-size:14px; font-weight:600; }
          nav.links a{ position:relative; } nav.links a:hover{ color:var(--text); }
          .btn{ display:inline-flex; align-items:center; justify-content:center; min-height:46px; border-radius:10px; background:linear-gradient(135deg,var(--gold),var(--gold2)); color:#171106; font-weight:800; padding:0 20px; border:0; cursor:pointer; transition:transform .12s, box-shadow .2s; box-shadow:0 8px 24px color-mix(in srgb,var(--gold) 22%, transparent); }
          .btn:hover{ transform:translateY(-1px); }
          .btn.ghost{ background:transparent; color:var(--text); border:1px solid var(--line); box-shadow:none; }
          .btn.full{ width:100%; }
          .chip{ display:inline-block; margin-left:8px; padding:3px 10px; border-radius:999px; font-size:12px; font-weight:700; background:color-mix(in srgb,var(--gold) 18%, transparent); color:var(--gold); }
          section{ padding:clamp(48px,8vw,88px) 0; scroll-margin-top:80px; }
          .band{ border-top:1px solid var(--line); background:linear-gradient(180deg,rgba(255,255,255,.035),rgba(255,255,255,.01)); }
          .eyebrow{ display:inline-block; color:var(--gold); font-size:13px; font-weight:800; letter-spacing:.18em; text-transform:uppercase; margin-bottom:16px; }
          h1{ font-family:\(displayFamily); font-size:var(--h1); line-height:1.02; font-weight:900; letter-spacing:\(headTracking); overflow-wrap:break-word; }
          h2,.brand,.action h3,.stat strong{ overflow-wrap:break-word; }
          h2{ font-size:var(--h2); line-height:1.1; font-weight:850; letter-spacing:-.01em; }
          .hero{ padding:clamp(46px,8vw,84px) 0 clamp(38px,6vw,60px); }
          .hero-grid{ display:grid; grid-template-columns:\(heroSplit ? "minmax(0,1.05fr) minmax(300px,.8fr)" : "1fr"); gap:44px; align-items:center; \(heroSplit ? "" : "text-align:center; max-width:820px; margin-inline:auto;") }
          .hero p.sub{ color:var(--sub); font-size:clamp(17px,2.2vw,20px); max-width:640px; margin:18px \(heroSplit ? "0" : "auto") 28px; }
          .cta{ display:inline-flex; gap:14px; flex-wrap:wrap; \(heroSplit ? "" : "justify-content:center;") }
          .media-frame{ position:relative; min-height:360px; border:1px solid var(--line); border-radius:var(--radius); overflow:hidden; background:linear-gradient(150deg,color-mix(in srgb,var(--gold) 14%, transparent),transparent 55%),linear-gradient(300deg,color-mix(in srgb,var(--gold2) 12%, transparent),transparent 55%),#0a0a0c; box-shadow:0 30px 80px rgba(0,0,0,.45); }
          .media-frame .mono-badge{ position:absolute; top:26px; left:26px; width:56px; height:56px; border-radius:14px; display:grid; place-items:center; font-family:Georgia,serif; font-weight:900; font-size:28px; color:#0b0b0d; background:linear-gradient(135deg,var(--gold),var(--gold2)); }
          .service-mark{ position:absolute; left:26px; right:26px; bottom:26px; padding:16px 18px; border-radius:12px; background:rgba(5,5,6,.7); border:1px solid var(--line); backdrop-filter:blur(6px); }
          .service-mark span{ display:block; color:var(--gold); font-size:12px; font-weight:800; letter-spacing:.12em; text-transform:uppercase; margin-bottom:6px; }
          .service-mark strong{ display:block; font-size:26px; line-height:1.05; }
          .stat-grid{ display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:14px; }
          .stat{ text-align:center; padding:22px 14px; border:1px solid var(--line); border-radius:var(--radius); background:var(--panel); }
          .stat strong{ display:block; font-size:34px; font-weight:900; color:var(--gold); font-family:\(displayFamily); }
          .stat span{ color:var(--sub); font-size:13px; font-weight:600; }
          .section-head{ margin-bottom:30px; } .section-head h2{ margin-bottom:8px; }
          .lead{ color:var(--sub); max-width:560px; font-size:16px; }
          .action-grid{ display:grid; grid-template-columns:repeat(auto-fit,minmax(240px,1fr)); gap:16px; }
          .action{ background:var(--panel); border:1px solid var(--line); border-radius:var(--radius); padding:26px; }
          .action span{ color:var(--gold); font-weight:900; font-size:14px; letter-spacing:.08em; }
          .action h3{ font-size:20px; margin:14px 0 8px; }
          .action p{ color:var(--sub); font-size:15px; }
          .about-grid{ display:grid; grid-template-columns:minmax(0,1.2fr) minmax(260px,.8fr); gap:40px; align-items:start; }
          .prose p{ color:var(--sub); margin-bottom:12px; }
          .trust-list{ list-style:none; display:grid; gap:14px; }
          .trust-list li{ border-top:1px solid var(--line); padding-top:14px; }
          .trust-list strong{ display:block; margin-bottom:3px; } .trust-list p{ color:var(--sub); }
          .quote-grid{ display:grid; grid-template-columns:repeat(auto-fit,minmax(280px,1fr)); gap:16px; }
          .quote{ background:var(--panel); border:1px solid var(--line); border-radius:var(--radius); padding:26px; }
          .quote blockquote{ font-size:18px; line-height:1.5; } .quote blockquote:before{ content:"\u{201C}"; color:var(--gold); font-size:34px; font-family:Georgia,serif; margin-right:2px; }
          .quote figcaption{ color:var(--gold); font-weight:700; font-size:14px; margin-top:14px; }
          details.faq{ border:1px solid var(--line); border-radius:12px; background:var(--panel); padding:4px 18px; margin-bottom:10px; }
          details.faq summary{ cursor:pointer; font-weight:700; padding:16px 0; list-style:none; display:flex; justify-content:space-between; align-items:center; }
          details.faq summary::-webkit-details-marker{ display:none; }
          details.faq summary:after{ content:"+"; color:var(--gold); font-size:22px; } details.faq[open] summary:after{ content:"\u{2013}"; }
          details.faq .faq-a{ color:var(--sub); padding:0 0 16px; }
          .gallery-grid{ display:grid; grid-template-columns:repeat(auto-fill,minmax(260px,1fr)); gap:14px; }
          .gallery-grid figure{ margin:0; border:1px solid var(--line); border-radius:var(--radius); overflow:hidden; background:var(--panel); }
          .gallery-grid img{ width:100%; height:240px; object-fit:cover; display:block; transition:transform .35s ease; }
          .gallery-grid figure:hover img{ transform:scale(1.04); }
          .contact-layout{ display:grid; grid-template-columns:minmax(0,1fr) minmax(300px,440px); gap:36px; align-items:start; }
          .lead-form{ display:flex; flex-direction:column; gap:12px; background:#09090a; border:1px solid var(--line); border-radius:var(--radius); padding:24px; }
          .lead-form h3{ font-size:21px; } .lead-form p{ color:var(--sub); }
          .lead-form input,.lead-form textarea{ width:100%; padding:13px 14px; border-radius:10px; border:1px solid var(--line); background:#050506; color:var(--text); font-size:15px; font-family:inherit; }
          .lead-form input:focus,.lead-form textarea:focus{ outline:none; border-color:var(--gold); box-shadow:0 0 0 3px color-mix(in srgb,var(--gold) 16%, transparent); }
          footer{ color:var(--sub); padding:34px 0; font-size:14px; border-top:1px solid var(--line); }
          .foot{ display:flex; justify-content:space-between; gap:16px; flex-wrap:wrap; }
          .reveal{ opacity:0; transform:translateY(16px); transition:opacity .6s ease, transform .6s ease; }
          .reveal.in{ opacity:1; transform:none; }
          @media (prefers-reduced-motion: reduce){ html{ scroll-behavior:auto; } .reveal{ opacity:1; transform:none; transition:none; } }
          @media(max-width:860px){ nav.links{ display:none; } .hero-grid,.about-grid,.contact-layout{ grid-template-columns:1fr; } .media-frame{ min-height:260px; } }
        </style>
        </head>
        <body>
          <header>
            <div class="nav wrap">
              <a class="brand" href="\(page == .single ? "#top" : "index.html")"><span class="mk">\(esc(mono))</span>\(esc(n))</a>
              <nav class="links" aria-label="Primary">
                \(navLinks)
              </nav>
              <a class="btn" href="\(primaryHref)">\(esc(primaryLabel))</a>
            </div>
          </header>
          <main id="top">
            <div class="hero">
              <div class="wrap hero-grid">
                <div class="reveal in">
                  <span class="eyebrow">\(esc(locLine))</span>
                  <h1>\(esc(heroTitle))</h1>
                  <p class="sub">\(esc(subhead))</p>
                  <div class="cta">
                    <a class="btn" href="\(primaryHref)">\(esc(primaryLabel))</a>
                    \(heroCall)
                  </div>
                </div>
                \(heroVisual)
              </div>
            </div>
            \(bodySections)
          </main>
          <footer>
            <div class="wrap foot">
              <div>&copy; <span id="yr">\(year)</span> \(esc(n)). All rights reserved.\(c.isEmpty ? "" : " · " + esc(c))</div>
              <div>\(esc(t))</div>
            </div>
          </footer>
          <script>
          (function(){
            var h=document.querySelector('header');
            var s=function(){ if(h) h.classList.toggle('scrolled', window.scrollY>8); };
            window.addEventListener('scroll', s, {passive:true}); s();
            var y=document.getElementById('yr'); if(y){ y.textContent=new Date().getFullYear(); }
            if('IntersectionObserver' in window){
              var io=new IntersectionObserver(function(es){ es.forEach(function(e){ if(e.isIntersecting){ e.target.classList.add('in'); io.unobserve(e.target); } }); }, {threshold:.12});
              document.querySelectorAll('.reveal:not(.in)').forEach(function(el){ io.observe(el); });
            } else { document.querySelectorAll('.reveal').forEach(function(el){ el.classList.add('in'); }); }
          })();
          </script>
        </body>
        </html>
        """
    }

    /// LocalBusiness JSON-LD built from a dictionary + JSONSerialization (correct JSON escaping), then
    /// `<` is neutralized so a crafted value can never break out of the <script> element (XSS-safe).
    static func localBusinessJSONLD(name: String, type: String, city: String, phone: String, email: String) -> String {
        var dict: [String: Any] = ["@context": "https://schema.org", "@type": "LocalBusiness", "name": name, "description": type]
        if !city.isEmpty { dict["areaServed"] = city; dict["address"] = ["@type": "PostalAddress", "addressLocality": city] }
        if !phone.isEmpty { dict["telephone"] = phone }
        if !email.isEmpty { dict["email"] = email }
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        let safe = json.replacingOccurrences(of: "<", with: "\\u003c")
        return "<script type=\"application/ld+json\">\(safe)</script>"
    }

    private static func serviceCards(for type: String) -> String {
        let t = type.lowercased()
        let trio: [(String, String)]
        if t.contains("clean") {
            trio = [("Deep Cleaning","Top-to-bottom service that leaves every room spotless."),
                    ("Recurring Plans","Weekly, biweekly, or monthly — on your schedule."),
                    ("Move-In / Move-Out","Detailed turnovers for landlords and tenants.")]
        } else if t.contains("plumb") {
            trio = [("Emergency Repairs","Fast response for leaks, clogs, and burst pipes."),
                    ("Installations","Fixtures, water heaters, and full re-pipes."),
                    ("Maintenance","Inspections that prevent costly surprises.")]
        } else if t.contains("salon") || t.contains("hair") || t.contains("beauty") {
            trio = [("Cuts & Styling","On-trend looks tailored to you."),
                    ("Color","Balayage, highlights, and full color."),
                    ("Treatments","Healthy-hair care and conditioning.")]
        } else if t.contains("restaurant") || t.contains("cafe") || t.contains("food") {
            trio = [("Dine In","A warm room and a menu made fresh daily."),
                    ("Takeout","Order ahead and skip the wait."),
                    ("Catering","We bring the feast to your event.")]
        } else if t.contains("fitness") || t.contains("gym") || t.contains("train") {
            trio = [("Personal Training","One-on-one coaching toward real results."),
                    ("Group Classes","High-energy sessions for every level."),
                    ("Nutrition","Plans that fit your goals and your life.")]
        } else {
            trio = [("Expert Service","Skilled professionals who get it right the first time."),
                    ("Fair Pricing","Clear quotes with no hidden surprises."),
                    ("Satisfaction","We stand behind every job we do.")]
        }
        return trio.enumerated().map { idx, item in
            "<article class=\"action\"><span>0\(idx + 1)</span><h3>\(esc(item.0))</h3><p>\(esc(item.1))</p></article>"
        }.joined(separator: "\n                  ")
    }

    // esc/safeURL delegate to the shared HTMLSafe source (Sources/HTMLSafe.swift)
    // so the engine test suite and the shipped app exercise the SAME logic.
    private static func esc(_ s: String) -> String { HTMLSafe.esc(s) }

    /// Defense-in-depth for URL-valued attributes (form action / href). Single
    /// allowlist in HTMLSafe — see Sources/HTMLSafe.swift.
    static func safeURL(_ s: String) -> String { HTMLSafe.safeURL(s) }

    /// Six real, templated marketing captions for a topic, in the buyer's chosen tone.
    /// An optional brand hashtag is appended (buyer-controlled — no hardcoded brand).
    static func captions(for topic: String, tone: CaptionTone = .punchy, hashtag: String = "") -> [String] {
        let raw = topic.trimmingCharacters(in: .whitespaces)
        let t = raw.isEmpty ? "our latest offer" : raw
        let tag: String = {
            let h = hashtag.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty else { return "" }
            return " " + (h.hasPrefix("#") ? h : "#" + h.replacingOccurrences(of: " ", with: ""))
        }()
        let lines: [String]
        switch tone {
        case .punchy:
            lines = [
                "Stop scrolling — \(t) is exactly what you've been waiting for. Tap to learn more. 🔥",
                "We poured everything into \(t). Now it's your turn to experience the difference. ✨",
                "Real talk: \(t) won't last long. Limited spots, big results. DM us today. 📩",
                "Behind the scenes of \(t) — here's why our clients keep coming back. 💛",
                "Your competitors are already on \(t). Don't get left behind. Link in bio. 🚀",
                "Three reasons to choose \(t): quality, speed, and results you can see. Which matters most to you? 👇"
            ]
        case .professional:
            lines = [
                "Introducing \(t). Built to deliver measurable results for the businesses we serve.",
                "We're proud to share \(t) — a thoughtful step forward for our clients.",
                "\(t) is now available. Reach out to learn how it can work for you.",
                "Quality you can rely on: here's what \(t) means for your bottom line.",
                "Our team designed \(t) with one goal — your success. Let's talk.",
                "Considering \(t)? Here are the facts you need to make the right decision."
            ]
        case .friendly:
            lines = [
                "Hey friends! We've been working on \(t) and we can't wait for you to see it. 😊",
                "Good news — \(t) is finally here, and it's made with you in mind. 💛",
                "We think you're going to love \(t). Come say hi and check it out!",
                "Thanks for being part of our community — \(t) is our way of saying it back.",
                "Curious about \(t)? Drop us a message, we'd love to chat. 👋",
                "Small business, big heart — and now, \(t). Stop by anytime!"
            ]
        case .luxury:
            lines = [
                "\(t). Crafted for those who expect more.",
                "An invitation: experience \(t), where every detail is considered.",
                "Refined, deliberate, exceptional — \(t) is now available to a select few.",
                "We don't follow trends. We set the standard. Discover \(t).",
                "\(t) — the difference is in what you don't have to ask for.",
                "For those who know the value of doing it right: \(t)."
            ]
        }
        return lines.map { $0 + tag }
    }

    /// Draft a post body from operator data (business + topic). Deterministic, on-device.
    /// `hashtag` is the buyer's OWN brand tag (no hardcoded brand is ever injected —
    /// the old code shipped "#BlackLabel" into the buyer's post, a brand leak + fabrication).
    static func draftPost(business: String, topic: String, channel: String, hashtag: String = "") -> String {
        let b = business.trimmingCharacters(in: .whitespaces)
        let t = topic.trimmingCharacters(in: .whitespaces).isEmpty ? "our latest offer" : topic.trimmingCharacters(in: .whitespaces)
        let who = b.isEmpty ? "We" : b
        let hook: String
        switch channel.lowercased() {
        case "linkedin":
            hook = "\(who) is excited to share an update on \(t). Here's what it means for you — and why now is the right time to act."
        case "x":
            hook = "\(who): \(t) is here. Short version — it's good, it's limited, and you'll want in. 👇"
        case "tiktok", "instagram", "threads":
            hook = "POV: you just found \(t) from \(who). Save this. Share it. Don't sleep on it. ✨"
        default:
            hook = "\(who) just launched \(t). Tap to see why everyone's talking about it."
        }
        let tags = channelTags(channel, brandHashtag: hashtag)
        return tags.isEmpty ? hook : "\(hook)\n\n\(tags)"
    }
    /// Generic, non-branded channel hashtags + the buyer's own brand tag when set.
    /// Never injects any company brand the buyer didn't choose.
    private static func channelTags(_ channel: String, brandHashtag: String) -> String {
        let brand: String = {
            let h = brandHashtag.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty else { return "" }
            return h.hasPrefix("#") ? h : "#" + h.replacingOccurrences(of: " ", with: "")
        }()
        let generic: [String]
        switch channel.lowercased() {
        case "linkedin": generic = ["#marketing", "#growth", "#smallbusiness"]
        case "x":        generic = ["#marketing"]
        case "tiktok":   generic = ["#fyp", "#smallbusiness"]
        case "facebook": generic = ["#localbusiness"]
        case "threads":  generic = ["#threads"]
        default:         generic = ["#marketing", "#smallbusiness"]
        }
        return ([brand] + generic).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Multi-format content studio (social, blog, ad, email, landing copy)

    /// The content formats the studio can generate, in the buyer's brand voice.
    enum ContentFormat: String, CaseIterable, Identifiable {
        case socialPost = "Social post", blogOutline = "Blog outline", adCopy = "Ad copy",
             emailBlast = "Email", landingCopy = "Landing copy", smsBlast = "SMS"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .socialPost: return "bubble.left.and.text.bubble.right.fill"
            case .blogOutline: return "doc.text.fill"
            case .adCopy: return "megaphone.fill"
            case .emailBlast: return "envelope.fill"
            case .landingCopy: return "rectangle.portrait.and.arrow.right.fill"
            case .smsBlast: return "message.fill"
            }
        }
        var hint: String {
            switch self {
            case .socialPost: return "Caption-style post for any channel."
            case .blogOutline: return "Structured outline with sections you can flesh out."
            case .adCopy: return "Headline + primary text + CTA for paid ads."
            case .emailBlast: return "Subject line + body for a campaign email."
            case .landingCopy: return "Hero headline, subhead, and three benefits."
            case .smsBlast: return "Short, compliant SMS under 160 chars."
            }
        }
    }

    /// Generate real, deterministic copy for a format in the buyer's tone. No network,
    /// no fabricated claims (no invented stats/results) — just well-structured templates
    /// the buyer edits. `business`/`topic`/`city` are the buyer's own inputs.
    static func content(format: ContentFormat, business: String, topic: String, city: String,
                        tone: CaptionTone, hashtag: String) -> String {
        let biz = business.trimmingCharacters(in: .whitespaces)
        let who = biz.isEmpty ? "We" : biz
        let whoName = biz.isEmpty ? "Your Business" : biz
        let t = topic.trimmingCharacters(in: .whitespaces).isEmpty ? "what we do" : topic.trimmingCharacters(in: .whitespaces)
        let c = city.trimmingCharacters(in: .whitespaces)
        let loc = c.isEmpty ? "" : " in \(c)"
        let tag: String = {
            let h = hashtag.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty else { return "" }
            return h.hasPrefix("#") ? h : "#" + h.replacingOccurrences(of: " ", with: "")
        }()
        switch format {
        case .socialPost:
            return captions(for: topic, tone: tone, hashtag: hashtag).first ?? ""
        case .blogOutline:
            return """
            # \(t.capitalizedFirst): A Guide from \(whoName)

            ## Introduction
            - Who \(whoName) is and who this is for\(loc)
            - The problem readers are trying to solve

            ## Why \(t) matters
            - The cost of getting it wrong
            - What good looks like

            ## How \(whoName) approaches \(t)
            - Step 1 — assess
            - Step 2 — plan
            - Step 3 — deliver

            ## What to look for in a partner
            - Experience, transparency, and follow-through

            ## Next steps
            - Call to action: reach out to \(whoName)\(loc) for a quote
            """
        case .adCopy:
            return """
            HEADLINE: \(t.capitalizedFirst)\(loc) — Done Right
            PRIMARY TEXT: Looking for \(t.lowercased())\(loc)? \(who) make\(biz.isEmpty ? "" : "s") it simple: clear pricing, real craftsmanship, and people who show up. Get a free quote today.
            CTA: Get a Free Quote
            """
        case .emailBlast:
            let subj = "\(t.capitalizedFirst)\(loc) — here's how \(whoName) can help"
            return """
            SUBJECT: \(subj)

            Hi there,

            \(who) wanted to share something we think you'll find useful about \(t.lowercased()).

            We keep it simple: do great work, communicate clearly, and stand behind every job. If you've been putting off \(t.lowercased()), now's a good time to take the first step.

            Reply to this email or give us a call — we'd be glad to help\(loc).

            Best,
            \(whoName)
            """
        case .landingCopy:
            return """
            HERO HEADLINE: \(whoName)
            SUBHEAD: \(t.capitalizedFirst)\(loc) you can count on.
            BENEFIT 1: Quality that lasts — we get it right the first time.
            BENEFIT 2: Fair, upfront pricing with no surprises.
            BENEFIT 3: Friendly local service\(loc.isEmpty ? "" : " right here\(loc)").
            CTA: Get a Free Quote
            """
        case .smsBlast:
            let base = "\(whoName): \(t.capitalizedFirst)\(loc)! Reply for a free quote. Txt STOP to opt out."
            return String(base.prefix(160)) + (tag.isEmpty ? "" : "")
        }
    }

    /// Three DISTINCT ad-copy variations (different angles: benefit, urgency, social-proof) so the
    /// buyer can A/B them — the website claims "ad variations" (plural). Real text from the buyer's
    /// own inputs; never fabricated metrics.
    static func adVariations(business: String, topic: String, city: String, tone: CaptionTone) -> [String] {
        let biz = business.trimmingCharacters(in: .whitespaces)
        let who = biz.isEmpty ? "We" : biz
        let whoName = biz.isEmpty ? "Your Business" : biz
        let t = topic.trimmingCharacters(in: .whitespaces).isEmpty ? "what we do" : topic.trimmingCharacters(in: .whitespaces)
        let c = city.trimmingCharacters(in: .whitespaces)
        let loc = c.isEmpty ? "" : " in \(c)"
        let s = biz.isEmpty ? "" : "s"
        return [
            // 1 — benefit-led
            """
            HEADLINE: \(t.capitalizedFirst)\(loc) — Done Right
            PRIMARY TEXT: Looking for \(t.lowercased())\(loc)? \(who) make\(s) it simple: clear pricing, real craftsmanship, and people who show up.
            CTA: Get a Free Quote
            """,
            // 2 — urgency-led
            """
            HEADLINE: Booking \(t.capitalizedFirst) Now\(loc)
            PRIMARY TEXT: Spots for \(t.lowercased()) fill fast. Lock in your slot with \(whoName) today and skip the wait — no pressure, just honest work.
            CTA: Check Availability
            """,
            // 3 — social-proof-led
            """
            HEADLINE: Why Locals Choose \(whoName)
            PRIMARY TEXT: \(who) built a reputation\(loc) on \(t.lowercased()) done the right way — the first time. See what neighbors are saying, then get your own quote.
            CTA: See Reviews & Get a Quote
            """
        ]
    }

    /// The seven publishing lanes the website promises generation for.
    static let repurposeLanes: [String] = ["Email", "Instagram", "TikTok", "X", "Facebook", "LinkedIn", "Threads"]

    /// Repurpose ONE idea into a tailored draft for each of the 7 lanes (one-to-many), respecting
    /// each platform's voice and length convention. Real text from the buyer's inputs; the
    /// "generation live across all seven lanes" claim made true.
    static func repurpose(idea: String, business: String, city: String, tone: CaptionTone, hashtag: String) -> [(lane: String, draft: String)] {
        let t = idea.trimmingCharacters(in: .whitespaces).isEmpty ? "our latest offer" : idea.trimmingCharacters(in: .whitespaces)
        let caps = captions(for: t, tone: tone, hashtag: hashtag)
        let cap = caps.first ?? t
        let tag: String = {
            let h = hashtag.trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty else { return "" }
            return h.hasPrefix("#") ? h : "#" + h.replacingOccurrences(of: " ", with: "")
        }()
        func clamp(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }
        return repurposeLanes.map { lane in
            switch lane {
            case "Email":
                return (lane, content(format: .emailBlast, business: business, topic: t, city: city, tone: tone, hashtag: hashtag))
            case "Instagram":
                return (lane, clamp(cap, 2200) + (tag.isEmpty ? "" : "\n\n\(tag)"))
            case "TikTok":
                return (lane, clamp(cap, 150) + (tag.isEmpty ? "" : " \(tag)"))
            case "X":
                return (lane, clamp(cap, 280))
            case "Facebook":
                return (lane, caps.prefix(2).joined(separator: "\n\n"))
            case "LinkedIn":
                // Professional reframe regardless of caption tone.
                return (lane, content(format: .socialPost, business: business, topic: t, city: city, tone: .professional, hashtag: hashtag))
            case "Threads":
                return (lane, clamp(cap, 500))
            default:
                return (lane, cap)
            }
        }
    }

    /// Compose a real spotlight pitch email (subject + plain-text body) for a client.
    /// `sender` is the buyer's own identity; nothing is hardcoded or fabricated.
    /// `email` is the buyer's own reply-to address (optional) — appended to the signature
    /// so the recipient can actually reach them; never invented when blank.
    static func spotlightEmail(client: Lead, sender: (name: String, brand: String, tagline: String, email: String))
        -> (subject: String, body: String) {
        let bizRaw = client.company.isEmpty ? client.name : client.company
        let biz = bizRaw.trimmingCharacters(in: .whitespaces).isEmpty ? "your business" : bizRaw
        let ind = client.industry.trimmingCharacters(in: .whitespaces)
        let brand = sender.brand.trimmingCharacters(in: .whitespaces).isEmpty ? "our studio" : sender.brand
        let from = sender.name.trimmingCharacters(in: .whitespaces)
        let tagline = sender.tagline.trimmingCharacters(in: .whitespaces)
        let replyTo = sender.email.trimmingCharacters(in: .whitespaces)

        let subject = ind.isEmpty
            ? "A quick idea for \(biz)"
            : "Helping \(ind.lowercased()) like \(biz) get found online"

        var body = "Hi \(biz) team,\n\n"
        body += ind.isEmpty
            ? "I came across \(biz) and wanted to reach out. "
            : "I came across \(biz) while researching \(ind.lowercased()) in the area, and wanted to reach out. "
        body += "I run \(brand)"
        body += tagline.isEmpty ? "" : " — \(tagline)"
        body += ".\n\n"
        body += "We help local businesses look sharp and get found: a fast, modern landing page; "
        body += "ready-to-post social captions; and campaign links so you can see what's working. "
        body += "No long contracts — just clean work that brings in calls.\n\n"
        body += "If you're open to it, I'd love to show you a quick first-pass preview built specifically for \(biz). "
        body += "Would a 10-minute call this week work?\n\n"
        body += "Best,\n"
        body += from.isEmpty ? brand : "\(from)\n\(brand)"
        // Append the buyer's own reply-to address when provided — real contact, never fabricated.
        body += replyTo.isEmpty ? "" : "\n\(replyTo)"
        return (subject, body)
    }

    /// Build a mailto: URL the system opens in the buyer's own mail client.
    static func mailtoURL(to: String, subject: String, body: String) -> URL? {
        var comp = URLComponents()
        comp.scheme = "mailto"
        comp.path = to.trimmingCharacters(in: .whitespaces)
        comp.queryItems = [URLQueryItem(name: "subject", value: subject),
                           URLQueryItem(name: "body", value: body)]
        // mailto requires %20 (not +) for spaces in the query.
        comp.percentEncodedQuery = comp.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        return comp.url
    }

    /// Build a UTM-tagged URL via URLComponents (real, RFC-encoded).
    static func buildUTM(base: String, source: String, medium: String, campaign: String) -> String? {
        let b = base.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return nil }
        let normalized = (b.hasPrefix("http://") || b.hasPrefix("https://")) ? b : "https://" + b
        guard var comp = URLComponents(string: normalized), comp.host != nil else { return nil }
        var items = comp.queryItems ?? []
        func add(_ name: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespaces)
            guard !v.isEmpty else { return }
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: v))
        }
        add("utm_source", source)
        add("utm_medium", medium)
        add("utm_campaign", campaign)
        comp.queryItems = items.isEmpty ? nil : items
        return comp.url?.absoluteString
    }

    /// Build one agency/client handoff from the buyer's own campaign inputs. This
    /// deliberately bundles created assets, not performance claims.
    static func campaignPack(business: String, type: String, city: String, phone: String,
                             topic: String, channel: String, senderName: String,
                             senderBrand: String, tagline: String, senderEmail: String,
                             baseURL: String, formEndpoint: String, contactEmail: String,
                             template: SiteTemplate = .bold, palette: SitePalette = .gold,
                             tone: CaptionTone = .professional, hashtag: String = "") -> CampaignPack {
        let biz = firstNonEmpty(business, senderBrand, "Your Business")
        let campaign = firstNonEmpty(topic, "First campaign")
        let industry = firstNonEmpty(type, "Local Services")
        let ch = firstNonEmpty(channel, "Instagram")
        let page = landingPage(name: biz, type: industry, city: city, phone: phone,
                               template: template, palette: palette,
                               formEndpoint: formEndpoint, contactEmail: contactEmail)
        let caps = captions(for: campaign, tone: tone, hashtag: hashtag)
        let post = draftPost(business: biz, topic: campaign, channel: ch, hashtag: hashtag)
        let email = emailParts(from: content(format: .emailBlast, business: biz, topic: campaign,
                                             city: city, tone: tone, hashtag: hashtag))
        let sms = content(format: .smsBlast, business: biz, topic: campaign, city: city,
                          tone: tone, hashtag: hashtag)
        let source = slug(ch)
        let campaignSlug = slug(campaign)
        let utm = buildUTM(base: baseURL, source: source, medium: source == "email" ? "email" : "organic",
                           campaign: campaignSlug) ?? ""
        let schema = SchemaEngine.localBusiness(name: biz, type: industry, phone: phone,
                                                city: city, url: baseURL)
        let owner = firstNonEmpty(senderName, senderBrand, biz)
        let reply = senderEmail.trimmingCharacters(in: .whitespaces)
        let checklist = [
            "Review landing page copy and contact details.",
            "Publish the landing page HTML to the client's site or host.",
            utm.isEmpty ? "Add the final page URL before posting." : "Use the tracked campaign URL in posts and email.",
            "Post the social copy on \(ch).",
            "Send the email from \(reply.isEmpty ? owner : reply).",
            "Log real clicks and conversions in Campaign Links after launch."
        ]
        return CampaignPack(title: "\(biz) - \(campaign) Campaign Pack",
                            business: biz, topic: campaign, channel: ch, landingHTML: page,
                            socialPost: post, captions: caps, emailSubject: email.subject,
                            emailBody: email.body, sms: sms, schemaJSONLD: schema,
                            utmURL: utm, checklist: checklist)
    }

    private static func emailParts(from text: String) -> (subject: String, body: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let first = lines.first ?? ""
        let subject = first.replacingOccurrences(of: "SUBJECT:", with: "")
            .trimmingCharacters(in: .whitespaces)
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (subject.isEmpty ? "Campaign update" : subject, body)
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func slug(_ value: String) -> String {
        let pieces = value.lowercased().unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }
        let collapsed = pieces.joined().split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "campaign" : collapsed
    }
}

// MARK: - Local accounts (on-device, App Store 5.1.1(v) deletion supported)

enum AuthError: String, Error {
    case badEmail = "Enter a valid email address."
    case weakPw = "Password must be at least 6 characters."
    case exists = "An account with that email already exists — sign in instead."
    case noAccount = "No account found for that email — create one first."
    case wrongPw = "Incorrect password. Try again."
}
enum AccountStore {
    static let key = "com.blacklabel.marketing.accounts"
    static func load() -> [String: String] { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
    static func save(_ d: [String: String]) { UserDefaults.standard.set(d, forKey: key) }
    static func hash(_ e: String, _ p: String) -> String {
        SHA256.hash(data: Data((e.lowercased() + "::" + p).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func create(_ email: String, _ pw: String) -> Result<Void, AuthError> {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard e.contains("@"), e.contains(".") else { return .failure(.badEmail) }
        guard pw.count >= 6 else { return .failure(.weakPw) }
        var a = load(); if a[e] != nil { return .failure(.exists) }
        a[e] = hash(e, pw); save(a); return .success(())
    }
    static func signIn(_ email: String, _ pw: String) -> Result<Void, AuthError> {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased(); let a = load()
        guard let h = a[e] else { return .failure(.noAccount) }
        return h == hash(e, pw) ? .success(()) : .failure(.wrongPw)
    }
    static func delete(_ email: String) { var a = load(); a[email.trimmingCharacters(in: .whitespaces).lowercased()] = nil; save(a) }
}

final class Session: ObservableObject {
    @Published var signedIn = false
    @Published var email = ""
    /// True when the app was entered via "Explore with sample data" (reviewer/demo).
    /// Drives the app-wide DEMO banner and demo-action simulation. Never set for
    /// real sign-in or empty-guest sessions.
    @Published var demoMode = false
}

// MARK: - Multi-page site pack (lives here because it composes Studio.landingPage;
// SiteContent.swift must stay standalone-compilable for its engine proof).
extension SiteDeploy {
    /// Multi-page site pack: index / services / about / contact composed from the SAME honest
    /// sections as the one-pager (nothing invented to pad a page), cross-linked nav with an
    /// active state, one shared design system, robots + a sitemap covering every page, and the
    /// same deploy guide. This is the "full website" export; `pack` remains the one-pager.
    static func multiPack(name: String, type: String, city: String, phone: String,
                          template: SiteTemplate = .bold, palette: SitePalette = .gold,
                          formEndpoint: String = "", contactEmail: String = "",
                          headline: String = "", subhead: String = "", funnel: Bool = false,
                          content: SiteContent = SiteContent(), siteURL: String = "",
                          galleryImages: [String] = [],
                          today: Date = Date()) -> [(name: String, body: String)] {
        func page(_ kind: Studio.SitePageKind) -> String {
            Studio.landingPage(name: name, type: type, city: city, phone: phone,
                               template: template, palette: palette,
                               formEndpoint: formEndpoint, contactEmail: contactEmail,
                               headline: headline, subheadOverride: subhead, funnel: funnel,
                               content: content, page: kind, galleryImages: galleryImages)
        }
        var files: [(String, String)] = [
            ("index.html", page(.home)),
            ("services.html", page(.services)),
            ("about.html", page(.about)),
            ("contact.html", page(.contact)),
        ]
        // Projects page exists ONLY when the buyer supplied real photos (exporter writes
        // the image files themselves into images/).
        if !galleryImages.isEmpty { files.insert(("projects.html", page(.projects)), at: 2) }
        let url = canonicalURL(siteURL)
        var robots = "User-agent: *\nAllow: /\n"
        if !url.isEmpty { robots += "Sitemap: \(url)/sitemap.xml\n" }
        files.append(("robots.txt", robots))
        if !url.isEmpty {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
            let d = fmt.string(from: today)
            var locs = ["/", "/services.html", "/about.html", "/contact.html"]
            if !galleryImages.isEmpty { locs.insert("/projects.html", at: 2) }
            let entries = locs
                .map { "  <url><loc>\(xmlEscape(url))\($0)</loc><lastmod>\(d)</lastmod></url>" }
                .joined(separator: "\n")
            files.append(("sitemap.xml", """
            <?xml version="1.0" encoding="UTF-8"?>
            <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
            \(entries)
            </urlset>
            """))
        }
        // Reuse the one-pager's deploy guide verbatim (same hosts, same steps).
        if let guide = pack(html: "", siteName: name, siteURL: siteURL, today: today).first(where: { $0.name == "DEPLOY.md" }) {
            files.append(guide)
        }
        return files
    }
}
#endif // circuit-convert
