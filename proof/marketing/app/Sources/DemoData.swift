// Black Label Marketing — Reviewer / buyer DEMO mode.
//
// PURPOSE: let an App Store reviewer (and any prospective buyer) experience the
// FULL app with ZERO external accounts — no sign-in, no mailbox, no AI/provider
// login, no data source to bring. Reachable from the sign-in screen via
// "Explore with sample data" (a guest path).
//
// ZERO-HALLUCINATION / SHIP-NO-DATA contract (the app's inviolable rules):
//   • Every record here is SYNTHETIC and CLEARLY LABELED — fictional businesses
//     ("Bridgepoint Plumbing & Drain", "Cedar & Pine Cleaning", etc.), the (Sample) suffix on names, and a
//     visible "DEMO" banner in the running app. Nothing presents seeded data as
//     real, and no real reach/results are invented (the "logged" metrics shown
//     are openly part of the labeled sample, never claimed as the buyer's own).
//   • NOTHING here is Michael's data or Utah data: no real leads, no personal
//     email/phone/address. Phone numbers use the reserved 555-01xx range; emails
//     use example.com (RFC-2606 reserved). Cities are real metro labels only.
//   • This seed runs ONLY when the user explicitly enters demo mode — it is never
//     applied to the real (signed-in / guest-empty) store, which still starts
//     EMPTY on the buyer's own data. Demo state lives in a SEPARATE on-disk store
//     (workspace-demo.sqlite3) so it can never overwrite real buyer data.
//   • External side-effects (opening Mail, opening a URL) are SAFELY SIMULATED in
//     demo mode via DemoMode.openExternal — no real send, nothing leaves the app.
//
// The result: a reviewer taps one button and sees every screen populated, can
// one-click generate a real sample landing page + a real sample reel storyboard,
// and can exercise compose/schedule flows that are clearly labeled demo actions.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Demo mode flag (process-wide)

/// Process-wide demo switch. Set true ONLY by the "Explore with sample data"
/// entry point. Read by external-action call sites so they simulate instead of
/// firing real apps, and by Model/Prefs so demo persists to a SEPARATE store.
enum DemoMode {
    /// True while the app is in reviewer/demo mode. Off for real (signed-in) use.
    static private(set) var active = false

    /// Most-recent simulated-action note (so the UI can surface a truthful toast
    /// like "Demo: this would open your mail app" without any real side-effect).
    static var lastSimulatedNote = ""

    static func enable()  { active = true }
    static func disable() { active = false }

    /// Open an external URL — but in demo mode, SIMULATE it (no real Mail/Safari
    /// launch, no account needed) and record an honest note. Returns true if it
    /// actually opened; false if it was simulated.
    @discardableResult
    static func openExternal(_ url: URL, simulatedNote: String) -> Bool {
        if active {
            lastSimulatedNote = simulatedNote
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    /// A clearly-labeled banner string shown app-wide while in demo mode.
    static let banner = "DEMO MODE · Sample data — nothing here is real, and no email or post is actually sent."
}

/// Environment-gated destinations used only by the exact-build UI proof lane. A normal launch has
/// no value and follows the buyer navigation unchanged; these names never seed or replace data.
enum DemoProofSurface: String {
    case reel
    case email
    case postInsights = "post-insights"
    case crmDetail = "crm-detail"
    case campaignResults = "campaign-results"

    static var current: DemoProofSurface? {
        ProcessInfo.processInfo.environment["BLM_DEMO_PROOF_SURFACE"].flatMap(DemoProofSurface.init(rawValue:))
    }
}

/// Stable, app-generated demo artifacts. These files live outside the buyer's workspace and are
/// created only after the buyer explicitly enters demo mode. The reel is rendered by the same
/// `ReelRenderer` used for customer projects; it is not a bundled marketing mockup.
enum DemoArtifacts {
    static var directoryURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("BlackLabelMarketing/DemoOutputs", isDirectory: true)
    }

    static var renderedReelURL: URL {
        directoryURL.appendingPathComponent("lighthouse-sample-reel.mp4")
    }

    static func hasRenderedReel() -> Bool {
        guard let values = try? renderedReelURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return false }
        return values.isRegularFile == true && (values.fileSize ?? 0) > 4_096
    }
}

