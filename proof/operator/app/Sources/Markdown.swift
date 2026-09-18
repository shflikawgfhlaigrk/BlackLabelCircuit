#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — lightweight, dependency-free Markdown rendering for chat bubbles & notes.
// Renders headings, bold/italic/inline-code, bullet & numbered lists, blockquotes, and
// fenced ```code blocks``` with a copy button + horizontal scroll. No third-party deps —
// everything is parsed in-house so the shipped bundle stays self-contained.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Block model
enum MDBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet([String])
    case numbered(start: Int, items: [String])
    case quote(String)
    case code(language: String, body: String)
    case rule
    var id: String {
        switch self {
        case .heading(let l, let t): return "h\(l):\(t)"
        case .paragraph(let t): return "p:\(t.prefix(24))\(t.count)"
        case .bullet(let items): return "ul:\(items.joined().prefix(24))\(items.count)"
        case .numbered(let start, let items): return "ol:\(start):\(items.joined().prefix(24))\(items.count)"
        case .quote(let t): return "q:\(t.prefix(24))"
        case .code(let lang, let b): return "c:\(lang):\(b.prefix(24))\(b.count)"
        case .rule: return "hr"
        }
    }
}

enum MarkdownParser {
    /// Parse a markdown string into a small block model. Tolerant of partial input
    /// (so it renders smoothly while the model is still streaming).
    static func parse(_ raw: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        var paraBuf: [String] = []
        func flushPara() {
            if !paraBuf.isEmpty {
                let joined = paraBuf.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !joined.isEmpty { blocks.append(.paragraph(joined)) }
                paraBuf.removeAll()
            }
        }
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block (tolerant of an unterminated final fence while streaming).
            if trimmed.hasPrefix("```") {
                flushPara()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[i]); i += 1
                }
                blocks.append(.code(language: lang, body: body.joined(separator: "\n")))
                if i < lines.count { i += 1 } // consume closing fence
                continue
            }
            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushPara(); blocks.append(.rule); i += 1; continue
            }
            // Headings
            if trimmed.hasPrefix("#") {
                flushPara()
                let hashes = trimmed.prefix { $0 == "#" }.count
                let text = String(trimmed.dropFirst(hashes)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(hashes, 4), text: text)); i += 1; continue
            }
            // Blockquote
            if trimmed.hasPrefix(">") {
                flushPara()
                var q: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces)); i += 1
                }
                blocks.append(.quote(q.joined(separator: " "))); continue
            }
            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushPara()
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") {
                        items.append(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)); i += 1
                    } else { break }
                }
                blocks.append(.bullet(items)); continue
            }
            // Numbered list
            if trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                flushPara()
                // Preserve the list's starting number (CommonMark §5.3) so a list that begins at
                // a value other than 1 — or that the model double-spaced into separate blocks —
                // keeps its real numbering instead of every block restarting at "1.".
                let start = Int(trimmed.prefix { $0.isNumber }) ?? 1
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if let rr = t.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                        items.append(String(t[rr.upperBound...]).trimmingCharacters(in: .whitespaces)); i += 1
                    } else { break }
                }
                blocks.append(.numbered(start: start, items: items)); continue
            }
            // Blank line ends a paragraph
            if trimmed.isEmpty { flushPara(); i += 1; continue }
            // Otherwise accumulate into a paragraph
            paraBuf.append(trimmed); i += 1
        }
        flushPara()
        return blocks
    }

    /// Inline styling: **bold**, *italic*/_italic_, `code`. Returns an AttributedString.
    static func inline(_ text: String, base: Color) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        func appendPlain(_ s: Substring) {
            var a = AttributedString(String(s)); a.foregroundColor = base; out.append(a)
        }
        while let open = rest.firstIndex(where: { $0 == "*" || $0 == "_" || $0 == "`" }) {
            appendPlain(rest[rest.startIndex..<open])
            let marker = rest[open]
            let afterOpen = rest.index(after: open)
            // Bold (** or __)
            if marker != "`", afterOpen < rest.endIndex, rest[afterOpen] == marker {
                let contentStart = rest.index(after: afterOpen)
                if let closeRange = rest.range(of: String([marker, marker]), range: contentStart..<rest.endIndex) {
                    var a = AttributedString(String(rest[contentStart..<closeRange.lowerBound]))
                    a.foregroundColor = base; a.font = .system(size: 13.5, weight: .bold, design: .rounded)
                    out.append(a)
                    rest = rest[closeRange.upperBound...]; continue
                }
            }
            // Inline code
            if marker == "`", let close = rest[afterOpen...].firstIndex(of: "`") {
                var a = AttributedString(String(rest[afterOpen..<close]))
                a.foregroundColor = BLTheme.goldHi
                a.font = .system(size: 12.5, weight: .medium, design: .monospaced)
                a.backgroundColor = BLTheme.bg.opacity(0.6)
                out.append(a)
                rest = rest[rest.index(after: close)...]; continue
            }
            // Italic (single * or _)
            if marker != "`", let close = rest[afterOpen...].firstIndex(of: marker) {
                var a = AttributedString(String(rest[afterOpen..<close]))
                a.foregroundColor = base; a.font = .system(size: 13.5, weight: .regular, design: .rounded).italic()
                out.append(a)
                rest = rest[rest.index(after: close)...]; continue
            }
            // Lone marker — emit literally
            appendPlain(rest[open..<afterOpen]); rest = rest[afterOpen...]
        }
        appendPlain(rest)
        return out
    }
}

