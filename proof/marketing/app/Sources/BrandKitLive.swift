// Black Label Marketing — BrandKitLive (MK-16).
//
// The app-target bridges for the pure BrandKit: build the locked kit from the buyer's saved Prefs,
// and the live (buyer-initiated) URLSession fetcher for the domain importer. Kept out of BrandKit.swift
// so the pure kit + importer parse logic compile standalone in tests (no Prefs / networking).
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension BrandKit {
    /// The locked kit built from the buyer's real saved brand identity — nothing fabricated.
    /// `city` optionally overrides the saved default market for a one-off campaign.
    init(prefs: Prefs, city: String? = nil) {
        self.init(
            displayName: prefs.brandName,
            accentHex: prefs.brandAccentRGB,
            secondaryHex: prefs.brandColors.dropFirst().first ?? prefs.sitePalette.accentRGB,
            logoPath: "",                                   // buyer's logo is stored as Data in Prefs (logoData)
            fontName: "",
            tagline: prefs.tagline,
            contactEmail: prefs.contactEmail,
            city: (city ?? prefs.defaultMarket).trimmingCharacters(in: .whitespaces),
            paletteName: prefs.sitePalette.rawValue,
            siteTemplateName: prefs.siteTemplate.rawValue,
            extractedColors: prefs.brandColors
        )
    }

    /// Apply an imported starter kit back onto the buyer's Prefs — only fields the import actually
    /// found (guarded so an empty import never wipes the buyer's existing brand). Buyer-initiated.
    func applyImported(to prefs: Prefs) {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { prefs.brandName = name }
        let tag = tagline.trimmingCharacters(in: .whitespaces)
        if !tag.isEmpty { prefs.tagline = tag }
        if !extractedColors.isEmpty {
            prefs.brandColors = extractedColors
            prefs.customAccentHex = accentHex
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension BrandKitImporter {
    /// The live fetcher: a synchronous, buyer-initiated GET of the domain root through the egress
    /// choke point on the declared `userDirectedFetch` lane.
    /// Returns nil on ANY failure so the importer falls back to the honest empty kit (never fabricates).
    /// Call OFF the main thread (the campaign/settings importer already runs in a Task).
    static let liveFetcher = Fetcher { domain in
        let clean = normalizedDomain(domain)
        guard !clean.isEmpty, let url = URL(string: "https://" + clean + "/") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (BlackLabelMarketing BrandKit importer)", forHTTPHeaderField: "User-Agent")
        var html: String?
        let sem = DispatchSemaphore(value: 0)
        ConsentedEgress.sendUngated(request, lane: .userDirectedFetch) { data, response, _ in
            defer { sem.signal() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data = data, let body = String(data: data, encoding: .utf8) else { return }
            html = body
        }
        _ = sem.wait(timeout: .now() + 15)
        return html
    }

    /// Convenience: build a starter kit from the buyer's own domain over the real network.
    static func liveStarterKit(forDomain domain: String, base: BrandKit = .empty) -> BrandKit {
        starterKit(forDomain: domain, base: base, fetcher: liveFetcher)
    }
}
#endif // circuit-convert
