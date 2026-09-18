#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — LOT-FLIP SCOUT screen.
//
// Drives the LotFlipScout engine: pick a covered county, geocode its center (free OSM), pull the
// REAL county ArcGIS parcel layer in a ~3-mile ring, score the teardown / lot-flip plays by the
// improvement-to-land ratio (or the below-area-average signal), and show the ranked FlipLeads with
// their teardown reason + key numbers plus a nearest-neighbor canvass route. Nothing is fabricated:
// uncovered or value-less counties return the engine's honest gate, and a server miss says so.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Lot-Flip Scout view-model (pure, UI-free) — the redevelopment-score DISCLOSURE the screen
// renders, unit-tested so its honesty rules are pinned, not eyeballed.
//
// The load-bearing promises this presenter fixes:
//   1. A teardown/redevelopment SCORE is shown ONLY for a county that publishes a value layer. A
//      mapped-only or uncovered county is NOT scorable — the UI shows an honest gate ("gated, not
//      faked" / "nothing was invented"), never a fabricated score.
//   2. A lead card renders ONLY the key numbers the county actually published — a missing assessed /
//      land / improvement value is omitted entirely (never shown as $0 or invented), and the
//      opportunity gap is an ESTIMATE shown only when positive.
//   3. The disclosure copy (spread = opportunity-gap estimate not guaranteed profit; missing fields
//      say "unknown", never invented) is the SAME text the screen paints — pinned here so a careless
//      edit that softens the honesty language fails a test.
enum LotFlipScoutPresenter {
    /// How much this county's parcel layer supports — drives the redevelopment-score disclosure pill.
    enum Coverage: Equatable { case scored, mappedOnly, notCovered }

    static func coverage(_ r: FlipScoutResult) -> Coverage {
        if !r.supported { return .notCovered }
        return r.scored ? .scored : .mappedOnly
    }
    /// The status pill text: a scored county, a mapped-only (no value layer → honest gate) county, or
    /// an uncovered county. Never claims a score for a county that can't produce one.
    static func coverageLabel(_ r: FlipScoutResult) -> String {
        switch coverage(r) {
        case .scored: return "Scored"
        case .mappedOnly: return "Mapped only"
        case .notCovered: return "Not covered"
        }
    }
    /// True ONLY when a real redevelopment score can be shown. Mapped-only / uncovered ⇒ not scorable.
    static func isScorable(_ r: FlipScoutResult) -> Bool { coverage(r) == .scored }

    /// The redevelopment-score badge for a lead — a real 0…1 score (the assessor's own
    /// improvement-to-land ratio) rendered as a percent. A lead only exists once it cleared the engine
    /// score floor, so this never paints a fabricated score.
    static func scoreBadge(_ lead: FlipLead) -> String { "Teardown \(flipPct(lead.score))" }

    /// The honest empty state when a result carries no leads. A non-scorable county says so plainly
    /// (gated, not faked); a scorable one that found nothing says the ring beat nothing — never invents.
    static func emptyState(_ r: FlipScoutResult) -> (title: String, hint: String) {
        if isScorable(r) {
            return ("No teardown lots cleared the bar",
                    "Nothing in this ring beat the improvement-to-land threshold. Try another covered county.")
        }
        return ("No teardown scoring here",
                "This county publishes parcels + owners but no assessed-value layer, so teardowns can't be scored — gated honestly, not faked.")
    }

    /// One key-number row on a lead card. `isGap` marks the opportunity-gap estimate (rendered big).
    struct StatRow: Equatable { let label: String; let value: String; let isGap: Bool }

    /// The key-number rows a lead card renders — ONLY the fields the county actually published. A
    /// missing value is omitted entirely (never a fabricated $0); the estimated opportunity gap shows
    /// only when strictly positive.
    static func statRows(_ lead: FlipLead) -> [StatRow] {
        var rows: [StatRow] = []
        if let v = lead.value { rows.append(StatRow(label: "Assessed value", value: "$\(flipMoneyFmt(v))", isGap: false)) }
        if let l = lead.landValue { rows.append(StatRow(label: "Land value", value: "$\(flipMoneyFmt(l))", isGap: false)) }
        if let i = lead.imprValue { rows.append(StatRow(label: "Improvement value", value: "$\(flipMoneyFmt(i))", isGap: false)) }
        if let g = lead.estGap, g > 0 { rows.append(StatRow(label: "Opportunity gap (est.)", value: "$\(flipMoneyFmt(g))", isGap: true)) }
        return rows
    }

