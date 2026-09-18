// Black Label Marketing (lead engine, merged from Black Label Leads) — click-to-call + call logging/disposition (Tier-1 MVP "one-click Call").
//
// BYO telephony: the buyer connects their OWN provider (Twilio / Telnyx / a SIP/WebRTC desk phone)
// OR uses the zero-config `tel:` hand-off to the Mac's default calling app (FaceTime/handoff to iPhone).
// We NEVER place a call through a service of ours. When no provider is connected we honestly say so
// and fall back to `tel:`. Every call the buyer logs becomes a real Activity on the prospect.
//
// On-device. Provider API token (when used) lives in the Keychain, never in JSON or the bundle.
// No fabricated call data: a call log row exists only because the buyer placed/logged it.
import Foundation

// MARK: - call outcome (disposition) the buyer tags after a call

enum CallDisposition: String, Codable, CaseIterable, Identifiable {
    case connected, voicemail, noAnswer, busy, wrongNumber, notInterested, callback, meetingBooked
    var id: String { rawValue }
    var label: String {
        switch self {
        case .connected: return "Connected"; case .voicemail: return "Left voicemail"
        case .noAnswer: return "No answer"; case .busy: return "Busy"
        case .wrongNumber: return "Wrong number"; case .notInterested: return "Not interested"
        case .callback: return "Callback requested"; case .meetingBooked: return "Meeting booked"
        }
    }
    var icon: String {
        switch self {
        case .connected: return "phone.connection.fill"; case .voicemail: return "recordingtape"
        case .noAnswer: return "phone.down.fill"; case .busy: return "phone.badge.waveform.fill"
        case .wrongNumber: return "questionmark.circle.fill"; case .notInterested: return "hand.thumbsdown.fill"
        case .callback: return "arrow.uturn.left.circle.fill"; case .meetingBooked: return "calendar.badge.checkmark"
        }
    }
    /// A connected/positive disposition implies real engagement (used to advance status).
    var positive: Bool { self == .connected || self == .callback || self == .meetingBooked }
}

// MARK: - a logged call (real, on-device)

struct CallLog: Identifiable, Codable, Hashable {
    var id = UUID()
    var prospectID: UUID
    var phone: String = ""
    var at = Date()
    var disposition: CallDisposition = .noAnswer
    var durationSec: Int = 0
    var notes: String = ""
    var provider: String = "tel"          // "tel", "twilio", "telnyx", "manual"
}

// MARK: - telephony provider config (BYO; honest "connect a provider" gate)

/// Where a tel: hand-off actually opens on THIS platform — shared by every calling blurb so
/// an iPhone is never told about "your Mac's" dialer (§5.1).
enum TelephonyWords {
    #if os(iOS)
    static var defaultApp: String { "this \(PlatformWords.device)'s built-in calling app" }
    static var systemDialer: String { "this \(PlatformWords.device)'s dialer" }
    #else
    static let defaultApp = "your Mac's default calling app (FaceTime, or your iPhone via Continuity)"
    static let systemDialer = "your Mac's system dialer"
    #endif
}

enum TelephonyProvider: String, Codable, CaseIterable, Identifiable {
    case system   // tel: hand-off to the Mac's default calling app — always available, zero config
    case twilio
    case telnyx
    case manual   // log calls placed on a desk phone / cell, no integration
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System dialer (tel:)"; case .twilio: return "Twilio"
        case .telnyx: return "Telnyx"; case .manual: return "Manual log only"
        }
    }
    /// Providers that need an API credential before they can place a call programmatically.
    var needsCredential: Bool { self == .twilio || self == .telnyx }
    var blurb: String {
        switch self {
        case .system: return "Hands the number to \(TelephonyWords.defaultApp). No setup, no account."
        case .twilio: return "Place browser/Programmable-Voice calls through your own Twilio account. Connect your Account SID + Auth Token."
        case .telnyx: return "Use your own Telnyx voice account. Connect your API key."
        case .manual: return "Dial on your desk phone or cell and just log the outcome here — every call still lands on the prospect's timeline."
        }
    }
}

struct TelephonyConfig: Codable, Hashable {
    var provider: TelephonyProvider = .system
    var fromNumber: String = ""           // your caller-ID / outbound number (provider modes)
    var accountSID: String = ""           // Twilio Account SID / Telnyx connection id (non-secret id)
    /// the secret (auth token / API key) lives in Keychain keyed by `keychainAccount`, never here.
    var hasCredential: Bool = false

