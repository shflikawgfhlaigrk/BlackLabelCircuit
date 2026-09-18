#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — MY LEADS (the buyer's saved CRM leads).
//
// DATABASE-FIRST: the front door for leads is the live 28M+ public-records index
// (List Builder / Property Index / Map / Lot-Flip). This screen is where SAVED
// leads live and get worked. Importing an external list (paste/CSV) is a small
// secondary utility in the overflow menu — never required, never the front door.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

// MARK: - My Leads (saved CRM leads + secondary import/finder utilities)
struct LeadsScreen: View {
    @EnvironmentObject var model: AppModel
    var go: (Section) -> Void = { _ in }
    @State private var showImportCSV = false
    @State private var showPasteImport = false
    @State private var showFinders = false
    @State private var search = ""

    private var filtered: [Lead] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return model.leads }
        return model.leads.filter {
            [$0.name, $0.propertyAddress, $0.mailingAddress, $0.ownerName, $0.county, $0.notes]
                .joined(separator: " ").lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderRow(title: "My Leads", subtitle: "Every lead you've saved — from database lists, the map, the scouts, or an import") {
                GoldButton(label: "Build from database", icon: "square.stack.3d.up.fill") { go(.lists) }
                Menu {
                    SwiftUI.Section("Import external leads") {
                        Button { showPasteImport = true } label: { Label("Paste an external list…", systemImage: "doc.on.clipboard") }
                        Button { showImportCSV = true } label: { Label("Import a CSV file…", systemImage: "square.and.arrow.down") }
                    }
                    Divider()
                    SwiftUI.Section("Live business finders (OpenStreetMap)") {
                        Button { showFinders = true } label: { Label("Builders, trades & probate-source businesses…", systemImage: "building.2") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.blSystem(size: 16, weight: .bold)).foregroundColor(BLTheme.sub)
                        .frame(width: 34, height: 34).background(BLTheme.bg2).clipShape(Circle())
                        .overlay(Circle().stroke(BLTheme.stroke, lineWidth: 1))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Tools: import an external list (optional) or find businesses via live OpenStreetMap")
            }.blScreenPadding(28).padding(.bottom, 12)

            ScrollView { VStack(alignment: .leading, spacing: 12) {
                if model.leads.isEmpty {
                    emptyState
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.blSystem(size: 11, weight: .bold)).foregroundColor(BLTheme.sub)
                        TextField("Search your leads (name, address, owner, county)", text: $search)
                            .textFieldStyle(.plain).font(BLFont.body(12.5, .medium)).foregroundColor(BLTheme.text)
                        if !search.isEmpty {
                            Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    HStack {
                        Text("\(filtered.count) of \(model.leads.count) lead\(model.leads.count == 1 ? "" : "s")")
                            .font(BLFont.body(12, .bold)).foregroundColor(BLTheme.sub)
                        Spacer()
                    }
                    LazyVStack(spacing: 9) {
                        ForEach(filtered) { l in LeadRow(lead: l) }
                    }
                    if filtered.isEmpty {
                        Text("No saved leads match that search.").font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub)
                    }
                }
            }.blScreenPadding(28).padding(.top, 8) }
        }
        .sheet(isPresented: $showImportCSV) { ImportLeadsSheet().environmentObject(model).sheetCloseBar() }
        .sheet(isPresented: $showPasteImport) { ImportExternalLeadsSheet().environmentObject(model).sheetCloseBar() }
        .sheet(isPresented: $showFinders) { LiveFindersSheet().environmentObject(model).sheetCloseBar() }
    }

    /// Empty state = database-first CTAs. The product works before the buyer supplies anything.
    private var emptyState: some View {
        Panel(title: "No saved leads yet", icon: "person.3", glow: true) {
            Text("The database already has real property records across the country — build a targeted list and save the owners you want to work. Nothing needs to be pasted or uploaded first.")
                .font(BLFont.body(12.5, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                GoldButton(label: "Build a list", icon: "square.stack.3d.up.fill") { go(.lists) }
                GhostButton(label: "Browse the map", icon: "mappin.and.ellipse", tint: BLTheme.gold) { go(.map) }
                GhostButton(label: "Search the index", icon: "magnifyingglass", tint: BLTheme.gold) { go(.propertyIndex) }
                Spacer()
            }
            Text("Have a list from another tool? Import it any time from the ••• menu above — optional, never required.")
                .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
        }
    }
}

