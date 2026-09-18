// HTMLSafe — the single source of truth for HTML-output escaping and URL-scheme
// allowlisting used by every generator that emits markup (landing pages, email
// blocks, schema JSON-LD). Both the shipping app target AND the standalone
// engine test suite (Tests/EngineTests.swift, compiled with this file) call
// THESE functions, so a future edit here is caught by the suite — no drift
// between tested logic and shipped logic.
import Foundation

enum HTMLSafe {

    /// HTML-attribute / text escaping. Order matters: `&` must be escaped first so
    /// the entities produced by the later replacements are not double-encoded.
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Defense-in-depth for URL-valued attributes (form action / href). Only the
    /// safe, expected schemes survive; anything else (javascript:, data:, vbscript:,
    /// or a bare scheme-looking string) collapses to "#" so a crafted endpoint can
    /// never execute on submit/click. Then the result is HTML-attribute escaped.
    ///
    /// Every URL-valued attribute the generators emit MUST flow through this one
    /// allowlist — there is no second, looser path.
    static func safeURL(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        let ok = ["http://", "https://", "mailto:", "tel:"]
        // Relative URLs (no scheme, e.g. "/lead" or "#") are allowed.
        let looksAbsolute = lower.contains(":")
        let allowed = !looksAbsolute || ok.contains(where: { lower.hasPrefix($0) })
        return esc(allowed ? t : "#")
    }
}
