#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — DEALS list, the rich DEAL ANALYZER editor, and the standalone
// Analyzer scratchpad. All math is real (Model.Deal computed properties) and fully editable.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Deal view-model (pure, UI-free) — the honesty rules the analyzer/comps panel render.
//
// Extracted so the money screen's promises are asserted, not eyeballed:
//   1. Every result tile (MAO/70%, flip ROI, cap rate, cash-on-cash, wholesale spread) is derived
//      ONLY from the buyer's entered inputs via the Deal math — no seeded constant, no placeholder.
//   2. An empty deal renders honestly: a blank ARV field (never "$0"), and a NEEDS-INPUT verdict —
//      never a fabricated after-repair value to fill the tile.
//   3. The comps panel classifies by BASIS, not by prose: only real recorded sales read as "sold
//      comps", an assessed figure is always LABELED an estimate, and a gated pull shows NO ARV
//      number. A "sold comps" claim carrying zero underlying sales is an integrity failure.
enum DealPresenter {
    /// What the ARV field shows. Zero ⇒ the honest empty (the field's prompt), never "$0" — a
    /// placeholder zero reads as a real $0 after-repair value.
    static func arvFieldDisplay(_ deal: Deal) -> String {
        deal.arv > 0 ? String(Int(deal.arv)) : ""
    }

    /// The AnalyzerResults tiles as pure (label, value) pairs — the SAME numbers the view renders,
    /// each straight off the Deal math so a test can prove they trace to inputs, not constants.
    static func resultTiles(_ deal: Deal, maoPct: Double) -> [(label: String, value: String)] {
        var tiles: [(String, String)] = [
            ("MAO (\(Int(maoPct))%)", REMath.money(deal.mao(pct: maoPct))),
            (deal.profitLabel.uppercased(), REMath.money(deal.projectedProfit)),
        ]
        switch deal.exit {
        case .flip:
            tiles += [("All-in", REMath.money(deal.totalAllIn)),
                      ("Cash in", REMath.money(deal.cashInvested)),
                      ("ROI", REMath.pct(deal.flipROI))]
        case .rental:   // the BRRRR / buy-and-hold tiles
            tiles += [("Cash flow/mo", REMath.money(deal.monthlyCashFlow)),
                      ("Cap rate", REMath.pct(deal.capRate)),
                      ("Cash-on-cash", REMath.pct(deal.cashOnCash))]
        case .wholesale:
            tiles += [("MAO spread", REMath.money(deal.spreadVsAsking)),
                      ("Equity @ MAO", REMath.money(deal.equityAtMAO)),
                      ("Down pmt", REMath.money(deal.downPayment))]
        }
        return tiles
    }

    /// How the comps panel reads a CompsResult — classified by the engine's BASIS, never by its note.
    enum CompsPanel: Equatable {
        case soldComps(arv: Int, count: Int)      // real recorded arm's-length sales
        case sampleEstimate(arv: Int)             // synthetic workflow preview, explicitly unverified
        case assessedEstimate(arv: Int)           // labeled estimate — explicitly NOT sold comps
        case gated(note: String)                  // no source produced a figure — NO ARV shown
    }
    static func compsPanel(_ r: CompsResult) -> CompsPanel {
        guard r.available, let arv = r.arv else { return .gated(note: r.note) }
        switch CompsTruthPolicy.kind(r) {
        case .verifiedSoldComps: return .soldComps(arv: arv, count: r.comps.count)
        case .sampleEstimate: return .sampleEstimate(arv: arv)
        case .unverifiedEstimate: return .assessedEstimate(arv: arv)
        case .unavailable, .invalid: return .gated(note: r.note)
        }
    }

    /// HARD HONESTY INVARIANT: a "sold comps" result must carry the sales it claims. A comp-basis
    /// result with an empty comp set is a fabricated comp claim — this returns false so a test's
    /// planted-dishonesty control goes RED.
    static func compsIntegrity(_ r: CompsResult) -> Bool {
        CompsTruthPolicy.kind(r) != .invalid
    }

    /// Apply a pulled comps result to a deal EXACTLY as the editor does: write ARV only when the pull
    /// produced a real number, with a truthful `arvSource`. A gated result leaves ARV untouched —
    /// never a seeded constant. Returns the (possibly unchanged) deal so it's testable off the view.
    static func applyComps(_ r: CompsResult, to deal: Deal) -> Deal {
        var d = deal
        if r.available, let arv = r.arv {
            let kind = CompsTruthPolicy.kind(r)
            guard kind != .invalid && kind != .unavailable else { return d }
            d.arv = Double(arv)
            switch kind {
            case .verifiedSoldComps:
                d.arvSource = r.basis.label + " · \(r.comps.count) verified comps"
            case .sampleEstimate:
                d.arvSource = "Sample ARV estimate — not verified"
            case .unverifiedEstimate:
                d.arvSource = r.basis.label
            case .unavailable, .invalid:
                break
            }
        }
        return d
    }

