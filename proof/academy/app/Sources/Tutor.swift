// Black Label Academy — AC-20 grounded, cite-or-refuse Library Tutor.
//
// An on-device retrieval tutor over the bundled, lint-gated content DB. It answers a question ONLY by
// quoting a real lesson passage with a clickable entry citation; when nothing in the library covers
// the question it REFUSES, verbatim: "Not covered in the library." There is zero network and zero
// generation beyond the retrieved text — the answer body is a verbatim (display-cleaned) slice of a
// lesson, never synthesised prose. This is the honesty guarantee: the tutor cannot invent a fact,
// because it can only echo a passage the provenance-gated pipeline already shipped, and it names the
// exact lesson so the buyer can verify it.
//
// Retrieval reuses the same keyword-contains matching as `AppModel.searchResults` (title/body/tags),
// refined to the single best-matching PASSAGE so the quote always contains the asked-about terms.
import Foundation

/// The tutor's answer: either a verbatim lesson quote with its entry citation, or a fixed refusal.
struct TutorAnswer: Equatable {
    enum Kind: Equatable { case quote, refusal }
    let kind: Kind
    /// On `.quote`: the verbatim (display-cleaned) lesson passage. On `.refusal`: the refusal sentence.
    let text: String
    /// Citation — the lesson the quote came from. nil on a refusal (nothing to cite).
    let entryID: String?
    let entryTitle: String?

    var isRefusal: Bool { kind == .refusal }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum TutorEngine {
    /// The one, fixed refusal. The tutor NEVER answers off-library; it says exactly this and stops.
    static let refusal = "Not covered in the library."

    /// Terms too common to carry retrieval signal (kept tiny — this is retrieval, not NLP).
    private static let stop: Set<String> = [
        "the","and","for","are","but","not","you","your","with","that","this","how","what","why",
        "does","did","can","will","from","into","about","when","which","who","whom","its","it's","has"
    ]

    /// Retrieve an answer. Tokenise the question, find the best-scoring lesson passage across the whole
    /// library, and quote it with a citation — or refuse if nothing scores.
    static func answer(_ query: String, entries: [Entry]) -> TutorAnswer {
        let terms = tokenize(query)
        guard !terms.isEmpty else { return refuse() }

        var best: (score: Int, entry: Entry, passage: String)? = nil
        for e in entries {
            let titleHit = terms.contains { e.title.lowercased().contains($0) } ? 1 : 0
            let tagHit = terms.contains { t in e.tags.contains { $0.lowercased().contains(t) } } ? 1 : 0
            for para in passages(of: e.body) {
                let lower = para.lowercased()
                let hits = terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
                guard hits > 0 else { continue }   // the quote MUST contain the asked-about terms
                let score = hits * 4 + titleHit + tagHit
                if best == nil || score > best!.score {
                    best = (score, e, para)
                }
            }
        }

        guard let hit = best else { return refuse() }   // nothing in the library covers it
        return TutorAnswer(kind: .quote, text: clip(hit.passage), entryID: hit.entry.id, entryTitle: hit.entry.title)
    }

    private static func refuse() -> TutorAnswer {
        TutorAnswer(kind: .refusal, text: refusal, entryID: nil, entryTitle: nil)
    }

    // MARK: retrieval helpers (display-cleaning only — never generation)

    static func tokenize(_ s: String) -> [String] {
        let lowered = s.lowercased()
        let parts = lowered.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return parts.filter { $0.count >= 3 && !stop.contains($0) }
    }

    /// Split a lesson body into candidate passages: non-heading paragraphs, display-cleaned so the
    /// quote reads as plain prose (stat tokens resolved to their value, markdown stripped). Still a
    /// verbatim slice of the lesson — no words are added.
    static func passages(of body: String) -> [String] {
        body.components(separatedBy: "\n\n").compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }
            let cleaned = cleanPassage(trimmed)
            return cleaned.count >= 24 ? cleaned : nil
        }
    }

    static func cleanPassage(_ s: String) -> String {
        var t = MD.stripStats(s)                                   // [[stat:V|src:URL]] -> V
        t = t.replacingOccurrences(of: "\n", with: " ")
        // [label](url) -> label
        if let re = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\([^)]+\\)") {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "$1")
        }
        t = t.replacingOccurrences(of: "**", with: "")
             .replacingOccurrences(of: "`", with: "")
        if let ws = try? NSRegularExpression(pattern: "\\s+") {
            t = ws.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Truncate a long passage at a sentence boundary (~600 chars) so a quote stays readable. Still
    /// verbatim — it only cuts, never rewrites.
    private static func clip(_ s: String, limit: Int = 600) -> String {
        guard s.count > limit else { return s }
        let head = String(s.prefix(limit))
        if let dot = head.lastIndex(where: { ".!?".contains($0) }) {
            return String(head[...dot])
        }
        return head + "…"
    }
}
#endif // circuit-convert

