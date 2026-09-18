// CampaignBuilderLive — wires the pure CampaignBuilder to the real shipped generators.
//
// Kept separate from CampaignBuilder.swift so the pure orchestration + email copy compile (and unit-
// test) without dragging Model.swift (Studio.landingPage) or ReelEngine into the test's single compile
// unit. This file is part of the app target only; the reel + site here are the SAME shipped code paths
// the rest of the app uses (Studio.landingPage's XSS-safe render, ReelTemplate's real scenes).

import Foundation

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension CampaignBrand {
    /// Pull the buyer's real brand identity from Prefs — nothing fabricated. Optional `city` override
    /// lets the campaign target a market other than the saved default.
    init(prefs: Prefs, city: String? = nil) {
        self.init(
            name: prefs.displayBrand,
            accentHex: prefs.brandAccentRGB,
            paletteName: prefs.sitePalette.rawValue,
            siteTemplateName: prefs.siteTemplate.rawValue,
            tagline: prefs.tagline,
            contactEmail: prefs.contactEmail,
            city: (city ?? prefs.defaultMarket).trimmingCharacters(in: .whitespaces),
            hasLogo: prefs.logoData != nil
        )
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension CampaignBuilder {
    /// The real generators: the shipped landing-page builder and reel storyboard, BOTH reading the
    /// buyer's LOCKED brand kit (MK-16) on every call so the site palette and the reel tint can't drift.
    static let live = Generators(
        renderSite: { brand, category in
            // Studio.landingPage(kit:) HTML- and URL-escapes every injected field (proven by SiteContentTests).
            Studio.landingPage(kit: brand.kit, type: category)
        },
        reelHeadlines: { brand, category in
            ReelTemplate.promo3.scenes(kit: brand.kit, topic: category).map { $0.headline }
        }
    )

    /// Build the full campaign with the real shipped generators.
    static func buildLive(facet category: String, matchCount: Int, brand: CampaignBrand) throws -> CampaignBundle {
        try build(facet: category, matchCount: matchCount, brand: brand, generators: live)
    }

    /// Materialize the drafted reel spec into a renderable ReelProject — real ReelEngine scenes read
    /// from the buyer's locked brand kit (name/city/accent), ready for ReelRenderer.render(...).
    static func reelProject(from spec: CampaignReelSpec, brand: CampaignBrand) -> ReelProject {
        let template = ReelTemplate(rawValue: spec.templateRaw) ?? .promo3
        return ReelProject(template: template, topic: spec.category, kit: brand.kit, name: spec.name)
    }
}
#endif // circuit-convert
