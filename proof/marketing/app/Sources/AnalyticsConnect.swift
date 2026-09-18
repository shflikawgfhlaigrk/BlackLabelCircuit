#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — analytics/ad data-source connectors (honest-empty, own-it).
//
// The website promises analytics that "connects to your own sources (GA, ad accounts) and stays
// empty and honest until you connect them." This provides that connect surface: the buyer points it
// at THEIR OWN account, and until a real data sync exists the KPIs stay empty — we NEVER fabricate
// spend, clicks, or conversions. Live API sync requires the buyer's own provider OAuth app
// (registered in their console), mirroring the own-it social-OAuth pattern.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

enum AnalyticsSource: String, CaseIterable, Identifiable {
    case ga4 = "Google Analytics 4"
    case searchConsole = "Google Search Console"
    case googleAds = "Google Ads"
    case metaAds = "Meta Ads"
    var id: String { rawValue }

    var key: String {
        switch self { case .ga4: return "ga4"; case .searchConsole: return "searchConsole"; case .googleAds: return "googleAds"; case .metaAds: return "metaAds" }
    }
    var icon: String {
        switch self { case .ga4: return "chart.xyaxis.line"; case .searchConsole: return "magnifyingglass.circle.fill"; case .googleAds: return "g.circle.fill"; case .metaAds: return "f.circle.fill" }
    }
    var idLabel: String {
        switch self { case .ga4: return "Numeric Property ID (not G-XXXX)"; case .searchConsole: return "https://… or sc-domain:example.com"; case .googleAds: return "Customer ID (123-456-7890)"; case .metaAds: return "Ad account ID (act_XXXX)" }
    }
    /// Where the buyer goes to READ OFF the id `idLabel` asks for — the screen that displays it,
    /// not the product's front door. A bare `analytics.google.com` or `ads.google.com` lands a
    /// signed-out visitor on a marketing page and a signed-in one on whatever they last viewed;
    /// neither shows the id. Verified 2026-08-12: each resolves to the id-bearing screen, or to
    /// the provider's sign-in carrying a return link back to it.
    var console: String {
        switch self {
        // The numeric Property ID lives in Admin → Property Settings, not on the reporting home.
        case .ga4: return "https://analytics.google.com/analytics/web/#/admin"
        case .searchConsole: return "https://search.google.com/search-console"
        // The Customer ID sits in the account header of the Ads UI proper.
        case .googleAds: return "https://ads.google.com/aw/overview"
        // act_XXXX ids are listed per account in Ads Manager, not in Business settings.
        case .metaAds: return "https://adsmanager.facebook.com/adsmanager/manage/accounts"
        }
    }
    var provides: String {
        switch self {
        case .ga4: return "sessions, traffic sources, conversions"
        case .searchConsole: return "organic clicks, impressions, queries, pages"
        case .googleAds: return "ad spend, clicks, conversions"
        case .metaAds: return "ad spend, reach, results"
        }
    }
}

/// Honest-empty "Connect your data" panel. Saving an account ID records the buyer's OWN source;
/// KPIs remain empty until a real sync exists (clearly stated) — never fabricated.
struct DataSourcesPanel: View {
    @EnvironmentObject var prefs: Prefs
    @State private var drafts: [String: String] = [:]
    @State private var ga4TokenDraft = ""
    @State private var ga4ClientIDDraft = ""
    @State private var ga4HasToken = false
    @State private var ga4Refreshable = false
    @State private var ga4Loading = false
    @State private var ga4Note = ""
    @State private var ga4Result: GA4AnalyticsResult?
    @State private var ga4Comparison: GA4AnalyticsComparison?
    @State private var ga4Window = GA4ReportingWindow.thirtyDays
    @State private var searchConsoleSites: [SearchConsoleSite] = []
    @State private var searchConsoleLoading = false
    @State private var searchConsoleNote = ""
    @State private var searchConsoleComparison: SearchConsoleAnalyticsComparison?
    @State private var searchConsoleWindow = GA4ReportingWindow.thirtyDays