// MARK: - Import external leads (secondary utility — paste lanes consolidated)
struct ImportExternalLeadsSheet: View {
    @EnvironmentObject var model: AppModel
    private enum ImportLane: String, CaseIterable, Identifiable {
        case rows = "Paste rows", probate = "Probate notice", county = "County list"
        var id: String { rawValue }
    }
    @State private var lane: ImportLane = .rows
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconBadge(system: "doc.on.clipboard", size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Import external leads").font(.blSystem(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("Optional utility — most lists come straight from the built-in property database")
                        .font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.gold)
                }
                Spacer()
            }
            Picker("", selection: $lane) {
                ForEach(ImportLane.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            switch lane {
            case .rows: PasteLeadListLane()
            case .probate: ProbateLane()
            case .county: CountyLane()
            }
        }.blScreenPadding(26) }
        .sheetFrame(660, 720)
    }
}

// MARK: - Live business finders (OpenStreetMap — real open data, secondary tool)
struct LiveFindersSheet: View {
    @EnvironmentObject var model: AppModel
    private enum FinderLane: String, CaseIterable, Identifiable {
        case builders = "Builders & trades", area = "Probate-source businesses"
        var id: String { rawValue }
    }
    @State private var lane: FinderLane = .builders
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconBadge(system: "building.2", size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Live business finders").font(.blSystem(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("Real businesses from live OpenStreetMap — builders, trades, attorneys, estate services")
                        .font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.gold)
                }
                Spacer()
            }
            Picker("", selection: $lane) {
                ForEach(FinderLane.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            switch lane {
            case .builders: BuildersLane()
            case .area: AreaLane()
            }
        }.blScreenPadding(26) }
        .sheetFrame(660, 720)
    }
}

// Paste lane — the OPTIONAL external-list import utility (lives only inside
// ImportExternalLeadsSheet, never the front door).
private struct PasteLeadListLane: View {
    @EnvironmentObject var model: AppModel
    @State private var rawText = ""
    @State private var source: LeadSource = .manual
    @State private var hasHeader = true
    @State private var preview: CSVImport.Result?
    @State private var note = ""

    private let sourceOptions: [LeadSource] = [.manual, .probate, .builder, .teardown, .taxDelinquent, .codeViolation, .preForeclosure, .areaBusiness]

