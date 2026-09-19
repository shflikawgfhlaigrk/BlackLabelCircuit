// Black Label Marketing — "Remember me" session persistence (Keychain-backed).
//
// When the buyer ticks "Remember me" at sign-in, we persist a small session token in the
// system Keychain (NOT UserDefaults — a remembered session is a credential) and auto-restore
// it on the next cold launch so they aren't re-authing every time. Honest expiry: the token
// carries an absolute expiry; on launch an expired (or missing) token is cleared and the normal
// sign-in screen is shown — we never silently resurrect a stale session.
//
// BINDINGS:
//   • Stores only the session IDENTITY (email) + issued/expiry timestamps. NO password is ever
//     written here (AccountStore keeps SHA-256 digests keyed by email — no random salt, so it is
//     a workspace label, not a security boundary; this token references the already-authenticated
//     identity, it does not re-authenticate).
//   • Default OFF: if the buyer does not tick the box, nothing is persisted and launch behavior is
//     exactly as before (the auth screen).
//   • Demo and empty-guest sessions are never remembered — only a real signed-in identity.
//   • Keychain item is device-only (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly): not synced
//     to iCloud, not exported. Wiped on sign-out and on "Delete all data".
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif

/// A remembered session: who is signed in and until when. Codable so it round-trips through one
/// Keychain blob. `email` is the AccountStore identity ("guest"/"demo" are never stored).
struct RememberedSession: Codable {
    var email: String
    var issued: Date
    var expires: Date
    var isValid: Bool { Date() < expires && !email.isEmpty }
}

enum SessionStore {
    /// Keychain service + account keys for the single remembered-session blob.
    private static let service = "com.blacklabel.marketing.session"
    private static let account = "remember-me"
    private static let markerKey = "blm.session.rememberedSessionPresent"
    /// How long a remembered session stays valid before the buyer must sign in again.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60   // 30 days

    /// Persist a remembered session for `email` (called only when "Remember me" is ticked and the
    /// identity is a real account — never "guest"/"demo"). Overwrites any prior token.
    static func remember(email: String) {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !e.isEmpty, e != "guest", e != "demo" else { return }
        let now = Date()
        let token = RememberedSession(email: e, issued: now, expires: now.addingTimeInterval(lifetime))
        guard let data = try? JSONEncoder().encode(token) else { return }
        if write(data) {
            UserDefaults.standard.set(true, forKey: markerKey)
        } else {
            // Never advertise a remembered session that failed to persist.
            UserDefaults.standard.removeObject(forKey: markerKey)
        }
    }

    /// Load a remembered session IF one exists and is still valid. An expired token is proactively
    /// cleared (honest expiry) and nil is returned, so the caller falls through to the sign-in screen.
    static func restore() -> RememberedSession? {
        guard UserDefaults.standard.bool(forKey: markerKey) else { return nil }
        guard let data = read(), let token = try? JSONDecoder().decode(RememberedSession.self, from: data) else { return nil }
        guard token.isValid else { clear(); return nil }   // expired/empty → wipe, force re-auth
        return token
    }

    /// Whether a valid remembered session currently exists (for UI state / settings display).
    static var hasValidSession: Bool { restore() != nil }

    /// Remove the remembered session (sign-out, opt-out, or delete-all-data).
    static func clear() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        MarketingKeychain.delete(q)
        UserDefaults.standard.removeObject(forKey: markerKey)
    }

    // MARK: - Keychain primitives (data-protection keychain — see MarketingKeychain)

    @discardableResult
    private static func write(_ data: Data) -> Bool {
        // Data-protection keychain: access keyed to the stable bundle-id code-sign identifier,
        // so an ad-hoc rebuild never re-prompts. set() clears both keychains first (idempotent).
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return MarketingKeychain.set(base, data: data, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    private static func read() -> Data? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return MarketingKeychain.copy(base,
                                      accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                      allowAuthenticationUI: false)
    }
}
