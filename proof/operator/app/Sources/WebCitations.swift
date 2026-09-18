// Sovereign — CITE-OR-REFUSE for the local brain's web capabilities (SV-07).
//
// `web_search` and `url_context` give the LOCAL brain live web grounding. That is exactly the
// capability most likely to launder a fabrication: the model writes a confident paragraph, the UI
// staples a plausible "Sources" list under it, and nobody can tell which sentence came from which
// page — or whether any page was fetched at all.
//
// This file is the gate that makes that impossible, as pure functions the tests read:
//
//   1. NO SOURCE → NO ANSWER. If the daemon fetched nothing real, the turn REFUSES. A web answer is
//      never rendered on zero fetched sources — there is nothing for it to be grounded on.
//   2. NO PHANTOM CHIPS. A source chip renders ONLY for a source that was really fetched AND really
//      cited. A model that emits "[7]" when three pages were fetched produces NO seventh chip —
//      the citation set is intersected with the fetched set, never unioned.
//   3. UNCITED IS SAID OUT LOUD. Sources fetched but the reply cited none → the answer still renders
//      (it may be a refusal, a clarifying question, or a summary), but it is NOT dressed up as
//      cited research; the UI shows the fetched-but-uncited state honestly.
//
// The citation-marker parser lives here as the SINGLE engine both the web path and the document-RAG
// path (ChatScreen.citedChunks) compile against, so "what counts as a citation?" cannot drift into
// two answers. §5.1.
import Foundation

// MARK: - The one citation-marker parser

/// Parses inline "[n]" citation markers out of a model's reply. Deliberately CONSERVATIVE: when a
/// bracket group is ambiguous we under-attribute rather than risk crediting a source the reply never
/// actually used. PURE.
enum CitationMarkers {
    /// The set of citation numbers a reply actually used. A bracket group counts as a citation list
    /// ONLY when its whole content is integers separated by commas/semicolons/whitespace — so the
    /// grouped forms a model really emits ("[1]", "[1, 2]", "[1;3]", adjacent "[1][2]") all resolve,
    /// while "[12]" stays the single number 12 (never 1+2), and a non-citation bracket (a markdown
    /// link "[2nd quarter]", a range "[1-3]") is ignored rather than mis-attributed.
    static func numbers(in reply: String) -> Set<Int> {
        var result = Set<Int>()
        let chars = Array(reply)
        var i = 0
        while i < chars.count {
            guard chars[i] == "[" else { i += 1; continue }
            var j = i + 1
            while j < chars.count, chars[j] != "]", chars[j] != "[" { j += 1 }
            if j < chars.count, chars[j] == "]" {
                if let nums = list(String(chars[(i + 1)..<j])) { result.formUnion(nums) }
                i = j + 1
            } else {
                i += 1
            }
        }
        return result
    }

    /// Integers inside one bracket's content, iff the content is EXACTLY a citation list — one or
    /// more base-10 integers separated only by commas, semicolons, or whitespace. Any other token
    /// (letters, a hyphen, "+1", empty) disqualifies the whole group → nil.
    private static func list(_ content: String) -> [Int]? {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
        guard !tokens.isEmpty else { return nil }
        var nums: [Int] = []
        for t in tokens {
            guard t.allSatisfy({ $0.isNumber }), let n = Int(t) else { return nil }
            nums.append(n)
        }
        return nums
    }
}

// MARK: - A real, fetched web source

/// One source the daemon ACTUALLY fetched — a real URL, carrying the citation number the brain was
/// grounded with. Constructed only from a `ResearchResult.Source` (web_search) or a fetched
/// `URLContext` (url_context); there is deliberately no way to mint one from a model's output, so a
/// hallucinated citation has no object to attach to.
struct WebSource: Equatable, Identifiable {
    let n: Int          // the [n] the grounding block gave this source
    let title: String
    let url: String
    var id: Int { n }

    /// Buyer-facing label: the page title, falling back to the host (never a blank chip).
    var label: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return host.isEmpty ? url : host
    }

    /// The real host, shown on the chip so the buyer can see WHO said it at a glance.
    var host: String {
        guard let h = URL(string: url)?.host else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
}

// MARK: - The gate

/// Decides what a web-grounded turn is ALLOWED to render, from (what was really fetched, what the
/// reply really cited). PURE — the whole cite-or-refuse policy is unit-testable with no network and
/// no UI, which is the point: this is the rule that keeps a fabricated snippet off the screen.
enum WebAnswerGate {
    enum Decision: Equatable {
        /// Nothing real was fetched → render NO answer. Carries the honest reason shown instead.
        case refuse(String)
        /// The reply cited these REAL, fetched sources → render the answer + exactly these chips.
        case cited([WebSource])
        /// Sources were fetched but the reply cited none → render the answer WITHOUT dressing it as
        /// cited research. The fetched sources are carried so the UI can still show what was read.
        case uncited([WebSource])
    }

    /// The sources a reply genuinely cited: the INTERSECTION of what the model cited with what was
    /// really fetched. A "[7]" against three fetched pages yields nothing for 7 — a phantom citation
    /// can never produce a chip. Order follows the fetched list, so chips read [1] [2] [3]. PURE.
    static func citedSources(_ fetched: [WebSource], reply: String) -> [WebSource] {
        let cited = CitationMarkers.numbers(in: reply)
        guard !cited.isEmpty else { return [] }
        return fetched.filter { cited.contains($0.n) }
    }

    /// Citation numbers the reply used that match NO fetched source — i.e. the model invented them.
    /// Surfaced so the UI/tests can prove the phantoms were dropped rather than silently ignored.
    static func phantomCitations(_ fetched: [WebSource], reply: String) -> Set<Int> {
        let real = Set(fetched.map { $0.n })
        return CitationMarkers.numbers(in: reply).subtracting(real)
    }

    /// The whole policy in one pure decision. `fetched` MUST be the sources the daemon actually
    /// returned; an empty list is a refusal, not an empty answer.
    static func decide(fetched: [WebSource], reply: String,
                       noSourceReason: String = "I couldn’t read any source for that, so I won’t answer from memory and risk making it up. Try rephrasing, or paste a URL for me to read.") -> Decision {
        guard !fetched.isEmpty else { return .refuse(noSourceReason) }
        let cited = citedSources(fetched, reply: reply)
        return cited.isEmpty ? .uncited(fetched) : .cited(cited)
    }

    /// The honest one-liner shown under an answer that was grounded on real pages but cited none of
    /// them — so an uncited paragraph is never presented to the buyer as sourced research.
    static let uncitedNotice =
        "This answer didn’t cite the pages below, so treat it as unsourced — open them to verify."
}