    var keychainAccount: String { "telephony:\(provider.rawValue):\(accountSID.isEmpty ? fromNumber : accountSID)" }

    /// Can this config actually place a programmatic call right now?
    var canPlaceProgrammatic: Bool {
        guard provider.needsCredential else { return false }
        return !fromNumber.isEmpty && !accountSID.isEmpty && hasCredential
    }

    init() {}
    enum CodingKeys: String, CodingKey { case provider, fromNumber, accountSID, hasCredential }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(TelephonyProvider.self, forKey: .provider)) ?? .system
        fromNumber = (try? c.decode(String.self, forKey: .fromNumber)) ?? ""
        accountSID = (try? c.decode(String.self, forKey: .accountSID)) ?? ""
        hasCredential = (try? c.decode(Bool.self, forKey: .hasCredential)) ?? false
    }
}

// MARK: - dialer (builds the tel: URL or reports the connect-a-provider state)

struct DialPlan {
    var canDial: Bool
    var telURL: URL?            // present for system/tel hand-off
    var usesProvider: Bool     // true if a programmatic provider call would be placed
    var message: String        // honest state, esp. when blocked
}

enum Dialer {
    /// Normalize a phone number to a `tel:`-safe form: keep digits and a leading +, strip the rest.
    static func normalize(_ raw: String) -> String {
        var out = ""
        for (i, ch) in raw.enumerated() {
            if ch.isNumber { out.append(ch) }
            else if ch == "+" && i == 0 { out.append(ch) }
            else if ch == "+" && out.isEmpty { out.append(ch) }
        }
        return out
    }

    static func telURL(for phone: String) -> URL? {
        let n = normalize(phone)
        guard n.filter({ $0.isNumber }).count >= 7 else { return nil }
        return URL(string: "tel:\(n)")
    }

    /// Honest description of what tapping Call does under the CURRENT config, independent of any
    /// specific number — the Calls screen's provider banner. Mirrors `plan(phone:config:)` exactly:
    /// where the provider mode lacks the server voice token this build doesn't include, we say so
    /// and never claim an in-app provider call.
    static func setupNote(config: TelephonyConfig) -> String {
        switch config.provider {
        case .system:
            return "Calls hand off to \(TelephonyWords.defaultApp). No setup, no account."
        case .manual:
            return "Dial on your desk phone or cell, then log the outcome here — every call still lands on the lead's timeline. The tel: link opens your default app too."
        case .twilio, .telnyx:
            return config.canPlaceProgrammatic
                ? "\(config.provider.label) credentials are connected, but in-app \(config.provider.label) calling needs a server voice token this build doesn't include — calls hand off to \(TelephonyWords.systemDialer) and log as 'tel'."
                : "Connect your \(config.provider.label) credentials in Settings → Calling. Until then (and until a server voice token exists) calls hand off to \(TelephonyWords.systemDialer) and log as 'tel'."
        }
    }

    /// Decide what happens when the buyer taps Call on a prospect, honoring their telephony config.
    static func plan(phone: String, config: TelephonyConfig) -> DialPlan {
        let n = normalize(phone)
        guard n.filter({ $0.isNumber }).count >= 7 else {
            return DialPlan(canDial: false, telURL: nil, usesProvider: false, message: "No valid phone number on this prospect.")
        }
        switch config.provider {
        case .system:
            return DialPlan(canDial: true, telURL: telURL(for: phone), usesProvider: false,
                            message: "Calls via \(TelephonyWords.defaultApp).")
        case .manual:
            return DialPlan(canDial: true, telURL: telURL(for: phone), usesProvider: false,
                            message: "Dial on your phone, then log the outcome. (tel: link opens your default app too.)")
        case .twilio, .telnyx:
            // In-app provider voice needs a server-side voice token this build does not have, so the
            // call always goes through the Mac's system dialer. Be honest: usesProvider:false (so the
            // call log records 'tel', not the provider) and never claim "Ready to place a {provider}
            // call" for a call that actually originates from the local dialer.
            return DialPlan(canDial: true, telURL: telURL(for: phone), usesProvider: false,
                            message: config.canPlaceProgrammatic
                                ? "Dialing via \(TelephonyWords.systemDialer) — in-app \(config.provider.label) calling needs a server voice token (not connected)."
                                : "Connect your \(config.provider.label) credentials in Settings → Calling to place calls in-app. Using the system dialer for now.")
        }
    }
}