    var body: some View {
        Panel(title: "Paste rows from an external list", icon: "doc.on.clipboard", glow: true) {
            Text("For lists that live OUTSIDE the built-in property database — another tool's export, a spreadsheet, a county file. CSV and tab-separated paste both import through the same mapper, dedupe, and CRM pipeline.")
                .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $rawText).font(.blSystem(size: 12, design: .monospaced)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 118).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .onChangeCompat(of: rawText) { _ in preview = nil; note = "" }
                if rawText.isEmpty {
                    Text("Column order (header row): Name, County, Property Address, Owner, Phone, Email, Assessed Value")
                        .font(.blSystem(size: 12, design: .monospaced)).foregroundColor(BLTheme.sub.opacity(0.7)).padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                }
            }
            HStack(spacing: 12) {
                Toggle(isOn: $hasHeader) { Text("First row is a header").font(BLFont.body(12, .medium)) }
                    .toggleStyle(.checkbox).tint(BLTheme.gold)
                    .onChangeCompat(of: hasHeader) { _ in preview = nil; note = "" }
                Text("SOURCE").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                Picker("", selection: $source) {
                    ForEach(sourceOptions, id: \.self) { s in Text(s.label).tag(s) }
                }
                .labelsHidden().tint(BLTheme.gold).frame(maxWidth: 190)
                Spacer()
            }
            HStack(spacing: 10) {
                GhostButton(label: "Preview", icon: "eye", tint: BLTheme.gold) { refreshPreview() }
                    .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                GoldButton(label: "Import", icon: "tray.and.arrow.down") { importNow() }
                    .disabled((preview?.newLeads.count ?? 0) == 0 && rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if !note.isEmpty { Text(note).font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.green) }
                Spacer()
            }
            if let p = preview {
                HStack(spacing: 10) {
                    pasteStat("\(p.newLeads.count)", "NEW", BLTheme.green)
                    pasteStat("\(p.duplicates)", "DUPES", .orange)
                    pasteStat("\(p.withinFileDupes)", "IN-FILE", .orange)
                    pasteStat("\(p.skippedRows)", "SKIPPED", BLTheme.sub)
                }
                if let first = p.newLeads.first {
                    Text("First import: \(first.name)\(first.county.isEmpty ? "" : " - \(first.county)")\(first.source == .builder ? " - builders lead" : "")\(first.source == .teardown ? " - lot flip pipeline" : "")")
                        .font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.sub)
                }
            }
        }
    }

    @ViewBuilder private func pasteStat(_ v: String, _ l: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(BLFont.mono(18, .bold)).foregroundColor(tint)
            Text(l).font(BLFont.mono(8.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func computePreview() -> CSVImport.Result {
        CSVImport.run(rawText, existing: model.leads, source: source, hasHeader: hasHeader)
    }

    private func refreshPreview() {
        preview = computePreview()
    }

    private func importNow() {
        let result = computePreview()
        preview = result
        guard !result.newLeads.isEmpty else {
            note = "No new rows to import."
            return
        }
        model.addLeads(result.newLeads)
        note = "Imported \(result.newLeads.count) to Leads and Pipeline."
        rawText = ""
        preview = nil
    }
}

// MARK: - CSV import sheet (file pick → header auto-map → dedupe preview → import)
struct ImportLeadsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var rawText = ""
    @State private var fileName = ""
    @State private var headers: [String] = []
    @State private var mapping: [Int: CSVImport.Column] = [:]
    @State private var hasHeader = true
    @State private var preview: CSVImport.Result?
    @State private var imported = 0

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconBadge(system: "square.and.arrow.down", size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Import leads from CSV").font(.blSystem(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("Your own list — PropStream, BatchLeads, a county export, a spreadsheet").font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.gold)
                }
                Spacer()
            }

            Panel(title: "1 · Choose a file", icon: "doc.text") {
                HStack(spacing: 10) {
                    GoldButton(label: "Choose CSV…", icon: "folder") { pick() }
                    if !fileName.isEmpty { Text(fileName).font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.text).lineLimit(1) }
                    Spacer()
                }
                Toggle(isOn: $hasHeader) { Text("First row is a header").font(BLFont.body(12, .medium)) }.toggleStyle(.checkbox).tint(BLTheme.gold)
                    .onChangeCompat(of: hasHeader) { _ in reparse() }
                Text("Parsed on-device — nothing is uploaded. Only the columns you map are filled; the rest stay empty (never fabricated).")
                    .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }

            if !headers.isEmpty {
                Panel(title: "2 · Map columns", icon: "arrow.left.arrow.right") {
                    Text("We auto-mapped your headers — adjust any below. Set a column to “Ignore” to skip it.").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub)
                    ForEach(Array(headers.enumerated()), id: \.offset) { idx, h in
                        // Desktop's rigid 150pt label + 180pt picker exceeds a phone card's width
                        // and clips on BOTH edges — compact stacks the label over its picker.
                        if BLScale.isCompact {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(h.isEmpty ? "Column \(idx + 1)" : h).font(BLFont.mono(11.5, .semibold)).foregroundColor(BLTheme.text).lineLimit(1)
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.right").font(.blSystem(size: 10, weight: .bold)).foregroundColor(BLTheme.sub)
                                    mappingPicker(idx)
                                    Spacer(minLength: 0)
                                }
                            }
                        } else {
                            HStack(spacing: 10) {
                                Text(h.isEmpty ? "Column \(idx + 1)" : h).font(BLFont.mono(11.5, .semibold)).foregroundColor(BLTheme.text).frame(width: 150, alignment: .leading).lineLimit(1)
                                Image(systemName: "arrow.right").font(.blSystem(size: 10, weight: .bold)).foregroundColor(BLTheme.sub)
                                mappingPicker(idx).frame(width: 180)
                                Spacer()
                            }
                        }
                    }
                }
            }

            if let p = preview {
                Panel(title: "3 · Preview & import", icon: "checkmark.seal", glow: true) {
                    HStack(spacing: 14) {
                        importStat("\(p.newLeads.count)", "NEW", BLTheme.green)
                        importStat("\(p.duplicates)", "DUPLICATES", .orange)
                        importStat("\(p.withinFileDupes)", "IN-FILE DUPES", .orange)
                        if p.skippedRows > 0 { importStat("\(p.skippedRows)", "SKIPPED", BLTheme.sub) }
                    }
                    if !p.newLeads.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("FIRST FEW NEW LEADS").font(BLFont.mono(9, .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                            ForEach(p.newLeads.prefix(5)) { l in
                                Text("•  \(l.name)\(l.county.isEmpty ? "" : " · \(l.county)")\(l.propertyAddress.isEmpty ? "" : " · \(l.propertyAddress)")")
                                    .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.text).lineLimit(1)
                            }
                        }
                    }
                    HStack(spacing: 10) {
                        GoldButton(label: "Import \(p.newLeads.count) lead\(p.newLeads.count == 1 ? "" : "s")", icon: "tray.and.arrow.down") { doImport(p) }
                            .disabled(p.newLeads.isEmpty)
                        if imported > 0 { Text("Imported \(imported) — they're in your pipeline.").font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.green) }
                        Spacer()
                    }
                }
            }

            HStack { Spacer(); GhostButton(label: imported > 0 ? "Done" : "Cancel", icon: imported > 0 ? "checkmark" : "xmark", tint: BLTheme.sub) { dismiss() } }
        }.blScreenPadding(26) }
        .sheetFrame(620, 720)
    }

    @ViewBuilder private func importStat(_ v: String, _ l: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(v).font(BLFont.mono(20, .bold)).foregroundColor(tint); Text(l).font(BLFont.mono(8.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.6) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
    }

    /// One header's mapping control — shared by the desktop row and the compact stacked layout.
    @ViewBuilder private func mappingPicker(_ idx: Int) -> some View {
        Picker("", selection: Binding(
            get: { mapping[idx] },
            set: { newVal in
                if let nv = newVal { for k in mapping.keys where mapping[k] == nv && k != idx { mapping[k] = nil }; mapping[idx] = nv }
                else { mapping[idx] = nil }
                recompute()
            })) {
            Text("Ignore").tag(Optional<CSVImport.Column>.none)
            ForEach(CSVImport.Column.allCases, id: \.self) { c in Text(c.label).tag(Optional(c)) }
        }.labelsHidden().tint(BLTheme.gold)
    }

    private func pick() {
        let types: [UTType] = [UTType.commaSeparatedText, UTType(filenameExtension: "csv") ?? .plainText, .plainText, .text]
        #if os(iOS)
        // Real iOS import via the system document picker.
        iosImportFile(types: types) { url, text in
            fileName = url.lastPathComponent; rawText = text; imported = 0; reparse()
        }
        #else
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) {
            fileName = url.lastPathComponent; rawText = text; imported = 0; reparse()
        }
        #endif
    }
    private func reparse() {
        let rows = CSVImport.parse(rawText)
        guard !rows.isEmpty else { headers = []; mapping = [:]; preview = nil; return }
        headers = hasHeader ? rows[0] : (0..<(rows.first?.count ?? 0)).map { "Column \($0 + 1)" }
        mapping = hasHeader ? CSVImport.autoMap(headers: rows[0]) : [:]
        recompute()
    }
    private func recompute() {
        guard !rawText.isEmpty else { preview = nil; return }
        preview = CSVImport.run(rawText, existing: model.leads, mappingOverride: mapping, source: .manual, hasHeader: hasHeader)
    }
    private func doImport(_ p: CSVImport.Result) {
        let before = model.leads.count
        model.addLeads(p.newLeads)
        imported = model.leads.count - before
        recompute()   // refresh preview so re-importing shows 0 new (now they're dupes)
    }
}

