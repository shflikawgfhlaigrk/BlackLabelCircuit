// Black Label Marketing — Social brand-profile connect + per-platform bio generator.
// Tier-1 spine. Standalone, no network deps, App-Sandbox-safe (state persists in
// the app container). Connecting a brand profile is an HONEST manual step — the
// buyer pastes their own handle (and, when they have one, a personal access token
// from that platform's developer settings). Tokens are kept in Keychain, never in
// the JSON workspace backup. We NEVER mint fake tokens or claim a connection that
// doesn't exist.
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Platforms
//
// `enum SocialPlatform` (and its consent mapping `transmissionProvider`) lives in
// Sources/SocialPlatformIdentity.swift — Foundation-only, so the headless posting suite
// compiles the REAL mapping instead of a copy of it.

// MARK: - Own-it OAuth (the buyer authorizes with their OWN platform app, WE host the redirect)
//
// "Link" takes the buyer to the EXACT place on their own platform to mint an API token; publishing
// then wires through THEIR token. Most networks (Meta family, X, LinkedIn, Google/YouTube) require
// an HTTPS redirect URI and REJECT custom URL schemes — so a clean in-app capture is impossible
// without a hosted https bounce. WE host ONE stateless bounce (`SocialOAuth.redirectURI`): the
// provider redirects there with `?code&state`, and the bounce forwards straight to the app's custom
// scheme, which ASWebAuthenticationSession captures. The bounce stores NOTHING; the code passes
// through in-flight and is useless without the buyer's own client secret (which never leaves the
// device — the code→token exchange happens on-device). The buyer registers this ONE redirect URI in
// their own provider app; they never have to host anything. Pure builders here are unit-tested.
enum SocialOAuth {
    /// The single HTTPS redirect WE host for every provider + every Black Label app. The buyer
    /// registers exactly this in their own developer app. It is a stateless forwarder to the app's
    /// custom scheme; it never persists the code or the token.
    static let redirectURI = "https://blacklabelbots.com/oauth/bounce"
    /// The app's registered custom URL scheme the bounce forwards to (ASWebAuthenticationSession
    /// callback). Already declared in project.yml CFBundleURLSchemes.
    static let callbackScheme = "com.blacklabel.marketing"
    /// Short app code embedded in `state` so the one shared bounce knows which app to return to.
    static let appCode = "marketing"

    /// One provider's OAuth shape. `usesPKCE` (X, Google) sends a code_challenge; `secretInBody`
    /// confidential clients (Meta, LinkedIn, Google) include the buyer's client secret in the
    /// on-device token exchange. Endpoints verified against live provider docs (2025/2026).
    struct Provider {
        var authorize: String
        var token: String
        var scopes: [String]
        var scopeSeparator: String   // Meta = ",", others = " "
        var usesPKCE: Bool
        var secretInBody: Bool       // confidential client → needs the buyer's app secret to exchange
        /// Pinterest-style client auth: when the buyer's app has a secret, the token endpoint wants
        /// it as HTTP Basic (base64 "client_id:client_secret") rather than a client_secret form
        /// field. `secretInBody` stays true so the UI still collects the secret; the exchange
        /// builder moves it into the Authorization header instead of the body.
        var secretViaBasicAuth: Bool = false
    }

