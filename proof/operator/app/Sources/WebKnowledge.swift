// Sovereign — turn a public web page into a citable Knowledge document (multi-source web RAG).
//
// Closes the "Multi-source RAG (files + … + web)" gap: the buyer pastes a URL, Sovereign fetches
// it with the existing CONFIRMATION-GATED WebFetch (network.client entitlement already justified),
// and stores the readable text as an ordinary KnowledgeDoc(kind: "web"). From there it grounds and
// CITES exactly like an imported file — same on-device retrieval, same "Sources" chips, nothing
// new leaves the Mac on retrieval.
//
// This file is PURE (no SwiftUI / no network) so it locks under the headless test harness. The
// network call lives in WebFetch.fetch; the UI does fetch -> makeDoc -> store.upsertDoc.
//
// HONESTY: a page is only ever added when WebFetch genuinely returned readable text. A failed or
// blocked fetch surfaces the real WebFetch error and creates NOTHING — never a fabricated doc.
import Foundation

enum WebKnowledge {
    /// Normalize buyer input into an allowed public http/https URL, or nil.
    /// "example.com" -> "https://example.com"; a full allowed URL passes through; anything
    /// private/loopback/non-http or unparseable -> nil (delegates the allow-list to WebFetch).
    static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if WebFetch.isAllowed(s) { return s }            // already a complete, allowed URL
        if !s.contains("://") {                          // scheme-less -> assume https, re-check
            let https = "https://" + s
            if WebFetch.isAllowed(https) { return https }
        }
        return nil                                        // ftp:/file:/localhost/private/garbage
    }

    /// A human name for the stored doc: the page <title> when present, else the bare host, else a
    /// safe constant. Capped so a pathological title can't bloat the row. Pure -> testable.
    static func displayName(title: String, url: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return String(t.prefix(90)) }
        if let host = URL(string: url)?.host, !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return "Web page"
    }

    /// Assemble a citable Knowledge document from a fetched page. kind="web" + sourceURL carries
    /// provenance so the row can open the original and a citation can show where it came from.
    /// Body is the page's readable text verbatim — retrieval/chunking is unchanged from files.
    static func makeDoc(from r: WebFetch.Result) -> KnowledgeDoc {
        KnowledgeDoc(name: displayName(title: r.title, url: r.url),
                     kind: "web", body: r.text, sourceURL: r.url)
    }
}
