#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — the in-app guide reader.
//
// Replaces the old "hand the .md to NSWorkspace" behaviour, which launched whatever app the Mac
// had registered for Markdown (VS Code on a dev machine, TextEdit or Xcode elsewhere) and threw
// the buyer out of the product to read the product's own documentation.
//
// What the Connectors panel promises is what this delivers: read it, search it, keep it —
// rendered in the app's own type and palette, with cross references between guides as in-app
// jumps instead of filenames the buyer would have to go find on disk.
//
// HONESTY RULE (from BundledGuides): a guide that is not in this build says so on the page. It
// never renders a blank sheet.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

struct GuideReaderView: View {
    /// The guide the buyer tapped. Cross-reference jumps change `file` from here.
    let guide: BundledGuides.Guide

    @State private var file: String
    @State private var history: [String] = []
    @State private var query = ""
    @State private var saveNote = ""

    init(guide: BundledGuides.Guide) {
        self.guide = guide
        _file = State(initialValue: guide.file)
    }

    /// The shipped bytes for whatever guide is on screen right now, or nil when absent.
    private var source: String? { BundledGuides.text(file) }

    private var displayTitle: String {
        source.flatMap(GuideMarkdown.title) ?? BundledGuides.title(for: file)
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(BLTheme.stroke).frame(height: 1)
            if let source {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            let blocks = GuideMarkdown.blocks(source)
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                view(for: block)
                            }
                            references(in: source)
                        }
                        .frame(maxWidth: 760, alignment: .leading)
                        .padding(.horizontal, 26).padding(.vertical, 22)
                        .id("guide-top")
                    }
                    .onChange(of: file) { _ in proxy.scrollTo("guide-top", anchor: .top) }
                }
            } else {
                missing
            }
        }
        .background(BLTheme.bg)
        #if os(macOS)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 700)
        #endif
    }

    // MARK: - chrome

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !history.isEmpty {
                    Button {
                        guard let previous = history.popLast() else { return }
                        file = previous
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                            Text(BundledGuides.title(for: history.last ?? ""))
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(BLTheme.gold)
                        .padding(.vertical, 5).padding(.horizontal, 10)
                        .background(BLTheme.bg2, in: Capsule())
                        .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain).help("Back to the previous guide")
                    .accessibilityIdentifier("guide.back")
                }
                Text(displayTitle)
                    .font(BLFonts.display(20, weight: .medium)).foregroundColor(BLTheme.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                #if os(macOS)
                if source != nil {
                    GhostButton(label: "Save a copy…", icon: "square.and.arrow.down", tint: BLTheme.text) { saveCopy() }
                }
                #endif
            }

            if source != nil {
                HStack(spacing: 10) {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.sub)
                        TextField("Search this guide", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.text)
                            .accessibilityIdentifier("guide.search")
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11)).foregroundColor(BLTheme.sub)
                            }
                            .buttonStyle(.plain).help("Clear search")
                        }
                    }
                    .padding(.vertical, 7).padding(.horizontal, 11)
                    .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                    .frame(maxWidth: 320)

                    if !trimmedQuery.isEmpty, let source {
                        let hits = GuideMarkdown.matchCount(source, query: trimmedQuery)
                        Text(hits == 1 ? "1 match" : "\(hits) matches")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(hits == 0 ? BLTheme.sub : BLTheme.gold)
                    }
                    Spacer()
                    if !saveNote.isEmpty {
                        Text(saveNote)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(BLTheme.green).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
    }

    /// A guide that genuinely is not in this build says so — never a blank page (HONESTY RULE).
    @ViewBuilder private var missing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not included in this build")
                .font(.system(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text("Every guide ships with every release, so this is a packaging gap in this copy of the app rather than something you did. Nothing in your workspace is affected.")
                .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .padding(26)
    }

    /// Cross references, shown only for guides this build actually carries — a jump that leads
    /// nowhere is worse than no jump.
    @ViewBuilder private func references(in source: String) -> some View {
        let siblings = GuideMarkdown.referencedFiles(in: source, excluding: file)
            .filter { BundledGuides.url($0) != nil }
        if !siblings.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(BLTheme.stroke).frame(height: 1).padding(.top, 6)
                Text("ALSO IN THIS APP")
                    .font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
                HStack(spacing: 8) {
                    ForEach(siblings, id: \.self) { sibling in
                        Button {
                            history.append(file)
                            file = sibling
                            query = ""
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "doc.text").font(.system(size: 10, weight: .bold))
                                Text(BundledGuides.title(for: sibling))
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            }
                            .foregroundColor(BLTheme.gold)
                            .padding(.vertical, 6).padding(.horizontal, 11)
                            .background(BLTheme.bg2, in: Capsule())
                            .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("guide.jump." + sibling)
                    }
                }
            }
        }
    }

    // MARK: - blocks

    @ViewBuilder private func view(for block: GuideMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(BLFonts.display(level == 1 ? 24 : level == 2 ? 17 : 14, weight: level == 1 ? .medium : .medium))
                .foregroundColor(level == 1 ? BLTheme.text : BLTheme.gold)
                .padding(.top, level == 1 ? 0 : 10)
                .fixedSize(horizontal: false, vertical: true)

        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundColor(BLTheme.text.opacity(0.92))
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("•").font(.system(size: 12.5, weight: .bold)).foregroundColor(BLTheme.gold)
                        Text(inline(item))
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.text.opacity(0.92))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 2)

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text(item.marker)
                            .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(inline(item.text))
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.text.opacity(0.92))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.leading, 2)

        case .table(let header, let rows):
            let columns = max(header.count, rows.map(\.count).max() ?? 0)
            Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 9) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(inline(column < header.count ? header[column] : ""))
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(BLTheme.gold).tracking(0.4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider().overlay(BLTheme.stroke)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(inline(column < row.count ? row[column] : ""))
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundColor(BLTheme.text.opacity(0.92))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(12)
            .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))

        case .rule:
            Rectangle().fill(BLTheme.stroke).frame(height: 1).padding(.vertical, 4)
        }
    }

    /// Inline spans (**bold**, `code`) through AttributedString's own Markdown parser, with the
    /// active search term highlighted. A string the parser rejects renders as plain text rather
    /// than disappearing.
    private func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)

        let needle = trimmedQuery
        guard needle.count >= 2 else { return attributed }
        var range = attributed.startIndex..<attributed.endIndex
        while let hit = attributed[range].range(of: needle, options: [.caseInsensitive]) {
            attributed[hit].backgroundColor = BLTheme.gold.opacity(0.34)
            attributed[hit].foregroundColor = BLTheme.text
            guard hit.upperBound < range.upperBound else { break }
            range = hit.upperBound..<attributed.endIndex
        }
        return attributed
    }

    // MARK: - keep

    #if os(macOS)
    /// "Keep" without a hand-off: the buyer picks where the copy lands, and nothing is launched.
    private func saveCopy() {
        guard let text = source else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                saveNote = "Saved \(url.lastPathComponent)."
            } catch {
                saveNote = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }
    #endif
}
#endif // circuit-convert
