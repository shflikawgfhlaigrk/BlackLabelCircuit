// Black Label Real Estate — RE-22 title / lien chain UI (app-only, not test-compiled).
//
// Shows the recorded document history (deeds, mortgages, liens, judgments, releases) for a lead's
// parcel. It pulls from the county recorder's PUBLIC ArcGIS/feature endpoint the buyer connects for
// that state (the same buyer-configured, local-custody posture as skip-trace), caches the result on
// the lead (cache-hit == zero network), cites the source + fetch date on every row, and shows an
// explicit HONEST empty when no endpoint is configured or the endpoint returns nothing — never a
// fabricated lien. The pure query/parse/cache logic lives in TitleChain.swift.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Buyer-configured county recorder endpoint (per state; local, never our index).
enum TitleChainConfig {
    static func endpointKey(state: String) -> String { "bl.realestate.recorder_endpoint.\(state.uppercased())" }
    static func parcelFieldKey(state: String) -> String { "bl.realestate.recorder_parcelfield.\(state.uppercased())" }

    static func endpoint(state: String) -> String? {
        UserDefaults.standard.string(forKey: endpointKey(state: state))?.trimmingCharacters(in: .whitespaces).nonEmpty
    }
    static func parcelField(state: String) -> String {
        UserDefaults.standard.string(forKey: parcelFieldKey(state: state))?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "PARCEL_ID"
    }
    static func setEndpoint(_ url: String, parcelField: String, state: String) {
        UserDefaults.standard.set(url, forKey: endpointKey(state: state))
        UserDefaults.standard.set(parcelField, forKey: parcelFieldKey(state: state))
    }
}

private extension String { var nonEmpty: String? { isEmpty ? nil : self } }

// MARK: - Title / lien-chain view-model (pure, UI-free) — the lien/mortgage WATERFALL the sheet
// renders, unit-tested so its honesty rules are pinned, not eyeballed.
//
// The load-bearing promises this presenter fixes:
//   1. The waterfall is exactly the engine's classified chain, newest-recorded-first, with EVERY row
//      carrying its source + fetch-date citation. A row's kind is never upgraded past what the recorder
//      recorded (an unknown instrument stays "Recorded document", never promoted to a lien).
//   2. A recorded AMOUNT is shown only when the record carried one — nil ⇒ omitted, never a guessed $0.
//   3. The note the sheet shows on open and after a pull is an honest state machine: a cache hit
//      renders instantly (zero network); no parcel / no endpoint / empty result each map to a pinned
//      honest note ("not publicly queryable — nothing was invented" / "no records — nothing invented"),
//      NEVER a fabricated lien.
enum TitleChainPresenter {
    /// One rendered waterfall row — only the fields the recorder actually returned.
    struct EventRow: Equatable {
        let title: String        // the classified kind's label (never upgraded past the recorded type)
        let recordedDate: String
        let docType: String      // the RAW recorded instrument type, shown verbatim
        let party: String
        let amount: String?      // "$1234" only when a real amount was recorded; nil ⇒ omitted
        let citation: String     // source + fetch date — present on EVERY row
        let isEncumbrance: Bool  // a lien/mortgage/judgment encumbers; a deed/release does NOT
    }

    static func row(_ e: TitleEvent) -> EventRow {
        EventRow(title: e.kind.label,
                 recordedDate: e.recordedDate,
                 docType: e.docType,
                 party: e.party,
                 amount: e.amount.map { "$\($0)" },
                 citation: e.citation,
                 isEncumbrance: e.kind.isEncumbrance)
    }

    /// The full waterfall the sheet renders — the engine's chronological (newest-first) chain, each row
    /// cited. An absent/empty chain yields no rows (the sheet then shows the honest note instead).
    static func rows(_ chain: TitleChainSet?) -> [EventRow] {
        guard let c = chain, !c.isEmpty else { return [] }
        return c.chronological.map(row)
    }

    /// Provenance line under the waterfall — only rendered when the chain actually returned rows.
    static func sourceLine(_ chain: TitleChainSet) -> String {
        TitleChainEngine.sourceLine(county: chain.county, count: chain.events.count, dateLabel: chain.fetchedDate)
    }

    // The state the sheet is in when it first opens (a pure mirror of loadCacheOrNote).
    enum Initial: Equatable {
        case cachedChain   // a cached chain matched THIS parcel → render it, zero network
        case needParcel    // the lead has no resolved parcel id yet
        case notQueryable  // no county recorder endpoint configured for this state
        case promptPull    // endpoint present → prompt the buyer to pull
    }

