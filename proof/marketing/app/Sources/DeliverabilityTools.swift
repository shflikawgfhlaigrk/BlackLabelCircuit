// Black Label Marketing (lead engine, merged from Black Label Leads) — in-house deliverability toolkit (Tier-6 research addenda).
//
// Everything here is built WITHOUT a paid provider, using the system DNS resolver (dnssd) and
// pure on-device parsing. Mirrors what Instantly/Smartlead charge for, the parts we can do free:
//
//   * AuthChecker      — live SPF / DKIM / DMARC / MX record lookup + parse + verdicts.
//   * BlocklistChecker — DNSBL (RBL) lookup of a domain's mail IPs against public blocklists.
//   * SpamLinter       — spam-trigger word + structure analysis of a draft (deterministic score).
//   * SpintaxEngine    — {a|b|c} message-variation expander + variant counter + validator.
//
// The true warmup-network and inbox-placement SEED test require a provider/seed mailboxes and are
// surfaced in the UI behind an honest "connect a provider" state — never faked here.
//
// No fabricated data: every verdict traces to a real DNS answer or deterministic text analysis.
// Starts with nothing configured. No third-party SDK.
import Foundation

// MARK: - low-level DNS (extends the in-house resolver used by Deliverability.hasRecord to read CONTENT)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum DNSResolver {
    /// Fetch the textual content of all records of `type` for `name`. TXT → joined character-strings,
    /// CNAME → target host, A → dotted-quad. Returns [] on no-record / timeout (honest).
    ///
    /// The QUERY itself is not made here: it goes through the egress choke point
    /// (`ConsentedEgress.dnsAnswers`, declared `dnsRecordLookup` lane), which owns every socket and
    /// every resolver handle in Sources/. This enum keeps the part that is actually its job —
    /// decoding raw rdata into the text the deliverability checks read.
    static func records(_ name: String, type: ConsentedEgress.DNSRecordType,
                        timeout: Double = 5) async -> [String] {
        let answers = await ConsentedEgress.dnsAnswers(name, type: type, timeout: timeout)
        return answers.compactMap { decodeRData($0.0, rrtype: $0.1) }.filter { !$0.isEmpty }
    }

    /// Decode raw rdata into text per record type. TXT is length-prefixed character-strings (RFC 1035);
    /// CNAME/PTR are DNS-encoded names; A is 4 bytes. Pure, unit-tested via `decodeTXT`.
    static func decodeRData(_ data: Data, rrtype: ConsentedEgress.DNSRecordType?) -> String? {
        switch rrtype {
        case .text: return decodeTXT(data)
        case .canonicalName, .pointer: return decodeName(data)
        case .address: return data.count == 4 ? data.map { String($0) }.joined(separator: ".") : nil
        default: return decodeTXT(data)
        }
    }

    /// TXT rdata = one or more <len><bytes> character-strings, concatenated (RFC 1035 §3.3.14).
    static func decodeTXT(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        var i = 0, out = ""
        while i < bytes.count {
            let len = Int(bytes[i]); i += 1
            guard len > 0, i + len <= bytes.count else { break }
            if let s = String(bytes: bytes[i..<i+len], encoding: .utf8) { out += s }
            i += len
        }
        return out.isEmpty ? nil : out
    }

    /// Decode a DNS-encoded domain name (length-prefixed labels). No compression-pointer support
    /// (single-record rdata from dnssd is already expanded for CNAME), best-effort.
    static func decodeName(_ data: Data) -> String? {
        let bytes = [UInt8](data); var i = 0; var labels: [String] = []
        while i < bytes.count {
            let len = Int(bytes[i]); i += 1
            if len == 0 { break }
            if len >= 0xC0 { break } // compression pointer — give up cleanly
            guard i + len <= bytes.count else { break }
            if let s = String(bytes: bytes[i..<i+len], encoding: .utf8) { labels.append(s) }
            i += len
        }
        return labels.isEmpty ? nil : labels.joined(separator: ".")
    }
}
#endif // circuit-convert

// MARK: - SPF / DKIM / DMARC / MX auth checker