    static func maoLabel(percent: Double, isSample: Bool) -> String {
        isSample ? "Sample MAO estimate (\(Int(percent))%) — not verified" : "MAO (\(Int(percent))%)"
    }
}

/// Pure presentation contract shared by the view and tests. It prevents a synthetic or
/// provenance-free result from inheriting the green verified-sold-comps treatment by accident.
struct CompsPresentation: Hashable {
    var usesVerifiedStyle: Bool
    var icon: String
    var title: String
    var arvLabel: String
    var overflowLabel: String

    static func make(_ result: CompsResult) -> CompsPresentation {
        let money = result.arv.map { REMath.money(Double($0)) } ?? ""
        let overflow = max(0, result.comps.count - 8)
        switch CompsTruthPolicy.kind(result) {
        case .verifiedSoldComps:
            return .init(usesVerifiedStyle: true, icon: "checkmark.seal.fill",
                         title: result.basis.label, arvLabel: money.isEmpty ? "" : "ARV \(money)",
                         overflowLabel: overflow > 0 ? "+ \(overflow) more recorded sales in the comp set" : "")
        case .sampleEstimate:
            return .init(usesVerifiedStyle: false, icon: "info.circle.fill",
                         title: "Synthetic sample comparables — not verified",
                         arvLabel: money.isEmpty ? "Sample ARV estimate — not verified" : "Sample ARV estimate \(money) — not verified",
                         overflowLabel: overflow > 0 ? "+ \(overflow) more synthetic sample rows" : "")
        case .unverifiedEstimate:
            return .init(usesVerifiedStyle: false, icon: "info.circle.fill", title: result.basis.label,
                         arvLabel: money.isEmpty ? "Estimate — not verified" : "Estimate \(money) — not verified",
                         overflowLabel: "")
        case .unavailable, .invalid:
            return .init(usesVerifiedStyle: false, icon: "exclamationmark.triangle.fill",
                         title: "No verified comps source", arvLabel: "", overflowLabel: "")
        }
    }
}

// MARK: - Deals list
struct DealsScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject private var jump = SearchJump.shared
    @State private var editing: Deal?
    @State private var sort: DealSort = .recent
    enum DealSort: String, CaseIterable, Identifiable { case recent, profit, arv; var id: String { rawValue }
        var label: String { switch self { case .recent: return "Recent"; case .profit: return "Profit"; case .arv: return "ARV" } } }
    private var sorted: [Deal] {
        switch sort {
        case .recent: return model.deals
        case .profit: return model.deals.sorted { $0.projectedProfit > $1.projectedProfit }
        case .arv: return model.deals.sorted { $0.arv > $1.arv }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderRow(title: "Deals", subtitle: "\(model.deals.count) tracked · \(REMath.money(model.pipelineProfit)) projected profit") {
                if !model.deals.isEmpty {
                    Picker("", selection: $sort) { ForEach(DealSort.allCases) { Text($0.label).tag($0) } }.labelsHidden().tint(BLTheme.gold).fixedSize()
                }
                GoldButton(label: "New deal", icon: "plus") { editing = Deal() }
            }.blScreenPadding(28)
            if model.deals.isEmpty {
                Spacer()
                EmptyState(icon: "house.lodge", title: "No deals yet", hint: "Tap New deal to analyze a property — ARV, rehab, MAO, ROI and cash-flow are computed live.")
                Spacer()
            } else {
                ScrollView { LazyVStack(spacing: 11) {
                    ForEach(sorted) { d in DealRow(deal: d, maoPct: settings.data.maoPercent) { editing = d } onDelete: { model.deleteDeal(d) } }
                }.padding(.horizontal, BLScale.gutter(28)).padding(.bottom, 28) }
            }
        }
        .sheet(item: $editing) { d in DealEditor(deal: d).environmentObject(model).environmentObject(settings).sheetCloseBar() }
        // Global-search deep link: a deal hit opens that deal's editor, not just this screen.
        .onAppear(perform: consumeSearchJump)
        .onChangeCompat(of: jump.deal) { _ in consumeSearchJump() }
    }
    private func consumeSearchJump() {
        guard let id = jump.deal else { return }
        jump.deal = nil
        if let d = model.deals.first(where: { $0.id == id }) { editing = d }
    }
}

