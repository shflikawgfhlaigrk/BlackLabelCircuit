// CampaignBuilder — the one-flow "Build campaign" engine (MK-20).
//
// Turns a single lead-DB category facet the buyer picks into three drafted assets in ONE step:
//   (a) a promo reel      — a ReelProject storyboard (materialized by CampaignBuilder.reelProject in
//                            the app via the shipped ReelEngine), tinted with the buyer's brand accent;
//   (b) a landing page    — the buyer's own site via the shipped Studio.landingPage (XSS-safe path);
//   (c) a 3-step email    — a brand-voiced OutreachSequence the buyer sends from their OWN mailbox.
//
// This file is deliberately dependency-light: it composes only Foundation + the merged Lead domain
// (OutreachSequence / SequenceStep from LeadDomain.swift). The heavy generators (Studio.landingPage,
// ReelEngine) are injected through `Generators` so the orchestration + the email copy are unit-testable
// in one compile unit, and wired to the real shipped code in CampaignBuilderLive.swift.
//
// Bindings: nothing here fabricates a metric, an audience size, or a testimonial (§5.1). The email
// copy carries ONLY merge tokens ({{first}}/{{company}}/{{sender}}) filled from the buyer's own
// connected data at send time — never an invented number. Nothing auto-sends; the flow stops at review.

import Foundation

/// The buyer's real brand identity, fed into every generated asset. A pure value type (no Prefs /
/// AppModel singletons) so the builder runs headless in tests. Built from Prefs in the app via the
/// `CampaignBrand(prefs:)` convenience in CampaignBuilderLive.swift.
struct CampaignBrand: Equatable {
    /// Display brand name (Prefs.displayBrand — never empty; falls back to a neutral placeholder).
    var name: String
    /// Brand accent as packed RGB (Prefs.brandAccentRGB) — applied to the reel + the site palette.
    var accentHex: UInt32
    /// SitePalette rawValue driving the landing-page palette.
    var paletteName: String
    /// SiteTemplate rawValue driving the landing-page layout.
    var siteTemplateName: String
    /// Buyer tagline (optional — appended to the email signature only when present).
    var tagline: String
    /// Buyer's own contact email — the landing page's lead route falls back to a mailto here.
    var contactEmail: String
    /// Target market/city (optional) — localizes the reel + site copy.
    var city: String
    /// Whether the buyer supplied a logo (drives the reel's optional logo asset; never fabricated).
    var hasLogo: Bool

    init(name: String, accentHex: UInt32, paletteName: String, siteTemplateName: String,
         tagline: String = "", contactEmail: String = "", city: String = "", hasLogo: Bool = false) {
        self.name = name; self.accentHex = accentHex; self.paletteName = paletteName
        self.siteTemplateName = siteTemplateName; self.tagline = tagline
        self.contactEmail = contactEmail; self.city = city; self.hasLogo = hasLogo
    }

    /// The name to print in copy — never blank.
    var displayName: String {
        let t = name.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Your Brand" : t
    }

    /// The LOCKED brand kit (MK-16) this campaign reads on every asset call — reel tint, site palette,
    /// and email signature all resolve from ONE kit so no per-call brand arg can drift out of sync.
    var kit: BrandKit {
        BrandKit(displayName: name, accentHex: accentHex, secondaryHex: accentHex,
                 logoPath: hasLogo ? "logo" : "", fontName: "", tagline: tagline,
                 contactEmail: contactEmail, city: city,
                 paletteName: paletteName, siteTemplateName: siteTemplateName, extractedColors: [])
    }
}

/// The drafted reel, as a storyboard spec. Materialized into a renderable ReelProject by
/// `CampaignBuilder.reelProject(from:brand:)` (app-side) using the real ReelEngine scenes.
struct CampaignReelSpec: Equatable {
    var name: String
    var category: String
    /// Brand accent (packed RGB) the reel renders with — proves the brand tint reaches the reel.
    var accentHex: UInt32
    /// ReelTemplate rawValue this campaign opens from.
    var templateRaw: String
    /// Draft scene headlines (from the shipped ReelTemplate.scenes) — real copy, no invented metrics.
    var headlines: [String]
}

/// The three assets a single "Build campaign" run produces.
struct CampaignBundle: Equatable {
    /// The lead-DB category facet this campaign targets (e.g. "Plumbing").
    var category: String
    /// How many leads in that facet — a REAL count read from the lead DB facets, never estimated.
    var matchCount: Int
    var reel: CampaignReelSpec
    var siteHTML: String
    var sequence: OutreachSequence

