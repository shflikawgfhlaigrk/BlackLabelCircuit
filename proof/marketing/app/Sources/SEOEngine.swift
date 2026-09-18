// Black Label Marketing — Brand Audit + SEO engine.
//
// Runs on the buyer's OWN page: a real HTTP fetch (URLSession) of a URL the buyer
// types, then a deterministic, honest analysis of the returned HTML. A signal is
// either present in the fetched document or it is not — NOTHING is fabricated.
// There are no invented "search volumes," no fake rankings, no paid SEO API.
//
// The PURE logic below (HTMLProbe / AuditEngine / KeywordEngine / SchemaEngine) is
// mirrored by Tests/SEOTests.swift and is fully covered there. Only the network
// fetch (PageFetcher) is impure, and it surfaces real errors honestly.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Page signals (what we actually extract from the fetched HTML)

struct PageSignals {
    var url = ""
    var finalURL = ""
    var statusCode = 0
    var isHTTPS = false
    var title = ""
    var metaDescription = ""
    var hasViewport = false
    var h1s: [String] = []
    var h2Count = 0
    var imgCount = 0
    var imgMissingAlt = 0
    var hasOpenGraph = false
    var hasTwitterCard = false
    var hasCanonical = false
    var hasJSONLD = false
    var wordCount = 0
    var linkCount = 0
    var htmlBytes = 0
}

enum Severity: String { case good, warn, fail }
struct AuditItem: Identifiable {
    let id = UUID()
    var label: String
    var severity: Severity
    var detail: String
    var weight: Int
}

// MARK: - HTML probe (pure regex extraction — mirrors Tests/SEOTests.swift)

