// Black Label Marketing — AI CAPTION ENGINE (Buffer gap).
//
// Real on-device AI captions (FoundationModels / Apple Intelligence, macOS 26) with the
// deterministic Studio.captions template engine preserved as the always-available fallback.
// Follows the exact ViralReelAI / CreativeIdeation pattern: availability-check → structured
// prompt → tolerant parse → honest fallback. NO paid/cloud dependency, NO network call.
//
// Every variant carries its `source` ("On-device AI" or "Template") so the UI can show
// honestly which engine wrote it — never a fabricated "AI" claim (§5.1). Hashtags come ONLY
// from the buyer's OWN BrandKit (name / city) — nothing invented to fill a gap.
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The platform a caption is written for — drives the hard length limit and hashtag budget.
enum CaptionPlatform: String, CaseIterable, Identifiable, Hashable {
    case x = "X", instagram = "Instagram", linkedin = "LinkedIn"
    var id: String { rawValue }
    /// Hard character limit for a post on this platform.
    var charLimit: Int {
        switch self {
        case .x: return 280
        case .instagram: return 2200
        case .linkedin: return 3000
        }
    }
    /// How many hashtags read naturally on this platform (a cap, never a promise).
    var hashtagBudget: Int {
        switch self { case .x: return 2; case .instagram: return 5; case .linkedin: return 3 }
    }
    var icon: String {
        switch self { case .x: return "text.bubble"; case .instagram: return "camera.fill"; case .linkedin: return "briefcase.fill" }
    }
}

/// One generated caption the buyer can copy, save, or regenerate. Structured
/// (hook / body / CTA / hashtags) so each part renders and edits cleanly.
struct CaptionVariant: Identifiable, Hashable {
    var id = UUID()
    var hook: String            // scroll-stopping first line ("" on template variants)
    var bodyText: String        // the caption body
    var cta: String             // one direct call to action ("" on template variants)
    var hashtags: [String]      // ONLY buyer-brand-derived or topic tags — never invented brands
    var platform: CaptionPlatform
    var source: String          // "On-device AI" or "Template" — always honest