    /// True when all three assets drafted (a reachable reel, a rendered page, a 3-step cadence).
    var isComplete: Bool {
        !reel.headlines.isEmpty && !siteHTML.isEmpty && sequence.stepCount == 3
    }
}

/// Honest failure when the flow can't build — surfaced to the user, never swallowed.
enum CampaignBuildError: Error, LocalizedError, Equatable {
    case emptyFacet
    var errorDescription: String? {
        switch self {
        case .emptyFacet:
            return "Pick a lead category first — a campaign needs a real segment to build for."
        }
    }
}

enum CampaignBuilder {

    /// Injection seam for the heavy shipped generators, so the pure orchestration + email copy are
    /// testable without dragging Model.swift / ReelEngine into the unit-test compile unit. `.live`
    /// (CampaignBuilderLive.swift) wires the real Studio.landingPage + ReelTemplate.
    struct Generators {
        /// Render the buyer's landing page for this segment. `.live` → the XSS-safe Studio.landingPage.
        var renderSite: (CampaignBrand, String) -> String
        /// Draft reel scene headlines for this segment. `.live` → the shipped ReelTemplate.scenes.
        var reelHeadlines: (CampaignBrand, String) -> [String]
    }

    /// The ReelTemplate a one-flow campaign opens from (a 3-scene promo — matches the app's default).
    static let campaignTemplateRaw = "3-scene promo"

    /// Build all three assets from one picked category facet. Throws `emptyFacet` on a blank segment.
    static func build(facet category: String, matchCount: Int, brand: CampaignBrand,
                      generators: Generators) throws -> CampaignBundle {
        // Trim newlines as well as spaces/tabs: a facet that is only a newline (or a pasted blank
        // line) is NOT a real segment and must throw .emptyFacet, not build a phantom campaign.
        let cat = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cat.isEmpty else { throw CampaignBuildError.emptyFacet }

        let reel = CampaignReelSpec(
            name: "\(brand.displayName) — \(cat) campaign",
            category: cat,
            accentHex: brand.accentHex,
            templateRaw: campaignTemplateRaw,
            headlines: generators.reelHeadlines(brand, cat)
        )
        let site = generators.renderSite(brand, cat)
        let sequence = emailSequence(category: cat, brand: brand)

        return CampaignBundle(category: cat, matchCount: max(0, matchCount),
                              reel: reel, siteHTML: site, sequence: sequence)
    }

    /// A brand-voiced 3-step cold cadence for the segment. Merge tokens only — no fabricated stats,
    /// no invented reach/open-rate. The buyer's brand + tagline sign every touch; sends from their own
    /// mailbox after they enroll leads at the end of the flow (nothing auto-sends).
    static func emailSequence(category: String, brand: CampaignBrand) -> OutreachSequence {
        let cat = category.trimmingCharacters(in: .whitespaces)
        let catLower = cat.isEmpty ? "local" : cat.lowercased()
        // Signature comes from the locked brand kit (MK-16), read on every compose — so the email's
        // sender identity is the SAME brand the reel + site carry, never a per-call variant.
        let signature = brand.kit.emailSignature

        let intro = SequenceStep(
            delayDays: 0,
            subject: "A quick idea for {{company}}",
            body: """
            Hi {{first}},

            I work with \(catLower) businesses like {{company}}, and I put together a quick first-pass idea for you — a clean landing page and a short promo clip, built around your brand, not a template.

            Worth a two-minute look? I can send the preview over.

            \(signature)
            """)

        let followUp = SequenceStep(
            delayDays: 3,
            subject: "Re: A quick idea for {{company}}",
            subjectB: "Following up, {{first}}",
            body: """
            Hi {{first}},

            Floating this back to the top of your inbox. The idea for {{company}} is a modern page plus a promo reel you can post the same day — in your voice, ready to go.

            Happy to walk you through it whenever the timing's right.

            \(signature)
            """)

        let close = SequenceStep(
            delayDays: 4,
            subject: "Last note, {{first}}",
            body: """
            Hi {{first}},

            I'll close the loop here. If getting {{company}} in front of more \(catLower) customers is ever on your list, just reply and I'll pick it back up.

            \(signature)
            """)

        return OutreachSequence(name: "\(brand.displayName) → \(cat) campaign",
                                steps: [intro, followUp, close])
    }
}