enum HTMLProbe {
    static func attr(_ tag: String, _ attr: String) -> String? {
        let patterns = ["\(attr)\\s*=\\s*\"([^\"]*)\"", "\(attr)\\s*=\\s*'([^']*)'"]
        for p in patterns {
            if let r = tag.range(of: p, options: [.regularExpression, .caseInsensitive]) {
                let m = String(tag[r])
                if let v = m.range(of: "\"([^\"]*)\"|'([^']*)'", options: .regularExpression) {
                    return String(m[v]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                }
            }
        }
        return nil
    }
    static func firstGroup(_ html: String, _ pattern: String) -> String? {
        guard let r = html.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let chunk = String(html[r])
        if let open = chunk.range(of: ">"), let close = chunk.range(of: "<", range: open.upperBound..<chunk.endIndex) {
            return String(chunk[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
    static func count(_ html: String, _ pattern: String) -> Int {
        let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(html.startIndex..., in: html)
        return re?.numberOfMatches(in: html, range: range) ?? 0
    }
    static func stripTags(_ html: String) -> String {
        var s = html
        for block in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>"] {
            s = s.replacingOccurrences(of: block, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    static func matches(_ html: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return re.matches(in: html, range: range).compactMap { Range($0.range, in: html).map { String(html[$0]) } }
    }
    /// Parse a full HTML document into PageSignals.
    static func parse(_ html: String, url: String, finalURL: String, status: Int) -> PageSignals {
        var s = PageSignals()
        s.url = url; s.finalURL = finalURL; s.statusCode = status
        s.isHTTPS = finalURL.lowercased().hasPrefix("https://")
        s.htmlBytes = html.utf8.count
        if let t = firstGroup(html, "<title[^>]*>[\\s\\S]*?</title>") { s.title = t }
        for m in matches(html, "<meta[^>]+>") {
            let nameAttr = (attr(m, "name") ?? attr(m, "property") ?? "").lowercased()
            if nameAttr == "description", let c = attr(m, "content") { s.metaDescription = c }
            if nameAttr == "viewport" { s.hasViewport = true }
            if nameAttr.hasPrefix("og:") { s.hasOpenGraph = true }
            if nameAttr.hasPrefix("twitter:") { s.hasTwitterCard = true }
        }
        s.h1s = matches(html, "<h1[^>]*>[\\s\\S]*?</h1>").map { stripTags($0) }.filter { !$0.isEmpty }
        s.h2Count = count(html, "<h2[\\s>]")
        let imgs = matches(html, "<img[^>]*>")
        s.imgCount = imgs.count
        s.imgMissingAlt = imgs.filter { (attr($0, "alt") ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count
        s.hasCanonical = count(html, "<link[^>]+rel\\s*=\\s*[\"']canonical[\"']") > 0
        s.hasJSONLD = count(html, "<script[^>]+type\\s*=\\s*[\"']application/ld\\+json[\"']") > 0
        s.wordCount = stripTags(html).split(separator: " ").count
        s.linkCount = count(html, "<a[\\s][^>]*href")
        return s
    }
}

// MARK: - Audit scoring rubric (deterministic, honest — mirrors the tests)

enum AuditEngine {
    static func items(_ s: PageSignals) -> [AuditItem] {
        var out: [AuditItem] = []
        out.append(AuditItem(label: "HTTPS", severity: s.isHTTPS ? .good : .fail,
                             detail: s.isHTTPS ? "Served over HTTPS." : "Not served over HTTPS — required for trust & ranking.", weight: 12))
        let tlen = s.title.count
        out.append(AuditItem(label: "Title tag",
                             severity: tlen == 0 ? .fail : (tlen < 15 || tlen > 65 ? .warn : .good),
                             detail: tlen == 0 ? "Missing <title>." : ("\(tlen) chars" + (tlen < 15 ? " — too short." : (tlen > 65 ? " — may be truncated in search results." : " — good length."))),
                             weight: 14))
        let dlen = s.metaDescription.count
        out.append(AuditItem(label: "Meta description",
                             severity: dlen == 0 ? .fail : (dlen < 50 || dlen > 165 ? .warn : .good),
                             detail: dlen == 0 ? "Missing meta description." : ("\(dlen) chars" + (dlen < 50 ? " — too short." : (dlen > 165 ? " — may be truncated." : " — good length."))),
                             weight: 12))
        out.append(AuditItem(label: "Mobile viewport", severity: s.hasViewport ? .good : .fail,
                             detail: s.hasViewport ? "Responsive viewport set." : "No viewport meta — page won't be mobile-friendly.", weight: 10))
        out.append(AuditItem(label: "H1 heading",
                             severity: s.h1s.isEmpty ? .fail : (s.h1s.count > 1 ? .warn : .good),
                             detail: s.h1s.isEmpty ? "No H1 heading." : (s.h1s.count > 1 ? "\(s.h1s.count) H1s — use exactly one." : "Single H1: \"\(s.h1s[0].prefix(40))\""), weight: 10))
        out.append(AuditItem(label: "Image alt text",
                             severity: s.imgCount == 0 ? .good : (s.imgMissingAlt == 0 ? .good : (s.imgMissingAlt > s.imgCount / 2 ? .fail : .warn)),
                             detail: s.imgCount == 0 ? "No images." : "\(s.imgMissingAlt) of \(s.imgCount) images missing alt text.", weight: 8))
        out.append(AuditItem(label: "Social (Open Graph)", severity: s.hasOpenGraph ? .good : .warn,
                             detail: s.hasOpenGraph ? "Open Graph tags present." : "No Open Graph tags — links won't preview well when shared.", weight: 8))
        out.append(AuditItem(label: "Canonical URL", severity: s.hasCanonical ? .good : .warn,
                             detail: s.hasCanonical ? "Canonical link present." : "No canonical link — risk of duplicate-content dilution.", weight: 6))
        out.append(AuditItem(label: "Structured data (JSON-LD)", severity: s.hasJSONLD ? .good : .warn,
                             detail: s.hasJSONLD ? "JSON-LD structured data present." : "No structured data — add JSON-LD to enable rich results / AI citation.", weight: 8))
        out.append(AuditItem(label: "Content depth",
                             severity: s.wordCount >= 300 ? .good : (s.wordCount >= 100 ? .warn : .fail),
                             detail: "\(s.wordCount) words of visible text.", weight: 6))
        return out
    }
    static func score(_ items: [AuditItem]) -> Int {
        let total = items.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        let earned = items.reduce(0.0) { acc, it in
            switch it.severity { case .good: return acc + Double(it.weight); case .warn: return acc + Double(it.weight) * 0.5; case .fail: return acc }
        }
        return Int((earned / Double(total) * 100).rounded())
    }
    static func quickWins(_ items: [AuditItem]) -> [AuditItem] {
        items.filter { $0.severity != .good }.sorted { $0.weight > $1.weight }
    }
    /// Letter grade for the headline number.
    static func grade(_ score: Int) -> String {
        switch score { case 90...: return "A"; case 80..<90: return "B"; case 70..<80: return "C"; case 55..<70: return "D"; default: return "F" }
    }
}

// MARK: - Keyword ideas (derived from the buyer's own seed — no fabricated volumes)

enum KeywordEngine {
    static let modifiers = ["near me", "best", "affordable", "professional", "services", "cost", "reviews", "company"]
    static let intents = ["how to", "what is", "why", "tips for"]
    static func ideas(seed: String, city: String) -> [String] {
        let s = seed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return [] }
        var out: [String] = []
        let c = city.trimmingCharacters(in: .whitespaces).lowercased()
        if !c.isEmpty { out.append("\(s) \(c)"); out.append("\(s) in \(c)") }
        for m in modifiers { out.append(m == "near me" ? "\(s) \(m)" : "\(m) \(s)") }
        for i in intents { out.append("\(i) \(s)") }
        var seen = Set<String>(); return out.filter { seen.insert($0).inserted }
    }
}

// MARK: - Schema (JSON-LD) generator — valid LocalBusiness markup, injection-safe

enum SchemaEngine {
    static func esc(_ s: String) -> String {
        // JSON string escaping + the JSON-LD-in-<script> mitigation (escape `<`/`>`
        // as </> so a "</script>" inside a value can't break out).
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "<", with: "\\u003c")
         .replacingOccurrences(of: ">", with: "\\u003e")
    }
    static func localBusiness(name: String, type: String, phone: String, city: String, url: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        let ph = phone.trimmingCharacters(in: .whitespaces)
        let u = url.trimmingCharacters(in: .whitespaces)
        let c = city.trimmingCharacters(in: .whitespaces)
        let ty = type.trimmingCharacters(in: .whitespaces)
        var fields: [String] = ["\"@context\": \"https://schema.org\"", "\"@type\": \"LocalBusiness\""]
        if !n.isEmpty { fields.append("\"name\": \"\(esc(n))\"") }
        if !ph.isEmpty { fields.append("\"telephone\": \"\(esc(ph))\"") }
        if !u.isEmpty { fields.append("\"url\": \"\(esc(u))\"") }
        if !c.isEmpty { fields.append("\"address\": { \"@type\": \"PostalAddress\", \"addressLocality\": \"\(esc(c))\" }") }
        if !ty.isEmpty { fields.append("\"description\": \"\(esc(ty))\"") }
        return "<script type=\"application/ld+json\">\n{\n  " + fields.joined(separator: ",\n  ") + "\n}\n</script>"
    }
}

// MARK: - Real page fetch (the only impure part — honest errors, no fabrication)

enum PageFetchError: LocalizedError {
    case badURL, network(String), notHTML(Int), empty
    var errorDescription: String? {
        switch self {
        case .badURL: return "That doesn't look like a valid web address. Try https://yoursite.com"
        case .network(let m): return "Couldn't reach the page: \(m)"
        case .notHTML(let code): return "The server returned status \(code) (no readable HTML)."
        case .empty: return "The page returned no content."
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum PageFetcher {
    /// Normalize a user-typed address into a fetchable https URL.
    static func normalize(_ raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let withScheme = (t.hasPrefix("http://") || t.hasPrefix("https://")) ? t : "https://" + t
        guard let u = URL(string: withScheme), u.host != nil else { return nil }
        return u
    }
    /// Fetch + parse the buyer's URL into PageSignals. Real network, real status.
    static func audit(_ raw: String) async throws -> PageSignals {
        guard let url = normalize(raw) else { throw PageFetchError.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) BlackLabelMarketing/1.0", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        // The buyer's own URL, typed into the audit field — the declared `userDirectedFetch` lane.
        do { (data, resp) = try await ConsentedEgress.sendUngated(req, lane: .userDirectedFetch) }
        catch { throw PageFetchError.network(error.localizedDescription) }
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let finalURL = (http?.url ?? url).absoluteString
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw PageFetchError.empty
        }
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PageFetchError.empty }
        if status >= 400 { throw PageFetchError.notHTML(status) }
        return HTMLProbe.parse(html, url: url.absoluteString, finalURL: finalURL, status: status)
    }
}
#endif // circuit-convert

// MARK: - Persisted audit record (the buyer's own audit history)

struct AuditRecord: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: String = ""
    var score: Int = 0
    var title: String = ""
    var failCount: Int = 0
    var warnCount: Int = 0
    var goodCount: Int = 0
    var created = Date()
}
