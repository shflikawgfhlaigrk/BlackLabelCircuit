// Black Label Marketing — the unified connector-status model (pure, Foundation-only, testable).
//
// One place decides whether each login/integration is Connected / Off / Error / Unavailable, so the
// Connectors screen's status chips are consistent and provable. No SwiftUI here (colors are mapped in
// ConnectorsScreen) — this file compiles standalone for the test suite.
import Foundation

/// The four honest states a connector can be in. "off" = not configured (a truthful empty state, not
/// an error). "error" = configured but a real check failed. "unavailable" = the capability isn't wired
/// in this build yet (shown as a clear "not yet available", never a dead button that silently no-ops).
enum ConnectorState: String, Equatable {
    case connected, off, error, unavailable, testing, unverified

    /// Human label for the status chip.
    var chip: String {
        switch self {
        case .connected: return "Connected"
        case .off: return "Not connected"
        case .error: return "Needs attention"
        case .unavailable: return "Unavailable"
        case .testing: return "Connecting…"
        case .unverified: return "Ready to verify"
        }
    }
}

/// A non-secret receipt from the most recent real connector round-trip. This keeps a successful
/// verification visible after relaunch without ever persisting tokens, passwords, or response bodies.
struct ConnectorVerificationReceipt: Codable, Equatable {
    var ok: Bool
    var checkedAt: Date
    var detail: String
}

enum ConnectorVerificationStore {
    private static let prefix = "ConnectorVerification.v1."
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    static func receipt(_ id: String, defaults: UserDefaults = .standard) -> ConnectorVerificationReceipt? {
        guard let data = defaults.data(forKey: prefix + id) else { return nil }
        return try? JSONDecoder().decode(ConnectorVerificationReceipt.self, from: data)
    }

    static func record(_ id: String, ok: Bool, detail: String, at: Date = Date(), defaults: UserDefaults = .standard) {
        let safeDetail = String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        guard let data = try? JSONEncoder().encode(ConnectorVerificationReceipt(ok: ok, checkedAt: at, detail: safeDetail)) else { return }
        defaults.set(data, forKey: prefix + id)
    }

    static func clear(_ id: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: prefix + id)
    }

    static func verdict(_ id: String, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool? {
        guard let r = receipt(id, defaults: defaults), now.timeIntervalSince(r.checkedAt) <= maxAge else { return nil }
        return r.ok
    }

    static func smtp(_ id: UUID) -> String { "smtp.\(id.uuidString.lowercased())" }
    static let imap = "imap"
    static func emailAPI(_ provider: String, address: String) -> String { "email.\(provider).\(address.lowercased())" }
    static func social(_ platform: String) -> String { "social.\(platform.lowercased())" }
    static let cloudflareNewsletter = "cloudflare.newsletter"
    /// Sendblue messaging (iMessage/RCS/SMS). One receipt per install — the credential is one
    /// account-level key pair, not per-address like the mailboxes.
    static let sendblue = "sendblue"
    static func enrichment(_ provider: String) -> String { "enrichment.\(provider.lowercased())" }
}

// MARK: - Credential liveness (expiry vs now — the ONLY liveness derivation)

/// Tri-state liveness of a stored provider credential.
///
/// There is deliberately no fourth "probably fine" state. A credential is `live` only while a REAL
/// absolute expiry is still in the future, `expired` once that moment has passed, and `unknown`
/// whenever no expiry is on record. The presence of a stored token and a cached success receipt are
/// explicitly NOT liveness: that conflation is what let a credential whose token had lapsed keep
/// reporting as publish-ready, accept a schedule, and then fail at publish time with nothing in the
/// UI ever having said otherwise. Unknown is reported as unknown — never optimistically as live.
enum SocialTokenLiveness: String, Codable, Hashable {
    case live, expired, unknown

    /// Short, honest label for a status line. `.unknown` never reads as a positive claim.
    var label: String {
        switch self {
        case .live:    return "Credential live"
        case .expired: return "Credential expired"
        case .unknown: return "Expiry unknown"
        }
    }

    /// The ONLY affirmative liveness answer. False for `.unknown` by construction.
    var isKnownLive: Bool { self == .live }
    /// Known dead: publishing against this WILL fail, so gate on it rather than hope.
    var isKnownDead: Bool { self == .expired }

    /// Derive liveness from an absolute expiry. A nil expiry is UNKNOWN — never live.
    static func from(expiry: Date?, now: Date = Date()) -> SocialTokenLiveness {
        guard let expiry else { return .unknown }
        return expiry > now ? .live : .expired
    }
}

/// Absolute-expiry record for one provider credential. Non-secret (a timestamp only — never the
/// token), so it lives in UserDefaults alongside the other connector receipts rather than Keychain.
/// Written by the SAME call that writes the token, so the two can never drift apart: saving a token
/// with no expiry information CLEARS any older expiry instead of leaving a stale one in place.
enum SocialTokenExpiryStore {
    private static let prefix = "SocialTokenExpiry.v1."