struct AuthRecord: Identifiable, Hashable {
    enum Kind: String { case spf = "SPF", dkim = "DKIM", dmarc = "DMARC", mx = "MX" }
    enum Verdict: String { case pass = "Pass", warn = "Needs work", fail = "Missing", info = "Info" }
    var id: String { kind.rawValue }
    let kind: Kind
    let verdict: Verdict
    let value: String         // the raw record (or a human summary)
    let detail: String        // plain-English what-it-means / what-to-fix
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum AuthChecker {
    /// Pure SPF parse: a record at the apex starting with "v=spf1". Verdict: pass if it ends with
    /// a hard/soft-fail all mechanism (-all / ~all), warn if +all/?all (too permissive), fail if absent.
    static func evaluateSPF(_ txts: [String]) -> AuthRecord {
        guard let spf = txts.first(where: { $0.lowercased().hasPrefix("v=spf1") }) else {
            return AuthRecord(kind: .spf, verdict: .fail, value: "—",
                              detail: "No SPF record. Publish a TXT record like \"v=spf1 include:_spf.google.com ~all\" so receivers can verify your mail servers.")
        }
        let lower = spf.lowercased()
        if lower.contains("-all") {
            return AuthRecord(kind: .spf, verdict: .pass, value: spf, detail: "SPF present with a hard fail (-all). Strongest setting.")
        }
        if lower.contains("~all") {
            return AuthRecord(kind: .spf, verdict: .pass, value: spf, detail: "SPF present with a soft fail (~all). Good for cold outreach.")
        }
        if lower.contains("+all") || lower.contains("?all") {
            return AuthRecord(kind: .spf, verdict: .warn, value: spf, detail: "SPF ends with +all/?all — too permissive, anyone can spoof you. Use ~all or -all.")
        }
        return AuthRecord(kind: .spf, verdict: .warn, value: spf, detail: "SPF present but has no 'all' mechanism. Add ~all or -all at the end.")
    }

    /// DMARC lives at _dmarc.<domain> and starts with "v=DMARC1". Verdict keys on the policy p=.
    static func evaluateDMARC(_ txts: [String]) -> AuthRecord {
        guard let d = txts.first(where: { $0.lowercased().hasPrefix("v=dmarc1") }) else {
            return AuthRecord(kind: .dmarc, verdict: .fail, value: "—",
                              detail: "No DMARC record at _dmarc.<domain>. Add a TXT \"v=DMARC1; p=none; rua=mailto:you@domain\" to start monitoring, then tighten to quarantine/reject.")
        }
        let policy = policyValue(d, key: "p") ?? "none"
        switch policy.lowercased() {
        case "reject":     return AuthRecord(kind: .dmarc, verdict: .pass, value: d, detail: "DMARC p=reject — strongest protection against spoofing.")
        case "quarantine": return AuthRecord(kind: .dmarc, verdict: .pass, value: d, detail: "DMARC p=quarantine — failing mail goes to spam. Solid.")
        default:           return AuthRecord(kind: .dmarc, verdict: .warn, value: d, detail: "DMARC p=none — monitoring only, no enforcement. Move to quarantine once your sources pass.")
        }
    }

    /// DKIM is per-selector at <selector>._domainkey.<domain>. A present record with a public key
    /// (p=...) passes. We check the selectors the buyer supplies (provider-specific, e.g. "google").
    static func evaluateDKIM(_ txts: [String], selector: String) -> AuthRecord {
        guard let k = txts.first(where: { $0.lowercased().contains("v=dkim1") || $0.lowercased().contains("k=rsa") || $0.lowercased().contains("p=") }) else {
            return AuthRecord(kind: .dkim, verdict: .fail, value: "—",
                              detail: "No DKIM record at \(selector)._domainkey. Enable DKIM in your mail provider and publish the selector it gives you.")
        }
        if let p = policyValue(k, key: "p"), p.isEmpty {
            return AuthRecord(kind: .dkim, verdict: .warn, value: k, detail: "DKIM selector \(selector) has an empty public key (p=) — the key was revoked. Re-publish it.")
        }
        return AuthRecord(kind: .dkim, verdict: .pass, value: k, detail: "DKIM selector \(selector) is published with a public key. Messages can be signed.")
    }

    /// Parse a key=value out of a ";"-delimited record (SPF/DKIM/DMARC share this grammar).
    /// Returns "" (not nil) for a present-but-empty value like "p=" (a revoked DKIM key).
    static func policyValue(_ record: String, key: String) -> String? {
        for part in record.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0].lowercased() == key.lowercased() { return kv[1] }
        }
        return nil
    }

    /// Common DKIM selectors to probe automatically (provider defaults). The buyer can add their own.
    static let commonSelectors = ["google", "selector1", "selector2", "default", "dkim", "k1", "mail", "s1", "zoho", "fm1", "fm2", "fm3"]

    /// Run the whole live check for a domain. Async — does real DNS. Returns the four records + any
    /// DKIM selectors that resolved. `extraSelectors` lets the buyer add provider-specific ones.
    static func check(domain rawDomain: String, extraSelectors: [String] = []) async -> [AuthRecord] {
        let domain = EmailEngine.normalizeDomain(rawDomain)
        guard !domain.isEmpty else { return [] }
        async let apexTXT = DNSResolver.records(domain, type: .text)
        async let dmarcTXT = DNSResolver.records("_dmarc.\(domain)", type: .text)
        let mxOK = await Deliverability.domainAcceptsMail(domain)
        let spf = evaluateSPF(await apexTXT)
        let dmarc = evaluateDMARC(await dmarcTXT)

        // DKIM: probe selectors until one resolves (a non-empty TXT at <sel>._domainkey).
        var dkim = AuthRecord(kind: .dkim, verdict: .fail, value: "—",
                              detail: "No DKIM found on the common selectors. If your provider uses a custom selector, add it below and re-check.")
        for sel in (extraSelectors + commonSelectors) {
            let txts = await DNSResolver.records("\(sel)._domainkey.\(domain)", type: .text)
            if !txts.isEmpty { dkim = evaluateDKIM(txts, selector: sel); break }
        }
        let mx = AuthRecord(kind: .mx, verdict: mxOK ? .pass : .fail,
                            value: mxOK ? "Domain accepts mail" : "—",
                            detail: mxOK ? "An MX (or implicit A) record is published — the domain can receive mail."
                                         : "No MX record — this domain can't receive mail. Senders to it will bounce.")
        return [spf, dkim, dmarc, mx]
    }
}
#endif // circuit-convert