    /// The caption exactly as it would be posted: hook, body, CTA, then hashtags.
    var fullText: String {
        var parts: [String] = []
        if !hook.isEmpty { parts.append(hook) }
        if !bodyText.isEmpty { parts.append(bodyText) }
        if !cta.isEmpty { parts.append(cta) }
        if !hashtags.isEmpty { parts.append(hashtags.joined(separator: " ")) }
        return parts.joined(separator: "\n\n")
    }
    var characterCount: Int { fullText.count }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum AICaptionEngine {
    static let aiSource = "On-device AI"
    static let templateSource = "Template"

    enum Availability { case ready, unavailable(String) }

    static func availability() -> Availability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .ready
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .unavailable("This \(PlatformWords.device) doesn't support Apple Intelligence — captions use the built-in templates.")
                case .appleIntelligenceNotEnabled: return .unavailable("Turn on Apple Intelligence in \(PlatformWords.settingsApp) to write captions with on-device AI. Templates always work.")
                case .modelNotReady: return .unavailable("The on-device model is still downloading — template captions until it's ready.")
                @unknown default: return .unavailable("On-device AI is unavailable right now — captions use the built-in templates.")
                }
            }
        } else { return .unavailable("On-device AI captions need \(PlatformWords.osName) 26 or later — the template captions always work.") }
        #else
        return .unavailable("On-device AI captions need \(PlatformWords.osName) 26 or later — the template captions always work.")
        #endif
    }

    /// Generate caption variants for a post. On-device AI when available; the deterministic
    /// Studio.captions template engine otherwise. NEVER returns empty, NEVER calls a network
    /// service, and every variant is labeled with the engine that actually produced it.
    static func generateCaptions(brief: String, tone: CaptionTone, platform: CaptionPlatform,
                                 brandKit: BrandKit, count: Int = 4) async -> [CaptionVariant] {
        let b = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *), case .ready = availability() {
            do {
                let session = LanguageModelSession()
                let resp = try await session.respond(to: prompt(brief: b, tone: tone, platform: platform, brandKit: brandKit, count: count))
                let parsed = parse(resp.content, platform: platform)
                if !parsed.isEmpty { return parsed.map(clamp) }
            } catch {
                // Honest template fallback below. A failed model call never blocks the buyer.
            }
        }
        #endif
        return templateFallback(brief: b, tone: tone, platform: platform, brandKit: brandKit)
    }

    /// The preserved deterministic path: Studio.captions template lines, with hashtags derived
    /// from the buyer's OWN brand kit. Honestly labeled "Template" — no AI claim.
    static func templateFallback(brief: String, tone: CaptionTone, platform: CaptionPlatform,
                                 brandKit: BrandKit) -> [CaptionVariant] {
        let tags = brandHashtags(from: brandKit, platform: platform)
        return Studio.captions(for: brief, tone: tone).map { line in
            clamp(CaptionVariant(hook: "", bodyText: line, cta: "", hashtags: tags,
                                 platform: platform, source: templateSource))
        }
    }

    // MARK: - Prompt

    private static func prompt(brief: String, tone: CaptionTone, platform: CaptionPlatform,
                               brandKit kit: BrandKit, count: Int) -> String {
        let tags = brandHashtags(from: kit, platform: platform)
        var context: [String] = [
            "Topic / offer: \(brief.isEmpty ? "the brand's latest offer" : brief)",
            "Brand: \(kit.resolvedName)"
        ]
        let tag = kit.tagline.trimmingCharacters(in: .whitespaces)
        if !tag.isEmpty { context.append("Tagline: \(tag)") }
        let city = kit.city.trimmingCharacters(in: .whitespaces)
        if !city.isEmpty { context.append("Market: \(city)") }
        let tagRule = tags.isEmpty
            ? "only tags built from the topic words"
            : "drawn from \(tags.joined(separator: " ")) plus topic words"
        return """
        You are a senior social media copywriter. Write \(count) distinct \(platform.rawValue) captions in a \(tone.rawValue.lowercased()) tone for this post:

        \(context.joined(separator: "\n"))

        Hard limit: the ENTIRE caption (hook + body + CTA + hashtags) must fit in \(platform.charLimit) characters.

        For EACH caption output exactly these four lines, then a blank line:
        HOOK: <a scroll-stopping first line, max 10 words>
        BODY: <the caption body>
        CTA: <one direct call to action, max 8 words>
        TAGS: <space-separated hashtags, \(tagRule), max \(platform.hashtagBudget)>

        Do not invent statistics, prices, discounts, awards, customer names, dates, or testimonials.
        Keep every claim general and truthful. No fabricated urgency or scarcity.
        """
    }

    // MARK: - Parse (tolerant of spacing/casing, like CreativeIdeation.parse)

    static func parse(_ text: String, platform: CaptionPlatform) -> [CaptionVariant] {
        var out: [CaptionVariant] = []
        var hook = "", body = "", cta = "", tags: [String] = []
        func flush() {
            if !hook.isEmpty || !body.isEmpty {
                out.append(CaptionVariant(hook: hook, bodyText: body, cta: cta, hashtags: tags,
                                          platform: platform, source: aiSource))
            }
            hook = ""; body = ""; cta = ""; tags = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if lower.hasPrefix("hook:") { if !hook.isEmpty || !body.isEmpty { flush() }; hook = strip(line, "hook:") }
            else if lower.hasPrefix("body:") { body = strip(line, "body:") }
            else if lower.hasPrefix("cta:") { cta = strip(line, "cta:") }
            else if lower.hasPrefix("tags:") {
                tags = strip(line, "tags:").components(separatedBy: .whitespaces)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.")) }
                    .filter { !$0.isEmpty && $0 != "#" }
                    .map { $0.hasPrefix("#") ? $0 : "#" + $0 }
            }
        }
        flush()
        return out
    }
    private static func strip(_ s: String, _ prefix: String) -> String {
        String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Platform length enforcement

    /// Enforce the platform's hard limit: cap the hashtag count, then (only if still over)
    /// drop hashtags and truncate the body at a word boundary. Deterministic — no rewriting.
    static func clamp(_ variant: CaptionVariant) -> CaptionVariant {
        var v = variant
        v.hashtags = Array(v.hashtags.prefix(v.platform.hashtagBudget))
        guard v.characterCount > v.platform.charLimit else { return v }
        v.hashtags = []
        if v.characterCount > v.platform.charLimit {
            let overhead = v.characterCount - v.bodyText.count
            let room = max(0, v.platform.charLimit - overhead - 1)
            v.bodyText = truncate(v.bodyText, to: room)
        }
        return v
    }

    /// Cut a string to `limit` characters at a word boundary (when one exists past the midpoint),
    /// appending an ellipsis so the cut is visible — never a silently chopped word.
    static func truncate(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        guard limit > 0 else { return "…" }
        let cut = String(s.prefix(limit))
        if let lastSpace = cut.lastIndex(of: " "),
           cut.distance(from: cut.startIndex, to: lastSpace) > limit / 2 {
            return String(cut[..<lastSpace]) + "…"
        }
        return cut + "…"
    }

    // MARK: - Brand-kit hashtags (buyer's OWN data only — §5.1)

    /// Hashtags derived ONLY from the buyer's own brand kit: brand name + market city.
    /// An empty kit yields an empty list — never a fabricated tag.
    static func brandHashtags(from kit: BrandKit, platform: CaptionPlatform) -> [String] {
        var tags: [String] = []
        let name = hashtag(from: kit.displayName)
        if !name.isEmpty { tags.append(name) }
        let city = hashtag(from: kit.city)
        if !city.isEmpty && city != name { tags.append(city) }
        return Array(tags.prefix(platform.hashtagBudget))
    }

    /// "Black Label Estate" → "#BlackLabelEstate"; "" / punctuation-only → "".
    static func hashtag(from raw: String) -> String {
        let words = raw.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return "" }
        return "#" + words.map { $0.capitalizedFirst }.joined()
    }
}
#endif // circuit-convert