    static let needParcelNote = "This lead has no resolved parcel id yet — resolve the parcel first, then pull its recorded chain."
    static func promptPullNote(state: String) -> String { "Tap “Pull recorded chain” to query \(state)’s connected recorder for this parcel." }

    static func initialState(hasCachedMatch: Bool, parcelEmpty: Bool, endpointConfigured: Bool) -> Initial {
        if hasCachedMatch { return .cachedChain }
        if parcelEmpty { return .needParcel }
        if !endpointConfigured { return .notQueryable }
        return .promptPull
    }
    /// The note copy for a non-cached initial state ("" when a cached chain will render instead).
    static func initialNote(_ s: Initial, state: String) -> String {
        switch s {
        case .cachedChain: return ""
        case .needParcel: return needParcelNote
        case .notQueryable: return TitleChainEngine.unqueryableNote
        case .promptPull: return promptPullNote(state: state)
        }
    }

    // The outcome of a live pull — a real recorded chain, an honest empty (never a fabricated lien),
    // or an AMBIGUOUS join (round 16): the recorder answered with real deeds, but the county's parcel
    // id matched MORE THAN ONE parcel, so none of them can be attributed to this one.
    enum PullOutcome: Equatable { case chain, empty, ambiguous }
    /// A non-2xx response yields an empty parsed set upstream, so an empty parse (whatever its cause —
    /// error envelope, timeout, no rows) is the SAME honest empty; a fabricated lien can never appear.
    /// `.ambiguous` is checked FIRST: that set is also `isEmpty` (the gate drops the events), but it is
    /// NOT a "no records" state — the records exist and belong to other parcels, and saying otherwise
    /// would misreport the county's data.
    static func pullOutcome(parsed: TitleChainSet) -> PullOutcome {
        if parsed.ambiguousJoin { return .ambiguous }
        return parsed.isEmpty ? .empty : .chain
    }
    static func rendersChain(_ o: PullOutcome) -> Bool { o == .chain }
    static func pullNote(_ o: PullOutcome) -> String {
        switch o {
        case .chain:     return ""
        case .empty:     return TitleChainEngine.noRecordsNote
        case .ambiguous: return TitleChainEngine.ambiguousJoinNote
        }
    }

    // MARK: - Encumbrance badge for the lead card (inline, ZERO network — reads the lead's cached chain).
    //
    // Surfaces "how encumbered is this title" at a glance on the lead card, without a pull. HONEST
    // three-state (§5.1 — nothing invented):
    //   • .count(n)  — a chain WAS pulled and carried n real encumbrances (mortgage/lien/judgment/
    //                  foreclosure). A count is shown ONLY here; it is the engine's classified count,
    //                  never derived or guessed.
    //   • .none      — a chain was pulled and encumbered NOTHING. This is a truthful "none recorded",
    //                  NOT a claim of clear title — a deed/release row is not upgraded into a lien.
    //   • .notPulled — no cached chain for THIS parcel (never queried, or the parcel changed). We say
    //                  so plainly; we do not imply the title is clear when we haven't checked.
    enum Encumbrance: Equatable { case count(Int), none, notPulled }

    /// The badge state from a parcel-matched cached chain (pass the result of TitleChainEngine.cached,
    /// so a changed parcel correctly reads as .notPulled rather than a stale count).
    static func encumbrance(cached: TitleChainSet?) -> Encumbrance {
        guard let c = cached else { return .notPulled }
        let n = c.encumbranceCount
        return n > 0 ? .count(n) : .none
    }
    static func encumbranceBadge(cached: TitleChainSet?) -> String {
        switch encumbrance(cached: cached) {
        case .count(let n): return "\(n) recorded encumbrance\(n == 1 ? "" : "s")"
        case .none:         return "No recorded encumbrances"
        case .notPulled:    return "Title chain not pulled"
        }
    }
    /// True ONLY for the state that warns the investor — a real, pulled, non-zero encumbrance count.
    /// The two honest-empty states are never a warning (nothing was invented to warn about).
    static func encumbranceIsWarning(cached: TitleChainSet?) -> Bool {
        if case .count = encumbrance(cached: cached) { return true }
        return false
    }