    static func provider(for p: SocialPlatform) -> Provider? {
        switch p {
        case .instagram:
            return Provider(authorize: "https://api.instagram.com/oauth/authorize",
                            token: "https://graph.instagram.com/oauth/access_token",
                            scopes: ["instagram_business_basic", "instagram_business_content_publish"],
                            scopeSeparator: ",", usesPKCE: false, secretInBody: true)
        case .threads:
            return Provider(authorize: "https://threads.net/oauth/authorize",
                            token: "https://graph.threads.net/oauth/access_token",
                            scopes: ["threads_basic", "threads_content_publish"],
                            scopeSeparator: ",", usesPKCE: false, secretInBody: true)
        case .facebook:
            return Provider(authorize: "https://www.facebook.com/v21.0/dialog/oauth",
                            token: "https://graph.facebook.com/v21.0/oauth/access_token",
                            scopes: ["pages_show_list", "pages_read_engagement", "pages_manage_posts"],
                            scopeSeparator: ",", usesPKCE: false, secretInBody: true)
        case .x:
            return Provider(authorize: "https://twitter.com/i/oauth2/authorize",
                            token: "https://api.x.com/2/oauth2/token",
                            scopes: ["tweet.read", "users.read", "tweet.write", "offline.access"],
                            scopeSeparator: " ", usesPKCE: true, secretInBody: false)
        case .linkedin:
            return Provider(authorize: "https://www.linkedin.com/oauth/v2/authorization",
                            token: "https://www.linkedin.com/oauth/v2/accessToken",
                            scopes: ["w_member_social", "openid", "profile"],
                            scopeSeparator: " ", usesPKCE: false, secretInBody: true)
        case .youtube:
            return Provider(authorize: "https://accounts.google.com/o/oauth2/v2/auth",
                            token: "https://oauth2.googleapis.com/token",
                            scopes: ["https://www.googleapis.com/auth/youtube.upload"],
                            scopeSeparator: " ", usesPKCE: true, secretInBody: true)
        case .pinterest:
            return Provider(authorize: "https://www.pinterest.com/oauth/",
                            token: "https://api.pinterest.com/v5/oauth/token",
                            scopes: ["boards:read", "pins:read", "pins:write"],
                            scopeSeparator: ",", usesPKCE: true, secretInBody: true,
                            secretViaBasicAuth: true)
        case .tiktok:
            // TikTok has no own-it desktop OAuth content-publish path; it publishes via the Reel
            // Relay (OpenSDK Share Kit on the buyer's phone). So no hosted-redirect OAuth here.
            return nil
        }
    }

    /// Every network here supports the hosted-redirect OAuth hand-off.
    static func supportsAuthorize(_ p: SocialPlatform) -> Bool { provider(for: p) != nil }

    static func scopes(for p: SocialPlatform) -> [String] { provider(for: p)?.scopes ?? [] }
    static func authorizeEndpoint(for p: SocialPlatform) -> String? { provider(for: p)?.authorize }

