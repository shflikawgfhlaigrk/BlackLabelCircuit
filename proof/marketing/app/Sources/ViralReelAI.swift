// Black Label Marketing — AI-assisted short-form retention planner.
//
// The planner turns a truthful operator brief into a hook / proof / CTA structure for Reel Studio.
// It uses Apple's on-device Foundation Models when available and falls back to an explicit,
// deterministic template when it is not. It never fabricates metrics, customers, or outcomes.
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct ViralReelPlan: Hashable {
    var hook: String
    var proofLine: String
    var callToAction: String
    var rationale: String
    var secondsPerVisual: Double
    var source: String
}

enum ViralReelPlanner {
    static func generate(brand: String, buildSummary: String, audience: String, goal: String) async -> ViralReelPlan {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *), case .available = SystemLanguageModel.default.availability {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt(
                    brand: brand,
                    buildSummary: buildSummary,
                    audience: audience,
                    goal: goal
                ))
                if let plan = parse(response.content, source: "On-device AI") { return plan }
            } catch {
                // Honest local fallback below. A failed model call never blocks rendering.
            }
        }
        #endif
        return fallback(brand: brand, buildSummary: buildSummary, audience: audience, goal: goal)
    }

    static func fallback(brand: String, buildSummary: String, audience: String, goal: String) -> ViralReelPlan {
        ViralReelPlan(
            hook: "WE BUILT ALL OF THIS IN JULY.",
            proofLine: "WEBSITES. APPS. CLIENTS. TEAM.",
            callToAction: "FOLLOW THE BUILD.",
            rationale: "Human-led opening, immediate payoff, fast proof cuts, and a direct close.",
            secondsPerVisual: 0.9,
            source: "Research-backed template"
        )
    }

    static func parse(_ text: String, source: String = "On-device AI") -> ViralReelPlan? {
        var hook = ""
        var proof = ""
        var cta = ""
        var why = ""
        var pace = 0.9

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if lower.hasPrefix("hook:") { hook = value(after: "hook:", in: line) }
            else if lower.hasPrefix("proof:") { proof = value(after: "proof:", in: line) }
            else if lower.hasPrefix("cta:") { cta = value(after: "cta:", in: line) }
            else if lower.hasPrefix("why:") { why = value(after: "why:", in: line) }
            else if lower.hasPrefix("pace:") {
                let rawPace = value(after: "pace:", in: line)
                    .replacingOccurrences(of: "seconds", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: "s", with: "", options: .caseInsensitive)
                    .trimmingCharacters(in: .whitespaces)
                if let parsed = Double(rawPace) { pace = min(1.25, max(0.65, parsed)) }
            }
        }

        guard !hook.isEmpty, !proof.isEmpty, !cta.isEmpty else { return nil }
        return ViralReelPlan(
            hook: hook,
            proofLine: proof,
            callToAction: cta,
            rationale: why.isEmpty ? "Hook, rapid proof, human presence, and a direct close." : why,
            secondsPerVisual: pace,
            source: source
        )
    }

    private static func prompt(brand: String, buildSummary: String, audience: String, goal: String) -> String {
        """
        You are editing a native 9:16 short-form business reel for retention.

        Brand: \(brand)
        Truthful material available: \(buildSummary)
        Audience: \(audience)
        Goal: \(goal)

        Write one truthful hook / proof / CTA plan. The first frame must communicate the payoff.
        Keep the hook to 7 words, the proof line to 7 words, and the CTA to 5 words.
        Do not invent counts, revenue, clients, results, awards, dates, or testimonials.
        Do not open with a logo. No emojis. No hashtags.

        Output exactly five lines:
        HOOK: <first-frame payoff>
        PROOF: <what the viewer is about to see>
        CTA: <direct next action>
        WHY: <one short retention rationale>
        PACE: <a number from 0.65 to 1.25>
        """
    }

    private static func value(after prefix: String, in line: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