// MARK: - DNS blocklist (RBL) checker

struct BlocklistResult: Identifiable, Hashable {
    var id: String { zone }
    let zone: String        // e.g. zen.spamhaus.org
    let listed: Bool
    let note: String        // the listing reason / TXT, or "clean"
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum BlocklistChecker {
    /// Public DNSBL zones queried by reversing the IP and appending the zone. These are the standard
    /// free reputation lists. (Domain-based DBL uses the bare domain, no reverse.)
    static let ipZones = ["zen.spamhaus.org", "bl.spamcop.net", "b.barracudacentral.org", "dnsbl.sorbs.net"]
    static let domainZones = ["dbl.spamhaus.org"]

    /// Reverse an IPv4 dotted-quad for RBL queries: 1.2.3.4 -> 4.3.2.1
    static func reverseIPv4(_ ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return parts.reversed().joined(separator: ".")
    }

    /// Resolve a domain's sending IPs from its A record (best-effort, in-house). Real outbound IPs
    /// require the actual MTA; the apex A is a reasonable free proxy the buyer can verify.
    static func mailIPs(for domain: String) async -> [String] {
        await DNSResolver.records(domain, type: .address)
    }

    /// Check a single IP against a single zone. An A-record answer at reversed-ip.zone = listed.
    static func checkIP(_ ip: String, zone: String) async -> BlocklistResult {
        guard let rev = reverseIPv4(ip) else { return BlocklistResult(zone: zone, listed: false, note: "not an IPv4 address") }
        let q = "\(rev).\(zone)"
        let a = await DNSResolver.records(q, type: .address)
        if a.isEmpty { return BlocklistResult(zone: zone, listed: false, note: "clean") }
        let txt = await DNSResolver.records(q, type: .text)
        return BlocklistResult(zone: zone, listed: true, note: txt.first ?? "listed (code \(a.first ?? "127.0.0.x"))")
    }

    /// Check a domain (its mail IPs + the domain DBL) across all zones. Real DNS, honest results.
    static func check(domain rawDomain: String) async -> (ips: [String], results: [BlocklistResult]) {
        let domain = EmailEngine.normalizeDomain(rawDomain)
        guard !domain.isEmpty else { return ([], []) }
        var results: [BlocklistResult] = []
        let ips = await mailIPs(for: domain)
        for ip in ips {
            for zone in ipZones { results.append(await checkIP(ip, zone: zone)) }
        }
        // Domain blocklist (DBL): bare domain under the zone.
        for zone in domainZones {
            let a = await DNSResolver.records("\(domain).\(zone)", type: .address)
            results.append(BlocklistResult(zone: zone, listed: !a.isEmpty, note: a.isEmpty ? "clean" : "domain listed"))
        }
        return (ips, results)
    }
}
#endif // circuit-convert

// MARK: - spam-content linter (deterministic, on-device)

struct SpamLint {
    var score: Int                 // 0 (clean) … higher is worse
    var risk: Risk
    var hits: [Hit]
    struct Hit: Identifiable, Hashable { var id = UUID(); let label: String; let weight: Int; let kind: Kind
        enum Kind { case word, structure }
    }
    enum Risk: String { case low = "Low risk", medium = "Medium risk", high = "High risk"
        var tint: String { rawValue } }
}

enum SpamLinter {
    /// Classic spam-trigger phrases (subset of the well-known lists). Weighted by how toxic they are.
    static let triggerWords: [(String, Int)] = [
        ("free", 1), ("guarantee", 2), ("guaranteed", 2), ("no obligation", 2), ("risk-free", 2),
        ("act now", 3), ("limited time", 2), ("urgent", 2), ("winner", 3), ("congratulations", 2),
        ("click here", 3), ("buy now", 3), ("order now", 2), ("cash", 2), ("earn money", 3),
        ("make money", 3), ("100%", 2), ("cheap", 2), ("discount", 1), ("offer expires", 2),
        ("once in a lifetime", 3), ("this isn't spam", 4), ("not spam", 4), ("viagra", 5),
        ("crypto", 2), ("bitcoin", 2), ("investment", 1), ("double your", 3), ("income", 1),
        ("amazing", 1), ("incredible", 1), ("miracle", 3), ("$$$", 4), ("!!!", 3)
    ]