struct DealRow: View {
    let deal: Deal; var maoPct: Double = 70; let onTap: () -> Void; let onDelete: () -> Void
    @State private var hover = false
    @State private var confirmDelete = false
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                IconBadge(system: deal.exit.icon, size: 38, active: false)
                VStack(alignment: .leading, spacing: 5) {
                    Text(deal.address.isEmpty ? "Untitled property" : deal.address).font(.blSystem(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                    HStack(spacing: 8) { StatusPill(text: deal.status.label, tint: deal.status.tint)
                        DealVerdictBadge(verdict: DealScoring.score(deal, maoPct: maoPct).verdict)
                        Text(deal.exit.label).font(.blSystem(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                        Text("\(DealPresenter.maoLabel(percent: maoPct, isSample: deal.sampleFixtureID != nil)) \(REMath.money(deal.mao(pct: maoPct)))").font(.blSystem(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub) }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(REMath.money(deal.projectedProfit)).font(.blSystem(size: 17, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.green)
                    Text(deal.profitLabel).font(.blSystem(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                Image(systemName: "chevron.right").font(.blSystem(size: 12, weight: .bold)).foregroundColor(BLTheme.sub.opacity(hover ? 1 : 0.4))
            }
            .padding(16)
            .background(hover ? BLTheme.panelHi : BLTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(hover ? BLTheme.gold.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
            .shadow(color: hover ? .black.opacity(0.35) : .clear, radius: 14, y: 6)
        }.buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hover = h } }
        .contextMenu { Button("Delete", role: .destructive) { confirmDelete = true } }
        .confirmationDialog("Delete this deal?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes it — there is no undo.") }
    }
}

// MARK: - The full deal analyzer (editor). Live ARV/rehab/MAO/ROI/cash-flow.
struct DealEditor: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) var dismiss
    @State var deal: Deal
    @State private var compsResult: CompsResult? = nil
    @State private var pullingComps = false
    @State private var confirmDelete = false
    /// The deal as opened — dirty means the local copy differs from what the model holds
    /// (falling back to this snapshot for a not-yet-saved new deal).
    private let original: Deal
    init(deal: Deal) { self.original = deal; self._deal = State(initialValue: deal) }
    private var isDirty: Bool { deal != (model.deals.first(where: { $0.id == deal.id }) ?? original) }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconBadge(system: deal.exit.icon, size: 30)
                Text(deal.address.isEmpty ? "New deal" : "Edit deal").font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
            }
            Picker("", selection: $deal.exit) { ForEach(ExitStrategy.allCases) { Label($0.label, systemImage: $0.icon).tag($0) } }
                .pickerStyle(.segmented)

            Field(title: "Property address", text: $deal.address, prompt: "Property address")
            HStack(spacing: 12) {
                Field(title: "County", text: $deal.county, prompt: "Harris")
                NumField(title: "Square feet", value: $deal.sqft, prompt: "1800")
            }

            PropertyDossierPanel(deal: $deal, maoPct: settings.data.maoPercent)

            // ARV — real SOLD COMPS where the county publishes recorded sales; else a labeled
            // assessed-value estimate; else an honest gate. No fabricated comps.
            grpHeader("VALUATION (ARV)")
            HStack(spacing: 12) {
                NumField(title: "ARV", value: $deal.arv, prompt: "320000")
                Field(title: "ARV source", text: $deal.arvSource, prompt: "Sold comps / assessed est. / your est.")
            }
            if ParcelRegistry.covers(deal.county) {
                let supportsComps = ParcelRegistry.source(for: deal.county)?.supportsComps ?? false
                HStack(spacing: 10) {
                    GhostButton(label: pullingComps ? "Pulling comps…" : (supportsComps ? "Pull sold comps + ARV" : "Pull 3-mi assessed est."),
                                icon: pullingComps ? "hourglass" : (supportsComps ? "chart.bar.doc.horizontal" : "scope"), tint: BLTheme.gold) { pullComps() }
                        .disabled(pullingComps || deal.address.trimmingCharacters(in: .whitespaces).isEmpty)
                    if pullingComps { ProgressView().scaleEffect(0.6) }
                    Spacer()
                }
                if let r = compsResult {
                    CompsResultView(result: r)
                } else {
                    Text(supportsComps
                         ? "Live, free \(deal.county.capitalized) County GIS. Derives ARV from real recorded SALES near this address (median $/sqft) — actual sold comps, not assessed value."
                         : "Live, free \(deal.county.capitalized) County GIS. This county publishes no recorded sale prices, so ARV falls back to a LABELED 3-mile assessed estimate — never a fabricated comp.")
                        .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
            } else if !deal.county.isEmpty {
                Text("No open comps source wired for \(deal.county.capitalized) County yet — enter ARV manually or add the county's ArcGIS layer in Settings → Markets & Counties. Nothing is fabricated.")
                    .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }

            // Rehab estimator
            grpHeader("REHAB")
            Toggle(isOn: $deal.useRehabEstimate) { Text("Estimate rehab from sqft × condition").font(BLFont.body(12.5, .semibold)) }.toggleStyle(.switch).tint(BLTheme.gold)
            if deal.useRehabEstimate {
                Picker("", selection: $deal.rehabLevel) { ForEach(RehabLevel.allCases) { Text("\($0.label) ($\(Int($0.perSqft))/sf)").tag($0) } }.labelsHidden().tint(BLTheme.gold)
                Text("\(deal.rehabLevel.hint) · est. \(REMath.money(deal.rehabEstimate)) on \(Int(deal.sqft)) sf").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub)
            } else {
                NumField(title: "Repairs ($)", value: $deal.repairs, prompt: "45000")
            }

            // Offer + financing
            grpHeader("OFFER & FINANCING")
            HStack(spacing: 12) {
                NumField(title: "Asking / purchase", value: $deal.asking, prompt: "190000")
                NumField(title: "Down %", value: $deal.downPct, prompt: "20")
            }
            HStack(spacing: 12) {
                NumField(title: "APR %", value: $deal.apr, prompt: "7.5")
                NumField(title: "Loan years", value: $deal.loanYears, prompt: "30")
                NumField(title: "Closing %", value: $deal.closingCostsPct, prompt: "3")
            }

            // Exit-specific inputs
            if deal.exit == .flip {
                HStack(spacing: 12) {
                    NumField(title: "Hold months", value: $deal.holdingMonths, prompt: "5")
                    NumField(title: "Monthly carry", value: $deal.monthlyCarry, prompt: "1200")
                }
            } else if deal.exit == .rental {
                HStack(spacing: 12) {
                    NumField(title: "Monthly rent", value: $deal.monthlyRent, prompt: "2100")
                    NumField(title: "Monthly opex", value: $deal.monthlyOpEx, prompt: "600")
                }
            } else {
                NumField(title: "Assignment fee", value: $deal.assignmentFee, prompt: "10000")
            }

            Picker("Status", selection: $deal.status) { ForEach(DealStatus.allCases) { Text($0.label).tag($0) } }
                .pickerStyle(.menu).tint(BLTheme.gold)

            // Live results
            AnalyzerResults(deal: deal, maoPct: settings.data.maoPercent)

            VStack(alignment: .leading, spacing: 4) {
                Text("NOTES").font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $deal.notes).font(.blSystem(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden).padding(8).frame(height: 60).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            HStack(spacing: 10) {
                // Visible Delete for a saved deal — the list's right-click context menu is a
                // shortcut, never the only path (matches LeadDetail).
                if model.deals.contains(where: { $0.id == deal.id }) {
                    GhostButton(label: "Delete", icon: "trash", tint: BL.danger) { confirmDelete = true }
                }
                Spacer()
                GhostButton(label: "Cancel", tint: BLTheme.sub) { dismiss() }
                GoldButton(label: "Save deal", icon: "checkmark") { model.upsert(deal); dismiss() }
            }
            .confirmationDialog("Delete this deal?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.deleteDeal(deal); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This permanently removes it — there is no undo.") }
        }.blScreenPadding(26) }
        .sheetFrame(560, 720)
        .sheetEditsPending(isDirty)
    }
    @ViewBuilder private func grpHeader(_ t: String) -> some View {
        Text(t).font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.gold).tracking(1).padding(.top, 4)
    }
    /// Pull real sold comps (county deed roll) → ARV; fall back to a LABELED assessed estimate; gate
    /// honestly. Geocodes the subject, pulls the 3-mile assessed average (the AVM fallback input),
    /// then runs the comps engine. Sets ARV + a truthful `arvSource` the deal math + screens surface.
    private func pullComps() {
        pullingComps = true; compsResult = nil
        let county = deal.county, addr = deal.address, sqft = deal.sqft > 0 ? deal.sqft : nil
        let parcel = deal.parcel.trimmingCharacters(in: .whitespaces)
        Task {
            guard let coord = await OSMGeocoder.shared.geocode(addr) else {
                await MainActor.run { pullingComps = false
                    compsResult = CompsResult.gated("Couldn't locate that address to pull comps.", radius: 3) }
                return
            }
            // The assessed-area average is the labeled AVM fallback when no sold comps exist.
            let av = await ParcelLookup.areaValueAvg(county: county, lat: coord.0, lng: coord.1)
            // Scope the public-records comps read to the ZIP/state the buyer actually typed in the
            // address (real user data, never invented). If neither is present the read stays dormant
            // and we fall through to county ArcGIS → AVM → honest gate (behavior unchanged).
            let (zip, st) = Self.zipAndState(from: addr)
            let r = await CompsEngine.comps(county: county, lat: coord.0, lng: coord.1,
                                            subjectSqft: sqft, zip: zip, state: st,
                                            parcelId: parcel.isEmpty ? nil : parcel, assessedAVM: av.avgValue)
            await MainActor.run {
                pullingComps = false
                compsResult = r
                deal = DealPresenter.applyComps(r, to: deal)   // writes ARV only on a real pull (tested)
            }
        }
    }

    /// Extract a 5-digit ZIP and a valid US 2-letter state code from a free-text address the buyer
    /// typed. Returns nil for anything not actually present — never guesses. Used only to scope the
    /// public-records comps read (ZIP/state are public query params; no PII leaves the device).
    static func zipAndState(from address: String) -> (zip: String?, state: String?) {
        let upper = address.uppercased()
        // ZIP: a standalone 5-digit group (optionally ZIP+4). Take the last match (trailing ZIP).
        var zip: String? = nil
        let tokens = upper.components(separatedBy: CharacterSet(charactersIn: " ,\n\t-"))
        for t in tokens where t.count == 5 && t.allSatisfy({ $0.isNumber }) { zip = t }
        // State: a standalone 2-letter token that is a real US state/DC code.
        var state: String? = nil
        for t in tokens.reversed() where t.count == 2 && NationalPropertyCoverage.requiredStateCodes.contains(t) {
            state = t; break
        }
        return (zip, state)
    }
}