    private static func key(_ platformID: String) -> String {
        prefix + platformID.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func expiry(_ platformID: String, defaults: UserDefaults = .standard) -> Date? {
        guard let seconds = defaults.object(forKey: key(platformID)) as? Double else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Record (or, with nil, erase) the absolute expiry for a platform. Nil is meaningful: it is the
    /// honest "we were told nothing", which reads downstream as UNKNOWN.
    static func set(_ date: Date?, for platformID: String, defaults: UserDefaults = .standard) {
        guard let date else { defaults.removeObject(forKey: key(platformID)); return }
        defaults.set(date.timeIntervalSince1970, forKey: key(platformID))
    }

    static func clear(_ platformID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(platformID))
    }

    /// Current liveness for a platform, computed from the recorded expiry against `now`.
    static func liveness(_ platformID: String, now: Date = Date(), defaults: UserDefaults = .standard) -> SocialTokenLiveness {
        SocialTokenLiveness.from(expiry: expiry(platformID, defaults: defaults), now: now)
    }

    /// Absolute expiry parsed out of a provider's OAuth token response. `expires_in` is a duration in
    /// seconds (every provider here); a few return an absolute `expires_at` epoch instead. Anything
    /// missing, unparseable, or non-positive returns nil — which is UNKNOWN, never an invented expiry.
    static func expiryDate(fromOAuthResponse raw: [String: Any], now: Date = Date()) -> Date? {
        if let seconds = positiveSeconds(raw["expires_in"]) { return now.addingTimeInterval(seconds) }
        if let epoch = positiveSeconds(raw["expires_at"]) { return Date(timeIntervalSince1970: epoch) }
        return nil
    }

    private static func positiveSeconds(_ value: Any?) -> Double? {
        let parsed: Double?
        switch value {
        case let n as NSNumber: parsed = n.doubleValue
        case let s as String:   parsed = Double(s.trimmingCharacters(in: .whitespaces))
        default:                parsed = nil
        }
        guard let parsed, parsed.isFinite, parsed > 0 else { return nil }
        return parsed
    }
}

/// Pure state derivations — each mirrors the honest `isConfigured`/`isConnected`/`hasToken` flags the
/// underlying models already expose, so the chip can never claim "Connected" for an empty field.
enum ConnectorStatusEngine {
    /// Google sign-in: the REAL connection is a completed OAuth (a token + a validated userinfo call),
    /// NOT a saved client id. A saved client id only ENABLES the button, so it reads Off until the buyer
    /// actually signs in and a real `userinfo` returned 200. Founder directive 2026-07-03: "that's not an
    /// API, that's a bootstrap" — client-id-saved must never show Connected.
    static func google(clientIDConfigured: Bool, signedIn: Bool) -> ConnectorState { signedIn ? .connected : .off }
    /// Lead Database keys are bearer credentials, so non-empty text is only "configured". Green
    /// requires a live unmasked `/v1/leads` response from that exact key.
    static func leadDB(hasToken: Bool, testing: Bool, lastValidationOK: Bool?) -> ConnectorState {
        guard hasToken else { return .off }
        if testing { return .testing }
        switch lastValidationOK {
        case .some(true): return .connected
        case .some(false): return .error
        case .none: return .unverified
        }
    }
    static func mailbox(isConfigured: Bool) -> ConnectorState { isConfigured ? .connected : .off }

    /// Probe-driven SMTP mailbox status — the ONLY truthful source for the mailbox chip.
    /// "Connected" (green) is returned exclusively after a real SMTP probe (SMTPClient.verify) returned
    /// success. A configured-but-never-probed mailbox reads `.unverified` ("Not tested" — never green),
    /// an in-flight probe reads `.testing`, and a failed OR timed-out probe reads `.error` ("Failed").
    /// Fixes the 2026-07-08 founder-witnessed hallucination where a saved (even deliberately WRONG)
    /// password rendered "Connected" with no probe, and where "Connected" showed simultaneously with
    /// "Testing…". Changing credentials MUST reset `lastProbeOK` to nil so the chip drops out of green.
    static func mailboxProbe(configured: Bool, testing: Bool, lastProbeOK: Bool?) -> ConnectorState {
        guard configured else { return .off }          // not set up at all
        if testing { return .testing }                 // a real probe is in flight
        switch lastProbeOK {
        case .some(true):  return .connected           // a real SMTP probe returned success
        case .some(false): return .error               // probe failed or timed out (reason shown separately)
        case .none:        return .unverified          // configured but never verified — NEVER green
        }
    }

    /// A provider-API mailbox (Gmail API / Microsoft Graph): connected ONLY after a real authenticated
    /// API round-trip (validate/send) returned success. Mirrors EmailAPIStatus so the chip can't overclaim.
    static func emailAPI(hasToken: Bool, lastCallOK: Bool?) -> ConnectorState {
        guard hasToken else { return .off }
        switch lastCallOK {
        case .some(true):  return .connected
        case .some(false): return .error
        case .none:        return .unverified
        }
    }

    /// IMAP is connected only after a real TLS + LOGIN probe succeeds.
    static func imap(enabled: Bool, configured: Bool, testing: Bool = false, lastProbeOK: Bool? = nil) -> ConnectorState {
        if !enabled { return .off }
        guard configured else { return .error }
        if testing { return .testing }
        switch lastProbeOK {
        case .some(true): return .connected
        case .some(false): return .error
        case .none: return .unverified
        }
    }

