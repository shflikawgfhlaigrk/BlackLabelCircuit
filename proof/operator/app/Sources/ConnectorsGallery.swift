#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — CONNECTOR GALLERY. The one-click integrations grid shown in Settings → Connectors.
// Renders the SHIP-EMPTY ConnectorCatalog as tiles, each with REAL live status read from MCPManager
// (idle / connecting / connected N tools / failed). Only providers marked `available` connect in this
// build; the rest are honestly disabled ("Not yet available"), NEVER a fabricated connection. GitHub
// connects with the buyer's OWN token, stored only in Sovereign's private credential directory —
// never in mcp.json, never bundled.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ConnectorGallery: View {
    @EnvironmentObject var mcp: MCPManager
    @EnvironmentObject var demo: DemoMode
    @State private var tokenEntry: ConnectorEntry?
    @State private var oauthEntry: ConnectorEntry?
    @State private var showManualAdd = false
    @State private var googleOAuthClientID = ""
    @State private var slackOAuthClientID = ""
    @State private var setupMessage = ""

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 12)]
    private let googleConnectorIDs = ["gmail", "gdrive", "gcal"]

    private var connectedCount: Int {
        liveConnectedRows.count
    }
    private var configuredCount: Int {
        ConnectorCatalog.all.filter { $0.authKind != .customMCP && mcp.isConnectorConnected(id: $0.id) }.count
    }
    private var liveConnectedRows: [String] {
        ConnectorCatalog.all.filter { entry in
            if case .connected = mcp.connectorStatus(id: entry.id) { return true }
            return false
        }.map(\.displayName).sorted()
    }
    private var savedGoogleClientID: String? {
        googleConnectorIDs.compactMap { OAuthClientStore.clientID($0) }.first
    }
    private var savedSlackClientID: String? {
        OAuthClientStore.clientID("slack")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.grid.2x2.fill").foregroundColor(BLTheme.sub).font(.system(size: 12))
                Text(configuredCount == 0
                     ? "No connectors yet. Connect one with your own token. It is stored in Sovereign’s private on-device credential directory and sent to that connector only as authentication; it is not bundled or written to mcp.json."
                     : "\(connectedCount) live · \(configuredCount) configured · status below is read live from each server, never simulated.")
                    .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            connectorReadinessPanel
            oauthSetupStrip
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ConnectorCatalog.all) { entry in tile(entry) }
            }
        }
        // Show live status for already-connected catalog connectors after relaunch — but never in Demo
        // Mode (no network there) and never re-dialing a manual server.
        .onAppear { loadOAuthSetupDrafts() }
        .task { if !demo.active { await mcp.refreshConnectors() } }
        .sheet(item: $tokenEntry) { e in ConnectorTokenSheet(entry: e).environmentObject(mcp).sheetCloseBar() }
        .sheet(item: $oauthEntry) { e in ConnectorOAuthSheet(entry: e).environmentObject(mcp).sheetCloseBar() }
        .sheet(isPresented: $showManualAdd) { MCPAddServerSheet().environmentObject(mcp).sheetCloseBar() }
    }

    private var connectorReadinessPanel: some View {
        let googleConnected = googleConnectorIDs.filter { id in
            if case .connected = mcp.connectorStatus(id: id) { return true }
            return false
        }
        let firstGooglePending = googleConnectorIDs.compactMap { ConnectorCatalog.entry($0) }.first { entry in
            if case .connected = mcp.connectorStatus(id: entry.id) { return false }
            return true
        }
        let googleIDReady = googleConnectorIDs.contains { OAuthClientStore.clientID($0) != nil }
        let slackEntry = ConnectorCatalog.entry("slack")
        let slackConnected: Bool = {
            if case .connected = mcp.connectorStatus(id: "slack") { return true }
            return false
        }()
        let slackIDReady = OAuthClientStore.clientID("slack") != nil
        let connectedToolRows = liveConnectedRows

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold)
                Text("Finish connector wiring").font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                StatusPill(text: connectedToolRows.isEmpty ? "Needs account" : "\(connectedToolRows.count) connected",
                           tint: connectedToolRows.isEmpty ? .orange : BLTheme.green)
            }
            Text("This is the human launch path for the same connector gates the installed proof checks: Google managed MCP sign-ins, Slack client setup, and live tool discovery.")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)

            readinessRow(icon: "g.circle.fill",
                         title: "Google MCP",
                         detail: "Gmail, Drive, Calendar connected \(googleConnected.count)/\(googleConnectorIDs.count). \(googleIDReady ? "Client ID saved; sign in to each Google service." : "Paste one Google Desktop client ID below first.")",
                         pill: googleConnected.count == googleConnectorIDs.count ? "Connected" : (googleIDReady ? "OAuth needed" : "Client ID needed"),
                         tint: googleConnected.count == googleConnectorIDs.count ? BLTheme.green : .orange,
                         buttonLabel: firstGooglePending == nil ? nil : (googleIDReady ? "Sign in \(firstGooglePending!.displayName)" : "Google Console"),
                         buttonIcon: googleIDReady ? "person.badge.key" : "arrow.up.right.square") {
                if let firstGooglePending, googleIDReady {
                    oauthEntry = firstGooglePending
                } else {
                    openURL(ConnectorCatalog.entry("gmail")?.providerSetupURL)
                }
            }

            readinessRow(icon: "number.square.fill",
                         title: "Slack MCP",
                         detail: slackConnected ? "Slack is connected and discovered through the live MCP server." : (slackIDReady ? "Client ID saved; finish the Slack OAuth sign-in." : "Create a Slack app, paste its client ID below, then sign in."),
                         pill: slackConnected ? "Connected" : (slackIDReady ? "OAuth needed" : "Client ID needed"),
                         tint: slackConnected ? BLTheme.green : .orange,
                         buttonLabel: slackConnected ? nil : (slackIDReady ? "Sign in Slack" : "Slack Apps"),
                         buttonIcon: slackIDReady ? "person.badge.key" : "arrow.up.right.square") {
                if let slackEntry, slackIDReady {
                    oauthEntry = slackEntry
                } else {
                    openURL(slackEntry?.providerSetupURL)
                }
            }

            readinessRow(icon: "point.3.connected.trianglepath.dotted",
                         title: "Connected tool surface",
                         detail: connectedToolRows.isEmpty ? "No live catalog connector tools are discovered yet." : connectedToolRows.joined(separator: ", "),
                         pill: connectedToolRows.isEmpty ? "None" : "Live",
                         tint: connectedToolRows.isEmpty ? BLTheme.sub : BLTheme.green,
                         buttonLabel: "Refresh",
                         buttonIcon: "arrow.clockwise") {
                Task { await mcp.refreshConnectors() }
            }
        }
        .padding(14)
        .background(BLTheme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder
    private func readinessRow(icon: String,
                              title: String,
                              detail: String,
                              pill: String,
                              tint: Color,
                              buttonLabel: String? = nil,
                              buttonIcon: String = "arrow.right",
                              action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(BLTheme.gold)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(detail).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            StatusPill(text: pill, tint: tint)
            if let buttonLabel, let action {
                GoldButton(label: buttonLabel, icon: buttonIcon) { action() }
                    .disabled(demo.active)
                    .opacity(demo.active ? 0.5 : 1)
            }
        }
        .padding(10)
        .background(BLTheme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private var oauthSetupStrip: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key.fill").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold)
                Text("OAuth account setup").font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                StatusPill(text: savedGoogleClientID == nil ? "Google ID needed" : "Google ID saved",
                           tint: savedGoogleClientID == nil ? .orange : BLTheme.green)
                StatusPill(text: savedSlackClientID == nil ? "Slack ID needed" : "Slack ID saved",
                           tint: savedSlackClientID == nil ? .orange : BLTheme.green)
            }
            HStack(alignment: .bottom, spacing: 10) {
                Field(title: "Google OAuth client ID", text: $googleOAuthClientID, prompt: "your-id.apps.googleusercontent.com")
                    .frame(minWidth: 260)
                GoldButton(label: "Save Google ID", icon: "checkmark") { saveGoogleOAuthClientID() }
                    .disabled(demo.active || googleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(demo.active || googleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                GhostButton(label: "Google Console", icon: "arrow.up.right.square", tint: BLTheme.gold) {
                    openURL(ConnectorCatalog.entry("gmail")?.providerSetupURL)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Field(title: "Slack OAuth client ID", text: $slackOAuthClientID, prompt: "Slack app client ID")
                    .frame(minWidth: 260)
                GoldButton(label: "Save Slack ID", icon: "checkmark") { saveSlackOAuthClientID() }
                    .disabled(demo.active || slackOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(demo.active || slackOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                GhostButton(label: "Slack Apps", icon: "arrow.up.right.square", tint: BLTheme.gold) {
                    openURL(ConnectorCatalog.entry("slack")?.providerSetupURL)
                }
            }
            if !setupMessage.isEmpty {
                Text(setupMessage)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(BLTheme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func loadOAuthSetupDrafts() {
        googleOAuthClientID = savedGoogleClientID ?? googleOAuthClientID
        slackOAuthClientID = savedSlackClientID ?? slackOAuthClientID
    }

    private func saveGoogleOAuthClientID() {
        let cleaned = googleOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        for id in googleConnectorIDs {
            OAuthClientStore.setClientID(id, cleaned)
        }
        googleOAuthClientID = cleaned
        setupMessage = "Saved Google client ID for Gmail, Drive, and Calendar."
    }

    private func saveSlackOAuthClientID() {
        let cleaned = slackOAuthClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        OAuthClientStore.setClientID("slack", cleaned)
        slackOAuthClientID = cleaned
        setupMessage = "Saved Slack client ID."
    }

    private func openURL(_ raw: String?) {
        #if os(macOS)
        if let raw, let url = URL(string: raw) { NSWorkspace.shared.open(url) }
        #endif
    }

    @ViewBuilder private func tile(_ e: ConnectorEntry) -> some View {
        let configured = mcp.isConnectorConnected(id: e.id)
        let st = mcp.connectorStatus(id: e.id)
        let liveConnected: Bool = {
            if case .connected = st { return true }
            return false
        }()
        HoloCard(cornerRadius: 14, sweep: liveConnected, padding: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: e.iconSystemName).font(.system(size: 14, weight: .bold))
                        .foregroundColor(liveConnected ? BLTheme.ink : BLTheme.sub)
                        .frame(width: 34, height: 34)
                        .background(liveConnected ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.displayName).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text(e.category.label).font(BLTheme.mono(8, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                    }
                    Spacer()
                    StatusPill(text: statusText(e), tint: statusTint(e))
                }
                Text(e.blurb).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 30, alignment: .topLeading)
                if case .failed(let why) = st {
                    Text(why).font(.system(size: 10, design: .rounded)).foregroundColor(.orange)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                controls(e, configured: configured, status: st)
            }
        }
    }

    @ViewBuilder private func controls(_ e: ConnectorEntry, configured: Bool, status st: MCPManager.ServerStatus) -> some View {
        HStack(spacing: 8) {
            if e.authKind == .customMCP {
                GoldButton(label: "Add server", icon: "plus") { showManualAdd = true }
            } else if !e.available {
                GhostButton(label: "Not yet available", icon: "clock", tint: BLTheme.sub) {}
                    .disabled(true).opacity(0.55)
            } else if configured {
                if case .connecting = st {
                    ProgressView().controlSize(.small).tint(BLTheme.gold)
                } else {
                    GhostButton(label: "Refresh", icon: "arrow.clockwise", tint: BLTheme.gold) {
                        if let s = mcp.connectorServer(id: e.id) { Task { await mcp.discover(s) } }
                    }
                }
                if case .connected = st {
                    EmptyView()
                } else {
                    GhostButton(label: "Recover older credential", icon: "key.horizontal", tint: BLTheme.gold) {
                        Task { _ = await mcp.recoverLegacyCredential(for: e) }
                    }
                    .disabled(demo.active).opacity(demo.active ? 0.5 : 1)
                    GoldButton(label: e.authKind == .oauth2 ? "Reconnect" : "Replace token", icon: "link") {
                        if e.authKind == .oauth2 { oauthEntry = e } else { tokenEntry = e }
                    }
                    .disabled(demo.active).opacity(demo.active ? 0.5 : 1)
                }
                GhostButton(label: "Disconnect", icon: "xmark", tint: BLTheme.danger) { mcp.disconnectCatalog(e) }
            } else {
                // OAuth connectors present the sign-in sheet (ASWebAuthenticationSession); token
                // connectors keep the paste-your-token sheet exactly as before.
                GoldButton(label: e.authKind == .oauth2 ? "Sign in" : "Connect", icon: "link") {
                    if e.authKind == .oauth2 { oauthEntry = e } else { tokenEntry = e }
                }
                .disabled(demo.active).opacity(demo.active ? 0.5 : 1)
            }
            Spacer()
        }
    }

    private func statusText(_ e: ConnectorEntry) -> String {
        if e.authKind == .customMCP { return "Manual" }
        if !e.available { return "Soon" }
        switch mcp.connectorStatus(id: e.id) {
        case .idle:             return mcp.isConnectorConnected(id: e.id) ? "Needs proof" : "Not connected"
        case .connecting:       return "Connecting…"
        case .connected(let n): return "\(n) tool\(n == 1 ? "" : "s")"
        case .failed:           return mcp.isConnectorConnected(id: e.id) ? "Reconnect" : "Failed"
        }
    }
    private func statusTint(_ e: ConnectorEntry) -> Color {
        if e.authKind == .customMCP { return BLTheme.sub }
        if !e.available { return BLTheme.sub }
        switch mcp.connectorStatus(id: e.id) {
        case .connected:  return BLTheme.green
        case .failed:     return .orange
        case .connecting: return BLTheme.gold
        case .idle:       return mcp.isConnectorConnected(id: e.id) ? .orange : BLTheme.sub
        }
    }
}

// MARK: - Token sheet (the buyer pastes THEIR own token — privately stored, proven by a real call)
struct ConnectorTokenSheet: View {
    let entry: ConnectorEntry
    @EnvironmentObject var mcp: MCPManager
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var connecting = false
    @State private var result = ""        // honest live result of the last attempt (never faked)
    @State private var ok = false

    private var canConnect: Bool { !connecting && !token.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: entry.iconSystemName).font(.system(size: 16, weight: .bold)).foregroundColor(BLTheme.gold)
                Text("Connect \(entry.displayName)").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            }
            Text(entry.blurb).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            if let setup = entry.providerSetupURL {
                // Cross-platform: Compat.swift shims NSWorkspace on iOS, so the provider page opens
                // there too — the token field is unfillable without it.
                Button {
                    if let u = URL(string: setup) { NSWorkspace.shared.open(u) }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                        Text("Create a \(entry.tokenLabel.isEmpty ? "token" : entry.tokenLabel) on \(entry.displayName)")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    }.foregroundColor(BLTheme.gold)
                }.buttonStyle(.plain)
            }
            Text((entry.tokenLabel.isEmpty ? "token" : entry.tokenLabel).uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(1)
            SecureField("paste your token", text: $token)
                .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundColor(BLTheme.text)
                .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
            Text("Stored in Sovereign’s private on-device credential directory and sent to \(entry.displayName) only as authentication — not bundled or written to mcp.json. We verify it with one real call before showing “Connected.”")
                .font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            if !result.isEmpty {
                Text(result).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(ok ? BLTheme.green : .orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                GhostButton(label: "Cancel", icon: "xmark", tint: BLTheme.sub) { dismiss() }
                Spacer()
                if connecting { ProgressView().controlSize(.small).tint(BLTheme.gold) }
                GoldButton(label: "Connect", icon: "checkmark") { connect() }
                    .disabled(!canConnect).opacity(canConnect ? 1 : 0.5)
            }
        }
        .padding(24).sheetWidth(470).background(BLTheme.bg)
    }

    private func connect() {
        guard canConnect else { return }
        connecting = true; result = ""
        Task { @MainActor in
            await mcp.connectCatalog(entry, token: token)
            connecting = false
            switch mcp.connectorStatus(id: entry.id) {
            case .connected(let n):
                ok = true
                result = "Connected — discovered \(n) real tool\(n == 1 ? "" : "s")."
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            case .failed(let why):
                ok = false; result = why
            default:
                ok = false; result = "Could not verify the connection. Check the token and try again."
            }
        }
    }
}
#endif // circuit-convert
