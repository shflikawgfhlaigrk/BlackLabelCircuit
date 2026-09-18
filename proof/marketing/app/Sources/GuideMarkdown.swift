// Black Label Marketing — the block parser behind the in-app guide reader.
//
// WHY THIS EXISTS: the guides used to be handed to `NSWorkspace.shared.open`, which routes a .md
// file to whatever the Mac has registered for Markdown. On a developer's machine that is VS Code;
// on a buyer's machine it can be TextEdit, Xcode, or nothing sensible at all. Either way the buyer
// gets ejected out of the product to read the product's own documentation. The guides now render
// INSIDE the app (Sources/GuideReaderScreen.swift), and this file is the piece that turns the
// shipped Markdown into blocks that view can draw.
//
// Deliberately pure Foundation — no SwiftUI, no AppKit. That keeps it compilable by the bare-swift
// test lane (Tests/run.sh) so the parser is proven against the SHIPPED text, not a copy of it.
//
// SCOPE: exactly the Markdown the shipped guides use — ATX headings, paragraphs, `-` bullets,
// `1.` ordered lists, pipe tables, and `---` rules, with wrapped lines folded back into the item
// they belong to. Inline spans (**bold**, `code`) are NOT handled here: the reader hands each
// string to AttributedString's own inline Markdown parser.
import Foundation

enum GuideMarkdown {
    /// One numbered item, keeping the document's own marker rather than renumbering it — a guide
    /// that restarts at 1. must still read the way it was written.
    struct NumberedItem: Equatable {
        let marker: String
        let text: String
    }

    /// A block-level element of a guide, in document order.
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case numbered([NumberedItem])
        case table(header: [String], rows: [[String]])
        case rule
    }

    /// Parse a guide into its blocks. Unknown syntax degrades to a paragraph — a guide never
    /// renders blank because it used something this parser doesn't model.
    static func blocks(_ source: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [NumberedItem] = []
        var tableRows: [[String]] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            out.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll()
        }
        func flushBullets() {
            guard !bullets.isEmpty else { return }
            out.append(.bullets(bullets))
            bullets.removeAll()
        }
        func flushNumbered() {
            guard !numbered.isEmpty else { return }
            out.append(.numbered(numbered))
            numbered.removeAll()
        }
        func flushTable() {
            guard !tableRows.isEmpty else { return }
            var rows = tableRows
            tableRows.removeAll()
            let header = rows.removeFirst()
            // |---|---| is alignment syntax, never a row of data.
            if let first = rows.first, first.allSatisfy(isAlignmentCell) { rows.removeFirst() }
            out.append(.table(header: header, rows: rows))
        }
        func flushAll() { flushParagraph(); flushBullets(); flushNumbered(); flushTable() }

        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { flushAll(); continue }

            if line.hasPrefix("|") {
                flushParagraph(); flushBullets(); flushNumbered()
                tableRows.append(cells(line))
                continue
            }
            flushTable()   // any non-pipe line ends the table

            if isRule(line) {
                flushAll()
                out.append(.rule)
                continue
            }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let text = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if level <= 6 && !text.isEmpty {
                    flushAll()
                    out.append(.heading(level: level, text: text))
                    continue
                }
            }

            if let item = bulletBody(line) {
                flushParagraph(); flushNumbered()
                bullets.append(item)
                continue
            }
            if let item = numberedBody(line) {
                flushParagraph(); flushBullets()
                numbered.append(item)
                continue
            }

            // A wrapped continuation line belongs to whatever item is still open — the guides wrap
            // long list items at ~90 columns, and folding them back is what keeps "2. Double-click
            // the zip. macOS's built-in Archive Utility extracts…" one sentence instead of two rows.
            let indented = raw.first == " " || raw.first == "\t"
            if indented, !bullets.isEmpty {
                bullets[bullets.count - 1] += " " + line
                continue
            }
            if indented, let last = numbered.last {
                numbered[numbered.count - 1] = NumberedItem(marker: last.marker, text: last.text + " " + line)
                continue
            }
            flushBullets(); flushNumbered()
            paragraph.append(line)
        }
        flushAll()
        return out
    }

    /// The document's own H1, used as the reader's title so the buyer reads the guide's real name
    /// rather than a label the UI invented. nil when the file has no H1.
    static func title(_ source: String) -> String? {
        for raw in source.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("# ") else { continue }
            let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : String(text)
        }
        return nil
    }

    /// Sibling guides this document points at (`PERMISSIONS.md`, `SOCIAL-SETUP.md`, …), in first
    /// mention order and deduplicated. The reader turns these into in-app jumps so a cross
    /// reference never becomes a dead end the buyer has to go hunting for on disk.
    static func referencedFiles(in source: String, excluding self_: String = "") -> [String] {
        var found: [String] = []
        let scanner = source as NSString
        let pattern = try? NSRegularExpression(pattern: "[A-Z][A-Z0-9-]*\\.md")
        pattern?.enumerateMatches(in: source, range: NSRange(location: 0, length: scanner.length)) { match, _, _ in
            guard let match else { return }
            let file = scanner.substring(with: match.range)
            guard file != self_, !found.contains(file) else { return }
            found.append(file)
        }
        return found
    }

    /// Case-insensitive occurrence count, so the reader's "N matches" is a counted fact.
    static func matchCount(_ source: String, query: String) -> Int {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = source.startIndex..<source.endIndex
        while let hit = source.range(of: needle, options: [.caseInsensitive], range: range) {
            count += 1
            guard hit.upperBound < source.endIndex else { break }
            range = hit.upperBound..<source.endIndex
        }
        return count
    }

    // MARK: - line shapes

    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == "-" }
    }

    private static func isAlignmentCell(_ cell: String) -> Bool {
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("-") && trimmed.allSatisfy { $0 == "-" || $0 == ":" }
    }

    private static func cells(_ line: String) -> [String] {
        var body = line
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func bulletBody(_ line: String) -> String? {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func numberedBody(_ line: String) -> NumberedItem? {
        let digits = line.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return NumberedItem(marker: String(digits) + ".", text: text)
    }
}
