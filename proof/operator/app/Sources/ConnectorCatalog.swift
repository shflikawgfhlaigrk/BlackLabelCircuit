// Sovereign — CONNECTOR CATALOG. The curated, SHIP-EMPTY registry of one-click integrations. Each
// entry is pure DATA describing a provider (id, name, SF Symbol, category, optional remote MCP
// endpoint, how it authenticates, where the buyer gets their OWN token). Connecting one registers an
// MCPServerConfig (MCP.swift) and reuses the existing MCPClient discover()/callTool() over Streamable
// HTTP — no new transport, no new entitlement (the app's network.client covers it, in both the
// sandboxed App Store build and the Developer-ID build: token + HTTPS only, no subprocess, no socket).
//
// HONESTY (CHARTER §5.1 / §5.2): the catalog is DATA, not a connection. Nothing here is "connected";
// connection state is read live from MCPManager after a REAL handshake. Only providers marked
// `available` can be connected in THIS build — the rest render with an honest, disabled "Not yet
// available", NEVER a fabricated connected/tool count. No secret, no bundled token.
import Foundation

/// How a connector authenticates. `.token` (GitHub) and `.oauth2` (Linear, Slack, Google) are wired
/// over the shared OAuthConnector; the remaining `.oauth2` provider (OneDrive) carries catalog DATA
/// whose flow a later unit flips on + tests. `.localVault` (Obsidian) is a later unit too.
enum ConnectorAuthKind: String, Codable, Hashable {
    case token        // buyer pastes a personal access token; sent as headerName + valuePrefix + token
    case oauth2       // buyer's own OAuth 2.0 (+PKCE) via ASWebAuthenticationSession (OAuthConnector)
    case localVault   // a local folder/vault the buyer points at (e.g. Obsidian) — no remote auth
    case customMCP    // the buyer's own arbitrary MCP server URL (routes to the manual add-server sheet)
}

enum ConnectorCategory: String, Codable, Hashable {
    case development, productivity, communication, storage, knowledge, custom
    var label: String {
        switch self {
        case .development:   return "DEVELOPMENT"
        case .productivity:  return "PRODUCTIVITY"
        case .communication: return "COMMUNICATION"
        case .storage:       return "STORAGE"
        case .knowledge:     return "KNOWLEDGE"
        case .custom:        return "CUSTOM"
        }
    }
}

/// One provider in the catalog. `makeServerConfig()` turns it into a live MCPServerConfig whose secret
/// lives in the Keychain (ConnectorSecrets), referenced by `secretRef` — the raw token is never in the
/// persisted row.
struct ConnectorEntry: Identifiable, Hashable {
    let id: String                 // stable slug; also the Keychain account in ConnectorSecrets
    let displayName: String
    let iconSystemName: String     // SF Symbol
    let category: ConnectorCategory
    let endpointURL: String?       // remote MCP Streamable-HTTP endpoint (nil = no HTTP-MCP target yet)
    let authKind: ConnectorAuthKind
    let providerSetupURL: String?  // where the buyer creates their OWN token / app
    let tokenHeaderName: String    // e.g. "Authorization"
    let tokenValuePrefix: String   // NON-secret prefix composed with the Keychain token, e.g. "Bearer "
    let tokenLabel: String         // UI hint, e.g. "fine-grained personal access token"
    let available: Bool            // wired & connectable in THIS build (GitHub token + Linear OAuth)
    let blurb: String
    /// OAuth 2.0 + PKCE description for `.oauth2` connectors (nil for token/localVault/customMCP). The
    /// shared OAuthConnector (OAuthCore.swift) reads this to discover endpoints, register/resolve the
    /// client_id, and run the flow. Static endpoints here are a FALLBACK; live RFC 9728/8414 discovery
    /// wins when the server advertises it.
    /// `var` (not `let`) so the synthesized memberwise initializer includes it with a default —
    /// a defaulted `let` is excluded from the memberwise init, which is why entries passing
    /// `oauth:` failed to compile. Token/localVault/customMCP entries simply omit it (→ nil).
    var oauth: OAuthParams? = nil

