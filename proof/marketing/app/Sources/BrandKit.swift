// Black Label Marketing — BrandKit (MK-16).
//
// THE single, locked source of brand identity every generated asset reads. Before this, each
// generator took its own per-call brand arguments (name here, accent there, tagline somewhere
// else) and they could drift out of sync — a reel tinted one accent while the site used another.
// BrandKit fixes that: the reel engine, the landing-page builder (Studio), AND the outreach /
// email composer all read ONE BrandKit on every call, so the buyer's brand is applied identically
// across the reel .mp4, their site, and their email cadence.
//
// Pure value type — Foundation only, no Prefs / SwiftUI — so it runs headless in tests and can be
// compiled standalone. The Prefs bridge (`BrandKit(prefs:)`) and the live URLSession importer fetcher
// live in BrandKitLive.swift (app target only).
//
// Bindings: §5.1 zero fabrication. The domain importer NEVER invents a color, name, or logo — on any
// fetch/parse failure it returns the base kit UNCHANGED (an honest empty kit), so a buyer who imports
// from a bare domain gets exactly what was really found, never a made-up brand.
import Foundation

/// The buyer's locked brand identity, read by every asset generator on every call.
struct BrandKit: Equatable, Codable {
    /// Display brand name as the buyer typed it (may be empty → `resolvedName` falls back for copy).
    var displayName: String
    /// Primary/accent color as packed RGB (0xRRGGBB) — the reel tint + site accent.
    var accentHex: UInt32
    /// Secondary color as packed RGB — used where an asset needs a second brand color.
    var secondaryHex: UInt32
    /// Filesystem path (or absolute URL, from the importer) to the buyer's own logo; "" → none.
    var logoPath: String
    /// Display font family for headings; "" → the system default (never a fabricated licensed font).
    var fontName: String
    /// Buyer tagline (optional) — appended to the email signature and site trust copy when present.
    var tagline: String
    /// Buyer's own contact email — the site's lead route falls back to a mailto here.
    var contactEmail: String
    /// Target market/city (optional) — localizes reel + site copy.
    var city: String
    /// SitePalette rawValue driving the landing-page palette.
    var paletteName: String
    /// SiteTemplate rawValue driving the landing-page layout.
    var siteTemplateName: String
    /// Extra colors extracted from the buyer's logo/site (their real palette) — never invented.
    var extractedColors: [UInt32]

    init(displayName: String = "", accentHex: UInt32 = 0xD9B65C, secondaryHex: UInt32 = 0xB8923A,
         logoPath: String = "", fontName: String = "", tagline: String = "", contactEmail: String = "",
         city: String = "", paletteName: String = "Black & Gold", siteTemplateName: String = "Bold",
         extractedColors: [UInt32] = []) {
        self.displayName = displayName; self.accentHex = accentHex; self.secondaryHex = secondaryHex
        self.logoPath = logoPath; self.fontName = fontName; self.tagline = tagline
        self.contactEmail = contactEmail; self.city = city; self.paletteName = paletteName
        self.siteTemplateName = siteTemplateName; self.extractedColors = extractedColors
    }

    /// The honest empty kit — neutral product defaults, no buyer data, no fabricated brand. What a
    /// failed import returns, and where a fresh (empty) profile starts.
    static let empty = BrandKit()

    /// The name to print in copy — never blank (matches CampaignBrand.displayName's fallback).
    var resolvedName: String {
        let t = displayName.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Your Brand" : t
    }

    /// True when the buyer supplied a logo (drives the reel/site logo lockup; never fabricated).
    var hasLogo: Bool { !logoPath.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The accent as a web hex string "#RRGGBB" (for the site/email HTML).
    var accentWebHex: String { String(format: "#%06X", accentHex & 0xFFFFFF) }

    /// The brand-signed email signature block every drafted touch ends with — read from the locked
    /// kit on EVERY compose call so the sender identity never drifts per-message. Merge tokens only
    /// ({{sender}}), never a fabricated stat.
    var emailSignature: String {
        let tag = tagline.trimmingCharacters(in: .whitespaces)
        let line = "— {{sender}}, \(resolvedName)"
        return tag.isEmpty ? line : "\(line)\n\(tag)"
    }
}

/// Buyer-initiated importer: build a starter BrandKit from the buyer's OWN domain by reading its
/// public <head> (favicon / og / theme-color meta), Brandfetch-style but in-house (no paid API).
/// Every network read is injected through `Fetcher` so the parse + merge logic is unit-testable
/// without touching the network; the live URLSession fetcher lives in BrandKitLive.swift.
enum BrandKitImporter {

    /// Injected page fetcher. `.html` returns the raw HTML at the domain root, or nil on ANY failure
    /// (DNS, timeout, non-200) — the importer treats nil as "nothing found", never a fabricated page.
    struct Fetcher {
        var html: (_ domain: String) -> String?
    }

    /// Only the brand fields actually present on the site. Absent fields stay nil, so `merge` never
    /// overwrites a real value with a blank — and a site with no brand signals yields an all-nil parse.
    struct Parsed: Equatable {
        var name: String?
        var tagline: String?
        var accentHex: UInt32?
        var logoURL: String?
        var isEmpty: Bool { name == nil && tagline == nil && accentHex == nil && logoURL == nil }
    }

