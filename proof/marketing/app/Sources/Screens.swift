#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif
#if canImport(WebKit) && !CIRCUIT_WINDOWS_SIM
import WebKit
#endif

// MARK: - Shared layout helpers

struct ScreenHeader: View {
    let title: String; let subtitle: String
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    #endif
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Holographic foil headline driven by the live theme (gradient + sheen + glow).
            // Compact iPhone: the NavigationStack's inline bar already titles the screen, so the
            // 32pt headline would double every title — the subtitle carries the context instead.
            #if os(iOS)
            if hSize != .compact { FoilText(title, size: 32, weight: .medium, serif: true) }
            #else
            FoilText(title, size: 32, weight: .medium, serif: true)
            #endif
            Text(subtitle).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - WKWebView wrapper (live HTML preview)

#if os(macOS)
struct HTMLPreview: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.setValue(false, forKey: "drawsBackground")
        return v
    }
    func updateNSView(_ v: WKWebView, context: Context) {
        v.loadHTMLString(html, baseURL: nil)
    }
}
#else
// iOS: WKWebView via UIViewRepresentable. (iOS WKWebView has no `drawsBackground`; use
// isOpaque=false + a clear background so the holographic backdrop shows through.)
struct HTMLPreview: UIViewRepresentable {
    let html: String
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.isOpaque = false
        v.backgroundColor = .clear
        v.scrollView.backgroundColor = .clear
        return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {
        v.loadHTMLString(html, baseURL: nil)
    }
}
#endif

// MARK: - Dashboard

/// Real site traffic pulled from the buyer's OWN Cloudflare account (requests + Web Analytics page
/// views). Shows the last successful pull; when nothing is connected/pulled it stays an honest
/// "connect Cloudflare" empty state — never a fabricated number.
struct CloudflareTrafficPanel: View {
    var go: (Section) -> Void = { _ in }
    private var result: CFAnalyticsResult? {
        guard CloudflareAnalyticsConfig.isConfigured else { return nil }
        return CloudflareAnalyticsConfig.lastResult
    }

    var body: some View {
        Text("SITE TRAFFIC · CLOUDFLARE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(1.2)
        if let r = result, r.ok {
            Panel(title: "Cloudflare traffic", icon: "cloud.bolt.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(columns: blGridColumns(), spacing: 16) {
                        HeroStat(label: "HTTP Requests", value: r.requests.map { ConnectorsScreen.grouped($0) } ?? "—", icon: "arrow.left.arrow.right")
                        HeroStat(label: "Page Views", value: pageViews(r), icon: "eye.fill")
                    }
                    Text(caption(r)).font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Panel(title: "Cloudflare traffic", icon: "cloud.bolt.fill") {
                EmptyState(icon: "cloud.bolt",
                           title: "Connect Cloudflare to pull real traffic",
                           hint: "Add your Cloudflare API token, Account ID, and Zone in Connectors → Analytics, then hit Test / Refresh. Your real HTTP requests and page views appear here — pulled from your own account, never estimated.")
                Button { go(.connectors) } label: {
                    HStack(spacing: 6) { Image(systemName: "link"); Text("Open Connectors") }
                        .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                }.buttonStyle(.plain).padding(.top, 6)
            }
        }
    }

    private func pageViews(_ r: CFAnalyticsResult) -> String {
        switch r.pageViewsState {
        case .value: return r.pageViews.map { ConnectorsScreen.grouped($0) } ?? "—"
        case .noSiteTag, .notAvailable: return "—"
        }
    }
    private func caption(_ r: CFAnalyticsResult) -> String {
        let age = max(0, Date().timeIntervalSince(r.fetchedAt))
        let freshness = age > 86_400 ? "Cached result is over 24 hours old; refresh in Connectors." : "Verified \(r.fetchedAt.formatted(date: .abbreviated, time: .shortened))."
        var s = "\(r.rangeStart) → \(r.rangeEnd) · pulled from your own Cloudflare account. \(freshness)"
        switch r.pageViewsState {
        case .value: break
        case .noSiteTag: s += " Add your Web Analytics site tag in Connectors to include page views."
        case .notAvailable: s += " Enable Web Analytics for this site to include page views."
        }
        return s
    }
}

struct DashboardScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: Session
    @EnvironmentObject var prefs: Prefs
    // Setup-guide visibility survives creating a first item; only the buyer hiding it
    // (or finishing the trackable steps) retires it.
    @AppStorage("blm.onboarding.dismissed") private var onboardingDismissed = false
    var go: (Section) -> Void = { _ in }

    private var convRate: Double {
        let clicks = model.totalLoggedClicks
        return clicks > 0 ? Double(model.totalLoggedConversions) / Double(clicks) * 100 : 0
    }
    private var topLinks: [UTMLink] { model.links.filter { $0.clicks > 0 }.sorted { $0.clicks > $1.clicks }.prefix(5).map { $0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Studio Overview",
                             subtitle: session.email == "guest" ? "Signed in as Guest" : (session.email.isEmpty ? "Welcome back" : session.email))

                // Guided setup — stays visible until the buyer hides it or completes the
                // trackable steps, so making one caption doesn't vanish the guide mid-setup.
                if !onboardingDismissed && !(brandStepDone && createStepDone && clientsStepDone) {
                    OnboardingPanel(go: go, brandDone: brandStepDone, createDone: createStepDone,
                                    clientsDone: clientsStepDone) { onboardingDismissed = true }
                }

                // --- Real engagement analytics (from logged data only — never fabricated) ---
                Text("ENGAGEMENT").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(1.2)
                LazyVGrid(columns: blGridColumns(), spacing: 16) {
                    HeroStat(label: "Logged Clicks", value: "\(model.totalLoggedClicks)", icon: "cursorarrow.click.2")
                    HeroStat(label: "Conversions", value: "\(model.totalLoggedConversions)", icon: "checkmark.seal.fill")
                    HeroStat(label: "Conv. Rate", value: model.totalLoggedClicks > 0 ? String(format: "%.1f%%", convRate) : "—", icon: "percent")
                }

                if model.totalLoggedClicks > 0 {
                    Panel(title: "Top campaign links", icon: "chart.bar.fill") {
                        VStack(spacing: 10) {
                            let maxClicks = max(1, topLinks.map { $0.clicks }.max() ?? 1)
                            ForEach(topLinks) { l in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(l.label.isEmpty ? l.campaign : l.label).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                                        Spacer()
                                        Text("\(l.clicks) clicks · \(l.conversions) conv").font(BLFonts.mono(10.5, weight: .semibold)).foregroundColor(BLTheme.gold)
                                    }
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(BLTheme.bg2).frame(height: 7)
                                            Capsule().fill(BLTheme.goldGrad).frame(width: geo.size.width * CGFloat(l.clicks) / CGFloat(maxClicks), height: 7)
                                        }
                                    }.frame(height: 7)
                                }
                            }
                        }
                    }
                } else {
                    Panel(title: "Engagement", icon: "chart.bar.xaxis") {
                        EmptyState(icon: "chart.line.uptrend.xyaxis",
                                   title: "No engagement logged yet",
                                   hint: "Build campaign links, then log the real clicks and conversions you see in your own analytics. Numbers here are only ever what you record — never estimated.")
                    }
                }

                // --- Cloudflare site traffic (REAL pull from the buyer's own account, or honest-empty) ---
                CloudflareTrafficPanel(go: go)

                // --- Unified KPI rollup (paid + owned + earned — logged data only) ---
                KPIRollupView()

                // --- Measure moved onto Dashboard: links, landing A/B, and attribution. ---
                MeasureDashboardPanel()

                // --- Library counts (what the buyer has created) ---
                Text("YOUR LIBRARY").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(1.2)
                LazyVGrid(columns: blGridColumns(), spacing: 16) {
                    libStat("Reels", model.reels.count, "film.stack", .reels)
                    libStat("Sites", model.sites.count, "globe", .studio)
                    libStat("Captions", model.captions.count, "text.quote", .ideation)
                    libStat("Clients", model.clientLeads.count, "building.2", .leadsHub)
                    libStat("CRM Leads", model.leads.count, "person.2.fill", .leadsHub)
                    libStat("Segments", model.segments.count, "person.3.sequence.fill", .growHub)
                    libStat("Email Campaigns", model.campaigns.count, "envelope.badge.fill", .outreach)
                    libStat("Audits", model.audits.count, "checkmark.shield.fill", .growHub)
                    libStat("Scheduled", model.posts.count, "calendar.badge.clock", .pipeline)
                }
            }
            .padding(28)
        }
    }

    private var brandStepDone: Bool {
        !prefs.brandName.trimmingCharacters(in: .whitespaces).isEmpty || prefs.logoData != nil
    }
    private var createStepDone: Bool {
        !(model.reels.isEmpty && model.sites.isEmpty && model.captions.isEmpty)
    }
    private var clientsStepDone: Bool { !model.clientLeads.isEmpty || !model.leads.isEmpty }

    private func libStat(_ label: String, _ count: Int, _ icon: String, _ dest: Section) -> some View {
        Button { withAnimation { go(dest) } } label: {
            HeroStat(label: label, value: "\(count)", icon: icon)
        }.buttonStyle(.plain)
    }
}