// MARK: - Demo banner (always-visible truthful label)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// A thin, always-visible bar shown app-wide in demo mode. States plainly that the
/// data is sample and nothing is actually sent — so a reviewer/buyer is never misled —
/// and carries the one obvious path from "trying it" to "using it for real":
/// a "Connect your own & go live" button that exits demo into the real, empty workspace.
struct DemoBanner: View {
    /// Called when the reviewer/buyer chooses to leave the demo and set up for real.
    var onGoLive: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
            Text("DEMO MODE")
                .font(.system(size: 10.5, weight: .heavy, design: .rounded)).tracking(1.2)
            Text("· Sample data — nothing here is real, and no email or post is actually sent.")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            Spacer(minLength: 12)
            Button(action: onGoLive) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.forward.circle.fill").font(.system(size: 11, weight: .bold))
                    Text("Connect your own & go live").font(.system(size: 11, weight: .heavy, design: .rounded))
                }
                .foregroundColor(.white)
                .padding(.vertical, 4).padding(.horizontal, 12)
                .background(Capsule().fill(Color.black.opacity(hovering ? 0.92 : 0.82)))
                .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Leave the sample data and open your own empty workspace to sign in and go live.")
        }
        .foregroundColor(.black)
        .padding(.vertical, 6).padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [Color(hex: 0xE6C766), Color(hex: 0xC79A3A)],
                           startPoint: .leading, endPoint: .trailing)
        )
        .overlay(Rectangle().fill(Color.black.opacity(0.18)).frame(height: 1), alignment: .bottom)
    }
}
#endif // circuit-convert

// MARK: - Synthetic sample-data provider

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Builds a realistic, clearly-labeled sample workspace. Pure data construction —
/// no network, no fabrication of real-world results. Everything is fictional.
enum DemoData {