// A real, honest comps panel: the derived ARV + its BASIS label + the actual recorded sale set
// (real addresses, prices, dates) so a buyer sees the basis. Empty/AVM/gated states are explicit.
struct CompsResultView: View {
    let result: CompsResult
    /// The plain-language BASIS the ARV rests on — so the number is never presented unlabeled (§5.1).
    /// The subject parcel's OWN recorded sales roll is called out distinctly from a neighborhood ring
    /// and from a labeled assessed estimate.
    private var basisLine: String {
        if result.source == .sample {
            return "synthetic Sample Mode comparables — workflow preview only, NOT county records or real sales"
        }
        if result.fromParcelOwnHistory {
            return "this parcel's own recorded sales history (county deed roll)"
        }
        switch result.basis {
        case .soldCompsPerSqft, .soldCompsMedian:
            return result.isAreaRead ? "recorded arm's-length sales in the area (public-records read)"
                                     : "recorded arm's-length sales near this parcel (county deed roll)"
        case .sampleEstimate:       return "synthetic Sample Mode inputs — workflow preview only, NOT county records or real sales"
        case .parcelOwnSaleAnchor:  return "this parcel's own recorded sale — a labeled anchor, NOT neighborhood sold comps"
        case .assessedAVM:          return "county-assessed value — a labeled estimate, NOT sold comps"
        case .assessedAreaEstimate: return "county-assessed area read — a labeled estimate, NOT sold comps"
        case .none:                 return "no comps source connected"
        }
    }
    var body: some View {
        let presentation = CompsPresentation.make(result)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: presentation.icon)
                    .foregroundColor(presentation.usesVerifiedStyle ? BLTheme.green : (result.available ? BLTheme.gold : BLTheme.sub))
                    .font(.blSystem(size: 12, weight: .bold))
                Text(presentation.title).font(BLFont.mono(10, .bold)).foregroundColor(presentation.usesVerifiedStyle ? BLTheme.green : BLTheme.gold)
                if !presentation.arvLabel.isEmpty { Text("· \(presentation.arvLabel)").font(BLFont.body(11.5, .bold)).foregroundColor(BLTheme.text) }
                if result.source == .sample { StatusPill(text: "SYNTHETIC SAMPLE", tint: BLTheme.gold) }
                Spacer()
            }
            // Explicit BASIS line so a buyer never reads an unlabeled ARV (§5.1): comps from the subject
            // parcel's OWN recorded sales roll say so verbatim; a neighborhood ring vs a labeled AVM read
            // distinctly. Only shown when there is an ARV to qualify.
            if result.arv != nil {
                Text("BASIS: " + basisLine)
                    .font(BLFont.mono(8.5, .bold)).foregroundColor(presentation.usesVerifiedStyle ? BLTheme.green : BLTheme.gold)
                    .tracking(0.5)
            }
            Text(result.note).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            if !result.comps.isEmpty {
                Text(result.source == .sample ? "SYNTHETIC SAMPLE COMPARABLES" : "RECENT NEARBY SALES (county deed roll)")
                    .font(BLFont.mono(8.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.6).padding(.top, 2)
                VStack(spacing: 4) {
                    ForEach(result.comps.prefix(8)) { c in
                        HStack(spacing: 8) {
                            Text(c.address).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.text).lineLimit(1)
                            Spacer(minLength: 6)
                            if let d = c.distanceMiles { Text("\(String(format: "%.1f", d)) mi").font(BLFont.mono(9, .regular)).foregroundColor(BLTheme.sub) }
                            Text(result.source == .sample ? "Sample input" : c.dateLabel).font(BLFont.mono(9, .regular)).foregroundColor(BLTheme.sub)
                            if let ps = c.pricePerSqft { Text("$\(Int(ps))/sf").font(BLFont.mono(9, .regular)).foregroundColor(BLTheme.sub) }
                            Text(REMath.money(Double(c.salePrice))).font(BLFont.mono(10, .bold)).foregroundColor(BLTheme.gold)
                        }
                        .padding(.vertical, 3).padding(.horizontal, 8)
                        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
                if !presentation.overflowLabel.isEmpty {
                    Text(presentation.overflowLabel).font(BLFont.body(9.5, .medium)).foregroundColor(BLTheme.sub)
                }
            }
        }
        .padding(10)
        .background(BLTheme.bg2.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }
}

