// iOSNav.swift — Phase-2 iPhone-native navigation.
//
// The macOS app uses a NavigationSplitView with a 14-row sidebar (see MainView in main.swift).
// On a 390pt-wide iPhone that sidebar pattern is wrong: the split view forces a wide canvas and
// the sidebar either overlaps content or hides the screens behind a hard-to-reach toggle.
//
// This file provides the iPhone-compact replacement: a bottom TabView with the 4 PRIMARY sections
// as tabs + a "More" tab that lists every remaining screen (and routes into it via a
// NavigationStack). It reuses the EXACT same screen views as macOS — only the chrome changes.
//
// Selection routes through the shared `Nav` object so ⌘K / .sovRoute deep-links and the
// dashboard's quickAction routes keep working on iOS too. The whole file is iOS-only
// (`#if os(iOS)`), so macOS never compiles it and stays byte-identical.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

#if os(iOS)

// MARK: - Shared screen renderer (the body that both macOS `detail` and iOS tabs show)
//
// Each route's screen, wrapped in the living holographic backdrop. Extracted so iOS tabs and the
// macOS detail pane render IDENTICAL screen content. (macOS keeps its own copy inline in MainView
// for now; this is the iOS-side renderer.)
struct RouteScreen: View {
    let route: AppRoute
    @EnvironmentObject var nav: Nav
    var body: some View {
        ZStack {
            AuroraBackdrop()
            HUDGrid().ignoresSafeArea().opacity(0.6)
            ParticleField().allowsHitTesting(false)
            Group {
                switch route {
                case .dashboard: DashboardScreen(route: Binding(get: { nav.route }, set: { nav.route = $0 }))
                case .brain: ChatScreen()
                case .agent: AgentScreen()
                case .agents: CustomAgentsScreen()
                case .prompts: PromptsScreen()
                case .knowledge: KnowledgeScreen()
                case .memory: MemoryScreen()
                case .skills: SkillsScreen()
                case .automate: AutomateScreen()
                case .activity: ActivityScreen()
                case .connectors: ConnectorsScreen()
                case .weather: WeatherScreen()
                case .help: HelpScreen()
                case .settings: SettingsScreen()
                }
            }
        }
    }
}

// MARK: - iPhone tab shell

struct iPhoneTabShell: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var settings: AppSettings
    @Environment(\.holoTheme) private var theme

    // The 4 primary tabs surfaced at the bottom. Everything else lives under "More".
    // (Operator / The Brain / My Agents / Activity are the highest-traffic daily surfaces.)
    static let tabRoutes: [AppRoute] = [.dashboard, .brain, .agents, .activity]
    private var moreRoutes: [AppRoute] {
        AppRoute.allCases.filter { !Self.tabRoutes.contains($0) }
    }

    // Map any route to the tab it belongs to so deep-links (⌘K equivalents, quick actions, the
    // dashboard's "route = .prompts" jumps) select the right tab — a non-tab route selects More
    // and is pushed onto More's stack.
    @State private var moreSelection: AppRoute? = nil

    // REAL selection storage. A purely computed binding derived from nav.route cannot represent
    // "More is frontmost" (More maps to no route), so tapping More would write nothing and the
    // next getter read would snap the selection back to the current route's tab. The tab index
    // owns the truth; nav.route is written on tab taps and read only for external route changes.
    @State private var tabSelection: Int = 0

    private var selectedTab: Binding<Int> {
        Binding(
            get: { tabSelection },
            set: { idx in
                tabSelection = idx
                if idx < Self.tabRoutes.count { nav.route = Self.tabRoutes[idx]; moreSelection = nil }
                // selecting "More": leave nav.route as-is; the More list drives further routing
            }
        )
    }

    /// Follow a programmatic route change (deep-link, quick action, ⌘K palette) into the right tab.
    private func syncTab(with route: AppRoute) {
        if let i = Self.tabRoutes.firstIndex(of: route) { tabSelection = i }
        else { tabSelection = Self.tabRoutes.count }
    }

    var body: some View {
        TabView(selection: selectedTab) {
            ForEach(Array(Self.tabRoutes.enumerated()), id: \.element) { idx, r in
                NavigationStack {
                    // No .navigationTitle here: every screen draws its own ScreenTitle header with
                    // the same word, so a nav-bar title would show the name twice stacked. The bar
                    // stays inline-compact and hosts only the search affordance.
                    RouteScreen(route: r)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { searchToolbar }
                }
                .tabItem { Label(r.title, systemImage: r.icon) }
                .tag(idx)
            }

            // MORE tab: a list of the remaining screens, each pushed onto a NavigationStack.
            NavigationStack {
                moreList
                    .navigationTitle("More")
                    .navigationDestination(item: $moreSelection) { r in
                        // Same rule as the tabs: the screen's own ScreenTitle is the sole title.
                        RouteScreen(route: r)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { searchToolbar }
                            .onAppear { nav.route = r }
                    }
            }
            .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
            .tag(Self.tabRoutes.count)
        }
        .tint(settings.accent)
        .onAppear { syncTab(with: nav.route) }
        // Keep the tab selection and More's pushed screen in sync when a route is set
        // programmatically (deep-link, dashboard quick action) to a non-tab route.
        .onChange(of: nav.route) { r in
            syncTab(with: r)
            if !Self.tabRoutes.contains(r) { moreSelection = r }
            else { moreSelection = nil }
        }
    }

    // The ⌘K command palette has no keyboard trigger on iPhone — surface it as a visible
    // search button in the nav bar of every screen (Requirement #3: keyboard-only paths need a
    // visible touch equivalent).
    @ToolbarContentBuilder private var searchToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { NotificationCenter.default.post(name: .sovCommandPalette, object: nil) } label: {
                Image(systemName: "magnifyingglass")
            }
            .accessibilityLabel("Search and jump")
        }
    }

    private var moreList: some View {
        List {
            Section {
                ForEach(moreRoutes) { r in
                    Button { moreSelection = r; nav.route = r } label: {
                        HStack(spacing: 14) {
                            Image(systemName: r.icon)
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(theme.accent)
                                .frame(width: 30, height: 30)
                                .background(theme.accent.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Text(r.title)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundColor(BLTheme.text)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(BLTheme.sub)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())   // full-row tap target (>= 44pt)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(BLTheme.bg2)
                }
            } header: {
                Text("All sections").foregroundColor(BLTheme.sub)
            }
        }
        .scrollContentBackground(.hidden)
        .background(BLTheme.bg)
    }
}

#endif