    /// Builds the buyer's OWN authorization URL pointed at OUR hosted bounce. The buyer supplies
    /// only their App ID (client_id); the redirect is ours. `codeChallenge` is included for PKCE
    /// providers (X, Google). Returns nil only when the App ID is empty (honest fix-your-input).
    static func authorizeURL(platform: SocialPlatform, appID: String, state: String,
                             codeChallenge: String? = nil) -> URL? {
        guard let prov = provider(for: platform) else { return nil }
        let id = appID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        var items = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: prov.scopes.joined(separator: prov.scopeSeparator)),
            URLQueryItem(name: "state", value: state)
        ]
        if prov.usesPKCE, let ch = codeChallenge {
            items.append(URLQueryItem(name: "code_challenge", value: ch))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        var c = URLComponents(string: prov.authorize)
        c?.queryItems = items
        return c?.url
    }

    /// Builds the on-device code→token exchange request. Runs on the buyer's machine with the
    /// buyer's own client secret (confidential providers) and/or PKCE verifier — so the token is
    /// minted locally and never transits our infrastructure.
    static func tokenRequest(platform: SocialPlatform, appID: String, appSecret: String?,
                             code: String, codeVerifier: String?) -> URLRequest? {
        guard let prov = provider(for: platform) else { return nil }
        let id = appID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !code.isEmpty else { return nil }
        var form = [
            URLQueryItem(name: "client_id", value: id),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ]
        if prov.usesPKCE, let v = codeVerifier { form.append(URLQueryItem(name: "code_verifier", value: v)) }
        var basicCredential: String? = nil
        if prov.secretInBody, let s = appSecret?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            if prov.secretViaBasicAuth {
                // Pinterest: client auth travels as HTTP Basic, never as a form field.
                basicCredential = Data("\(id):\(s)".utf8).base64EncodedString()
            } else {
                form.append(URLQueryItem(name: "client_secret", value: s))
            }
        }
        var r = URLRequest(url: URL(string: prov.token)!)
        r.timeoutInterval = 20
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        if let basicCredential { r.setValue("Basic \(basicCredential)", forHTTPHeaderField: "Authorization") }
        r.httpBody = formEncode(form).data(using: .utf8)
        return r
    }

    /// Percent-encode a form body (spaces as %20, not "+", and provider-safe).
    private static func formEncode(_ items: [URLQueryItem]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return items.map { i in
            let k = i.name.addingPercentEncoding(withAllowedCharacters: allowed) ?? i.name
            let v = (i.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }

    /// A CSRF state token that also carries the app code, so the one shared bounce knows which
    /// app's scheme to forward to: "<appCode>.<nonce>". The app verifies the nonce on return.
    static func makeState() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let nonce = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(appCode).\(nonce)"
    }

    // MARK: PKCE helpers (X + Google)
    static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }
    static func codeChallenge(for verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Instagram Content Publishing — wires through the buyer's OWN token

    /// Step 1: create a REELS container from a PUBLIC video URL. Instagram fetches the file
    /// itself (it never accepts raw bytes), so `videoURL` must be publicly reachable over HTTPS.
    static func instagramCreateReelRequest(igUserID: String, videoURL: String, caption: String,
                                           accessToken: String, apiVersion: String = "v21.0") -> URLRequest? {
        let uid = igUserID.trimmingCharacters(in: .whitespaces)
        guard !uid.isEmpty, !accessToken.isEmpty, videoURL.lowercased().hasPrefix("https://") else { return nil }
        var c = URLComponents(string: "https://graph.instagram.com/\(apiVersion)/\(uid)/media")
        c?.queryItems = [
            URLQueryItem(name: "media_type", value: "REELS"),
            URLQueryItem(name: "video_url", value: videoURL),
            URLQueryItem(name: "caption", value: caption),
            URLQueryItem(name: "access_token", value: accessToken)
        ]
        guard let url = c?.url else { return nil }
        var r = URLRequest(url: url); r.timeoutInterval = 30; r.httpMethod = "POST"; return r
    }

    /// Step 2: publish the prepared container to the buyer's own feed.
    static func instagramPublishRequest(igUserID: String, creationID: String,
                                        accessToken: String, apiVersion: String = "v21.0") -> URLRequest? {
        let uid = igUserID.trimmingCharacters(in: .whitespaces)
        guard !uid.isEmpty, !creationID.isEmpty, !accessToken.isEmpty else { return nil }
        var c = URLComponents(string: "https://graph.instagram.com/\(apiVersion)/\(uid)/media_publish")
        c?.queryItems = [
            URLQueryItem(name: "creation_id", value: creationID),
            URLQueryItem(name: "access_token", value: accessToken)
        ]
        guard let url = c?.url else { return nil }
        var r = URLRequest(url: url); r.timeoutInterval = 30; r.httpMethod = "POST"; return r
    }
}

// MARK: - Reel Relay (own-it cross-platform publish: Mac render -> own phone -> native composer)
//
// NOVEL CORE (never shipped): the rendered .mp4 is carried from the Mac to the buyer's OWN
// iPhone over Apple's encrypted Handoff continuation-stream rail (AirDrop fallback), where ONE
// dispatcher drops it into each network's native composer under the account the buyer is already
// signed into. No OAuth redirect, no public URL, no per-buyer dev app, no posting-API review,
// nothing server-side. The pure parts below (rail selection, placement, the relay payload) carry
// NO UIKit/AppKit so they compile in both targets and are unit-tested headlessly.

/// Where a piece of media should land on a network.
enum PublishPlacement: String, Codable, CaseIterable { case feed, reel, short, story }

/// The native rail used on the phone to reach a network's own composer.
enum ShareRail: String, Codable {
    case instagramStories   // UIPasteboard sticker keys + instagram-stories:// scheme
    case instagramFeed      // com.instagram.exclusivegram UTI / system share sheet
    case tiktokOpenSDK      // TikTok OpenSDK TikTokShareRequest (needs app-level client_key); else shareSheet
    case shareSheet         // UIActivityViewController -> the network's own Share Extension
}

enum ReelRelay {
    /// Handoff activity type advertised by the Mac and continued by the iOS companion.
    static var activityType: String { AppBrand.publishActivityType }

