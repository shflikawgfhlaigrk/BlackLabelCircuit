#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Bundled Node runtime (architecture reality check)

/// Decides whether an on-disk executable can actually run on THIS machine.
///
/// `FileManager.isExecutableFile` only reads the permission bit. Build 53 copied Node from the
/// build host, so an Apple-silicon build could contain an **arm64-thin** runtime while the app itself
/// was universal. Build 58 vendors both slices, but this runtime check remains a defense against a
/// damaged, substituted, or non-bundled developer copy. A config pointing at an unrunnable command
/// is worse than no config: the failure surfaces inside Claude, far from this app, with no
/// explanation.
///
/// So read the Mach-O header instead of trusting the mode bits. No subprocess is spawned: this is
/// evaluated from SwiftUI view state and must stay cheap and side-effect free.
enum BundledNodeRuntime {
    /// CPU type this process is running as (`cpu_type_t` values from `<mach-o/machine.h>`).
    static var nativeCPUType: UInt32 {
        #if arch(arm64)
        return 0x0100_000c   // CPU_TYPE_ARM64
        #elseif arch(x86_64)
        return 0x0100_0007   // CPU_TYPE_X86_64
        #else
        return 0
        #endif
    }

    /// True when `path` is a Mach-O carrying a slice for `nativeCPUType`.
    /// False for a missing file, a script, or a thin binary built for the other architecture.
    static func hasNativeSlice(atPath path: String) -> Bool {
        let want = nativeCPUType
        guard want != 0,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return false }
        let bytes = [UInt8](head)

        func be32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
                 | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
        }
        func le32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return (UInt32(bytes[offset + 3]) << 24) | (UInt32(bytes[offset + 2]) << 16)
                 | (UInt32(bytes[offset + 1]) << 8) | UInt32(bytes[offset])
        }

        // Universal ("fat") binary: header and arch table are big-endian by definition.
        // 0xcafebabe = 32-bit entries, 0xcafebabf = 64-bit entries.
        if let magic = be32(0), magic == 0xcafe_babe || magic == 0xcafe_babf {
            let entrySize = (magic == 0xcafe_babe) ? 20 : 32
            guard let count = be32(4), count > 0, count < 64 else { return false }
            for index in 0..<Int(count) {
                guard let cpu = be32(8 + index * entrySize) else { return false }
                if cpu == want { return true }
            }
            return false
        }
        // Thin Mach-O: 0xfeedfacf (64-bit) / 0xfeedface (32-bit), little-endian on every
        // architecture Apple still ships. cputype is the word right after the magic.
        if let magic = le32(0), magic == 0xfeed_facf || magic == 0xfeed_face {
            return le32(4) == want
        }
        return false
    }
}