// Probate-notice import lane — an OPTIONAL utility for a notice the buyer found
// themselves. Database-backed probate lists (estate-style recorded owners) come from
// List Builder → Probate; this exists only for records outside the index.
private struct ProbateLane: View {
    @EnvironmentObject var model: AppModel
    @State private var notice = ""
    @State private var lastParsed = 0
    @State private var enriching = false
    @State private var enrichNote = ""
    var body: some View {
        Panel(title: "Import a probate notice (external)", icon: "doc.text.magnifyingglass", glow: true) {
            Label("Database-backed probate lists (estate-style recorded owners) are built in List Builder → Probate — no notice needed. This utility only imports a specific notice you found yourself.",
                  systemImage: "info.circle")
                .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $notice).font(.blSystem(size: 12, design: .monospaced)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 96).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                if notice.isEmpty {
                    Text("Paste a probate / estate public notice. Decedent names + counties are extracted on-device — nothing is uploaded.")
                        .font(.blSystem(size: 12, design: .monospaced)).foregroundColor(BLTheme.sub.opacity(0.7)).padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                }
            }
            HStack(spacing: 10) {
                GoldButton(label: "Parse & save", icon: "tray.and.arrow.down") {
                    let f = REMath.parseProbate(notice); lastParsed = f.count; model.addLeads(f)
                }
                if lastParsed > 0 { Text("Added \(lastParsed) lead\(lastParsed == 1 ? "" : "s")").font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.green) }
                Spacer()
            }
        }
        Panel(title: "Resolve to real properties", icon: "scope") {
            Text("For every probate lead whose county is covered, pull the REAL parcel off the county's free GIS: situs address, county-assessed value, recorded owner, the owner's mailing address (skip-trace), ownership confidence and free public debt signals. Gated honestly where no open source exists — never fabricated.")
                .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            Text("Covered counties: \(ParcelRegistry.coveredCounties.joined(separator: ", "))").font(BLFont.mono(10, .semibold)).foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
            let pending = model.leads.filter { $0.source == .probate && $0.propertyAddress.isEmpty && ParcelRegistry.covers($0.county) }
            HStack(spacing: 10) {
                GhostButton(label: enriching ? "Resolving…" : "Resolve \(pending.count) covered leads", icon: enriching ? "hourglass" : "wand.and.stars", tint: BLTheme.gold) { resolve(pending) }
                    .disabled(enriching || pending.isEmpty)
                if !enrichNote.isEmpty { Text(enrichNote).font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.green) }
                Spacer()
            }
        }
    }
    private func resolve(_ pending: [Lead]) {
        enriching = true; enrichNote = ""
        Task {
            // Collect resolved leads, then apply them in ONE coalesced batch so a covered dense
            // county (hundreds of probate leads) triggers a single disk write, not one full-dataset
            // re-encode per lead on the main thread (the O(n²) save cliff).
            var updates: [Lead] = []
            for l in pending {
                let (updated, rec) = await ParcelEnrich.enrich(l)
                if rec.available, rec.address != nil { updates.append(updated) }
            }
            let resolved = updates.count
            await MainActor.run {
                model.batch { for u in updates { model.upsert(u) } }
                enriching = false
                enrichNote = "Resolved \(resolved) of \(pending.count) to real parcels."
            }
        }
    }
}