    /// Build the live MCPServerConfig for this connector. The row carries `connectorID` + `secretRef`
    /// (the Keychain account) + the NON-secret `authValue` prefix; the bare token is read from
    /// ConnectorSecrets at call time, so the persisted mcp.json never holds the raw secret. Returns nil
    /// for entries with no remote endpoint (e.g. the Custom-MCP entry, which routes to the manual add
    /// sheet). Pure → unit-tested.
    func makeServerConfig() -> MCPServerConfig? {
        guard let url = endpointURL, !url.isEmpty else { return nil }
        var cfg = MCPServerConfig(name: displayName, url: url,
                                  authHeader: tokenHeaderName, authValue: tokenValuePrefix)
        cfg.connectorID = id
        cfg.secretRef = id
        return cfg
    }
}

/// The curated registry. Ships EMPTY of any connection — these are descriptions, not grants.
enum ConnectorCatalog {
    static let all: [ConnectorEntry] = [
        github, linear, slack, gmail, googleDrive, googleCalendar, oneDrive, obsidian, customMCP
    ]

    static func entry(_ id: String) -> ConnectorEntry? { all.first { $0.id == id } }

    // MARK: Wired this cycle — GitHub (token) + Linear (OAuth). Both work in sandboxed AND Dev-ID builds.

    static let github = ConnectorEntry(
        id: "github", displayName: "GitHub", iconSystemName: "chevron.left.forwardslash.chevron.right",
        category: .development, endpointURL: "https://api.githubcopilot.com/mcp/",
        authKind: .token, providerSetupURL: "https://github.com/settings/personal-access-tokens",
        tokenHeaderName: "Authorization", tokenValuePrefix: "Bearer ",
        tokenLabel: "fine-grained personal access token", available: true,
        blurb: "Your repos, issues, and pull requests as real tools. Your fine-grained PAT is stored in this device's Keychain and sent to GitHub only as authentication.")

    /// Linear — the OAuth exerciser for this unit. Its MCP server does RFC 7591 dynamic client
    /// registration, so the buyer pastes NOTHING: the client_id is minted on the fly (true secretless),
    /// endpoints are discovered via RFC 9728 → 8414, and the access token lands in the Keychain only.
    static let linear = ConnectorEntry(
        id: "linear", displayName: "Linear", iconSystemName: "list.bullet.rectangle.portrait",
        category: .productivity, endpointURL: "https://mcp.linear.app/mcp",
        authKind: .oauth2, providerSetupURL: "https://linear.app/settings/account/security",
        tokenHeaderName: "Authorization", tokenValuePrefix: "Bearer ",
        tokenLabel: "OAuth", available: true,
        blurb: "Issues, projects, and cycles. Sign in with your own Linear account — nothing to paste, because Linear's MCP server mints the client id via dynamic registration. The access token is stored in Keychain and sent to Linear only as authentication.",
        oauth: OAuthParams(
            supportsDCR: true,                                 // Linear MCP does RFC 7591 → no buyer paste
            clientIDRequired: false,                           // secretless: client_id minted via DCR
            scopes: ["read"],
            redirectScheme: "sovereign",
            redirectPath: "callback",
            resourceIndicator: "https://mcp.linear.app/mcp"))  // RFC 8707 — scope the token to the endpoint

    // MARK: Wired via the shared OAuthConnector — Slack (USER-token OAuth) + Google (Gmail/Drive/
    // Calendar, reversed-client-id redirect). All reuse the SAME OAuthConnector + MCPClient as Linear;
    // nothing is "connected" until a real token exchange + tools/list round-trip succeeds.

    /// Slack — OAuth via the shared OAuthConnector. Slack's MCP server uses the USER-token OAuth
    /// endpoints (oauth/v2_user/authorize + oauth.v2.user.access), which return a top-level
    /// access_token via standard auth-code + PKCE — so NO Slack-specific deviation is needed in the
    /// engine. Live discovery (mcp.slack.com/.well-known/oauth-protected-resource →
    /// oauth-authorization-server) confirms these endpoints; the static values are the fallback.
    /// No DCR (docs: "we do not support Dynamic Client Registration"), so the buyer pastes their own
    /// Slack app client_id (https://api.slack.com/apps); PKCE keeps it secretless on desktop.
    static let slack = ConnectorEntry(
        id: "slack", displayName: "Slack", iconSystemName: "number.square.fill",
        category: .communication, endpointURL: "https://mcp.slack.com/mcp",
        authKind: .oauth2, providerSetupURL: "https://api.slack.com/apps",
        tokenHeaderName: "Authorization", tokenValuePrefix: "Bearer ",
        tokenLabel: "OAuth", available: true,
        blurb: "Read channels, search messages, and post on your behalf. Your token is stored in Keychain, sent to Slack only as authentication, and never bundled.",
        oauth: OAuthParams(
            authorizationEndpoint: "https://slack.com/oauth/v2_user/authorize",
            tokenEndpoint: "https://slack.com/api/oauth.v2.user.access",
            supportsDCR: false, clientIDRequired: true,
            scopes: ["channels:read", "channels:history", "users:read", "search:read.public", "chat:write"],
            redirectScheme: "sovereign", redirectPath: "callback",
            // RFC 8707 audience: Slack's protected-resource metadata advertises the resource as the
            // ORIGIN (https://mcp.slack.com), not the /mcp path — match it exactly so the token's
            // audience is accepted. The bearer is still POSTed to endpointURL (…/mcp).
            resourceIndicator: "https://mcp.slack.com"))