    /// Build a starter kit from the buyer's domain. On any fetch/parse failure returns `base`
    /// UNCHANGED — the honest empty path: never invents a color, name, or logo (§5.1).
    static func starterKit(forDomain rawDomain: String, base: BrandKit = .empty, fetcher: Fetcher) -> BrandKit {
        let domain = normalizedDomain(rawDomain)
        guard !domain.isEmpty, let html = fetcher.html(domain), !html.isEmpty else { return base }
        return merge(base: base, parsed: parse(html: html, domain: domain))
    }

    /// Merge parsed signals onto the base kit — ONLY where the parse actually found a value. A nil
    /// field leaves the base untouched, so nothing is fabricated to fill a gap.
    static func merge(base: BrandKit, parsed: Parsed) -> BrandKit {
        var kit = base
        if let n = parsed.name, !n.isEmpty { kit.displayName = n }
        if let t = parsed.tagline, !t.isEmpty { kit.tagline = t }
        if let a = parsed.accentHex {
            kit.accentHex = a
            if !kit.extractedColors.contains(a) { kit.extractedColors.append(a) }
        }
        if let logo = parsed.logoURL, !logo.isEmpty { kit.logoPath = logo }
        return kit
    }

    /// Parse brand signals from a site's HTML <head>. Pure + deterministic.
    static func parse(html: String, domain: String) -> Parsed {
        var p = Parsed()
        // Name: prefer og:site_name, then <title> (kept as-is; not truncated into a fabricated brand).
        if let n = propertyContent(html, "og:site_name") ?? titleText(html) {
            let trimmed = n.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { p.name = trimmed }
        }
        // Tagline: the site's own description.
        if let d = (metaContent(html, "description") ?? propertyContent(html, "og:description")) {
            let trimmed = d.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { p.tagline = trimmed }
        }
        // Accent: theme-color meta (a real hex the site declared) — only if it parses to a hex.
        if let tc = metaContent(html, "theme-color"), let hex = parseHexColor(tc) {
            p.accentHex = hex
        }
        // Logo: apple-touch-icon, then og:image, then the conventional /favicon.ico — resolved absolute.
        if let ref = linkHref(html, rel: "apple-touch-icon")
            ?? propertyContent(html, "og:image")
            ?? linkHref(html, rel: "icon") {
            let abs = absoluteURL(ref.trimmingCharacters(in: .whitespacesAndNewlines), domain: domain)
            if !abs.isEmpty { p.logoURL = abs }
        }
        return p
    }

    // MARK: - Pure parsing helpers

    /// Strip scheme/path/whitespace and lowercase → a bare host like "acme.com".
    static func normalizedDomain(_ s: String) -> String {
        var d = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where d.hasPrefix(scheme) { d = String(d.dropFirst(scheme.count)) }
        if d.hasPrefix("www.") { d = String(d.dropFirst(4)) }
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        return d.trimmingCharacters(in: .whitespaces)
    }

    /// Resolve a possibly-relative asset ref against the domain. Absolute URLs pass through.
    static func absoluteURL(_ ref: String, domain: String) -> String {
        if ref.isEmpty { return "" }
        if ref.hasPrefix("http://") || ref.hasPrefix("https://") { return ref }
        if ref.hasPrefix("//") { return "https:" + ref }
        let path = ref.hasPrefix("/") ? ref : "/" + ref
        return "https://" + domain + path
    }

    /// Parse "#RRGGBB", "RRGGBB", or "#RGB" into packed RGB. Returns nil for a named/unparseable
    /// color — we do NOT guess a hex from a color name (that would fabricate a brand color).
    static func parseHexColor(_ s: String) -> UInt32? {
        var h = s.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        if h.count == 3 {
            // #abc → #aabbcc
            var expanded = ""
            for ch in h { expanded.append(ch); expanded.append(ch) }
            h = expanded
        }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return v & 0xFFFFFF
    }

    /// `<meta name="X" content="...">` — quote-safe so an apostrophe inside a double-quoted value
    /// does not truncate the capture (a real bug the prior kit test locked).
    static func metaContent(_ html: String, _ name: String) -> String? {
        let v = NSRegularExpression.escapedPattern(for: name)
        let pat = "<meta[^>]*name=([\"'])\(v)\\1[^>]*content=([\"'])([\\s\\S]*?)\\2"
        return firstCapture(html, pat, group: 3)
    }

    /// `<meta property="og:X" content="...">`.
    static func propertyContent(_ html: String, _ property: String) -> String? {
        let v = NSRegularExpression.escapedPattern(for: property)
        let pat = "<meta[^>]*property=([\"'])\(v)\\1[^>]*content=([\"'])([\\s\\S]*?)\\2"
        return firstCapture(html, pat, group: 3)
    }

    /// `<link rel="X" href="...">` (rel and href in either order).
    static func linkHref(_ html: String, rel: String) -> String? {
        let v = NSRegularExpression.escapedPattern(for: rel)
        let a = "<link[^>]*rel=([\"'])\(v)\\1[^>]*href=([\"'])([\\s\\S]*?)\\2"
        if let m = firstCapture(html, a, group: 3) { return m }
        let b = "<link[^>]*href=([\"'])([\\s\\S]*?)\\1[^>]*rel=([\"'])\(v)\\3"
        return firstCapture(html, b, group: 2)
    }

    /// `<title>...</title>`.
    static func titleText(_ html: String) -> String? {
        firstCapture(html, "<title[^>]*>([\\s\\S]*?)</title>", group: 1)
    }

    private static func firstCapture(_ html: String, _ pattern: String, group: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > group else { return nil }
        let r = m.range(at: group)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }
}