    /// Apply the full sample workspace to a fresh model + prefs. Idempotent: it
    /// replaces the demo store's contents wholesale, so re-entering demo mode is clean.
    static func seed(model: AppModel, prefs: Prefs) {
        seedPrefs(prefs)
        let now = Date()
        func daysAgo(_ d: Int) -> Date { Calendar.current.date(byAdding: .day, value: -d, to: now) ?? now }
        func daysAhead(_ d: Int) -> Date { Calendar.current.date(byAdding: .day, value: d, to: now) ?? now }

        // --- Saved clients (fictional businesses to pitch) ---------------------
        let clients: [ClientLead] = [
            ClientLead(name: "Bridgepoint Plumbing & Drain (Sample)", domain: "bridgepointplumbing.example.com",
                       phone: "(512) 555-0142", email: "hello@bridgepointplumbing.example.com",
                       address: "210 Cedar Ave, Austin, TX", industry: "Plumbing", created: daysAgo(12)),
            ClientLead(name: "Cedar & Pine Cleaning (Sample)", domain: "cedarpineclean.example.com",
                       phone: "(615) 555-0188", email: "team@cedarpineclean.example.com",
                       address: "44 Music Row, Nashville", industry: "Cleaning", created: daysAgo(9)),
            ClientLead(name: "Lumen Salon & Spa (Sample)", domain: "lumensalon.example.com",
                       phone: "(305) 555-0173", email: "front@lumensalon.example.com",
                       address: "880 Ocean Dr, Miami", industry: "Salon / Beauty", created: daysAgo(7)),
            ClientLead(name: "Summit Strength Gym (Sample)", domain: "summitstrength.example.com",
                       phone: "(303) 555-0119", email: "coach@summitstrength.example.com",
                       address: "1700 Blake St, Denver", industry: "Fitness", created: daysAgo(5)),
            ClientLead(name: "Harbor Table Bistro (Sample)", domain: "harbortable.example.com",
                       phone: "(206) 555-0150", email: "reserve@harbortable.example.com",
                       address: "55 Pike St, Seattle", industry: "Restaurant", created: daysAgo(3)),
        ]
        model.leads = clients.map(Lead.init(legacy:)) + model.leads

        // --- A generated landing page (REAL output from the live engine) -------
        let siteHTML = Studio.landingPage(name: "Bridgepoint Plumbing & Drain", type: "Plumbing", city: "Austin",
                                          phone: "(512) 555-0142", template: .bold, palette: .gold,
                                          formEndpoint: "", contactEmail: "hello@bridgepointplumbing.example.com")
        let site = SiteProject(name: "Bridgepoint Plumbing & Drain — Landing (Sample)", businessType: "Plumbing",
                               city: "Austin", phone: "(512) 555-0142", html: siteHTML, created: daysAgo(6))
        let site2HTML = Studio.landingPage(name: "Lumen Salon & Spa", type: "Salon / Beauty", city: "Miami",
                                          phone: "(305) 555-0173", template: .classic, palette: .crimson)
        let site2 = SiteProject(name: "Lumen Salon — Landing (Sample)", businessType: "Salon / Beauty",
                                city: "Miami", phone: "(305) 555-0173", html: site2HTML, created: daysAgo(2))
        model.sites = [site2, site]

        // --- A reel project (REAL storyboard from the live engine) -------------
        var reel = ReelProject(name: "Bridgepoint Plumbing & Drain — Promo Reel (Sample)", format: .vertical,
                               scenes: ReelStoryboard.defaultScenes(business: "Bridgepoint Plumbing & Drain",
                                                                    topic: "24/7 Emergency Service", city: "Austin"),
                               paletteAccentHex: SitePalette.gold.accentRGB, fps: 30, created: daysAgo(4))
        reel.scenes.append(ReelScene(headline: "Call (512) 555-0142", subtitle: "Licensed · Insured · Local", seconds: 2.4))
        model.reels = [reel]

        // --- Captions (REAL output from the live engine) -----------------------
        let caps1 = Studio.captions(for: "24/7 emergency plumbing", tone: .punchy, hashtag: "BridgepointPlumbing")
        let caps2 = Studio.captions(for: "fresh spring hair color", tone: .luxury, hashtag: "LumenSalon")
        model.captions = [
            Caption(topic: "24/7 emergency plumbing (Sample)", text: caps1.first ?? "", created: daysAgo(5)),
            Caption(topic: "spring hair color (Sample)", text: caps2.first ?? "", created: daysAgo(3)),
            Caption(topic: "biweekly home cleaning (Sample)",
                    text: Studio.captions(for: "biweekly home cleaning", tone: .friendly, hashtag: "CedarPine").first ?? "",
                    created: daysAgo(1)),
        ]

        // --- Campaign links with operator-logged engagement (labeled sample) ---
        func utm(_ label: String, _ base: String, _ src: String, _ med: String, _ camp: String, clicks: Int, conv: Int, _ ago: Int) -> UTMLink {
            UTMLink(label: label, url: Studio.buildUTM(base: base, source: src, medium: med, campaign: camp) ?? base,
                    source: src, medium: med, campaign: camp, created: daysAgo(ago), clicks: clicks, conversions: conv)
        }
        model.links = [
            utm("Spring Promo — Instagram (Sample)", "bridgepointplumbing.example.com", "instagram", "social", "spring_promo", clicks: 184, conv: 12, 6),
            utm("Spring Promo — Email (Sample)", "bridgepointplumbing.example.com", "newsletter", "email", "spring_promo", clicks: 96, conv: 9, 5),
            utm("Grand Opening — Google (Sample)", "lumensalon.example.com", "google", "cpc", "grand_opening", clicks: 312, conv: 21, 3),
        ]

        // --- Captured CRM leads (synthetic, reserved contact data) -------------
        model.leads = [
            Lead(legacy: CapturedLead(name: "Jordan Avery (Sample)", email: "jordan.avery@example.com", phone: "(512) 555-0102",
                         message: "Need a quote for a water heater replacement.", sourceCampaign: "spring_promo", created: daysAgo(4))),
            Lead(legacy: CapturedLead(name: "Priya Nair (Sample)", email: "priya.nair@example.com", phone: "(305) 555-0166",
                         message: "Booking balayage for an event.", sourceCampaign: "grand_opening", created: daysAgo(2))),
            Lead(legacy: CapturedLead(name: "Marcus Lee (Sample)", email: "marcus.lee@example.com", phone: "(615) 555-0190",
                         message: "Recurring biweekly cleaning, 3-bed home.", sourceCampaign: "spring_promo", created: daysAgo(1))),
            Lead(legacy: CapturedLead(name: "Dana Brooks (Sample)", email: "dana.brooks@example.com", phone: "",
                         message: "Personal training, 2x/week.", sourceCampaign: "", created: daysAgo(0))),
        ] + model.leads

        // --- Saved audience segment (rule-based, over the sample contacts) -----
        model.segments = [
            Segment(name: "Austin leads with email (Sample)", match: .all,
                    rules: [SegRule(field: .email, op: .isNotEmpty, value: ""),
                            SegRule(field: .source, op: .contains, value: "spring")],
                    created: daysAgo(4)),
            Segment(name: "All recent contacts (Sample)", match: .any,
                    rules: [SegRule(field: .recencyDays, op: .withinDays, value: "14")],
                    created: daysAgo(2)),
        ]

        // --- Email campaign (block-based) --------------------------------------
        model.campaigns = [
            EmailCampaign(name: "Spring Tune-Up Offer (Sample)", subject: "{{first_name}}, beat the spring rush",
                          blocks: [EmailBlock(kind: .heading, text: "Spring tune-up — 15% off"),
                                   EmailBlock(kind: .paragraph, text: "Hi {{first_name}}, book your spring service before the rush and save."),
                                   EmailBlock(kind: .button, text: "Book now", url: "https://bridgepointplumbing.example.com")],
                          segmentID: model.segments.first?.id, created: daysAgo(4)),
        ]

        // --- Spotlight records (composed pitches; honest "Composed" status) ----
        model.spotlights = clients.prefix(2).map {
            SpotlightRecord(client: $0.name, subject: "A quick idea for \($0.name)",
                            to: $0.email, status: "Composed", created: daysAgo(3))
        }

        // --- SEO / brand audit history (labeled sample scores) -----------------
        model.audits = [
            AuditRecord(url: "https://bridgepointplumbing.example.com", score: 82,
                        title: "Bridgepoint Plumbing & Drain — Austin's 24/7 Plumber", failCount: 1, warnCount: 3, goodCount: 14, created: daysAgo(6)),
            AuditRecord(url: "https://lumensalon.example.com", score: 74,
                        title: "Lumen Salon & Spa — Miami", failCount: 2, warnCount: 4, goodCount: 11, created: daysAgo(2)),
        ]

        // --- Connected social profiles (manual link, honest) -------------------
        model.socialProfiles = [
            SocialProfile(platform: .instagram, handle: "bridgepointplumbing", bio: "Austin's 24/7 plumber · Licensed & insured", hasToken: false, linkedAt: daysAgo(8)),
            SocialProfile(platform: .facebook, handle: "bridgepointplumbing", bio: "Bridgepoint Plumbing & Drain — fast, fair, local.", hasToken: false, linkedAt: daysAgo(8)),
        ]

        // --- Ad campaign (operator-logged spend/results, labeled sample) -------
        model.adCampaigns = [
            AdCampaign(name: "Spring Leads — Google (Sample)", provider: .google, objective: .leads,
                       destinationURL: "bridgepointplumbing.example.com", totalBudget: 1500, spent: 640,
                       loggedClicks: 312, loggedConversions: 21, startDate: daysAgo(10), endDate: daysAhead(4), created: daysAgo(10)),
        ]

        // --- Email journey (drip; ships OFF, here pre-built for the demo) -------
        let camp = model.campaigns.first
        model.journeys = [
            Journey(name: "New-lead welcome (Sample)", enabled: false, segmentID: model.segments.last?.id,
                    steps: [JourneyStep(kind: .trigger, note: "New lead captured"),
                            JourneyStep(kind: .send, campaignID: camp?.id, campaignName: camp?.name ?? "Welcome"),
                            JourneyStep(kind: .wait, waitDays: 3),
                            JourneyStep(kind: .send, campaignName: "Day-3 follow-up")],
                    created: daysAgo(4)),
        ]

        // --- Best-time post engagement (logged, labeled sample) ----------------
        model.postStats = [
            PostEngagement(weekday: 4, hour: 18, engagement: 210, channel: "Instagram", loggedAt: daysAgo(7)),
            PostEngagement(weekday: 6, hour: 12, engagement: 165, channel: "Instagram", loggedAt: daysAgo(5)),
            PostEngagement(weekday: 2, hour: 9,  engagement: 98,  channel: "Facebook",  loggedAt: daysAgo(3)),
            PostEngagement(weekday: 4, hour: 19, engagement: 240, channel: "Instagram", loggedAt: daysAgo(1)),
        ]

        // --- Influencer CRM (entered facts only) -------------------------------
        model.influencers = [
            Influencer(handle: "austineats", platform: "Instagram", niche: "local food / austin", followers: 48000,
                       engagementRatePct: 4.2, email: "collabs@example.com", status: "Contacted",
                       notes: "Great fit for Harbor Table.", created: daysAgo(6)),
            Influencer(handle: "milehighfit", platform: "TikTok", niche: "fitness / denver", followers: 120000,
                       engagementRatePct: 3.1, email: "biz@example.com", status: "Prospect", created: daysAgo(3)),
        ]

        // --- Landing A/B test (operator-logged) --------------------------------
        model.landingTests = [
            LandingTest(name: "Hero CTA test (Sample)", goal: "Form submit",
                        variants: [LandingVariant(label: "A", siteID: site.id, siteName: site.name, views: 540, conversions: 38),
                                   LandingVariant(label: "B", siteID: site2.id, siteName: site2.name, views: 512, conversions: 51)],
                        created: daysAgo(5)),
        ]

        // --- Workflows (ship OFF; pre-built for the demo) ----------------------
        model.workflows = [
            Workflow(name: "Tag hot leads (Sample)", enabled: false, trigger: .newLead,
                     condField: .hasEmail, action: .addTag, actionValue: "hot", created: daysAgo(4)),
        ]

        // --- Multichannel campaign (tier-3) ------------------------------------
        model.mcampaigns = [
            MCampaign(name: "Spring Growth Push (Sample)", objective: "Leads",
                      start: daysAgo(10), end: daysAhead(20),
                      entries: [MChannelEntry(kind: .email,   assetRef: "Spring Tune-Up Offer", planned: 4, loggedReach: 2100, loggedClicks: 96,  loggedConversions: 9,  spend: 0,   note: "Newsletter blasts"),
                                MChannelEntry(kind: .social,  assetRef: "IG promo reel",          planned: 8, loggedReach: 5400, loggedClicks: 184, loggedConversions: 12, spend: 0,   note: "Organic posts"),
                                MChannelEntry(kind: .ads,     assetRef: "Google Leads",           planned: 1, loggedReach: 9800, loggedClicks: 312, loggedConversions: 21, spend: 640, note: "Search ads"),
                                MChannelEntry(kind: .landing, assetRef: "Bridgepoint landing",      planned: 1, loggedReach: 1052, loggedClicks: 89,  loggedConversions: 17, spend: 0,   note: "A/B in progress")],
                      created: daysAgo(10)),
        ]

        // --- ABM accounts (entered firmographics) ------------------------------
        model.abmAccounts = [
            ABMAccount(company: "Greenfield Property Group (Sample)", website: "greenfieldpg.example.com",
                       employees: 240, revenueM: 38, industryFit: 3, contactsLinked: 2, hasChampion: true,
                       notes: "Multi-location, needs per-site pages.", plays: ABMEngine.starterPlays(), created: daysAgo(7)),
            ABMAccount(company: "Lakeside Dental Partners (Sample)", website: "lakesidedental.example.com",
                       employees: 60, revenueM: 9, industryFit: 2, contactsLinked: 1, hasChampion: false,
                       notes: "3 practices.", plays: ABMEngine.starterPlays(), created: daysAgo(4)),
        ]

        // --- Referral program (logged advocates) -------------------------------
        model.referralPrograms = [
            ReferralProgram(name: "Refer-a-neighbor (Sample)", rewardType: .credit, rewardPerConversion: 25,
                            advocateMessage: "Love working with us? Refer a neighbor and you both get $25.",
                            records: [ReferralRecord(advocate: "Jordan Avery (Sample)", referrals: 6, qualified: 4, converted: 3, created: daysAgo(5)),
                                      ReferralRecord(advocate: "Priya Nair (Sample)",   referrals: 3, qualified: 2, converted: 2, created: daysAgo(2))],
                            created: daysAgo(6)),
        ]

        // --- Strategy roadmap (ICE items) --------------------------------------
        model.roadItems = [
            RoadItem(title: "Launch Google Business posts (Sample)", detail: "Weekly GBP posts for all clients", quarter: 1, impact: 8, effort: 3, done: false, created: daysAgo(5)),
            RoadItem(title: "Add SMS follow-ups (Sample)", detail: "Text new leads within 5 min", quarter: 1, impact: 9, effort: 5, done: false, created: daysAgo(4)),
            RoadItem(title: "Quarterly case-study reels (Sample)", detail: "One per top client", quarter: 2, impact: 7, effort: 4, done: false, created: daysAgo(3)),
            RoadItem(title: "Referral program rollout (Sample)", detail: "Done — see Referrals", quarter: 1, impact: 6, effort: 3, done: true, created: daysAgo(6)),
        ]

        // --- Scheduled + completed posts (content pipeline / Post Insights) -----
        // The two completed rows use deliberately synthetic provider ids and are paired with the
        // isolated sample metrics below. The app-wide DEMO banner and in-screen SAMPLE METRICS
        // panel keep these from ever reading as buyer/provider results.
        var instagramPost = ScheduledPost(title: "Spring tune-up results (Sample)", body: caps1.first ?? "",
                                          channel: SocialPlatform.instagram.rawValue,
                                          scheduledAt: daysAgo(4), created: daysAgo(6))
        instagramPost.platformRaw = SocialPlatform.instagram.rawValue
        instagramPost.publishState = "published"
        instagramPost.publishDetail = "Post id sample-instagram-001"
        instagramPost.publishedAt = daysAgo(4)

        var facebookPost = ScheduledPost(title: "Before/after re-pipe (Sample)",
                                         body: "Sample post: a before-and-after service story.",
                                         channel: SocialPlatform.facebook.rawValue,
                                         scheduledAt: daysAgo(2), created: daysAgo(3))
        facebookPost.platformRaw = SocialPlatform.facebook.rawValue
        facebookPost.publishState = "published"
        facebookPost.publishDetail = "Post id sample-facebook-001"
        facebookPost.publishedAt = daysAgo(2)

        model.posts = [
            ScheduledPost(title: "Spring maintenance reminder (Sample)", body: caps1.first ?? "", channel: "Instagram", scheduledAt: daysAhead(2), created: daysAgo(1)),
            ScheduledPost(title: "Customer story follow-up (Sample)", body: "A clearly labeled sample post planned for next week.", channel: "Facebook", scheduledAt: daysAhead(5), created: daysAgo(1)),
            instagramPost,
            facebookPost,
        ]

        // Note: auditLog (the security hash-chain) is intentionally left to record
        // real in-session events; we don't fabricate a tamper-evident history.
    }

