#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — one-click property verification dossier.
//
// This is the decision layer over the app's real source engines. One explicit buyer action runs the
// available assessor, comps, Census, FEMA, recorder, and underwriting paths; every section reports verified,
// attention, setup-needed, or unavailable. An absent response never becomes a reassuring answer.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum PropertyDossierState: String, Codable, Hashable {
    case verified
    case attention
    case setupNeeded
    case unavailable

    var label: String {
        switch self {
        case .verified: return "VERIFIED"
        case .attention: return "ATTENTION"
        case .setupNeeded: return "SETUP NEEDED"
        case .unavailable: return "UNAVAILABLE"
        }
    }
    var icon: String {
        switch self {
        case .verified: return "checkmark.seal.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .setupNeeded: return "wrench.and.screwdriver.fill"
        case .unavailable: return "questionmark.circle.fill"
        }
    }
}

struct PropertyDossierCheck: Identifiable, Codable, Hashable {
    var id: String { category }
    var category: String
    var state: PropertyDossierState
    var headline: String
    var detail: String
    var source: String
    var isBlocker: Bool
}

enum PropertyDossierDecision: String, Codable, Hashable {
    case pursue = "PURSUE"
    case review = "REVIEW"
    case pass = "PASS"
    case needsInput = "NEEDS INPUT"
}

struct PropertyDossier: Hashable {
    var decision: PropertyDossierDecision
    var analyzedDeal: Deal
    var score: DealScore
    var checks: [PropertyDossierCheck]
    var fetchedAt: Date
    var summary: String

    var blockers: [PropertyDossierCheck] { checks.filter(\.isBlocker) }
    var verifiedCount: Int { checks.filter { $0.state == .verified }.count }
}

/// A source can return real evidence, need buyer setup, or be unavailable. Keeping these distinct is
/// what prevents a timeout/no-coverage response from becoming an invented negative result.
enum DossierEvidence<Value> {
    case available(Value)
    case setup(String)
    case unavailable(String)
}

enum PropertyDossierEngine {
    static func run(deal: Deal, maoPct: Double = 70,
                    session: URLSession = .shared) async -> PropertyDossier {
        let address = deal.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinate = address.isEmpty ? nil : await OSMGeocoder.shared.geocode(address)

        async let comps = loadComps(deal: deal, coordinate: coordinate)
        async let market = loadMarket(address: address, session: session)
        async let flood = loadFlood(coordinate: coordinate, session: session)
        async let title = loadTitle(deal: deal, session: session)
        async let assessor = loadAssessor(deal: deal)
        let evidence = await (comps, market, flood, title, assessor)
        return build(deal: deal, maoPct: maoPct, coordinate: coordinate,
                     comps: evidence.0, market: evidence.1, flood: evidence.2,
                     title: evidence.3, assessor: evidence.4, now: Date())
    }