// MARK: - Rendered view
struct MarkdownView: View {
    let text: String
    var base: Color = BLTheme.text
    // PERF: parse ONCE per distinct `text`, not on every `body` re-render. SwiftUI re-creates
    // this struct (re-running init) only when `text` actually changes — so finished messages
    // above a streaming bubble never re-parse when the parent re-renders per stream token.
    // Previously `blocks` was a computed property that re-ran MarkdownParser.parse on EVERY
    // render of EVERY message bubble (O(messages) parses per stream token) — the hottest cliff.
    private let blocks: [MDBlock]

    init(text: String, base: Color = BLTheme.text) {
        self.text = text
        self.base = base
        self.blocks = MarkdownParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Identify by position: blocks are cached + stable per parse, so the array index is a
            // stable identity. Avoids ForEach id collisions when a message has two identical
            // paragraphs / two horizontal rules (content-derived ids would clash and glitch).
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in render(block) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func render(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let t):
            Text(MarkdownParser.inline(t, base: base))
                .font(.system(size: headingSize(level), weight: .bold, design: .rounded))
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 4 : 0)
        case .paragraph(let t):
            Text(MarkdownParser.inline(t, base: base))
                .font(.system(size: 13.5, design: .rounded)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(BLTheme.gold).frame(width: 5, height: 5).padding(.top, 6)
                        Text(MarkdownParser.inline(it, base: base)).font(.system(size: 13.5, design: .rounded))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let start, let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, it in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(start + idx).").font(.system(size: 12.5, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.gold)
                            .textSelection(.enabled)
                        Text(MarkdownParser.inline(it, base: base)).font(.system(size: 13.5, design: .rounded))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let t):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(BLTheme.gold.opacity(0.6)).frame(width: 3)
                Text(MarkdownParser.inline(t, base: BLTheme.sub)).font(.system(size: 13, design: .rounded).italic())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let lang, let body):
            CodeBlock(language: lang, code: body)
        case .rule:
            Rectangle().fill(BLTheme.stroke).frame(height: 1).padding(.vertical, 2)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level { case 1: return 20; case 2: return 17; case 3: return 15; default: return 14 }
    }
}

// MARK: - Fenced code block with language chip + copy
struct CodeBlock: View {
    let language: String; let code: String
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language.lowercased())
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.gold).tracking(0.6)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string)
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation { copied = false } }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .bold))
                        Text(copied ? "Copied" : "Copy").font(.system(size: 10, weight: .semibold, design: .rounded))
                    }.foregroundColor(copied ? BLTheme.green : BLTheme.sub)
                }.buttonStyle(.plain)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(BLTheme.bg.opacity(0.8))
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: 12, design: .monospaced)).foregroundColor(BLTheme.text)
                    .textSelection(.enabled).padding(12)
            }
        }
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        .textSelection(.enabled)
    }
}
#endif // circuit-convert