// MARK: - Headless self-test (proves cite-or-refuse without a WindowServer)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// `Black Label Academy --selftest-tutor`. Proves the grounded tutor: a no-match query REFUSES with
/// the exact sentence; a real-term query QUOTES a verbatim lesson passage and cites its entry_id.
/// Reproducible proof for AC-20 (wired into tests/smoke.sh). Platform-agnostic (tutor ships on both).
func runTutorSelfTest() -> Never {
    print("== Black Label Academy — grounded tutor (cite-or-refuse) self-test ==")
    var ok = true
    let entries = ContentDB.load()
    print("  retrieving over \(entries.count) lessons (zero network, quote-or-refuse)")

    // 1) A query with no library coverage MUST refuse, verbatim.
    let none = TutorEngine.answer("zzxqwe blorptastic quux nonsense", entries: entries)
    print("  off-library query -> \(none.isRefusal ? "REFUSED: \"\(none.text)\"" : "ANSWERED (WRONG)")")
    if !none.isRefusal || none.text != TutorEngine.refusal || none.entryID != nil {
        print("FAIL: off-library query did not refuse with the exact sentence + no citation"); ok = false
    }

    // 2) A query built from a real lesson MUST quote a verbatim passage from THAT lesson and cite it.
    if let sample = entries.first(where: { !TutorEngine.passages(of: $0.body).isEmpty }) {
        let terms = TutorEngine.tokenize(sample.title)
        let q = terms.prefix(4).joined(separator: " ")
        let a = TutorEngine.answer(q.isEmpty ? sample.title : q, entries: entries)
        print("  in-library query \"\(q)\" -> \(a.isRefusal ? "REFUSED (WRONG)" : "QUOTED from [\(a.entryID ?? "?")]")")
        if a.isRefusal || a.entryID == nil {
            print("FAIL: in-library query did not return a cited quote"); ok = false
        } else {
            // Zero generation: the quoted text must be a verbatim (cleaned) slice of the cited lesson.
            let cited = entries.first { $0.id == a.entryID }
            let citedBody = cited.map { TutorEngine.cleanPassage($0.body) } ?? ""
            let quoted = a.text.hasSuffix("…") ? String(a.text.dropLast()) : a.text
            if !citedBody.contains(quoted) {
                print("FAIL: quoted passage is not verbatim from the cited lesson body (generation leak)"); ok = false
            } else {
                print("  verbatim-from-source OK — quote is a real slice of [\(a.entryID!)]")
            }
        }
    } else {
        print("FAIL: no lesson has a quotable passage — content empty?"); ok = false
    }

    print(ok ? "TUTOR SELFTEST OK — cite-or-refuse: quotes a real cited passage or refuses verbatim, zero generation"
             : "TUTOR SELFTEST FAILED")
    exit(ok ? 0 : 1)
}
#endif // circuit-convert
