#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// AC-18 — CoreSpotlight system index. Every lesson becomes a CSSearchableItem so the buyer can
// find a lesson from the OS Spotlight search and deep-link straight into the reader. This is a
// system-integration surface a web app structurally cannot offer.
//
// Honesty (§5.1): the indexed payload uses SOURCED fields only — the lesson's compiled title,
// pillar, tags, and a stats-stripped lede excerpt drawn from the lint-gated body. No figure, no
// fabricated blurb, no marketing copy is ever written into the index.
import Foundation
#if canImport(CoreSpotlight) && !CIRCUIT_WINDOWS_SIM
import CoreSpotlight
#endif

enum SpotlightIndexer {
    /// Domain for all Academy lesson items — lets us wipe/rebuild the whole set atomically.
    static let domain = "com.blacklabel.academy.lesson"
    /// The searchable content type. String form keeps this portable across SDK minimums.
    static let contentType = "public.plain-text"

    /// A pure, testable projection of the fields we index for one lesson. Building the payload
    /// separately from the index makes the honesty invariant verifiable headlessly (no live index).
    struct Payload: Equatable {
        let id: String
        let title: String
        let pillar: String
        let summary: String
        let keywords: [String]
    }

    /// The stats-stripped first paragraph of the body (the lede) — a real, sourced excerpt.
    static func summary(for entry: Entry) -> String {
        let stripped = MD.stripStats(entry.body)
        for block in stripped.components(separatedBy: "\n\n") {
            let para = block
                .split(separator: "\n").map { String($0) }
                .filter { !$0.hasPrefix("#") }   // skip the H1/H2 headings
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !para.isEmpty { return para }
        }
        // No prose lede (rare) — fall back to the pillar's own subtitle, itself sourced app copy.
        return Pillar(rawValue: entry.pillar)?.subtitle ?? entry.title
    }

    static func payload(for entry: Entry) -> Payload {
        Payload(id: entry.id,
                title: entry.title,
                pillar: entry.pillar,
                summary: summary(for: entry),
                keywords: entry.tags + [entry.pillar])
    }

    static func item(for entry: Entry) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(itemContentType: contentType)
        let p = payload(for: entry)
        attrs.title = p.title
        attrs.contentDescription = p.summary
        attrs.keywords = p.keywords
        if let pillar = Pillar(rawValue: entry.pillar) { attrs.subject = pillar.title }
        return CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: domain, attributeSet: attrs)
    }

    /// Rebuild the whole lesson index from the current (lint-gated) library. Called on launch and
    /// after an in-app content update so Spotlight always matches the served library. No-op-safe:
    /// failures are swallowed (Spotlight is a convenience surface, never load-bearing).
    static func reindex(_ entries: [Entry]) {
        let index = CSSearchableIndex.default()
        let items = entries.map(item(for:))
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// The unique identifier carried by a Spotlight-tap user activity, mapped back to a lesson id.
    static func lessonID(from userInfo: [AnyHashable: Any]?) -> String? {
        userInfo?[CSSearchableItemActivityIdentifier] as? String
    }
}

// MARK: - Headless honesty self-test (`--selftest-spotlight`)

/// Builds the Spotlight payload for every compiled lesson and asserts it is honest: a real id
/// matching the entry, a non-empty title, a valid pillar, and a summary that leaks NO raw stat
/// token and no known escaping bug. Proves the index payload without a live CSSearchableIndex.
func runSpotlightSelfTest() -> Never {
    print("== Black Label Academy — Spotlight payload honesty self-test ==")
    let entries = ContentDB.load()
    var ok = true
    if entries.isEmpty { print("FAIL: no entries loaded"); ok = false }
    let validPillars = Set(Pillar.allCases.map { $0.rawValue })
    for e in entries {
        let p = SpotlightIndexer.payload(for: e)
        if p.id != e.id { print("FAIL: \(e.id) payload id mismatch"); ok = false }
        if p.title.isEmpty { print("FAIL: \(e.id) empty title"); ok = false }
        if !validPillars.contains(p.pillar) { print("FAIL: \(e.id) invalid pillar '\(p.pillar)'"); ok = false }
        if p.summary.isEmpty { print("FAIL: \(e.id) empty summary"); ok = false }
        // The summary must carry no unrendered provenance token and no escaping regression.
        if p.summary.contains("[[stat") { print("FAIL: \(e.id) summary leaks a raw stat token"); ok = false }
        if p.summary.contains("u003e") || p.summary.contains("\\u") {
            print("FAIL: \(e.id) summary leaks an escaping bug"); ok = false
        }
    }
    print("  indexed payloads: \(entries.count) lessons, domain=\(SpotlightIndexer.domain)")
    print(ok ? "SPOTLIGHT SELFTEST OK — every payload is sourced (title/pillar/summary), no fabricated field"
             : "SPOTLIGHT SELFTEST FAILED")
    exit(ok ? 0 : 1)
}
#endif // circuit-convert