    /// Pinned disclosure copy — rendered VERBATIM by the screen so the honesty language can't be
    /// silently softened. (§5.1: spread is an estimate, missing fields say "unknown", counties gated.)
    static let countyScoutDisclosure = "Live county ArcGIS parcels in a ~3-mile ring around the county center. The teardown signal is the assessor's own improvement-to-land ratio (a cheap structure on dear land), or — where the county doesn't split it — a value well below the area average. Spread is shown as an opportunity-gap estimate, never a guaranteed profit. Counties without an open value layer are gated, never faked."
    static let databaseScoutDisclosure = "Loads matching parcels straight from the property database and keeps only rows with real deal math: teardown ratio, land-heavy assessed value, or recorded-sale value spread. Each card shows why it qualified plus the risks still needing verification. Missing fields say \"unknown\" — never invented."
}

struct LotFlipScoutScreen: View {
    @EnvironmentObject var model: AppModel
    var go: (Section) -> Void = { _ in }
    @State private var county: String = FlipParcelRegistry.all.first { $0.canScore }?.key ?? (FlipParcelRegistry.all.first?.key ?? "")
    @State private var scanning = false
    @State private var result: FlipScoutResult?
    @State private var route: CanvassRoute?
    @State private var note = ""
    // Database scout — market/type scoped (never an unscoped 28M-row walk).
    @State private var databaseArea = DatabaseListArea()
    @State private var databaseSignal: DatabaseDealScout.LotSignal = .teardown
    @State private var databaseScanning = false
    @State private var databaseStopRequested = false
    @State private var databaseCandidates: [DatabaseDealCandidate] = []
    @State private var databaseRowsScanned = 0
    @State private var databaseTotalRows: Int?
    @State private var databasePage = 0
    @State private var databaseTier = ""
    @State private var databaseMasked = false
    @State private var databaseNote = ""
    /// Auto-scan page budget per run — keeps a huge market from scanning forever;
    /// "Scan more" continues from where it stopped (honest, user-controlled).
    private let autoPageBudget = 20
    private let initialVisibleCandidates = 12
    private let visibleCandidateStep = 25
    @State private var databaseResumePage: Int?
    @State private var databaseVisibleLimit = 12