    /// Networks that can be reached by the relay today (all of them — every one has a native
    /// share rail on iOS). Mirrors SocialPlatform.allCases.
    static func supports(_ p: SocialPlatform) -> Bool { true }

    /// Default placement per network for a vertical short-form reel.
    static func defaultPlacement(for p: SocialPlatform) -> PublishPlacement {
        switch p {
        case .youtube:            return .short
        case .tiktok, .instagram: return .reel
        default:                  return .feed   // x, facebook, linkedin, threads, pinterest
        }
    }

    /// Which native rail to use for a platform + placement.
    static func rail(for p: SocialPlatform, placement: PublishPlacement) -> ShareRail {
        switch p {
        case .instagram: return placement == .story ? .instagramStories : .instagramFeed
        case .tiktok:    return .tiktokOpenSDK
        default:         return .shareSheet
        }
    }

    /// Honest: can the caption be pre-filled into the composer for this rail, or must the
    /// buyer paste it? (IG feed/X don't reliably prefill; Stories has no caption field.)
    static func captionPrefills(_ rail: ShareRail) -> Bool {
        switch rail {
        case .tiktokOpenSDK:                       return true
        case .instagramStories, .instagramFeed:    return false
        case .shareSheet:                          return false
        }
    }

    /// The Handoff relay payload (small metadata only). The .mp4 is DELIBERATELY excluded —
    /// it travels over the continuation stream / AirDrop, never inside userInfo.
    static func activityUserInfo(platform: SocialPlatform, placement: PublishPlacement,
                                 caption: String, reelID: String) -> [String: String] {
        ["platform": platform.rawValue, "placement": placement.rawValue,
         "caption": caption, "reelID": reelID]
    }

    /// Parse a received relay payload back into typed values (iOS side).
    static func parse(_ userInfo: [AnyHashable: Any]) -> (platform: SocialPlatform, placement: PublishPlacement, caption: String, reelID: String)? {
        guard let praw = userInfo["platform"] as? String, let platform = SocialPlatform(rawValue: praw) else { return nil }
        let placement = PublishPlacement(rawValue: (userInfo["placement"] as? String) ?? "") ?? defaultPlacement(for: platform)
        return (platform, placement, (userInfo["caption"] as? String) ?? "", (userInfo["reelID"] as? String) ?? "")
    }
}

// MARK: - Connected brand profile (the buyer's OWN account)

struct SocialProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var platform: SocialPlatform
    var handle: String = ""          // the buyer's own handle (no @)
    var bio: String = ""             // generated/edited bio they pushed
    /// Whether a token exists in Keychain for this platform. The token value itself
    /// is never stored in Codable app/workspace data. Empty => "Profile linked"
    /// (manual) — honest, never a fake connection.
    ///
    /// NOTE: this is PRESENCE, not health. It says a credential is on disk, nothing about whether it
    /// still works. Never derive publish-readiness from it alone — use `liveness(now:)`.
    var hasToken: Bool = false
    /// Absolute expiry of the stored token, mirrored from `SocialTokenExpiryStore` by
    /// `refreshSocialCredentialFlags()`. nil means no expiry is on record (a hand-pasted token, or a
    /// provider that returned none) — which is UNKNOWN, never "fine". Optional so profiles saved
    /// before expiry tracking existed decode unchanged (and decode to the honest nil).
    var tokenExpiry: Date? = nil
    var linkedAt = Date()

    /// The credential's health RIGHT NOW, computed from the recorded expiry against `now`. A profile
    /// with no stored token has no credential to be live, so it reports `.unknown` rather than
    /// borrowing a stale expiry.
    func liveness(now: Date = Date()) -> SocialTokenLiveness {
        guard hasToken else { return .unknown }
        return SocialTokenLiveness.from(expiry: tokenExpiry, now: now)
    }

    /// Status text for the account row. Says what is actually known — an expired credential says so
    /// rather than continuing to read "API credential stored".
    var connectionLabel: String {
        guard hasToken else { return "Profile linked" }
        switch liveness() {
        case .live:    return "API credential live"
        case .expired: return "API credential expired — reconnect"
        case .unknown: return "API credential stored · expiry unknown"
        }
    }
}

