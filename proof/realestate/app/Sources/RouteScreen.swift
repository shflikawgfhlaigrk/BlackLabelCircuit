#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — ROUTE screen.
// Turns the buyer's REAL pipeline (deals with addresses, ARV → priority) plus probate leads
// into an optimized canvassing run: geocode (free OSM, honest misses), solve (free TSP/VRP),
// show measured total miles + per-vehicle splits + a real Google Maps link. No fabricated stops.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Route view-model (pure, UI-free) — the honesty rules the screen renders, unit-tested.
//
// Extracted so the Route screen's three load-bearing promises are asserted, not eyeballed:
//   1. The visit list is the OPTIMIZER'S OWN order (never re-sorted by the view).
//   2. A stop we couldn't geocode is listed HONESTLY by name and NEVER carries a fabricated
//      coordinate (an unroutable stop with a lat/lng would be an invented location — a hard fail).
//   3. Distance/time are labeled as STRAIGHT-LINE, ~30 mph planning ESTIMATES — never presented as
//      measured road miles or live drive time (the miles are great-circle haversine, not routed).
enum RoutePresenter {
    /// Deals become stops only when they carry a real address (ARV drives canvasser priority).
    /// A deal with a blank address is dropped — never turned into an invented stop.
    ///
    /// The deal's ALREADY-RESOLVED coordinate is carried through (same as `leadStops` below).
    /// Dropping it forced RoutePlanner to re-geocode every deal, and a deal address the public
    /// Nominatim index does not carry then failed the whole run: live 2026-08-03,
    /// `nominatim.openstreetmap.org/search?q=418 Magnolia Ridge Ln, Gainesville` → HTTP 200 `[]`.
    /// With Deals-only (the screen's default candidate set) that left zero routable stops AND no
    /// depot fallback, so the optimizer returned no routes and the screen rendered "Nothing
    /// routable" for a pipeline whose coordinates were sitting right there. This is a passthrough
    /// of a coordinate the record already holds — nothing is invented; a deal without one stays
    /// un-geocoded and is still surfaced honestly as unroutable.
    static func dealStops(_ deals: [Deal]) -> [RouteStop] {
        deals.filter { !$0.address.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { RouteStop(label: $0.address, address: $0.address,
                             lat: $0.lat, lng: $0.lng, priority: $0.arv) }
    }
    /// Leads become stops only with a real subject/situs address (or an address-bearing note).
    /// Priority = the lot/parcel value (canvasser visits value-first). No address ⇒ no stop.
    static func leadStops(_ leads: [Lead]) -> [RouteStop] {
        leads.compactMap { l in
            if let addr = l.routableAddress {
                let prio = Double(l.source == .teardown && l.landValue > 0 ? l.landValue : l.assessedValue)
                return RouteStop(label: l.name, address: addr, lat: l.lat, lng: l.lng, priority: prio)
            }
            let noteAddr = l.notes.split(separator: "·").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            guard noteAddr.range(of: #"\d"#, options: .regularExpression) != nil else { return nil }
            return RouteStop(label: l.name, address: noteAddr, lat: l.lat, lng: l.lng, priority: Double(l.assessedValue))
        }
    }
    static func candidateStops(deals: [Deal], leads: [Lead], includeDeals: Bool, includeLeads: Bool) -> [RouteStop] {
        (includeDeals ? dealStops(deals) : []) + (includeLeads ? leadStops(leads) : [])
    }

    /// The visit list across every vehicle, in the OPTIMIZER'S order — a straight passthrough of
    /// `RouteResult.labels`, never re-sorted. This is what the numbered stop rows render.
    static func orderedLabels(_ r: RouteResult) -> [String] {
        r.routes.flatMap { r.labels($0) }
    }

    /// The stops we could NOT locate — surfaced by name, exactly as the planner returned them.
    static func unlocated(_ r: RouteResult) -> [RouteStop] { r.unroutable }

    /// One honest "couldn't locate" line: the stop's name (+ the address we tried), never a coordinate.
    static func unlocatedLine(_ s: RouteStop) -> String {
        "\(s.label)\(s.address.isEmpty ? "" : " — \(s.address)")"
    }

    /// HARD HONESTY INVARIANT: every unlocated stop must be genuinely un-geocoded (no lat/lng).
    /// If any "couldn't locate" stop carries a coordinate, the view is claiming an invented location.
    static func unlocatedAreHonest(_ r: RouteResult) -> Bool { r.unroutable.allSatisfy { !$0.routable } }

    /// The straight-line / ~30 mph assumption, stated plainly so the numbers are never read as
    /// measured road distance or a live-traffic drive time.
    static let assumptionsNote =
        "Straight-line (as-the-crow-flies) distance at ~30 mph — a planning estimate, not measured road miles or live drive time."
    static let milesLabel = "Est. miles"        // great-circle, not routed road miles
    static let driveTimeLabel = "Est. drive time" // miles ÷ ~30 mph, not a measured/live ETA

    static func driveTime(_ minutes: Double) -> String {
        let h = Int(minutes) / 60, m = Int(minutes) % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}

struct RouteScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: SettingsStore
    @State private var depot = ""
    @State private var mode: RouteMode = .canvasser
    @State private var includeDeals = true
    @State private var includeLeads = false
    @State private var planning = false
    @State private var result: RouteResult?
    @State private var note = ""

    // Stops the user can actually route: deals that have an address (ARV drives canvasser priority),
    // and leads that carry an address-bearing note. Nothing fabricated. (RoutePresenter is the
    // unit-tested source of truth for this honesty; the view just reads it.)
    private var dealStops: [RouteStop] { RoutePresenter.dealStops(model.deals) }
    private var leadStops: [RouteStop] { RoutePresenter.leadStops(model.leads) }
    private var candidateStops: [RouteStop] {
        RoutePresenter.candidateStops(deals: model.deals, leads: model.leads, includeDeals: includeDeals, includeLeads: includeLeads)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Route", subtitle: "Optimize a canvassing run over your real pipeline — free TSP/VRP, estimated straight-line miles").blScreenPadding(28).padding(.bottom, 0)
            ScrollView { VStack(alignment: .leading, spacing: 16) {
                Panel(title: "Plan a run", icon: "map.fill", glow: true) {
                    Field(title: "Start / depot address", text: $depot, prompt: "Your office or depot address")
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("MODE").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
                            Picker("", selection: $mode) { ForEach(RouteMode.allCases) { Text($0.label).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Two switch+label pairs don't fit one phone row — the second label wrapped
                    // mid-phrase — so on compact each gets its own line.
                    AdaptiveStack(spacing: 16) {
                        Toggle(isOn: $includeDeals) { Text("Deals (\(dealStops.count))").font(BLFont.body(12.5, .semibold)) }.toggleStyle(.checkbox).tint(BLTheme.gold)
                        Toggle(isOn: $includeLeads) { Text("Addressed leads (\(leadStops.count))").font(BLFont.body(12.5, .semibold)) }.toggleStyle(.checkbox).tint(BLTheme.gold)
                        if !BLScale.isCompact { Spacer() }
                    }
                    HStack(spacing: 10) {
                        GoldButton(label: planning ? "Optimizing…" : "Optimize route", icon: planning ? "hourglass" : "wand.and.stars") { runPlan() }
                            .opacity(planning ? 0.6 : 1).disabled(planning || candidateStops.isEmpty || depot.trimmingCharacters(in: .whitespaces).isEmpty)
                        if candidateStops.isEmpty { Text("Add a deal with an address to route").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub) }
                        Spacer()
                    }
                    Text("Canvasser orders by ARV (highest-value doors first). Fleet splits the work across vehicles from your depot. Geocoding is free OpenStreetMap — an address we can't locate is flagged, never invented.")
                        .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    if planning {
                        HStack(spacing: 10) { ProgressView().controlSize(.small); Text("Geocoding \(candidateStops.count) stops + depot, then solving…").font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.sub) }.padding(.top, 4)
                    }
                }
                if let r = result { resultView(r) }
            }.blScreenPadding(28).padding(.top, 8) }
        }
        .onAppear {
            // Sample Mode has no saved depot, and the sample depot is a labeled synthetic address
            // ("… (Sample)"), so seed the field with it — visibly, and only when the field is
            // empty. It stays editable: type a real depot and the real geocoder handles it.
            if depot.isEmpty { depot = model.isDemo ? DemoData.routeDepotAddress : settings.data.depotAddress }
            mode = settings.data.routeMode
        }
    }

    private func runPlan() {
        planning = true; result = nil; note = ""
        let stops = candidateStops, start = depot, cfg = mode.config
        // persist the chosen depot + mode back into settings (real customization)
        settings.data.depotAddress = start; settings.data.routeMode = mode
        // In Sample Mode ONE address resolves offline — the labeled synthetic depot, which no
        // public index carries. Every other address (including a real depot the buyer types over
        // it) still goes to the real OSM geocoder, so the depot field is live in Sample Mode too.
        // The route itself is always the real optimizer over the real stops: no canned mileage.
        let geocode = model.isDemo
            ? DemoData.routeGeocoder { await OSMGeocoder.shared.geocode($0) }
            : { await OSMGeocoder.shared.geocode($0) }
        Task {
            let r = await RoutePlanner.plan(stops: stops, depot: start, config: cfg, geocode: geocode)
            await MainActor.run { result = r; planning = false }
        }
    }

    @ViewBuilder private func resultView(_ r: RouteResult) -> some View {
        Panel(title: "Optimized run", icon: "checkmark.seal.fill", glow: true) {
            if r.routes.isEmpty {
                EmptyState(icon: "mappin.slash", title: "Nothing routable",
                           hint: "None of the stops (or the depot) could be geocoded. Check the addresses include city + state.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: BLScale.cardMin(120, spacing: 10)), spacing: 10)], spacing: 10) {
                    metric(RoutePresenter.milesLabel, String(format: "%.1f", r.totalMiles), BLTheme.gold)
                    metric(RoutePresenter.driveTimeLabel, driveTime(r.totalMinutes), BLTheme.text)
                    metric("Stops", "\(r.stopCount)", BLTheme.green)
                    if r.routes.count > 1 { metric("Vehicles", "\(r.routes.count)", .blue) }
                }
                Text(RoutePresenter.assumptionsNote)
                    .font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(r.routes.enumerated()), id: \.offset) { i, route in
                    routeBlock(i: i, route: route, multi: r.routes.count > 1, labels: r.labels(route))
                }
                if !RoutePresenter.unlocated(r).isEmpty {
                    Divider().overlay(BLTheme.stroke)
                    Text("COULDN'T LOCATE (\(RoutePresenter.unlocated(r).count)) — not invented").font(BLFont.mono(9.5, .bold)).foregroundColor(BL.danger).tracking(0.5)
                    ForEach(RoutePresenter.unlocated(r)) { s in
                        Text("•  \(RoutePresenter.unlocatedLine(s))").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
                    }
                }
            }
        }
    }