// Results panel — reused by the editor and the standalone analyzer.
struct AnalyzerResults: View {
    let deal: Deal; let maoPct: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The synthesized verdict over all the real math below — the one-glance "should I buy this?".
            DealScorecardView(deal: deal, maoPct: maoPct)
            AdaptiveStack(spacing: 12) {
                resultTile(DealPresenter.maoLabel(percent: maoPct, isSample: deal.sampleFixtureID != nil), REMath.money(deal.mao(pct: maoPct)), BLTheme.goldGrad)
                resultTile(deal.profitLabel.uppercased(), REMath.money(deal.projectedProfit), plain: BLTheme.green)
            }
            if deal.exit == .flip {
                AdaptiveStack(spacing: 12) {
                    smallTile("All-in", REMath.money(deal.totalAllIn))
                    smallTile("Cash in", REMath.money(deal.cashInvested))
                    smallTile("ROI", REMath.pct(deal.flipROI))
                }
            } else if deal.exit == .rental {
                AdaptiveStack(spacing: 12) {
                    smallTile("Cash flow/mo", REMath.money(deal.monthlyCashFlow))
                    smallTile("Cap rate", REMath.pct(deal.capRate))
                    smallTile("Cash-on-cash", REMath.pct(deal.cashOnCash))
                }
            } else {
                AdaptiveStack(spacing: 12) {
                    smallTile("MAO spread", REMath.money(deal.spreadVsAsking))
                    smallTile("Equity @ MAO", REMath.money(deal.equityAtMAO))
                    smallTile("Down pmt", REMath.money(deal.downPayment))
                }
            }
        }
    }
    @ViewBuilder private func resultTile(_ l: String, _ v: String, _ grad: LinearGradient? = nil, plain: Color = BLTheme.text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l).font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
            Text(v).font(.blSystem(size: 20, weight: .heavy, design: .rounded))
                .foregroundStyle(grad.map(AnyShapeStyle.init) ?? AnyShapeStyle(plain))
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    @ViewBuilder private func smallTile(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(l).font(.blSystem(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.4)
            Text(v).font(.blSystem(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Deal Scorecard (the synthesized GO / CAUTION / PASS verdict)

extension DealVerdict {
    /// Verdict → palette (kept in the SwiftUI layer so the engine stays Foundation-only).
    var tint: Color {
        switch self {
        case .go:         return BLTheme.green
        case .caution:    return BLTheme.gold
        case .pass:       return BL.danger
        case .incomplete: return BLTheme.sub
        }
    }
}

/// A trustworthy one-glance verdict over the deal's REAL math — with the factor breakdown shown so
/// the buyer sees exactly WHY. Honest by construction: NEEDS-INPUT when ARV is missing, and a GO is
/// never printed on an unverified (estimate-only) ARV.
struct DealScorecardView: View {
    let deal: Deal
    var maoPct: Double = 70
    var body: some View {
        let s = DealScoring.score(deal, maoPct: maoPct)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(s.verdict.tint.opacity(0.16)).frame(width: 46, height: 46)
                    Image(systemName: s.verdict.icon).font(.blSystem(size: 20, weight: .bold)).foregroundColor(s.verdict.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(s.verdict.label).font(.blSystem(size: 17, weight: .heavy, design: .rounded)).foregroundColor(s.verdict.tint)
                        if s.verdict != .incomplete {
                            Text("\(s.score)/100").font(BLFont.mono(12, .bold)).foregroundColor(BLTheme.sub)
                        }
                        if s.capped { StatusPill(text: "ARV unverified", tint: BLTheme.gold) }
                    }
                    Text(s.verdict.title).font(.blSystem(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(s.keyMetricValue).font(.blSystem(size: 16, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(s.keyMetricLabel.uppercased()).font(.blSystem(size: 8.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.4)
                }
            }
            if !s.reason.isEmpty {
                Text(s.reason).font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            if !s.factors.isEmpty {
                VStack(spacing: 7) { ForEach(s.factors) { ScoreFactorBar(factor: $0) } }.padding(.top, 2)
            }
        }
        .padding(15)
        .background(BLTheme.bg2.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(s.verdict.tint.opacity(0.35), lineWidth: 1))
    }
}

/// One score factor as a labeled bar (points / max) + its honest explanation.
private struct ScoreFactorBar: View {
    let factor: ScoreFactor
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(factor.name).font(.blSystem(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Text("\(factor.points)/\(factor.max)").font(BLFont.mono(9.5, .semibold)).foregroundColor(BLTheme.sub)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(BLTheme.stroke.opacity(0.5)).frame(height: 4)
                    Capsule().fill(barColor).frame(width: max(3, geo.size.width * frac), height: 4)
                }
            }.frame(height: 4)
            Text(factor.detail).font(.blSystem(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private var frac: Double { factor.max > 0 ? Double(factor.points) / Double(factor.max) : 0 }
    private var barColor: Color {
        switch frac { case 0.75...: return BLTheme.green; case 0.4..<0.75: return BLTheme.gold; default: return BL.danger.opacity(0.85) }
    }
}

/// Compact verdict chip for the Deals list (verdict at a glance across the pipeline).
struct DealVerdictBadge: View {
    let verdict: DealVerdict
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: verdict.icon).font(.blSystem(size: 8.5, weight: .bold))
            Text(verdict.label).font(.blSystem(size: 9.5, weight: .heavy, design: .rounded))
        }
        .foregroundColor(verdict.tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(verdict.tint.opacity(0.14)).clipShape(Capsule())
    }
}

// MARK: - Standalone analyzer scratchpad (analyze without saving; one tap to save as a deal)
struct AnalyzerScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: SettingsStore
    @State private var deal = Deal()
    @State private var saved = false
    @State private var compsResult: CompsResult? = nil
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Deal Analyzer", subtitle: "Model any property — ARV, rehab, MAO, ROI, cash-flow, financing. Save it as a deal when it pencils.")
            Panel(title: "Inputs", icon: "slider.horizontal.3", glow: true) {
                Picker("", selection: $deal.exit) { ForEach(ExitStrategy.allCases) { Label($0.label, systemImage: $0.icon).tag($0) } }.pickerStyle(.segmented)
                AdaptiveStack(spacing: 12) { Field(title: "Address", text: $deal.address, prompt: "optional"); NumField(title: "Square feet", value: $deal.sqft, prompt: "1800") }
                AdaptiveStack(spacing: 12) { NumField(title: "ARV", value: $deal.arv, prompt: "320000"); NumField(title: "Asking", value: $deal.asking, prompt: "190000") }
                Toggle(isOn: $deal.useRehabEstimate) { Text("Estimate rehab from sqft × condition").font(BLFont.body(12.5, .semibold)) }.toggleStyle(.switch).tint(BLTheme.gold)
                if deal.useRehabEstimate {
                    Picker("", selection: $deal.rehabLevel) { ForEach(RehabLevel.allCases) { Text("\($0.label) ($\(Int($0.perSqft))/sf)").tag($0) } }.labelsHidden().tint(BLTheme.gold)
                } else { NumField(title: "Repairs", value: $deal.repairs, prompt: "45000") }
                AdaptiveStack(spacing: 12) { NumField(title: "Down %", value: $deal.downPct, prompt: "20"); NumField(title: "APR %", value: $deal.apr, prompt: "7.5"); NumField(title: "Closing %", value: $deal.closingCostsPct, prompt: "3") }
                if deal.exit == .flip { AdaptiveStack(spacing: 12) { NumField(title: "Hold months", value: $deal.holdingMonths, prompt: "5"); NumField(title: "Monthly carry", value: $deal.monthlyCarry, prompt: "1200") } }
                else if deal.exit == .rental { AdaptiveStack(spacing: 12) { NumField(title: "Monthly rent", value: $deal.monthlyRent, prompt: "2100"); NumField(title: "Monthly opex", value: $deal.monthlyOpEx, prompt: "600") } }
                else { NumField(title: "Assignment fee", value: $deal.assignmentFee, prompt: "10000") }
            }
            if let compsResult {
                Panel(title: model.isDemo ? "Completed sample ARV + comps" : "ARV + comps", icon: "chart.bar.doc.horizontal", glow: true) {
                    if model.isDemo {
                        Label("SAMPLE ARV + MAO ESTIMATES — NOT VERIFIED", systemImage: "info.circle.fill")
                            .font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.gold)
                    }
                    CompsResultView(result: compsResult)
                }
            }
            Panel(title: "Results", icon: "function") {
                AnalyzerResults(deal: deal, maoPct: settings.data.maoPercent)
                HStack {
                    GoldButton(label: "Save as deal", icon: "tray.and.arrow.down") {
                        model.upsert(deal)
                        if model.isDemo {
                            deal = DemoData.analysisDeal(from: model.deals)
                            compsResult = DemoData.analysisComps(for: deal)
                        } else {
                            deal = Deal(); compsResult = nil
                        }
                        withAnimation { saved = true }
                    }
                    if saved { Label("Saved to Deals", systemImage: "checkmark.circle.fill").font(BLFont.body(12, .bold)).foregroundColor(BLTheme.green) }
                    Spacer()
                }
            }
        }.blScreenPadding(28) }
        .onAppear {
            guard model.isDemo, deal.address.isEmpty else { return }
            deal = DemoData.analysisDeal(from: model.deals)
            compsResult = DemoData.analysisComps(for: deal)
        }
    }
}

// Numeric field bound to a Double (blank = 0). Reusable across analyzer screens.
// Stays in sync when `value` is set programmatically (e.g. "Pull 3-mi avg" writes ARV).
enum NumericInput {
    static func parse(_ raw: String) -> Double {
        let canonical = raw
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !canonical.isEmpty,
              canonical.allSatisfy({ $0.isNumber || $0 == "." }),
              canonical.filter({ $0 == "." }).count <= 1,
              let parsed = Double(canonical), parsed.isFinite, parsed >= 0 else { return 0 }
        return parsed
    }

    static func format(_ value: Double) -> String {
        guard value != 0 else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(value)
    }
}

struct NumField: View {
    let title: String; @Binding var value: Double; var prompt = ""
    @State private var text = ""
    @FocusState private var focused: Bool
    private var accessibilityID: String {
        "deal-input." + title.lowercased().map { character in
            character.isLetter || character.isNumber ? String(character) : "-"
        }.joined()
    }
    private func commit(_ raw: String) { value = NumericInput.parse(raw) }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain).font(.blSystem(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .focused($focused)
                .accessibilityLabel(title)
                .accessibilityIdentifier(accessibilityID)
                .padding(.vertical, 11).padding(.horizontal, 13)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(focused ? BLTheme.gold.opacity(0.6) : BLTheme.stroke, lineWidth: focused ? 1.5 : 1))
                .onChangeCompat(of: text) { commit($0) }
                .onSubmit { commit(text) }
                .onChangeCompat(of: focused) { isFocused in if !isFocused { commit(text) } }
                // Reflect external programmatic changes only while the user isn't typing.
                .onChangeCompat(of: value) { v in if !focused, NumericInput.format(v) != text { text = NumericInput.format(v) } }
                .onAppear { text = NumericInput.format(value) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif // circuit-convert