// MARK: - Secure credential storage

enum SocialCredentialStore {
    private static var service: String {
        "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").social"
    }

    /// Save a token AND its absolute expiry together, so the two can never drift out of step.
    /// `expiry: nil` is not "keep the old one" — it erases any recorded expiry, because a new token
    /// invalidates the previous one's lifetime. The result is an honest UNKNOWN rather than a stale
    /// expiry silently vouching for a different credential.
    static func saveToken(_ token: String, for platform: SocialPlatform, expiry: Date? = nil) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { clearToken(for: platform); return }
        SocialTokenExpiryStore.set(expiry, for: account(for: platform))
        guard let data = t.data(using: .utf8) else { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: platform),
        ]
        // Data-protection keychain, keyed to the stable bundle-id code-sign identifier so an
        // ad-hoc rebuild never re-prompts. Device-only (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly):
        // never synced to iCloud, never exported. set() clears both keychains first (idempotent).
        MarketingKeychain.set(base, data: data, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }

    static func token(for platform: SocialPlatform) -> String? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: platform),
        ]
        guard let data = MarketingKeychain.copy(base, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                                allowAuthenticationUI: false) else { return nil }
        return String(data: data, encoding: .utf8)?.nilIfBlank
    }

    /// PRESENCE of a credential — deliberately not health. Pair it with `liveness(for:)`.
    static func hasToken(for platform: SocialPlatform) -> Bool { token(for: platform) != nil }

    /// The recorded absolute expiry for this platform's token, or nil when none is on record.
    static func expiry(for platform: SocialPlatform) -> Date? {
        SocialTokenExpiryStore.expiry(account(for: platform))
    }

    /// Health of the stored credential right now: `.live` only while a recorded expiry is still in
    /// the future, `.expired` once it has passed, `.unknown` when nothing is recorded (or no token
    /// is stored at all). Never infers "live" from the token merely existing.
    static func liveness(for platform: SocialPlatform, now: Date = Date()) -> SocialTokenLiveness {
        guard hasToken(for: platform) else { return .unknown }
        return SocialTokenLiveness.from(expiry: expiry(for: platform), now: now)
    }

    static func clearToken(for platform: SocialPlatform) {
        SocialTokenExpiryStore.clear(account(for: platform))
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: platform),
        ]
        MarketingKeychain.delete(q)
    }

    static func clearAll() {
        for platform in SocialPlatform.allCases { SocialTokenExpiryStore.clear(account(for: platform)) }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        MarketingKeychain.delete(q)
    }

    private static func account(for platform: SocialPlatform) -> String {
        platform.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")
    }
}

// MARK: - Publish readiness

enum SocialPublishState: String {
    case unsupported = "Unsupported"
    case needsProfile = "Needs profile"
    case manualReady = "Manual ready"
    /// A stored credential whose recorded expiry is still in the future. The ONLY state that claims
    /// the account is live for API publishing.
    case credentialStored = "Credential stored"
    /// A stored credential whose recorded expiry has PASSED. Publishing against it will fail, so it
    /// must never be treated as ready — this is the state that used to masquerade as the one above.
    case credentialExpired = "Credential expired"
    /// A stored credential with no expiry on record (hand-pasted token, or a provider that returned
    /// none). We genuinely do not know: reported as unknown, never as ready.
    case credentialExpiryUnknown = "Expiry unknown"

