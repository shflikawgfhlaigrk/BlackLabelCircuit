// AC-16 per-CLAIM provenance — the reader-side wedge.
//
// The TrustChip already shows a per-LESSON "N/N figures sourced" seal. This is the next resolution
// down: every individual inline figure in a lesson body is a `[[stat:VALUE|src:URL]]` (a cited
// claim) or `[[stat:VALUE|est:METHOD]]` (an honest estimate) token — the SAME grammar the build-time
// provenance lint gates on (tools/academy/provenance.py STAT_RE). This file parses those tokens into
// `StatClaim`s the reader can make individually tappable, so a buyer can tap any number and see the
// exact source URL — or, for an estimate, the honest "estimate — no external source" state, never an
// estimate dressed up as sourced.
//
// KEY INVARIANT (why this cannot lie): `StatParser.claims(in:)` and `StatParser.linkify(_:)` walk the
// SAME ordered match set. The Nth claim and the Nth `blstat://claim/N` link the reader renders are
// therefore the SAME token by construction — a tapped figure maps 1:1 to the compiled source it was
// parsed from. Nothing here re-asserts or hand-authors a figure; it only surfaces what the compiler
// already proved honest.
import Foundation

/// One inline quantitative claim in a lesson body. Value + provenance are read verbatim from the
/// `[[stat:…]]` token; the reader never adds, rounds, or re-sources a figure.
struct StatClaim: Identifiable, Hashable {
    /// How this figure is backed. Exactly mirrors the lint's src/est distinction (§5.1).
    enum Provenance: Hashable {
        case sourced(url: String)      // [[stat:V|src:URL]] — cited to a real external URL
        case estimate(method: String)  // [[stat:V|est:METHOD]] — an honest own estimate, no external source
        case unqualified               // [[stat:V]] — the lint blocks this in real content; the reader
                                        // still degrades it honestly (as an estimate) if one ever appears
    }

    /// Stable 0-based position of this claim in the lesson body. Doubles as the popover identity and
    /// the `blstat://claim/<index>` link target, so tap-target and claim can never desync.
    let index: Int
    /// The figure exactly as written in prose (e.g. "$45.4B", "83.5", "pipeline architectures").
    let value: String
    let provenance: Provenance
    var id: Int { index }

    var isSourced: Bool { if case .sourced = provenance { return true } else { return false } }

    /// The source URL for a cited claim; nil for an estimate. An estimate NEVER exposes a URL — the
    /// whole point of the honest state is that there isn't one to show.
    var sourceURL: String? { if case .sourced(let u) = provenance { return u } else { return nil } }

    /// The estimate method for an own-estimate claim; nil otherwise.
    var estimateMethod: String? { if case .estimate(let m) = provenance { return m } else { return nil } }

    /// The single honest line the reader shows for the claim's backing. A cited claim shows its URL;
    /// an estimate (or a would-be unqualified figure) shows the honest literal and is NEVER labeled as
    /// sourced. This is the anti-fabrication contract the self-test pins.
    static let estimateState = "estimate — no external source"
    var honestState: String {
        switch provenance {
        case .sourced(let url): return url
        case .estimate, .unqualified: return Self.estimateState
        }
    }
}

/// Pure parsing over a lesson body. No SwiftUI, no I/O — headless-testable and shared verbatim by the
/// reader (Markdown.swift) and both proof lanes (`--selftest-provenance` + ProvenanceClaimTests).
enum StatParser {
    // Match ANY [[stat:VALUE(|src:…|est:…)?]] token. Value = up to a `|` or `]`; the qualifier kind
    // and its argument are captured separately so a claim's provenance is read, not re-derived.
    static let tokenRE = try! NSRegularExpression(
        pattern: #"\[\[stat:([^\]|]+?)(?:\|(src|est):([^\]]+))?\]\]"#)

    /// Every inline claim in `body`, in document order, indexed 0…N-1.
    static func claims(in body: String) -> [StatClaim] {
        let ns = body as NSString
        let matches = tokenRE.matches(in: body, range: NSRange(location: 0, length: ns.length))
        return matches.enumerated().map { i, m in
            let value = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let kind = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ""
            let arg = m.range(at: 3).location != NSNotFound
                ? ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces) : ""
            let prov: StatClaim.Provenance
            switch kind {
            case "src": prov = .sourced(url: arg)
            case "est": prov = .estimate(method: arg)
            default: prov = .unqualified
            }
            return StatClaim(index: i, value: value, provenance: prov)
        }
    }

    /// Rewrite `body` so each `[[stat:VALUE|…]]` becomes an inline Markdown link `[VALUE](blstat://claim/i)`.
    /// The index `i` is the claim's position in the SAME ordered match set `claims(in:)` walks, so the
    /// rendered links and the parsed claims are guaranteed 1:1. Replacements are applied back-to-front
    /// so earlier ranges stay valid.
    static func linkify(_ body: String) -> String {
        let ns = NSMutableString(string: body)
        let src = body as NSString
        let matches = tokenRE.matches(in: body, range: NSRange(location: 0, length: src.length))
        for (i, m) in matches.enumerated().reversed() {
            // Strip only bracket chars from the link TEXT so the Markdown link can't mis-nest; the
            // value's own characters ($, %, letters) render as-is.
            let value = src.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            ns.replaceCharacters(in: m.range, with: "[\(value)](blstat://claim/\(i))")
        }
        return ns as String
    }
}