/// Guided setup shown on the Dashboard until the buyer hides it or completes the steps.
struct OnboardingPanel: View {
    var go: (Section) -> Void
    var brandDone = false
    var createDone = false
    var clientsDone = false
    var dismiss: () -> Void = {}
    var body: some View {
        Panel(title: "Welcome — let's set up your studio", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Four quick steps to your first campaign. Everything runs on your own data and saves on this device.")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                step(1, done: brandDone, "Make it yours", "Add your brand, logo, and colors.", "paintbrush.pointed.fill") { go(.settings) }
                step(2, done: false, "Connect your accounts", "Mailboxes, socials, lead database, analytics — live status for each.", "link.circle.fill") { go(.connectors) }
                step(3, done: createDone, "Create something", "Generate a reel, a landing page, or captions.", "wand.and.stars") { go(.reels) }
                step(4, done: clientsDone, "Find clients & grow", "Pull real local businesses to pitch.", "building.2.fill") { go(.clients) }
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Text("Hide this guide").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    private func step(_ n: Int, done: Bool, _ t: String, _ d: String, _ icon: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Group {
                    if done {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy)).foregroundColor(BLTheme.inkOnGold)
                            .frame(width: 30, height: 30).background(BLTheme.green).clipShape(Circle())
                    } else {
                        Text("\(n)").font(BLFonts.mono(15, weight: .heavy)).foregroundColor(BLTheme.inkOnGold)
                            .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(Circle())
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(t).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(d).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                Image(systemName: icon).foregroundColor(BLTheme.gold).font(.system(size: 14, weight: .bold))
                Image(systemName: "chevron.right").foregroundColor(BLTheme.sub).font(.system(size: 11, weight: .bold))
            }
            .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

// MARK: - Find Clients (live business discovery by industry + market — businesses to pitch)
struct ClientsScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var vertical: MktVertical = .restaurant
    @State private var metro: MktMetro = MktMarkets.all.first!
    @State private var keyword = ""
    @State private var results: [BizResult] = []
    @State private var loading = false
    @State private var errorMsg = ""
    @State private var note = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Find Clients", subtitle: "Real local businesses by industry and market — the accounts you can pitch.")

                Panel(title: "Search by industry", icon: "building.2.fill") {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("INDUSTRY").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
                            Picker("", selection: $vertical) { ForEach(MktVertical.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("MARKET").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
                            Picker("", selection: $metro) { ForEach(MktMarkets.all) { Text($0.label).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Field(title: "Business name or keyword (optional)", text: $keyword, prompt: "e.g. Papa John's, pizza, boutique, crossfit", onSubmit: { if !loading { runSearch() } })
                    HStack(spacing: 10) {
                        GoldButton(label: loading ? "Searching…" : "Find businesses", icon: loading ? "hourglass" : "magnifyingglass") { runSearch() }
                            .opacity(loading ? 0.6 : 1).disabled(loading)
                        if !results.isEmpty {
                            Button { saveAll() } label: {
                                Label("Save all (\(results.count))", systemImage: "tray.and.arrow.down")
                                    .font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    Text("Live from OpenStreetMap open data — real businesses only, not invented. Saved clients feed your captions and content pipeline.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }

                if loading {
                    Panel(title: "Searching", icon: "hourglass") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Searching \(vertical.rawValue) in \(metro.label)…").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                            HoloSkeletonBlock(lines: 4)
                        }.padding(.vertical, 4)
                    }
                } else if !errorMsg.isEmpty {
                    Panel(title: "No results", icon: "exclamationmark.triangle") { EmptyState(icon: "exclamationmark.magnifyingglass", title: "Nothing came back", hint: errorMsg) }
                } else if !results.isEmpty {
                    Panel(title: "\(results.count) businesses · \(vertical.rawValue) · \(metro.label)", icon: "list.bullet.rectangle.fill") {
                        VStack(spacing: 8) { ForEach(results) { b in bizRow(b) } }
                    }
                } else if model.clientLeads.isEmpty {
                    Panel(title: "Results", icon: "building.2") {
                        EmptyState(icon: "building.2.crop.circle", title: "Pick an industry and a market", hint: "Choose a vertical and a city, then Find businesses to pull real local accounts you can pitch.")
                    }
                }

                if !note.isEmpty { Label(note, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green) }

                if !model.clientLeads.isEmpty {
                    Panel(title: "Saved clients (\(model.clientLeads.count))", icon: "person.2.fill") {
                        // Bounded window — an unbounded non-lazy ForEach over the lead pool froze
                        // the machine on the CRM tab (2026-07-07); never render the full pool.
                        VStack(spacing: 8) {
                            LazyVStack(spacing: 8) { ForEach(model.clientLeads.prefix(200)) { c in savedRow(c) } }
                            if model.clientLeads.count > 200 {
                                Text("Showing first 200 of \(model.clientLeads.count)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                                    .frame(maxWidth: .infinity).padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
            .padding(26)
        }
        .onAppear {
            // Apply the buyer's saved default vertical/market, if set.
            if let v = MktVertical.allCases.first(where: { $0.rawValue == prefs.defaultVertical }) { vertical = v }
            if let m = MktMarkets.all.first(where: { $0.label == prefs.defaultMarket }) { metro = m }
        }
    }

    @ViewBuilder private func bizRow(_ b: BizResult) -> some View {
        let saved = model.clientLeads.contains { $0.company.caseInsensitiveCompare(b.name) == .orderedSame && $0.domain == b.domain }
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "building.2.fill").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(b.name).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                HStack(spacing: 8) {
                    if !b.domain.isEmpty { Text(b.domain).font(BLFonts.mono(11, weight: .medium)).foregroundColor(BLTheme.gold) }
                    if !b.phone.isEmpty { Text(b.phone).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub) }
                    if !b.email.isEmpty { Label(b.email, systemImage: "envelope.fill").font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.green) }
                }
                if !b.address.isEmpty { Text(b.address).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1) }
            }
            Spacer()
            if saved { StatusPill(text: "Saved", tint: BLTheme.green) }
            else {
                Button { model.addClient(Lead(legacy: ClientLead(name: b.name, domain: b.domain, phone: b.phone, email: b.email, address: b.address, industry: b.industry))); withAnimation { note = "Saved \(b.name)." } } label: {
                    Label("Save", systemImage: "plus").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                }.buttonStyle(.plain)
            }
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func savedRow(_ c: Lead) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.displayName).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text([c.industry, c.domain, c.phone].filter { !$0.isEmpty }.joined(separator: " · ")).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
            Spacer()
            ConfirmDeleteButton(title: "Delete this client?",
                                message: "\(c.displayName) will be removed from your saved clients. This cannot be undone.",
                                tint: BLTheme.sub) {
                model.deleteClient(c)
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func runSearch() {
        errorMsg = ""; note = ""; loading = true; results = []
        let v = vertical, m = metro, k = keyword
        Task {
            do { let r = try await MktFinder.search(vertical: v, metro: m, keyword: k); await MainActor.run { results = r; loading = false } }
            catch { await MainActor.run { errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; loading = false } }
        }
    }
    private func saveAll() {
        var n = 0
        for b in results where !model.clientLeads.contains(where: { $0.company.caseInsensitiveCompare(b.name) == .orderedSame && $0.domain == b.domain }) {
            model.addClient(Lead(legacy: ClientLead(name: b.name, domain: b.domain, phone: b.phone, email: b.email, address: b.address, industry: b.industry))); n += 1
        }
        withAnimation { note = "Saved \(n) new businesses to clients." }
    }
}

// MARK: - Site Studio

struct SiteStudioScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var name = ""
    @State private var type = ""
    @State private var city = ""
    @State private var phone = ""
    @State private var template: SiteTemplate = .bold
    @State private var palette: SitePalette = .gold
    @State private var includeForm = true
    @State private var html = ""
    @State private var toast = ""
    @State private var isFunnel = false          // Landing page vs single-page funnel
    @State private var headline = ""             // optional editable hero headline
    @State private var subhead = ""              // optional editable subhead / prompt
    @State private var mobilePreview = false     // mobile vs desktop preview
    @State private var content = SiteContent()   // optional multi-section copy slots (honest-empty)
    @State private var deployURL = ""            // buyer's real site URL (sitemap only when set)

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Site Studio", subtitle: "Generate a responsive landing page with a lead-capture form.")
                    Panel(title: "Business details", icon: "building.2.fill") {
                        VStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("PAGE TYPE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                                Picker("", selection: $isFunnel) {
                                    Text("Landing page").tag(false); Text("Single-page funnel").tag(true)
                                }.labelsHidden().pickerStyle(.segmented).tint(BLTheme.gold)
                            }
                            Field(title: "Business name", text: $name, prompt: "Summit Plumbing Co.")
                            Field(title: "Business type", text: $type, prompt: "Plumbing")
                            Field(title: "City", text: $city, prompt: "Austin, TX")
                            Field(title: "Phone", text: $phone, prompt: "(512) 555-0142")
                            GoldButton(label: isFunnel ? "Generate funnel" : "Generate page", fill: true, icon: "wand.and.stars") { generate() }
                        }
                    }
                    Panel(title: "Copy (optional)", icon: "text.cursor") {
                        VStack(alignment: .leading, spacing: 10) {
                            Field(title: "Headline", text: $headline, prompt: "Leave blank for an auto headline")
                            VStack(alignment: .leading, spacing: 4) {
                                Text("PROMPT / SUBHEAD").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                                TextEditor(text: $subhead).frame(minHeight: 56)
                                    .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                                    .padding(6).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                                Text("Describe your offer in your words — it becomes the page subhead. Blank = an on-brand default.")
                                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            }
                        }
                    }
                    Panel(title: "Page order", icon: "arrow.up.arrow.down.square.fill") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Move the content bands below the fixed hero. Empty optional sections stay hidden but keep their position for when you add content.")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Array(content.orderedSections.enumerated()), id: \.element) { index, section in
                                HStack(spacing: 10) {
                                    Image(systemName: section.icon)
                                        .font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.gold)
                                        .frame(width: 18)
                                    Text(section.title)
                                        .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Spacer()
                                    Button(action: { moveSection(section, by: -1) }) {
                                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                                    }
                                    .buttonStyle(.plain).foregroundColor(BLTheme.text).disabled(index == 0)
                                    .accessibilityLabel("Move \(section.title) up")
                                    .accessibilityIdentifier("site.section.\(section.rawValue).move_up")
                                    Button(action: { moveSection(section, by: 1) }) {
                                        Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold))
                                    }
                                    .buttonStyle(.plain).foregroundColor(BLTheme.text)
                                    .disabled(index == content.orderedSections.count - 1)
                                    .accessibilityLabel("Move \(section.title) down")
                                    .accessibilityIdentifier("site.section.\(section.rawValue).move_down")
                                }
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                            }
                            Text(html.isEmpty ? "Generate once to start the live preview." : "Every move updates the live preview immediately.")
                                .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }
                    Panel(title: "Sections (optional)", icon: "square.stack.3d.up.fill") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Add real content and each section appears on your page. Leave a section empty and it's simply omitted — we never invent a review, a rating, or a stat.")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

                            contentField(label: "ABOUT", prompt: "Your story — one idea per line becomes a paragraph.", text: $content.about, tall: true)