// Builders lane — OSM construction trades in a metro.
private struct BuildersLane: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: SettingsStore
    @State private var metro = REMarkets.all.first!
    @State private var results: [BuilderResult] = []
    @State private var loading = false
    @State private var err = ""; @State private var note = ""
    var body: some View {
        Panel(title: "New-construction & contractors", icon: "hammer.fill", glow: true) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MARKET").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                    Picker("", selection: $metro) { ForEach(REMarkets.all) { Text($0.label).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                GoldButton(label: loading ? "Searching…" : "Find builders", icon: loading ? "hourglass" : "magnifyingglass") { run() }.disabled(loading)
                if !results.isEmpty { GhostButton(label: "Save all (\(results.count))", icon: "tray.and.arrow.down") { for r in results { model.saveBuilder(r, metro: metro) }; note = "Saved \(results.count)." } }
                Spacer()
            }
            Text("Live from OpenStreetMap open data — real builders, roofers, carpenters, plumbers and trade contractors in the market.").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            if loading { HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Searching \(metro.label)…").font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.sub) } }
            else if !err.isEmpty { Text(err).font(BLFont.body(12, .medium)).foregroundColor(BL.danger).fixedSize(horizontal: false, vertical: true) }
            else { ForEach(results) { r in builderRow(r) } }
            if !note.isEmpty { Label(note, systemImage: "checkmark.circle.fill").font(BLFont.body(12, .bold)).foregroundColor(BLTheme.green) }
        }
    }
    @ViewBuilder private func builderRow(_ r: BuilderResult) -> some View {
        HStack(spacing: 12) {
            IconBadge(system: "hammer.fill", size: 32, active: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.blSystem(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                HStack(spacing: 8) { Text(r.kind.capitalized).font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.gold)
                    if !r.phone.isEmpty { Text(r.phone).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub) }
                    if !r.domain.isEmpty { Text(r.domain).font(BLFont.mono(11, .medium)).foregroundColor(BLTheme.sub) } }
            }
            Spacer()
            GhostButton(label: "Save", icon: "plus", tint: BLTheme.green) { model.saveBuilder(r, metro: metro); note = "Saved \(r.name)." }
        }.padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }
    private func run() {
        loading = true; err = ""; note = ""; results = []
        let m = metro
        Task { do { let r = try await BuilderFinder.search(metro: m); await MainActor.run { results = r; loading = false } }
               catch { await MainActor.run { err = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; loading = false } } }
    }
}

