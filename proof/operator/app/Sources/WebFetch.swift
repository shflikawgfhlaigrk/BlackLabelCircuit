// Sovereign — minimal, dependency-free web-fetch for the agent's fetch_url tool.
//
// Fetches a URL the buyer's agent names and returns its readable text (HTML stripped to plain
// prose). This is the ONLY tool that reaches outside the buyer's own machine, so at the agent
// layer it is CONFIRMATION-GATED: the buyer approves each fetch before it runs. Uses the
// network.client entitlement already justified for Weather + OAuth.
//
// HONESTY: returns the real fetched text or an honest error. Never fabricates page content.
// Caps the response so a huge page can't blow the context window or memory.
import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum WebFetch {
    struct Result { let url: String; let title: String; let text: String }
    struct FetchError: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    /// The PURE SSRF gate: only http/https, and never a URL whose host is (or is an IP LITERAL for)
    /// loopback / private / link-local / ULA. Rewritten from the old literal-string-prefix denylist,
    /// which a decimal (`2130706433`), octal (`0177.0.0.1`), hex (`0x7f.0.0.1`), IPv4-mapped-IPv6
    /// (`[::ffff:127.0.0.1]`) or trailing-dot (`localhost.`) form all walked straight past. Host IP
    /// literals are parsed with `inet_aton`/`inet_pton` (which understand every one of those encodings)
    /// and classified by range. A DNS name is allowed here; the resolve-based check (a public name that
    /// points at a private IP) needs I/O and lives in `resolvedHostContainsPrivateIP`, applied by
    /// `fetch`. Pure → testable.
    static func isAllowed(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = normalizedHost(url) else { return false }
        // Hostnames that never leave the local machine, regardless of resolution.
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return false }
        switch literalIPVerdict(host) {
        case .blocked:  return false
        case .allowed:  return true      // a public IP literal
        case .notAnIP:  return true      // a DNS name — resolve-time check is done in fetch()
        }
    }

    /// Lowercased host with a trailing FQDN dot stripped (so `localhost.` / `127.0.0.1.` can't dodge the
    /// checks) and IPv6 brackets removed (so `[::1]` classifies as the IPv6 literal `::1`). PURE.
    static func normalizedHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : host
    }

    enum LiteralIPVerdict: Equatable { case blocked, allowed, notAnIP }

    /// Classify a host STRING as a blocked IP literal, an allowed (public) IP literal, or not an IP at
    /// all — trying IPv6 then loose IPv4 (decimal/octal/hex/short forms via inet_aton). PURE.
    static func literalIPVerdict(_ host: String) -> LiteralIPVerdict {
        if let v6 = ipv6Verdict(host) { return v6 }
        if let addr = parseIPv4Loose(host) { return ipv4Blocked(addr) ? .blocked : .allowed }
        return .notAnIP
    }

    /// Parse an IPv4 host in ANY encoding inet_aton accepts (dotted-decimal, a bare decimal/octal/hex
    /// integer, hex-dotted, short forms). Returns the address in HOST byte order, or nil if not IPv4. PURE.
    static func parseIPv4Loose(_ host: String) -> UInt32? {
        var addr = in_addr()
        let ok = host.withCString { inet_aton($0, &addr) }
        guard ok != 0 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    /// True if a host-order IPv4 address is loopback/private/link-local/CGNAT/this-network. PURE.
    static func ipv4Blocked(_ a: UInt32) -> Bool {
        let o1 = (a >> 24) & 0xff, o2 = (a >> 16) & 0xff
        switch o1 {
        case 0:   return true                      // 0.0.0.0/8  "this host on this network"
        case 10:  return true                      // 10/8       private
        case 127: return true                      // 127/8      loopback
        case 169: return o2 == 254                 // 169.254/16 link-local (incl. 169.254.169.254 metadata)
        case 172: return (16...31).contains(o2)    // 172.16/12  private
        case 192: return o2 == 168                 // 192.168/16 private
        case 100: return (64...127).contains(o2)   // 100.64/10  CGNAT (shared address space)
        default:  return false
        }
    }

    /// Classify an IPv6 host string, or nil if it isn't IPv6. Blocks ::/:: 1 loopback, fe80::/10
    /// link-local, fc00::/7 ULA, and IPv4-mapped/compatible forms whose embedded v4 is private. PURE.
    static func ipv6Verdict(_ host: String) -> LiteralIPVerdict? {
        var buf = [UInt8](repeating: 0, count: 16)
        let ok = host.withCString { cs in
            buf.withUnsafeMutableBytes { inet_pton(AF_INET6, cs, $0.baseAddress) }
        }
        guard ok == 1 else { return nil }
        return ipv6BytesBlocked(buf) ? .blocked : .allowed
    }

    /// The IPv6 range classifier over 16 raw bytes (shared by the literal and resolved-address paths). PURE.
    static func ipv6BytesBlocked(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }               // malformed → refuse
        if b[0..<15].allSatisfy({ $0 == 0 }) { return true }   // :: (unspecified) and ::1 (loopback)
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true } // fe80::/10 link-local
        if (b[0] & 0xfe) == 0xfc { return true }                // fc00::/7 ULA
        // IPv4-mapped ::ffff:a.b.c.d and IPv4-compatible ::a.b.c.d → classify the embedded v4.
        if b[0..<10].allSatisfy({ $0 == 0 }),
           (b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0) {
            let v4 = (UInt32(b[12]) << 24) | (UInt32(b[13]) << 16) | (UInt32(b[14]) << 8) | UInt32(b[15])
            return ipv4Blocked(v4)
        }
        return false
    }

    /// The RESOLVE-time SSRF defense the pure gate can't do: resolve the host and return true if ANY
    /// resolved address is private/loopback/link-local/ULA (DNS rebinding / a public name that points at
    /// the metadata endpoint or the buyer's LAN). Returns false when the host resolves entirely to public
    /// addresses OR can't be resolved at all (can't prove private → let the real request surface the
    /// network error rather than over-block offline). Not pure (does DNS) — used by `fetch`/`readURL`.
    static func resolvedHostContainsPrivateIP(_ raw: String) -> Bool {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              let host = normalizedHost(url) else { return true }   // unparseable → treat as unsafe
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, nil, &res) == 0, let head = res else { return false }
        defer { freeaddrinfo(head) }
        var ptr: UnsafeMutablePointer<addrinfo>? = head
        while let ai = ptr {
            if let sa = ai.pointee.ai_addr {
                switch ai.pointee.ai_family {
                case Int32(AF_INET):
                    let v4 = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                    }
                    if ipv4Blocked(v4) { return true }
                case Int32(AF_INET6):
                    var bytes = [UInt8](repeating: 0, count: 16)
                    sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s6 in
                        withUnsafeBytes(of: s6.pointee.sin6_addr) { rawBuf in
                            for i in 0..<16 { bytes[i] = rawBuf[i] }
                        }
                    }
                    if ipv6BytesBlocked(bytes) { return true }
                default: break
                }
            }
            ptr = ai.pointee.ai_next
        }
        return false
    }

    /// Strip HTML to readable text + pull a <title>. Pure string work → unit-testable.
    static func extractText(_ html: String, cap: Int = 8000) -> (title: String, text: String) {
        // Title.
        var title = ""
        if let t = html.range(of: "<title[^>]*>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) {
            title = String(html[t])
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var s = html
        // Drop script/style/head wholesale.
        for tag in ["script", "style", "head", "noscript", "svg"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>.*?</\(tag)>",
                                       with: " ", options: [.regularExpression, .caseInsensitive])
        }
        // Block elements → newlines so paragraphs survive.
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>",
                                   with: "\n", options: [.regularExpression, .caseInsensitive])
        // Remove all remaining tags.
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Decode the few common entities.
        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " ", "&mdash;": "—", "&rsquo;": "’"]
        for (k, v) in entities { s = s.replacingOccurrences(of: k, with: v) }
        // Collapse whitespace.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n[ \\t]*\\n[ \\t]*(\\n[ \\t]*)+", with: "\n\n", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > cap { s = String(s.prefix(cap)) + "\n…(truncated)" }
        return (title, s)
    }

    /// Fetch + extract. Throws an honest FetchError on transport/HTTP failure or a blocked URL.
    static func fetch(_ raw: String, timeout: TimeInterval = 20) async throws -> Result {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAllowed(trimmed), let url = URL(string: trimmed) else {
            throw FetchError(message: "That URL isn't allowed (only public http/https pages).")
        }
        // Resolve-time defense: a public-looking hostname that resolves to a private/loopback/metadata
        // address (DNS rebinding) is caught here, after the pure literal gate.
        guard !resolvedHostContainsPrivateIP(trimmed) else {
            throw FetchError(message: "That URL resolves to a private or loopback address — blocked.")
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("Mozilla/5.0 (Macintosh) Sovereign/1.1", forHTTPHeaderField: "User-Agent")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        let (data, response) = try await URLSession(configuration: cfg).data(for: req)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetchError(message: "The page returned HTTP \(http.statusCode).")
        }
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw FetchError(message: "Couldn't decode the page as text.")
        }
        let (title, text) = extractText(html)
        guard !text.isEmpty else { throw FetchError(message: "The page had no readable text.") }
        return Result(url: trimmed, title: title, text: text)
    }
}
