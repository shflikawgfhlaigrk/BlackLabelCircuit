// Sovereign — CONNECTOR SECRETS. Prompt-free private-file token storage for catalog connectors.
// The buyer's own token lives in Sovereign's owner-only Application Support directory, never in
// mcp.json, never bundled, never logged. The persisted connector
// config (MCP.swift's MCPServerConfig) stores only the NON-secret prefix + which private-store account
// holds the token; the bare token is read from here at call time to build the auth header.
//
// HONESTY (CHARTER §5.1 / §5.2): ships EMPTY. No token is bundled. A connector with no stored token
// resolves to NO auth header — an honest unauthenticated call the server rejects with a real error —
// never a fabricated "connected".
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#endif

/// Private file store for connector tokens, keyed by connector id. Pure of any
/// bundled secret. `nonisolated` statics so the I/O layer (MCPClient.post) can resolve a token off the
/// main actor. Honors the same `SOV_HEADLESS_TESTS` bypass as ExternalAuth (see HeadlessKeychain in
/// ExternalAuth.swift) so the unsigned test binary never blocks on a Keychain ACL prompt.
enum ConnectorSecrets {
    /// Stable service namespace. This is NOT a UserDefaults key (it is
    /// listed in Tests' testDataWipe `notUserDefaults` set) and is cleared on "delete all data" via
    /// MCPManager.wipeAll() -> ConnectorSecrets.wipeAll().
    static let service = "com.blacklabel.sovereign.connectors"

    private static func headlessKey(_ account: String) -> String { "\(service)/\(account)" }

    /// Store (or overwrite) the buyer's token for a connector. The token is theirs and never leaves
    /// Sovereign's private store except to build a request header.
    @discardableResult
    static func store(account: String, token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty, !t.isEmpty, let data = t.data(using: .utf8) else { return false }
        if HeadlessKeychain.active { HeadlessKeychain.set(headlessKey(account), data); return true }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SovereignKeychain.set(base, data: data)
    }

    /// Read a connector's token (nil when none stored → honest unauthenticated call, never faked).
    static func token(forAccount account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let data: Data
        if HeadlessKeychain.active {
            guard let d = HeadlessKeychain.get(headlessKey(account)) else { return nil }
            data = d
        } else {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            guard let d = SovereignKeychain.copy(q) else { return nil }
            data = d
        }
        guard let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    static func hasToken(forAccount account: String) -> Bool { token(forAccount: account) != nil }

    /// Remove one connector's token (disconnect).
    static func delete(account: String) {
        guard !account.isEmpty else { return }
        if HeadlessKeychain.active { HeadlessKeychain.delete(headlessKey(account)); return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SovereignKeychain.delete(q)
    }

    /// Explicit foreground import from an older Keychain-backed build. No caller invokes this from
    /// init, status, dashboard refresh, or a timer.
    @discardableResult
    static func recoverLegacy(account: String) -> SovereignLegacyRecoveryResult {
        guard !account.isEmpty else { return .unavailable }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        return SovereignKeychain.recoverLegacy(q)
    }

    /// Wipe EVERY connector token (App Store 5.1.1(v) delete-all; called from MCPManager.wipeAll()).
    /// Delete each known catalog account plus configured manual accounts. The headless map and live
    /// file store share the same explicit account list.
    static func wipeAll(additionalAccounts: [String] = []) {
        let accounts = Set(ConnectorCatalog.all.flatMap { [$0.id, "\($0.id).oauth"] } + additionalAccounts)
        if HeadlessKeychain.active {
            // Clear each catalog account AND its OAuth refresh sidecar (`<id>.oauth`).
            for account in accounts { HeadlessKeychain.delete(headlessKey(account)) }
            return
        }
        for account in accounts { delete(account: account) }
    }
}
