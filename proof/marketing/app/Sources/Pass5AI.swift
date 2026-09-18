// Black Label Marketing — AI CREATIVE IDEATION ENGINE (tier-5 flagship).
//
// On-device Apple Intelligence (FoundationModels, macOS 26) behind an @available guard.
// NO paid/cloud dependency. If the on-device model isn't present, the feature stays an
// HONEST gate AND the buyer still gets a real, deterministic concept generator (below) —
// never a fabricated "AI" result, never a network call.
//
// It proposes campaign CONCEPTS (angle + hook + channels + copy starter) from the buyer's
// OWN brand inputs (name, what they do, audience, goal). It invents creative ideas — which is
// the point — but it NEVER invents facts/metrics/results; the substrate of the app stays
// zero-fabrication. Concepts are drafts the buyer approves and turns into real campaigns.
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// One generated campaign concept the buyer can review and turn into a real campaign.
struct CreativeConcept: Identifiable, Hashable, Codable {
    var id = UUID()
    var angle: String          // the strategic angle ("Speed & reliability")
    var hook: String           // a headline / hook line
    var channels: [String]     // suggested channels
    var copyStarter: String    // a first-draft body the buyer edits
    var source: String         // "On-device AI" or "Template" — always honest
}

/// One saved ideation turn: the buyer's brief plus the concepts generated from it.
struct CreativeIdeationBatch: Identifiable, Hashable, Codable {
    var id = UUID()
    var brand: String = ""
    var does: String = ""
    var audience: String = ""
    var goal: String = ""
    var concepts: [CreativeConcept] = []
    var usedAI: Bool = false
    var created = Date()
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum CreativeIdeation {
    enum Availability { case ready, unavailable(String) }

    static func availability() -> Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable("This \(PlatformWords.device) doesn't support Apple Intelligence.")
                case .appleIntelligenceNotEnabled: return .unavailable("Turn on Apple Intelligence in \(PlatformWords.settingsApp) to use on-device AI ideation.")
                case .modelNotReady: return .unavailable("The on-device model is still downloading — try again shortly.")
                @unknown default: return .unavailable("On-device AI is unavailable right now.")
                }
            }
        } else { return .unavailable("On-device AI needs \(PlatformWords.osName) 26 or later. The template ideas below always work.") }
        #else
        return .unavailable("On-device AI needs \(PlatformWords.osName) 26 or later. The template ideas below always work.")
        #endif
    }

    private static func prompt(brand: String, does: String, audience: String, goal: String, count: Int) -> String {
        """
        You are a senior creative director. Propose \(count) distinct marketing campaign concepts for:
        Brand: \(brand.isEmpty ? "(unnamed brand)" : brand)
        What they do: \(does.isEmpty ? "(local business)" : does)
        Target audience: \(audience.isEmpty ? "(local customers)" : audience)
        Primary goal: \(goal.isEmpty ? "more leads" : goal)

        For EACH concept output exactly these four lines, then a blank line:
        ANGLE: <a strategic angle, 2-5 words>
        HOOK: <a punchy headline, max 12 words>
        CHANNELS: <2-3 channels, comma separated, from: Email, Social, Ads, Landing page, Video>
        COPY: <one tight opening paragraph, max 45 words, no emojis>

        Do not invent statistics, prices, awards, or testimonials. Keep claims general and truthful.
        """
    }

    /// Generate concepts on-device. Returns nil if the model is unavailable / errored
    /// (the caller falls back to `templates(...)`). NEVER calls a network service.
    static func generate(brand: String, does: String, audience: String, goal: String, count: Int = 3) async -> [CreativeConcept]? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            guard case .ready = availability() else { return nil }
            do {
                let session = LanguageModelSession()
                let resp = try await session.respond(to: prompt(brand: brand, does: does, audience: audience, goal: goal, count: count))
                let parsed = parse(resp.content)
                return parsed.isEmpty ? nil : parsed
            } catch { return nil }
        }
        #endif
        return nil
    }

    /// Parse the model's blocked output into concepts. Tolerant of spacing/casing.
    static func parse(_ text: String) -> [CreativeConcept] {
        var concepts: [CreativeConcept] = []
        var angle = "", hook = "", channels: [String] = [], copy = ""
        func flush() {
            if !angle.isEmpty || !hook.isEmpty || !copy.isEmpty {
                concepts.append(CreativeConcept(angle: angle.isEmpty ? "Concept" : angle,
                                                hook: hook, channels: channels.isEmpty ? ["Social", "Email"] : channels,
                                                copyStarter: copy, source: "On-device AI"))
            }
            angle = ""; hook = ""; channels = []; copy = ""
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("angle:") { if !angle.isEmpty { flush() }; angle = strip(line, "angle:") }
            else if lower.hasPrefix("hook:") { hook = strip(line, "hook:") }
            else if lower.hasPrefix("channels:") { channels = strip(line, "channels:").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            else if lower.hasPrefix("copy:") { copy = strip(line, "copy:") }
        }
        flush()
        return concepts
    }
    private static func strip(_ s: String, _ prefix: String) -> String {
        String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Deterministic, on-device template concepts — the always-available fallback. Real,
    /// usable starters built from the buyer's inputs; honestly labeled "Template" (no AI claim).
    static func templates(brand: String, does: String, audience: String, goal: String) -> [CreativeConcept] {
        let b = brand.trimmingCharacters(in: .whitespaces).isEmpty ? "your brand" : brand.trimmingCharacters(in: .whitespaces)
        let d = does.trimmingCharacters(in: .whitespaces).isEmpty ? "what you do best" : does.trimmingCharacters(in: .whitespaces).lowercased()
        let a = audience.trimmingCharacters(in: .whitespaces).isEmpty ? "local customers" : audience.trimmingCharacters(in: .whitespaces).lowercased()
        let g = goal.trimmingCharacters(in: .whitespaces).isEmpty ? "more leads" : goal.trimmingCharacters(in: .whitespaces).lowercased()
        return [
            CreativeConcept(angle: "Trust & proof",
                hook: "Why \(a) choose \(b)",
                channels: ["Landing page", "Email", "Social"],
                copyStarter: "Choosing the right partner for \(d) shouldn't be a gamble. \(b) earns trust the honest way — show up, do great work, repeat. Here's why \(a) keep coming back.",
                source: "Template"),
            CreativeConcept(angle: "Speed & ease",
                hook: "\(d.capitalizedFirst), without the headache",
                channels: ["Ads", "Social", "Landing page"],
                copyStarter: "You've got enough on your plate. \(b) makes \(d) simple — quick to start, easy to work with, and built around \(g). Reach out and we'll handle the rest.",
                source: "Template"),
            CreativeConcept(angle: "Local & personal",
                hook: "Your neighborhood team for \(d)",
                channels: ["Social", "Email"],
                copyStarter: "\(b) is part of this community. When \(a) need \(d), they want someone who actually answers the phone. That's us — friendly, reliable, and right around the corner.",
                source: "Template"),
        ]
    }
}
#endif // circuit-convert
// NOTE: `String.capitalizedFirst` is defined once in Model.swift and reused here.