    /// Demo brand identity — fictional studio, neutral defaults. Never Michael's data.
    private static func seedPrefs(_ prefs: Prefs) {
        prefs.brandName = "Lighthouse Local Marketing (Demo)"
        prefs.tagline = "Marketing that books the next job."
        prefs.accent = .gold
        prefs.defaultMarket = "Austin, TX"
        prefs.defaultVertical = "Local services"
        prefs.siteTemplate = .bold
        prefs.sitePalette = .gold
        prefs.captionTone = .punchy
        prefs.captionHashtag = "LighthouseLocal"
        prefs.senderName = "Alex Rivera"
        prefs.senderEmail = "alex@lighthouselocal.example.com"
        prefs.contactEmail = "hello@lighthouselocal.example.com"
    }

    /// Isolated metrics for the two synthetic completed posts above. This function is consulted
    /// only while `DemoMode.active`; real workspaces continue to show provider values or blanks.
    static func postMetrics(for post: ScheduledPost) -> PostMetrics? {
        guard DemoMode.active,
              post.publishState == "published",
              post.publishDetail?.hasPrefix("Post id sample-") == true else { return nil }
        let fetchedAt = post.publishedAt ?? post.scheduledAt
        switch post.platformRaw.flatMap(SocialPlatform.init(rawValue:)) {
        case .some(.instagram):
            return PostMetrics(impressions: 1_284, likes: 86, comments: 14, shares: 19, views: 1_116, fetchedAt: fetchedAt)
        case .some(.facebook):
            return PostMetrics(impressions: 742, likes: 41, comments: 9, shares: 7, views: nil, fetchedAt: fetchedAt)
        default:
            return nil
        }
    }
}
#endif // circuit-convert
