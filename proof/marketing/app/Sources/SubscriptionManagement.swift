// Black Label Marketing — Cancel & Export surface model (Foundation-only, testable).
//
// MK-18: "one-click real cancel + export; no reactivation / phantom charge / subaccount tax."
// The BILLING half — whether a real Stripe self-service cancel exists — is a §3 founder decision
// (pending on MICHAEL-TASKS: enable the Stripe customer portal, or `soften`). This model makes the
// IN-APP surface honest under BOTH pending outcomes without inventing a billing claim:
//
//   • founder ENABLES the Stripe customer portal → a portal URL is configured → we deep-link to it
//     and say "Manage or cancel your subscription". The moment the config exists, MK-18 flips.
//   • founder rules `soften` (no portal)          → NO portal URL → we show the honest floor:
//     "email us to cancel — we never reactivate or add per-seat charges" + the working export-all.
//
// It NEVER fabricates a portal URL and NEVER asserts "one-click cancel" until a real portal is
// configured. A non-https / malformed / javascript: portal string is treated as ABSENT (floor), so
// a bad or hostile config can never render as a link. Ships empty: the config keys are unset in the
// shipped binary today, so a downloaded copy always shows the honest floor until the founder rules.

import Foundation

enum SubscriptionManagement {
    /// Info.plist key the founder sets to the buyer-facing Stripe customer-portal URL once the
    /// self-service cancel is enabled. Empty/absent in the shipped binary today (ships empty).
    static let portalInfoKey = "BLMSubscriptionPortalURL"
    /// UserDefaults override (a per-install founder/QA seed), checked ahead of Info.plist.
    static let portalDefaultsKey = "blm.subscriptionPortalURL"
    /// Optional configured support address for the honest floor. Absent → the floor points the
    /// buyer at their own purchase receipt (a real inbox), never a fabricated address.
    static let supportInfoKey = "BLMSupportEmail"
    static let supportDefaultsKey = "blm.supportEmail"

    /// Validate a candidate portal URL. Only an absolute `https://` URL with a host is a real
    /// portal; everything else (nil, empty, http, javascript:, "not a url", "https://") is treated
    /// as NOT configured so it can never render as a link or a fabricated "one-click cancel".
    static func validPortalURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Minimal shape check for a configured support email — one `@`, a dot in the domain, no
    /// whitespace. Returns nil for anything malformed; the surface never invents an address.
    static func sanitizedSupportEmail(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        guard !raw.contains(where: { $0.isWhitespace }) else { return nil }
        let parts = raw.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let domain = parts[1]
        guard domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix("."), domain.count > 2 else { return nil }
        return raw
    }
}

/// The honest, config-driven Cancel/Export surface. Pure value type — the SwiftUI panel reads it.
struct CancelExportSurface: Equatable {
    enum Mode: Equatable {
        case portal(URL)     // founder enabled the Stripe customer portal
        case honestFloor     // no portal configured yet — email-to-cancel + export-all
    }

    let mode: Mode
    /// Configured support email for the floor; nil → point the buyer at their own receipt.
    let supportEmail: String?

    /// Primary initializer — drives directly from raw config strings (what the tests exercise).
    init(portalURLRaw: String?, supportEmailRaw: String? = nil) {
        if let url = SubscriptionManagement.validPortalURL(portalURLRaw) {
            mode = .portal(url)
        } else {
            mode = .honestFloor
        }
        supportEmail = SubscriptionManagement.sanitizedSupportEmail(supportEmailRaw)
    }

    /// Convenience — read config from the bundle + user defaults (what the app uses at runtime).
    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let portal = defaults.string(forKey: SubscriptionManagement.portalDefaultsKey)
            ?? bundle.object(forInfoDictionaryKey: SubscriptionManagement.portalInfoKey) as? String
        let support = defaults.string(forKey: SubscriptionManagement.supportDefaultsKey)
            ?? bundle.object(forInfoDictionaryKey: SubscriptionManagement.supportInfoKey) as? String
        self.init(portalURLRaw: portal, supportEmailRaw: support)
    }

    var portalConfigured: Bool { if case .portal = mode { return true }; return false }

    var portalURL: URL? { if case let .portal(url) = mode { return url }; return nil }

    var headline: String {
        switch mode {
        case .portal:      return "Manage or cancel your subscription"
        case .honestFloor: return "Cancel your subscription"
        }
    }

    /// Body copy. In floor mode it makes the anti-lock-in promise WITHOUT claiming a one-click
    /// cancel (there is no self-service cancel until a real portal backs it).
    var body: String {
        switch mode {
        case .portal:
            return "Open your subscription portal to update payment or cancel your plan. Changes take effect immediately — no reactivation, no phantom charge, and no per-seat or per-sub-account tax."
        case .honestFloor:
            if let email = supportEmail {
                return "To cancel, email \(email). Cancellation is honored on request — we never reactivate a canceled plan, add a phantom charge, or tax you per seat or per sub-account."
            }
            return "To cancel, reply to your subscription receipt (the email your key arrived in). Cancellation is honored on request — we never reactivate a canceled plan, add a phantom charge, or tax you per seat or per sub-account."
        }
    }

    /// Primary action label. Only claims a real portal action when a real portal backs it; the
    /// floor never says "one-click cancel".
    var primaryActionLabel: String {
        switch mode {
        case .portal:      return "Open subscription portal"
        case .honestFloor: return supportEmail == nil ? "How to cancel" : "Email to cancel"
        }
    }

    /// A `mailto:` action for the floor when a support email is configured (nil otherwise).
    var cancelMailtoURL: URL? {
        guard case .honestFloor = mode, let email = supportEmail else { return nil }
        return URL(string: "mailto:\(email)?subject=Cancel%20my%20subscription")
    }

    /// Always shown: export-first reminder (MK-13). Canceling never strands or holds the buyer's
    /// data — the audience/sites/settings are theirs and export anytime.
    var exportNote: String {
        "Export everything first — your audience, sites, and settings are yours. Use Export workspace below; canceling never deletes or holds your data, and there is no contact-count billing on the way out."
    }

    /// The full rendered user-facing payload. Adversarial tests regex THIS to prove the floor
    /// carries zero fabricated cancel/refund/portal strings and no fabricated URL.
    var renderedPayload: String {
        var out = [headline, body, exportNote, primaryActionLabel]
        if let url = portalURL { out.append(url.absoluteString) }
        if let mailto = cancelMailtoURL { out.append(mailto.absoluteString) }
        return out.joined(separator: "\n")
    }
}
