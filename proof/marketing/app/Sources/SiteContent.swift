// Black Label Marketing — Site Studio content model.
// Real copy slots the buyer fills for a full multi-section site: about, custom services,
// testimonials, FAQ, stats, hours, service area. Ships EMPTY — every section is honest-empty
// and simply omitted when the buyer hasn't supplied it. We NEVER fabricate a testimonial, a
// star rating, or a stat; the only numbers on a generated page are ones the buyer typed in.
import Foundation

struct SiteService: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var detail: String = ""
}

/// A real customer testimonial the buyer entered. Never generated, never seeded.
struct Testimonial: Identifiable, Codable, Hashable {
    var id = UUID()
    var quote: String = ""
    var author: String = ""
}

struct FAQItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var q: String = ""
    var a: String = ""
}

/// A headline metric shown in the trust bar. Buyer-supplied real numbers ONLY (e.g. "15" / "Years
/// in business"). The generator renders these verbatim — it never invents or rounds a figure.
struct SiteStat: Identifiable, Codable, Hashable {
    var id = UUID()
    var value: String = ""
    var label: String = ""
}

/// The movable content bands below the fixed hero. A stable Codable enum keeps the order portable
/// across live previews, saved projects, and every export format.
enum SiteSection: String, CaseIterable, Codable, Hashable, Identifiable {
    case stats, services, about, testimonials, faq, contact

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stats: return "Stats"
        case .services: return "Services"
        case .about: return "About"
        case .testimonials: return "Testimonials"
        case .faq: return "FAQ"
        case .contact: return "Contact"
        }
    }
    var icon: String {
        switch self {
        case .stats: return "chart.bar.fill"
        case .services: return "square.grid.2x2.fill"
        case .about: return "building.2.fill"
        case .testimonials: return "quote.bubble.fill"
        case .faq: return "questionmark.bubble.fill"
        case .contact: return "envelope.fill"
        }
    }

    static let defaultOrder: [SiteSection] = [.stats, .services, .about, .testimonials, .faq, .contact]

    /// Repair duplicate, partial, or future-migrated arrays without losing a section.
    static func normalized(_ order: [SiteSection]) -> [SiteSection] {
        var seen = Set<SiteSection>()
        return (order + defaultOrder).filter { seen.insert($0).inserted }
    }
}

/// Everything the buyer can add to a generated site beyond the basics. All optional; the site
/// generator includes a section only when its content is non-empty (honest empty state).
struct SiteContent: Codable, Hashable {
    var about: String = ""
    var services: [SiteService] = []
    var testimonials: [Testimonial] = []
    var faqs: [FAQItem] = []
    var stats: [SiteStat] = []
    var hours: String = ""
    var serviceArea: String = ""
    var email: String = ""        // public contact email shown on the page (the buyer's own)
    var ctaLabel: String = ""     // override the primary CTA label
    var sectionOrder: [SiteSection] = SiteSection.defaultOrder