                            // Stats (buyer's OWN real numbers)
                            listEditor(title: "STATS", note: "Your real numbers only (e.g. “15+” / “Years in business”).",
                                       count: content.stats.count, onAdd: { content.stats.append(SiteStat()) }) {
                                ForEach($content.stats) { $s in
                                    rowEditor(onDelete: { content.stats.removeAll { $0.id == s.id } }) {
                                        smallField("Value", $s.value); smallField("Label", $s.label)
                                    }
                                }
                            }
                            // Services / packages (custom override the auto trio) — P1-12: the "Services"
                            // section on the generated site. Each row is one offering (a service or a
                            // product package) shown as a card. Clearer copy so it doesn't read like a
                            // raw-HTML/embed field.
                            listEditor(title: "SERVICES / PACKAGES", note: "The offerings shown on your site's Services section — one card each (e.g. a service or a product package). Leave empty to use a sensible default set for your business type.",
                                       count: content.services.count, onAdd: { content.services.append(SiteService()) }) {
                                ForEach($content.services) { $s in
                                    rowEditor(onDelete: { content.services.removeAll { $0.id == s.id } }) {
                                        smallField("Name (e.g. service or package)", $s.title); smallField("Short description", $s.detail)
                                    }
                                }
                            }
                            // Testimonials (real, buyer-entered only — never fabricated)
                            listEditor(title: "TESTIMONIALS", note: "Real client quotes only. Empty = no reviews section.",
                                       count: content.testimonials.count, onAdd: { content.testimonials.append(Testimonial()) }) {
                                ForEach($content.testimonials) { $t in
                                    rowEditor(onDelete: { content.testimonials.removeAll { $0.id == t.id } }) {
                                        smallField("Quote", $t.quote); smallField("Author", $t.author)
                                    }
                                }
                            }
                            // FAQ
                            listEditor(title: "FAQ", note: "Common questions and answers.",
                                       count: content.faqs.count, onAdd: { content.faqs.append(FAQItem()) }) {
                                ForEach($content.faqs) { $f in
                                    rowEditor(onDelete: { content.faqs.removeAll { $0.id == f.id } }) {
                                        smallField("Question", $f.q); smallField("Answer", $f.a)
                                    }
                                }
                            }
                            // Tall: hours are naturally multi-line ("Mon–Fri 9–5\nSat 10–2") and the
                            // generator renders each line — a single-line field couldn't enter them.
                            contentField(label: "HOURS", prompt: "Mon–Fri 9–5…", text: $content.hours, tall: true)
                            HStack(spacing: 10) {
                                contentField(label: "SERVICE AREA", prompt: "Austin & nearby", text: $content.serviceArea, tall: false)
                                contentField(label: "PUBLIC EMAIL", prompt: "hi@yourbrand.com", text: $content.email, tall: false)
                            }
                        }
                    }
                    Panel(title: "Style", icon: "paintpalette.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("TEMPLATE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                                Picker("", selection: $template) { ForEach(SiteTemplate.allCases) { Text($0.rawValue).tag($0) } }
                                    .labelsHidden().pickerStyle(.segmented).tint(BLTheme.gold)
                                Text(template.blurb).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("PALETTE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                                Picker("", selection: $palette) { ForEach(SitePalette.allCases) { Text($0.rawValue).tag($0) } }
                                    .labelsHidden().tint(BLTheme.gold)
                            }
                            Toggle(isOn: $includeForm) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Lead-capture form").font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Text(prefs.formEndpoint.isEmpty && prefs.contactEmail.isEmpty
                                         ? "Set a form endpoint or contact email in Settings to enable."
                                         : "Posts to your endpoint / contact email (set in Settings).")
                                        .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                }
                            }.tint(BLTheme.gold)
                            .disabled(prefs.formEndpoint.isEmpty && prefs.contactEmail.isEmpty)
                            Text("Live preview updates when you regenerate. Pick once in Settings to set your default.")
                                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }
                    if !html.isEmpty {
                        Panel(title: "Save & export", icon: "square.and.arrow.down") {
                            VStack(spacing: 10) {
                                GoldButton(label: "Save project", fill: true, icon: "tray.and.arrow.down.fill") { save() }
                                GoldButton(label: "Export HTML…", fill: true, icon: "arrow.up.doc.fill") { export() }
                                #if os(macOS)
                                GoldButton(label: "Export deploy pack…", fill: true, icon: "shippingbox.fill") { exportDeployPack() }
                                GoldButton(label: "Export multi-page site…", fill: true, icon: "doc.on.doc.fill") { exportMultiPageSite() }
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("SITE URL (optional)").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                                    TextField("https://yourbusiness.com", text: $deployURL).textFieldStyle(.plain)
                                        .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                                        .padding(8).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                                    Text("Deploy pack = one-page site + robots.txt + a deploy guide. Multi-page site = linked index / services / about / contact pages from the same content. A sitemap.xml is added only when you set your real site URL.")
                                        .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                                }
                                #endif
                                if !toast.isEmpty {
                                    Text(toast).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green)
                                }
                            }
                        }
                    }
                    if !model.sites.isEmpty {
                        Panel(title: "Saved projects (\(model.sites.count))", icon: "globe") {
                            VStack(spacing: 8) {
                                ForEach(model.sites) { s in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(s.name.isEmpty ? "Untitled" : s.name).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                            Text(s.businessType + (s.city.isEmpty ? "" : " · " + s.city)).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                        }
                                        Spacer()
                                        IconButton(system: "eye") { loadSite(s) }
                                        IconButton(system: "trash", tint: BLTheme.danger) { model.deleteSite(s) }
                                    }
                                    .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .splitPaneWidth(min: 360, ideal: 420)

            VStack(spacing: 0) {
                if !html.isEmpty {
                    HStack(spacing: 8) {
                        Text(DemoMode.active ? "SAMPLE OUTPUT · GENERATED HTML" : "PREVIEW")
                            .font(BLFonts.mono(9, weight: .bold))
                            .foregroundColor(DemoMode.active ? BLTheme.gold : BLTheme.sub).tracking(0.6)
                        Spacer()
                        Picker("", selection: $mobilePreview) {
                            Image(systemName: "desktopcomputer").tag(false)
                            Image(systemName: "iphone").tag(true)
                        }.labelsHidden().pickerStyle(.segmented).frame(width: 96).tint(BLTheme.gold)
                    }.padding(10)
                }
                ZStack {
                    BLTheme.bg2.ignoresSafeArea()
                    if html.isEmpty {
                        EmptyState(icon: "globe.americas.fill",
                                   title: "Live preview appears here",
                                   hint: "Fill in the business details and \(AppBrand.tapVerb) Generate to see a polished, responsive page render in real time — toggle desktop / mobile.")
                    } else if mobilePreview {
                        // Mobile preview: constrain the responsive page to a phone width in a device
                        // frame. maxWidth, not width — a 375pt phone must not clip the frame edges.
                        HTMLPreview(html: html)
                            .frame(maxWidth: 390)
                            .frame(maxHeight: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(BLTheme.stroke, lineWidth: 6))
                            .padding(.vertical, 14)
                    } else {
                        HTMLPreview(html: html)
                    }
                }
            }
            .splitPaneWidth(min: 420)
        }
        .onAppear {
            template = prefs.siteTemplate; palette = prefs.sitePalette
            if type.isEmpty { type = prefs.defaultVertical }
            if city.isEmpty { city = prefs.defaultMarket }
            loadDemoSiteIfNeeded()
        }
    }

    /// Opens the real HTML generated into the isolated sample project, so demo mode proves the
    /// finished responsive page instead of stopping at a configuration form or empty preview.
    private func loadDemoSiteIfNeeded() {
        guard DemoMode.active, html.isEmpty, let sample = model.sites.first else { return }
        loadSite(sample)
        toast = "SAMPLE OUTPUT · Generated HTML loaded in the live preview."
    }

    private func loadSite(_ site: SiteProject) {
        html = site.html
        name = site.name
        type = site.businessType
        city = site.city
        phone = site.phone
        content = site.content
    }

    // MARK: content editor helpers

    @ViewBuilder private func contentField(label: String, prompt: String, text: Binding<String>, tall: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
            if tall {
                TextEditor(text: text).frame(minHeight: 60)
                    .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text).scrollContentBackground(.hidden)
                    .padding(6).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
            } else {
                TextField(prompt, text: text).textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                    .padding(8).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func smallField(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text).textFieldStyle(.plain)
            .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)
            .padding(7).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func rowEditor<C: View>(onDelete: @escaping () -> Void, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 6) {
            content()
            Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.danger) }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private func listEditor<Rows: View>(title: String, note: String, count: Int, onAdd: @escaping () -> Void,
                                                     @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                Spacer()
                Button(action: onAdd) { Label("Add", systemImage: "plus").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold) }.buttonStyle(.plain)
            }
            rows()
            if count == 0 { Text(note).font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub) }
        }
    }

    private func generate() {
        let useForm = includeForm && (!prefs.formEndpoint.isEmpty || !prefs.contactEmail.isEmpty)
        html = Studio.landingPage(name: name, type: type, city: city, phone: phone, template: template, palette: palette,
                                  formEndpoint: useForm ? prefs.formEndpoint : "",
                                  contactEmail: useForm ? prefs.contactEmail : "",
                                  headline: headline, subheadOverride: subhead, funnel: isFunnel, content: content)
        toast = ""
    }
    private func moveSection(_ section: SiteSection, by offset: Int) {
        var order = content.orderedSections
        guard let source = order.firstIndex(of: section) else { return }
        let destination = source + offset
        guard order.indices.contains(destination) else { return }
        let moved = order.remove(at: source)
        order.insert(moved, at: destination)
        content.sectionOrder = order
        if !html.isEmpty { generate() }
    }
    private func save() {
        guard !html.isEmpty else { return }
        model.upsert(SiteProject(name: name, businessType: type, city: city, phone: phone, html: html, content: content))
        flash("Project saved.")
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (name.isEmpty ? "landing-page" : name.replacingOccurrences(of: " ", with: "-").lowercased()) + ".html"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
                flash("Exported to \(url.lastPathComponent).")
            } catch {
                flash("Export failed: \(error.localizedDescription)")
            }
        }
    }
    #if os(macOS)
    /// Writes the full deploy pack (index.html + robots.txt + optional sitemap.xml + DEPLOY.md)
    /// into a folder the buyer picks — a complete, host-ready static site.
    private func exportDeployPack() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (name.isEmpty ? "site" : name.replacingOccurrences(of: " ", with: "-").lowercased()) + "-site"
        panel.canCreateDirectories = true
        panel.title = "Export deploy pack"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in SiteDeploy.pack(html: html, siteName: name, siteURL: deployURL) {
                try f.body.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8)
            }
            flash("Deploy pack exported to \(dir.lastPathComponent)/ — see DEPLOY.md inside.")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }

    /// Writes the multi-page site (index / services / about / contact — plus projects when the
    /// buyer picks real photos — + robots + optional sitemap + DEPLOY.md) into a folder the
    /// buyer picks. Photos are the buyer's OWN files, copied into images/; skipping the photo
    /// prompt simply omits the Projects page (honest empty state).
    private func exportMultiPageSite() {
        // Optional project photos first (Cancel = no gallery page).
        let photoPanel = NSOpenPanel()
        photoPanel.title = "Project photos (optional)"
        photoPanel.message = "Pick photos of YOUR real work for a Projects page — or Cancel to skip it."
        photoPanel.prompt = "Add Photos"
        photoPanel.allowedContentTypes = [.png, .jpeg, .heic, .webP]
        photoPanel.allowsMultipleSelection = true
        photoPanel.canChooseDirectories = false
        let photoURLs: [URL] = photoPanel.runModal() == .OK ? photoPanel.urls : []

        let panel = NSSavePanel()
        panel.nameFieldStringValue = (name.isEmpty ? "site" : name.replacingOccurrences(of: " ", with: "-").lowercased()) + "-site"
        panel.canCreateDirectories = true
        panel.title = "Export multi-page site"
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let useForm = includeForm && (!prefs.formEndpoint.isEmpty || !prefs.contactEmail.isEmpty)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Copy the buyer's photos into images/ with safe, deduped names.
            var galleryNames: [String] = []
            if !photoURLs.isEmpty {
                let imgDir = dir.appendingPathComponent("images")
                try FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
                for (i, src) in photoURLs.enumerated() {
                    let ext = src.pathExtension.isEmpty ? "jpg" : src.pathExtension.lowercased()
                    let stem = src.deletingPathExtension().lastPathComponent
                        .lowercased()
                        .map { $0.isLetter || $0.isNumber ? $0 : "-" }
                    let safe = String(stem).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
                    let fname = "\(safe.isEmpty ? "photo" : safe)-\(i + 1).\(ext)"
                    try FileManager.default.copyItem(at: src, to: imgDir.appendingPathComponent(fname))
                    galleryNames.append(fname)
                }
            }
            let files = SiteDeploy.multiPack(name: name, type: type, city: city, phone: phone,
                                             template: template, palette: palette,
                                             formEndpoint: useForm ? prefs.formEndpoint : "",
                                             contactEmail: useForm ? prefs.contactEmail : "",
                                             headline: headline, subhead: subhead, funnel: isFunnel,
                                             content: content, siteURL: deployURL,
                                             galleryImages: galleryNames)
            for f in files {
                try f.body.write(to: dir.appendingPathComponent(f.name), atomically: true, encoding: .utf8)
            }
            let pageCount = galleryNames.isEmpty ? 4 : 5
            flash("Multi-page site exported to \(dir.lastPathComponent)/ — \(pageCount) pages\(galleryNames.isEmpty ? "" : " incl. Projects (\(galleryNames.count) photos)") + DEPLOY.md.")
        } catch {
            flash("Export failed: \(error.localizedDescription)")
        }
    }
    #endif
    private func flash(_ m: String) {
        toast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if toast == m { toast = "" } }
    }
}

// MARK: - Captions

