#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct HubTab<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let icon: String
}

struct HubTabs<ID: Hashable>: View {
    let tabs: [HubTab<ID>]
    @Binding var selection: ID

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tabs) { tab in
                    let selected = selection == tab.id
                    Button {
                        withAnimation(.easeOut(duration: 0.16)) { selection = tab.id }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11, weight: .bold))
                            Text(tab.title)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(selected ? BLTheme.inkOnGold : BLTheme.text)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 11)
                        .background(selected ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(selected ? Color.clear : BLTheme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

struct CaptionStudioInlinePanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var topic = ""
    @State private var tone: CaptionTone = .punchy
    @State private var generated: [String] = []
    @State private var inputError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Panel(title: "Caption ideation", icon: "text.quote") {
                VStack(spacing: 12) {
                    Field(title: "Topic", text: $topic, prompt: "Spring promo, new menu, grand opening...")
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TONE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                            Picker("", selection: $tone) { ForEach(CaptionTone.allCases) { Text($0.rawValue).tag($0) } }
                                .labelsHidden()
                                .tint(BLTheme.gold)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if !prefs.captionHashtag.trimmingCharacters(in: .whitespaces).isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("BRAND TAG").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                                Text("#" + prefs.captionHashtag.replacingOccurrences(of: "#", with: ""))
                                    .font(BLFonts.mono(12, weight: .semibold))
                                    .foregroundColor(BLTheme.gold)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    GoldButton(label: "Generate captions", fill: true, icon: "sparkles") {
                        guard !topic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            inputError = "Add a real topic or offer before generating captions."
                            generated = []
                            return
                        }
                        inputError = ""
                        generated = Studio.captions(for: topic, tone: tone, hashtag: prefs.captionHashtag)
                    }
                    if !inputError.isEmpty {
                        Text(inputError).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !generated.isEmpty {
                Panel(title: "Suggestions", icon: "lightbulb.fill") {
                    VStack(spacing: 8) {
                        ForEach(Array(generated.enumerated()), id: \.offset) { _, text in
                            captionRow(text, topic: topic, saveable: true)
                        }
                    }
                }
            }

            if !model.captions.isEmpty {
                Panel(title: "Saved captions (\(model.captions.count))", icon: "books.vertical.fill") {
                    VStack(spacing: 8) {
                        ForEach(model.captions) { caption in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(caption.topic)
                                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                        .foregroundColor(BLTheme.gold)
                                    Text(caption.text)
                                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                        .foregroundColor(BLTheme.text)
                                }
                                Spacer()
                                IconButton(system: "doc.on.doc") { copy(caption.text) }
                                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteCaption(caption) }
                            }
                            .padding(10)
                            .background(BLTheme.bg2)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                        }
                    }
                }
            }
        }
        .onAppear { tone = prefs.captionTone }
    }

    private func captionRow(_ text: String, topic: String, saveable: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundColor(BLTheme.text)
            Spacer()
            IconButton(system: "doc.on.doc") { copy(text) }
            if saveable {
                IconButton(system: "plus.circle.fill", tint: BLTheme.green) {
                    let cleanTopic = topic.trimmingCharacters(in: .whitespaces).isEmpty ? "general" : topic
                    model.addCaption(Caption(topic: cleanTopic, text: text))
                }
            }
        }
        .padding(10)
        .background(BLTheme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct SitesDailyMailScreen: View {
    enum Mode: String, Hashable {
        case sites, dailyMail
    }

    @State private var mode: Mode
    private let tabs = [
        HubTab(id: Mode.sites, title: "Sites", icon: "globe"),
        HubTab(id: Mode.dailyMail, title: "Daily Mail", icon: "envelope.open.fill")
    ]

    init(initial: Mode = .sites) {
        _mode = State(initialValue: initial)
    }

    // Pinned header + tabs; children scroll themselves (see LeadsHubScreen for why no outer scroll).
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Websites & Daily Email",
                             subtitle: "Publish your landing pages and keep a daily email rhythm — both live here.")
                HubTabs(tabs: tabs, selection: $mode)
            }
            .padding(.horizontal, 26).padding(.top, 26)
            Group {
                switch mode {
                case .sites:
                    SiteStudioScreen()
                case .dailyMail:
                    // Fixed config panel on top; the newsletter screen scrolls in the remaining space.
                    VStack(alignment: .leading, spacing: 14) {
                        CloudflareDailyMailConfigPanel().padding(.horizontal, 26)
                        NewsletterScreen()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct CloudflareDailyMailConfigPanel: View {
    @State private var endpoint = CloudflareEmailConfig.endpoint
    @State private var fromEmail = CloudflareEmailConfig.fromEmail
    @State private var fromName = CloudflareEmailConfig.fromName
    @State private var token = ""
    @State private var autoSend = CloudflareEmailConfig.autoSend
    @State private var hasToken = CloudflareEmailConfig.hasToken
    @State private var note = ""

    var body: some View {
        let configured = CloudflareEmailConfig.isConfigured(endpoint: endpoint, fromEmail: fromEmail, hasToken: hasToken)
        Panel(title: "Daily Mail configuration", icon: "cloud.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Optional/advanced — newsletters already send over your own mailbox with no setup. Configure this only to route high-volume sends through your own Cloudflare Email Sending instead.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.sub)
                    Spacer()
                    StatusPill(text: configured ? "Configured" : "Off", tint: configured ? BLTheme.gold : BLTheme.sub)
                }
                Field(title: "Worker endpoint (https)", text: $endpoint, prompt: "https://newsletter.yourname.workers.dev/send")
                HStack(spacing: 10) {
                    Field(title: "From email", text: $fromEmail, prompt: "news@yourbrand.com")
                    Field(title: "From name", text: $fromName, prompt: "Acme Studio")
                }
                SecureRow(title: hasToken ? "Shared secret (saved - type to replace)" : "Shared secret (Bearer token)",
                          prompt: hasToken ? "Saved" : "Paste the token from wrangler secret put",
                          onCommit: { token = $0 })
                Toggle(isOn: $autoSend) {
                    Text("Auto-send due newsletters through Cloudflare")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.text)
                }
                .tint(BLTheme.gold)
                HStack(spacing: 10) {
                    GoldButton(label: "Save Daily Mail config", icon: "checkmark.circle") { save() }
                    GhostButton(label: "Cloudflare guide", icon: "arrow.up.right") {
                        if let url = URL(string: "https://developers.cloudflare.com/email-service/") {
                            DemoMode.openExternal(url, simulatedNote: "Demo: this would open Cloudflare Email Sending.")
                        }
                    }
                }
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(note.hasPrefix("Saved") ? BLTheme.green : BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func save() {
        CloudflareEmailConfig.endpoint = endpoint
        CloudflareEmailConfig.fromEmail = fromEmail
        CloudflareEmailConfig.fromName = fromName
        CloudflareEmailConfig.autoSend = autoSend
        if !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CloudflareEmailConfig.setToken(token)
            token = ""
        }
        hasToken = CloudflareEmailConfig.hasToken
        note = CloudflareEmailConfig.isConfigured ? "Saved Daily Mail config." : "Saved. Add a valid https endpoint, from email, and shared secret to connect."
    }
}

struct CampaignHubScreen: View {
    enum Mode: String, Hashable {
        case ads, campaigns
    }

    @State private var mode: Mode
    private let tabs = [
        HubTab(id: Mode.ads, title: "Ad Campaigns", icon: "megaphone.fill"),
        HubTab(id: Mode.campaigns, title: "Campaigns", icon: "rectangle.3.group.fill")
    ]

    init(initial: Mode = .ads) {
        _mode = State(initialValue: initial)
    }

    // Pinned header + tabs; children scroll themselves (see LeadsHubScreen for why no outer scroll).
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Ad Campaigns",
                             subtitle: "Paid ads and campaign planning are one campaign workspace.")
                HubTabs(tabs: tabs, selection: $mode)
            }
            .padding(.horizontal, 26).padding(.top, 26)
            Group {
                switch mode {
                case .ads: AdCampaignsScreen()
                case .campaigns: MCampaignScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct OutreachHubScreen: View {
    enum Mode: String, Hashable {
        case email, journeys, sequences, messages, inbox, delivery, deals, workflows
    }

    @State private var mode: Mode
    private let tabs = [
        HubTab(id: Mode.email, title: "Email Builder", icon: "envelope.badge.fill"),
        HubTab(id: Mode.journeys, title: "Journeys", icon: "arrow.triangle.branch"),
        HubTab(id: Mode.sequences, title: "Sequences", icon: "paperplane.fill"),
        HubTab(id: Mode.messages, title: "Messages", icon: "message.fill"),
        HubTab(id: Mode.inbox, title: "Inbox", icon: "tray.and.arrow.down.fill"),
        HubTab(id: Mode.delivery, title: "Delivery", icon: "checkmark.seal.fill"),
        HubTab(id: Mode.deals, title: "Deals", icon: "chart.bar.doc.horizontal.fill"),
        HubTab(id: Mode.workflows, title: "Workflows", icon: "gearshape.2.fill")
    ]

    init(initial: Mode = .email) {
        _mode = State(initialValue: initial)
    }

    // Pinned header + tabs; children scroll themselves (see LeadsHubScreen for why no outer scroll).
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Outreach",
                             subtitle: "Email building, journeys, sequences, inbox, deal movement, and workflow automation are one operating surface.")
                HubTabs(tabs: tabs, selection: $mode)
            }
            .padding(.horizontal, 26).padding(.top, 26)
            Group {
                switch mode {
                case .email: EmailBuilderScreen()
                case .journeys: JourneyScreen()
                case .sequences: SequencesScreen()
                case .messages: MessagesScreen()
                case .inbox: InboxScreen()
                case .delivery: DeliveryDashboard()
                case .deals: DealPipelineScreen()
                case .workflows: WorkflowScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct LeadsHubScreen: View {
    enum Mode: String, Hashable {
        case crm, database, finder, importer
    }

    @State private var mode: Mode
    // b26: the Lead Database tab is on iOS behind the in-app StoreKit 2 subscription
    // (com.blacklabel.marketing.leaddb.monthly) ONLY. The user-pasted access-key unlock was
    // removed under Guideline 3.1.1 — the App Store app is consumer-only, no web/enterprise key.
    private let tabs = [
        HubTab(id: Mode.crm, title: "CRM Leads", icon: "person.2.badge.gearshape.fill"),
        HubTab(id: Mode.database, title: "Lead Database", icon: "tray.full.fill"),
        HubTab(id: Mode.finder, title: "Find Clients", icon: "building.2.fill"),
        HubTab(id: Mode.importer, title: "Import", icon: "square.and.arrow.down.fill")
    ]

    init(initial: Mode = .crm) {
        _mode = State(initialValue: initial)
    }

    // Hub shell = pinned header + tabs; each child screen owns its OWN scrolling. The old outer
    // ScrollView nested every child's ScrollView inside it — scroll events deadlocked (the page
    // wouldn't move at all) and laziness died, which is how the 10k-lead CRM tab froze the machine.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Leads",
                             subtitle: "CRM contacts, the full lead database, and client discovery are merged into one page.")
                HubTabs(tabs: tabs, selection: $mode)
            }
            .padding(.horizontal, 26).padding(.top, 26)
            Group {
                switch mode {
                case .crm: LeadsScreen()
                case .database: LeadDatabaseScreen()
                case .finder: ClientsScreen()
                case .importer: LeadImportScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct GrowHubScreen: View {
    enum Mode: String, Hashable {
        case audience, scoring, plays, creators, strategy, search
    }

    @State private var mode: Mode
    private let tabs = [
        HubTab(id: Mode.audience, title: "Audience", icon: "person.3.sequence.fill"),
        HubTab(id: Mode.scoring, title: "Scoring", icon: "flame.fill"),
        HubTab(id: Mode.plays, title: "Plays", icon: "scope"),
        HubTab(id: Mode.creators, title: "Creators", icon: "star.circle.fill"),
        HubTab(id: Mode.strategy, title: "Strategy", icon: "map.fill"),
        HubTab(id: Mode.search, title: "Search", icon: "magnifyingglass.circle.fill")
    ]

    init(initial: Mode = .audience) {
        _mode = State(initialValue: initial)
    }

    // Pinned header + tabs; children scroll themselves (see LeadsHubScreen for why no outer scroll).
    // Composite tabs stack their screens — each keeps its own independent scroll region.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Grow",
                             subtitle: "Audience building, scoring, ABM, creators, referrals, strategy, SEO, and AI citations are one growth workspace.")
                HubTabs(tabs: tabs, selection: $mode)
            }
            .padding(.horizontal, 26).padding(.top, 26)
            Group {
                switch mode {
                case .audience:
                    AudienceScreen()
                case .scoring:
                    LeadScoringScreen()
                case .plays:
                    VStack(spacing: 0) {
                        LookalikeScreen()
                        ABMScreen()
                    }
                case .creators:
                    VStack(spacing: 0) {
                        InfluencerScreen()
                        ReferralScreen()
                    }
                case .strategy:
                    VStack(spacing: 0) {
                        RoadmapScreen()
                        CMOAdvisorScreen()
                        BrandAuditScreen()
                    }
                case .search:
                    VStack(spacing: 0) {
                        SEOToolkitScreen()
                        AEOScreen()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct MeasureDashboardPanel: View {
    enum Mode: String, Hashable {
        case links, landing, attribution
    }

    @State private var mode: Mode = .links
    private let tabs = [
        HubTab(id: Mode.links, title: "Links", icon: "link"),
        HubTab(id: Mode.landing, title: "Landing A/B", icon: "rectangle.split.2x1.fill"),
        HubTab(id: Mode.attribution, title: "Attribution", icon: "arrow.triangle.merge")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("MEASURE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(1.2)
            HubTabs(tabs: tabs, selection: $mode)
            switch mode {
            case .links: LinksScreen()
            case .landing: LandingABScreen()
            case .attribution: AttributionScreen()
            }
        }
    }
}
#endif // circuit-convert