    /// Non-empty entries only (a blank row the buyer left half-filled is dropped, never rendered).
    var cleanServices: [SiteService] { services.filter { !$0.title.trimmingCharacters(in: .whitespaces).isEmpty } }
    var cleanTestimonials: [Testimonial] { testimonials.filter { !$0.quote.trimmingCharacters(in: .whitespaces).isEmpty } }
    var cleanFAQs: [FAQItem] { faqs.filter { !$0.q.trimmingCharacters(in: .whitespaces).isEmpty } }
    var cleanStats: [SiteStat] { stats.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty } }
    var orderedSections: [SiteSection] { SiteSection.normalized(sectionOrder) }

    var isEmpty: Bool {
        about.trimmingCharacters(in: .whitespaces).isEmpty && cleanServices.isEmpty && cleanTestimonials.isEmpty
        && cleanFAQs.isEmpty && cleanStats.isEmpty && hours.trimmingCharacters(in: .whitespaces).isEmpty
        && serviceArea.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

// MARK: - Deploy pack

/// Turns a generated page into a small, genuinely deployable site folder: index.html plus
/// robots.txt, sitemap.xml, and a short deploy guide for the free hosts (Netlify Drop,
/// Cloudflare Pages, GitHub Pages). Honest by design: the sitemap and the robots Sitemap line
/// exist ONLY when the buyer supplies a real https/http site URL — we never invent a domain.
enum SiteDeploy {

    /// Normalized canonical URL: trimmed, trailing slash dropped, http(s) only — anything else
    /// (a bare word, javascript:, mailto:) is treated as "no URL yet" so we never emit a fake one.
    static func canonicalURL(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t = String(t.dropLast()) }
        let lower = t.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return "" }
        // Reject if there's nothing after the scheme.
        let rest = t.drop(while: { $0 != ":" }).dropFirst(3)
        return rest.isEmpty ? "" : t
    }

    /// Minimal XML escaping for the URL embedded in sitemap.xml.
    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The files of the deploy pack, in write order. `html` is the generated page verbatim.
    static func pack(html: String, siteName: String, siteURL: String, today: Date = Date()) -> [(name: String, body: String)] {
        let url = canonicalURL(siteURL)
        var files: [(String, String)] = [("index.html", html)]

        var robots = "User-agent: *\nAllow: /\n"
        if !url.isEmpty { robots += "Sitemap: \(url)/sitemap.xml\n" }
        files.append(("robots.txt", robots))

        if !url.isEmpty {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"; fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = TimeZone(identifier: "UTC")
            let sitemap = """
            <?xml version="1.0" encoding="UTF-8"?>
            <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
              <url><loc>\(xmlEscape(url))/</loc><lastmod>\(fmt.string(from: today))</lastmod></url>
            </urlset>
            """
            files.append(("sitemap.xml", sitemap))
        }

        let n = siteName.trimmingCharacters(in: .whitespaces).isEmpty ? "your site" : siteName.trimmingCharacters(in: .whitespaces)
        let urlNote = url.isEmpty
            ? "No domain yet? That's fine — this pack works as-is. Once you have one, re-export with your site URL set and a sitemap.xml is included automatically."
            : "Canonical URL: \(url)"
        let readme = """
        # Deploying \(n)

        This folder is a complete static site — no build step, no dependencies.
        \(urlNote)

        Pick any free host:

        ## Netlify Drop (fastest)
        1. Open https://app.netlify.com/drop
        2. Drag this whole folder onto the page. Done — you get a live URL.

        ## Cloudflare Pages
        1. https://pages.cloudflare.com -> Create a project -> Direct upload.
        2. Upload this folder. Free SSL + global CDN included.

        ## GitHub Pages
        1. Create a repository and push these files to its root.
        2. Settings -> Pages -> deploy from branch (root). Your site appears at
           https://<user>.github.io/<repo>/

        ## Point your domain
        Add your domain in the host's dashboard and follow its DNS instructions
        (usually one CNAME record). SSL is automatic on all three hosts.
        """
        files.append(("DEPLOY.md", readme))
        return files
    }
}


// Robust decode: every field defaults when absent, so a SiteContent written by an older app build
// (before email/ctaLabel existed) still loads instead of throwing keyNotFound.
extension SiteContent {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        about = (try? c.decode(String.self, forKey: .about)) ?? ""
        services = (try? c.decode([SiteService].self, forKey: .services)) ?? []
        testimonials = (try? c.decode([Testimonial].self, forKey: .testimonials)) ?? []
        faqs = (try? c.decode([FAQItem].self, forKey: .faqs)) ?? []
        stats = (try? c.decode([SiteStat].self, forKey: .stats)) ?? []
        hours = (try? c.decode(String.self, forKey: .hours)) ?? ""
        serviceArea = (try? c.decode(String.self, forKey: .serviceArea)) ?? ""
        email = (try? c.decodeIfPresent(String.self, forKey: .email)) ?? ""
        ctaLabel = (try? c.decodeIfPresent(String.self, forKey: .ctaLabel)) ?? ""
        sectionOrder = SiteSection.normalized((try? c.decodeIfPresent([SiteSection].self, forKey: .sectionOrder)) ?? [])
    }
}