    /// Gmail — OAuth via the shared OAuthConnector against Google's LIVE managed MCP server
    /// (gmailmcp.googleapis.com). Live RFC 9728 path-aware discovery resolves issuer
    /// accounts.google.com → RFC 8414 AS metadata (auth + token endpoints, S256); the static endpoints
    /// here are the fallback. Google has NO DCR, so the buyer pastes their OWN client_id (no bundled
    /// secret); PKCE keeps it secretless. The redirect is Google's reversed-client-id custom scheme
    /// (redirectStyle .googleReversedClientID), derived per-connection from that client_id.
    /// SCOPE NOTE: gmail.readonly is a Google RESTRICTED scope — a buyer using their own client_id must
    /// keep the OAuth app in Testing mode (add themselves as a test user) or complete Google's
    /// verification, else the consent screen is blocked. Surfaced truthfully in ConnectorOAuthSheet.
    static let gmail = ConnectorEntry(
        id: "gmail", displayName: "Gmail", iconSystemName: "envelope.fill",
        category: .communication, endpointURL: "https://gmailmcp.googleapis.com/mcp/v1",
        authKind: .oauth2, providerSetupURL: "https://console.cloud.google.com/apis/credentials",
        tokenHeaderName: "Authorization", tokenValuePrefix: "Bearer ",
        tokenLabel: "OAuth", available: true,
        blurb: "Search threads and read your own inbox as real tools. Sign in with your own Google account using a client ID you create. Your token is stored in Keychain, sent to Google only as authentication, and never bundled.",
        oauth: OAuthParams(
            authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",   // static fallback; live discovery wins
            tokenEndpoint: "https://oauth2.googleapis.com/token",
            supportsDCR: false, clientIDRequired: true,                              // no DCR → buyer pastes own client_id
            scopes: ["https://www.googleapis.com/auth/gmail.readonly"],              // READ-FIRST, from live scopes_supported
            redirectStyle: .googleReversedClientID,                                  // Google installed-app reversed-client-id redirect
            usesPKCE: true,
            extraAuthParams: ["access_type": "offline", "prompt": "consent"],        // ensure a refresh_token
            resourceIndicator: "https://gmailmcp.googleapis.com/mcp/v1"))            // RFC 8707 — scope the token to the MCP endpoint

    /// Google Drive — same shared OAuth path against drivemcp.googleapis.com. drive.readonly is a Google
    /// RESTRICTED scope (same Testing-mode / verification caveat as Gmail, surfaced in the sheet).
    static let googleDrive = ConnectorEntry(
        id: "gdrive", displayName: "Google Drive", iconSystemName: "externaldrive.fill.badge.icloud",
        category: .storage, endpointURL: "https://drivemcp.googleapis.com/mcp/v1",
        authKind: .oauth2, providerSetupURL: "https://console.cloud.google.com/apis/credentials",
        tokenHeaderName: "Authorization", tokenValuePrefix: "Bearer ",
        tokenLabel: "OAuth", available: true,
        blurb: "Search and read your own Drive files as real tools. Sign in with your own Google account using a client ID you create. Your token is stored in Keychain, sent to Google only as authentication, and never bundled.",
        oauth: OAuthParams(
            authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token",
            supportsDCR: false, clientIDRequired: true,
            scopes: ["https://www.googleapis.com/auth/drive.readonly"],              // READ-FIRST, from live scopes_supported
            redirectStyle: .googleReversedClientID,
            usesPKCE: true,
            extraAuthParams: ["access_type": "offline", "prompt": "consent"],
            resourceIndicator: "https://drivemcp.googleapis.com/mcp/v1"))