    var body: some View {
        Panel(title: "Connect your data", icon: "link.circle.fill") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AnalyticsSource.allCases) { src in
                    let saved = prefs.analyticsAccounts[src.key] ?? ""
                    if src == .ga4 { ga4Card(saved: saved) }
                    else if src == .searchConsole { searchConsoleCard(saved: saved) }
                    else { configuredOnlyCard(src, saved: saved) }
                }
                Text("Own-it: these are YOUR accounts. We never fabricate spend, clicks, or conversions — the dashboard shows only data you've logged or that syncs from a source you connect.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            ga4HasToken = GA4AnalyticsConfig.hasToken
            ga4Refreshable = GA4AnalyticsConfig.hasRefreshableCredential
            ga4ClientIDDraft = GA4AnalyticsConfig.clientID
            ga4Comparison = GA4AnalyticsConfig.lastComparison
            ga4Result = ga4Comparison?.current ?? GA4AnalyticsConfig.lastResult
            if let cachedWindow = ga4Comparison?.window { ga4Window = cachedWindow }
            searchConsoleComparison = SearchConsoleAnalyticsConfig.lastComparison
            if let cachedWindow = searchConsoleComparison?.window { searchConsoleWindow = cachedWindow }
        }
    }

    @ViewBuilder private func searchConsoleCard(saved: String) -> some View {
        let draftProperty = drafts[AnalyticsSource.searchConsole.key] ?? saved
        let normalized = SearchConsoleAnalytics.normalizeProperty(draftProperty)
        let verified = searchConsoleComparison?.current.siteURL == normalized
        let nativeScopeReady = SearchConsoleAnalytics.hasRequiredScope(GA4AnalyticsConfig.credential)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: AnalyticsSource.searchConsole.icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                Text(AnalyticsSource.searchConsole.rawValue).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                StatusPill(text: verified ? "Live · verified read" : ((!ga4HasToken || saved.isEmpty) ? "Not connected" : "Ready to test"),
                           tint: verified ? BLTheme.green : ((!ga4HasToken || saved.isEmpty) ? BLTheme.sub : BLTheme.gold))
            }
            Text("Real organic search totals plus the top queries and pages, compared with the immediately preceding period.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            Text("1  Authorize Google   ·   2  choose an exact verified property   ·   3  test the live read")
                .font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
            HStack(spacing: 8) {
                Field(title: "Exact Search Console property", text: Binding(
                    get: { drafts[AnalyticsSource.searchConsole.key] ?? saved },
                    set: { drafts[AnalyticsSource.searchConsole.key] = $0 }), prompt: "https://example.com/ or sc-domain:example.com")
                GhostButton(label: "Open GSC", icon: "arrow.up.right") {
                    if let url = URL(string: AnalyticsSource.searchConsole.console) {
                        DemoMode.openExternal(url, simulatedNote: "Demo: this would open Google Search Console.")
                    }
                }
            }
            if !searchConsoleSites.isEmpty {
                Picker("Verified property", selection: Binding(
                    get: { drafts[AnalyticsSource.searchConsole.key] ?? saved },
                    set: { drafts[AnalyticsSource.searchConsole.key] = $0 })) {
                        if saved.isEmpty { Text("Choose a property").tag("") }
                        ForEach(searchConsoleSites) { site in
                            Text("\(site.siteURL) · \(site.permissionLevel)").tag(site.siteURL)
                        }
                    }
                    .pickerStyle(.menu)
            }
            HStack(spacing: 8) {
                // Loopback (127.0.0.1) Google OAuth needs com.apple.security.network.server.
                // The Mac App Store slice ships without that entitlement (App Review 2.4.5(i):
                // minimum entitlements only), so this button — and only this button — is absent
                // there; the pasted-token path below is the store build's connect route.
                #if os(macOS) && DIRECT_DISTRIBUTION
                GoldButton(label: searchConsoleLoading ? "Connecting…" : (nativeScopeReady ? "Reconnect Google" : "Authorize Search Console"),
                           icon: "person.crop.circle.badge.checkmark") { connectSearchConsole() }
                    .disabled(searchConsoleLoading)
                #endif
                GhostButton(label: searchConsoleSites.isEmpty ? "Find my properties" : "Reload properties", icon: "list.bullet") {
                    loadSearchConsoleSites()
                }
                .disabled(searchConsoleLoading || !ga4HasToken)
                Text(nativeScopeReady ? "Search Console read-only grant available"
                     : (ga4HasToken ? "Manual token scope unverified · live test required" : "Reconnect Google to add Search Console read-only"))
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(nativeScopeReady ? BLTheme.green : .orange)
            }
            HStack(spacing: 8) {
                Picker("Comparison window", selection: $searchConsoleWindow) {
                    ForEach(GA4ReportingWindow.allCases) { window in Text(window.label).tag(window) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 280)
                GhostButton(label: "Save setup", icon: "checkmark") { saveSearchConsole() }
                GoldButton(label: searchConsoleLoading ? "Pulling six reads…" : "Test & compare", icon: "arrow.clockwise") {
                    refreshSearchConsole()
                }
                .disabled(searchConsoleLoading)
            }
            if !searchConsoleNote.isEmpty {
                Text(searchConsoleNote).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(searchConsoleNote.hasPrefix("✓") ? BLTheme.green : BLTheme.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let comparison = searchConsoleComparison, verified {
                let result = comparison.current
                HStack(spacing: 18) {
                    ga4Metric("CLICKS", String(format: "%.0f", result.clicks), comparison.clicksChange)
                    ga4Metric("IMPRESSIONS", String(format: "%.0f", result.impressions), comparison.impressionsChange)
                    ga4Metric("CTR", String(format: "%.1f%%", result.ctr * 100), comparison.ctrChange)
                    ga4Metric("AVG POSITION", result.position > 0 ? String(format: "%.1f", result.position) : "—", comparison.positionChange)
                    Spacer()
                }
                HStack(alignment: .top, spacing: 16) {
                    searchRows("TOP QUERIES", result.queries)
                    searchRows("TOP PAGES", result.pages)
                }
                Text("Search Console Search Analytics API · final web data · \(result.startDate) to \(result.endDate) · tables show top \(SearchConsoleAnalytics.topRowLimit) rows, not complete totals · pulled \(result.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(verified ? BLTheme.green.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
    }

    private func searchRows(_ title: String, _ rows: [SearchConsoleMetricRow]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            if rows.isEmpty {
                Text("No rows returned").font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            } else {
                ForEach(Array(rows.prefix(5))) { row in
                    HStack(spacing: 7) {
                        Text(row.key).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(Int(row.clicks.rounded())) clicks")
                    }
                    .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func ga4Card(saved: String) -> some View {
        let draftProperty = drafts[AnalyticsSource.ga4.key] ?? saved
        let verified = ga4Result?.propertyID == GA4Analytics.normalizePropertyID(draftProperty)
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: AnalyticsSource.ga4.icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                Text(AnalyticsSource.ga4.rawValue).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                StatusPill(text: verified ? "Live · verified read" : ((saved.isEmpty || !ga4HasToken) ? "Not connected" : "Ready to test"),
                           tint: verified ? BLTheme.green : ((saved.isEmpty || !ga4HasToken) ? BLTheme.sub : BLTheme.gold))
            }
            Text("Two real GA4 reads compare this period with the immediately preceding period. No modeled or sample metrics.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            Text("1  Find your numeric Property ID in GA Admin   ·   2  connect your Google Desktop OAuth client   ·   3  verify the live read")
                .font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Field(title: "Numeric Property ID", text: Binding(
                    get: { drafts[AnalyticsSource.ga4.key] ?? saved },
                    set: { drafts[AnalyticsSource.ga4.key] = $0 }), prompt: "123456789 (not G-XXXX)")
                GhostButton(label: "Open GA", icon: "arrow.up.right") {
                    if let url = URL(string: AnalyticsSource.ga4.console) {
                        DemoMode.openExternal(url, simulatedNote: "Demo: this would open Google Analytics.")
                    }
                }
            }
            #if os(macOS) && DIRECT_DISTRIBUTION
            Field(title: "Google Desktop OAuth Client ID", text: $ga4ClientIDDraft,
                  prompt: "123…apps.googleusercontent.com")
            #endif
            HStack(spacing: 8) {
                #if os(macOS) && DIRECT_DISTRIBUTION
                GoldButton(label: ga4Loading ? "Connecting…" : (ga4Refreshable ? "Reconnect Google" : "Connect Google"),
                           icon: "person.crop.circle.badge.checkmark") { connectGA4() }
                    .disabled(ga4Loading)
                #endif
                GhostButton(label: "OAuth setup", icon: "questionmark.circle") {
                    if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
                        DemoMode.openExternal(url, simulatedNote: "Demo: this would open Google Cloud OAuth credentials.")
                    }
                }
                #if os(macOS) && DIRECT_DISTRIBUTION
                Text(ga4Refreshable ? "Refresh token secured in Keychain · renews automatically" : "Use a Desktop app client · PKCE + local callback · no client secret")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(ga4Refreshable ? BLTheme.green : BLTheme.sub)
                #else
                Text(ga4HasToken ? "Access token stored — paste a new one below to replace it" : "Paste an analytics.readonly access token below to connect")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(ga4HasToken ? BLTheme.green : BLTheme.sub)
                #endif
            }
            #if !(os(macOS) && DIRECT_DISTRIBUTION)
            Text("This build connects GA4 with an access token you paste below (scope \(GA4Analytics.readonlyScope)). Manual tokens are short-lived and do not renew themselves.")
                .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            #endif
            DisclosureGroup("Advanced · short-lived access token") {
                VStack(alignment: .leading, spacing: 6) {
                    SecureField(ga4HasToken ? "Access token stored — paste to replace" : "OAuth access token (analytics.readonly)", text: $ga4TokenDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 10).padding(.horizontal, 12).background(BLTheme.bg)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                    Text("Required scope: \(GA4Analytics.readonlyScope). Manual access tokens expire and cannot renew themselves.")
                        .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 5)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
            HStack(spacing: 8) {
                Picker("Comparison window", selection: $ga4Window) {
                    ForEach(GA4ReportingWindow.allCases) { window in Text(window.label).tag(window) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 280)
                GhostButton(label: "Save setup", icon: "checkmark") { saveGA4() }
                GoldButton(label: ga4Loading ? "Pulling two periods…" : "Test & compare", icon: "arrow.clockwise") { refreshGA4() }
                    .disabled(ga4Loading)
                if ga4HasToken {
                    GhostButton(label: "Disconnect", icon: "xmark.circle", tint: BLTheme.danger) { disconnectGA4() }
                }
            }
            if !ga4Note.isEmpty {
                Text(ga4Note).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(ga4Note.hasPrefix("✓") ? BLTheme.green : BLTheme.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let result = ga4Result, verified {
                HStack(spacing: 18) {
                    ga4Metric("SESSIONS", result.sessions.map(String.init) ?? "—", ga4Comparison?.sessionsChange)
                    ga4Metric("USERS", result.users.map(String.init) ?? "—", ga4Comparison?.usersChange)
                    ga4Metric("KEY EVENTS", result.keyEvents.map { String(format: "%.0f", $0) } ?? "—", ga4Comparison?.keyEventsChange)
                    ga4Metric("VIEWS", result.pageViews.map(String.init) ?? "—", ga4Comparison?.pageViewsChange)
                    Spacer()
                }
                if !result.channels.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CHANNELS").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
                        ForEach(Array(result.channels.prefix(6))) { channel in
                            HStack(spacing: 8) {
                                Text(channel.channel).frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(channel.sessions.map(String.init) ?? "—") sessions")
                                Text(changeText(ga4Comparison?.sessionsChange(for: channel.channel)))
                                    .foregroundColor(changeTint(ga4Comparison?.sessionsChange(for: channel.channel)))
                                    .frame(width: 72, alignment: .trailing)
                            }
                            .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }
                }
                Text("Google Analytics Data API · \(result.startDate) to \(result.endDate) versus the prior \(ga4Comparison?.window.rawValue ?? ga4Window.rawValue) days · pulled \(result.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
        }
        .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(verified ? BLTheme.green.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
    }

    private func ga4Metric(_ label: String, _ value: String, _ change: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
            Text(label).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            Text(changeText(change)).font(.system(size: 8.5, weight: .bold, design: .rounded)).foregroundColor(changeTint(change))
        }
    }

    private func changeText(_ change: Double?) -> String {
        guard let change else { return "No prior baseline" }
        return String(format: "%+.1f%%", change * 100)
    }

    private func changeTint(_ change: Double?) -> Color {
        guard let change else { return BLTheme.sub }
        return change >= 0 ? BLTheme.green : .orange
    }

    @ViewBuilder private func configuredOnlyCard(_ src: AnalyticsSource, saved: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: src.icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                Text(src.rawValue).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                StatusPill(text: saved.isEmpty ? "Not connected" : "ID saved · API not live",
                           tint: saved.isEmpty ? BLTheme.sub : BLTheme.gold)
            }
            HStack(spacing: 8) {
                Field(title: "", text: Binding(
                    get: { drafts[src.key] ?? saved },
                    set: { drafts[src.key] = $0 }), prompt: src.idLabel)
                GhostButton(label: saved.isEmpty ? "Save" : "Update", icon: "checkmark") {
                    let value = (drafts[src.key] ?? saved).trimmingCharacters(in: .whitespaces)
                    if value.isEmpty { prefs.analyticsAccounts[src.key] = nil } else { prefs.analyticsAccounts[src.key] = value }
                }
                GhostButton(label: "Open", icon: "arrow.up.right") {
                    if let url = URL(string: src.console) {
                        DemoMode.openExternal(url, simulatedNote: "Demo: this would open \(src.console).")
                    }
                }
            }
            Text(saved.isEmpty
                 ? "Save your own \(src.rawValue) account ID. API execution is not wired yet."
                 : "Saved \(saved), but no metrics are pulled yet. This is deliberately not labeled connected.")
                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func saveGA4() {
        let property = (drafts[AnalyticsSource.ga4.key] ?? prefs.analyticsAccounts[AnalyticsSource.ga4.key] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedProperty = GA4Analytics.normalizePropertyID(property) else {
            ga4Note = GA4AnalyticsError.invalidPropertyID.localizedDescription; return
        }
        prefs.analyticsAccounts[AnalyticsSource.ga4.key] = normalizedProperty
        drafts[AnalyticsSource.ga4.key] = normalizedProperty
        if !ga4TokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            GA4AnalyticsConfig.setToken(ga4TokenDraft); ga4TokenDraft = ""
        }
        GA4AnalyticsConfig.clientID = ga4ClientIDDraft
        ga4HasToken = GA4AnalyticsConfig.hasToken
        ga4Refreshable = GA4AnalyticsConfig.hasRefreshableCredential
        ga4Note = ga4HasToken ? "Saved. Test & refresh to prove the connection." : GA4AnalyticsError.missingToken.localizedDescription
    }

    private func saveSearchConsole() {
        let raw = drafts[AnalyticsSource.searchConsole.key] ?? prefs.analyticsAccounts[AnalyticsSource.searchConsole.key] ?? ""
        guard let property = SearchConsoleAnalytics.normalizeProperty(raw) else {
            searchConsoleNote = SearchConsoleAnalyticsError.invalidProperty.localizedDescription; return
        }
        prefs.analyticsAccounts[AnalyticsSource.searchConsole.key] = property
        drafts[AnalyticsSource.searchConsole.key] = property
        searchConsoleNote = ga4HasToken ? "Saved. Test & compare to prove the connection." : GA4AnalyticsError.missingToken.localizedDescription
    }

    #if os(macOS) && DIRECT_DISTRIBUTION
    private func connectSearchConsole() {
        let clientID = ga4ClientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { searchConsoleNote = GA4AnalyticsError.missingClientID.localizedDescription; return }
        GA4AnalyticsConfig.clientID = clientID
        searchConsoleLoading = true
        searchConsoleNote = "Opening Google consent for Analytics and Search Console read-only access…"
        GA4OAuth.shared.connect(clientID: clientID) { result in
            switch result {
            case .failure(let error):
                searchConsoleLoading = false; searchConsoleNote = error.localizedDescription
            case .success:
                ga4HasToken = true; ga4Refreshable = true
                searchConsoleLoading = false
                searchConsoleNote = "Google authorized. Loading your verified Search Console properties…"
                loadSearchConsoleSites()
            }
        }
    }
    #endif

    private func loadSearchConsoleSites() {
        searchConsoleLoading = true
        Task {
            do {
                let sites = try await SearchConsoleAnalytics.listSites()
                await MainActor.run {
                    searchConsoleSites = sites; searchConsoleLoading = false
                    if sites.isEmpty {
                        searchConsoleNote = "Google returned no Search Console properties for this account. Add or verify one in Search Console."
                    } else {
                        searchConsoleNote = "✓ Loaded \(sites.count) verified Search Console propert\(sites.count == 1 ? "y" : "ies"). Choose one, then test it."
                        let current = drafts[AnalyticsSource.searchConsole.key] ?? prefs.analyticsAccounts[AnalyticsSource.searchConsole.key] ?? ""
                        if current.isEmpty, let first = sites.first { drafts[AnalyticsSource.searchConsole.key] = first.siteURL }
                    }
                }
            } catch {
                await MainActor.run { searchConsoleLoading = false; searchConsoleNote = error.localizedDescription }
            }
        }
    }

    private func refreshSearchConsole() {
        saveSearchConsole()
        guard let property = prefs.analyticsAccounts[AnalyticsSource.searchConsole.key], GA4AnalyticsConfig.hasToken else { return }
        searchConsoleLoading = true
        Task {
            do {
                let comparison = try await SearchConsoleAnalytics.pullComparison(siteURL: property, window: searchConsoleWindow)
                await MainActor.run {
                    searchConsoleComparison = comparison; searchConsoleLoading = false
                    ga4HasToken = GA4AnalyticsConfig.hasToken
                    ga4Refreshable = GA4AnalyticsConfig.hasRefreshableCredential
                    searchConsoleNote = "✓ Live Search Console periods pulled from the selected property."
                }
            } catch {
                await MainActor.run { searchConsoleLoading = false; searchConsoleNote = error.localizedDescription }
            }
        }
    }

    #if os(macOS) && DIRECT_DISTRIBUTION
    private func connectGA4() {
        let property = (drafts[AnalyticsSource.ga4.key] ?? prefs.analyticsAccounts[AnalyticsSource.ga4.key] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalizedProperty = GA4Analytics.normalizePropertyID(property) else {
            ga4Note = GA4AnalyticsError.invalidPropertyID.localizedDescription; return
        }
        let clientID = ga4ClientIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else { ga4Note = GA4AnalyticsError.missingClientID.localizedDescription; return }
        prefs.analyticsAccounts[AnalyticsSource.ga4.key] = normalizedProperty
        drafts[AnalyticsSource.ga4.key] = normalizedProperty
        GA4AnalyticsConfig.clientID = clientID
        ga4Loading = true
        ga4Note = "Opening Google consent in your browser…"
        GA4OAuth.shared.connect(clientID: clientID) { result in
            switch result {
            case .failure(let error):
                ga4Loading = false; ga4Note = error.localizedDescription
            case .success:
                ga4HasToken = true; ga4Refreshable = true
                ga4Note = "Google authorized. Verifying a real GA4 read…"
                refreshGA4(saveFirst: false)
            }
        }
    }
    #endif

    private func refreshGA4(saveFirst: Bool = true) {
        if saveFirst { saveGA4() }
        guard let property = prefs.analyticsAccounts[AnalyticsSource.ga4.key],
              GA4AnalyticsConfig.hasToken else { return }
        ga4Loading = true
        Task {
            do {
                let comparison = try await GA4Analytics.pullComparison(propertyID: property, window: ga4Window)
                await MainActor.run {
                    ga4Comparison = comparison; ga4Result = comparison.current; ga4Loading = false
                    ga4HasToken = GA4AnalyticsConfig.hasToken
                    ga4Refreshable = GA4AnalyticsConfig.hasRefreshableCredential
                    ga4Note = "✓ Live GA4 periods pulled and compared from your property."
                }
            } catch {
                await MainActor.run { ga4Loading = false; ga4Note = error.localizedDescription }
            }
        }
    }

    private func disconnectGA4() {
        GA4AnalyticsConfig.disconnect()
        GA4AnalyticsConfig.clearResult()
        SearchConsoleAnalyticsConfig.clearResult()
        prefs.analyticsAccounts[AnalyticsSource.ga4.key] = nil
        drafts[AnalyticsSource.ga4.key] = ""
        ga4HasToken = false; ga4Refreshable = false; ga4Result = nil; ga4Comparison = nil
        searchConsoleComparison = nil; searchConsoleSites = []; ga4Note = "Disconnected."
    }
}
#endif // circuit-convert