    /// Pure dossier assembly, exposed to the offline suite so decision/blocker honesty is pinned.
    static func build(deal: Deal, maoPct: Double = 70, coordinate: (Double, Double)? = nil,
                      comps: DossierEvidence<CompsResult>,
                      market: DossierEvidence<CensusMarketComparison>,
                      flood: DossierEvidence<FloodFeatureSet>,
                      title: DossierEvidence<TitleChainSet>,
                      assessor: DossierEvidence<ParcelRecord> = .setup("Exact subject-parcel verification was not supplied."),
                      now: Date = Date()) -> PropertyDossier {
        var analyzed = deal
        if let coordinate { analyzed.lat = coordinate.0; analyzed.lng = coordinate.1 }
        var checks: [PropertyDossierCheck] = []

        switch assessor {
        case .available(let record) where record.available && !record.gated && record.parcel != nil:
            if analyzed.lat == nil, let lat = record.lat { analyzed.lat = lat }
            if analyzed.lng == nil, let lng = record.lng { analyzed.lng = lng }
            let facts = [
                record.owner.map { "owner on record \($0)" } ?? "owner not published",
                record.address.map { "situs \($0)" } ?? "situs not published",
                record.assessedValue.map { "assessed \(REMath.money(Double($0)))" } ?? "assessed value not published"
            ].joined(separator: " · ")
            checks.append(.init(category: "Subject parcel", state: .verified,
                                headline: "Parcel \(record.parcel!) matched one assessor identity",
                                detail: facts,
                                source: "\(deal.county.capitalized) County assessor ArcGIS · exact parcel-field query",
                                isBlocker: false))
        case .available(let record):
            checks.append(.init(category: "Subject parcel", state: .unavailable,
                                headline: "Subject parcel identity could not be verified",
                                detail: record.note.isEmpty ? "The assessor returned no single exact parcel identity." : record.note,
                                source: "\(deal.county.capitalized) County assessor ArcGIS",
                                isBlocker: true))
        case .setup(let note):
            checks.append(.init(category: "Subject parcel", state: .setupNeeded,
                                headline: "County and parcel ID are required", detail: note,
                                source: "County assessor ArcGIS", isBlocker: true))
        case .unavailable(let note):
            checks.append(.init(category: "Subject parcel", state: .unavailable,
                                headline: "Subject parcel identity could not be verified", detail: note,
                                source: "County assessor ArcGIS", isBlocker: true))
        }

        switch comps {
        case .available(let result) where result.available && result.arv != nil:
            analyzed = DealPresenter.applyComps(result, to: analyzed)
            let isComp = CompsTruthPolicy.isVerifiedSoldComps(result)
            let isSample = CompsTruthPolicy.kind(result) == .sampleEstimate
            checks.append(.init(category: "Valuation", state: isComp ? .verified : .attention,
                                headline: isComp
                                    ? "ARV backed by \(result.comps.count) recorded sale\(result.comps.count == 1 ? "" : "s")"
                                    : (isSample ? "Sample ARV estimate — not verified" : "ARV is a labeled estimate, not sold comps"),
                                detail: result.note,
                                source: result.source.label, isBlocker: !result.available))
        case .available(let result):
            checks.append(.init(category: "Valuation", state: .unavailable,
                                headline: "No source-backed ARV returned", detail: result.note,
                                source: result.source.label, isBlocker: true))
        case .setup(let note):
            checks.append(.init(category: "Valuation", state: .setupNeeded,
                                headline: "Connect or enter a valuation basis", detail: note,
                                source: "County/public-record comps", isBlocker: true))
        case .unavailable(let note):
            checks.append(.init(category: "Valuation", state: .unavailable,
                                headline: "Valuation could not be verified", detail: note,
                                source: "County/public-record comps", isBlocker: true))
        }

        let score = DealScoring.score(analyzed, maoPct: maoPct)
        let scoreState: PropertyDossierState = score.verdict == .go ? .verified
            : (score.verdict == .incomplete ? .setupNeeded : .attention)
        checks.append(.init(category: "Underwriting", state: scoreState,
                            headline: score.headline.isEmpty ? score.titleForDossier : score.headline,
                            detail: score.reason,
                            source: "Buyer inputs + transparent deal math", isBlocker: score.verdict == .pass || score.verdict == .incomplete))

        switch flood {
        case .available(let set) where !set.isEmpty:
            let risks = set.features.map(\.risk)
            let worst = worstFloodRisk(risks)
            let blocker = worst == .high || worst == .undetermined || worst == .unknown
            checks.append(.init(category: "Flood", state: worst == .minimal ? .verified : .attention,
                                headline: floodHeadline(worst),
                                detail: "\(set.features.count) FEMA zone feature\(set.features.count == 1 ? "" : "s") intersected the property-sized query. Confirm parcel boundaries and insurance requirements before closing.",
                                source: set.source, isBlocker: blocker))
        case .available:
            checks.append(.init(category: "Flood", state: .unavailable,
                                headline: "No FEMA zone returned — risk is not cleared",
                                detail: "NFHL may lack coverage or the public service may not have matched the geocoded point. Retry or verify through the official FEMA map.",
                                source: "FEMA National Flood Hazard Layer (NFHL)", isBlocker: true))
        case .setup(let note):
            checks.append(.init(category: "Flood", state: .setupNeeded, headline: "A complete address is required",
                                detail: note, source: "FEMA NFHL", isBlocker: true))
        case .unavailable(let note):
            checks.append(.init(category: "Flood", state: .unavailable, headline: "Flood status could not be verified",
                                detail: note, source: "FEMA NFHL", isBlocker: true))
        }

        switch title {
        case .available(let set) where set.ambiguousJoin:
            checks.append(.init(category: "Recorder", state: .attention,
                                headline: "Recorder join was ambiguous",
                                detail: TitleChainEngine.ambiguousJoinNote, source: set.source, isBlocker: true))
        case .available(let set) where !set.isEmpty:
            let n = set.encumbranceCount
            checks.append(.init(category: "Recorder", state: n > 0 ? .attention : .verified,
                                headline: n > 0
                                    ? "\(n) encumbering instrument\(n == 1 ? "" : "s") needs review"
                                    : "No classified encumbrance in \(set.events.count) returned record\(set.events.count == 1 ? "" : "s")",
                                detail: n > 0
                                    ? "Review mortgages, liens, judgments, foreclosures, and any later releases with a title professional."
                                    : "This is the recorder response, not a title-clearance opinion or title insurance commitment.",
                                source: set.source, isBlocker: n > 0))
        case .available(let set):
            checks.append(.init(category: "Recorder", state: .unavailable,
                                headline: "No recorder documents returned — title is not cleared",
                                detail: TitleChainEngine.noRecordsNote, source: set.source, isBlocker: true))
        case .setup(let note):
            checks.append(.init(category: "Recorder", state: .setupNeeded,
                                headline: "Parcel or recorder connection needed", detail: note,
                                source: "County recorder", isBlocker: true))
        case .unavailable(let note):
            checks.append(.init(category: "Recorder", state: .unavailable,
                                headline: "Recorded chain could not be verified", detail: note,
                                source: "County recorder", isBlocker: true))
        }

        switch market {
        case .available(let comparison):
            let current = comparison.current
            let values = [
                current.medianHomeValue.map { "median value \(REMath.money(Double($0)))" },
                current.medianGrossRent.map { "gross rent \(REMath.money(Double($0)))/mo" },
                current.medianHouseholdIncome.map { "income \(REMath.money(Double($0)))" },
                current.vacancyRate.map { String(format: "vacancy %.1f%%", $0 * 100) }
            ].compactMap { $0 }.joined(separator: " · ")
            checks.append(.init(category: "Market", state: .verified,
                                headline: current.areaName.isEmpty ? "Current tract context loaded" : current.areaName,
                                detail: values.isEmpty ? "The tract matched, but these ACS estimates were unavailable." : values,
                                source: "U.S. Census Bureau · \(current.vintage)\(comparison.baseline == nil ? "" : " vs \(comparison.baseline!.vintage)")",
                                isBlocker: false))
        case .setup(let note):
            checks.append(.init(category: "Market", state: .setupNeeded,
                                headline: "Add a Census API key for tract context", detail: note,
                                source: "U.S. Census Bureau ACS", isBlocker: false))
        case .unavailable(let note):
            checks.append(.init(category: "Market", state: .unavailable,
                                headline: "Market context could not be loaded", detail: note,
                                source: "U.S. Census Bureau ACS", isBlocker: false))
        }

        let decision: PropertyDossierDecision
        if score.verdict == .incomplete { decision = .needsInput }
        else if score.verdict == .pass { decision = .pass }
        else if checks.contains(where: \.isBlocker) || score.verdict == .caution { decision = .review }
        else { decision = .pursue }

        let summary = summaryText(decision: decision, deal: analyzed, score: score,
                                  checks: checks, fetchedAt: now)
        return PropertyDossier(decision: decision, analyzedDeal: analyzed, score: score,
                               checks: checks, fetchedAt: now, summary: summary)
    }