    /// Google Calendar — same shared OAuth path against calendarmcp.googleapis.com. calendar.readonly is
    /// a Google SENSITIVE scope (Testing-mode / verification caveat, surfaced in the sheet).
    static let googleCalendar = ConnectorEntry(
        id: "gcal", displayName: "Google Calendar", iconSystemName: "calendar",
        category: .productivity, endpointURL: "https://calendarmcp.googleapis.com/mcp/v1",
        authKind: .oauth2, providerSetupURL: "https://console.cloud.google.com/apis/credentials",
        tokenHeaderName: "Authorization", tokenValuePrefix: "Bearer ",
        tokenLabel: "OAuth", available: true,
        blurb: "Read your own calendars and events as real tools. Sign in with your own Google account using a client ID you create. Your token is stored in Keychain, sent to Google only as authentication, and never bundled. (Apple Calendar is already live under Connectors.)",
        oauth: OAuthParams(
            authorizationEndpoint: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenEndpoint: "https://oauth2.googleapis.com/token",
            supportsDCR: false, clientIDRequired: true,
            scopes: ["https://www.googleapis.com/auth/calendar.readonly"],           // READ-FIRST, from live scopes_supported
            redirectStyle: .googleReversedClientID,
            usesPKCE: true,
            extraAuthParams: ["access_type": "offline", "prompt": "consent"],
            resourceIndicator: "https://calendarmcp.googleapis.com/mcp/v1"))

    // MARK: Catalog DATA only (a later unit flips available:true + tests). OAuth params are pre-populated
    // so the shared engine has a starting point, but the FLOW is not exercised yet. Honest disabled
    // state in the gallery; never a fabricated connection.

    static let oneDrive = ConnectorEntry(
        id: "onedrive", displayName: "OneDrive", iconSystemName: "cloud.fill",
        category: .storage, endpointURL: nil,
        authKind: .oauth2, providerSetupURL: "https://portal.azure.com",
        tokenHeaderName: "Authorization", tokenValuePrefix: "Bearer ",
        tokenLabel: "OAuth", available: false,
        blurb: "Search and read your own Microsoft 365 files. Microsoft OAuth arrives in a later unit.",
        oauth: OAuthParams(
            authorizationEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
            tokenEndpoint: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
            supportsDCR: false, clientIDRequired: true,
            scopes: ["Files.Read", "User.Read", "offline_access"],
            redirectScheme: "sovereign", redirectPath: "callback"))

    static let obsidian = ConnectorEntry(
        id: "obsidian", displayName: "Obsidian", iconSystemName: "book.closed.fill",
        category: .knowledge, endpointURL: nil,
        authKind: .localVault, providerSetupURL: "https://github.com/coddingtonbear/obsidian-local-rest-api",
        tokenHeaderName: "Authorization", tokenValuePrefix: "Bearer ",
        tokenLabel: "local REST API key", available: false,
        blurb: "Your own Markdown vault as searchable knowledge. Local-vault connect arrives in a later unit.")

    // MARK: Always-available manual escape hatch (the buyer's own arbitrary MCP server)

    static let customMCP = ConnectorEntry(
        id: "custom", displayName: "Custom MCP server", iconSystemName: "server.rack",
        category: .custom, endpointURL: nil,
        authKind: .customMCP, providerSetupURL: nil,
        tokenHeaderName: "", tokenValuePrefix: "",
        tokenLabel: "", available: true,
        blurb: "Point at any Model Context Protocol server you run (HTTPS). Add its endpoint and an optional auth header.")
}

