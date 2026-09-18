#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — Property Index.
//
// The buyer's window into OUR harvested PUBLIC-RECORDS index (the Cloudflare Worker over Postgres,
// queried via `RealEstateAPI`). It searches by PUBLIC params only (state/county/city/zip/owner/
// address) and renders real parcels with honest, labeled empty states for every sparse field.
//
// HONESTY (CHARTER §5.1):
//   • The headline + metrics are LIVE TRUTH from /v1/stats + /v1/coverage — never a baked-in claim.
//     The old screen gated a "Sellable National" pill on impossible thresholds (100M rows / all 51
//     states) read from a local CSV table; that gate is gone. The pill now states what the index
//     actually holds today, straight from /v1/stats + /v1/coverage — never a hardcoded count.
//   • Every monetary / geo / date field on a record is Optional. A missing value renders as a
//     labeled empty state (e.g. "Assessed value not recorded") — never a guess, never a $0 stand-in.
//   • last_sale_price is sparse in the data, so a result set is labeled an "assessed-value index",
//     never "sold comps". lat/lng absence is shown as a ZIP/city "area" read, never a fake radius.
//   • LOCAL-FIRST: only public query params leave the device. No CRM lead / PII is ever sent.
//
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

private enum PropertyIndexTab: String, CaseIterable, Identifiable {
    case search = "Search", coverage = "Coverage"
    var id: String { rawValue }
}

struct PropertyIndexScreen: View {
    @EnvironmentObject var model: AppModel
    var go: ((Section) -> Void)? = nil

    @State private var tab: PropertyIndexTab = .search

    // Search params (public only — these are the sole things sent to /v1).
    @State private var query = ""
    @State private var state = ""
    @State private var county = ""
    @State private var city = ""
    @State private var zip = ""
    @State private var owner = ""

    // Live results + paging.
    @State private var page = PropertyPage.empty
    @State private var pageIndex = 1
    private let perPage = 25
    @State private var searched = false
    @State private var loading = false
    @State private var error = ""