struct CaptionsScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var topic = ""
    @State private var tone: CaptionTone = .punchy
    @State private var generated: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Captions", subtitle: "Six ready-to-post marketing captions, in your brand voice.")
                Panel(title: "Generate", icon: "text.quote") {
                    VStack(spacing: 12) {
                        Field(title: "Topic", text: $topic, prompt: "Spring promo, new menu, grand opening…")
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("TONE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                                Picker("", selection: $tone) { ForEach(CaptionTone.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if !prefs.captionHashtag.trimmingCharacters(in: .whitespaces).isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("BRAND TAG").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                                    Text("#" + prefs.captionHashtag.replacingOccurrences(of: "#", with: "")).font(BLFonts.mono(12, weight: .semibold)).foregroundColor(BLTheme.gold)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        GoldButton(label: "Generate captions", fill: true, icon: "sparkles") {
                            generated = Studio.captions(for: topic, tone: tone, hashtag: prefs.captionHashtag)
                        }
                    }
                }
                if !generated.isEmpty {
                    Panel(title: "Suggestions", icon: "lightbulb.fill") {
                        VStack(spacing: 8) {
                            ForEach(Array(generated.enumerated()), id: \.offset) { _, c in
                                captionRow(c, topic: topic, saveable: true)
                            }
                        }
                    }
                }
                if !model.captions.isEmpty {
                    Panel(title: "Library (\(model.captions.count))", icon: "books.vertical.fill") {
                        VStack(spacing: 8) {
                            ForEach(model.captions) { c in
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(c.topic).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                                        Text(c.text).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                                    }
                                    Spacer()
                                    IconButton(system: "doc.on.doc") { copy(c.text) }
                                    IconButton(system: "trash", tint: BLTheme.danger) { model.deleteCaption(c) }
                                }
                                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .onAppear { tone = prefs.captionTone }
    }
    private func captionRow(_ text: String, topic: String, saveable: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            Spacer()
            IconButton(system: "doc.on.doc") { copy(text) }
            if saveable {
                IconButton(system: "plus.circle.fill", tint: BLTheme.green) {
                    model.addCaption(Caption(topic: topic.trimmingCharacters(in: .whitespaces).isEmpty ? "general" : topic, text: text))
                }
            }
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Links (UTM builder)

struct LinksScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var base = ""
    @State private var source = ""
    @State private var medium = ""
    @State private var campaign = ""
    @State private var built = ""
    @State private var err = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Links", subtitle: "Build tracking links (UTM tags) that show you which channel every visit came from.")
                Panel(title: "UTM builder", icon: "link.badge.plus") {
                    VStack(spacing: 12) {
                        Field(title: "Base URL", text: $base, prompt: "yourbusiness.com/promo")
                        Field(title: "Source (utm_source)", text: $source, prompt: "instagram")
                        Field(title: "Medium (utm_medium)", text: $medium, prompt: "social")
                        Field(title: "Campaign (utm_campaign)", text: $campaign, prompt: "spring_sale")
                        GoldButton(label: "Build link", fill: true, icon: "hammer.fill") { build() }
                        if !err.isEmpty { Text(err).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(Color(hex: 0xFF6B6B)) }
                    }
                }
                if !built.isEmpty {
                    Panel(title: "Result", icon: "checkmark.circle.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(built).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundColor(BLTheme.text).textSelection(.enabled)
                            HStack {
                                GoldButton(label: "Copy", icon: "doc.on.doc") { copy(built) }
                                GoldButton(label: "Save link", icon: "tray.and.arrow.down.fill") { saveLink() }
                            }
                        }
                    }
                }
                if !model.links.isEmpty {
                    Panel(title: "Saved links (\(model.links.count))", icon: "list.bullet.rectangle.fill") {
                        VStack(spacing: 8) {
                            Text("Log the real clicks & conversions you see in your own analytics. These feed the Dashboard — never estimated or auto-filled.")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                            ForEach(model.links) { l in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .top, spacing: 8) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(l.label).font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                                            Text(l.url).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundColor(BLTheme.text).textSelection(.enabled)
                                        }
                                        Spacer()
                                        IconButton(system: "doc.on.doc") { copy(l.url) }
                                        IconButton(system: "trash", tint: BLTheme.danger) { model.deleteLink(l) }
                                    }
                                    HStack(spacing: 14) {
                                        counter(label: "Clicks", value: l.clicks, tint: BLTheme.gold,
                                                dec: { model.logClicks(l, add: -1) }, inc: { model.logClicks(l, add: 1) })
                                        counter(label: "Conversions", value: l.conversions, tint: BLTheme.green,
                                                dec: { model.logConversions(l, add: -1) }, inc: { model.logConversions(l, add: 1) })
                                        Spacer()
                                    }
                                }
                                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
    }
    private func build() {
        err = ""
        guard let url = Studio.buildUTM(base: base, source: source, medium: medium, campaign: campaign) else {
            err = "Enter a valid base URL (e.g. yourbusiness.com/promo)."; built = ""; return
        }
        built = url
    }
    private func saveLink() {
        guard !built.isEmpty else { return }
        let label = campaign.trimmingCharacters(in: .whitespaces).isEmpty ? "Campaign link" : campaign
        model.addLink(UTMLink(label: label, url: built, source: source, medium: medium, campaign: campaign))
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }
    @ViewBuilder private func counter(label: String, value: Int, tint: Color, dec: @escaping () -> Void, inc: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
            Button(action: dec) { Image(systemName: "minus.circle.fill").foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
            Text("\(value)").font(BLFonts.mono(13, weight: .heavy)).foregroundColor(tint).frame(minWidth: 24)
            Button(action: inc) { Image(systemName: "plus.circle.fill").foregroundColor(tint) }.buttonStyle(.plain)
        }
    }
}

// MARK: - Email Spotlight engine (REAL end-to-end: composes a pitch and hands it
// to the buyer's own mail client via mailto. We log only "Composed" — never a
// fabricated "Delivered" — so the record is always honest.)