// MARK: - Connector → privacy data classes (the manifest's source of truth)
//
// WHY THIS EXISTS. A connector is not just an auth row: once it is connected, the AgentEngine feeds
// its tool OUTPUT straight back to the brain —
//
//   AgentEngine.runTool() → MCPManager.callTool() → returns the provider's text
//     → messages.append(["role":"user","content":[{"type":"tool_result","content": <that text>}]])
//     → AgentBrain.toolTurn(messages:) → ExternalBrain.makeRequest()
//     → POST https://api.anthropic.com/v1/messages          (Brain.swift)
//
// So connecting Gmail means the buyer's EMAIL BODIES leave the device inside that request, and
// connecting Slack means their MESSAGE CONTENT does. That is a privacy-manifest data class, and it
// is the kind of fact that silently rots: someone adds a tenth connector, ships it, and the manifest
// now understates what the app transmits.
//
// This map closes that. Every `ConnectorCatalog.all` entry MUST classify what its tool output puts
// into that outbound request, and the ship gate asserts (1) nothing is unclassified and (2) every
// class a WIRED connector contributes is actually declared in PrivacyInfo.xcprivacy. Adding a
// connector that carries a new class fails the gate until the manifest is updated — the divergence
// is impossible to ship rather than merely currently-absent.
//
// Scope note: these are the classes the connector's CONTENT contributes. The OAuth/PAT credential
// every connector carries is `.userID`, declared once for all of them by the manifest and asserted
// separately; it is not repeated per entry.
enum ConnectorDataClass: String, CaseIterable, Hashable {
    /// NSPrivacyCollectedDataTypeEmailsOrTextMessages — subject, sender, recipients, or body of the
    /// buyer's mail / chat messages.
    case emailsOrTextMessages = "NSPrivacyCollectedDataTypeEmailsOrTextMessages"
    /// NSPrivacyCollectedDataTypeOtherUserContent — documents, files, issues, notes, calendar entries.
    case otherUserContent = "NSPrivacyCollectedDataTypeOtherUserContent"
    /// NSPrivacyCollectedDataTypeName — a person's name carried in the tool output.
    case name = "NSPrivacyCollectedDataTypeName"
    /// NSPrivacyCollectedDataTypeEmailAddress — an address carried in the tool output.
    case emailAddress = "NSPrivacyCollectedDataTypeEmailAddress"
}

enum ConnectorPrivacyDisclosure {
    /// What each connector's TOOL OUTPUT contributes to the outbound external-brain request.
    /// Keyed by `ConnectorEntry.id`. Traced per provider from the scope it actually requests.
    static let contentClasses: [String: Set<ConnectorDataClass>] = [
        // Repos, issues, PRs — code and prose the buyer wrote, plus author names/handles.
        "github":   [.otherUserContent, .name],
        // Issues, projects, cycles — prose plus assignee/creator identity.
        "linear":   [.otherUserContent, .name],
        // Channel history, DMs, search results. Message CONTENT, with sender names.
        "slack":    [.emailsOrTextMessages, .otherUserContent, .name],
        // gmail.readonly — message bodies, subjects, senders, recipients.
        "gmail":    [.emailsOrTextMessages, .otherUserContent, .name, .emailAddress],
        // drive.readonly — document contents plus owner/sharer identity.
        "gdrive":   [.otherUserContent, .name, .emailAddress],
        // calendar.readonly — event titles/notes plus attendee names and addresses.
        "gcal":     [.otherUserContent, .name, .emailAddress],
        // Catalog DATA only (available == false): no endpoint, no flow, nothing transmitted yet.
        // Classified anyway so flipping `available` cannot slip a new class past the gate.
        "onedrive": [.otherUserContent, .name],
        "obsidian": [.otherUserContent],
        // The buyer points this at their OWN MCP server; we cannot bound what it returns, so it is
        // classified at the widest class its output can occupy.
        "custom":   [.emailsOrTextMessages, .otherUserContent, .name, .emailAddress],
    ]

    /// Every class contributed by the connectors that are WIRED in this build. These MUST all appear
    /// in PrivacyInfo.xcprivacy.
    static var requiredClassesForAvailableConnectors: Set<ConnectorDataClass> {
        ConnectorCatalog.all
            .filter { $0.available }
            .reduce(into: Set<ConnectorDataClass>()) { acc, e in
                acc.formUnion(contentClasses[e.id] ?? [])
            }
    }

    /// Catalog ids with no classification — a NEW connector nobody classified. Must be empty.
    static var unclassifiedConnectorIDs: [String] {
        ConnectorCatalog.all.map(\.id).filter { contentClasses[$0] == nil }.sorted()
    }

    /// Classified ids that are no longer in the catalog — keeps the map from rotting the other way.
    static var orphanedClassificationIDs: [String] {
        let live = Set(ConnectorCatalog.all.map(\.id))
        return contentClasses.keys.filter { !live.contains($0) }.sorted()
    }
}