    @ViewBuilder private func metric(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(BLFont.mono(22, .bold)).foregroundColor(tint)
            Text(label.uppercased()).font(BLFont.mono(9, .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private func routeBlock(i: Int, route: VehicleRoute, multi: Bool, labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if BLScale.isCompact {
                VStack(alignment: .leading, spacing: 8) {
                    if multi { FoilBadge(text: "Vehicle \(i + 1)", icon: "car.fill") }
                    Text(String(format: "%.1f mi · %@", route.miles, driveTime(route.minutes))).font(BLFont.mono(12, .semibold)).foregroundColor(BLTheme.text)
                    mapsAction(route)
                }
            } else {
                HStack {
                    if multi { FoilBadge(text: "Vehicle \(i + 1)", icon: "car.fill") }
                    Text(String(format: "%.1f mi · %@", route.miles, driveTime(route.minutes))).font(BLFont.mono(12, .semibold)).foregroundColor(BLTheme.text)
                    Spacer()
                    mapsAction(route)
                }
            }
            // ordered stop list (the optimized visit order)
            ForEach(Array(labels.enumerated()), id: \.offset) { idx, label in
                HStack(spacing: 10) {
                    Text("\(idx + 1)").font(BLFont.mono(11, .bold)).foregroundColor(BLTheme.ink)
                        .frame(width: 20, height: 20).background(BLTheme.goldGrad).clipShape(Circle())
                    Text(label).font(BLFont.body(12.5, .medium)).foregroundColor(BLTheme.text).lineLimit(1)
                    Spacer()
                }
            }
        }
        .padding(13).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func mapsAction(_ route: VehicleRoute) -> some View {
        GhostButton(label: "Open in Maps", icon: "arrow.up.right.square", tint: BLTheme.gold) {
            if let u = URL(string: route.mapsURL) { NSWorkspace.shared.open(u) }
        }
    }

    private func driveTime(_ minutes: Double) -> String { RoutePresenter.driveTime(minutes) }
}
#endif // circuit-convert