struct SpotlightPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @Binding var spotlightToast: String
    @State private var selected: ClientLead.ID?
    @State private var previewSubject = ""
    @State private var previewBody = ""

    private var emailableClients: [Lead] { model.clientLeads }

    var body: some View {
        Panel(title: "Email spotlight", icon: "envelope.badge.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    FoilBadge(text: "LIVE", icon: "checkmark.seal.fill")
                    Text("Pitch a saved client from \(senderLabel) — opens in your mail app, ready to send.")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.clientLeads.isEmpty {
                    EmptyState(icon: "person.crop.circle.badge.questionmark",
                               title: "No clients yet",
                               hint: "Find and save businesses in Find Clients, then spotlight them here with a one-\(AppBrand.tapVerb) email pitch.")
                } else {
                    if prefs.senderName.trimmingCharacters(in: .whitespaces).isEmpty && prefs.brandName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Label("Set your name and brand in Settings so pitches sign off correctly.", systemImage: "exclamationmark.circle.fill")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                    }
                    // Bounded window — same machine-freeze class as the CRM tab (2026-07-07).
                    LazyVStack(spacing: 8) {
                        ForEach(model.clientLeads.prefix(200)) { c in clientRow(c) }
                    }
                    if model.clientLeads.count > 200 {
                        Text("Showing first 200 of \(model.clientLeads.count)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    if !previewSubject.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PREVIEW").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                            Text(previewSubject).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                            Text(previewBody).font(.system(size: 12, weight: .regular, design: .rounded)).foregroundColor(BLTheme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                    if !spotlightToast.isEmpty {
                        Label(spotlightToast, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                    }
                }

                if !model.spotlights.isEmpty {
                    Divider().background(BLTheme.stroke)
                    Text("SPOTLIGHT LOG (\(model.spotlights.count))").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                    VStack(spacing: 6) {
                        ForEach(model.spotlights) { s in
                            HStack(spacing: 8) {
                                StatusPill(text: s.status, tint: BLTheme.gold)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.client).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Text(s.subject).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                                }
                                Spacer()
                                Text(s.created.formatted(date: .abbreviated, time: .shortened)).font(BLFonts.mono(9.5)).foregroundColor(BLTheme.sub)
                                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteSpotlight(s) }
                            }
                            .padding(.vertical, 7).padding(.horizontal, 10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }
        }
    }

    private var senderLabel: String {
        let b = prefs.displayBrand
        return b
    }

    @ViewBuilder private func clientRow(_ c: Lead) -> some View {
        let hasEmail = !c.email.trimmingCharacters(in: .whitespaces).isEmpty
        HStack(spacing: 10) {
            Image(systemName: "building.2.fill").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                .frame(width: 28, height: 28).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 1) {
                Text(c.displayName).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(hasEmail ? c.email : (c.industry.isEmpty ? "No email on file — preview only" : "\(c.industry) · no email on file"))
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(hasEmail ? BLTheme.gold : BLTheme.sub).lineLimit(1)
            }
            Spacer()
            GhostButton(label: "Preview", icon: "eye") { preview(c) }
            GoldButton(label: hasEmail ? "Compose" : "Compose (no email)", icon: "paperplane.fill") { compose(c) }
                .opacity(hasEmail ? 1 : 0.85)
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func mail(for c: Lead) -> (String, String) {
        Studio.spotlightEmail(client: c, sender: (name: prefs.senderName, brand: prefs.displayBrand, tagline: prefs.tagline, email: prefs.senderEmail))
    }
    private func preview(_ c: Lead) {
        let m = mail(for: c); previewSubject = m.0; previewBody = m.1; spotlightToast = ""
    }
    private func compose(_ c: Lead) {
        let m = mail(for: c)
        previewSubject = m.0; previewBody = m.1
        let to = c.email.trimmingCharacters(in: .whitespaces)
        if let url = Studio.mailtoURL(to: to, subject: m.0, body: m.1) {
            let opened = DemoMode.openExternal(url, simulatedNote: "Demo: this would open your mail app with a ready-to-send pitch for \(c.displayName).")
            model.logSpotlight(SpotlightRecord(client: c.displayName, subject: m.0, to: to, status: to.isEmpty ? "Drafted" : "Composed"))
            withAnimation { spotlightToast = !opened
                ? "Demo — the pitch for \(c.name) is composed below (no email is actually sent)."
                : (to.isEmpty
                    ? "Opened a draft in your mail app — add the recipient and send."
                    : "Opened in your mail app for \(c.name) — review and send.") }
        }
    }
}

// MARK: - Content Pipeline (spotlight + draft → schedule)

struct PipelineScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var business = ""
    @State private var topic = ""
    @State private var channel = MarketingChannel.instagram.rawValue
    @State private var draft = ""
    @State private var date = Date()
    @State private var toast = ""
    @State private var spotlightToast = ""
    @State private var packURL = ""
    @State private var campaignPack: CampaignPack?
    @State private var packToast = ""
    @State private var publishing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Content Pipeline",
                             subtitle: "Send client spotlights now; draft and schedule social posts.")

                // --- WORKING end-to-end: email spotlights via the buyer's own mail client ---
                SpotlightPanel(spotlightToast: $spotlightToast)

                Panel(title: "Client campaign pack", icon: "shippingbox.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            FoilBadge(text: "HANDOFF", icon: "doc.badge.gearshape.fill")
                            Text("Landing page, captions, email, SMS, schema, UTM link, and launch checklist.")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Field(title: "Campaign URL (optional)", text: $packURL, prompt: "yourbusiness.com/spring")
                        GoldButton(label: "Build client pack", fill: true, icon: "shippingbox.fill") { buildPack() }
                        if let pack = campaignPack {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(pack.title)
                                            .font(.system(size: 14, weight: .bold, design: .rounded))
                                            .foregroundColor(BLTheme.text)
                                        Text([pack.channel, pack.utmURL.isEmpty ? "No URL yet" : "Tracked URL ready"].joined(separator: " · "))
                                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                            .foregroundColor(BLTheme.sub)
                                    }
                                    Spacer()
                                    StatusPill(text: "\(pack.captions.count) captions", tint: BLTheme.gold)
                                }
                                Text(pack.socialPost)
                                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.text)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(10)
                                    .background(BLTheme.bg2)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                                HStack {
                                    GoldButton(label: "Copy handoff", icon: "doc.on.doc") { copy(pack.markdown); flashPack("Copied client pack.") }
                                    GoldButton(label: "Export .md", icon: "square.and.arrow.up") { exportPack(pack) }
                                }
                                if !packToast.isEmpty {
                                    Text(packToast)
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundColor(BLTheme.green)
                                }
                            }
                        }
                    }
                }

	                Panel(title: "Social channels", icon: "antenna.radiowaves.left.and.right") {
	                    VStack(alignment: .leading, spacing: 10) {
	                        LazyVGrid(columns: blGridColumns(), spacing: 10) {
	                            ForEach(MarketingChannel.allCases) { ch in
	                                let readiness = publishReadiness(ch.rawValue)
	                                HStack(spacing: 8) {
	                                    Image(systemName: ch.icon).font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold)
	                                    VStack(alignment: .leading, spacing: 3) {
	                                        Text(ch.rawValue).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
	                                        Text(readiness.detail).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
	                                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
	                                    }
	                                    Spacer()
	                                    StatusPill(text: readiness.badge, tint: readiness.tint)
	                                }
	                                .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
	                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                            }
                        }
                    }
                }

                Panel(title: "Draft a post", icon: "square.and.pencil") {
                    VStack(spacing: 12) {
                        Field(title: "Business / operator", text: $business, prompt: "Summit Plumbing Co.")
                        Field(title: "Topic", text: $topic, prompt: "Spring promo, new menu, grand opening…")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("INTENDED CHANNEL").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
                            Picker("", selection: $channel) {
                                ForEach(MarketingChannel.allCases) { Text($0.rawValue).tag($0.rawValue) }
                            }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                        }
                        GoldButton(label: "Draft post", fill: true, icon: "wand.and.stars") {
                            draft = Studio.draftPost(business: business, topic: topic, channel: channel, hashtag: prefs.captionHashtag)
                        }
                    }
                }

                if !draft.isEmpty {
                    Panel(title: "Draft & schedule", icon: "calendar.badge.plus") {
                        VStack(alignment: .leading, spacing: 12) {
	                            TextEditor(text: $draft)
	                                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
	                                .scrollContentBackground(.hidden).frame(minHeight: 110)
	                                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
	                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
	                            publishStatus(publishReadiness(channel))
	                            HStack {
	                                if canDirectPublish(channel) {
	                                    GoldButton(label: publishing ? "Publishing…" : "Publish now", icon: "paperplane.fill") {
	                                        publishNow(body: draft, channel: channel)
	                                    }
	                                    .disabled(publishing)
	                                    GhostButton(label: "Copy + open", icon: "arrow.up.forward.app") {
	                                        copyAndOpenForPublishing(body: draft, channel: channel)
	                                    }
	                                } else {
	                                    GoldButton(label: publishReadiness(channel).actionTitle, icon: "paperplane.fill") {
	                                        copyAndOpenForPublishing(body: draft, channel: channel)
	                                    }
	                                }
	                                GhostButton(label: "Copy only", icon: "doc.on.doc") {
	                                    copy(draft); flash("Post copied.")
	                                }
	                            }
	                            DatePicker("Schedule for", selection: $date)
	                                .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).tint(BLTheme.gold)
	                            GoldButton(label: "Schedule post", fill: true, icon: "tray.and.arrow.down.fill") { schedulePost() }
                            if !toast.isEmpty {
                                Text(toast).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green)
                            }
                        }
                    }
                }

                if !model.posts.isEmpty {
                    Panel(title: "Scheduled (\(model.posts.count))", icon: "calendar") {
	                        VStack(spacing: 8) {
	                            ForEach(model.posts) { p in
	                                let readiness = publishReadiness(p.channel)
	                                HStack(alignment: .top, spacing: 8) {
	                                    VStack(alignment: .leading, spacing: 4) {
	                                        HStack(spacing: 6) {
	                                            Text(p.channel).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
	                                            StatusPill(text: "Scheduled", tint: BLTheme.gold)
	                                            StatusPill(text: readiness.badge, tint: readiness.tint)
	                                        }
	                                        Text(p.body).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
	                                        Text(p.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
	                                    }
	                                    Spacer()
	                                    IconButton(system: "paperplane.fill") { copyAndOpenForPublishing(body: p.body, channel: p.channel) }
	                                    IconButton(system: "doc.on.doc") { copy(p.body) }
	                                    IconButton(system: "trash", tint: BLTheme.danger) { model.deletePost(p) }
	                                }
                                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
	        .onAppear {
	            model.refreshSocialCredentialFlags()
	            if business.isEmpty { business = prefs.displayBrand }
	            if topic.isEmpty { topic = "First campaign" }
	        }
	    }
	    @ViewBuilder private func publishStatus(_ readiness: SocialPublishReadiness) -> some View {
	        HStack(alignment: .top, spacing: 9) {
	            StatusPill(text: readiness.badge, tint: readiness.tint)
	            Text(readiness.detail)
	                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
	                .foregroundColor(BLTheme.sub)
	                .fixedSize(horizontal: false, vertical: true)
	            Spacer(minLength: 0)
	        }
	        .padding(10)
	        .background(BLTheme.bg2)
	        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
	        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
	    }
	    private func publishReadiness(_ channel: String) -> SocialPublishReadiness {
	        SocialPublisher.readiness(channel: channel, profiles: model.socialProfiles)
	    }
	    private func buildPack() {
        let packBusiness = business.trimmingCharacters(in: .whitespaces).isEmpty ? prefs.displayBrand : business
        let packTopic = topic.trimmingCharacters(in: .whitespaces).isEmpty ? "First campaign" : topic
        campaignPack = Studio.campaignPack(business: packBusiness,
                                           type: prefs.defaultVertical,
                                           city: prefs.defaultMarket,
                                           phone: "",
                                           topic: packTopic,
                                           channel: channel,
                                           senderName: prefs.senderName,
                                           senderBrand: prefs.displayBrand,
                                           tagline: prefs.tagline,
                                           senderEmail: prefs.senderEmail,
                                           baseURL: packURL,
                                           formEndpoint: prefs.formEndpoint,
                                           contactEmail: prefs.contactEmail,
                                           template: prefs.siteTemplate,
                                           palette: prefs.sitePalette,
                                           tone: prefs.captionTone,
                                           hashtag: prefs.captionHashtag)
        flashPack("Client pack built.")
    }
    private func schedulePost() {
        guard !draft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let title = topic.trimmingCharacters(in: .whitespaces).isEmpty ? "Post" : topic
	        model.schedule(ScheduledPost(title: title, body: draft, channel: channel, scheduledAt: date))
	        flash("Scheduled for \(date.formatted(date: .abbreviated, time: .shortened)). Publish status: \(publishReadiness(channel).badge).")
	    }
	    /// True only when a stored API credential is NOT known to be dead AND the network can publish a
	    /// text post directly through its API (X / LinkedIn / Facebook / Threads). Media-only networks
	    /// (Instagram / YouTube / TikTok) keep the copy-and-open / Reel Relay path — honest, not fake.
	    ///
	    /// `hasUsableCredential` covers `.credentialStored` (expiry verified ahead of now) and
	    /// `.credentialExpiryUnknown` (nothing recorded — the provider stays the authority), and
	    /// excludes `.credentialExpired`, which previously slipped through as "credential stored" and
	    /// let a schedule be accepted against a dead token.
	    private func canDirectPublish(_ channel: String) -> Bool {
	        guard let platform = SocialPublisher.platform(for: channel),
	              publishReadiness(channel).state.hasUsableCredential else { return false }
	        return SocialPublishCapability.supportsTextPost(platform)
	    }
	    /// Fire the REAL posting client with the buyer's own stored token and surface the true result.
	    private func publishNow(body: String, channel: String) {
	        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
	        guard !text.isEmpty else { flash("Nothing to publish — write a post first."); return }
	        guard let platform = SocialPublisher.platform(for: channel) else { copyAndOpenForPublishing(body: body, channel: channel); return }
	        guard let token = SocialCredentialStore.token(for: platform), !token.isEmpty else {
	            flash("Connect \(channel) with a stored credential before publishing."); return
	        }
	        publishing = true
	        flash("Publishing to \(channel)…")
	        Task {
	            let result = await SocialPublishService().publish(SocialPost(text: text),
	                                                              to: platform,
	                                                              account: SocialAccount(accessToken: token))
	            await MainActor.run {
	                publishing = false
	                switch result {
	                case .success(let r):
	                    flash("Published to \(channel). Post id \(r.id).")
	                case .failure(let e):
	                    flash(e.errorDescription ?? "Publish failed.")
	                }
	            }
	        }
	    }
	    private func copyAndOpenForPublishing(body: String, channel: String) {
	        copy(body)
	        let readiness = publishReadiness(channel)
	        guard let urlString = readiness.profileURL, let url = URL(string: urlString) else {
	            flash("Post copied. Link \(channel) in Social Profiles before opening the publish path.")
	            return
	        }
	        let opened = DemoMode.openExternal(url, simulatedNote: "Demo: this would open \(channel) so you can publish the copied post.")
	        flash(opened ? "Post copied and \(channel) opened." : "Demo — post copied; \(channel) profile would open here.")
	    }
    private func flash(_ m: String) {
        toast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if toast == m { toast = "" } }
    }
    private func copy(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
    }
    private func exportPack(_ pack: CampaignPack) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = pack.title.replacingOccurrences(of: " ", with: "-").lowercased() + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            try? pack.markdown.write(to: url, atomically: true, encoding: .utf8)
            flashPack("Exported \(url.lastPathComponent).")
        }
    }
    private func flashPack(_ m: String) {
        packToast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if packToast == m { packToast = "" } }
    }
}

// MARK: - Settings (account + deletion)