    // Live overview (drives the honest headline + metric cards).
    @State private var stats: StatsResult?
    @State private var coverage: CoverageResult?
    @State private var overviewLoading = false
    @State private var overviewError = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    metrics
                    Picker("", selection: $tab) {
                        ForEach(PropertyIndexTab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 2)

                    switch tab {
                    case .search:
                        searchPanel
                        messages
                        resultsPanel
                    case .coverage:
                        CoverageScreen()
                    }
                }
                .padding(.horizontal, BLScale.gutter(28))
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            loadOverview()
        }
    }

    // MARK: Header

    private var header: some View {
        HeaderRow(title: "Property Index", subtitle: overviewSubtitle) {
            overviewPill
        }
        .blScreenPadding(28)
        .padding(.bottom, 4)
    }

    private var overviewSubtitle: String {
        if overviewLoading { return "Reading the live public-records index…" }
        if let total = stats?.total_properties, total > 0 {
            return "Live public-records index — \(PIIndexFormat.compact(total)) parcels across \(statesCovered) states. Public fields only; no skip-trace stored."
        }
        if !overviewError.isEmpty {
            return "The live index is unreachable — check your connection, then try again. If you use an access key, check it in Settings → Lead Database."
        }
        return "Our growing multi-state public-records index — search real parcels by state, county, city, ZIP, or owner."
    }

    @ViewBuilder private var overviewPill: some View {
        if overviewLoading {
            StatusPill(text: "Checking index", tint: BLTheme.gold)
        } else if let total = stats?.total_properties, total > 0 {
            StatusPill(text: "\(statesCovered) states · \(PIIndexFormat.compact(total)) records", tint: BLTheme.green)
        } else if !overviewError.isEmpty {
            StatusPill(text: "Live index offline", tint: BL.danger)
        } else {
            StatusPill(text: "No records", tint: BLTheme.gold)
        }
    }

    /// State count from live coverage first, then stats — never an assumed 50.
    private var statesCovered: Int {
        coverage?.states_covered ?? coverage?.coverage.count ?? stats?.states ?? 0
    }

    // MARK: Live metric cards (real truth from /v1/stats + /v1/coverage)

    private var metrics: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: BLScale.cardMin(180, spacing: 12)), spacing: 12)], spacing: 12) {
            MetricCard(label: "Indexed parcels",
                       value: stats?.total_properties.map { PIIndexFormat.full($0) } ?? "—",
                       icon: "building.2.fill", accent: BLTheme.gold, hero: true)
            MetricCard(label: "States covered",
                       value: statesCovered > 0 ? "\(statesCovered)" : "—",
                       icon: "map.fill", accent: .blue)
            MetricCard(label: "Counties covered",
                       // 0 here means the stats cache hasn't aggregated counties — that is
                       // "unavailable", not a claim of zero coverage. Show an honest dash.
                       value: (stats?.counties).flatMap { $0 > 0 ? PIIndexFormat.full($0) : nil } ?? "—",
                       icon: "mappin.and.ellipse", accent: .teal)
            MetricCard(label: "Suppressed (opt-out)",
                       value: stats?.suppressed.map { PIIndexFormat.full($0) } ?? "0",
                       icon: "nosign", accent: .orange)
        }
    }

    // MARK: Search

    private var searchPanel: some View {
        Panel(title: "Search the public-records index", icon: "magnifyingglass", glow: true) {
            Field(title: "Address, city or owner (free text)", text: $query, prompt: "Street, city, parcel, owner")
            HStack(spacing: 10) {
                Field(title: "State", text: $state, prompt: "State code")
                Field(title: "County", text: $county, prompt: "County name")
                Field(title: "City", text: $city, prompt: "City name")
                Field(title: "ZIP", text: $zip, prompt: "ZIP code")
            }
            Field(title: "Owner name", text: $owner, prompt: "Owner from public record")
            HStack(spacing: 10) {
                GoldButton(label: loading ? "Searching" : "Search", icon: "magnifyingglass") { startSearch() }
                    .disabled(loading)
                GhostButton(label: "Map filters", icon: "mappin.and.ellipse", tint: BLTheme.gold) { openMapForCurrentFilters() }
                GhostButton(label: "Clear", icon: "xmark.circle", tint: BLTheme.sub) { clearSearch() }
                Spacer()
                if page.masked == true {
                    StatusPill(text: "Preview tier — add a key in Settings", tint: BLTheme.gold)
                } else if let label = pageTierLabel {
                    StatusPill(text: label, tint: .blue)
                }
            }
            Text("Only public query params leave your device. Your own leads, deals, and contacts stay local.")
                .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub.opacity(0.85))
        }
    }

    @ViewBuilder private var messages: some View {
        if !error.isEmpty {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(BLFont.body(11.5, .semibold)).foregroundColor(BL.danger).padding(.horizontal, 4)
        }
    }

    @ViewBuilder private var resultsPanel: some View {
        if !searched {
            Panel(title: "Results", icon: "list.bullet.rectangle") {
                EmptyState(icon: "building.columns",
                           title: "Search the live index",
                           hint: "Enter a state, county, city, ZIP, or owner. Results come straight from our harvested public records — never fabricated.")
                    .padding(.vertical, 10)
            }
        } else if !error.isEmpty {
            // UNREACHABLE — the worker/API failed to return a valid answer (offline, timeout, HTTP
            // error, or an unparseable body). This branch is checked BEFORE the no-match branch (a
            // failed load also has zero results) so an outage can NEVER masquerade as "0 parcels
            // found" (RE-1). Distinct title + icon + the real reason (in the banner above) + Retry.
            Panel(title: "Results", icon: "exclamationmark.icloud.fill") {
                VStack(spacing: 12) {
                    EmptyState(icon: "wifi.exclamationmark",
                               title: "Can't reach the live index",
                               hint: "The public-records index didn't return a result, so there is nothing to show. This is a connection problem — not an empty search — and nothing was fabricated to fill the gap.")
                    GhostButton(label: loading ? "Retrying…" : "Retry search", icon: "arrow.clockwise", tint: BLTheme.gold) { runSearch() }
                        .disabled(loading)
                }
                .padding(.vertical, 10)
            }
        } else if page.results.isEmpty {
            // GENUINE NO-MATCH — the index answered successfully, with zero rows for these filters.
            Panel(title: "Results", icon: "list.bullet.rectangle") {
                EmptyState(icon: "magnifyingglass",
                           title: "No matching parcels",
                           hint: "The index answered, but no public records matched those filters. Widen the state / county / ZIP, or open Coverage to see which states are indexed.")
                    .padding(.vertical, 10)
            }
        } else {
            Panel(title: "Results", icon: "list.bullet.rectangle", glow: true) {
                resultsHeader
                DatabaseRecordSaveList(records: page.results,
                                       origin: .propertyIndex,
                                       apiCategory: nil,
                                       criteriaSummary: searchSummary)
                pager
            }
        }
    }

    /// Human summary of the active search filters (provenance on saved leads).
    private var searchSummary: String {
        var bits: [String] = ["Property Index"]
        for v in [query, owner, city, county, state.uppercased(), zip] {
            let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { bits.append(t) }
        }
        return bits.joined(separator: " · ")
    }

    private var resultsHeader: some View {
        HStack(spacing: 8) {
            Text(resultsCountLabel).font(BLFont.body(12, .bold)).foregroundColor(BLTheme.text)
            Spacer()
            GhostButton(label: "Map results", icon: "mappin.and.ellipse", tint: BLTheme.gold) { openMapForCurrentFilters() }
            // Honest provenance: this is an assessed-value index, NOT sold comps.
            StatusPill(text: "Assessed-value index", tint: .teal)
        }
    }

    private var resultsCountLabel: String {
        let shown = page.results.count
        if let total = page.total, total > shown {
            return "\(shown) of \(PIIndexFormat.full(total)) parcels"
        }
        return "\(shown) parcel\(shown == 1 ? "" : "s")"
    }

    @ViewBuilder private var pager: some View {
        if (page.total ?? 0) > perPage {
            HStack(spacing: 10) {
                GhostButton(label: "Previous", icon: "chevron.left", tint: BLTheme.sub) {
                    if pageIndex > 1 { pageIndex -= 1; runSearch() }
                }.disabled(pageIndex <= 1 || loading)
                Text("Page \(pageIndex) of \(totalPages)")
                    .font(BLFont.mono(11.5, .semibold)).foregroundColor(BLTheme.sub)
                GhostButton(label: "Next", icon: "chevron.right", tint: BLTheme.sub) {
                    if pageIndex < totalPages { pageIndex += 1; runSearch() }
                }.disabled(pageIndex >= totalPages || loading)
                Spacer()
            }
            .padding(.top, 6)
        }
    }

    private var totalPages: Int {
        let total = page.total ?? page.results.count
        return max(1, Int(ceil(Double(total) / Double(perPage))))
    }

    // MARK: Actions

    private func startSearch() {
        pageIndex = 1
        runSearch()
    }

    private func runSearch() {
        loading = true
        error = ""
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize location inputs to the index's format so "Georgia"/"Bibb County" match instead
        // of silently returning zero (USStates; unrecognized values pass through as typed).
        let stTrim = state.trimmingCharacters(in: .whitespacesAndNewlines)
        let st = stTrim.isEmpty ? "" : USStates.queryState(from: stTrim)
        let co = USStates.normalizedCounty(county), ci = city, zp = zip, ow = owner, p = pageIndex
        Task {
            do {
                let result = try await RealEstateAPI.searchOrThrow(query: q.isEmpty ? nil : q,
                                                                   ownerName: ow.isEmpty ? nil : ow,
                                                                   city: ci.isEmpty ? nil : ci,
                                                                   zip: zp.isEmpty ? nil : zp,
                                                                   state: st.isEmpty ? nil : st,
                                                                   county: co.isEmpty ? nil : co,
                                                                   page: p, perPage: perPage)
                await MainActor.run {
                    loading = false
                    searched = true
                    page = result
                    error = ""
                }
            } catch {
                await MainActor.run {
                    loading = false
                    searched = true
                    page = .empty
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func clearSearch() {
        query = ""; state = ""; county = ""; city = ""; zip = ""; owner = ""
        page = .empty; searched = false; error = ""; pageIndex = 1
    }

    private func openMapForCurrentFilters() {
        model.pendingPropertyMapRequest = PropertyMapLaunchRequest(query: query,
                                                                   state: state,
                                                                   county: county,
                                                                   city: city,
                                                                   zip: zip)
        go?(.map)
    }

    private func loadOverview() {
        overviewLoading = true
        overviewError = ""
        Task {
            let statsResult = try? await RealEstateAPI.stats()
            let coverageResult = try? await RealEstateAPI.coverage()
            await MainActor.run {
                overviewLoading = false
                stats = statsResult
                coverage = coverageResult
                if statsResult == nil && coverageResult == nil {
                    overviewError = "unreachable"
                }
            }
        }
    }

    private var pageTierLabel: String? {
        guard let tier = page.tier, !tier.isEmpty else { return nil }
        return "\(tier.capitalized) tier"
    }
}

// MARK: - Selectable record list + save-to-My-Leads bar (shared by Property Index +
// the guided List Builder). Saving dedupes by state + parcel_id + owner_name and
// stamps full provenance; contact fields stay empty (public records carry none).

struct DatabaseRecordSaveList: View {
    @EnvironmentObject var model: AppModel
    let records: [PropertyRecord]
    let origin: DatabaseLeadOrigin
    let apiCategory: String?
    let criteriaSummary: String

    @State private var selected = Set<String>()
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                GhostButton(label: selected.count == records.count && !records.isEmpty ? "Deselect all" : "Select all",
                            icon: "checklist", tint: BLTheme.sub) {
                    selected = selected.count == records.count ? [] : Set(records.map(\.id))
                    note = ""
                }
                GoldButton(label: "Save \(selected.count) to My Leads", icon: "person.crop.circle.badge.plus") { save() }
                    .disabled(selected.isEmpty)
                if !note.isEmpty {
                    Label(note, systemImage: "checkmark.circle.fill")
                        .font(BLFont.body(12, .bold)).foregroundColor(BLTheme.green)
                }
                Spacer()
            }
            Text("Tap rows to select. Saved leads carry the public record + where it came from; phone/email stay empty until you skip-trace — never invented.")
                .font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub)
            LazyVStack(spacing: 9) {
                ForEach(records) { record in
                    Button {
                        if selected.contains(record.id) { selected.remove(record.id) } else { selected.insert(record.id) }
                        note = ""
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: selected.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                .font(.blSystem(size: 15, weight: .bold))
                                .foregroundColor(selected.contains(record.id) ? BLTheme.gold : BLTheme.sub.opacity(0.6))
                            PropertyRecordRow(record: record)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .onChangeCompat(of: records.map(\.id).joined(separator: "|")) { _ in
            // New page/result set → stale selection would silently save the wrong rows.
            selected = []
        }
    }

    private func save() {
        let chosen = records.filter { selected.contains($0.id) }
        let result = model.saveDatabaseRecords(chosen, origin: origin,
                                               apiCategory: apiCategory,
                                               criteriaSummary: criteriaSummary)
        note = result.added == 0
            ? "All \(result.duplicates) already in My Leads."
            : "Saved \(result.added)\(result.duplicates > 0 ? " · \(result.duplicates) already saved" : "")."
        selected = []
    }
}

// MARK: - One parcel row (honest, optional-aware) — shared with the guided List Builder.

struct PropertyRecordRow: View {
    let record: PropertyRecord

    var body: some View {
        HStack(spacing: 13) {
            IconBadge(system: "house.fill", size: 36, active: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(titleLine).font(BLFont.body(14, .bold)).foregroundColor(BLTheme.text).lineLimit(1)
                if !locationLine.isEmpty {
                    Text(locationLine).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let owner = record.owner_name, !owner.isEmpty {
                        Text(owner).font(BLFont.body(10.5, .semibold)).foregroundColor(BLTheme.gold).lineLimit(1)
                    }
                    if let parcel = record.parcel_id, !parcel.isEmpty {
                        Text(parcel).font(BLFont.mono(10, .medium)).foregroundColor(BLTheme.sub).lineLimit(1)
                    }
                }
                if absenteeFlag {
                    Text("Absentee — mailing address differs from situs")
                        .font(BLFont.body(9.5, .semibold)).foregroundColor(.orange)
                }
                if let sale = saleLine {
                    Text(sale).font(BLFont.body(9.5, .medium)).foregroundColor(BLTheme.sub.opacity(0.85))
                }
                Text(freshnessBadge)
                    .font(BLFont.body(9, .semibold))
                    .foregroundColor(freshnessColor)
                    .lineLimit(1)
            }
            Spacer()
            valueColumn
        }
        .padding(13)
        .background(BLTheme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private var titleLine: String {
        if let a = record.situs_address, !a.isEmpty { return a }
        if let p = record.parcel_id, !p.isEmpty { return "Parcel \(p)" }
        if let owner = record.owner_name, !owner.isEmpty { return "Owner record: \(owner)" }
        return "Property record (address not recorded)"
    }

    private var locationLine: String {
        var parts: [String] = []
        if let c = record.situs_city, !c.isEmpty { parts.append(c) }
        let st = record.situs_state ?? record.state
        if let st, !st.isEmpty { parts.append(st) }
        if let z = record.situs_zip, !z.isEmpty { parts.append(z) }
        var line = parts.joined(separator: ", ")
        if let county = record.county, !county.isEmpty {
            line += line.isEmpty ? "\(county) County" : " · \(county) County"
        }
        return line
    }

    private var absenteeFlag: Bool {
        guard let mail = record.mailing_address?.trimmingCharacters(in: .whitespacesAndNewlines), !mail.isEmpty,
              let situs = record.situs_address?.trimmingCharacters(in: .whitespacesAndNewlines), !situs.isEmpty
        else { return false }
        return mail.lowercased() != situs.lowercased()
    }

    /// Sold price is ~1.9% filled — only show it when truly present, and label it honestly.
    private var saleLine: String? {
        guard let price = record.last_sale_price, price > 0 else { return nil }
        if let date = record.last_sale_date, !date.isEmpty {
            return "Last recorded sale: \(REMath.money(Double(price))) · \(date)"
        }
        return "Last recorded sale: \(REMath.money(Double(price)))"
    }

    /// Data-freshness + confidence badge computed from the record's `harvested_at`
    /// timestamp. Older public-record harvests earn a lower confidence label so the
    /// buyer can trust recent parcels more than stale ones. A missing/unparseable
    /// harvested_at renders an honest em dash — we never fabricate a harvest date.
    private var freshnessBadge: String {
        guard let days = harvestAgeDays, days >= 0 else {
            return "Freshness — · confidence unrated (no harvest date on record)"
        }
        let conf: String
        switch days {
        case 0...30:   conf = "high"
        case 31...180: conf = "medium"
        default:       conf = "low"
        }
        let age = days == 0 ? "today" : (days == 1 ? "1 day ago" : "\(days) days ago")
        return "Harvested \(age) · \(conf) confidence"
    }

    private var freshnessColor: Color {
        guard let days = harvestAgeDays, days >= 0 else { return BLTheme.sub.opacity(0.7) }
        switch days {
        case 0...30:   return BLTheme.green
        case 31...180: return .orange
        default:       return BLTheme.sub
        }
    }

    /// Whole days between the record's harvested_at and now, or nil when the field
    /// is absent/unparseable (so the badge can show an honest em dash, not a guess).
    private var harvestAgeDays: Int? {
        guard let raw = record.harvested_at?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let harvested = PropertyRecordRow.parseHarvestDate(raw)
        else { return nil }
        return Calendar.current.dateComponents([.day], from: harvested, to: Date()).day
    }

    /// Tolerant parse of the harvested_at string across the shapes the Worker emits
    /// (ISO-8601 with/without fractional seconds, plain date). Returns nil on anything
    /// unrecognized so the caller shows an honest em dash rather than a fabricated date.
    private static func parseHarvestDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    @ViewBuilder private var valueColumn: some View {
        if let assessed = record.assessed_value, assessed > 0 {
            VStack(alignment: .trailing, spacing: 2) {
                Text(REMath.money(Double(assessed))).font(BLFont.body(13, .heavy)).foregroundColor(BLTheme.green)
                Text("Assessed").font(BLFont.body(8.5, .semibold)).foregroundColor(BLTheme.sub)
            }
        } else {
            Text("Assessed n/a").font(BLFont.body(10, .semibold)).foregroundColor(BLTheme.sub.opacity(0.7))
        }
    }
}

// MARK: - Number formatting (file-scoped to avoid cross-file symbol collisions)

enum PIIndexFormat {
    /// Compact magnitude for pills/headlines, e.g. "412", "26.0K", "3.4M". Illustrative
    /// format only — the live count is always read from /v1/stats, never hardcoded.
    static func compact(_ n: Int) -> String {
        let v = Double(n)
        switch n {
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 10_000...:    return String(format: "%.0fK", v / 1_000)
        case 1_000...:     return String(format: "%.1fK", v / 1_000)
        default:           return "\(n)"
        }
    }
    /// Grouped full count for metric cards, e.g. "48,120" (illustrative — the value shown is
    /// always the live /v1/stats total, never a baked-in number).
    static func full(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
#endif // circuit-convert