    /// True when a credential is stored and is NOT known to be dead. Direct-publish gates use this:
    /// we block only what we KNOW will fail and let the provider be the authority on the rest —
    /// while never claiming an unknown credential is healthy.
    var hasUsableCredential: Bool { self == .credentialStored || self == .credentialExpiryUnknown }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct SocialPublishReadiness: Hashable {
    var platform: SocialPlatform?
    var profile: SocialProfile?
    var state: SocialPublishState
    var badge: String
    var detail: String
    var actionTitle: String
    var canOpenProfile: Bool
    /// The credential health this readiness was derived from, carried through so callers can show the
    /// real reason instead of re-deriving (or guessing at) it.
    var liveness: SocialTokenLiveness = .unknown

    var tint: Color {
        switch state {
        case .credentialStored: return BLTheme.green
        case .credentialExpired: return BLTheme.danger
        case .credentialExpiryUnknown, .manualReady: return BLTheme.gold
        case .needsProfile, .unsupported: return BLTheme.sub
        }
    }

    var profileURL: String? {
        guard canOpenProfile, let platform, let profile else { return nil }
        return platform.profileURL(handle: profile.handle)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum SocialPublisher {
    static func platform(for channel: String) -> SocialPlatform? {
        switch channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "instagram": return .instagram
        case "x": return .x
        case "tiktok": return .tiktok
        case "facebook": return .facebook
        case "linkedin": return .linkedin
        case "threads": return .threads
        case "pinterest": return .pinterest
        default: return nil
        }
    }

    /// Publish readiness for a channel. `now` is injected so the expiry comparison is testable and so
    /// every caller in one render pass agrees on the moment being asked about.
    static func readiness(channel: String, profiles: [SocialProfile], now: Date = Date()) -> SocialPublishReadiness {
        guard let platform = platform(for: channel) else {
            return SocialPublishReadiness(platform: nil,
                                          profile: nil,
                                          state: .unsupported,
                                          badge: "Unsupported",
                                          detail: "This channel is not part of the publishing pipeline.",
                                          actionTitle: "Copy post",
                                          canOpenProfile: false)
        }
        guard let profile = profiles.first(where: { $0.platform == platform }) else {
            return SocialPublishReadiness(platform: platform,
                                          profile: nil,
                                          state: .needsProfile,
                                          badge: "Link account",
                                          detail: "Link your own \(platform.rawValue) profile before treating this post as publish-ready.",
                                          actionTitle: "Copy post",
                                          canOpenProfile: false)
        }
        if profile.hasToken {
            // Health, not presence. A stored token proves only that bytes are on disk; whether it
            // still works is decided by its expiry against `now`, and an unknown expiry stays
            // unknown rather than being rounded up to "ready".
            switch profile.liveness(now: now) {
            case .live:
                return SocialPublishReadiness(platform: platform,
                                              profile: profile,
                                              state: .credentialStored,
                                              badge: "Credential stored",
                                              detail: "A \(platform.rawValue) API credential is stored in Keychain on this device and is valid until \(profile.tokenExpiry.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "its recorded expiry"). The post is ready for your platform API/dashboard flow.",
                                              actionTitle: "Copy + open profile",
                                              canOpenProfile: true,
                                              liveness: .live)
            case .expired:
                return SocialPublishReadiness(platform: platform,
                                              profile: profile,
                                              state: .credentialExpired,
                                              badge: "Credential expired",
                                              detail: "The stored \(platform.rawValue) credential expired \(profile.tokenExpiry.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "before now"). Publishing through the API will fail until you reconnect \(platform.rawValue) — copy and post manually in the meantime.",
                                              actionTitle: "Copy + open profile",
                                              canOpenProfile: true,
                                              liveness: .expired)
            case .unknown:
                return SocialPublishReadiness(platform: platform,
                                              profile: profile,
                                              state: .credentialExpiryUnknown,
                                              badge: "Expiry unknown",
                                              detail: "A \(platform.rawValue) API credential is stored in Keychain on this device, but no expiry was recorded for it — this app cannot tell whether it is still valid. Reconnect through \(platform.rawValue) OAuth to record one, or publish and read the provider's real response.",
                                              actionTitle: "Copy + open profile",
                                              canOpenProfile: true,
                                              liveness: .unknown)
            }
        }
        return SocialPublishReadiness(platform: platform,
                                      profile: profile,
                                      state: .manualReady,
                                      badge: "Manual ready",
                                      detail: "The \(platform.rawValue) profile is linked. Copy the post, open the profile, and publish it from the buyer's own account.",
                                      actionTitle: "Copy + open profile",
                                      canOpenProfile: true)
    }
}
#endif // circuit-convert

// MARK: - Per-platform bio generator (from the buyer's OWN brand inputs)

struct BrandVoiceInput {
    var brand = ""
    var tagline = ""
    var city = ""
    var industry = ""
    var hashtag = ""
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum BioEngine {
    /// Generate a platform-appropriate bio from the buyer's OWN brand inputs.
    /// Never invents facts; trims to the platform limit; only adds a hashtag where
    /// the platform convention supports it AND the buyer provided one.
    static func bio(_ v: BrandVoiceInput, for p: SocialPlatform) -> String {
        let brand = v.brand.trimmingCharacters(in: .whitespaces)
        let tag = v.tagline.trimmingCharacters(in: .whitespaces)
        let city = v.city.trimmingCharacters(in: .whitespaces)
        let ind = v.industry.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if !tag.isEmpty { parts.append(tag) }
        else if !ind.isEmpty { parts.append(ind.capitalizedFirst) }
        if !city.isEmpty { parts.append("📍 \(city)") }
        if p.likesHashtags, !v.hashtag.trimmingCharacters(in: .whitespaces).isEmpty {
            let raw = v.hashtag.trimmingCharacters(in: .whitespaces)
            parts.append(raw.hasPrefix("#") ? raw : "#\(raw)")
        }
        var line = parts.joined(separator: " · ")
        if (p == .linkedin || p == .facebook), !brand.isEmpty {
            line = line.isEmpty ? brand : "\(brand) — \(line)"
        }
        if line.isEmpty { line = brand }
        return clamp(line, to: p.bioLimit)
    }
    /// Trim to a hard character limit, preferring a word boundary past the halfway mark.
    static func clamp(_ s: String, to limit: Int) -> String {
        if s.count <= limit { return s }
        let slice = String(s.prefix(limit))
        if let sp = slice.lastIndex(of: " "), slice.distance(from: slice.startIndex, to: sp) > limit / 2 {
            return String(slice[..<sp])
        }
        return slice
    }
}
#endif // circuit-convert

// MARK: - Persistence

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    func connect(_ p: SocialProfile) {
        upsertSocialProfile(p)
    }

    /// Link a profile, optionally storing a token for it. `expiry` is the absolute moment the token
    /// dies, taken from the provider's own OAuth response — pass nil when the provider told us
    /// nothing (a hand-pasted token), which records an honest UNKNOWN instead of an assumed lifetime.
    func connect(_ p: SocialProfile, token: String?, expiry: Date? = nil) {
        var profile = p
        if let token {
            let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                SocialCredentialStore.clearToken(for: p.platform)
                profile.hasToken = false
                profile.tokenExpiry = nil
            } else {
                SocialCredentialStore.saveToken(cleaned, for: p.platform, expiry: expiry)
                profile.hasToken = true
                profile.tokenExpiry = expiry
            }
        } else {
            profile.hasToken = SocialCredentialStore.hasToken(for: p.platform)
            profile.tokenExpiry = profile.hasToken ? SocialCredentialStore.expiry(for: p.platform) : nil
        }
        upsertSocialProfile(profile)
    }

    func disconnect(_ p: SocialProfile) {
        SocialCredentialStore.clearToken(for: p.platform)
        socialProfiles.removeAll { $0.id == p.id || $0.platform == p.platform }
    }

    func profile(for platform: SocialPlatform) -> SocialProfile? { socialProfiles.first { $0.platform == platform } }

    /// Re-derive every profile's credential facts from the real stores (Keychain for presence,
    /// the expiry store for lifetime). A workspace snapshot can carry a `hasToken`/`tokenExpiry`
    /// pair from another machine or another credential entirely, so both are normalized here rather
    /// than trusted — an imported profile can never keep vouching for a credential this Mac has not
    /// got, and can never keep an expiry that belonged to a replaced token.
    func refreshSocialCredentialFlags() {
        for i in socialProfiles.indices {
            let platform = socialProfiles[i].platform
            let present = SocialCredentialStore.hasToken(for: platform)
            socialProfiles[i].hasToken = present
            socialProfiles[i].tokenExpiry = present ? SocialCredentialStore.expiry(for: platform) : nil
        }
    }

    private func upsertSocialProfile(_ p: SocialProfile) {
        if let i = socialProfiles.firstIndex(where: { $0.platform == p.platform }) { socialProfiles[i] = p }
        else { socialProfiles.insert(p, at: 0) }
    }
}
#endif // circuit-convert

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