// Area lane — the existing OSM area-business finder (estate agents / probate attorneys / etc.)
private struct AreaLane: View {
    @EnvironmentObject var model: AppModel
    @State private var vertical: REVertical = .probateAttorneys
    @State private var metro = REMarkets.all.first!
    @State private var results: [AreaResult] = []
    @State private var loading = false; @State private var err = ""; @State private var note = ""
    var body: some View {
        Panel(title: "Probate-source businesses", icon: "building.2.fill", glow: true) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) { Text("SOURCE TYPE").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                    Picker("", selection: $vertical) { ForEach(REVertical.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().tint(BLTheme.gold) }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) { Text("MARKET").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                    Picker("", selection: $metro) { ForEach(REMarkets.all) { Text($0.label).tag($0) } }.labelsHidden().tint(BLTheme.gold) }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                GoldButton(label: loading ? "Searching…" : "Find sources", icon: loading ? "hourglass" : "magnifyingglass") { run() }.disabled(loading)
                if !results.isEmpty { GhostButton(label: "Save all (\(results.count))", icon: "tray.and.arrow.down") { for r in results { model.saveArea(r, metro: metro) }; note = "Saved \(results.count)." } }
                Spacer()
            }
            Text("Live OpenStreetMap. Owner records aren't in any free national API — this finds the real local businesses that source probate/estate deals.").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            if loading { HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Searching…").font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.sub) } }
            else if !err.isEmpty { Text(err).font(BLFont.body(12, .medium)).foregroundColor(BL.danger).fixedSize(horizontal: false, vertical: true) }
            else { ForEach(results) { r in
                HStack(spacing: 12) {
                    IconBadge(system: r.vertical.icon, size: 32, active: true)
                    VStack(alignment: .leading, spacing: 2) { Text(r.name).font(.blSystem(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        HStack(spacing: 8) { if !r.phone.isEmpty { Text(r.phone).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub) }
                            if !r.domain.isEmpty { Text(r.domain).font(BLFont.mono(11, .medium)).foregroundColor(BLTheme.gold) } } }
                    Spacer()
                    GhostButton(label: "Save", icon: "plus", tint: BLTheme.green) { model.saveArea(r, metro: metro); note = "Saved \(r.name)." }
                }.padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
            } }
            if !note.isEmpty { Label(note, systemImage: "checkmark.circle.fill").font(BLFont.body(12, .bold)).foregroundColor(BLTheme.green) }
        }
    }
    private func run() {
        loading = true; err = ""; note = ""; results = []
        let v = vertical, m = metro
        Task { do { let r = try await AreaFinder.search(vertical: v, metro: m); await MainActor.run { results = r; loading = false } }
               catch { await MainActor.run { err = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; loading = false } } }
    }
}