    /// Lint a subject + body. Deterministic spam-likelihood score the buyer can act on before sending.
    static func lint(subject: String, body: String) -> SpamLint {
        var hits: [SpamLint.Hit] = []
        var score = 0
        let full = (subject + " \n " + body)
        let lower = full.lowercased()

        for (word, w) in triggerWords where lower.contains(word) {
            score += w; hits.append(.init(label: "Trigger phrase: “\(word)”", weight: w, kind: .word))
        }
        // Structural signals.
        if subject.count > 60 { score += 2; hits.append(.init(label: "Subject is long (>60 chars) — trim it", weight: 2, kind: .structure)) }
        if subject == subject.uppercased() && subject.contains(where: { $0.isLetter }) {
            score += 3; hits.append(.init(label: "Subject is ALL CAPS", weight: 3, kind: .structure))
        }
        let exclamations = full.filter { $0 == "!" }.count
        if exclamations >= 3 { score += 2; hits.append(.init(label: "\(exclamations) exclamation marks — looks shouty", weight: 2, kind: .structure)) }
        let upperWords = full.split(separator: " ").filter { $0.count > 2 && $0 == $0.uppercased() && $0.contains(where: { $0.isLetter }) }
        if upperWords.count >= 3 { score += 2; hits.append(.init(label: "\(upperWords.count) ALL-CAPS words", weight: 2, kind: .structure)) }
        // Link density.
        let links = countLinks(full)
        if links >= 4 { score += 3; hits.append(.init(label: "\(links) links — too many for a cold email", weight: 3, kind: .structure)) }
        // Missing unsubscribe (CAN-SPAM + spam-filter signal).
        if !lower.contains("unsubscribe") && !lower.contains("opt out") && !lower.contains("reply \"stop\"") && !lower.contains("reply stop") {
            score += 2; hits.append(.init(label: "No opt-out / unsubscribe line", weight: 2, kind: .structure))
        }
        // Very short body reads as a blast.
        if body.split(separator: " ").count < 12 { score += 1; hits.append(.init(label: "Body is very short — add specific context", weight: 1, kind: .structure)) }

        let risk: SpamLint.Risk = score >= 9 ? .high : (score >= 4 ? .medium : .low)
        return SpamLint(score: score, risk: risk, hits: hits.sorted { $0.weight > $1.weight })
    }

