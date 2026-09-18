// Black Label Real Estate — AI OUTREACH COPY (on-device only, no paid API, no data leaves the Mac).
// Uses Apple's on-device FoundationModels (macOS 26 / Apple Intelligence) when available, behind an
// @available guard. There is NO paid/cloud dependency: if the on-device model isn't present, the
// feature stays an HONEST gate ("on-device AI unavailable") and the buyer keeps a real, deterministic
// template generator (below) — never a fabricated "AI" result and never a cloud call.
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AICopy {

    /// Availability of the on-device generator, with an honest human-readable reason when gated.
    enum Availability { case ready, unavailable(String) }

    static func availability() -> Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable("This \(kThisDeviceWord) doesn't support Apple Intelligence.")
                case .appleIntelligenceNotEnabled: return .unavailable("Turn on Apple Intelligence in System Settings to use on-device AI copy.")
                case .modelNotReady: return .unavailable("The on-device model is still downloading — try again shortly.")
                @unknown default: return .unavailable("On-device AI is unavailable right now.")
                }
            }
        } else {
            return .unavailable("On-device AI needs macOS 26 or later. Use the template generator below.")
        }
        #else
        return .unavailable("On-device AI needs macOS 26 or later. Use the template generator below.")
        #endif
    }

    /// The instruction prompt — short, compliant, audience-aware. Never fabricates property facts;
    /// it only writes copy around the AUDIENCE the user picked, with merge placeholders the buyer fills.
    private static func prompt(audience: String, channel: String, tone: String) -> String {
        """
        Write a short, warm, compliant real-estate seller-outreach \(channel) for the audience "\(audience)".
        Tone: \(tone). 90 words max. Be empathetic and low-pressure — these are often distressed or grieving sellers.
        Use {{name}} and {{property}} as merge placeholders (do not invent a name or address).
        Include a soft call to action and a clear opt-out line. Do not promise a price. No emojis.
        """
    }

    /// Generate copy on-device. Returns the generated text, or nil if the model is unavailable / errored
    /// (the caller falls back to `template(...)`). NEVER calls a network service.
    static func generate(audience: String, channel: String = "letter", tone: String = "professional and caring") async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            guard case .ready = availability() else { return nil }
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt(audience: audience, channel: channel, tone: tone))
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            } catch { return nil }
        }
        #endif
        return nil
    }

    /// Deterministic, on-device template generator — the always-available fallback. Real copy the
    /// buyer can use immediately; no AI claim, no fabrication (merge fields stay as placeholders).
    static func template(audience: String, channel: String = "letter") -> String {
        let opener: String
        switch audience.lowercased() {
        case let a where a.contains("probate"):
            opener = "I work with families navigating the estate of a loved one. If selling {{property}} would make a hard time simpler, I can buy it as-is — no repairs, no cleanout, no agent fees."
        case let a where a.contains("absentee"):
            opener = "I noticed you own {{property}} but live elsewhere. If managing it from a distance has become a hassle, I'd be glad to make you a straightforward cash offer."
        case let a where a.contains("foreclosure"):
            opener = "I understand things can get overwhelming fast. If keeping {{property}} isn't the right path, there may be options that protect your credit and put cash in your hands."
        case let a where a.contains("landlord"):
            opener = "Tired of tenants, toilets, and turnover at {{property}}? I buy rentals as-is, leases and all, so you can walk away clean."
        default:
            opener = "I'm a local investor interested in {{property}}. If you've thought about selling, I can make a fair, as-is cash offer with a closing date of your choosing."
        }
        let signoff = channel.lowercased().contains("text")
            ? "Reply STOP to opt out anytime."
            : "If now isn't the right time, no problem at all — just let me know and I won't reach out again."
        return "Hi {{name}},\n\n\(opener)\n\nWould you be open to a quick, no-obligation conversation?\n\n\(signoff)"
    }
}
