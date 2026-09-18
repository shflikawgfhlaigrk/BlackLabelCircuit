#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Brand Profiler.
// Profiles the buyer's brand from THEIR OWN material with no paid provider: scrape their public
// website (title / description / theme + CSS colors) and extract dominant colors from their logo.
// Everything is the buyer's own data; nothing is invented. URLSession + CoreGraphics only.
import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum BrandProfiler {
    struct Profile {
        var brandName: String?
        var tagline: String?
        var colors: [UInt32]   // suggested brand colors, most-brandable first
    }

    // MARK: Website profiling (the buyer's own public site)

    static func profileSite(_ urlString: String, completion: @escaping (Profile?) -> Void) {
        var s = urlString.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { completion(nil); return }
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s) else { completion(nil); return }
        var req = URLRequest(url: url); req.timeoutInterval = 12
        req.setValue("Mozilla/5.0 (compatible; BlackLabelMarketing/1.0)", forHTTPHeaderField: "User-Agent")
        ConsentedEgress.sendUngated(req, lane: .userDirectedFetch) { data, _, _ in
            guard let data = data, let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let p = parse(html)
            DispatchQueue.main.async { completion(p) }
        }
    }

    /// Pure HTML → Profile parsing (unit-testable; no network).
    static func parse(_ html: String) -> Profile {
        let title = firstGroup(html, #"<title[^>]*>([\s\S]*?)</title>"#)
        let desc = metaContent(html, key: "name", value: "description")
            ?? metaContent(html, key: "property", value: "og:description")
        let ogSite = metaContent(html, key: "property", value: "og:site_name")

        var colors: [UInt32] = []
        if let theme = metaContent(html, key: "name", value: "theme-color"), let hex = parseHex(theme) { colors.append(hex) }
        for raw in allGroups(html, #"#([0-9a-fA-F]{6})\b"#) {
            if let v = UInt32(raw, radix: 16) { colors.append(v) }
        }
        let ranked = rankBrandable(colors)

        let brand = clean(ogSite) ?? brandFromTitle(clean(title))
        return Profile(brandName: brand, tagline: clean(desc), colors: Array(ranked.prefix(5)))
    }

    // MARK: Logo color extraction (the buyer's own logo)

    /// Extract up to `maxColors` dominant, brandable colors from a logo image by downscaling and
    /// bucketing pixels. Ignores fully-transparent pixels and near-white/near-black backgrounds.
    static func logoColors(_ cg: CGImage, maxColors: Int = 4) -> [UInt32] {
        let w = 48, h = 48
        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var counts: [UInt32: Int] = [:]
        for i in stride(from: 0, to: buf.count, by: 4) {
            let r = buf[i], g = buf[i+1], b = buf[i+2], a = buf[i+3]
            if a < 32 { continue }                       // skip transparent
            // quantize to 5-bit buckets to merge near-identical colors
            let qr = UInt32(r & 0xF8), qg = UInt32(g & 0xF8), qb = UInt32(b & 0xF8)
            let key = (qr << 16) | (qg << 8) | qb
            counts[key, default: 0] += 1
        }
        let ranked = rankBrandable(counts.sorted { $0.value > $1.value }.map { $0.key })
        return Array(ranked.prefix(maxColors))
    }

    // MARK: - Helpers

    /// Rank colors so vivid/brandable ones come first; drop near-white, near-black, and dupes.
    static func rankBrandable(_ colors: [UInt32]) -> [UInt32] {
        var seen = Set<UInt32>()
        var out: [(hex: UInt32, score: Double)] = []
        for c in colors {
            let r = Double((c >> 16) & 0xFF), g = Double((c >> 8) & 0xFF), b = Double(c & 0xFF)
            let mx = max(r, g, b), mn = min(r, g, b)
            let lum = (mx + mn) / 2 / 255
            let sat = mx == 0 ? 0 : (mx - mn) / mx
            if lum > 0.94 || lum < 0.06 { continue }     // skip near-white / near-black
            // coarse-dedupe on the 5-bit bucket
            let bucket = (c & 0xF8F8F8)
            if seen.contains(bucket) { continue }
            seen.insert(bucket)
            out.append((c, sat * (1 - abs(lum - 0.5))))   // vivid + mid-lightness scores highest
        }
        return out.sorted { $0.score > $1.score }.map { $0.hex }
    }

    private static func metaContent(_ html: String, key: String, value: String) -> String? {
        // <meta name="description" content="..."> in either attribute order. The closing quote is a
        // BACKREFERENCE to the opening one (\1 / \2) so an apostrophe inside a double-quoted value
        // (e.g. "Austin's plumbers") doesn't truncate the capture.
        let v = NSRegularExpression.escapedPattern(for: value)
        // order A: key first, content second → content is group 2
        if let m = groupN(html, "<meta[^>]*\(key)=([\"'])\(v)\\1[^>]*content=([\"'])([\\s\\S]*?)\\2", group: 3) { return m }
        // order B: content first, key second → content is group 2
        if let m = groupN(html, "<meta[^>]*content=([\"'])([\\s\\S]*?)\\1[^>]*\(key)=([\"'])\(v)\\3", group: 2) { return m }
        return nil
    }

    private static func brandFromTitle(_ title: String?) -> String? {
        guard let t = title else { return nil }
        // "Brand — tagline" / "Brand | tagline" → take the brand side.
        for sep in [" — ", " – ", " | ", " - ", ": "] {
            if let r = t.range(of: sep) { return String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespaces) }
        }
        return t
    }

    private static func clean(_ s: String?) -> String? {
        guard var v = s?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        v = v.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&nbsp;", with: " ")
        v = v.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    static func parseHex(_ s: String) -> UInt32? {
        let h = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard h.count == 6 else { return nil }
        return UInt32(h, radix: 16)
    }

    private static func firstGroup(_ s: String, _ pattern: String) -> String? {
        allGroups(s, pattern).first
    }
    /// Extract a specific capture group from the first match (for backreference patterns).
    private static func groupN(_ s: String, _ pattern: String, group: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > group, m.range(at: group).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: group))
    }
    private static func allGroups(_ s: String, _ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            guard m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
    }
}
#endif // circuit-convert