    private static func loadComps(deal: Deal, coordinate: (Double, Double)?) async -> DossierEvidence<CompsResult> {
        guard !deal.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .setup("Enter a complete property address.")
        }
        guard !deal.county.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .setup("Enter the county so the correct public-record source can be selected.")
        }
        guard let coordinate else { return .unavailable("The address could not be geocoded.") }
        let area = await ParcelLookup.areaValueAvg(county: deal.county, lat: coordinate.0, lng: coordinate.1)
        let location = zipAndState(from: deal.address)
        let parcel = deal.parcel.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = await CompsEngine.comps(county: deal.county, lat: coordinate.0, lng: coordinate.1,
                                             subjectSqft: deal.sqft > 0 ? deal.sqft : nil,
                                             zip: location.zip, state: location.state,
                                             parcelId: parcel.isEmpty ? nil : parcel,
                                             assessedAVM: area.avgValue)
        return .available(result)
    }

    private static func loadAssessor(deal: Deal) async -> DossierEvidence<ParcelRecord> {
        let county = deal.county.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !county.isEmpty else { return .setup("Enter the subject property's county.") }
        let parcel = deal.parcel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parcel.isEmpty else { return .setup("Resolve or enter the subject parcel ID.") }
        guard ParcelRegistry.source(for: county) != nil else {
            return .setup("No exact assessor connector is configured for \(county.capitalized) County yet.")
        }
        let record = await ParcelLookup.resolveParcel(parcelID: parcel, county: county)
        if record.available, !record.gated, record.parcel != nil { return .available(record) }
        return .unavailable(record.note.isEmpty ? "The assessor returned no single exact parcel identity." : record.note)
    }

    private static func loadMarket(address: String, session: URLSession) async -> DossierEvidence<CensusMarketComparison> {
        guard !address.isEmpty else { return .setup("Enter a complete property address.") }
        guard let key = CensusMarketConfig.apiKey else {
            return .setup("The free Census Data API key is stored locally in Keychain after you add it in Market Intelligence.")
        }
        do { return .available(try await CensusMarketIntelligence.loadComparison(address: address, apiKey: key, session: session)) }
        catch { return .unavailable(error.localizedDescription) }
    }

    private static func loadFlood(coordinate: (Double, Double)?, session: URLSession) async -> DossierEvidence<FloodFeatureSet> {
        guard let coordinate else { return .setup("The address must geocode before FEMA can be queried.") }
        let url = FloodOverlayEngine.pointQueryURL(lat: coordinate.0, lng: coordinate.1)
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return .unavailable("The FEMA service returned no successful HTTP response.")
            }
            return .available(FloodOverlayEngine.parse(data))
        } catch { return .unavailable(error.localizedDescription) }
    }

    private static func loadTitle(deal: Deal, session: URLSession) async -> DossierEvidence<TitleChainSet> {
        let parcel = deal.parcel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parcel.isEmpty else { return .setup("Resolve or enter the subject parcel ID before querying recorded documents.") }
        let state = zipAndState(from: deal.address).state ?? ""
        let builtIn = TitleRecorderRegistry.source(county: deal.county, state: state)
        let url: URL?
        let source: String
        if let builtIn {
            url = builtIn.queryURL(parcelId: parcel); source = builtIn.sourceLabel
        } else if !state.isEmpty, let endpoint = TitleChainConfig.endpoint(state: state) {
            url = TitleChainEngine.queryURL(endpoint: endpoint,
                                            parcelField: TitleChainConfig.parcelField(state: state),
                                            parcelId: parcel)
            source = "\(deal.county.capitalized) County recorder"
        } else {
            return .setup(TitleChainEngine.unqueryableNote)
        }
        guard let url else { return .setup(TitleChainEngine.unqueryableNote) }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        request.setValue("BlackLabelRealEstate/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return .unavailable("The county recorder returned no successful HTTP response.")
            }
            let formatter = DateFormatter(); formatter.dateFormat = "MMM d, yyyy"
            let stamp = formatter.string(from: Date())
            return .available(builtIn?.parse(data, county: deal.county, fetchedDate: stamp)
                ?? TitleChainEngine.parse(data, county: deal.county, source: source, fetchedDate: stamp))
        } catch { return .unavailable(error.localizedDescription) }
    }

    static func zipAndState(from address: String) -> (zip: String?, state: String?) {
        let tokens = address.uppercased().components(separatedBy: CharacterSet(charactersIn: " ,\n\t-"))
        let zip = tokens.last { $0.count == 5 && $0.allSatisfy(\.isNumber) }
        let state = tokens.reversed().first { $0.count == 2 && NationalPropertyCoverage.requiredStateCodes.contains($0) }
        return (zip, state)
    }

    private static func worstFloodRisk(_ risks: [FloodRisk]) -> FloodRisk {
        let order: [FloodRisk] = [.high, .undetermined, .unknown, .moderate, .minimal]
        return order.first { risks.contains($0) } ?? .unknown
    }

    private static func floodHeadline(_ risk: FloodRisk) -> String {
        switch risk {
        case .high: return "FEMA Special Flood Hazard Area intersects the property"
        case .moderate: return "FEMA moderate flood hazard intersects the property"
        case .minimal: return "FEMA returned a minimal-hazard zone"
        case .undetermined: return "FEMA flood hazard is undetermined"
        case .unknown: return "FEMA returned an unclassified flood zone"
        }
    }

    private static func summaryText(decision: PropertyDossierDecision, deal: Deal, score: DealScore,
                                    checks: [PropertyDossierCheck], fetchedAt: Date) -> String {
        var lines = [
            "PROPERTY VERIFICATION DOSSIER",
            deal.address.isEmpty ? "Address: not entered" : "Address: \(deal.address)",
            "Decision: \(decision.rawValue)",
            score.headline.isEmpty ? "Underwriting: \(score.verdict.label)" : "Underwriting: \(score.headline)",
            "Generated: \(fetchedAt.formatted(date: .abbreviated, time: .shortened))",
            ""
        ]
        let blockers = checks.filter(\.isBlocker)
        lines.append("BLOCKERS / REQUIRED REVIEW")
        lines.append(contentsOf: blockers.isEmpty ? ["None returned by the connected checks."] : blockers.map { "- \($0.category): \($0.headline)" })
        lines += ["", "EVIDENCE"]
        for check in checks {
            lines += ["[\(check.state.label)] \(check.category) — \(check.headline)",
                      check.detail, "Source: \(check.source)", ""]
        }
        lines.append("This packet reports only returned source data and buyer-entered assumptions; unavailable checks remain unresolved.")
        return lines.joined(separator: "\n")
    }
}

