#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Import screen — bring your own database (CSV/TSV) into the unified lead pool.
//
// Presentation only: parsing, mapping, and dedupe all live in LeadImportEngine.swift
// (Foundation-only, suite-tested). Flow: pick file → auto-mapped columns with per-column
// override → preview → import with honest counts (imported / duplicates / empty rows).

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

struct LeadImportScreen: View {
    @EnvironmentObject var model: AppModel

    @State private var showPicker = false
    @State private var fileName = ""
    @State private var table: LeadImportTable? = nil
    @State private var mapping: [LeadImportField] = []
    @State private var skipExisting = true
    @State private var extraTag = ""
    @State private var loadError = ""
    @State private var summary = ""

    private static let maxFileBytes = 50 * 1024 * 1024

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let table, !table.isEmpty {
                    mappingCard(table)
                    previewCard(table)
                    importBar(table)
                } else {
                    emptyState
                }
                if !summary.isEmpty {
                    Text(summary).font(BLFonts.mono(12, weight: .medium)).foregroundColor(BLTheme.green)
                }
                if !loadError.isEmpty {
                    Text(loadError).font(BLFonts.mono(12, weight: .medium)).foregroundColor(BLTheme.danger)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(isPresented: $showPicker,
                      allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText, .text],
                      allowsMultipleSelection: false) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            load(url)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import your own database")
                .font(.system(size: 17, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text("Bring an existing lead list into the CRM from a CSV or TSV export. Columns are auto-matched to lead fields and every match can be corrected before anything is imported. Duplicates against your current leads are skipped by default.")
                .font(.system(size: 13)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Text("Using Excel, Numbers, or Google Sheets? Export the sheet as CSV first (File → Save As / Export / Download → CSV).")
                .font(BLFonts.mono(11, weight: .medium)).foregroundColor(BLTheme.sub)
            GoldButton(label: "Choose file…", icon: "square.and.arrow.down") { loadError = ""; summary = ""; showPicker = true }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: Column mapping

    private func mappingCard(_ table: LeadImportTable) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(fileName).font(BLFonts.mono(12, weight: .bold)).foregroundColor(BLTheme.text)
                Text("\(table.rows.count) rows · \(table.headers.count) columns\(table.hadHeaderRow ? "" : " · no header row detected")")
                    .font(BLFonts.mono(11, weight: .medium)).foregroundColor(BLTheme.sub)
                Spacer()
                GhostButton(label: "Start over", icon: "arrow.counterclockwise") { reset() }
            }
            Text("MATCH COLUMNS").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(table.headers.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(table.headers[i])
                                .font(BLFonts.mono(11, weight: .bold)).foregroundColor(BLTheme.text)
                                .lineLimit(1)
                            Picker("", selection: binding(for: i)) {
                                ForEach(LeadImportField.allCases) { f in Text(f.label).tag(f) }
                            }
                            .labelsHidden().tint(BLTheme.gold)
                        }
                        .padding(10)
                        .frame(width: 170, alignment: .leading)
                        .background(mapping.indices.contains(i) && mapping[i] != .skip ? BLTheme.panelHi : BLTheme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                }
            }
        }
        .padding(18)
        .background(BLTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func binding(for column: Int) -> Binding<LeadImportField> {
        Binding(get: { mapping.indices.contains(column) ? mapping[column] : .skip },
                set: { if mapping.indices.contains(column) { mapping[column] = $0 } })
    }

    // MARK: Preview (first rows, real cells only)

    private func previewCard(_ table: LeadImportTable) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PREVIEW — FIRST \(min(5, table.rows.count)) ROWS")
                .font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(table.rows.prefix(5).enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 10) {
                            ForEach(row.indices, id: \.self) { c in
                                Text(row[c].isEmpty ? "—" : row[c])
                                    .font(BLFonts.mono(11, weight: .medium))
                                    .foregroundColor(row[c].isEmpty ? BLTheme.sub.opacity(0.5) : BLTheme.sub)
                                    .lineLimit(1)
                                    .frame(width: 170, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(BLTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: Import action

    private func importBar(_ table: LeadImportTable) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $skipExisting) {
                Text("Skip rows that match an existing lead (by email, or name + company)")
                    .font(.system(size: 12.5)).foregroundColor(BLTheme.text)
            }
            .toggleStyle(.switch).tint(BLTheme.gold)
            HStack(spacing: 10) {
                TextField("Tag every imported lead (optional, e.g. spring-list)", text: $extraTag)
                    .textFieldStyle(.plain)
                    .font(BLFonts.mono(12, weight: .medium)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 9).padding(.horizontal, 12)
                    .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                    .frame(maxWidth: 360)
                GoldButton(label: "Import \(table.rows.count) rows", icon: "square.and.arrow.down.fill") {
                    runImport(table)
                }
                .disabled(!mapping.contains { $0 != .skip })
            }
            if !mapping.contains(where: { $0 != .skip }) {
                Text("Match at least one column above to enable the import.")
                    .font(BLFonts.mono(11, weight: .medium)).foregroundColor(BLTheme.sub)
            }
        }
        .padding(18)
        .background(BLTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func runImport(_ table: LeadImportTable) {
        let built = LeadImportEngine.buildLeads(from: table, mapping: mapping,
                                               fileName: fileName, extraTag: extraTag)
        let fresh: [Lead]
        let existingDupes: Int
        if skipExisting {
            let split = LeadImportEngine.partitionAgainstExisting(built.leads, existing: model.leads)
            fresh = split.fresh; existingDupes = split.duplicates
        } else {
            fresh = built.leads; existingDupes = 0
        }
        model.batch {
            model.leads = fresh + model.leads
        }
        var bits = ["Imported \(fresh.count) lead\(fresh.count == 1 ? "" : "s") from \(fileName)."]
        if existingDupes > 0 { bits.append("\(existingDupes) already in your CRM — skipped.") }
        if built.duplicatesInFile > 0 { bits.append("\(built.duplicatesInFile) duplicate row\(built.duplicatesInFile == 1 ? "" : "s") inside the file — collapsed.") }
        if built.skippedEmptyRows > 0 { bits.append("\(built.skippedEmptyRows) empty row\(built.skippedEmptyRows == 1 ? "" : "s") skipped.") }
        summary = bits.joined(separator: " ")
        self.table = nil
        mapping = []
    }

    // MARK: File loading

    private func load(_ url: URL) {
        loadError = ""; summary = ""
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int, size > Self.maxFileBytes {
                loadError = "That file is over 50 MB. Split the export into smaller files and import each one."
                return
            }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
                loadError = "Couldn't read that file as text. Export it as CSV (UTF-8) and try again."
                return
            }
            let parsed = LeadImportEngine.parseTable(text)
            if parsed.isEmpty {
                loadError = "No rows found in \(url.lastPathComponent). Check that the export actually contains data."
                return
            }
            fileName = url.lastPathComponent
            table = parsed
            mapping = LeadImportEngine.autoMap(parsed.headers)
        } catch {
            loadError = "Couldn't open that file: \(error.localizedDescription)"
        }
    }

    private func reset() {
        table = nil; mapping = []; fileName = ""; loadError = ""; summary = ""
    }
}
#endif // circuit-convert
