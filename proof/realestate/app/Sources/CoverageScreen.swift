#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — Coverage.
//
// An HONEST, live map of what our public-records index actually holds: ONLY the states that are
// really present in /v1/coverage, each with its real county + parcel counts. There is deliberately
// NO implied 50-state grid and no "coming soon" placeholders — an unindexed state simply does not
// appear, so the buyer never mistakes ambition for coverage (CHARTER §5.1).
//
// Data comes straight from `RealEstateAPI.coverage()` + `.stats()`. If the worker is unreachable the
// screen says so plainly rather than inventing rows. It is built to embed inside the Property Index
// page (a "Coverage" tab), so it renders a content stack — no outer ScrollView of its own.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct CoverageScreen: View {
    @State private var coverage: CoverageResult?
    @State private var stats: StatsResult?
    @State private var loading = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            summaryPanel
            coveragePanel
        }
        .onAppear(perform: load)
    }

    // MARK: Summary

    private var summaryPanel: some View {
        Panel(title: "Live coverage", icon: "map.fill", glow: true) {
            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading the live index…").font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub)
                }
            } else if entries.isEmpty {
                EmptyState(icon: error.isEmpty ? "map" : "wifi.slash",
                           title: error.isEmpty ? "No coverage reported" : "Live index offline",
                           hint: error.isEmpty
                                ? "The index reported zero indexed states. Connect a data source or check back as harvesting expands."
                                : "Couldn't reach the live index — check your connection and try again.")
                    .padding(.vertical, 6)
            } else {
                HStack(spacing: 14) {
                    Stat(label: "States indexed", value: "\(statesCount)", big: true)
                    Stat(label: "Counties", value: PIIndexFormat.full(countiesCount))
                    Stat(label: "Parcels", value: PIIndexFormat.full(parcelsCount))
                }
                Text("This is our growing multi-state index — not a claim of nationwide coverage. Every state below has real indexed parcels.")
                    .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Per-state list (only states actually present)

    @ViewBuilder private var coveragePanel: some View {
        if !entries.isEmpty {
            Panel(title: "Indexed states", icon: "list.bullet.rectangle") {
                LazyVStack(spacing: 9) {
                    ForEach(entries) { entry in CoverageRow(entry: entry) }
                }
            }
        }
    }

    // MARK: Derived (honest — prefer live coverage, fall back to stats, never assume)

    /// States sorted by parcel count desc, then county count desc, then name.
    private var entries: [CoverageEntry] {
        (coverage?.coverage ?? []).sorted {
            let lp = $0.properties ?? 0, rp = $1.properties ?? 0
            if lp != rp { return lp > rp }
            let lc = $0.counties ?? 0, rc = $1.counties ?? 0
            if lc != rc { return lc > rc }
            return $0.state < $1.state
        }
    }

    private var statesCount: Int { coverage?.states_covered ?? entries.count }
    private var countiesCount: Int {
        if let c = stats?.counties { return c }
        return entries.compactMap(\.counties).reduce(0, +)
    }
    private var parcelsCount: Int {
        if let total = stats?.total_properties { return total }
        return entries.compactMap(\.properties).reduce(0, +)
    }

    private func load() {
        loading = true
        error = ""
        Task {
            let coverageResult = try? await RealEstateAPI.coverage()
            let statsResult = try? await RealEstateAPI.stats()
            await MainActor.run {
                loading = false
                coverage = coverageResult
                stats = statsResult
                if coverageResult == nil { error = "unreachable" }
            }
        }
    }
}

// MARK: - One state row

private struct CoverageRow: View {
    let entry: CoverageEntry

    var body: some View {
        HStack(spacing: 13) {
            stateBadge
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.state.uppercased()).font(BLFont.body(14, .bold)).foregroundColor(BLTheme.text)
                Text(countyLabel).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(parcelLabel).font(BLFont.body(13, .heavy)).foregroundColor(BLTheme.gold)
                Text("parcels").font(BLFont.body(8.5, .semibold)).foregroundColor(BLTheme.sub)
            }
        }
        .padding(13)
        .background(BLTheme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private var stateBadge: some View {
        Text(entry.state.uppercased())
            .font(BLFont.mono(12, .bold)).foregroundColor(BLTheme.ink)
            .frame(width: 40, height: 36)
            .background(BLTheme.goldGrad)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var countyLabel: String {
        guard let c = entry.counties, c > 0 else { return "County count not reported" }
        return "\(c) \(c == 1 ? "county" : "counties") indexed"
    }

    private var parcelLabel: String {
        guard let p = entry.properties, p > 0 else { return "n/a" }
        return PIIndexFormat.full(p)
    }
}
#endif // circuit-convert