    /// Social: connected only when a real API token is stored, that token's recorded expiry is still
    /// in the FUTURE, and a real provider call has succeeded. "Linked by profile" (handle only, no
    /// token) is off for publishing purposes — we don't overclaim.
    ///
    /// `liveness` is authoritative and is checked BEFORE the cached round-trip verdict, because a
    /// stored receipt only proves the credential worked when the call was made. An expired token with
    /// a week-old success receipt is dead, and reporting it green is exactly the lie this fixes:
    ///   • `.expired` → `.error`, no matter how good the cached verdict looks.
    ///   • `.unknown` (no expiry recorded — e.g. a hand-pasted token) → `.unverified`
    ///     ("Ready to verify"), the honest UNKNOWN. Never green off an unknown.
    ///   • `.live`   → the normal receipt logic decides connected / error / unverified.
    /// `liveness` defaults to `.unknown` so a caller that has not yet been taught about expiry gets
    /// the cautious answer rather than an accidental green.
    static func social(hasToken: Bool, linked: Bool, lastCallOK: Bool? = nil,
                       liveness: SocialTokenLiveness = .unknown) -> ConnectorState {
        guard hasToken else { return .off }
        switch liveness {
        case .expired:
            return .error                                     // known dead — outranks any cached success
        case .unknown:
            return lastCallOK == .some(false) ? .error : .unverified   // honest unknown, never green
        case .live:
            switch lastCallOK {
            case .some(true): return .connected
            case .some(false): return .error
            case .none: return .unverified
            }
        }
    }

    static func crm(isConnected: Bool, providerSelected: Bool) -> ConnectorState {
        if isConnected { return .connected }
        return providerSelected ? .error : .off    // provider chosen but no token = misconfigured
    }

    /// Telephony: the system dialer is always available (connected), BYO providers need a credential.
    static func telephony(providerNeedsCredential: Bool, canPlaceProgrammatic: Bool) -> ConnectorState {
        if !providerNeedsCredential { return .connected }   // system/manual are always usable
        return canPlaceProgrammatic ? .connected : .off
    }

    /// Enrichment (BYO Hunter/Apollo email-finder). The chip reads Connected ONLY when a real provider
    /// is keyed and ready — the in-house pattern guesser is an internal fallback, not a live third-party
    /// integration, so it never paints this connector green on its own (no fake "connected" — §5.1).
    /// `lastCallOK` surfaces the outcome of the buyer's most recent real find. A saved key that has not
    /// completed a live request is ready to verify, never green.
    static func enrichment(providerNeedsKey: Bool, providerReady: Bool, lastCallOK: Bool? = nil) -> ConnectorState {
        guard providerReady else { return .off }
        switch lastCallOK {
        case .some(false): return .error       // a real provider call failed — honest, never green
        case .some(true):  return .connected
        case .none:        return .unverified
        }
    }

    /// Analytics live sync isn't implemented yet — a saved ID is a configured source, not a live
    /// connection. We label it honestly rather than fabricate a "Connected" state.
    static func analytics(hasSavedID: Bool) -> ConnectorState {
        hasSavedID ? .off : .off                            // configured-but-not-syncing reads as Off; UI explains
    }

    /// Cloudflare Analytics: a REAL pull connector. "off" until the buyer supplies token + account +
    /// zone; once configured it reads the outcome of the last live pull — "connected" only after a
    /// real successful pull, "error" when configured but the last pull failed (never overclaims).
    /// `lastPullOK` is nil when no pull has run yet (configured but unverified reads as off).
    static func cloudflareAnalytics(hasToken: Bool, hasAccount: Bool, hasZone: Bool,
                                    lastPullOK: Bool?) -> ConnectorState {
        guard hasToken, hasAccount, hasZone else { return .off }
        switch lastPullOK {
        case .some(true): return .connected
        case .some(false): return .error
        case .none: return .unverified
        }
    }

    /// Sendblue messaging (BYO iMessage/RCS/SMS line). Mirrors the mailbox-probe rule exactly:
    /// a stored key pair is only "configured", and the chip goes green ONLY after a real
    /// authenticated Sendblue response. A key saved by an older signature that this build cannot
    /// read back is `.error` — "needs attention" — never a silent Off, because the buyer thinks
    /// they are connected and every send would be quietly simulated.
    static func sendblue(hasCredential: Bool, savedButUnreadable: Bool = false,
                         testing: Bool = false, lastProbeOK: Bool? = nil) -> ConnectorState {
        if !hasCredential { return savedButUnreadable ? .error : .off }
        if testing { return .testing }
        switch lastProbeOK {
        case .some(true):  return .connected
        case .some(false): return .error
        case .none:        return .unverified
        }
    }

    static func cloudflareNewsletter(isConfigured: Bool, lastCallOK: Bool? = nil) -> ConnectorState {
        guard isConfigured else { return .off }
        switch lastCallOK {
        case .some(true): return .connected
        case .some(false): return .error
        case .none: return .unverified
        }
    }
}