// MARK: - Dashboard (live rollups from saved data)
struct DashboardScreen: View {
    @EnvironmentObject var model: AppModel
    var go: (Section) -> Void = { _ in }
    let cols = [GridItem(.adaptive(minimum: BLScale.cardMin(240, spacing: 16)), spacing: 16)]
    private var isEmptyApp: Bool { model.deals.isEmpty && model.leads.isEmpty && model.buyers.isEmpty }
    @State private var reveal = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: "Command Center", subtitle: "Live rollups from your own pipeline — nothing fabricated")
                if isEmptyApp { onboarding }
                LazyVGrid(columns: cols, spacing: 16) {
                    MetricCard(label: "Active deals", number: Double(model.activeDeals.count), fmt: { String(Int($0)) }, icon: "house.fill", accent: BLTheme.gold)
                    MetricCard(label: "Pipeline profit", number: model.pipelineProfit, fmt: { REMath.money($0) }, icon: "dollarsign.circle.fill", accent: BLTheme.green, hero: true)
                    MetricCard(label: "Leads", number: Double(model.leads.count), fmt: { String(Int($0)) }, icon: "person.3.fill", accent: BLTheme.gold)
                    MetricCard(label: "Equity at MAO", number: model.totalEquityAtMAO, fmt: { REMath.money($0) }, icon: "chart.line.uptrend.xyaxis", accent: .blue)
                }
                .opacity(reveal ? 1 : 0).offset(y: reveal ? 0 : 14)
                AdaptiveStack(spacing: 16) {
                    Panel(title: "Deal pipeline", icon: "chart.bar.fill", glow: true) {
                        if model.deals.isEmpty {
                            EmptyState(icon: "chart.bar.doc.horizontal", title: "No deals yet", hint: "Source a lead, then promote it to a deal — pipeline and projected profit populate here.")
                                .padding(.vertical, 8)
                        } else {
                            ForEach(DealStatus.allCases) { s in
                                let n = model.count(s)
                                if n > 0 { PipelineRow(label: s.label, tint: s.tint, count: n, total: model.deals.count) }
                            }
                        }
                    }
                    Panel(title: "CRM funnel", icon: "person.3.fill") {
                        if model.leads.isEmpty {
                            EmptyState(icon: "person.3.sequence", title: "No leads captured", hint: "Build a list from the property database and save the owners you want to work — they land here.")
                                .padding(.vertical, 8)
                        } else {
                            ForEach(LeadStatus.allCases) { s in
                                let n = model.leadCount(s)
                                if n > 0 { PipelineRow(label: s.label, tint: s.tint, count: n, total: max(1, model.leads.count)) }
                            }
                        }
                    }
                }
                .opacity(reveal ? 1 : 0).offset(y: reveal ? 0 : 18)
            }.blScreenPadding(28)
        }
        .background(ParticleField().opacity(0.7))   // capped gold motes behind the dashboard
        .onAppear { withAnimation(.spring(response: 0.7, dampingFraction: 0.85).delay(0.05)) { reveal = true } }
    }
    private var onboarding: some View {
        Panel(title: "Start here", icon: "sparkles", glow: true) {
            Text("The property database is already loaded — real public records across the country. Three steps to your first deal, no lists to paste or upload:")
                .font(BLFont.body(12.5, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            AdaptiveStack(spacing: 12) {
                stepCard(1, "Build a list", "Absentee, probate, vacant, high equity — straight from the database", "square.stack.3d.up.fill") { go(.lists) }
                stepCard(2, "Explore the map", "Real parcel pins for any area, live from the index", "mappin.and.ellipse") { go(.map) }
                stepCard(3, "Analyze & offer", "ARV, MAO, ROI, then an LOI", "function") { go(.analyzer) }
            }
        }
    }
    @ViewBuilder private func stepCard(_ n: Int, _ title: String, _ sub: String, _ icon: String, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack { IconBadge(system: icon, size: 30); Spacer(); Text("\(n)").font(BLFont.mono(13, .bold)).foregroundColor(BLTheme.gold) }
                Text(title).font(.blSystem(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(sub).font(.blSystem(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

// Premium hero stat card — gradient wash, glowing icon chip, holographic tilt surface, and a
// rolling AnimatedCounter value (when given a numeric `number:` + `fmt:`). The legacy `value:`
// init renders a static string for non-numeric stats.
struct MetricCard: View {
    let label: String; let icon: String; var accent: Color = BLTheme.gold; var hero = false
    private let number: Double?
    private let fmt: (Double) -> String
    private let staticValue: String?

    /// Numeric stat — value animates on change via AnimatedCounter.
    init(label: String, number: Double, fmt: @escaping (Double) -> String, icon: String, accent: Color = BLTheme.gold, hero: Bool = false) {
        self.label = label; self.number = number; self.fmt = fmt; self.staticValue = nil
        self.icon = icon; self.accent = accent; self.hero = hero
    }
    /// Static stat — pre-formatted string (e.g. percentages, non-rolling values).
    init(label: String, value: String, icon: String, accent: Color = BLTheme.gold, hero: Bool = false) {
        self.label = label; self.number = nil; self.fmt = { _ in value }; self.staticValue = value
        self.icon = icon; self.accent = accent; self.hero = hero
    }

    private var valueFont: Font { .blSystem(size: hero ? 30 : 28, weight: .heavy, design: .rounded) }
    var body: some View {
        VStack(alignment: .leading, spacing: BLScale.isCompact ? 8 : 12) {
            HStack { IconBadge(system: icon, size: BLScale.isCompact ? 26 : 32, active: false); Spacer() }
            Group {
                if let n = number {
                    AnimatedCounter(value: n, format: fmt, font: valueFont)
                        .foregroundStyle(hero ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.text))
                } else {
                    Text(staticValue ?? "")
                        .font(valueFont)
                        .foregroundStyle(hero ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.text))
                }
            }
            .minimumScaleFactor(0.6).lineLimit(1)
            Text(label.uppercased()).font(.blSystem(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.8)
        }
        .blPadding(BLScale.isCompact ? 14 : 20).frame(maxWidth: .infinity, alignment: .leading)
        .background(RadialGradient(colors: [accent.opacity(hero ? 0.16 : 0.08), .clear], center: .topLeading, startRadius: 0, endRadius: 200))
        .holoCard(radius: 18, sweep: hero)
    }
}

// Pipeline distribution row with mini progress bar.
struct PipelineRow: View {
    let label: String; let tint: Color; let count: Int; let total: Int
    var body: some View {
        HStack(spacing: 12) {
            StatusPill(text: label, tint: tint)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(BLTheme.bg2).frame(height: 6)
                    Capsule().fill(tint.opacity(0.85)).frame(width: max(6, geo.size.width * CGFloat(count) / CGFloat(max(1, total))), height: 6)
                        .shadow(color: tint.opacity(0.5), radius: 3)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 14)
            Text("\(count)").font(.blSystem(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).frame(minWidth: 22, alignment: .trailing)
        }
    }
}

// Deals, Deal Analyzer, My Leads, Pipeline, Offers, Dispositions, Analytics, and
// Global Search live in their own files (DealScreens.swift, LeadScreens.swift, etc.).

// MARK: - Calculators
struct CalculatorsScreen: View {
    @State private var loan = "240000"; @State private var apr = "6.75"; @State private var years = "30"
    @State private var noi = "24000"; @State private var price = "300000"
    @State private var cf = "6000"; @State private var cash = "60000"
    let cols = [GridItem(.adaptive(minimum: BLScale.cardMin(320, spacing: 16)), spacing: 16)]
    private var pi: Double { REMath.monthlyPI(principal: Double(loan) ?? 0, apr: Double(apr) ?? 0, years: Double(years) ?? 0) }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 20) {
            SectionHeader(title: "Calculators", subtitle: "Financing and return math, computed live")
            LazyVGrid(columns: cols, spacing: 16) {
                Panel(title: "Mortgage Payment", icon: "percent") {
                    HStack(spacing: 10) { Field(title: "Loan", text: $loan); Field(title: "APR %", text: $apr); Field(title: "Years", text: $years) }
                    Stat(label: "Monthly P&I", value: REMath.money(pi), big: true)
                    Stat(label: "Total interest", value: REMath.money(pi * (Double(years) ?? 0) * 12 - (Double(loan) ?? 0)))
                }
                Panel(title: "Cap Rate", icon: "building.2.fill") {
                    HStack(spacing: 10) { Field(title: "Annual NOI", text: $noi); Field(title: "Price", text: $price) }
                    Stat(label: "Cap rate", value: REMath.pct(REMath.capRate(noi: Double(noi) ?? 0, price: Double(price) ?? 0)), big: true)
                }
                Panel(title: "Cash-on-Cash", icon: "banknote.fill") {
                    HStack(spacing: 10) { Field(title: "Annual cash flow", text: $cf); Field(title: "Cash invested", text: $cash) }
                    Stat(label: "Cash-on-cash", value: REMath.pct(REMath.cashOnCash(annualCashFlow: Double(cf) ?? 0, cashInvested: Double(cash) ?? 0)), big: true)
                }
            }
        }.blScreenPadding(24) }
    }
}

// MARK: - Settings (full customization surface — branding, criteria, params, routes, profiles)
struct SettingsScreen: View {
    @EnvironmentObject var session: Session
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: SettingsStore
    @State private var confirmDelete = false
    /// Full erase (account + workspace + settings + every connected-provider credential).
    @State private var confirmWipe = false
    @State private var googleClientID = UserDefaults.standard.string(forKey: GoogleAuth.clientIDDefaultsKey) ?? ""
    @State private var savedCID = false
    @State private var newCounty = ""
    @State private var profileName = ""
    @State private var newMemberName = ""
    @State private var newMemberRole = "Acquisitions"
    // Buyer-registered county source (Markets & Counties)
    @State private var ccName = ""; @State private var ccURL = ""
    @State private var ccOwner = ""; @State private var ccAddr = ""; @State private var ccParcel = ""
    @State private var ccValue = ""; @State private var ccLand = ""; @State private var ccImprov = ""
    @State private var ccError = ""; @State private var ccSaved = ""
    @State private var customCounties = CustomCountyStore.names
    // Lead Database (public-records API) connection. Presence is read from the prompt-free private
    // store. Security.framework remains reachable only through the explicit recovery action.
    @State private var leadDBToken = ""
    /// The connected/not-connected SIGNAL the un-prefilled field would otherwise lose. Sourced from
    /// `Keychain.hasLeadDBTokenResult()`, an EXISTENCE-only probe that never returns the secret — so the
    /// buyer can still see whether a key is saved without this screen ever holding one.
    @State private var leadDBKeySaved = false
    @State private var leadDBBaseURL = UserDefaults.standard.string(forKey: APIConfig.baseURLDefaultsKey) ?? ""
    @State private var leadDBTesting = false
    @State private var leadDBStatus = ""          // honest result line (count or error)
    @State private var leadDBStatusOK = false
    @State private var recoveringLegacyCredentials = false
    @State private var legacyCredentialRecoveryNote = ""
    /// Truthful confirmation line for the diagnostics export (set from exportTextFile's return —
    /// never claims a save that didn't happen).
    @State private var diagnosticsExportNote = ""

    // MARK: - Diagnostics (user-accessible support surface; no Terminal, no secrets)

    private var appVersionBadge: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(v) (\(b))"
    }

    /// The support snapshot. PRESENCE, COUNTS and VERSIONS only — deliberately never a key, token,
    /// email, address, or workspace record, so the file is always safe to hand to support.
    private func diagnosticsReport() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let bundleID = Bundle.main.bundleIdentifier ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let skipVendors = SkipTraceKeychain.connectedVendors()
        let lines: [String] = [
            "BLACK LABEL REAL ESTATE — DIAGNOSTICS",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "App: \(bundleID) \(version) (build \(build))",
            "OS: \(os)",
            "",
            "SIGN-IN",
            "  Sign in with Apple entitlement: \(AppleAuth.isAvailable ? "present in this build" : "not in this build (button hidden by design)")",
            "  Google client ID configured: \(googleClientID.trimmingCharacters(in: .whitespaces).isEmpty ? "no" : "yes")",
            "  Mode: \(session.demoMode ? "Sample Mode (synthetic workspace)" : (session.email == "guest" ? "guest" : "account"))",
            "",
            "INTEGRATIONS (presence only — keys are never included)",
            "  Lead Database key saved: \(leadDBKeySaved ? "yes" : "no (capped preview tier)")",
            "  Lead Database base URL override: \(leadDBBaseURL.trimmingCharacters(in: .whitespaces).isEmpty ? "no (shipped default)" : "yes")",
            "  Skip-trace vendors connected: \(skipVendors.isEmpty ? "none" : skipVendors.map { $0.rawValue }.joined(separator: ", "))",
            "  Direct-mail vendor key saved: \(MailVendorKeychain.hasKey() ? "yes" : "no")",
            "  Telephony provider details saved: \(model.phoneProvider.connected ? "yes (sending not enabled in this build)" : "no")",
            "  MCP server bundled: \(mcpServerPresent ? "yes" : "no")",
            "  MCP integrity manifest: \(mcpManifestStatusText)",
            "  Node.js runtime detected: \(detectedNodePath ?? "not found")",
            "",
            "WORKSPACE (counts only)",
            "  Leads: \(model.leads.count) · Deals: \(model.deals.count) · Offers: \(model.offers.count) · Buyers: \(model.buyers.count)",
            "  Custom county sources registered: \(customCounties.count)",
            "",
            "Everything above is presence/count/version truth. No credentials, addresses,",
            "owner names or workspace records are included in this file.",
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - Claude / MCP (local control surface)

    /// One capability row. `gated` mirrors what the server actually refuses, not a chosen adjective.
    private struct MCPCapability { let tool: String; let gated: Bool; let detail: String }

    private var mcpCapabilities: [MCPCapability] {
        [
            MCPCapability(tool: "search_parcels", gated: false,
                          detail: "Searches the public-records parcel index by location, owner, category or assessed-value band. Returns real county rows only — it never geocodes, infers, or invents a parcel."),
            MCPCapability(tool: "get_comps", gated: false,
                          detail: "Recorded sold comparables from the county deed roll. Rows with no priced sale are dropped BEFORE any median is computed, with the full drop accounting returned — it never medians over nulls."),
            MCPCapability(tool: "calc_arv", gated: false,
                          detail: "Derives ARV from recorded sold comps. Refuses with arv:null and a machine-readable reason when the data is too thin. In non-disclosure states (GA, AL, TX) no sale prices are published, so the sold-comp basis cannot fire and it says so."),
            MCPCapability(tool: "plan_route", gated: false,
                          detail: "Orders up to 60 stops into a drive route through the local optimizer. A stop it cannot place is returned as unroutable — it never fabricates a coordinate."),
            MCPCapability(tool: "get_property_audit", gated: false,
                          detail: "Read-only. Returns an audit that was already computed and stored; it never recomputes or backfills one, and a parcel with no stored audit reports that plainly."),
        ]
    }

    /// The MCP server SHIPPED INSIDE this app bundle (Contents/Resources/server.mjs — vendored from
    /// the API repo by build.command / the Xcode resources phase; see mcp/README.md). This used to
    /// point at ~/BlackLabelRealEstateAPI/mcp/server.mjs, a developer-only path that nothing
    /// installs, downloads, or creates on a buyer's Mac — so the config the panel printed could
    /// never work for a customer. Resolving through the bundle means the file the config names is
    /// the file the buyer already has.
    private var mcpServerURL: URL? { Bundle.main.url(forResource: "server", withExtension: "mjs") }

    /// True when the MCP server is actually present in this bundle. Reported honestly — a missing
    /// server is stated rather than implied to exist because the panel rendered.
    private var mcpServerPresent: Bool { mcpServerURL != nil }

    private var mcpServerPath: String { mcpServerURL?.path ?? "" }
    private var mcpManifestURL: URL? { Bundle.main.url(forResource: "mcp-manifest", withExtension: "json") }
    private var mcpManifestMap: [String: String] {
        guard let url = mcpManifestURL,
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = json["files"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for key in ["server.mjs", "mcp-kit.mjs", "arv.mjs"] {
            guard let val = files[key] as? String else { continue }
            out[key] = val
        }
        return out
    }
    private var mcpManifestValid: Bool {
        let required = ["server.mjs", "mcp-kit.mjs", "arv.mjs"]
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        return required.allSatisfy { key in
            guard let digest = mcpManifestMap[key] else { return false }
            return digest.count == 64 && digest.unicodeScalars.allSatisfy { hex.contains($0) }
        }
    }
    private var mcpManifestStatusText: String {
        guard mcpManifestURL != nil else { return "not in this build" }
        guard mcpManifestValid else { return "present, but not valid" }
        return "present and valid"
    }
    private var mcpConnectorRunnable: Bool { mcpServerPresent && mcpManifestValid }

    /// Where Claude will look for `node` when it launches the bundled server.
    /// The server binary is shipped with this app, so a bundled runtime is preferred
    /// when it can actually run on THIS Mac. The legacy install paths are still shown as
    /// fallback for non-bundled developer builds and for architectures the bundled
    /// runtime does not cover.
    private static let nodeSearchPaths = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    /// The runtime this build ships, if it ships one AND it can run on this machine.
    /// A bundled runtime is only offered when it carries a slice for this architecture —
    /// `isExecutableFile` is a permission bit, not an exec guarantee.
    private var bundledNodePath: String? {
        guard let bundled = Bundle.main.url(forResource: "node", withExtension: nil)?.path,
              FileManager.default.isExecutableFile(atPath: bundled),
              BundledNodeRuntime.hasNativeSlice(atPath: bundled) else { return nil }
        return bundled
    }
    private var usingBundledNodeRuntime: Bool { bundledNodePath != nil }
    private var detectedNodePath: String? {
        // System paths are NOT arch-filtered: an x86_64 Node on Apple Silicon runs under Rosetta,
        // and refusing a runtime the buyer already uses would break a working connector.
        bundledNodePath ?? Self.nodeSearchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The block to paste into Claude's MCP settings. Emitted ONLY when the server is really in the
    /// bundle — a config naming a path that does not exist is worse than no config at all.
    private var mcpClaudeConfig: String? {
        guard mcpConnectorRunnable else { return nil }
        return """
        {
          "mcpServers": {
            "blbestate": {
              "command": "\(mcpNodeCommand)",
              "args": ["\(mcpServerPath)"]
            }
          }
        }
        """
    }

    /// Command used in the copied Claude MCP config.
    private var mcpNodeCommand: String {
        detectedNodePath ?? "node"
    }

    private var claudeMCPPanel: some View {
        Panel(title: "Claude / MCP", icon: "terminal.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Drive this app's public-records engine from Claude. The MCP server runs on this Mac and Claude connects to it — nothing about this connector sends your pipeline, your leads, or your deals to Black Label or to anyone else.")
                    .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("MCP server").font(BLFont.body(12.5, .bold)).foregroundColor(BLTheme.text)
                    StatusPill(text: mcpServerPresent ? "Included in this app" : "Not in this build",
                               tint: mcpServerPresent ? BLTheme.green : BLTheme.sub)
                    Spacer()
                    if let cfg = mcpClaudeConfig {
                        GhostButton(label: "Copy Claude config", icon: "doc.on.doc", tint: BLTheme.gold) {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(cfg, forType: .string)
                        }
                    } else if mcpServerPresent {
                        Text("Cannot publish Claude config: MCP integrity manifest is missing or invalid.")
                            .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
                    }
                }

                if let cfg = mcpClaudeConfig {
                    // The old copy here — "nothing to download or install" — was FALSE on a clean
                    // machine: the server file ships, but Node.js is not always shipped. The
                    // "runtime is included in this build" line was then claimed on the strength of
                    // detectedNodePath alone, which is ALSO true when the detected runtime is the
                    // buyer's own Node — so the app credited itself for an install the buyer did.
                    // Say which one is actually in play.
                    Text(detectedNodePath == nil
                         ? "The MCP server file ships inside this app. It runs under Node.js, which Claude launches — this app never starts it. Install Node.js on this \(kThisDeviceWord), then copy the config."
                         : (usingBundledNodeRuntime
                            ? "The MCP server file ships inside this app and so does the Node.js runtime it needs. Claude launches that runtime to run the server with no extra install required."
                            : "The MCP server file ships inside this app. It runs under the Node.js already installed on this \(kThisDeviceWord), which Claude launches — this app never starts it."))
                        .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Text("Node.js runtime").font(BLFont.body(12, .bold)).foregroundColor(BLTheme.text)
                        if let node = detectedNodePath {
                            StatusPill(text: "Found", tint: BLTheme.green)
                            Text(node).font(BLFont.mono(10, .medium)).foregroundColor(BLTheme.sub).lineLimit(1)
                        } else {
                            StatusPill(text: "Not found", tint: BLTheme.gold)
                            Text("Install Node.js, then paste the config and restart Claude.")
                                .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
                        }
                        Spacer()
                    }
                    if !mcpConnectorRunnable {
                        HStack(spacing: 8) {
                            Text("MCP integrity manifest").font(BLFont.body(12, .bold)).foregroundColor(BLTheme.text)
                            StatusPill(text: mcpManifestStatusText, tint: BLTheme.gold)
                            Spacer()
                        }
                    }

                    Text(detectedNodePath == nil ? "Once Node.js is present: paste this into Claude's MCP settings and restart Claude." : "Copy this into Claude's MCP settings and restart Claude.")
                        .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(cfg)
                        .font(BLFont.mono(10, .medium)).foregroundColor(BLTheme.sub)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                } else {
                    // No config is shown when the bundle has no server: printing one would name a
                    // path that does not exist and the connector would silently never start.
                    Text("This copy of the app does not include the MCP server, so there is no configuration to paste and the connector cannot run. The tools below describe what the connector does when it is included.")
                        .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("What Claude can do through it")
                    .font(BLFont.body(12, .bold)).foregroundColor(BLTheme.text)

                ForEach(mcpCapabilities, id: \.tool) { cap in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(cap.tool).font(BLFont.mono(11, .bold)).foregroundColor(BLTheme.text)
                            StatusPill(text: cap.gated ? "Gated off" : "Read-only",
                                       tint: cap.gated ? BLTheme.sub : BLTheme.green)
                            Spacer()
                        }
                        Text(cap.detail).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                }

                Text("Every tool here is READ-ONLY against public records. None of them contacts an owner, sends mail, moves money, or changes your pipeline — those stay in your hands, in this app.")
                    .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var d: Binding<SettingsData> { $settings.data }
    private func addMember() {
        let n = newMemberName.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        var m = TeamMember(); m.name = n; m.role = newMemberRole.trimmingCharacters(in: .whitespaces).isEmpty ? "Acquisitions" : newMemberRole
        model.upsert(m); newMemberName = ""; newMemberRole = "Acquisitions"
    }

    var body: some View {
        ScrollView { LazyVStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Settings", subtitle: "Tailor every part of the product — branding, targets, valuation, routes, profiles")

            // REAL ESTATE PRO SUBSCRIPTION — the app's ONE in-app purchase, always on screen.
            //
            // Deliberately first, and deliberately NOT conditioned on entitlement, sample/demo
            // state, or sign-in. Every other paywall route in the app sits behind a gated action,
            // which is how App Review reached Guideline 2.1(b) on iOS 1.1 (22) — the products
            // "could not be found". A permanent row cannot be missed the same way, and it is the
            // screen the App Review purchase recording is made from. Store builds only: the
            // Developer-ID macOS build sells nothing through StoreKit (3.1.1) and has its own
            // trial surface in Trial.swift.
            #if os(iOS) || MAS_BUILD
            REProSubscriptionPanel()
            #endif

            // BRANDING / IDENTITY
            Panel(title: "Branding & identity", icon: "paintpalette.fill", glow: true) {
                Field(title: "Workspace name", text: d.workspaceName, prompt: "Your company")
                Field(title: "Tagline", text: d.tagline, prompt: "Shown on the sign-in screen")
                Toggle(isOn: d.useSerifDisplay) { Text("Serif display headlines (Cormorant Garamond)").font(BLFont.body(12.5, .semibold)) }.toggleStyle(.switch).tint(BLTheme.gold)
                Toggle(isOn: d.motionEnabled) { Text("Premium ambient motion (shimmer, sheen, drift)").font(BLFont.body(12.5, .semibold)) }.toggleStyle(.switch).tint(BLTheme.gold)
                Text("Fine-tune the holographic look (accent, intensity, motion, particles, background, tilt, glow, presets) in the Theme Studio below. Motion always pauses when the system Reduce Motion setting is on.")
                    .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }

            // CLAUDE / MCP — a LOCAL control surface, deliberately not a data-sharing row.
            //
            // Every credential panel below describes something this app reaches OUT to. The MCP is
            // the reverse: a server on this Mac that Claude connects INTO, which then calls the same
            // read-only public-records paths the app itself uses. Nothing about it ships buyer data
            // to Black Label. It is stated that way here rather than implied.
            //
            // The refusals listed are the SERVER's, not marketing copy: the estate tools return
            // provenance and drop accounting on every result, refuse with a machine reason instead
            // of inventing a number, and mark a zero result verified-empty rather than empty-looking.
            //
            // macOS ONLY: the server runs under Node.js, which iOS cannot run, and project.yml
            // bundles mcp/ into the Mac target alone — on iPhone this panel could only ever render
            // a dead "Not in this build" surface with instructions the device cannot follow.
            #if os(macOS)
            claudeMCPPanel
            #endif

            // THEME / APPEARANCE STUDIO — full holographic customization with a live preview.
            ThemeStudioPanel()

            // DATA SOURCES / COUNTIES
            Panel(title: "Data sources & counties", icon: "map.circle.fill") {
                Field(title: "Preferred market", text: d.preferredMarket, prompt: "Atlanta, GA")
                Text("TARGET COUNTIES").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
                if settings.data.targetCounties.isEmpty {
                    Text("None yet — add the counties you source.").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
                } else {
                    WrapChips(items: settings.data.targetCounties) { c in settings.data.targetCounties.removeAll { $0 == c } }
                }
                HStack(spacing: 8) {
                    TextField("Add county", text: $newCounty).textFieldStyle(.plain).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                        .onSubmit(addCounty)
                    GhostButton(label: "Add", icon: "plus", tint: BLTheme.gold, action: addCounty)
                }
            }

            // MARKETS & COUNTIES — connected parcel coverage + buyer-registered custom layers.
            marketsAndCountiesPanel

            // PROBATE + BUILDER TARGET CRITERIA
            Panel(title: "Probate & builder criteria", icon: "doc.text.magnifyingglass") {
                Text("PROBATE SOURCES (matched on saved leads)").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                WrapChips(items: settings.data.probateSources) { s in settings.data.probateSources.removeAll { $0 == s } }
                Field(title: "Lead qualifier note", text: d.minLeadScoreNote, prompt: "e.g. equity > 40%, owner out of state")
                Divider().overlay(BLTheme.stroke)
                HStack(spacing: 12) {
                    StepperField(label: "Builder min units", value: d.builderMinUnits, range: 1...500, step: 1)
                    SliderField(label: "Builder radius", value: d.builderRadiusMi, range: 5...100, unit: "mi")
                }
            }

            // 3-MILE / ARV PARAMETERS
            Panel(title: "Radius & valuation", icon: "scope") {
                SliderField(label: "Comparable radius", value: d.radiusMiles, range: 0.5...10, unit: "mi")
                SliderField(label: "Max-allowable-offer rule", value: d.maoPercent, range: 50...90, unit: "%")
                Field(title: "ARV source label", text: d.arvSourceNote, prompt: "County-assessed / fair-market value")
                Text("MAO drives the Deals editor's offer math. ARV shown is your stated source — never a fabricated comp average.")
                    .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }

            // ROUTE / CANVASS OPTIONS
            Panel(title: "Route & canvass", icon: "map.fill") {
                Field(title: "Depot / start address", text: d.depotAddress, prompt: "Your office address")
                VStack(alignment: .leading, spacing: 6) {
                    Text("DEFAULT MODE").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
                    Picker("", selection: d.routeMode) { ForEach(RouteMode.allCases) { Text($0.label).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                }
                SliderField(label: "Avg drive speed", value: d.avgSpeedMph, range: 15...65, unit: "mph")
            }

            // TEAM / LEAD ROUTING
            Panel(title: "Team & lead routing", icon: "person.2.fill") {
                Text("Add teammates (acquisitions, dispo, VAs) and choose how NEW leads get an owner. Single-user? Leave it empty — leads stay unassigned.")
                    .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("AUTO-ASSIGN NEW LEADS").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
                    Picker("", selection: $model.assignStrategy) { ForEach(AssignStrategy.allCases) { Text($0.label).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                }
                Divider().overlay(BLTheme.stroke)
                if model.team.isEmpty {
                    Text("No teammates yet.").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
                } else {
                    ForEach(model.team) { m in
                        HStack(spacing: 10) {
                            Text(m.initials).font(BLFont.mono(11, .bold)).foregroundColor(BLTheme.ink).frame(width: 28, height: 28).background(m.active ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.name).font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
                                Text("\(m.role)\(m.email.isEmpty ? "" : " · \(m.email)") · \(model.leadCount(assignedTo: m.id)) leads").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).lineLimit(1)
                            }
                            Spacer()
                            Toggle(isOn: Binding(get: { m.active }, set: { var x = m; x.active = $0; model.upsert(x) })) { Text("Active").font(BLFont.body(10.5, .medium)) }.toggleStyle(.switch).tint(BLTheme.gold).controlSize(.mini)
                            GhostButton(label: "Remove", icon: "trash", tint: BL.danger) { model.deleteMember(m) }
                        }
                        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                }
                HStack(spacing: 8) {
                    TextField("Name", text: $newMemberName).textFieldStyle(.plain).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    TextField("Role", text: $newMemberRole).textFieldStyle(.plain).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.text).frame(width: 130)
                        .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                        .onSubmit(addMember)
                    GhostButton(label: "Add", icon: "person.badge.plus", tint: BLTheme.gold, action: addMember)
                }
            }

            // SAVED PROFILES
            Panel(title: "Saved profiles", icon: "square.stack.3d.up.fill") {
                HStack(spacing: 8) {
                    TextField("Profile name", text: $profileName).textFieldStyle(.plain).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    GoldButton(label: "Save current", icon: "tray.and.arrow.down") { settings.saveCurrentAsProfile(named: profileName); profileName = "" }
                }
                if settings.profiles.isEmpty {
                    Text("Save the current settings as a reusable profile (e.g. \"Atlanta probate\", \"North GA fleet\").")
                        .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
                } else {
                    ForEach(settings.profiles) { p in
                        HStack(spacing: 10) {
                            IconBadge(system: "bookmark.fill", size: 30, active: false)
                            Text(p.name).font(BLFont.body(13.5, .semibold)).foregroundColor(BLTheme.text)
                            Spacer()
                            GhostButton(label: "Apply", icon: "arrow.down.circle", tint: BLTheme.gold) { withAnimation { settings.apply(p) } }
                            GhostButton(label: "Delete", icon: "trash", tint: BL.danger) { settings.deleteProfile(p) }
                        }
                        .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                }
            }

            // LEAD DATABASE — public-records API connection (token + optional base URL override).
            leadDatabasePanel

            Panel(title: "Saved credential recovery", icon: "key.viewfinder") {
                Text("Earlier builds saved connected-provider keys and remembered sessions in macOS Keychain. Use this one-time action only if an upgrade no longer sees them. macOS may ask you to authorize access; the original Keychain items are left unchanged.")
                    .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                GhostButton(label: recoveringLegacyCredentials ? "Checking macOS Keychain…" : "Recover saved credentials from macOS Keychain…",
                            icon: "key.viewfinder", tint: BLTheme.gold) {
                    recoverLegacyCredentials()
                }
                .disabled(recoveringLegacyCredentials)
                if !legacyCredentialRecoveryNote.isEmpty {
                    Text(legacyCredentialRecoveryNote)
                        .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // SIGN-IN PROVIDERS (Google + Apple) — prominent, real status.
            Panel(title: "Sign-in", icon: "person.badge.key.fill", glow: true) {
                // GOOGLE — the client-ID field is the prominent control (this is what enables the button).
                HStack(spacing: 8) {
                    Image(systemName: "globe").font(.blSystem(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                    Text("Google").font(BLFont.body(14, .bold)).foregroundColor(BLTheme.text)
                    Spacer()
                    let live = !(UserDefaults.standard.string(forKey: GoogleAuth.clientIDDefaultsKey) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    StatusPill(text: live ? "Enabled" : "Add client ID", tint: live ? BLTheme.green : BLTheme.gold)
                }
                Text("Paste a Google OAuth Desktop client ID to enable Sign in with Google. A Web client will NOT work for the native flow — create a \"Desktop app\" OAuth client in Google Cloud Console. Stored privately on this \(kThisDeviceWord); never uploaded.")
                    .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                Field(title: "Google client ID", text: $googleClientID, prompt: "xxxxx.apps.googleusercontent.com")
                    .onChangeCompat(of: googleClientID) { _ in if savedCID { withAnimation { savedCID = false } } }
                HStack(spacing: 10) {
                    GoldButton(label: "Save client ID", icon: "checkmark") {
                        let v = googleClientID.trimmingCharacters(in: .whitespacesAndNewlines)
                        UserDefaults.standard.set(v, forKey: GoogleAuth.clientIDDefaultsKey)
                        withAnimation { savedCID = true }
                    }
                    GhostButton(label: "Clear", icon: "xmark", tint: BLTheme.sub) {
                        googleClientID = ""
                        UserDefaults.standard.removeObject(forKey: GoogleAuth.clientIDDefaultsKey)
                        withAnimation { savedCID = false }
                    }
                    if savedCID { Text("Saved").font(BLFont.body(12, .bold)).foregroundColor(BLTheme.green) }
                }

                Divider().overlay(BLTheme.stroke)

                // APPLE — status only, and only the truth about THIS artifact: the entitlement is
                // either in the running binary's signature or it isn't. When it isn't, the sign-in
                // screen hides the Apple button entirely (AuthProviders.appleVisible) rather than
                // offering a flow this build cannot complete.
                HStack(spacing: 8) {
                    Image(systemName: "apple.logo").font(.blSystem(size: 14, weight: .bold)).foregroundColor(BLTheme.text)
                    Text("Apple").font(BLFont.body(14, .bold)).foregroundColor(BLTheme.text)
                    Spacer()
                    StatusPill(text: AppleAuth.isAvailable ? "Active" : "Not in this build",
                               tint: AppleAuth.isAvailable ? BLTheme.green : BLTheme.sub)
                }
                Text(AppleAuth.isAvailable
                     ? "Sign in with Apple is active on this build."
                     : "This build is not signed with the Sign-in-with-Apple entitlement, so the Apple button is not shown on the sign-in screen. Use Google, email and password, or continue as a guest. The Mac App Store and iOS releases are signed with the entitlement and show the real Apple button.")
                    .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }

            // ACCOUNT
            Panel(title: "Account", icon: "person.crop.circle") {
                Stat(label: "Signed in as", value: session.email.isEmpty ? "guest" : session.email)
                HStack(spacing: 10) {
                    GhostButton(label: "Sign out", icon: "rectangle.portrait.and.arrow.right") { withAnimation { session.signOut() } }
                    if session.email != "guest" && !session.email.isEmpty {
                        GhostButton(label: "Delete account", icon: "trash", tint: BL.danger) { confirmDelete = true }
                    }
                }
                // FULL ERASE. The credentials-only delete above leaves the workspace and every
                // connected-provider key in place, which is not what "delete my account" means to a
                // reviewer or a buyer. This one really erases: the local workspace blob, the
                // settings blob, the buyer-registered county sources, and every provider credential
                // in private local storage.
                GhostButton(label: "Delete account & local data", icon: "trash.fill", tint: BL.danger) { confirmWipe = true }
                Text("Erases the saved workspace (deals, leads, offers, drafts), all settings and saved profiles, your registered county sources, and every connected-provider key (skip trace, direct mail, telephony, Lead Database token) stored on this \(kThisDeviceWord). This cannot be undone.")
                    .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }

            // DIAGNOSTICS — the user-accessible support surface (DOD-7.6) with a one-click export
            // (DOD-11.5). Everything shown/exported is presence/count/version truth only — never a
            // key, token, address, or any workspace record. No Terminal, no development tools.
            Panel(title: "Diagnostics", icon: "stethoscope") {
                Text("A snapshot of this install for support: version, platform, and which integrations are connected (never the keys themselves, and never your workspace records). Export it as a text file to attach to a support request.")
                    .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                Text(diagnosticsReport())
                    .font(BLFont.mono(10, .medium)).foregroundColor(BLTheme.sub)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                HStack {
                    GhostButton(label: "Export diagnostics…", icon: "square.and.arrow.up", tint: BLTheme.gold) {
                        diagnosticsExportNote = exportTextFile(
                            suggestedName: "BlackLabelRealEstate-diagnostics.txt",
                            contents: diagnosticsReport()) ?? ""
                    }
                    if !diagnosticsExportNote.isEmpty {
                        Label(diagnosticsExportNote, systemImage: "checkmark.circle.fill")
                            .font(BLFont.body(11.5, .bold)).foregroundColor(BLTheme.green)
                    }
                    Spacer()
                }
            }

            Panel(title: "About", icon: "info.circle") {
                HStack { Text(settings.data.workspaceName).font(BLFont.display(15, .semibold)).foregroundColor(BLTheme.text); FoilBadge(text: appVersionBadge) }
                Text("Deal analysis, probate lead capture, 3-mile sourcing, route optimization, and financing math. Your workspace is stored privately on this \(kThisDeviceWord) and is never uploaded to Black Label. Data leaves this \(kThisDeviceWord) only when you trigger it: a skip trace sends the owner name and address to the provider you connected, a letter send transmits the recipient address and letter body to your mail provider, and parcel/comp lookups and route geocoding query public-records and mapping services.")
                    .font(BLFont.body(12.5, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
        }.blScreenPadding(24) }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { AccountStore.delete(session.email); withAnimation { session.signOut() } }
        } message: { Text("This permanently removes your account credentials from this device. Your saved deals and leads remain in the app's local store — use \"Delete account & local data\" to erase those too.") }
        .alert("Delete your account and erase all local data?", isPresented: $confirmWipe) {
            Button("Cancel", role: .cancel) {}
            Button("Erase everything", role: .destructive) { withAnimation { eraseAccountAndLocalData() } }
        } message: { Text("This permanently erases your saved workspace, settings, saved profiles, registered county sources and every connected-provider key stored on this \(kThisDeviceWord). It cannot be undone.") }
        .onAppear { refreshLeadDBCredentialStatus() }
    }

    /// The REAL account-deletion path. Every line here removes something that actually persists —
    /// no dialog-only theatre. Order matters: local stores first, then credentials, then sign-out
    /// (which tears down the session that the screen's state is bound to).
    private func eraseAccountAndLocalData() {
        // 1. Local account credential for the signed-in email (hash in UserDefaults).
        if !session.email.isEmpty && session.email != "guest" { AccountStore.delete(session.email) }
        // 2. Workspace blob — deals, leads, offers, drafts, buyers, lists, sequences.
        model.startEmptyGuestWorkspace()
        // 3. Settings blob — all settings, saved profiles, saved looks.
        settings.eraseAll()
        // 4. Connected-provider credentials in private local storage.
        SkipTraceKeychain.clearAll()
        MailVendorKeychain.clear()
        ProviderKeychain.clear()
        Keychain.setLeadDBToken(nil)
        SessionStore.clear()
        // 5. Buyer-entered local configuration held in UserDefaults.
        CustomCountyStore.save([:])
        UserDefaults.standard.removeObject(forKey: GoogleAuth.clientIDDefaultsKey)
        UserDefaults.standard.removeObject(forKey: APIConfig.baseURLDefaultsKey)
        // 6. Make the erase VISIBLE in this screen instead of leaving stale values on screen.
        googleClientID = ""; savedCID = false
        leadDBToken = ""; leadDBBaseURL = ""; leadDBStatus = "Erased — no token stored on this \(kThisDeviceWord)."
        refreshLeadDBCredentialStatus()
        customCounties = CustomCountyStore.names
        newCounty = ""; profileName = ""
        // 7. Finally drop the session.
        session.signOut()
    }

    private func addCounty() {
        let c = newCounty.trimmingCharacters(in: .whitespaces).capitalized
        guard !c.isEmpty, !settings.data.targetCounties.contains(c) else { return }
        settings.data.targetCounties.append(c); newCounty = ""
    }

    // MARK: Markets & Counties — connected parcel coverage + a buyer-registered custom layer.
    // Lets a buyer point the product at ANY open ArcGIS parcel layer (owner/addr/parcel/value plus
    // optional land + improvement fields). Registering a land+improvement layer immediately turns on
    // the teardown scout for that market — coverage becomes user-expandable, not developer-gated.
    private var marketsAndCountiesPanel: some View {
        Panel(title: "Markets & counties (parcel coverage)", icon: "map.circle.fill", glow: true) {
            // Connected coverage — real status from the live registry (built-in + custom), never faked.
            Text("CONNECTED PARCEL LAYERS").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
            ForEach(ParcelRegistry.coveredCounties, id: \.self) { c in
                HStack(spacing: 8) {
                    Image(systemName: "mappin.circle.fill").font(.blSystem(size: 13)).foregroundColor(BLTheme.gold)
                    Text(c).font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
                    if !ParcelRegistry.isBuiltIn(c) { FoilBadge(text: "Yours") }
                    Spacer()
                    if TeardownScout.canScout(c) { StatusPill(text: "Teardown-ready", tint: BLTheme.green) }
                    else { StatusPill(text: "Owner + value", tint: BLTheme.sub) }
                    if !ParcelRegistry.isBuiltIn(c) {
                        GhostButton(label: "Remove", icon: "trash", tint: BL.danger) {
                            CustomCountyStore.remove(c); customCounties = CustomCountyStore.names; ccSaved = ""
                        }
                    }
                }
                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
            }
            Text("\(TeardownScout.scoutableCounties.count) of these publish the assessor's land + improvement split, so the teardown / lot-flip scout runs there. Add your own below.")
                .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            Divider().overlay(BLTheme.stroke)

            // Register a custom layer.
            Text("REGISTER A COUNTY (OPEN ARCGIS PARCEL LAYER)").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.gold).tracking(0.6)
            Text("Paste your county's open ArcGIS parcel query endpoint and the exact field names from its schema. Adding land + improvement fields enables the teardown scout for that market. Stored only on this \(kThisDeviceWord).")
                .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            Field(title: "County name", text: $ccName, prompt: "e.g. Gwinnett")
            Field(title: "Layer query URL", text: $ccURL, prompt: "https://…/FeatureServer/0/query")
            HStack(spacing: 10) {
                Field(title: "Owner field", text: $ccOwner, prompt: "OWNER")
                Field(title: "Address field", text: $ccAddr, prompt: "SITE_ADDRESS")
            }
            HStack(spacing: 10) {
                Field(title: "Parcel-ID field", text: $ccParcel, prompt: "PIN")
                Field(title: "Value field (optional)", text: $ccValue, prompt: "TOTAL_VALUE")
            }
            HStack(spacing: 10) {
                Field(title: "Land-value field (teardown)", text: $ccLand, prompt: "LAND_VAL")
                Field(title: "Improvement field (teardown)", text: $ccImprov, prompt: "BLDG_VAL")
            }
            if !ccError.isEmpty { Label(ccError, systemImage: "exclamationmark.triangle.fill").font(BLFont.body(11.5, .semibold)).foregroundColor(BL.danger).fixedSize(horizontal: false, vertical: true) }
            if !ccSaved.isEmpty { Label(ccSaved, systemImage: "checkmark.circle.fill").font(BLFont.body(11.5, .bold)).foregroundColor(BLTheme.green) }
            HStack(spacing: 10) {
                GoldButton(label: "Register county", icon: "plus.circle.fill") { registerCounty() }
                GhostButton(label: "Clear", icon: "xmark", tint: BLTheme.sub) { clearCountyForm() }
                Spacer()
            }
        }
    }

    private func registerCounty() {
        ccError = ""; ccSaved = ""
        if let reason = CustomCountyStore.upsert(name: ccName, url: ccURL, ownerField: ccOwner,
                                                 addrField: ccAddr, parcelField: ccParcel,
                                                 valueField: ccValue, landField: ccLand, improvementField: ccImprov) {
            ccError = reason; return
        }
        let nm = ccName.trimmingCharacters(in: .whitespaces).capitalized
        let scout = TeardownScout.canScout(nm)
        customCounties = CustomCountyStore.names
        ccSaved = "\(nm) connected." + (scout ? " Teardown scout is now live for it." : " Add land + improvement fields to enable the teardown scout.")
        clearCountyForm(keepMessage: true)
    }
    private func clearCountyForm(keepMessage: Bool = false) {
        ccName = ""; ccURL = ""; ccOwner = ""; ccAddr = ""; ccParcel = ""; ccValue = ""; ccLand = ""; ccImprov = ""
        if !keepMessage { ccError = ""; ccSaved = "" }
    }

    // MARK: Lead Database — connect the public-records API (access key + optional base URL).
    // The key (blre_… / storefront key) raises the row-cap tier; it is stored privately, never
    // uploaded. "Test connection" calls the live /v1/health and shows the real property count or an
    // honest error — nothing is faked. Only PUBLIC query params ever leave this device.
    private var leadDatabasePanel: some View {
        Panel(title: "Lead Database (public records)", icon: "cylinder.split.1x2.fill", glow: true) {
            Text("Connect to the Black Label public-records index to search owners, parcels, addresses and assessed values across covered states. Your access key raises your row limit (preview / pro / founder). The key is stored privately on this \(kThisDeviceWord) — never uploaded. Only public query terms (state, county, owner, address, ZIP) are ever sent.")
                .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Text("ACCESS KEY").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                SecureField("Enter a new key (blank keeps the saved key)", text: $leadDBToken)
                    .textFieldStyle(.plain).font(BLFont.body(13.5, .medium)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 11).padding(.horizontal, 13)
                    .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                Label(leadDBKeySaved
                        ? "A key is saved on this \(kThisDeviceWord) — leave this blank to keep it, or type a new one to replace it."
                        : "No key saved on this \(kThisDeviceWord) — searches run on the capped preview tier.",
                      systemImage: leadDBKeySaved ? "key.fill" : "key.slash")
                    .font(BLFont.body(11, .medium))
                    .foregroundColor(leadDBKeySaved ? BLTheme.green : BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Optional base-URL override. Default is the shipped production Worker; paste a value
            // here only to point at a staging/alternate endpoint without a rebuild.
            Field(title: "API base URL (optional)", text: $leadDBBaseURL, prompt: APIConfig.prodDefault.absoluteString)
            Text("Leave blank to use the Black Label production endpoint (\(APIConfig.prodDefault.absoluteString)). Paste an alternate URL here to override it.")
                .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            if !leadDBStatus.isEmpty {
                Label(leadDBStatus, systemImage: leadDBStatusOK ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(BLFont.body(12, .bold)).foregroundColor(leadDBStatusOK ? BLTheme.green : BL.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                GoldButton(label: leadDBTesting ? "Testing…" : "Test connection", icon: "antenna.radiowaves.left.and.right") {
                    saveAndTestLeadDB()
                }
                GhostButton(label: "Save", icon: "checkmark", tint: BLTheme.gold) { saveLeadDB() }
                GhostButton(label: "Clear", icon: "xmark", tint: BLTheme.sub) {
                    leadDBToken = ""; leadDBBaseURL = ""
                    switch Keychain.setLeadDBToken(nil) {
                    case .success:
                        APIConfig.setBaseURLOverride(nil)
                        refreshLeadDBCredentialStatus()
                        leadDBStatus = "Cleared."; leadDBStatusOK = true
                        NotificationCenter.default.post(name: .blreLeadDBTokenChanged, object: nil)
                    case .failure(let error):
                        leadDBStatus = error.localizedDescription; leadDBStatusOK = false
                    }
                }
                Spacer()
            }
        }
    }

    private func saveLeadDB() {
        guard saveLeadDBCredentialIfEntered() else { return }
        refreshLeadDBCredentialStatus()
        if let reason = APIConfig.setBaseURLOverride(leadDBBaseURL) {
            leadDBStatus = reason; leadDBStatusOK = false
        } else {
            leadDBStatus = "Saved."; leadDBStatusOK = true
        }
        // Live list screens re-run their current query so the new tier cap applies now.
        NotificationCenter.default.post(name: .blreLeadDBTokenChanged, object: nil)
    }

    private func saveAndTestLeadDB() {
        // Persist first so health() reads the key + base the buyer just typed.
        guard saveLeadDBCredentialIfEntered() else { return }
        refreshLeadDBCredentialStatus()
        if let reason = APIConfig.setBaseURLOverride(leadDBBaseURL) {
            leadDBStatus = reason; leadDBStatusOK = false; return
        }
        NotificationCenter.default.post(name: .blreLeadDBTokenChanged, object: nil)
        leadDBTesting = true; leadDBStatus = ""; leadDBStatusOK = false
        Task {
            do {
                let h = try await RealEstateAPI.health()
                await MainActor.run {
                    leadDBTesting = false
                    if h.ok == true || h.properties != nil {
                        leadDBStatusOK = true
                        if let n = h.properties {
                            leadDBStatus = "Connected — \(n.formatted()) properties available."
                        } else {
                            leadDBStatus = "Connected to the Lead Database."
                        }
                    } else {
                        leadDBStatusOK = false
                        leadDBStatus = "Reached the server but it reported not-ready."
                    }
                }
            } catch {
                await MainActor.run {
                    leadDBTesting = false; leadDBStatusOK = false
                    leadDBStatus = (error as? RealEstateAPIError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
    }

    private func saveLeadDBCredentialIfEntered() -> Bool {
        let token = leadDBToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return true }
        switch Keychain.setLeadDBToken(token) {
        case .success: return true
        case .failure(let error):
            leadDBStatus = error.localizedDescription
            leadDBStatusOK = false
            return false
        }
    }

    private func refreshLeadDBCredentialStatus() {
        switch Keychain.hasLeadDBTokenResult() {
        case .success(let saved): leadDBKeySaved = saved
        case .failure(let error):
            leadDBKeySaved = false
            leadDBStatus = error.localizedDescription
            leadDBStatusOK = false
        }
    }

    private func recoverLegacyCredentials() {
        recoveringLegacyCredentials = true
        legacyCredentialRecoveryNote = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let report = Keychain.recoverKnownLegacyAccounts()
            DispatchQueue.main.async {
                recoveringLegacyCredentials = false
                legacyCredentialRecoveryNote = report.summary
                refreshLeadDBCredentialStatus()
                session.restoreRememberedAsync()
            }
        }
    }
}

// MARK: - Theme / Appearance Studio
// Full holographic customization with a LIVE PREVIEW pane. Every control writes into the live
// `settings.data.holo`, which the whole FX kit reads — so changes apply app-wide instantly.
struct ThemeStudioPanel: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var presetName = ""
    @State private var customColor = Color(hex: 0xC9A961)

    // Two-way bindings into the persisted holo theme.
    private var h: Binding<HoloTheme> { Binding(get: { settings.data.holo }, set: { settings.setHolo($0) }) }

    // Built-in accent swatches the buyer can pick (drives accent + a sensible highlight/dim).
    private let swatches: [(String, UInt32, UInt32, UInt32)] = [
        ("Gold", 0xC9A961, 0xF9E27D, 0x8A7340), ("Champagne", 0xD4C5A0, 0xEFE6C9, 0xA8966F),
        ("Platinum", 0xD8DBE0, 0xFFFFFF, 0x9AA0A8), ("Emerald", 0x7DE2C3, 0xBFF7E6, 0x3E9C86),
        ("Cyan", 0x4FD7FF, 0xA6F0FF, 0x2E9BBF), ("Violet", 0x9C7DFF, 0xC9B7FF, 0x6A4FCB),
        ("Magenta", 0xFF5FE1, 0xFFB3F2, 0xB23F9F), ("Burgundy", 0x8B3A4A, 0xB85666, 0x6B2D3E),
    ]

    var body: some View {
        Panel(title: "Theme Studio", icon: "wand.and.stars", glow: true) {
            Text("Own the look. Every choice applies app-wide instantly — the preview is live.")
                .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)

            // ── LIVE PREVIEW (reads the same theme the rest of the app does) ──
            ThemePreview()
                .environment(\.holoTheme, settings.data.holo)
                .frame(height: 168)
                .padding(.bottom, 2)

            // PRESETS — one-click named looks.
            Text("PRESETS").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
            FlowLayout(spacing: 8) {
                ForEach(HoloTheme.presets, id: \.name) { p in
                    Button { withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { settings.setHolo(p.theme) } } label: {
                        HStack(spacing: 6) {
                            Circle().fill(p.theme.accent).frame(width: 12, height: 12)
                                .overlay(Circle().stroke(p.theme.accentHi.opacity(0.8), lineWidth: 1))
                            Text(p.name).font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.text)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 11)
                        .background(BLTheme.bg2).clipShape(Capsule())
                        .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }

            Divider().overlay(BLTheme.stroke)

            // ACCENT — preset swatches + custom picker.
            Text("ACCENT").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
            FlowLayout(spacing: 10) {
                ForEach(swatches, id: \.0) { name, c, hi, dim in
                    let on = settings.data.holo.accentHex == c
                    Button { withAnimation { var t = settings.data.holo; t.accentHex = c; t.accentHiHex = hi; t.accentDimHex = dim; settings.setHolo(t) } } label: {
                        Circle().fill(Color(hex: c)).frame(width: 26, height: 26)
                            .overlay(Circle().stroke(BLTheme.text.opacity(on ? 0.9 : 0), lineWidth: 2))
                            .shadow(color: Color(hex: c).opacity(0.5), radius: on ? 6 : 0)
                    }.buttonStyle(.plain).help(name)
                }
                ColorPicker("", selection: $customColor, supportsOpacity: false)
                    .labelsHidden().frame(width: 28)
                    .onChangeCompat(of: customColor) { newVal in
                        var t = settings.data.holo
                        t.accentHex = newVal.holoHex
                        t.accentHiHex = newVal.holoHex   // a tasteful highlight ≈ accent; kept simple + honest
                        t.accentDimHex = newVal.holoHex
                        settings.setHolo(t)
                    }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("IRIDESCENT HUE (borders & sheen)").font(BLFont.mono(9, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                HStack(spacing: 10) {
                    ForEach([(0x4FD7FF), (0x9C7DFF), (0xFF5FE1), (0x7DE2C3), (0xF9E27D)], id: \.self) { c in
                        let on = settings.data.holo.iridescentHex == UInt32(c)
                        Button { var t = settings.data.holo; t.iridescentHex = UInt32(c); settings.setHolo(t) } label: {
                            Circle().fill(Color(hex: UInt32(c))).frame(width: 20, height: 20)
                                .overlay(Circle().stroke(BLTheme.text.opacity(on ? 0.9 : 0), lineWidth: 2))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            Divider().overlay(BLTheme.stroke)

            // HOLO INTENSITY.
            VStack(alignment: .leading, spacing: 6) {
                Text("HOLO INTENSITY").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
                Picker("", selection: h.intensity) { ForEach(HoloIntensity.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().tint(BLTheme.gold)
            }
            // MOTION LEVEL.
            VStack(alignment: .leading, spacing: 6) {
                Text("MOTION LEVEL").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
                Picker("", selection: h.motion) { ForEach(HoloMotion.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().tint(BLTheme.gold)
                Text("Reduce Motion (macOS) always wins and freezes loops, no matter this setting.")
                    .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
            }
            // BACKGROUND STYLE.
            VStack(alignment: .leading, spacing: 6) {
                Text("BACKGROUND").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
                Picker("", selection: h.background) { ForEach(HoloBackground.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().tint(BLTheme.gold)
            }

            // PARTICLES / GLOW sliders.
            SliderField(label: "Particle density", value: h.particleDensity, range: 0...1, unit: "")
            SliderField(label: "Glow strength", value: h.glowStrength, range: 0...1, unit: "")

            // CARD TILT.
            Toggle(isOn: h.tiltEnabled) { Text("Card 3D tilt on hover").font(BLFont.body(12.5, .semibold)) }.toggleStyle(.switch).tint(BLTheme.gold)
            if settings.data.holo.tiltEnabled {
                SliderField(label: "Tilt strength", value: h.tiltStrength, range: 0...1, unit: "")
            }

            Divider().overlay(BLTheme.stroke)

            // SAVE / LOAD a custom look.
            Text("MY SAVED LOOKS").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
            HStack(spacing: 8) {
                TextField("Name this look", text: $presetName).textFieldStyle(.plain).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                GoldButton(label: "Save look", icon: "square.and.arrow.down") { settings.saveHoloPreset(named: presetName); presetName = "" }
            }
            if settings.holoPresets.isEmpty {
                Text("Save your current holographic look as a preset you can re-apply any time.").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
            } else {
                ForEach(settings.holoPresets) { p in
                    HStack(spacing: 10) {
                        Circle().fill(p.theme.accent).frame(width: 18, height: 18).overlay(Circle().stroke(p.theme.accentHi.opacity(0.8), lineWidth: 1))
                        Text(p.name).font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
                        Spacer()
                        GhostButton(label: "Apply", icon: "arrow.down.circle", tint: BLTheme.gold) { withAnimation { settings.applyHolo(p) } }
                        GhostButton(label: "Delete", icon: "trash", tint: BL.danger) { settings.deleteHoloPreset(p) }
                    }
                    .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                }
            }
            GhostButton(label: "Reset to Gold Vault", icon: "arrow.counterclockwise", tint: BLTheme.sub) {
                withAnimation { settings.setHolo(.goldVault) }
            }
        }
        .onAppear { customColor = settings.data.holo.accent }
    }
}

// A self-contained miniature of the app's signature surfaces, so the buyer SEES their look live.
// Everything here is a VISUAL SPECIMEN of the theme — the numbers are illustrative sample values
// (labelled "SAMPLE"), never the user's real pipeline/lead figures. Real metrics live on the
// Dashboard / Analytics screens and are always computed from the user's own data.
struct ThemePreview: View {
    @Environment(\.holoTheme) private var theme
    var body: some View {
        ZStack {
            AuroraBackdrop()
            ParticleField().opacity(0.9)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    FoilText("Black Label", size: 22, weight: .semibold)
                    Text("SAMPLE")
                        .font(BLFont.mono(7.5, .bold)).tracking(1).foregroundColor(BLTheme.ink)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(BLTheme.gold.opacity(0.85)).clipShape(Capsule())
                }
                HStack(spacing: 12) {
                    miniStat("$428K", "SAMPLE PIPELINE")
                    miniStat("17", "SAMPLE LEADS")
                }
                HStack(spacing: 8) {
                    Text("Primary action").font(BLFont.body(11.5, .bold)).foregroundColor(BLTheme.ink)
                        .padding(.vertical, 7).padding(.horizontal, 14)
                        .background(BLTheme.goldGrad).clipShape(Capsule())
                        .holoSheen().glowPulse()
                    HoloShimmerSkeleton(width: 90, height: 12)
                }
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }
    private func miniStat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(v).font(.blSystem(size: 18, weight: .heavy, design: .rounded)).foregroundStyle(BLTheme.goldGrad)
            Text(l).font(BLFont.mono(8, .bold)).foregroundColor(BLTheme.sub).tracking(1)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .holoCard(radius: 12, sweep: false)
    }
}

// Removable chip row used for counties / probate sources.
struct WrapChips: View {
    let items: [String]; let onRemove: (String) -> Void
    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 5) {
                    Text(item).font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.text)
                    Button { onRemove(item) } label: { Image(systemName: "xmark").font(.blSystem(size: 8, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                }
                .padding(.vertical, 5).padding(.horizontal, 10)
                .background(BLTheme.gold.opacity(0.12)).clipShape(Capsule())
                .overlay(Capsule().stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
            }
        }
    }
}

// Labelled integer stepper.
struct StepperField: View {
    let label: String; @Binding var value: Int; let range: ClosedRange<Int>; let step: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
            HStack {
                Text("\(value)").font(BLFont.mono(15, .bold)).foregroundColor(BLTheme.text)
                Spacer()
                Stepper("", value: $value, in: range, step: step).labelsHidden()
            }
            .padding(.vertical, 6).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Labelled slider with a live numeric readout.
struct SliderField: View {
    let label: String; @Binding var value: Double; let range: ClosedRange<Double>; let unit: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label.uppercased()).font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                Spacer()
                Text(String(format: value < 10 ? "%.1f%@" : "%.0f%@", value, unit)).font(BLFont.mono(13, .bold)).foregroundColor(BLTheme.gold)
            }
            Slider(value: $value, in: range).tint(BLTheme.gold)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Minimal flow layout for chips (wraps to the next line).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? 400
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
#endif // circuit-convert
