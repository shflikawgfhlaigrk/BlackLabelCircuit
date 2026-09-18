#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — OAUTH CONNECT SHEET. The sign-in surface for `.oauth2` catalog connectors (Linear now;
// Slack / Google / OneDrive in later units), shown by ConnectorGallery instead of the paste-a-token
// sheet. It runs the SHARED OAuthConnector flow (OAuthCore.swift): discover endpoints → register/resolve
// the client_id → ASWebAuthenticationSession sign-in → token exchange → a REAL tools/list round-trip.
//
// HONESTY (CHARTER §5.1 / §5.2): nothing is "connected" until a real access_token is exchanged AND the
// real handshake discovers ≥0 tools. The result line is the live tool count or the real error — never a
// fabricated "Connected". The access token lives in the Keychain only; no secret is shown or stored on disk.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ConnectorOAuthSheet: View {
    let entry: ConnectorEntry
    @EnvironmentObject var mcp: MCPManager
    @Environment(\.dismiss) private var dismiss

    // Only providers that REQUIRE a buyer-pasted client_id AND don't have one stored show the field.
    // Linear (DCR, clientIDRequired:false) skips it entirely — true secretless sign-in.
    @State private var clientID = ""
    @State private var connecting = false
    @State private var result = ""        // honest live result of the last attempt (never faked)
    @State private var ok = false

    private var needsClientID: Bool {
        (entry.oauth?.clientIDRequired ?? false) && OAuthClientStore.clientID(entry.id) == nil
    }
    private var usesSavedClientID: Bool {
        (entry.oauth?.clientIDRequired ?? false) && OAuthClientStore.clientID(entry.id) != nil
    }
    private var canConnect: Bool {
        guard !connecting else { return false }
        return needsClientID ? !clientID.trimmingCharacters(in: .whitespaces).isEmpty : true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: entry.iconSystemName).font(.system(size: 16, weight: .bold)).foregroundColor(BLTheme.gold)
                Text("Sign in to \(entry.displayName)").font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            }
            Text(entry.blurb).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            if needsClientID {
                if let setup = entry.providerSetupURL {
                    // Cross-platform: Compat.swift shims NSWorkspace on iOS, so the provider page
                    // opens there too — the client-ID field is unfillable without it.
                    Button {
                        if let u = URL(string: setup) { NSWorkspace.shared.open(u) }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                            Text("Create an OAuth app on \(entry.displayName) to get a client ID")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }.foregroundColor(BLTheme.gold)
                    }.buttonStyle(.plain)
                }
                Text("CLIENT ID").font(.system(size: 9, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(1)
                TextField("paste your OAuth client ID", text: $clientID)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced)).foregroundColor(BLTheme.text)
                    .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                Text("A client ID is public and is saved locally. You'll finish sign-in in a secure browser window; the access token is stored in this device's Keychain and sent to \(entry.displayName) only as authentication for connector requests.")
                    .font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                // Google-specific truth: read-only Gmail/Drive scopes are RESTRICTED/SENSITIVE. With the
                // buyer's OWN client_id, Google blocks the consent screen unless the OAuth app is in
                // Testing mode (they add themselves as a test user) or has passed verification.
                if entry.oauth?.redirectStyle == .googleReversedClientID {
                    Text("Google note: Sovereign requests read-only access, but Google treats read-only Gmail/Drive as “restricted/sensitive.” Using your own client ID, keep your OAuth app in “Testing” mode and add yourself as a test user (or complete Google's verification) — otherwise Google blocks the consent screen.")
                        .font(.system(size: 10, design: .rounded)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
            } else if usesSavedClientID {
                Text("Using a locally saved OAuth client ID. You'll sign in with your own \(entry.displayName) account; the access token is stored in Keychain and sent to \(entry.displayName) only as authentication.")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No token to paste. You'll sign in with your own \(entry.displayName) account; the access token is stored in Keychain and sent to \(entry.displayName) only as authentication, never bundled or written to mcp.json.")
                    .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }

            if !result.isEmpty {
                Text(result).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(ok ? BLTheme.green : .orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                GhostButton(label: "Cancel", icon: "xmark", tint: BLTheme.sub) { dismiss() }
                Spacer()
                if connecting { ProgressView().controlSize(.small).tint(BLTheme.gold) }
                GoldButton(label: "Sign in", icon: "person.badge.key") { connect() }
                    .disabled(!canConnect).opacity(canConnect ? 1 : 0.5)
            }
        }
        .padding(24).sheetWidth(470).background(BLTheme.bg)
    }

    private func connect() {
        guard canConnect else { return }
        connecting = true; result = ""
        // If the buyer supplied a client_id, persist it (non-secret) before the flow resolves one.
        if needsClientID {
            OAuthClientStore.setClientID(entry.id, clientID.trimmingCharacters(in: .whitespaces))
        }
        Task { @MainActor in
            do {
                let accessToken = try await OAuthConnector.shared.connect(entry)
                // Register the live server + run the REAL discover (handshake + tools/list).
                await mcp.connectCatalog(entry, token: accessToken)
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
                    ok = false; result = "Signed in, but couldn't verify any tools. Try again."
                }
            } catch {
                connecting = false; ok = false
                result = (error as? OAuthError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
#endif // circuit-convert