// County lane — gated sources (tax-delinquent / code-violation / pre-foreclosure): honest.
private struct CountyLane: View {
    @EnvironmentObject var model: AppModel
    @State private var paste = ""
    @State private var which: GatedSource = .taxDelinquent
    @State private var note = ""
    var body: some View {
        Panel(title: "Import a county list (external)", icon: "building.columns.fill", glow: true) {
            Label("Tax-delinquent and pre-foreclosure feeds publish county-by-county and are still being integrated into the national index. Until they land, this utility imports a county's published list — the database-backed lists in List Builder (absentee, vacant, high equity) cover the same areas today.",
                  systemImage: "info.circle")
                .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
            Picker("", selection: $which) { ForEach(GatedSource.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
            Text(which.explainer).font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            if which.supportsPaste {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $paste).font(.blSystem(size: 12, design: .monospaced)).foregroundColor(BLTheme.text)
                        .scrollContentBackground(.hidden).padding(8).frame(height: 90).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    if paste.isEmpty { Text("Paste the published list / legal-notice block here.").font(.blSystem(size: 12, design: .monospaced)).foregroundColor(BLTheme.sub.opacity(0.7)).padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false) }
                }
                HStack(spacing: 10) {
                    GoldButton(label: "Import", icon: "tray.and.arrow.down") {
                        let n = model.importPasted(paste, source: which.source, detail: which.title); note = "Imported \(n) lead\(n == 1 ? "" : "s")."; paste = ""
                    }
                    if !note.isEmpty { Text(note).font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.green) }
                    Spacer()
                }
            } else {
                Label("Point this at your jurisdiction's open dataset to enable automatic pulls. Until configured it stays empty — no placeholder records.", systemImage: "info.circle")
                    .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// Shared compact lead row with inline status picker + open detail.
struct LeadRow: View {
    @EnvironmentObject var model: AppModel
    let lead: Lead
    @State private var detail = false
    @State private var confirmDelete = false
    var body: some View {
        Button { detail = true } label: {
            HStack(spacing: 12) {
                IconBadge(system: lead.source.icon, size: 34, active: false)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lead.name).font(.blSystem(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    HStack(spacing: 6) {
                        Text(lead.source.label).font(BLFont.body(10.5, .semibold)).foregroundColor(BLTheme.gold)
                        if !lead.county.isEmpty { Text("· \(lead.county)").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub) }
                        if !lead.propertyAddress.isEmpty { Text("· \(lead.propertyAddress)").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).lineLimit(1) }
                        if lead.assessedValue > 0 { Text("· \(REMath.money(Double(lead.assessedValue)))").font(BLFont.body(10.5, .bold)).foregroundColor(BLTheme.green) }
                    }
                }
                Spacer()
                if lead.openTasks > 0 { Text("\(lead.openTasks)").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.ink).padding(4).background(BLTheme.goldGrad).clipShape(Circle()) }
                StatusPill(text: lead.status.label, tint: lead.status.tint)
            }
            .padding(13).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
        .contextMenu { Button("Delete", role: .destructive) { confirmDelete = true } }
        .confirmationDialog("Delete this lead?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.deleteLead(lead) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes the lead and its whole activity timeline — there is no undo.") }
        .sheet(isPresented: $detail) { LeadDetail(lead: lead).environmentObject(model).sheetCloseBar() }
    }
}
#endif // circuit-convert