struct SettingsScreen: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    /// Needed by account deletion: the connected mailboxes + CRM account whose provider tokens
    /// must also be destroyed (they live in the lead-engine settings, not the workspace).
    @EnvironmentObject var leadEngine: LeadEngineStore
    @Environment(\.openURL) private var openURL
    @State private var confirmDelete = false
    /// Account deletion runs server-side deletions first, so it is asynchronous and reports back.
    @State private var deleting = false
    @State private var deletionReceipts: [AccountDeletionReceipt] = []
    @State private var deletionSummary = ""
    @State private var newProfileName = ""
    @State private var saved = ""
    @State private var workspaceError = ""
    @State private var workspaceStatus = ""
    // Support & diagnostics (DOD-7.6/11.5): outcome of the last export/copy action.
    @State private var diagStatus = ""
    @State private var diagError = ""
    // iOS logo import: NSOpenPanel can't run synchronously on a phone, so iOS uses a SwiftUI
    // `.fileImporter` (UIDocumentPicker) toggled by this flag (see `pickLogo()` + the modifier below).
    @State private var showLogoImporter = false
    @State private var showWorkspaceImporter = false
    // Buyer's own Google OAuth client ID (enables the Google sign-in button). Persisted to
    // UserDefaults so the option is never silently unavailable — set it here, then sign out.
    @State private var googleClientID = UserDefaults.standard.string(forKey: GoogleAuth.clientIDDefaultsKey) ?? ""
    // Buyer's own Lead Database subscription key. Empty = masked preview tier; a valid Bearer key
    // unlocks full contacts + one-tap "Add as recipient" in the Lead Database screen. Persisted to
    // LeadDBCredential (data-protection Keychain) — the exact store LeadDBStore reads.
    @State private var leadDBToken = LeadDBCredential.token
    @State private var leadDBValidation: LeadDBTokenValidation? = nil
    @State private var leadDBTesting = false
    // Brand profiler (point the engine at the buyer's own site → name/tagline/colors).
    @State private var brandSite = ""
    @State private var profiling = false
    @State private var profileNote = ""
    // P1-5: manual hex entry for the brand color (the tester couldn't reach #C20017 via the picker).
    @State private var hexInput = ""
    // P1-9: transient "Saved" confirmation driven by prefs autosave (edits persist silently otherwise).
    @State private var autoSavedFlash = false
    // P1-7: one-time first-run intro on the "Make it yours" page.
    @AppStorage("blm.seenMakeItYours") private var seenMakeItYours = false
    // P1-6: after a successful site pull, show what was applied + mark manual steps optional.
    @State private var siteApplied = false
    // New sender identity inputs.
    @State private var newSenderName = ""
    @State private var newSenderEmail = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Settings", subtitle: "Make it yours — brand, defaults, and identity. Everything saves on this device.")

                // P1-7: intentional first-run intro instead of silently dropping the buyer here.
                if !seenMakeItYours {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "sparkles").font(.system(size: 18, weight: .bold)).foregroundColor(BLTheme.gold)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Let's make it yours").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Text("This is where you set your brand identity — your logo, name, colors, and voice. Everything you enter is saved on THIS device and flows into every site, reel, caption, and email you generate. You can change any of it anytime. Fastest start: paste your website below and \(AppBrand.tapVerb) Profile to pull your name and colors automatically.")
                                .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                            GhostButton(label: "Got it", icon: "checkmark") { seenMakeItYours = true }
                        }
                        Spacer()
                    }
                    .padding(14).background(BLTheme.gold.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.gold.opacity(0.35), lineWidth: 1))
                }

                // --- Brand identity ---
                Panel(title: "Brand identity", icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 14) {
                            BrandMark(size: 56)
                            VStack(alignment: .leading, spacing: 8) {
                                GhostButton(label: prefs.logoData == nil ? "Choose logo…" : "Replace logo…", icon: "photo") { pickLogo() }
                                if prefs.logoData != nil { GhostButton(label: "Remove logo", icon: "trash", tint: BLTheme.danger) { prefs.logoData = nil } }
                            }
                            Spacer()
                        }
                        Field(title: "Brand name", text: $prefs.brandName, prompt: "e.g. Pixel Studio")
                        Field(title: "Tagline", text: $prefs.tagline, prompt: "e.g. we make local brands shine")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("ACCENT").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                            HStack(spacing: 10) {
                                ForEach(AccentChoice.allCases) { a in
                                    Button { prefs.accent = a } label: {
                                        Circle().fill(a.color).frame(width: 26, height: 26)
                                            .overlay(Circle().stroke(Color.white.opacity(prefs.accent == a ? 0.9 : 0.2), lineWidth: prefs.accent == a ? 2 : 1))
                                            .shadow(color: a.color.opacity(0.5), radius: prefs.accent == a ? 8 : 0)
                                    }.buttonStyle(.plain).help(a.rawValue)
                                }
                                Spacer()
                            }
                            Text("Accent recolors the whole app instantly.").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        }

                        // Custom brand color (overrides the presets above) — the "custom colors" claim.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("CUSTOM COLOR").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                            Text("Pick a color, or type an exact brand hex like #C20017.")
                                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            HStack(spacing: 10) {
                                ColorPicker("", selection: customColorBinding, supportsOpacity: false).labelsHidden()
                                // Manual hex entry — type or paste an exact brand color like #C20017.
                                HStack(spacing: 4) {
                                    Text("#").font(BLFonts.mono(12, weight: .bold)).foregroundColor(BLTheme.sub)
                                    TextField("C20017", text: $hexInput)
                                        .textFieldStyle(.plain)
                                        .font(BLFonts.mono(12, weight: .semibold))
                                        .foregroundColor(BLTheme.text)
                                        .frame(width: 74)
                                        .onChange(of: hexInput) { newValue in
                                            if let v = Self.parseHex(newValue) { prefs.customAccentHex = v }
                                        }
                                        .onSubmit {
                                            if let v = Self.parseHex(hexInput) { prefs.customAccentHex = v }
                                        }
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(BLTheme.stroke, lineWidth: 1))
                                if prefs.customAccentHex != 0 {
                                    GhostButton(label: "Use preset", icon: "arrow.uturn.backward") { prefs.customAccentHex = 0; hexInput = "" }
                                }
                                Spacer()
                            }
                            if !prefs.brandColors.isEmpty {
                                Text("EXTRACTED FROM YOUR BRAND").font(BLFonts.mono(8.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                                HStack(spacing: 8) {
                                    ForEach(prefs.brandColors, id: \.self) { hex in
                                        Button { prefs.customAccentHex = hex } label: {
                                            RoundedRectangle(cornerRadius: 6).fill(Color(hex: hex)).frame(width: 30, height: 22)
                                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.25), lineWidth: 1))
                                        }.buttonStyle(.plain).help(String(format: "#%06X", hex))
                                    }
                                    Spacer()
                                }
                            }
                        }
                        .onAppear { if prefs.customAccentHex != 0, hexInput.isEmpty { hexInput = String(format: "%06X", prefs.customAccentHex) } }

                        // Auto-profile from the buyer's own website.
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PROFILE FROM YOUR SITE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                            HStack(spacing: 8) {
                                Field(title: "", text: $brandSite, prompt: "yourbrand.com")
                                GoldButton(label: profiling ? "Reading…" : "Profile", icon: "wand.and.stars") { profileFromSite() }
                                    .opacity(profiling ? 0.6 : 1).disabled(profiling)
                            }
                            if !profileNote.isEmpty {
                                Text(profileNote).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(profileNote.hasPrefix("✓") ? BLTheme.green : BLTheme.gold).fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Reads your public site for name, tagline, and colors. Your logo's colors are extracted automatically when you choose one. Nothing is sent anywhere.")
                                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

                            // P1-6: after a successful pull, confirm exactly what was applied and mark the
                            // manual brand-identity steps as satisfied/optional.
                            if siteApplied {
                                VStack(alignment: .leading, spacing: 7) {
                                    Label("Applied to your brand identity", systemImage: "checkmark.seal.fill")
                                        .font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                                    HStack(spacing: 10) {
                                        if let logo = prefs.logoImage {
                                            Image(nsImage: logo).resizable().scaledToFit().frame(width: 34, height: 34)
                                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                                .overlay(RoundedRectangle(cornerRadius: 7).stroke(BLTheme.stroke, lineWidth: 1))
                                        }
                                        if !prefs.brandName.isEmpty {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(prefs.brandName).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                                                if !prefs.tagline.isEmpty { Text(prefs.tagline).font(.system(size: 9.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1) }
                                            }
                                        }
                                        Spacer()
                                        ForEach(prefs.brandColors.prefix(5), id: \.self) { hex in
                                            RoundedRectangle(cornerRadius: 5).fill(Color(hex: hex)).frame(width: 22, height: 22)
                                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(0.25), lineWidth: 1))
                                        }
                                    }
                                    Text("The manual brand name, color, and logo steps above are now optional — they've been set from your site. Adjust any of them if you want.")
                                        .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(11).background(BLTheme.green.opacity(0.07)).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.green.opacity(0.3), lineWidth: 1))
                            }
                        }
                    }
                }

                // --- Brand kit (MK-16: import from the buyer's own domain) ---
                Panel(title: "Brand kit", icon: "square.grid.2x2") {
                    BrandKitImportControl()
                }

                // --- Senders & deliverability ---
                Panel(title: "Senders & deliverability", icon: "paperplane.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("DISTINCT SENDERS").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                        ForEach(model.senders) { s in
                            HStack {
                                Text(s.label).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                Spacer()
                                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteSender(s) }
                            }
                        }
                        HStack(spacing: 8) {
                            Field(title: "", text: $newSenderName, prompt: "Name")
                            Field(title: "", text: $newSenderEmail, prompt: "you@brand.com")
                            GhostButton(label: "Add", icon: "plus") {
                                let e = newSenderEmail.trimmingCharacters(in: .whitespaces)
                                guard EmailValidator.isValid(e) else { flash("Enter a valid sender email."); return }
                                model.addSender(SenderIdentity(name: newSenderName.trimmingCharacters(in: .whitespaces), email: e))
                                newSenderName = ""; newSenderEmail = ""
                            }
                        }
                        Divider().background(BLTheme.stroke)
                        Text("WARMUP PACING").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                        Toggle(isOn: $prefs.warmup.enabled) { Text("Ramp daily send volume").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text) }.tint(BLTheme.gold)
                        if prefs.warmup.enabled {
                            Stepper("Start: \(prefs.warmup.startCap)/day", value: $prefs.warmup.startCap, in: 5...200, step: 5).font(.system(size: 12, design: .rounded))
                            Stepper("Increase: +\(prefs.warmup.dailyIncrease)/day", value: $prefs.warmup.dailyIncrease, in: 0...100, step: 5).font(.system(size: 12, design: .rounded))
                            Stepper("Ceiling: \(prefs.warmup.maxCap)/day", value: $prefs.warmup.maxCap, in: 20...2000, step: 20).font(.system(size: 12, design: .rounded))
                        }
                        Text("Warmup caps how many journey/newsletter emails queue per day to protect deliverability. Sends go from your own mailbox; addresses are validated and de-duplicated (clean lists).")
                            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                }

                // --- Content defaults ---
                Panel(title: "Content defaults", icon: "slider.horizontal.3") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            picker("DEFAULT INDUSTRY", sel: Binding(
                                get: { prefs.defaultVertical.isEmpty ? "—" : prefs.defaultVertical },
                                set: { prefs.defaultVertical = $0 == "—" ? "" : $0 }),
                                options: ["—"] + MktVertical.allCases.map { $0.rawValue })
                            picker("DEFAULT MARKET", sel: Binding(
                                get: { prefs.defaultMarket.isEmpty ? "—" : prefs.defaultMarket },
                                set: { prefs.defaultMarket = $0 == "—" ? "" : $0 }),
                                options: ["—"] + MktMarkets.all.map { $0.label })
                        }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("SITE TEMPLATE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                                Picker("", selection: $prefs.siteTemplate) { ForEach(SiteTemplate.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("SITE PALETTE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                                Picker("", selection: $prefs.sitePalette) { ForEach(SitePalette.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("CAPTION TONE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                                Picker("", selection: $prefs.captionTone) { ForEach(CaptionTone.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Field(title: "Brand hashtag", text: $prefs.captionHashtag, prompt: "PixelStudio").frame(maxWidth: .infinity)
                        }
                    }
                }

                // --- Spotlight sender ---
                Panel(title: "Spotlight sender", icon: "envelope.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("How your email pitches sign off. Sends use your own mail app — no third-party service.")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        Field(title: "Your name", text: $prefs.senderName, prompt: "e.g. Dana Ramirez")
                        Field(title: "Reply-to email (optional)", text: $prefs.senderEmail, prompt: "you@yourstudio.com")
                    }
                }

                // --- Sign-in ---
                Panel(title: "Sign-in", icon: "key.fill") {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Email, guest, and Apple Sign-In work out of the box. To turn on the \"Sign in with Google\" button, paste your own Google OAuth 2.0 Desktop client ID below — it saves on this device, no secret required.")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

                        // Prominent Google client-ID setup card (the brief: make this field prominent).
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                GoogleGlyph().frame(width: 20, height: 20)
                                Text("Google sign-in").font(.system(size: 14.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                Spacer()
                                Label(GoogleAuth.isConfigured ? "Enabled" : "Off",
                                      systemImage: GoogleAuth.isConfigured ? "checkmark.seal.fill" : "circle.dashed")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundColor(GoogleAuth.isConfigured ? BLTheme.green : BLTheme.sub)
                            }
                            Field(title: "Google Desktop client ID", text: $googleClientID, prompt: "xxxxxxxx.apps.googleusercontent.com")
                            HStack(spacing: 10) {
                                GoldButton(label: "Save client ID", icon: "checkmark.circle") { saveGoogleClientID() }
                                if !googleClientID.trimmingCharacters(in: .whitespaces).isEmpty {
                                    GhostButton(label: "Clear", icon: "xmark.circle", tint: BLTheme.danger) {
                                        googleClientID = ""; saveGoogleClientID()
                                    }
                                }
                            }
                            Text("Create one at console.cloud.google.com → APIs & Services → Credentials → Create credentials → OAuth client ID → Application type: Desktop app. Paste the resulting client ID here. (A Web client ID will NOT work for this native app.)")
                                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(14)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(GoogleAuth.isConfigured ? BLTheme.green.opacity(0.4) : BLTheme.stroke, lineWidth: 1))

                        Text("Sign in with Apple shows on the sign-in screen and activates for real in the signed (provisioned) build of this app.")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // --- Lead Database subscription ---
                // Store builds (iOS App Store AND Mac App Store): the ONLY unlock is the in-app
                // StoreKit 2 subscription (com.blacklabel.marketing.leaddb.monthly) — Guideline
                // 3.1.1 rejected the pasted-key path b23→b25 on iOS and again on macOS build 61
                // (2026-07-27). The "Subscription key" field below compiles ONLY in the
                // Developer-ID / direct lane (-D DIRECT_DISTRIBUTION), where a license key is
                // permitted and nothing is an App Store submission.
                Panel(title: "Lead Database", icon: "tray.full.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        #if !DIRECT_DISTRIBUTION
                        LeadDBSubscribeCard()
                        #else
                        HStack(spacing: 10) {
                            Text("Subscription key").font(.system(size: 14.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Spacer()
                            Label(leadDBStatusLabel,
                                  systemImage: leadDBStatusIcon)
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundColor(leadDBStatusColor)
                        }
                        Text("Without a key, the Lead Database shows a masked preview (emails & phones blurred). Paste your subscription key to unlock full contact details and add them straight to your campaigns. Saves on this device.")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        Field(title: "Subscription key", text: $leadDBToken, prompt: "Paste your Lead Database key")
                        HStack(spacing: 10) {
                            GoldButton(label: leadDBTesting ? "Validating…" : "Validate & save", icon: "checkmark.circle") { saveLeadDBToken() }
                                .disabled(leadDBTesting)
                            if !leadDBToken.trimmingCharacters(in: .whitespaces).isEmpty {
                                GhostButton(label: "Clear", icon: "xmark.circle", tint: BLTheme.danger) {
                                    leadDBToken = ""; saveLeadDBToken()
                                }
                            }
                        }
                        if let validation = leadDBValidation {
                            Text(validation.detail)
                                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                .foregroundColor(validation.valid ? BLTheme.green : BLTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        #endif
                    }
                }

                // --- Landing-page lead capture ---
                Panel(title: "Landing-page lead capture", icon: "tray.and.arrow.down.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Where generated landing-page forms send leads. Use your own form endpoint (POST), or a contact email as a fallback. Leave both blank to ship pages without a form.")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        Field(title: "Form endpoint URL (optional)", text: $prefs.formEndpoint, prompt: "https://forms.yoursite.com/lead")
                        Field(title: "Contact email (fallback)", text: $prefs.contactEmail, prompt: "leads@yourstudio.com")
                    }
                }

                // --- Appearance ---
                Panel(title: "Appearance", icon: "wand.and.rays") {
                    Toggle(isOn: $prefs.motionEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Premium motion").font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Text("Master switch for all living motion — aurora drift, particles, foil shimmer, border-pulse. Off (or system Reduce Motion) falls back to a still, gorgeous look.")
                                .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }.tint(BLTheme.gold)
                }

                // --- Theme / Appearance Studio (full holographic customization + live preview) ---
                ThemeStudioPanel()

                // --- Lead scoring weights (transparent, buyer-tunable) ---
                Panel(title: "Lead scoring", icon: "flame.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tune how leads are scored. Every point is justified by a real field — there's no hidden model. Scores recompute instantly.")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        weightStepper("Has email", value: $prefs.leadScoreWeights.hasEmail)
                        weightStepper("Has phone", value: $prefs.leadScoreWeights.hasPhone)
                        weightStepper("Is a business", value: $prefs.leadScoreWeights.hasCompany)
                        weightStepper("Added in last 7 days", value: $prefs.leadScoreWeights.recentWithin7)
                        weightStepper("Added in last 30 days", value: $prefs.leadScoreWeights.recentWithin30)
                        weightStepper("Per logged touch", value: $prefs.leadScoreWeights.perLoggedTouch)
                        weightStepper("Touch points cap", value: $prefs.leadScoreWeights.touchCap, step: 4)
                        GhostButton(label: "Reset to defaults", icon: "arrow.counterclockwise") {
                            prefs.leadScoreWeights = .default; flash("Lead-scoring weights reset.")
                        }
                    }
                }

                // --- Saved profiles ---
                Panel(title: "Saved profiles", icon: "rectangle.stack.person.crop.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Save your full setup (brand, accent, defaults, tone) and switch between clients instantly.")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        HStack {
                            Field(title: "Profile name", text: $newProfileName, prompt: "Lighthouse Local")
                            GoldButton(label: "Save current", icon: "plus") {
                                prefs.saveCurrentAsProfile(named: newProfileName); newProfileName = ""
                                flash("Profile saved.")
                            }
                        }
                        if prefs.profiles.isEmpty {
                            EmptyState(icon: "rectangle.stack.badge.plus", title: "No profiles yet", hint: "Save your current brand setup to reuse it later.")
                        } else {
                            ForEach(prefs.profiles) { p in
                                HStack(spacing: 10) {
                                    Circle().fill(p.accent.color).frame(width: 16, height: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(p.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                        Text([p.brandName, p.vertical, p.market].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                                    }
                                    Spacer()
                                    GhostButton(label: "Apply", icon: "arrow.down.circle") { prefs.apply(p); flash("Applied \(p.name).") }
                                    IconButton(system: "trash", tint: BLTheme.danger) { prefs.deleteProfile(p) }
                                }
                                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                            }
                        }
                    }
                }

                if !saved.isEmpty {
                    Label(saved, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                } else if autoSavedFlash {
                    // P1-9: instant confirmation that a silently-autosaved edit persisted.
                    Label("Saved ✓ — changes save automatically on this device", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                        .transition(.opacity)
                }

                // --- Workspace backup ---
                Panel(title: "Workspace backup", icon: "externaldrive.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Save or restore all local studio data and customization. OAuth client IDs, Lead Database keys, and remembered sessions stay on this device.")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            GoldButton(label: "Export workspace", icon: "square.and.arrow.up") { exportWorkspace() }
                            GhostButton(label: "Import workspace", icon: "square.and.arrow.down") { chooseWorkspaceImport() }
                            Spacer()
                            Label("JSON", systemImage: "doc.text.fill")
                                .font(BLFonts.mono(10, weight: .bold))
                                .foregroundColor(BLTheme.gold)
                        }
                        if !workspaceError.isEmpty {
                            Label(workspaceError, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundColor(BLTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !workspaceStatus.isEmpty {
                            Label(workspaceStatus, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundColor(BLTheme.green)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                // --- Account ---
                Panel(title: "Account", icon: "person.crop.circle.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stat(label: "Signed in as", value: session.email == "guest" ? "Guest" : (session.email.isEmpty ? "Guest" : session.email))
                        GoldButton(label: "Sign out", icon: "arrow.backward.square") { withAnimation { session.signedIn = false } }
                    }
                }

                // --- Cancel or export (MK-18) ---
                // Honest under BOTH pending founder outcomes: if a Stripe customer-portal URL is
                // configured we deep-link to it; otherwise we show the email-to-cancel floor + the
                // working export-all. The surface fabricates no portal URL and never claims a
                // one-click cancel until a real portal backs it (SubscriptionManagement.swift).
                Panel(title: "Cancel or export", icon: "arrow.uturn.left.circle.fill") {
                    let surface = CancelExportSurface()
                    VStack(alignment: .leading, spacing: 12) {
                        Text(surface.headline)
                            .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text(surface.body)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            if let portal = surface.portalURL {
                                GoldButton(label: surface.primaryActionLabel, icon: "arrow.up.forward.app") {
                                    openURL(portal)
                                }
                            } else if let mailto = surface.cancelMailtoURL {
                                GhostButton(label: surface.primaryActionLabel, icon: "envelope") {
                                    openURL(mailto)
                                }
                            }
                            GoldButton(label: "Export everything first", icon: "square.and.arrow.up") { exportWorkspace() }
                            Spacer()
                        }
                        Text(surface.exportNote)
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // --- Support & diagnostics (DOD-7.6 / DOD-11.5) ---
                // The panel and the export render the SAME fact list (SupportDiagnostics.facts()),
                // so what support receives is exactly what the user just read — nothing more.
                Panel(title: "Support & diagnostics", icon: "stethoscope") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("The facts support asks for first. Export diagnostic bundle writes exactly these facts to a plain-text file you can read in full before sending — no account emails, no tokens or credentials, no leads, no message content.")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(SupportDiagnostics.facts()) { fact in
                                Stat(label: fact.label, value: fact.value)
                            }
                        }
                        HStack(spacing: 10) {
                            GoldButton(label: "Export diagnostic bundle", icon: "square.and.arrow.up") { exportDiagnostics() }
                            GhostButton(label: "Copy to clipboard", icon: "doc.on.doc") { copyDiagnostics() }
                            Spacer()
                        }
                        if !diagStatus.isEmpty {
                            Label(diagStatus, systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundColor(BLTheme.green)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !diagError.isEmpty {
                            Label(diagError, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundColor(BLTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Panel(title: "About", icon: "info.circle.fill") {
                    VStack(alignment: .leading, spacing: 6) {
                        Stat(label: "App", value: AppBrand.displayName)
                        // Read from the bundle, never hardcoded — a literal here shipped "1.0"
                        // while the app was 1.1 (build 72).
                        Stat(label: "Version", value: SupportDiagnostics.appVersionString())
                        Text("Sites, captions, spotlights, and campaign links — a native marketing studio. Bundled fonts: Cormorant Garamond + JetBrains Mono (OFL).")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
                Panel(title: "Reset & delete", icon: "trash.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Permanently delete your account and every piece of data stored on this device (clients, site projects, captions, links, spotlights, and your settings), and every saved credential in your Keychain. It also deletes the records this app created on services you connected: the short links in your Cloudflare Worker's KV store are removed, and your Google authorization for this app is revoked at Google. Content you already sent to a third party — texts delivered by Sendblue, posts published to a social network, leads pushed into your CRM — lives on those services and can only be removed there; you'll be told exactly which. This cannot be undone.")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        if !deletionSummary.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(deletionSummary)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                ForEach(deletionReceipts) { receipt in
                                    Text("• \(receipt.target.label): \(AccountDeletionReceiptText.line(receipt.outcome))")
                                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                        .foregroundColor(receipt.outcome.isSuccessClaim ? BLTheme.sub : BLTheme.danger)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                        Button { confirmDelete = true } label: {
                            HStack(spacing: 6) { Image(systemName: "trash"); Text("Delete my account & data") }
                                .font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(.white)
                                .padding(.vertical, 11).padding(.horizontal, 18)
                                .background(Color(hex: 0xC0392B)).clipShape(Capsule())
                        }.buttonStyle(.plain).disabled(deleting)
                    }
                }
            }
            .padding(28)
        }
        .alert("Delete account?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteAccount() }
        } message: {
            Text("This permanently removes your account, all saved data, settings and credentials from this device, deletes the short links this app created on your Cloudflare Worker, and revokes your Google authorization. You'll see a per-item receipt — anything that could not be deleted is named, never glossed over.")
        }
        .onChange(of: prefs.lastSaveAt) { _ in
            // P1-9: a pref autosaved — surface an instant "Saved" pill for ~1.6s.
            withAnimation { autoSavedFlash = true }
            let stamp = prefs.lastSaveAt
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                if prefs.lastSaveAt == stamp { withAnimation { autoSavedFlash = false } }
            }
        }
        .onAppear { validateSavedLeadDBToken() }
        #if os(iOS)
        // iOS logo/workspace import via the system document picker (UIDocumentPicker). Security-
        // scoped: we start/stop access around the read so picking from iCloud Drive / Files works.
        // Each importer rides its OWN background host: two `.fileImporter`s chained on the SAME
        // view silently drop the first presentation on iOS/iPadOS — App Review 2.1(a) 2026-07-21,
        // "tapped to upload logo … no response" on iPad.
        .background(Color.clear.fileImporter(isPresented: $showLogoImporter, allowedContentTypes: [.png, .jpeg, .image], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { setLogo(data) }
        })
        .background(Color.clear.fileImporter(isPresented: $showWorkspaceImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importWorkspace(url)
        })
        #endif
    }

    @ViewBuilder private func picker(_ title: String, sel: Binding<String>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
            Picker("", selection: sel) { ForEach(options, id: \.self) { Text($0).tag($0) } }.labelsHidden().tint(BLTheme.gold)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickLogo() {
        #if os(iOS)
        // Phone import: present the system document picker (handled by the .fileImporter modifier).
        showLogoImporter = true
        #else
        let p = NSOpenPanel()
        p.allowedContentTypes = [.png, .jpeg, .image]
        p.allowsMultipleSelection = false; p.canChooseDirectories = false
        if p.runModal() == .OK, let url = p.url, let data = try? Data(contentsOf: url) {
            // Downscale-friendly: store the raw image; NSImage handles rendering.
            setLogo(data)
        }
        #endif
    }

    /// Store the buyer's logo AND extract its dominant colors into the brand kit palette.
    private func setLogo(_ data: Data) {
        prefs.logoData = data
        if let cg = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let colors = BrandProfiler.logoColors(cg)
            if !colors.isEmpty { prefs.brandColors = colors }
        }
    }

    /// Two-way bridge between prefs.customAccentHex (UInt32, 0 = preset) and a SwiftUI Color.
    private var customColorBinding: Binding<Color> {
        Binding(
            get: { prefs.customAccentHex != 0 ? Color(hex: prefs.customAccentHex) : prefs.accent.color },
            set: { prefs.customAccentHex = Self.hex(from: $0) }
        )
    }
    /// Parse a user-typed hex color into a 0xRRGGBB value. Accepts "#C20017", "c20017", "C20017",
    /// and 3-digit shorthand "#f00" → 0xFF0000. Returns nil until a complete, valid color is entered
    /// (so partial typing never applies a garbage color). Never fabricates — invalid input is ignored.
    static func parseHex(_ raw: String) -> UInt32? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.allSatisfy({ $0.isHexDigit }) else { return nil }
        if s.count == 3 {   // shorthand: expand each nibble (F00 → FF0000)
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return v
    }
    private static func hex(from color: Color) -> UInt32 {
        #if canImport(AppKit)
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let r = UInt32((ns.redComponent * 255).rounded()), g = UInt32((ns.greenComponent * 255).rounded()), b = UInt32((ns.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
        #else
        let ui = UIColor(color); var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (UInt32((r*255).rounded()) << 16) | (UInt32((g*255).rounded()) << 8) | UInt32((b*255).rounded())
        #endif
    }

    private func profileFromSite() {
        let site = brandSite.trimmingCharacters(in: .whitespaces)
        guard !site.isEmpty else { profileNote = "Enter your website address first."; return }
        profiling = true; profileNote = ""
        BrandProfiler.profileSite(site) { profile in
            profiling = false
            guard let p = profile else { profileNote = "Couldn't read that site — check the address."; return }
            var filled: [String] = []
            if let b = p.brandName, prefs.brandName.trimmingCharacters(in: .whitespaces).isEmpty { prefs.brandName = b; filled.append("name") }
            if let t = p.tagline, prefs.tagline.trimmingCharacters(in: .whitespaces).isEmpty { prefs.tagline = String(t.prefix(140)); filled.append("tagline") }
            if !p.colors.isEmpty {
                prefs.brandColors = p.colors
                if let first = p.colors.first { prefs.customAccentHex = first; hexInput = String(format: "%06X", first) }
                filled.append("colors")
            }
            siteApplied = !filled.isEmpty
            profileNote = filled.isEmpty ? "Read your site — nothing new to fill (already set)." : "✓ Filled \(filled.joined(separator: ", ")) from your site."
        }
    }
    private func flash(_ m: String) {
        saved = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if saved == m { saved = "" } }
    }
    private func exportWorkspace() {
        workspaceError = ""
        workspaceStatus = ""
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "black-label-marketing-workspace.json"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try model.exportWorkspace(to: url, prefs: prefs)
                workspaceStatus = "Workspace exported."
                flash("Workspace exported.")
            } catch {
                workspaceError = error.localizedDescription
            }
        }
    }
    /// DOD-11.5: write the privacy-safe diagnostic bundle. macOS: save panel. iOS: the Compat
    /// NSSavePanel shim turns the same synchronous write into a share sheet.
    private func exportDiagnostics() {
        diagStatus = ""; diagError = ""
        let text = SupportDiagnostics.bundleText(SupportDiagnostics.facts())
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = SupportDiagnostics.defaultFilename()
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                diagStatus = "Diagnostic bundle exported. It contains only the facts shown above."
            } catch {
                diagError = error.localizedDescription
            }
        }
    }

    /// Same facts, straight to the clipboard — for pasting into a support email.
    private func copyDiagnostics() {
        diagStatus = ""; diagError = ""
        let text = SupportDiagnostics.bundleText(SupportDiagnostics.facts())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        diagStatus = "Diagnostics copied. Paste into your support email — only the facts shown above."
    }

    private func chooseWorkspaceImport() {
        workspaceError = ""
        workspaceStatus = ""
        #if os(iOS)
        showWorkspaceImporter = true
        #else
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            importWorkspace(url)
        }
        #endif
    }
    private func importWorkspace(_ url: URL) {
        do {
            let summary = try model.importWorkspace(from: url, prefs: prefs)
            workspaceError = ""
            workspaceStatus = "Workspace restored: \(summary)"
            flash("Workspace restored.")
        } catch {
            workspaceStatus = ""
            workspaceError = error.localizedDescription
        }
    }
    private func saveGoogleClientID() {
        let trimmed = googleClientID.trimmingCharacters(in: .whitespaces)
        googleClientID = trimmed
        let d = UserDefaults.standard
        if trimmed.isEmpty { d.removeObject(forKey: GoogleAuth.clientIDDefaultsKey) }
        else { d.set(trimmed, forKey: GoogleAuth.clientIDDefaultsKey) }
        flash(trimmed.isEmpty ? "Google client ID cleared." : "Google sign-in enabled — saved on this device.")
    }

    private func saveLeadDBToken() {
        let trimmed = leadDBToken.trimmingCharacters(in: .whitespacesAndNewlines)
        leadDBToken = trimmed
        if trimmed.isEmpty {
            LeadDBCredential.clear()
            leadDBValidation = nil
            leadDBTesting = false
            flash("Lead Database key cleared — preview mode.")
            return
        }
        leadDBTesting = true
        leadDBValidation = nil
        Task {
            let validation = await LeadDB.validateToken(trimmed)
            await MainActor.run {
                leadDBTesting = false
                leadDBValidation = validation
                if validation.valid {
                    LeadDBCredential.save(trimmed)
                    flash("Lead Database key validated and saved to your Keychain on this device.")
                }
            }
        }
    }

    private var leadDBStatusLabel: String {
        if leadDBToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Preview" }
        if leadDBTesting { return "Validating…" }
        if let validation = leadDBValidation { return validation.valid ? "Unlocked" : "Rejected" }
        return "Not tested"
    }
    private var leadDBStatusIcon: String {
        if leadDBTesting { return "hourglass" }
        if leadDBValidation?.valid == true { return "checkmark.seal.fill" }
        if leadDBValidation?.valid == false { return "xmark.octagon.fill" }
        return "lock.fill"
    }
    private var leadDBStatusColor: Color {
        if leadDBTesting { return BLTheme.gold }
        if leadDBValidation?.valid == true { return BLTheme.green }
        if leadDBValidation?.valid == false { return BLTheme.danger }
        return BLTheme.sub
    }
    private func validateSavedLeadDBToken() {
        let token = leadDBToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !leadDBTesting else { return }
        leadDBTesting = true
        Task {
            let validation = await LeadDB.validateToken(token)
            await MainActor.run {
                leadDBTesting = false
                leadDBValidation = validation
            }
        }
    }
    /// The mailboxes whose provider OAuth tokens must be destroyed alongside the account.
    private var connectedAPIMailboxes: [(provider: EmailAPIProvider, address: String)] {
        ([leadEngine.settings.mailbox] + leadEngine.settings.extraMailboxes).compactMap { mailbox in
            guard let provider = mailbox.authKind.provider else { return nil }
            let address = mailbox.fromEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            return address.isEmpty ? nil : (provider, address)
        }
    }

    /// App Store 5.1.1(v) full in-account deletion — and it now means what it says.
    ///
    /// ORDER IS LOAD-BEARING: the SERVER-SIDE deletions run FIRST (short links on the buyer's own
    /// Worker, the Google OAuth grant), because they are authenticated with credentials that the
    /// local wipe is about to destroy. Only when the runner has returned its receipts do we clear
    /// the device. The buyer is then shown what actually happened — including anything that did
    /// NOT delete — instead of a blanket "it's all gone".
    private func deleteAccount() {
        guard !deleting else { return }
        deleting = true
        let email = session.email
        let mailboxes = connectedAPIMailboxes
        let crmAccounts = leadEngine.settings.crmConnector.provider == .none
            ? []
            : [CRMConnectorKeychain.account(for: leadEngine.settings.crmConnector)]
        Task { @MainActor in
            let receipts = await AccountDeletionRunner.run(mailboxes: mailboxes, crmAccounts: crmAccounts)
            deletionReceipts = receipts
            deletionSummary = AccountDeletionPlanner.summary(receipts)
            model.logSecurity("delete_account", deletionSummary)
            if email != "guest" && !email.isEmpty { AccountStore.delete(email) }
            // Single source of truth: clears EVERY collection (incl. multichannel campaigns,
            // ABM accounts, referral programs, roadmap items, and the audit log) and removes
            // the on-disk store.
            model.deleteAllData()
            prefs.resetAll()
            session.email = ""
            deleting = false
            withAnimation { session.signedIn = false }
        }
    }

    /// Compact +/- stepper for an integer scoring weight, with a live value readout.
    @ViewBuilder private func weightStepper(_ label: String, value: Binding<Int>, step: Int = 1) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            Spacer()
            Button { value.wrappedValue = max(0, value.wrappedValue - step) } label: { Image(systemName: "minus.circle.fill").foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
            Text("\(value.wrappedValue)").font(BLFonts.mono(13, weight: .heavy)).foregroundColor(BLTheme.gold).frame(minWidth: 30)
            Button { value.wrappedValue = min(100, value.wrappedValue + step) } label: { Image(systemName: "plus.circle.fill").foregroundColor(BLTheme.gold) }.buttonStyle(.plain)
        }
        .padding(.vertical, 7).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
#endif // circuit-convert