    // MARK: - Compact card-face encumbrance chip (Kanban card, ZERO network — reads the cached chain).
    //
    // The Kanban board shows many leads at a glance; this is the tiny version of the detail badge so an
    // investor can see "which of these deals carry recorded encumbrances" without opening each one. It
    // reads the SAME parcel-matched cached chain (no pull, no network on render) and obeys the identical
    // §5.1 honesty contract — a positive count ONLY when a chain was actually pulled AND actually
    // encumbered something; a truthful "0" for a pulled-clean chain; and an honest em-dash for a lead
    // whose chain was never pulled (never a fabricated lien count, never an implied "clear title").
    /// The compact chip text: "<n> enc." for a real pulled count, "0 enc." for a pulled-clean chain,
    /// and "—" when no chain is cached for this parcel. (The NO-FABRICATED-LIEN card-face guard pins
    /// that the two non-count states never surface a positive number.)
    static func cardFaceBadge(cached: TitleChainSet?) -> String {
        switch encumbrance(cached: cached) {
        case .count(let n): return "\(n) enc."
        case .none:         return "0 enc."
        case .notPulled:    return "—"
        }
    }
    /// True ONLY for a real, pulled, non-zero encumbrance count — the chip the card should tint as a
    /// warning. Both honest-empty states ("0 enc." / "—") are never a warning (nothing to warn about).
    static func cardFaceIsWarning(cached: TitleChainSet?) -> Bool { encumbranceIsWarning(cached: cached) }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct TitleChainSheet: View {
    @EnvironmentObject var model: AppModel
    let lead: Lead
    @State private var chain: TitleChainSet? = nil
    @State private var note: String = ""
    @State private var loading = false
    @State private var showConfig = false

    private var state: String { (lead.dbState ?? DatabaseLeadImport.stateToken(in: lead.county) ?? "").uppercased() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Title & lien chain").font(BLFont.display(24, .semibold)).foregroundColor(BLTheme.text)
                Text("Recorded deeds, mortgages, liens, judgments and releases for parcel \(lead.parcel.isEmpty ? "—" : lead.parcel).")
                    .font(BLFont.body(12)).foregroundColor(BLTheme.text.opacity(0.6))

                if let chain, !chain.isEmpty {
                    ForEach(chain.chronological) { e in eventRow(TitleChainPresenter.row(e)) }
                    Text(TitleChainPresenter.sourceLine(chain))
                        .font(BLFont.mono(10)).foregroundColor(BLTheme.text.opacity(0.55))
                } else if !note.isEmpty {
                    Text(note).font(BLFont.body(12)).foregroundColor(BLTheme.text.opacity(0.6))
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(BLTheme.bg2).cornerRadius(10)
                }

                HStack(spacing: 10) {
                    Button(loading ? "Pulling…" : "Pull recorded chain") { Task { await pull(force: true) } }
                        .disabled(loading || lead.parcel.isEmpty)
                        .font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
                    Button("Connect county recorder") { showConfig = true }
                        .font(BLFont.body(13)).foregroundColor(BLTheme.text.opacity(0.7))
                }
            }
            .blScreenPadding(24)
        }
        .sheetFrame(560, 640)
        .onAppear { loadCacheOrNote() }
        .sheet(isPresented: $showConfig) { RecorderConfigSheet(state: state).sheetCloseBar() }
    }

    @ViewBuilder private func eventRow(_ e: TitleChainPresenter.EventRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(e.title).font(BLFont.body(13, .semibold))
                    .foregroundColor(e.isEncumbrance ? BLTheme.text : BLTheme.text.opacity(0.75))
                Spacer()
                Text(e.recordedDate).font(BLFont.mono(11)).foregroundColor(BLTheme.text.opacity(0.6))
            }
            if !e.docType.isEmpty { Text(e.docType).font(BLFont.body(11)).foregroundColor(BLTheme.text.opacity(0.6)) }
            if !e.party.isEmpty { Text(e.party).font(BLFont.body(11)).foregroundColor(BLTheme.text.opacity(0.55)) }
            if let a = e.amount { Text(a).font(BLFont.mono(11)).foregroundColor(BLTheme.text.opacity(0.7)) }
            Text(e.citation).font(BLFont.mono(9)).foregroundColor(BLTheme.text.opacity(0.45))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).cornerRadius(10)
    }

    /// Show the cached chain instantly (zero network) if it matches this parcel; else set the note.
    private func loadCacheOrNote() {
        let cached = TitleChainEngine.cached(lead.titleChainCache, parcel: lead.parcel, state: state)
        let hasEndpoint = TitleRecorderRegistry.source(county: lead.county, state: state) != nil
            || TitleChainConfig.endpoint(state: state) != nil
        let s = TitleChainPresenter.initialState(hasCachedMatch: cached != nil,
                                                 parcelEmpty: lead.parcel.isEmpty,
                                                 endpointConfigured: hasEndpoint)
        // A cache QUARANTINED by the round-16 ambiguous-join gate (see TitleChainEngine.cached) comes
        // back with its events dropped — render the honest gated note, never an empty "chain" card.
        if let c = cached, c.ambiguousJoin { chain = nil; note = TitleChainEngine.ambiguousJoinNote; return }
        if case .cachedChain = s { chain = cached; note = ""; return }
        note = TitleChainPresenter.initialNote(s, state: state)
    }

    /// Live-pull the chain from the county recorder, parse honestly, and cache on the lead. A built-in
    /// LIVE-VERIFIED recorder source for the lead's county is preferred; otherwise the buyer-configured
    /// endpoint is used. No source at all → the honest un-queryable note (never a fabricated chain).
    private func pull(force: Bool) async {
        let builtIn = TitleRecorderRegistry.source(county: lead.county, state: state)
        let url: URL?
        let sourceLabel: String
        if let src = builtIn {
            url = src.queryURL(parcelId: lead.parcel)
            sourceLabel = src.sourceLabel
        } else if let endpoint = TitleChainConfig.endpoint(state: state) {
            url = TitleChainEngine.queryURL(endpoint: endpoint,
                                            parcelField: TitleChainConfig.parcelField(state: state),
                                            parcelId: lead.parcel)
            sourceLabel = "\(state) county recorder"
        } else {
            await MainActor.run { note = TitleChainEngine.unqueryableNote }; return
        }
        guard let url else {
            await MainActor.run { note = TitleChainEngine.unqueryableNote }; return
        }
        await MainActor.run { loading = true; note = "Querying \(state) recorder…" }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        req.setValue("BlackLabelRealEstate/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        let df = DateFormatter(); df.dateFormat = "MMM d, yyyy"
        let stamp = df.string(from: Date())
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let ok = (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
            let set: TitleChainSet
            if ok, let src = builtIn {
                set = src.parse(data, county: lead.county, fetchedDate: stamp)
            } else if ok {
                set = TitleChainEngine.parse(data, county: lead.county, source: sourceLabel, fetchedDate: stamp)
            } else {
                set = TitleChainSet(county: lead.county, source: sourceLabel, fetchedDate: stamp)
            }
            let outcome = TitleChainPresenter.pullOutcome(parsed: set)
            await MainActor.run {
                loading = false
                if TitleChainPresenter.rendersChain(outcome) {
                    chain = set; note = ""
                    var l = lead
                    l.titleChainCache = TitleChainEngine.cacheEntry(set, parcel: lead.parcel, state: state)
                    model.upsert(l)
                } else {
                    chain = nil; note = TitleChainPresenter.pullNote(outcome)
                }
            }
        } catch {
            // Transport failure = the recorder was never queried. Rendering the no-records note here
            // read as a clean-title signal for a query that never happened.
            await MainActor.run { loading = false; chain = nil; note = TitleChainEngine.unreachableNote }
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Connect a county recorder endpoint (buyer-configured, local custody).
struct RecorderConfigSheet: View {
    let state: String
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var parcelField = "PARCEL_ID"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect \(state) recorder").font(BLFont.display(22, .semibold)).foregroundColor(BLTheme.text)
            Text("Paste the county's PUBLIC ArcGIS feature-layer URL for recorded documents (…/FeatureServer/0 or …/MapServer/0). Nothing is sent to Black Label — the query runs from this \(kThisDeviceWord) straight to the county.")
                .font(BLFont.body(12)).foregroundColor(BLTheme.text.opacity(0.6))
            TextField("https://gis.county.gov/…/FeatureServer/0", text: $endpoint)
                .textFieldStyle(.roundedBorder).font(BLFont.mono(11))
            TextField("Parcel field name (e.g. PARCEL_ID, APN)", text: $parcelField)
                .textFieldStyle(.roundedBorder).font(BLFont.mono(11))
            Button("Save endpoint") {
                TitleChainConfig.setEndpoint(endpoint.trimmingCharacters(in: .whitespaces),
                                             parcelField: parcelField.trimmingCharacters(in: .whitespaces),
                                             state: state)
                dismiss()
            }
            .disabled(endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
            .font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
        }
        .blScreenPadding(24).sheetFrame(520, 340)
        .onAppear {
            endpoint = TitleChainConfig.endpoint(state: state) ?? ""
            parcelField = TitleChainConfig.parcelField(state: state)
        }
    }
}
#endif // circuit-convert
