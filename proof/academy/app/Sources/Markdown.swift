#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Lightweight Markdown renderer for entry bodies.
// Inline stat shortcodes ([[stat:VALUE|src:URL]]) render as the value; full provenance
// lives in the Metrics + Sources panels of the reader ("shows its receipts").
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

enum MD {
    static func stripStats(_ s: String) -> String {
        let pattern = "\\[\\[stat:([^\\]|]+?)(\\|(?:src|est):[^\\]]+)?\\]\\]"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: "$1")
    }

    static func attr(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }

    static func parse(_ s: String) -> [MDBlock] {
        var out: [MDBlock] = []
        for raw in s.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { out.append(.space); continue }
            if line.hasPrefix("### ") { out.append(.h3(String(line.dropFirst(4)))) }
            else if line.hasPrefix("## ") { out.append(.h2(String(line.dropFirst(3)))) }
            else if line.hasPrefix("# ") { out.append(.h1(String(line.dropFirst(2)))) }
            else if line.hasPrefix("> ") { out.append(.quote(String(line.dropFirst(2)))) }
            else if line.hasPrefix("- ") || line.hasPrefix("* ") { out.append(.bullet(String(line.dropFirst(2)))) }
            else if let m = numbered(line) { out.append(.numbered(m.0, m.1)) }
            else { out.append(.para(line)) }
        }
        return out
    }

    static func numbered(_ line: String) -> (Int, String)? {
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let numPart = String(line[line.startIndex..<dot])
        guard let n = Int(numPart) else { return nil }
        let after = line.index(after: dot)
        guard after < line.endIndex, line[after] == " " else { return nil }
        return (n, String(line[line.index(after: after)...]))
    }
}

enum MDBlock {
    case h1(String), h2(String), h3(String), quote(String)
    case bullet(String), numbered(Int, String), para(String), space

    @ViewBuilder func view() -> some View {
        switch self {
        case .h1(let s):
            FoilText(text: s, size: 23).padding(.top, 4)
        case .h2(let s):
            Text(MD.attr(s)).font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.goldLite).padding(.top, 6)
        case .h3(let s):
            Text(MD.attr(s)).font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.text)
        case .quote(let s):
            HStack(alignment: .top, spacing: 10) {
                Rectangle().fill(BLTheme.goldBase).frame(width: 3)
                Text(MD.attr(s)).font(.system(size: 14.5, weight: .regular, design: .serif))
                    .italic().foregroundColor(BLTheme.text.opacity(0.9))
            }
            .padding(.vertical, 2)
        case .bullet(let s):
            HStack(alignment: .top, spacing: 8) {
                Text("•").foregroundColor(BLTheme.goldBase).font(.system(size: 14, weight: .bold))
                Text(MD.attr(s)).font(.system(size: 14)).foregroundColor(BLTheme.text)
            }
        case .numbered(let n, let s):
            HStack(alignment: .top, spacing: 8) {
                Text("\(n).").foregroundColor(BLTheme.goldBase).font(.system(size: 14, weight: .bold)).frame(minWidth: 18, alignment: .trailing)
                Text(MD.attr(s)).font(.system(size: 14)).foregroundColor(BLTheme.text)
            }
        case .para(let s):
            Text(MD.attr(s)).font(.system(size: 14)).foregroundColor(BLTheme.text).lineSpacing(3)
        case .space:
            Color.clear.frame(height: 2)
        }
    }
}

struct MarkdownView: View {
    let text: String
    @State private var selected: StatClaim?

    var body: some View {
        // AC-16 per-claim provenance: instead of stripping inline [[stat:…]] tokens to bare values, we
        // render each as a tappable Markdown link (`blstat://claim/<index>`) and open a provenance
        // popover for it. `claims` and `linkify` walk the SAME ordered tokens, so a tapped figure maps
        // 1:1 to the claim it came from. This one change gives every reader surface — macOS + iOS,
        // regular lessons and post-mortem sections (all funnel through MarkdownView) — the same
        // per-claim receipts.
        let prepared = MarkdownView.storeSafeBody(text)
        let claims = StatParser.claims(in: prepared)
        let blocks = MD.parse(StatParser.linkify(prepared))
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                b.view().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .tint(BLTheme.goldBase)   // inline stat links read as gold, not system-blue
        .environment(\.openURL, OpenURLAction { url in
            // A blstat:// tap opens the provenance popover for that claim; everything else (a real
            // source URL tapped inside the popover) falls through to the system browser.
            if url.scheme == "blstat", let i = Int(url.lastPathComponent), i < claims.count {
                selected = claims[i]
                return .handled
            }
            #if os(iOS)
            // Store posture: the reader never leaves the app for a web page.
            return .handled
            #else
            return .systemAction
            #endif
        })
        .popover(item: $selected) { ClaimProvenanceView(claim: $0) }
    }

    /// iOS App Store posture (4.2.2 response): the reader never bounces to a web browser, so raw
    /// Markdown web links in lesson bodies render as their plain label text. Stat tokens
    /// (`[[stat:…]]`) are untouched — they linkify to in-app blstat:// provenance popovers, and the
    /// popover shows the source URL as selectable text. macOS keeps tappable links.
    static func storeSafeBody(_ s: String) -> String {
        #if os(iOS)
        return s.replacingOccurrences(
            of: #"\[([^\]]+)\]\(\s*https?://[^)]*\)"#,
            with: "$1", options: .regularExpression)
        #else
        return s
        #endif
    }
}

/// The per-claim provenance popover (AC-16). Shows the figure verbatim, then EITHER its exact source
/// URL (tappable, opens the browser) OR the honest "estimate — no external source" state with the
/// method — an estimate is never rendered as if it were sourced. Every field is read from the claim's
/// own token; nothing is re-asserted here.
struct ClaimProvenanceView: View {
    let claim: StatClaim

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("CLAIM").font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.sub).tracking(1.2)
            Text(claim.value).font(.system(size: 18, weight: .heavy, design: .rounded))
                .foregroundColor(BLTheme.goldLite)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(BLTheme.line)

            switch claim.provenance {
            case .sourced(let urlStr):
                Label("Sourced", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(BLTheme.green)
                #if os(iOS)
                // Store posture: the citation stays fully visible (and copyable) but is not a
                // tappable link — the reader never bounces to a browser.
                Text(urlStr).font(.system(size: 12)).foregroundColor(BLTheme.cyan)
                    .textSelection(.enabled)
                #else
                if let url = URL(string: urlStr) {
                    Link(destination: url) {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                            Text(urlStr).font(.system(size: 12)).multilineTextAlignment(.leading)
                        }.foregroundColor(BLTheme.cyan)
                    }
                } else {
                    Text(urlStr).font(.system(size: 12)).foregroundColor(BLTheme.cyan)
                        .textSelection(.enabled)
                }
                #endif

            case .estimate(let method):
                Label(StatClaim.estimateState, systemImage: "questionmark.circle")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(BLTheme.sub)
                Text(method).font(.system(size: 12)).foregroundColor(BLTheme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)

            case .unqualified:
                // Should never occur in shipped content (the lint blocks it) — but if it ever did, it
                // degrades honestly rather than implying a source it doesn't have.
                Label(StatClaim.estimateState, systemImage: "questionmark.circle")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(BLTheme.sub)
            }
        }
        .padding(16).frame(width: 320, alignment: .leading)
    }
}
#endif // circuit-convert