    static func countLinks(_ s: String) -> Int {
        var n = 0; let lower = s.lowercased()
        n += lower.components(separatedBy: "http://").count - 1
        n += lower.components(separatedBy: "https://").count - 1
        n += lower.components(separatedBy: "www.").count - 1
        return n
    }
}

// MARK: - spintax (message variation) engine

enum SpintaxEngine {
    /// Count the number of distinct variants a spintax string can produce. {a|b}{c|d} = 4.
    /// Returns 1 for a string with no spintax. nil if the braces are malformed (unbalanced).
    static func variantCount(_ s: String) -> Int? {
        guard isValid(s) else { return nil }
        var total = 1
        for group in groups(in: s) { total *= max(1, group.count) }
        return total
    }

    /// Validate balanced, non-nested {…|…} braces. (Nesting is intentionally unsupported — keep it
    /// predictable.) Returns false on an unbalanced or nested brace.
    static func isValid(_ s: String) -> Bool {
        var depth = 0
        for ch in s {
            if ch == "{" { depth += 1; if depth > 1 { return false } }
            else if ch == "}" { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0
    }

    /// Extract each {a|b|c} group's option list, in order.
    static func groups(in s: String) -> [[String]] {
        var out: [[String]] = []
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "{", let close = s[i...].firstIndex(of: "}") {
                let inner = String(s[s.index(after: i)..<close])
                out.append(inner.components(separatedBy: "|"))
                i = s.index(after: close)
            } else { i = s.index(after: i) }
        }
        return out
    }

    /// Pick ONE concrete variant. Deterministic when `seed` is given (same seed → same output) so a
    /// prospect always gets the same arm; random when seed is nil.
    static func spin(_ s: String, seed: UInt64? = nil) -> String {
        guard isValid(s) else { return s }
        var rng: any RandomNumberGenerator = seed.map { SeededRNG(seed: $0) } ?? SystemRandomNumberGenerator()
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "{", let close = s[i...].firstIndex(of: "}") {
                let opts = String(s[s.index(after: i)..<close]).components(separatedBy: "|")
                out += opts.randomElement(using: &rng) ?? ""
                i = s.index(after: close)
            } else { out.append(s[i]); i = s.index(after: i) }
        }
        return out
    }

    /// Small deterministic RNG (SplitMix64) so seeded spins are reproducible across runs/machines.
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }
}

// MARK: - custom tracking domain — REMOVED, deliberately
//
// There used to be a `TrackingDomain` verifier here: it resolved the CNAME on a subdomain the buyer
// was told to create and, when the record matched, reported "Tracking domain is live."
//
// That claim was false. Open/click tracking needs two things this app does not have — a link-rewrite
// host that reissues every URL in an outgoing message, and an open pixel served from that host. A
// resolving CNAME points at nothing that serves either, so a buyer who followed the instructions
// changed their DNS and measured exactly zero opens and zero clicks.
//
// Asking someone to edit their DNS for a feature that does not exist is worse than not offering the
// feature, so the whole thing is gone rather than reworded: the API, the settings fields
// (`trackingHost` / `trackingTarget`), and the never-wired UI hook. When link rewriting and a pixel
// host actually ship, this comes back with the serving side FIRST and the DNS step last.
