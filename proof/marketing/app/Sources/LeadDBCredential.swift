// Black Label Marketing — the Lead Database subscription key, moved out of UserDefaults.
//
// WHAT WAS WRONG: every other secret in this app (Sendblue, Cloudflare, GA4, the mailbox OAuth
// tokens, the enrichment keys, the CRM token, the remembered session) already lived in the
// data-protection Keychain via MarketingKeychain. The Lead Database access token did not. It sat
// in `UserDefaults.standard["leadDBToken"]` — i.e. as cleartext in a plist inside the app
// container, readable by anything that can read that file, backed up in the clear, and printed by
// the diagnostics snapshot. It is a bearer credential for a paid subscription: it belongs in the
// Keychain like the rest.
//
// WHAT THIS FILE DOES:
//   • `LeadDBCredential` is now the ONLY reader/writer of that token, backed by MarketingKeychain
//     (data-protection keychain, keyed to the bundle id — survives ad-hoc re-signs, no prompts).
//   • `migrateFromDefaults()` carries EXISTING INSTALLS forward: on first run after the update it
//     lifts the plaintext token out of UserDefaults, writes it to the Keychain, and REMOVES the
//     plaintext copy so the weaker store does not keep shadowing the new one. Buyers do not
//     re-enter anything, and the cleartext does not survive the upgrade.
//   • The migration DECISION is a pure function (`tokenToMigrate`) so the whole rule — including
//     the "never clobber a Keychain token with a stale plist value" case — is executed headlessly
//     in Tests/LeadDBCredentialTests.swift.
//
// The legacy defaults key is kept as a constant (not a literal sprinkled around) because
// LeadsMigration still has to read the RETIRED Leads app's own defaults domain for the one-time
// carry-over; that read is cross-domain and stays a defaults read by necessity — but its result is
// now written to the Keychain, never back into our own plist.
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif

enum LeadDBCredential {
    /// The legacy plaintext location. Read-and-erase only; nothing writes it any more.
    static let legacyDefaultsKey = "leadDBToken"

    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").leaddb"
    }
    private static let account = "subscription-token"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    // MARK: - pure migration decision

    /// Should the plaintext value be lifted into the Keychain?
    ///
    /// Only when the Keychain slot is empty AND the plist actually holds a non-blank token. A
    /// token already in the Keychain always wins: a leftover plist entry from a previous version
    /// must never overwrite the current credential.
    static func tokenToMigrate(defaultsValue: String?, keychainValue: String?) -> String? {
        let keychain = (keychainValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard keychain.isEmpty else { return nil }
        let plain = (defaultsValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return plain.isEmpty ? nil : plain
    }

    /// True when the plaintext copy must be erased. That is ANY time the plist still holds a
    /// value — whether we just migrated it or the Keychain already had one. The weaker store is
    /// never left holding a live credential.
    static func shouldEraseDefaults(defaultsValue: String?) -> Bool {
        !((defaultsValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty
    }

    // MARK: - the credential

    /// The subscription key, or "" when none is saved. Reads are silent (no Keychain UI) so a
    /// background search can never hang on an auth prompt.
    static var token: String {
        guard let data = MarketingKeychain.copy(base, accessible: kSecAttrAccessibleWhenUnlocked,
                                                allowAuthenticationUI: false),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static var hasToken: Bool { !token.isEmpty }

    /// A saved-but-unreadable item (legacy ACL) still counts as "the buyer has a key" for status
    /// copy — it just needs a reconnect. Never used to claim the data path is unlocked.
    static var hasSavedItem: Bool { MarketingKeychain.exists(base) }

    /// `defaults` is injectable ONLY so the erase-the-plaintext half of this write is executable in
    /// the headless suite (Tests/LeadDBMigrationPathTests.swift). Every shipped caller uses the
    /// default `.standard`.
    static func save(_ raw: String, defaults: UserDefaults = .standard) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { clear(defaults: defaults); return }
        MarketingKeychain.set(base, data: Data(t.utf8), accessible: kSecAttrAccessibleWhenUnlocked)
        // Belt and braces: saving a new key also clears any stale plaintext copy.
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    static func clear(defaults: UserDefaults = .standard) {
        MarketingKeychain.delete(base)
        defaults.removeObject(forKey: legacyDefaultsKey)
    }

    /// One-time upgrade path for installs that already hold a plaintext token. Idempotent, cheap,
    /// and safe to call on every launch. Returns true when a token was actually moved.
    @discardableResult
    static func migrateFromDefaults(defaults: UserDefaults = .standard) -> Bool {
        let plain = defaults.string(forKey: legacyDefaultsKey)
        var moved = false
        if let carry = tokenToMigrate(defaultsValue: plain, keychainValue: token) {
            MarketingKeychain.set(base, data: Data(carry.utf8), accessible: kSecAttrAccessibleWhenUnlocked)
            moved = true
        }
        if shouldEraseDefaults(defaultsValue: plain) {
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
        return moved
    }
}