// MARK: - Headless proof hook (`Black Label Academy --selftest-provenance`)

/// Proves the two teeth the dispatch asked for: a planted unsourced/estimate claim renders the HONEST
/// state (never dressed as sourced), and a real claim maps 1:1 to its compiled source — first on
/// planted fixtures, then against the REAL lint-gated library so it cannot go vacuously green.
func runProvenanceSelfTest() -> Never {
    print("== Black Label Academy — per-claim provenance self-test ==")
    var ok = true
    func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL: \(msg)"); ok = false } }

    // 1) A planted ESTIMATE renders the honest state and is NOT sourced.
    let est = StatParser.claims(in: "Our TAM is [[stat:$4.2B|est:top-down BLS employment × ARPU]] a year.")
    check(est.count == 1, "estimate body should yield exactly one claim, got \(est.count)")
    if let c = est.first {
        check(!c.isSourced, "an estimate claim must not report as sourced")
        check(c.sourceURL == nil, "an estimate must expose NO source URL")
        check(c.honestState == StatClaim.estimateState, "estimate honest state wrong: \"\(c.honestState)\"")
        check(c.estimateMethod == "top-down BLS employment × ARPU", "estimate method not read verbatim")
    }

    // 2) A would-be UNQUALIFIED figure (lint blocks it in real content) still degrades honestly —
    //    it is NEVER surfaced as if it had a source.
    let bare = StatParser.claims(in: "A planted [[stat:9000]] figure.")
    check(bare.count == 1 && bare.first?.isSourced == false
          && bare.first?.honestState == StatClaim.estimateState,
          "an unqualified figure must degrade to the honest estimate state, never sourced")

    // 3) A real SOURCED claim maps 1:1 to its exact compiled URL.
    let url = "https://www.example.gov/coffee-report"
    let src = StatParser.claims(in: "Coffee was [[stat:$45.4B|src:\(url)]] in 2024.")
    check(src.count == 1, "sourced body should yield one claim")
    if let c = src.first {
        check(c.isSourced && c.sourceURL == url, "sourced claim did not map 1:1 to its URL")
        check(c.honestState == url, "a cited claim's honest state must be its URL")
        check(c.value == "$45.4B", "value not read verbatim from the token")
    }

    // 4) STRUCTURAL 1:1 — claims() and linkify() walk the same ordered tokens, so the Nth claim and the
    //    Nth rendered link are the same figure; no raw token leaks into the rendered text.
    let multi = "[[stat:1|src:https://a.gov]] then [[stat:2|est:a guess]] then [[stat:3|src:https://c.gov]]"
    let mc = StatParser.claims(in: multi)
    let linked = StatParser.linkify(multi)
    check(mc.count == 3, "expected 3 claims across the multi body, got \(mc.count)")
    for c in mc { check(linked.contains("blstat://claim/\(c.index)"), "claim \(c.index) has no matching link") }
    check(!linked.contains("[[stat"), "a raw [[stat token leaked into rendered text")
    check(linked.contains("blstat://claim/1") && mc[1].isSourced == false,
          "the middle (estimate) claim must be index 1 and unsourced — alignment drift")

    // 5) AGAINST THE REAL COMPILED LIBRARY — every entry's figures parse 1:1, no unqualified figure
    //    survives the lint, and every cited claim carries a real http(s) URL. Non-vacuous: fails loudly
    //    if the library is empty.
    let entries = ContentDB.load()
    print("  auditing per-claim provenance across \(entries.count) compiled lessons")
    check(!entries.isEmpty, "compiled library is EMPTY — the real-library leg would be vacuous")
    var totalClaims = 0, sourced = 0, estimates = 0
    for e in entries {
        let claims = StatParser.claims(in: e.body)
        // 1:1 with the raw token count (regex match count) — parse recovers exactly the tokens present.
        let rawTokens = StatParser.tokenRE.numberOfMatches(
            in: e.body, range: NSRange(location: 0, length: (e.body as NSString).length))
        check(claims.count == rawTokens, "\(e.id): parsed \(claims.count) claims but body has \(rawTokens) tokens")
        for c in claims {
            totalClaims += 1
            switch c.provenance {
            case .unqualified:
                check(false, "\(e.id): an UNQUALIFIED inline figure '\(c.value)' shipped — the lint should have blocked it")
            case .sourced(let u):
                sourced += 1
                check(u.hasPrefix("http://") || u.hasPrefix("https://"),
                      "\(e.id): sourced claim '\(c.value)' has a non-http(s) URL: \(u)")
                check(c.honestState == u, "\(e.id): sourced claim honest state must equal its URL")
            case .estimate:
                estimates += 1
                check(c.honestState == StatClaim.estimateState && c.sourceURL == nil,
                      "\(e.id): an estimate claim leaked a source or wrong honest state")
            }
        }
    }
    check(totalClaims > 0, "the whole library has ZERO inline claims — the audit would be vacuous")
    print("  \(totalClaims) inline claims: \(sourced) sourced (1:1 to a real URL), \(estimates) honest estimates, 0 unqualified")

    print(ok
        ? "PROVENANCE SELFTEST OK — every inline figure is tappable to its exact source or the honest estimate state; a real claim maps 1:1, an estimate is never dressed as sourced"
        : "PROVENANCE SELFTEST FAILED")
    exit(ok ? 0 : 1)
}