private extension DealScore {
    var titleForDossier: String { "\(verdict.label) · \(reason)" }
}

struct PropertyDossierPanel: View {
    @Binding var deal: Deal
    let maoPct: Double
    @State private var dossier: PropertyDossier?
    @State private var loading = false
    @State private var note = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                IconBadge(system: "doc.text.magnifyingglass", size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("PROPERTY VERIFICATION DOSSIER").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.gold).tracking(0.8)
                    Text("One run · exact assessor identity, valuation, FEMA, recorder, and Census").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                GoldButton(label: loading ? "Verifying…" : (dossier == nil ? "Verify property" : "Run again"),
                           icon: "checkmark.shield.fill") { run() }
                    .disabled(loading || deal.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if loading {
                ProgressView("Querying public sources and rebuilding the decision…")
                    .font(BLFont.body(10.5, .medium)).tint(BLTheme.gold)
            }
            if !note.isEmpty {
                Text(note).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let dossier {
                HStack(spacing: 9) {
                    StatusPill(text: dossier.decision.rawValue,
                               tint: dossier.decision == .pursue ? BLTheme.green : (dossier.decision == .pass ? .red : BLTheme.gold))
                    Text("\(dossier.verifiedCount)/\(dossier.checks.count) checks verified")
                        .font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub)
                    if !dossier.blockers.isEmpty {
                        Text("· \(dossier.blockers.count) required review")
                            .font(BLFont.mono(9.5, .bold)).foregroundColor(.orange)
                    }
                    Spacer()
                    GhostButton(label: copied ? "Copied" : "Copy dossier", icon: "doc.on.doc") { copy(dossier.summary) }
                }
                VStack(spacing: 6) {
                    ForEach(dossier.checks) { check in checkRow(check) }
                }
            } else if let saved = deal.dossierSummary, !saved.isEmpty {
                DisclosureGroup("Last saved dossier · \(deal.dossierFetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "date unavailable")") {
                    Text(saved).font(BLFont.mono(9.5)).foregroundColor(BLTheme.sub).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                .font(BLFont.body(10.5, .semibold)).foregroundColor(BLTheme.sub)
            }
        }
        .padding(12).background(BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder private func checkRow(_ check: PropertyDossierCheck) -> some View {
        let tint: Color = check.state == .verified ? BLTheme.green
            : (check.state == .attention ? .orange : BLTheme.sub)
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: check.state.icon).font(BLFont.body(12, .bold)).foregroundColor(tint).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(check.category.uppercased()).font(BLFont.mono(8.5, .bold)).foregroundColor(tint)
                    if check.isBlocker { Text("REVIEW").font(BLFont.mono(7.5, .bold)).foregroundColor(.orange) }
                }
                Text(check.headline).font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.text)
                Text(check.detail).font(BLFont.body(9.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                Text("Source: \(check.source)").font(BLFont.mono(8)).foregroundColor(BLTheme.sub.opacity(0.75))
            }
            Spacer()
        }
        .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func run() {
        loading = true; copied = false; note = ""
        let input = deal
        Task {
            let result = await PropertyDossierEngine.run(deal: input, maoPct: maoPct)
            await MainActor.run {
                var updated = result.analyzedDeal
                updated.dossierSummary = result.summary
                updated.dossierFetchedAt = result.fetchedAt
                deal = updated
                dossier = result
                loading = false
                note = result.blockers.isEmpty
                    ? "Verification finished. Save the deal to retain this sourced packet."
                    : "Verification finished with \(result.blockers.count) item\(result.blockers.count == 1 ? "" : "s") requiring review. Save the deal to retain the packet."
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }
}
#endif // circuit-convert