    /// Counties the scout can actually score (the picker leads with these); the rest are honest gates.
    private var scorable: [CountyParcels] { FlipParcelRegistry.all.filter { $0.canScore } }
    private var gated: [CountyParcels] { FlipParcelRegistry.all.filter { !$0.canScore } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Lot-Flip Scout",
                          subtitle: "Find builder teardown lots on real database records — improvement-to-land ratio, before the builder does")
                .blScreenPadding(28).padding(.bottom, 0)
            ScrollView { LazyVStack(alignment: .leading, spacing: 16) {
                databaseScoutPanel
                planPanel
                if scanning { scanningPanel }
                if let r = result { resultPanel(r) }
                if let rt = route, !rt.stops.isEmpty { routePanel(rt) }
            }.blScreenPadding(28).padding(.top, 8) }
            .scrollIndicators(.visible)
        }
        .onAppear { runLotFlipUISmokeIfRequested() }
    }

    // MARK: plan a scout

    private var databaseScoutPanel: some View {
        Panel(title: "Database deal scout", icon: "magnifyingglass.circle.fill", glow: true) {
            // 1 · WHERE — the scout always runs against a chosen market, never a
            // blind national walk that starts in Alaska and never finishes.
            Text("1 · CHOOSE A MARKET").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
            HStack(spacing: 10) {
                compactAreaField("State", text: $databaseArea.state, width: 64)
                compactAreaField("County", text: $databaseArea.county, width: 150)
                compactAreaField("City", text: $databaseArea.city, width: 140)
                compactAreaField("ZIP", text: $databaseArea.zip, width: 80)
                Spacer()
            }
            // 2 · WHAT — the lot/deal signal, each an honest server-side predicate.
            Text("2 · CHOOSE A LOT TYPE").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
            HStack(spacing: 8) {
                ForEach(DatabaseDealScout.LotSignal.allCases) { s in
                    Button { databaseSignal = s } label: {
                        Text(s.rawValue).font(BLFont.body(11.5, .semibold))
                            .foregroundColor(databaseSignal == s ? BLTheme.ink : BLTheme.sub)
                            .padding(.vertical, 6).padding(.horizontal, 11)
                            .background(databaseSignal == s ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(databaseSignal == s ? Color.clear : BLTheme.stroke, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            Text(databaseSignal.blurb).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
            // 3 · SCAN
            HStack(spacing: 14) {
                metric("Rows scanned", formatCount(databaseRowsScanned), BLTheme.text)
                metric("Candidates", formatCount(databaseCandidates.count), BLTheme.green)
                metric("Page", databasePage == 0 ? "-" : "\(databasePage)", BLTheme.gold)
            }
            if let total = databaseTotalRows {
                Text("\(formatCount(databaseRowsScanned)) of \(formatCount(total)) matching database rows checked\(databaseTier.isEmpty ? "" : " · \(databaseTier) tier")")
                    .font(BLFont.mono(10.5, .semibold)).foregroundColor(BLTheme.sub)
            }
            HStack(spacing: 10) {
                GoldButton(label: databaseScanning ? "Scanning \(scanAreaLabel)…" : "Scan \(scanAreaLabel)",
                           icon: databaseScanning ? "hourglass" : "play.fill") { runDatabaseScout() }
                    .opacity(databaseScanning || !databaseArea.hasLocation ? 0.6 : 1)
                    .disabled(databaseScanning || !databaseArea.hasLocation)
                if databaseScanning {
                    GhostButton(label: "Stop", icon: "stop.fill", tint: BL.danger) { databaseStopRequested = true }
                }
                if !databaseScanning, databaseResumePage != nil {
                    GhostButton(label: "Scan more", icon: "forward.fill", tint: BLTheme.gold) { runDatabaseScout(resume: true) }
                }
                if !databaseCandidates.isEmpty {
                    GhostButton(label: "Save all to My Leads", icon: "tray.and.arrow.down.fill", tint: BLTheme.green) {
                        saveAllDatabaseDeals()
                    }
                    GhostButton(label: "Open in Map", icon: "mappin.and.ellipse", tint: BLTheme.gold) { openCandidatesInMap() }
                    GhostButton(label: "Export CSV", icon: "square.and.arrow.up", tint: BLTheme.gold) { exportCandidates() }
                }
                Spacer()
            }
            if !databaseArea.hasLocation {
                Text("Pick at least a state, county, city, or ZIP — the scout scans real database rows for that market.")
                    .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub)
            }
            Text(LotFlipScoutPresenter.databaseScoutDisclosure)
                .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            if databaseMasked {
                Label("Preview tier: pages are 25 rows. Everything shown is real — add the Lead Database key in Settings for bigger scans.",
                      systemImage: "info.circle")
                    .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
            }
            if !databaseNote.isEmpty {
                Text(databaseNote).font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            if databaseScanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Evaluating public-record rows for actual deal signals…")
                        .font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.sub)
                }
            }
            if !databaseScanning && databaseRowsScanned > 0 && databaseCandidates.isEmpty {
                EmptyState(icon: "magnifyingglass",
                           title: "No candidates cleared the bar in the scanned rows",
                           hint: "Every scanned row is real; none scored ≥ \(DatabaseDealScout.defaultMinimumScore). Try another signal, widen the market, or scan more pages.")
            }
            if !databaseCandidates.isEmpty {
                HStack(spacing: 10) {
                    Text("Showing \(formatCount(visibleCandidateCount)) of \(formatCount(databaseCandidates.count)) candidates")
                        .font(BLFont.mono(10.5, .semibold)).foregroundColor(BLTheme.sub)
                    Spacer()
                    if databaseCandidates.count > databaseVisibleLimit {
                        GhostButton(label: "Show \(formatCount(min(visibleCandidateStep, databaseCandidates.count - databaseVisibleLimit))) more",
                                    icon: "chevron.down",
                                    tint: BLTheme.gold) {
                            databaseVisibleLimit = min(databaseCandidates.count, databaseVisibleLimit + visibleCandidateStep)
                        }
                    }
                    if databaseVisibleLimit > initialVisibleCandidates {
                        GhostButton(label: "Collapse", icon: "chevron.up", tint: BLTheme.text) {
                            databaseVisibleLimit = initialVisibleCandidates
                        }
                    }
                }
                ForEach(Array(databaseCandidates.prefix(visibleCandidateCount))) { candidate in databaseDealCard(candidate) }
            }
        }
    }

    private var visibleCandidateCount: Int {
        min(databaseVisibleLimit, databaseCandidates.count)
    }

    private var scanAreaLabel: String {
        databaseArea.hasLocation ? databaseArea.summary : "a market"
    }

    private func compactAreaField(_ title: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(BLFont.mono(8.5, .bold)).foregroundColor(BLTheme.sub).tracking(1.0)
            TextField(title, text: text)
                .font(BLFont.body(12, .semibold)).textFieldStyle(.plain).foregroundColor(BLTheme.text)
                .padding(.vertical, 7).padding(.horizontal, 9).background(BLTheme.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        }
        .frame(width: width)
    }

    private var planPanel: some View {
        Panel(title: "Scout a county", icon: "hammer.fill", glow: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text("COUNTY").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
                Picker("", selection: $county) {
                    if !scorable.isEmpty {
                        SwiftUI.Section("Scoring teardowns") {
                            ForEach(scorable, id: \.key) { c in
                                Text(c.display.replacingOccurrences(of: ", GA", with: "") + (c.hasSplit ? "  · land/impr split" : "  · area-avg"))
                                    .tag(c.key)
                            }
                        }
                    }
                    if !gated.isEmpty {
                        SwiftUI.Section("Mapped only (no value layer)") {
                            ForEach(gated, id: \.key) { c in
                                Text(c.display.replacingOccurrences(of: ", GA", with: "") + "  · gated").tag(c.key)
                            }
                        }
                    }
                }
                .labelsHidden().tint(BLTheme.gold).frame(maxWidth: 340, alignment: .leading)
            }
            HStack(spacing: 10) {
                GoldButton(label: scanning ? "Scouting…" : "Run scout",
                           icon: scanning ? "hourglass" : "scope") { runScout() }
                    .opacity(scanning ? 0.6 : 1).disabled(scanning || county.isEmpty)
                Spacer()
            }
            Text(LotFlipScoutPresenter.countyScoutDisclosure)
                .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            if !note.isEmpty {
                Text(note).font(BLFont.body(11.5, .semibold)).foregroundColor(BL.danger).fixedSize(horizontal: false, vertical: true)
            }
            Text("Covered: \(FlipParcelRegistry.coveredDisplay)")
                .font(BLFont.mono(10, .semibold)).foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scanningPanel: some View {
        Panel(title: "Scouting", icon: "scope", glow: false) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Locating the county center, then pulling + scoring real parcels…")
                    .font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.sub)
            }
        }
    }

    @ViewBuilder private func databaseDealCard(_ candidate: DatabaseDealCandidate) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.displayAddress)
                        .font(BLFont.body(14, .bold)).foregroundColor(BLTheme.text).lineLimit(2)
                    Text(candidate.displayOwner)
                        .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
                Spacer()
                FoilBadge(text: "\(candidate.tier) \(candidate.score)", icon: "checkmark.seal.fill")
            }
            Text(candidate.summary).font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("WHY THIS IS A DEAL").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.gold).tracking(1)
                ForEach(candidate.reasons) { reason in
                    HStack(alignment: .top, spacing: 8) {
                        Text("+\(reason.points)").font(BLFont.mono(10, .bold)).foregroundColor(BLTheme.green).frame(width: 34, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reason.title).font(BLFont.body(11.5, .bold)).foregroundColor(BLTheme.text)
                            Text(reason.detail).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: 8) {
                if let assessed = candidate.record.assessed_value { Stat(label: "Assessed", value: REMath.money(Double(assessed))) }
                if let land = candidate.record.land_value { Stat(label: "Land", value: REMath.money(Double(land))) }
                if let improvement = candidate.record.improvement_value { Stat(label: "Improvement", value: REMath.money(Double(improvement))) }
                if let sale = candidate.record.last_sale_price { Stat(label: "Last sale", value: REMath.money(Double(sale))) }
            }
            if !candidate.risks.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("VERIFY").font(BLFont.mono(9.5, .bold)).foregroundColor(BL.danger).tracking(1)
                    ForEach(candidate.risks, id: \.self) { risk in
                        Text("• \(risk)").font(BLFont.body(10.8, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.gold).tracking(1)
                ForEach(candidate.nextSteps, id: \.self) { step in
                    Text("• \(step)").font(BLFont.body(10.8, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                GhostButton(label: "Save lead", icon: "tray.and.arrow.down.fill", tint: BLTheme.green) {
                    let r = model.addDatabaseLeads([candidate.asLead(area: databaseArea, signal: databaseSignal)])
                    databaseNote = r.added == 1 ? "Saved \(candidate.displayAddress) to My Leads." : "\(candidate.displayAddress) is already in My Leads."
                }
                let mailing = DatabaseDealScout.mailingLine(candidate.record)
                if !mailing.isEmpty {
                    GhostButton(label: "Copy mailing", icon: "doc.on.doc", tint: BLTheme.text) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mailing, forType: .string)
                    }
                }
                if let lat = candidate.record.lat, let lng = candidate.record.lng {
                    GhostButton(label: "Open in Maps", icon: "mappin.and.ellipse", tint: BLTheme.gold) {
                        if let u = URL(string: "https://maps.apple.com/?q=\(lat),\(lng)") { NSWorkspace.shared.open(u) }
                    }
                }
                if let source = candidate.record.source_url, let url = URL(string: source) {
                    GhostButton(label: "Source", icon: "link", tint: BLTheme.gold) { NSWorkspace.shared.open(url) }
                }
                Spacer()
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func runDatabaseScout(resume: Bool = false) {
        guard !databaseScanning, databaseArea.hasLocation else { return }
        let startPage = resume ? (databaseResumePage ?? 1) : 1
        databaseScanning = true
        databaseStopRequested = false
        if !resume {
            databaseCandidates = []
            databaseRowsScanned = 0
            databaseTotalRows = nil
            databasePage = 0
            databaseVisibleLimit = initialVisibleCandidates
        }
        databaseResumePage = nil
        databaseTier = ""
        databaseMasked = false
        databaseNote = ""
        let loader = DatabaseDealScout.liveLoader(area: databaseArea, signal: databaseSignal)
        let budget = autoPageBudget
        Task {
            var page = startPage
            var pagesThisRun = 0
            var seen = Set(databaseCandidates.map(\.id))
            var finalMasked = false
            var lastNote = ""
            var pausedForBudget = false
            do {
                while true {
                    let stopped = await MainActor.run { databaseStopRequested }
                    if stopped { break }
                    let scan = try await DatabaseDealScout.scanPage(page: page, loader: loader)
                    let fresh = scan.candidates.filter { seen.insert($0.id).inserted }
                    finalMasked = scan.masked
                    lastNote = scan.note
                    await MainActor.run {
                        databasePage = scan.page
                        databaseRowsScanned += scan.scannedRows
                        databaseTotalRows = scan.total
                        databaseTier = scan.tier ?? ""
                        databaseMasked = scan.masked
                        databaseCandidates.append(contentsOf: fresh)
                        databaseCandidates.sort { ($0.score, $0.record.assessed_value ?? 0) > ($1.score, $1.record.assessed_value ?? 0) }
                        databaseNote = scan.note
                    }
                    if scan.isFinalPage { break }
                    pagesThisRun += 1
                    if pagesThisRun >= budget {
                        pausedForBudget = true
                        await MainActor.run { databaseResumePage = scan.page + 1 }
                        break
                    }
                    page = scan.page + 1
                }
                await MainActor.run {
                    let counts = "\(formatCount(databaseRowsScanned)) row\(databaseRowsScanned == 1 ? "" : "s") checked, \(formatCount(databaseCandidates.count)) candidate\(databaseCandidates.count == 1 ? "" : "s")"
                    if databaseStopRequested {
                        databaseNote = "Stopped: \(counts)."
                    } else if pausedForBudget {
                        databaseNote = "Paused after \(budget) pages (\(counts)). Scan more to continue where it left off."
                    } else if finalMasked && databaseCandidates.isEmpty {
                        databaseNote = lastNote
                    } else {
                        databaseNote = "Scan of \(databaseArea.summary) complete: \(counts)."
                    }
                    databaseScanning = false
                    databaseStopRequested = false
                    emitLotFlipUISmoke()
                }
            } catch {
                await MainActor.run {
                    databaseNote = "Database scan failed: \(error.localizedDescription)"
                    databaseScanning = false
                    databaseStopRequested = false
                    emitLotFlipUISmoke(error: error.localizedDescription)
                }
            }
        }
    }

    private func saveAllDatabaseDeals() {
        let result = model.addDatabaseLeads(databaseCandidates.map { $0.asLead(area: databaseArea, signal: databaseSignal) })
        databaseNote = result.added == 0
            ? "All \(formatCount(result.duplicates)) candidate\(result.duplicates == 1 ? " is" : "s are") already in My Leads."
            : "Saved \(formatCount(result.added)) into My Leads\(result.duplicates > 0 ? " · \(formatCount(result.duplicates)) already saved" : "")."
    }

    /// Show the scouted market's matching parcels as live pins on the Property Map,
    /// carrying the same server-side signal so pins == scanned records.
    private func openCandidatesInMap() {
        var criteria = DatabaseDealScout.criteria(area: databaseArea, signal: databaseSignal)
        criteria.categoryOverride = databaseSignal.apiCategory
        model.pendingPropertyMapRequest = .forList(criteria)
        go(.map)
    }

    private func exportCandidates() {
        guard !databaseCandidates.isEmpty else { return }
        let name = "lotflip-\(databaseSignal.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))-\(Int(Date().timeIntervalSince1970)).csv"
        guard exportTextFile(suggestedName: name,
                             contents: DatabaseListEngine.csv(databaseCandidates.map(\.record)),
                             type: .commaSeparatedText) != nil else {
            databaseNote = "Export cancelled."; return
        }
        databaseNote = "Exported \(formatCount(databaseCandidates.count)) candidate row\(databaseCandidates.count == 1 ? "" : "s")."
    }

    // DEV-ONLY UI smoke (BLRE_LOTFLIP_UI_SMOKE=1): auto-runs a scoped scan and prints
    // the outcome; proves the page loads, scans the database, and renders candidates.
    fileprivate func runLotFlipUISmokeIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["BLRE_LOTFLIP_UI_SMOKE"] == "1", !databaseScanning, databaseRowsScanned == 0 else { return }
        databaseArea = DatabaseListArea()
        databaseArea.state = env["BLRE_SMOKE_STATE"] ?? "RI"
        databaseSignal = .teardown
        runDatabaseScout()
    }

    private func emitLotFlipUISmoke(error: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        guard env["BLRE_LOTFLIP_UI_SMOKE"] == "1" else { return }
        let line = error.map { "BLRE_LOTFLIP_UI|phase=error|error=\($0)" }
            ?? "BLRE_LOTFLIP_UI|phase=done|signal=\(databaseSignal.rawValue)|state=\(databaseArea.state)|rows=\(databaseRowsScanned)|total=\(databaseTotalRows ?? -1)|candidates=\(databaseCandidates.count)"
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8) ?? Data())
        #if os(macOS)
        if env["BLRE_LOTFLIP_UI_SMOKE_QUIT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
        #endif
    }

    // MARK: results

    @ViewBuilder private func resultPanel(_ r: FlipScoutResult) -> some View {
        Panel(title: r.county, icon: "checkmark.seal.fill", glow: true) {
            HStack(spacing: 10) {
                StatusPill(text: LotFlipScoutPresenter.coverageLabel(r),
                           tint: r.supported ? (r.scored ? BLTheme.green : BLTheme.gold) : BL.danger)
                if r.scored { StatusPill(text: "\(r.leads.count) lead\(r.leads.count == 1 ? "" : "s")", tint: BLTheme.gold) }
                Spacer()
            }
            HStack(spacing: 14) {
                metric("Parcels scanned", "\(r.parcelsScanned)", BLTheme.text)
                if let avg = r.areaAvgValue { metric("Area avg value", "$\(flipMoneyFmt(avg))", BLTheme.gold) }
                if let ceil = r.ceilingValue { metric("Build comp ceiling", "$\(flipMoneyFmt(ceil))", BLTheme.green) }
            }
            if !r.note.isEmpty {
                Text(r.note).font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            if r.leads.isEmpty {
                let es = LotFlipScoutPresenter.emptyState(r)
                EmptyState(icon: "hammer", title: es.title, hint: es.hint)
            } else {
                ForEach(r.leads) { lead in leadCard(lead) }
            }
        }
    }

    @ViewBuilder private func leadCard(_ lead: FlipLead) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(lead.address.isEmpty ? "(address on record)" : lead.address)
                        .font(BLFont.body(14, .bold)).foregroundColor(BLTheme.text).lineLimit(2)
                    Text(lead.owner).font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
                Spacer()
                FoilBadge(text: LotFlipScoutPresenter.scoreBadge(lead), icon: "hammer.fill")
            }
            Text(lead.reason).font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            // Key numbers — only the ones the county actually published (never invented). The presenter
            // is the single, unit-tested source of which rows appear.
            VStack(spacing: 5) {
                ForEach(Array(LotFlipScoutPresenter.statRows(lead).enumerated()), id: \.offset) { _, row in
                    Stat(label: row.label, value: row.value, big: row.isGap)
                }
            }
            if !lead.mailing.isEmpty || lead.lat != nil {
                HStack(spacing: 10) {
                    if !lead.mailing.isEmpty {
                        GhostButton(label: "Copy owner mailing", icon: "doc.on.doc", tint: BLTheme.text) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(lead.mailing, forType: .string)
                        }
                    }
                    if let lat = lead.lat, let lng = lead.lng {
                        GhostButton(label: "Open in Maps", icon: "mappin.and.ellipse", tint: BLTheme.gold) {
                            if let u = URL(string: "https://maps.apple.com/?q=\(lat),\(lng)") { NSWorkspace.shared.open(u) }
                        }
                    }
                    Spacer()
                }
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: canvass route

    @ViewBuilder private func routePanel(_ rt: CanvassRoute) -> some View {
        Panel(title: "Canvass route", icon: "map.fill", glow: true) {
            HStack(spacing: 14) {
                metric("Stops", "\(rt.stops.count)", BLTheme.green)
                metric("Total miles", String(format: "%.1f", rt.totalMiles), BLTheme.gold)
            }
            Text("Nearest-neighbor run from the \(rt.startName.lowercased()), value-first by opportunity gap. Leads without a mapped coordinate are dropped (can't be driven to), never invented.")
                .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(rt.stops.enumerated()), id: \.element.id) { idx, stop in
                HStack(spacing: 10) {
                    Text("\(idx + 1)").font(BLFont.mono(11, .bold)).foregroundColor(BLTheme.ink)
                        .frame(width: 20, height: 20).background(BLTheme.goldGrad).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(stop.lead.address.isEmpty ? stop.lead.owner : stop.lead.address)
                            .font(BLFont.body(12.5, .medium)).foregroundColor(BLTheme.text).lineLimit(1)
                        Text(String(format: "%.1f mi leg · %.1f mi total", stop.legMiles, stop.cumulativeMiles))
                            .font(BLFont.mono(10, .semibold)).foregroundColor(BLTheme.sub)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder private func metric(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(BLFont.mono(22, .bold)).foregroundColor(tint)
            Text(label.uppercased()).font(BLFont.mono(9, .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(13)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func formatCount(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: run

    private func runScout() {
        guard let reg = FlipParcelRegistry.all.first(where: { $0.key == county }) else { return }
        scanning = true; result = nil; route = nil; note = ""
        Task {
            // Geocode the county center (free OSM, file-cached). Honest miss → no fabricated coordinate.
            guard let center = await OSMGeocoder.shared.geocode(reg.display) else {
                await MainActor.run {
                    scanning = false
                    note = "Couldn't locate \(reg.display) to anchor the parcel ring — try again shortly. Nothing was invented."
                }
                return
            }
            let r = await LotFlipScout.scout(lat: center.0, lng: center.1, countyRaw: reg.key)
            let rt = Canvasser.route(from: center.0, center.1, leads: r.leads)
            await MainActor.run {
                result = r
                route = rt.stops.isEmpty ? nil : rt
                scanning = false
            }
        }
    }
}
#endif // circuit-convert
