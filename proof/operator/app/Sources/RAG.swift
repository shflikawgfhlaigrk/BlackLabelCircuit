// Sovereign — semantic RAG over the buyer's own Knowledge documents, with citations.
//
// Upgrades the keyword-overlap retrieval to EMBEDDING-based cosine similarity using Apple's
// on-device NaturalLanguage framework (NLEmbedding) — fully local, free, no cloud, ships with
// macOS. When sentence embeddings aren't available for the locale, we fall back to keyword
// overlap so the feature never silently breaks. Either way, retrieved chunks are tagged with a
// citation index so the brain can cite "[1]", "[2]" and the UI can show the source list.
//
// HONESTY: returns "" when no docs are enabled or nothing matches — never invents grounding.
import Foundation
#if canImport(NaturalLanguage) && !CIRCUIT_WINDOWS_SIM
import NaturalLanguage
#endif

/// A retrieved chunk with provenance for citation.
struct RetrievedChunk: Identifiable, Hashable {
    let id = UUID()
    let citation: Int        // 1-based index used in the prompt + the UI source list
    let docName: String
    let docID: UUID
    let text: String
    let score: Double        // cosine (semantic) or normalized overlap (keyword)
    // True for a Knowledge document (the "Sources" chip can open it). False for an EPHEMERAL
    // attachment (a dropped file used to ground one reply): it isn't saved to Knowledge, so its
    // chip must not be a dead "open in Knowledge" click — the UI renders it as a non-tappable
    // marker instead. Defaulted true so every existing call site (Knowledge RAG) is unchanged.
    var routable: Bool = true
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// On-device semantic retriever. Stateless across calls (embeddings are cheap on chunk counts
/// a single buyer accumulates); caches the NLEmbedding handle for the process lifetime.
enum SemanticRAG {
    /// Process-lifetime embedding handle (loading it is the expensive part).
    private static let embedding: NLEmbedding? = {
        // Sentence embeddings give far better retrieval than word vectors for prose chunks.
        if let e = NLEmbedding.sentenceEmbedding(for: .english) { return e }
        return NLEmbedding.wordEmbedding(for: .english)
    }()

    /// Whether on-device embeddings are usable on this device/locale (for honest UI copy).
    static var available: Bool { embedding != nil }

    /// Vector for a piece of text. Sentence embeddings vectorize the whole string; the word
    /// fallback averages token vectors. Returns nil when the text yields no vector.
    private static func vector(_ text: String) -> [Double]? {
        guard let e = embedding else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let v = e.vector(for: trimmed) { return v }
        // Word-embedding fallback: average the token vectors.
        let toks = trimmed.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !toks.isEmpty else { return nil }
        var sum: [Double] = []
        var n = 0
        for t in toks {
            guard let tv = e.vector(for: t) else { continue }
            if sum.isEmpty { sum = tv } else { for i in 0..<min(sum.count, tv.count) { sum[i] += tv[i] } }
            n += 1
        }
        guard n > 0 else { return nil }
        return sum.map { $0 / Double(n) }
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count); guard n > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<n { dot += a[i]*b[i]; na += a[i]*a[i]; nb += b[i]*b[i] }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom == 0 ? 0 : dot / denom
    }

    /// A doc the retriever ranks over (decoupled from SwiftUI types for unit-testing).
    struct Doc { let id: UUID; let name: String; let chunks: [String] }

    /// Retrieve the top chunks for `query` across `docs`, scored by semantic similarity
    /// (or keyword overlap when `useSemantic` is false or embeddings are unavailable).
    /// Honest: returns [] when nothing clears the relevance floor.
    static func retrieve(query: String, docs: [Doc], max: Int, useSemantic: Bool) -> [RetrievedChunk] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !docs.isEmpty else { return [] }

        let semantic = useSemantic && available
        if semantic, let qv = vector(q) {
            struct Scored { let docID: UUID; let docName: String; let chunk: String; let score: Double }
            var scored: [Scored] = []
            for d in docs {
                for c in d.chunks {
                    guard let cv = vector(c) else { continue }
                    let s = cosine(qv, cv)
                    if s > 0.18 {   // relevance floor — below this, it isn't really about the query
                        scored.append(Scored(docID: d.id, docName: d.name, chunk: c, score: s))
                    }
                }
            }
            // If semantic produced nothing above the floor, fall through to keyword so we don't
            // silently return empty when there genuinely IS overlap.
            if !scored.isEmpty {
                let top = scored.sorted { $0.score > $1.score }.prefix(max)
                return top.enumerated().map { i, s in
                    RetrievedChunk(citation: i + 1, docName: s.docName, docID: s.docID, text: s.chunk, score: s.score)
                }
            }
        }

        // Keyword overlap fallback (same scoring as the original, with provenance + normalization).
        let qTerms = Set(tokenize(q)).filter { $0.count > 2 }
        guard !qTerms.isEmpty else { return [] }
        struct KScored { let docID: UUID; let docName: String; let chunk: String; let hits: Int }
        var kscored: [KScored] = []
        for d in docs {
            for c in d.chunks {
                let terms = Set(tokenize(c))
                let hits = qTerms.reduce(0) { $0 + (terms.contains($1) ? 1 : 0) }
                if hits > 0 { kscored.append(KScored(docID: d.id, docName: d.name, chunk: c, hits: hits)) }
            }
        }
        guard !kscored.isEmpty else { return [] }
        let top = kscored.sorted { $0.hits > $1.hits }.prefix(max)
        return top.enumerated().map { i, s in
            RetrievedChunk(citation: i + 1, docName: s.docName, docID: s.docID, text: s.chunk,
                           score: Double(s.hits) / Double(qTerms.count))
        }
    }

    private static func tokenize(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Format retrieved chunks into a grounding block the brain reads, with citation tags so it
    /// can attribute claims to "[1]", "[2]". Returns "" for an empty set.
    static func groundingText(_ chunks: [RetrievedChunk]) -> String {
        guard !chunks.isEmpty else { return "" }
        let body = chunks.map { "[\($0.citation)] From \"\($0.docName)\":\n\($0.text)" }.joined(separator: "\n\n")
        return "Relevant excerpts from the user's own documents. When you use one, cite it inline like [1]:\n\n" + body
    }
}
#endif // circuit-convert
