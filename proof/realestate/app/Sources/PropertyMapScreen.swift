#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — PROPERTY MAP.
// A real MapKit map of the buyer's local pipeline plus the live public-records
// index. CRM leads/deals may be geocoded through the same OSM path the route
// engine uses; public-record pins only render when the source already supplied
// lat/lng. Coordinates are never invented.
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
import Foundation
#if canImport(MapKit) && !CIRCUIT_WINDOWS_SIM
import MapKit
#endif
#if canImport(OSLog) && !CIRCUIT_WINDOWS_SIM
import OSLog
#else
import CircuitPortKit
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let propertyMapLogger = Logger(subsystem: "com.blacklabel.realestate", category: "PropertyMap")

enum MapPinKind: Hashable {
    case lead
    case deal
    case publicRecord
    case publicRecordSummary
}

// A single placed pin on the map.
struct MapPin: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
    let tint: Color
    let kind: MapPinKind
    let badge: String?
    /// The underlying public record for .publicRecord pins — powers "Save to My
    /// Leads" straight off the map. nil for CRM lead/deal pins.
    let record: PropertyRecord?
    /// RedevelopmentScore (0–100, from TeardownScout) for a public-record parcel, or nil when the
    /// assessor land/improvement split needed to score it isn't on the record. Drives the parcel's
    /// heat color; nil renders the honest neutral "not scorable" marker (never a fabricated score).
    let redevelopmentScore: Int?

    init(id: String, title: String, subtitle: String, coordinate: CLLocationCoordinate2D, tint: Color, kind: MapPinKind, badge: String? = nil, record: PropertyRecord? = nil, redevelopmentScore: Int? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.tint = tint
        self.kind = kind
        self.badge = badge
        self.record = record
        self.redevelopmentScore = redevelopmentScore
    }

    var isDeal: Bool { kind == .deal }
    var isLead: Bool { kind == .lead }
    var isPublicRecord: Bool { kind == .publicRecord }
    var isPublicRecordSummary: Bool { kind == .publicRecordSummary }
    var isPublicRecordLayer: Bool { isPublicRecord || isPublicRecordSummary }

    static func == (a: MapPin, b: MapPin) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

// MARK: - RedevelopmentScore heat shading (shared by the native + SwiftUI map layers + the legend)
//
// Public-record parcels are shaded by their RedevelopmentScore so a teardown-hunting buyer sees the
// hot dirt at a glance. A nil score (assessor split missing) is NOT colored as if it scored — it
// draws the neutral gray "not scorable" marker. Bands mirror TeardownScout.tier exactly.
extension MapPin {
    /// The four heat bands + the honest "not scorable" state. `nil` score → `.notScorable`.
    enum RedevelopmentHeat {
        case prime, strong, watch, marginal, notScorable

        static func band(_ score: Int?) -> RedevelopmentHeat {
            guard let s = score else { return .notScorable }
            switch s {
            case 80...: return .prime
            case 60..<80: return .strong
            case 40..<60: return .watch
            default: return .marginal
            }
        }
        /// SwiftUI Color for the SwiftUI Map fallback + pin buttons.
        var color: Color {
            switch self {
            case .prime: return .red
            case .strong: return .orange
            case .watch: return .yellow
            case .marginal: return .brown
            case .notScorable: return Color(white: 0.55)
            }
        }
        var legendLabel: String {
            switch self {
            case .prime: return "Prime (80+)"
            case .strong: return "Strong (60–79)"
            case .watch: return "Watch (40–59)"
            case .marginal: return "Marginal (<40)"
            case .notScorable: return "Not scorable — no assessor split"
            }
        }
    }

    var redevelopmentHeat: RedevelopmentHeat { RedevelopmentHeat.band(redevelopmentScore) }

    /// Heat tint for a scored public-record parcel; the honest neutral gray when not scorable.
    var redevelopmentTint: Color { redevelopmentHeat.color }
}

#if os(macOS)
private final class PropertyMapAnnotation: NSObject, MKAnnotation {
    let pin: MapPin
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(pin: MapPin) {
        self.pin = pin
        self.coordinate = pin.coordinate
        self.title = pin.title
        self.subtitle = pin.subtitle.isEmpty ? nil : pin.subtitle
    }
}

private struct NativePropertyMapView: NSViewRepresentable {
    let pins: [MapPin]
    var floodFeatures: [FloodFeature] = []   // RE-19 FEMA flood-zone polygons for the current view
    @Binding var region: MKCoordinateRegion
    @Binding var selected: MapPin?
    let onSelect: (MapPin) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(region: $region, selected: $selected, onSelect: onSelect)
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: .zero)
        map.delegate = context.coordinator
        map.pointOfInterestFilter = .excludingAll
        map.showsCompass = true
        map.showsScale = true
        map.setRegion(region, animated: false)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.region = $region
        context.coordinator.selected = $selected
        context.coordinator.onSelect = onSelect
        context.coordinator.pinsByID = Dictionary(uniqueKeysWithValues: pins.map { ($0.id, $0) })

        // RE-19: draw the real FEMA flood-zone polygons as overlays (colored by risk band). Diffed by
        // a cheap signature so we only rebuild overlays when the returned zones actually change.
        let floodSignature = floodFeatures.map { "\($0.zone)#\($0.renderableRings.count)" }.joined(separator: "|")
        if context.coordinator.lastFloodSignature != floodSignature {
            context.coordinator.lastFloodSignature = floodSignature
            let features = floodFeatures
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak map] in
                guard let map else { return }
                map.removeOverlays(map.overlays.filter { $0 is MKPolygon })
                coordinator.floodRiskByPolygon.removeAll()
                for f in features {
                    for ring in f.renderableRings {
                        let coords = ring.map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }
                        let poly = MKPolygon(coordinates: coords, count: coords.count)
                        poly.title = f.label
                        coordinator.floodRiskByPolygon[ObjectIdentifier(poly)] = f.risk
                        map.addOverlay(poly, level: .aboveRoads)
                    }
                }
            }
        }

        let incoming = Set(pins.map(\.id))
        let signature = pins.map(\.id).sorted().joined(separator: "|")
        if context.coordinator.lastAnnotationSignature != signature {
            context.coordinator.lastAnnotationSignature = signature
            context.coordinator.lastRenderSignature = signature
            let annotations = pins.map(PropertyMapAnnotation.init)
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak map] in
                guard coordinator.lastAnnotationSignature == signature, let map else { return }
                let existing = Set(map.annotations.compactMap { ($0 as? PropertyMapAnnotation)?.pin.id })
                if existing != incoming {
                    map.removeAnnotations(map.annotations)
                    map.addAnnotations(annotations)
                }
                Self.emitNativeRenderSmoke(map: map, visiblePinCount: pins.count, signature: signature, coordinator: coordinator)
                propertyMapLogger.notice("rendered map annotations visible=\(pins.count, privacy: .public) annotations=\(map.annotations.count, privacy: .public) center=\(region.center.latitude, privacy: .public),\(region.center.longitude, privacy: .public) span=\(region.span.latitudeDelta, privacy: .public),\(region.span.longitudeDelta, privacy: .public)")
            }
        } else if context.coordinator.lastRenderSignature != signature {
            context.coordinator.lastRenderSignature = signature
            propertyMapLogger.notice("rendered map annotations visible=\(pins.count, privacy: .public) annotations=\(map.annotations.count, privacy: .public) center=\(region.center.latitude, privacy: .public),\(region.center.longitude, privacy: .public) span=\(region.span.latitudeDelta, privacy: .public),\(region.span.longitudeDelta, privacy: .public)")
        }

        if !context.coordinator.regionApproximatelyMatches(map.region, region) {
            let targetRegion = region
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak map] in
                guard let map, !coordinator.regionApproximatelyMatches(map.region, targetRegion) else { return }
                coordinator.programmaticRegionChange = true
                map.setRegion(targetRegion, animated: false)
            }
        }

        if let selected {
            if !map.selectedAnnotations.contains(where: { ($0 as? PropertyMapAnnotation)?.pin.id == selected.id }) {
                DispatchQueue.main.async { [weak map] in
                    guard let map,
                          let annotation = map.annotations.compactMap({ $0 as? PropertyMapAnnotation }).first(where: { $0.pin.id == selected.id }),
                          !map.selectedAnnotations.contains(where: { ($0 as? PropertyMapAnnotation)?.pin.id == selected.id }) else { return }
                    map.selectAnnotation(annotation, animated: true)
                }
            }
        } else if !map.selectedAnnotations.isEmpty {
            DispatchQueue.main.async { [weak map] in
                guard let map, !map.selectedAnnotations.isEmpty else { return }
                map.deselectAnnotation(map.selectedAnnotations[0], animated: false)
            }
        }
    }

    private static func emitNativeRenderSmoke(map: MKMapView,
                                              visiblePinCount: Int,
                                              signature: String,
                                              coordinator: Coordinator) {
        let env = ProcessInfo.processInfo.environment
        guard env["BLRE_MAP_RENDER_SMOKE"] == "1",
              coordinator.lastNativeRenderSmokeSignature != signature else { return }
        coordinator.lastNativeRenderSmokeSignature = signature
        let mapSize = map.bounds.size
        let windowSize = map.window?.frame.size ?? .zero
        let annotationPins = map.annotations.compactMap { ($0 as? PropertyMapAnnotation)?.pin }
        let summaryAnnotations = annotationPins.filter(\.isPublicRecordSummary).count
        let parcelAnnotations = annotationPins.filter(\.isPublicRecord).count
        let line = "BLRE_MAP_RENDER|annotations=\(map.annotations.count)|pins=\(visiblePinCount)|summary_annotations=\(summaryAnnotations)|parcel_annotations=\(parcelAnnotations)|map=\(Int(mapSize.width))x\(Int(mapSize.height))|window=\(Int(windowSize.width))x\(Int(windowSize.height))"
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8) ?? Data())
        if env["BLRE_MAP_RENDER_SMOKE_QUIT"] == "1" &&
            (parcelAnnotations > 0 || env["BLRE_MAP_RENDER_SMOKE_ALLOW_SUMMARY_QUIT"] == "1") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var region: Binding<MKCoordinateRegion>
        var selected: Binding<MapPin?>
        var onSelect: (MapPin) -> Void
        var pinsByID: [String: MapPin] = [:]
        var programmaticRegionChange = false
        var lastAnnotationSignature = ""
        var lastRenderSignature = ""
        var lastNativeRenderSmokeSignature = ""
        var lastFloodSignature = ""
        var floodRiskByPolygon: [ObjectIdentifier: FloodRisk] = [:]  // RE-19: renderer color lookup

        init(region: Binding<MKCoordinateRegion>, selected: Binding<MapPin?>, onSelect: @escaping (MapPin) -> Void) {
            self.region = region
            self.selected = selected
            self.onSelect = onSelect
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if programmaticRegionChange {
                programmaticRegionChange = false
                return
            }
            region.wrappedValue = mapView.region
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? PropertyMapAnnotation else { return }
            let alreadySelected = selected.wrappedValue?.id == annotation.pin.id
            selected.wrappedValue = annotation.pin
            if !alreadySelected {
                onSelect(annotation.pin)
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard let annotation = view.annotation as? PropertyMapAnnotation,
                  selected.wrappedValue?.id == annotation.pin.id else { return }
            selected.wrappedValue = nil
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? PropertyMapAnnotation else { return nil }
            let reuseID = "PropertyMapMarker"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
            view.annotation = annotation
            view.canShowCallout = true
            view.displayPriority = annotation.pin.isPublicRecord ? .defaultHigh : .required
            view.markerTintColor = markerColor(for: annotation.pin)
            view.glyphText = glyph(for: annotation.pin)
            view.clusteringIdentifier = annotation.pin.isPublicRecord ? "public-record-parcels" : nil
            return view
        }

        // RE-19: color each FEMA flood polygon by its real risk band (kept in lock-step with
        // FloodRisk). SFHA polygons read strongest; a translucent fill lets the heat show through.
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let poly = overlay as? MKPolygon else { return MKOverlayRenderer(overlay: overlay) }
            let risk = floodRiskByPolygon[ObjectIdentifier(poly)] ?? .unknown
            let color = Self.floodNSColor(risk)
            let r = MKPolygonRenderer(polygon: poly)
            r.fillColor = color.withAlphaComponent(0.26)
            r.strokeColor = color.withAlphaComponent(0.85)
            r.lineWidth = 1.2
            return r
        }

        static func floodNSColor(_ risk: FloodRisk) -> NSColor {
            switch risk {
            case .high: return NSColor.systemBlue
            case .moderate: return NSColor.systemTeal
            case .minimal: return NSColor.systemGreen
            case .undetermined: return NSColor.systemGray
            case .unknown: return NSColor.systemIndigo
            }
        }

        func regionApproximatelyMatches(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Bool {
            abs(a.center.latitude - b.center.latitude) < 0.0001 &&
            abs(a.center.longitude - b.center.longitude) < 0.0001 &&
            abs(a.span.latitudeDelta - b.span.latitudeDelta) < 0.0001 &&
            abs(a.span.longitudeDelta - b.span.longitudeDelta) < 0.0001
        }

        private func markerColor(for pin: MapPin) -> NSColor {
            switch pin.kind {
            case .lead: return .systemOrange
            case .deal: return .systemGreen
            case .publicRecord: return Self.redevelopmentNSColor(pin.redevelopmentHeat)
            case .publicRecordSummary: return .systemBlue
            }
        }

        /// AppKit heat color for a public-record parcel graded by RedevelopmentScore. Kept in lock-step
        /// with MapPin.RedevelopmentHeat.color so the native map and the SwiftUI fallback shade alike.
        static func redevelopmentNSColor(_ heat: MapPin.RedevelopmentHeat) -> NSColor {
            switch heat {
            case .prime: return .systemRed
            case .strong: return .systemOrange
            case .watch: return .systemYellow
            case .marginal: return .systemBrown
            case .notScorable: return .systemGray
            }
        }

        private func glyph(for pin: MapPin) -> String {
            switch pin.kind {
            case .lead: return "L"
            case .deal: return "$"
            case .publicRecord: return "P"
            case .publicRecordSummary: return pin.badge ?? "#"
            }
        }
    }
}
#endif

struct PropertyMapScreen: View {
    @EnvironmentObject var model: AppModel
    var go: (Section) -> Void = { _ in }
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35),
        span: MKCoordinateSpan(latitudeDelta: 48, longitudeDelta: 60))
    @State private var crmPins: [MapPin] = []
    @State private var publicPins: [MapPin] = []
    @State private var unlocated: [String] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var recordLoading = false
    @State private var recordsLoaded = false
    @State private var recordError = ""
    @State private var recordCount = 0
    @State private var recordSource = "Production"
    @State private var representedRecordCount = 0
    @State private var showingRecordSummaries = false
    @State private var showLeads = true
    @State private var showDeals = true
    @State private var showPublicRecords = true
    @State private var recordQuery = ""
    @State private var recordState = ""
    @State private var recordCounty = ""
    @State private var recordCity = ""
    @State private var recordZip = ""
    // Guided-list passthrough (set by "Open in Map" from List Builder / Lot-Flip):
    // the same whitelisted server category the list counted, so pins == list records.
    @State private var recordCategory = ""
    @State private var recordMinValue: Int?
    @State private var recordMaxValue: Int?
    @State private var recordSoldAfter = ""
    @State private var recordSoldBefore = ""
    @State private var recordListLabel = ""
    @State private var recordListTotal: Int?      // the list's full DB count at launch
    @State private var showListContext = true     // the compact List-context drawer
    @State private var lastLoadedTier: String?    // tier the last /v1/map page answered with
    @State private var pinSaveNote = ""
    @State private var selected: MapPin?
    @State private var viewportReloadTask: Task<Void, Never>?
    @State private var needsViewportRefreshAfterLoad = false
    @State private var didInitialFit = false   // some load has framed the map (CRM fit or record fit)
    @State private var lastRecordReloadKey = ""
    // RE-19 FEMA flood-zone overlay (off by default; fetched live for the viewport on toggle-on).
    @State private var showFlood = false
    /// Phone-only: the record filter fields start collapsed so the map gets the screen.
    @State private var showFilters = false
    /// Phone-only: the map key starts hidden behind a button so pins stay visible.
    @State private var showLegend = false
    @State private var showFieldMode = false   // RE-20 Field Mode sheet
    @State private var floodFeatures: [FloodFeature] = []
    @State private var floodNote = ""
    @State private var floodLoading = false

    private let recordLimit = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            publicRecordControls

            ZStack(alignment: .topTrailing) {
                mapSurface
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))

                if filteredPins.isEmpty && !loading && !recordLoading {
                    mapEmptyOverlay
                }

                VStack(alignment: .trailing, spacing: 8) {
                    if loading || recordLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(loading ? "Locating your leads…" : "Loading properties…")
                                .font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.text)
                        }
                        .padding(8).background(.ultraThinMaterial).clipShape(Capsule())
                    }
                    legendOverlay
                }.padding(14)
            }
            // A fixed 430-pt map plus the desktop header and filter strip is taller than a 667-pt
            // phone; the overflowing VStack was centred, so the header vanished under the nav bar
            // and the status strip under the tab bar. On compact the map simply takes what's left.
            .frame(minHeight: BLScale.isCompact ? 200 : 430, maxHeight: BLScale.isCompact ? .infinity : nil)
            .padding(.horizontal, BLScale.gutter(28))

            if let s = selected { selectedCard(s).padding(.horizontal, BLScale.gutter(28)).padding(.top, 12) }
            statusStrip
        }
        .onAppear {
            model.lastMapBounds = Self.bounds(for: region)
            if !loaded { geocodeAll() }
            // DEV-ONLY smoke seed: BLRE_MAP_CATEGORY simulates "opened from a built list"
            // so the render smoke can prove a category-filtered map draws parcel pins
            // only (summary_annotations = 0). Never ships enabled.
            let env = ProcessInfo.processInfo.environment
            if model.pendingPropertyMapRequest == nil, !recordsLoaded,
               let cat = env["BLRE_MAP_CATEGORY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !cat.isEmpty {
                var criteria = DatabaseListCriteria()
                criteria.type = .custom
                criteria.categoryOverride = cat
                criteria.area.state = env["BLRE_SMOKE_STATE"] ?? "RI"
                model.pendingPropertyMapRequest = .forList(criteria)
            }
            consumePendingMapRequestIfNeeded()
            // The buyer's own pipeline wins the opening frame: when CRM pins exist the record
            // layer loads underneath without yanking the viewport; with no pipeline yet, the
            // record fit frames the live coverage as before.
            if !recordsLoaded { loadPublicRecords(fitResults: candidates.isEmpty, includeWholeCache: true) }
        }
        .onChangeCompat(of: model.leads.count) { _ in loaded = false; geocodeAll() }
        .onChangeCompat(of: model.deals.count) { _ in loaded = false; geocodeAll() }
        .onChangeCompat(of: model.pendingPropertyMapRequest) { request in
            if request != nil { consumePendingMapRequestIfNeeded() }
        }
        .onChangeCompat(of: showPublicRecords) { show in
            if show && !recordsLoaded { loadPublicRecords(fitResults: false) }
        }
        .onChangeCompat(of: showFlood) { show in
            if show { loadFloodZones() } else { floodNote = "" }
        }
        .sheet(isPresented: $showFieldMode) {
            FieldModeSheet(region: region).environmentObject(model).sheetCloseBar()
        }
        .onChangeCompat(of: viewportKey) { _ in
            // Publish the live viewport so the List Builder can offer "current map view"
            // as an area — then refetch records for the visible bounds.
            model.lastMapBounds = Self.bounds(for: region)
            scheduleVisibleRecordReload()
            if showFlood { loadFloodZones() }   // re-pull FEMA zones for the new viewport
        }
        .onDisappear {
            viewportReloadTask?.cancel()
        }
    }

    private var header: some View {
        HeaderRow(title: "Property Map", subtitle: "Local leads/deals plus live public-record pins — real coordinates only") {
            layerToggles
        }
        .padding(.horizontal, BLScale.gutter(28))
        // 44 pt clears the desktop window's title bar. A phone has a nav bar there already, so the
        // same inset pushed the header down INTO it and the subtitle ran under the back button.
        .padding(.top, BLScale.isCompact ? 0 : 44)
        .padding(.bottom, 8)
    }

    /// Three layer checkboxes. They overflow a phone row at full width, so compact scrolls them.
    @ViewBuilder private var layerToggles: some View {
        let row = HStack(spacing: BLScale.isCompact ? 12 : 14) {
            Toggle(isOn: $showLeads) { Text("Leads").font(BLFont.body(12, .semibold)) }.toggleStyle(.checkbox).tint(BLTheme.gold)
            Toggle(isOn: $showDeals) { Text("Deals").font(BLFont.body(12, .semibold)) }.toggleStyle(.checkbox).tint(BLTheme.gold)
            Toggle(isOn: $showPublicRecords) { Text("Public records").font(BLFont.body(12, .semibold)) }.toggleStyle(.checkbox).tint(BLTheme.gold)
        }.fixedSize()
        if BLScale.isCompact {
            ScrollView(.horizontal, showsIndicators: false) { row }
        } else {
            row
        }
    }

    private var publicRecordControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The desktop filter strip is 656 pt of fixed-width fields in one row — on a phone it
            // ran off both edges and the middle fields were unreachable. Compact folds the same
            // five filters into a two-up grid that fits the screen.
            if BLScale.isCompact {
                // Collapsed by default so the map — the reason you opened this screen — owns the
                // phone's screen instead of 250 pt of filter chrome.
                Button { withAnimation(.easeOut(duration: 0.18)) { showFilters.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showFilters ? "chevron.down" : "line.3.horizontal.decrease.circle")
                            .font(.blSystem(size: 11, weight: .bold))
                        Text(showFilters ? "Hide filters" : "Filters")
                            .font(.blSystem(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(BLTheme.gold)
                    .padding(.vertical, 6).padding(.horizontal, 11)
                    .background(BLTheme.gold.opacity(0.10)).clipShape(Capsule())
                    .overlay(Capsule().stroke(BLTheme.gold.opacity(0.32), lineWidth: 1))
                }.buttonStyle(.plain)
                if showFilters {
                    VStack(spacing: 8) {
                        HStack(alignment: .bottom, spacing: 10) {
                            compactField("State", text: $recordState, width: nil)
                            compactField("County", text: $recordCounty, width: nil)
                        }
                        HStack(alignment: .bottom, spacing: 10) {
                            compactField("City", text: $recordCity, width: nil)
                            compactField("ZIP", text: $recordZip, width: nil)
                        }
                        compactField("Search", text: $recordQuery, width: nil)
                    }
                }
            } else {
                HStack(alignment: .bottom, spacing: 10) {
                    compactField("State", text: $recordState, width: 58)
                    compactField("County", text: $recordCounty, width: 150)
                    compactField("City", text: $recordCity, width: 140)
                    compactField("ZIP", text: $recordZip, width: 78)
                    compactField("Search", text: $recordQuery, width: 190)
                    Spacer(minLength: 0)
                }
            }
            actionStrip
            listFilterChip
        }
        .padding(.horizontal, BLScale.gutter(28))
        .padding(.bottom, 14)
    }

    /// The map's action buttons. Five buttons plus a status pill never fit a phone row, so on
    /// compact the strip scrolls sideways instead of being clipped at both ends.
    @ViewBuilder private var actionStrip: some View {
        if BLScale.isCompact {
            ScrollView(.horizontal, showsIndicators: false) { actionRow }
        } else {
            actionRow
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
                compactMapAction(label: recordLoading ? "Loading" : "Load visible records",
                                 icon: "map.fill",
                                 tint: BLTheme.gold,
                                 filled: true) {
                    loadPublicRecords(fitResults: true, includeWholeCache: true)
                }
                .disabled(recordLoading)
                compactMapAction(label: "Show parcel pins",
                                 icon: "building.2.crop.circle",
                                 tint: .cyan) {
                    showParcelPins()
                }
                .disabled(recordLoading)
                // RE-19: overlay the live FEMA flood-zone polygons for the current view.
                compactMapAction(label: floodLoading ? "Loading FEMA…" : (showFlood ? "Flood zones: ON" : "Flood zones (FEMA)"),
                                 icon: showFlood ? "drop.fill" : "drop",
                                 tint: .blue,
                                 filled: showFlood) {
                    showFlood.toggle()
                }
                .disabled(floodLoading)
                // RE-20: Field Mode — download parcels for offline use, then stand-on-parcel lookup.
                compactMapAction(label: "Field Mode",
                                 icon: "figure.walk",
                                 tint: .green) {
                    showFieldMode = true
                }
                compactMapAction(label: "Clear",
                                 icon: "xmark.circle",
                                 tint: BLTheme.sub) {
                    recordQuery = ""; recordState = ""; recordCounty = ""; recordCity = ""; recordZip = ""
                    recordCategory = ""; recordMinValue = nil; recordMaxValue = nil
                    recordSoldAfter = ""; recordSoldBefore = ""; recordListLabel = ""
                    loadPublicRecords(fitResults: true, includeWholeCache: true)
                }
                Spacer(minLength: 10)
                StatusPill(text: publicStatusText, tint: recordError.isEmpty ? BLTheme.green : BL.danger)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
        }
    }

    // Active guided-list filter chip — the pins on screen are that list's records.
    @ViewBuilder private var listFilterChip: some View {
        Group {
            if hasListFilter {
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal.decrease.circle.fill").font(.blSystem(size: 11, weight: .bold)).foregroundColor(BLTheme.gold)
                    Text("List filter: \(recordListLabel.isEmpty ? recordCategory : recordListLabel)")
                        .font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.text).lineLimit(1)
                    Button { withAnimation { showListContext.toggle() } } label: {
                        Image(systemName: showListContext ? "chevron.up.circle" : "info.circle")
                            .font(.blSystem(size: 11)).foregroundColor(BLTheme.gold)
                    }.buttonStyle(.plain).help(showListContext ? "Hide list context" : "Show list context")
                    Button { clearListFilter() } label: {
                        Image(systemName: "xmark.circle.fill").font(.blSystem(size: 11)).foregroundColor(BLTheme.sub)
                    }.buttonStyle(.plain).help("Clear the list filter and browse all records")
                    Spacer()
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(BLTheme.gold.opacity(0.08)).clipShape(Capsule())
                .overlay(Capsule().stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
                if showListContext { listContextDrawer }
            }
        }
    }

    private var hasListFilter: Bool {
        !recordCategory.trimmedMapFilter.isEmpty || !recordListLabel.isEmpty
    }

    /// Compact List-context drawer: exactly what filter the pins on screen obey,
    /// the list's full database count, this tier's pin cap, and the way back.
    private var listContextDrawer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 14) {
                if !recordCategory.trimmedMapFilter.isEmpty {
                    contextItem("Category", DatabaseListCriteria.humanCategory(recordCategory))
                }
                let area = [recordCity, recordCounty, recordState.uppercased(), recordZip]
                    .map { $0.trimmedMapFilter }.filter { !$0.isEmpty }.joined(separator: ", ")
                contextItem("Area", area.isEmpty ? "Viewport" : area)
                if recordMinValue != nil || recordMaxValue != nil {
                    let band = [recordMinValue.map { "≥ $\(PropertyMapScreen.compactStaticCount($0))" },
                                recordMaxValue.map { "≤ $\(PropertyMapScreen.compactStaticCount($0))" }]
                        .compactMap { $0 }.joined(separator: " ")
                    contextItem("Assessed", band)
                }
                if !recordSoldAfter.trimmedMapFilter.isEmpty || !recordSoldBefore.trimmedMapFilter.isEmpty {
                    let dates = [recordSoldAfter.trimmedMapFilter.isEmpty ? nil : "after \(recordSoldAfter)",
                                 recordSoldBefore.trimmedMapFilter.isEmpty ? nil : "before \(recordSoldBefore)"]
                        .compactMap { $0 }.joined(separator: ", ")
                    contextItem("Sold", dates)
                }
                contextItem("Full count", recordListTotal.map { PropertyMapScreen.compactStaticCount($0) } ?? "—")
                contextItem("Pins shown", "\(publicParcelPinCount) (cap \(recordLimit)\(lastLoadedTier.map { " · \($0) tier" } ?? ""))")
                Spacer()
            }
            HStack(spacing: 10) {
                GhostButton(label: "Back to List Builder", icon: "square.stack.3d.up.fill", tint: BLTheme.gold) { go(.lists) }
                Text("Pins obey the list's exact criteria — the same records the count includes, capped per tier.")
                    .font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub)
                Spacer()
            }
        }
        .padding(10)
        .background(BLTheme.bg2.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder private func contextItem(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(BLFont.mono(8, .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            Text(value).font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.text).lineLimit(1)
        }
    }

    private func compactMapAction(label: String,
                                  icon: String,
                                  tint: Color,
                                  filled: Bool = false,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.blSystem(size: 11.5, weight: .bold))
                Text(label).lineLimit(1)
            }
            .font(.blSystem(size: 12.5, weight: .bold, design: .rounded))
            .foregroundColor(filled ? BLTheme.ink : tint)
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            .background(filled ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2), in: Capsule())
            .overlay(Capsule().stroke(filled ? BLTheme.goldHi.opacity(0.45) : tint.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: true)
    }

    /// `width: nil` = fill the available column, used by the phone's two-up filter grid; the
    /// desktop strip keeps its authored fixed widths.
    private func compactField(_ title: String, text: Binding<String>, width: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(BLFont.mono(8.5, .bold)).foregroundColor(BLTheme.sub).tracking(1.0)
            TextField(title, text: text)
                .font(BLFont.body(12, .semibold))
                .textFieldStyle(.plain)
                .foregroundColor(BLTheme.text)
                .padding(.vertical, 7).padding(.horizontal, 9)
                .background(BLTheme.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                .onSubmit { loadPublicRecords(fitResults: true) }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var publicStatusText: String {
        if recordLoading { return "Loading pins" }
        if !recordError.isEmpty { return "Map feed offline" }
        if showingRecordSummaries && recordsLoaded {
            let samples = publicParcelPinCount
            if samples > 0 {
                return "\(samples) parcel pins + \(recordCount) count markers covering \(compactCount(representedRecordCount)) records"
            }
            return "\(compactCount(representedRecordCount)) records across \(recordCount) map markers"
        }
        if recordsLoaded { return "\(recordCount) \(recordSource.lowercased()) pins" }
        return "Public pins ready"
    }

    private var allPins: [MapPin] { crmPins + publicPins }
    private var publicParcelPinCount: Int { publicPins.filter { $0.isPublicRecord }.count }
    private var publicSummaryMarkerCount: Int { publicPins.filter { $0.isPublicRecordSummary }.count }
    private var filteredPins: [MapPin] {
        allPins.filter { pin in
            (pin.isDeal && showDeals) ||
            (pin.isLead && showLeads) ||
            (pin.isPublicRecordLayer && showPublicRecords)
        }
    }
    private var viewportKey: String {
        // MapKit normalizes a macOS MKMapView region by small amounts after annotations render.
        // Use a coarse reload key so those internal adjustments do not refetch the same 500 pins
        // every few seconds; real pans/zooms still cross these buckets and reload.
        let centerLat = Int((region.center.latitude * 4).rounded())
        let centerLng = Int((region.center.longitude * 4).rounded())
        let spanLat = Int((region.span.latitudeDelta / 2).rounded())
        return "\(centerLat):\(centerLng):\(spanLat)"
    }
    private var recordReloadKey: String {
        [
            viewportKey,
            recordQuery.trimmedMapFilter,
            recordState.trimmedMapFilter.uppercased(),
            recordCounty.trimmedMapFilter.lowercased(),
            recordCity.trimmedMapFilter.lowercased(),
            recordZip.trimmedMapFilter,
            recordCategory.trimmedMapFilter,
            recordMinValue.map(String.init) ?? "",
            recordMaxValue.map(String.init) ?? "",
            recordSoldAfter.trimmedMapFilter,
            recordSoldBefore.trimmedMapFilter
        ].joined(separator: "|")
    }

    @ViewBuilder private var mapSurface: some View {
        #if os(macOS)
        NativePropertyMapView(pins: filteredPins, floodFeatures: showFlood ? floodFeatures : [], region: $region, selected: $selected, onSelect: { pin in
            select(pin)
        })
        #else
        if #available(macOS 14.0, iOS 17.0, *) {
            Map(position: Binding(
                get: { MapCameraPosition.region(region) },
                set: { position in if let r = position.region { region = r } }
            )) {
                ForEach(filteredPins) { pin in
                    Annotation(pin.title, coordinate: pin.coordinate) { pinButton(pin) }
                }
            }
        } else {
            Map(coordinateRegion: $region, annotationItems: filteredPins) { pin in
                MapAnnotation(coordinate: pin.coordinate) { pinButton(pin) }
            }
        }
        #endif
    }

    @ViewBuilder private func pinButton(_ pin: MapPin) -> some View {
        Button { select(pin) } label: {
            if pin.isPublicRecordSummary {
                Text(pin.badge ?? "#")
                    .font(BLFont.mono(11, .heavy))
                    .foregroundColor(.white)
                    .frame(minWidth: 30, minHeight: 30)
                    .padding(5)
                    .background(pin.tint, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.45), radius: 4)
                    .scaleEffect(selected?.id == pin.id ? 1.22 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected?.id)
            } else {
                Image(systemName: icon(for: pin))
                    .font(.blSystem(size: pin.isDeal ? 17 : (pin.isPublicRecord ? 16 : 22), weight: .bold))
                    .foregroundStyle(pin.tint)
                    .shadow(color: .black.opacity(0.5), radius: 3)
                    .padding(pin.isDeal || pin.isPublicRecord ? 4 : 0)
                    .background(pin.isDeal || pin.isPublicRecord ? AnyShapeStyle(BLTheme.bg2) : AnyShapeStyle(Color.clear), in: Circle())
                    .scaleEffect(selected?.id == pin.id ? 1.3 : 1)
                    .animation(.spring(response: 0.3, dampingFraction: 0.7), value: selected?.id)
            }
        }
        .buttonStyle(.plain)
        .help(pin.title + (pin.subtitle.isEmpty ? "" : " — " + pin.subtitle))
    }

    @ViewBuilder private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(LeadSource.allCases.filter { src in crmPins.contains { $0.isLead && $0.tint == src.tint } }, id: \.self) { src in
                HStack(spacing: 6) { Circle().fill(src.tint).frame(width: 8, height: 8); Text(src.label).font(BLFont.body(10, .semibold)).foregroundColor(BLTheme.text) }
            }
            if crmPins.contains(where: { $0.isDeal }) {
                HStack(spacing: 6) { Image(systemName: "house.fill").font(.blSystem(size: 8)).foregroundColor(BLTheme.green); Text("Deal").font(BLFont.body(10, .semibold)).foregroundColor(BLTheme.text) }
            }
            if publicSummaryMarkerCount > 0 {
                HStack(spacing: 6) { Image(systemName: "circle.grid.2x2.fill").font(.blSystem(size: 8)).foregroundColor(.blue); Text("Record count marker").font(BLFont.body(10, .semibold)).foregroundColor(BLTheme.text) }
            }
            if publicParcelPinCount > 0 {
                // Parcels are shaded by RedevelopmentScore (teardown heat) — spell the scale out so the
                // colors read, and name the honest "not scorable" gray for parcels missing the split.
                Divider().frame(width: 92)
                Text("PARCEL REDEVELOPMENT").font(BLFont.mono(8, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                ForEach([MapPin.RedevelopmentHeat.prime, .strong, .watch, .marginal, .notScorable], id: \.legendLabel) { heat in
                    HStack(spacing: 6) { Circle().fill(heat.color).frame(width: 8, height: 8); Text(heat.legendLabel).font(BLFont.body(10, .semibold)).foregroundColor(BLTheme.text) }
                }
            }
            // RE-19: FEMA flood-zone bands actually present in the current view (never a static key).
            if showFlood {
                Divider().frame(width: 92)
                Text("FEMA FLOOD ZONES").font(BLFont.mono(8, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                let bands = FloodOverlayEngine.legendBands(FloodFeatureSet(features: floodFeatures))
                if bands.isEmpty {
                    Text(floodLoading ? "Loading FEMA NFHL…" : "No zones in view").font(BLFont.body(9.5, .semibold)).foregroundColor(BLTheme.sub)
                } else {
                    ForEach(bands, id: \.rawValue) { band in
                        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(floodColor(band)).frame(width: 9, height: 9); Text(band.legendLabel).font(BLFont.body(9.5, .semibold)).foregroundColor(BLTheme.text).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                if !floodNote.isEmpty {
                    Text(floodNote).font(BLFont.body(8.5, .medium)).foregroundColor(BLTheme.sub).frame(maxWidth: 190, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
            }
        }.padding(9).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// The full key covers half a phone map, so compact hides it behind a tap on the key button.
    @ViewBuilder private var legendOverlay: some View {
        if BLScale.isCompact {
            VStack(alignment: .trailing, spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.18)) { showLegend.toggle() } } label: {
                    Image(systemName: showLegend ? "xmark" : "list.bullet.circle")
                        .font(.blSystem(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                        .padding(7).background(.ultraThinMaterial).clipShape(Circle())
                }.buttonStyle(.plain).accessibilityLabel(showLegend ? "Hide map key" : "Show map key")
                if showLegend { legend }
            }
        } else {
            legend
        }
    }

    /// SwiftUI color mirror of Coordinator.floodNSColor (native renderer), kept in lock-step.
    private func floodColor(_ risk: FloodRisk) -> Color {
        switch risk {
        case .high: return .blue
        case .moderate: return .teal
        case .minimal: return .green
        case .undetermined: return .gray
        case .unknown: return .indigo
        }
    }

    /// RE-19: pull the LIVE FEMA NFHL flood-zone polygons for the current viewport. Honest: on an
    /// empty/timeout/error response it shows the source-cited empty note and draws nothing invented.
    private func loadFloodZones() {
        let center = region.center, span = region.span
        let minLng = center.longitude - span.longitudeDelta / 2
        let maxLng = center.longitude + span.longitudeDelta / 2
        let minLat = center.latitude - span.latitudeDelta / 2
        let maxLat = center.latitude + span.latitudeDelta / 2
        // A whole-country view returns nothing useful and hammers the service — ask the buyer to zoom.
        guard span.latitudeDelta < 2.5, span.longitudeDelta < 2.5 else {
            floodFeatures = []; floodNote = "Zoom in to a city/neighborhood to load FEMA flood zones."; return
        }
        floodLoading = true; floodNote = "Loading FEMA National Flood Hazard Layer…"
        let url = FloodOverlayEngine.queryURL(minLng: minLng, minLat: minLat, maxLng: maxLng, maxLat: maxLat)
        var req = URLRequest(url: url)
        req.timeoutInterval = 30   // the public NFHL service is slow/throttled
        req.setValue("BlackLabelRealEstate/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let ok = (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
                let set = ok ? FloodOverlayEngine.parse(data) : FloodFeatureSet()
                await MainActor.run {
                    floodLoading = false
                    floodFeatures = set.features
                    if set.isEmpty {
                        floodNote = FloodOverlayEngine.emptyNote
                    } else {
                        let df = DateFormatter(); df.dateFormat = "MMM d, h:mm a"
                        floodNote = FloodOverlayEngine.sourceLine(featureCount: set.features.count, dateLabel: df.string(from: Date()))
                    }
                }
            } catch {
                await MainActor.run {
                    floodLoading = false; floodFeatures = []
                    floodNote = FloodOverlayEngine.emptyNote
                }
            }
        }
    }

    @ViewBuilder private func selectedCard(_ pin: MapPin) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: pin)).font(.blSystem(size: 18, weight: .bold)).foregroundStyle(pin.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(pin.title).font(BLFont.body(14, .bold)).foregroundColor(BLTheme.text)
                if !pin.subtitle.isEmpty { Text(pin.subtitle).font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).lineLimit(1) }
            }
            Spacer()
            if pin.isPublicRecordSummary {
                GhostButton(label: "Drill in", icon: "plus.magnifyingglass", tint: BLTheme.gold) {
                    select(pin)
                }
            } else {
                if let record = pin.record {
                    GhostButton(label: "Save to My Leads", icon: "person.crop.circle.badge.plus", tint: BLTheme.green) {
                        savePin(record)
                    }
                }
                GhostButton(label: "Directions", icon: "arrow.triangle.turn.up.right.diamond", tint: BLTheme.gold) {
                    let q = "\(pin.coordinate.latitude),\(pin.coordinate.longitude)"
                    if let u = URL(string: "https://maps.apple.com/?daddr=\(q)") { NSWorkspace.shared.open(u) }
                }
            }
            if !pinSaveNote.isEmpty {
                Label(pinSaveNote, systemImage: "checkmark.circle.fill")
                    .font(BLFont.body(11.5, .bold)).foregroundColor(BLTheme.green)
            }
        }
        .padding(13).background(BLTheme.panelGrad).clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(pin.tint.opacity(0.4), lineWidth: 1))
    }

    /// Save the selected public-record pin into My Leads (deduped, with map provenance;
    /// contact fields stay empty — labeled "not skip-traced yet" in the CRM).
    private func savePin(_ record: PropertyRecord) {
        let filterBits = ["Property Map",
                          recordListLabel.isEmpty ? nil : recordListLabel,
                          recordCategory.trimmedMapFilter.isEmpty || !recordListLabel.isEmpty ? nil : DatabaseListCriteria.humanCategory(recordCategory)]
            .compactMap { $0 }
        let result = model.saveDatabaseRecords([record],
                                               origin: .map,
                                               apiCategory: recordCategory.trimmedMapFilter.isEmpty ? nil : recordCategory,
                                               criteriaSummary: filterBits.joined(separator: " · "))
        pinSaveNote = result.added == 1 ? "Saved to My Leads." : "Already in My Leads."
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { pinSaveNote = "" }
    }

    @ViewBuilder private var mapEmptyOverlay: some View {
        VStack(spacing: 10) {
            EmptyState(icon: recordError.isEmpty ? "mappin.slash" : "wifi.exclamationmark",
                       title: recordError.isEmpty ? "No matching records in this viewport" : "Couldn't load properties",
                       hint: recordError.isEmpty
                            ? "Widen the map or clear filters — records reload as you move."
                            : "The live index didn't answer. Check the connection and retry — nothing is fabricated to fill the map.")
            if !recordError.isEmpty {
                GhostButton(label: recordLoading ? "Retrying…" : "Retry", icon: "arrow.clockwise", tint: BLTheme.gold) {
                    loadPublicRecords(fitResults: false)
                }
                .disabled(recordLoading)
            }
        }
        .blScreenPadding(24)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var statusStrip: some View {
        if !recordError.isEmpty || !unlocated.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !recordError.isEmpty {
                    // Client-facing line stays calm; the full technical error is in the
                    // PropertyMap os_log stream (loadPublicRecords logs it on failure).
                    Text("PUBLIC MAP FEED OFFLINE — retry above.")
                        .font(BLFont.mono(9.5, .bold)).foregroundColor(BL.danger).tracking(0.5)
                }
                if !unlocated.isEmpty {
                    Text("COULDN'T LOCATE (\(unlocated.count)) — not invented").font(BLFont.mono(9.5, .bold)).foregroundColor(BL.danger).tracking(0.5)
                    ForEach(unlocated.prefix(8), id: \.self) { Text("-  \($0)").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).lineLimit(1) }
                    if unlocated.count > 8 { Text("+\(unlocated.count - 8) more — add city + state to locate them.").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub) }
                }
            }.padding(.horizontal, BLScale.gutter(28)).padding(.top, 10).padding(.bottom, 20)
        } else {
            Spacer().frame(height: 20)
        }
    }

    // Records that can possibly be mapped (have an address-shaped string).
    private struct Candidate {
        let id: UUID
        let pinID: String
        let title: String
        let subtitle: String
        let address: String
        let tint: Color
        let isDeal: Bool
        let lat: Double?
        let lng: Double?
    }

    private var candidates: [Candidate] {
        var out: [Candidate] = []
        for l in model.leads {
            guard let addr = l.routableAddress else { continue }
            // County strings arrive both bare ("Hall") and suffixed ("Hall County") — append the
            // word only when missing so the geocode query never reads "Hall County County".
            let county = l.county.trimmingCharacters(in: .whitespaces)
            let countyLabel = county.lowercased().hasSuffix("county") ? county : "\(county) County"
            out.append(Candidate(id: l.id, pinID: "lead-\(l.id.uuidString)", title: l.name,
                                 subtitle: l.propertyAddress,
                                 address: county.isEmpty ? addr : "\(addr), \(countyLabel)",
                                 tint: l.source.tint, isDeal: false, lat: l.lat, lng: l.lng))
        }
        for d in model.deals where !d.address.trimmingCharacters(in: .whitespaces).isEmpty && d.address.range(of: #"\d"#, options: .regularExpression) != nil {
            out.append(Candidate(id: d.id, pinID: "deal-\(d.id.uuidString)", title: d.address,
                                 subtitle: d.arv > 0 ? "ARV \(REMath.money(d.arv))" : d.county,
                                 address: d.address, tint: BLTheme.green, isDeal: true, lat: d.lat, lng: d.lng))
        }
        return out
    }

    private func geocodeAll() {
        guard !candidates.isEmpty else { crmPins = []; unlocated = []; loaded = true; return }
        loading = true; loaded = true
        let cands = candidates
        Task {
            var placed: [MapPin] = []
            var missed: [String] = []
            for c in cands {
                var coord: (Double, Double)?
                if let la = c.lat, let lo = c.lng { coord = (la, lo) }
                else { coord = await OSMGeocoder.shared.geocode(c.address) }
                if let coord {
                    placed.append(MapPin(id: c.pinID, title: c.title, subtitle: c.subtitle,
                                         coordinate: CLLocationCoordinate2D(latitude: coord.0, longitude: coord.1),
                                         tint: c.tint, kind: c.isDeal ? .deal : .lead))
                    if c.lat == nil {
                        if c.isDeal, let i = model.deals.firstIndex(where: { $0.id == c.id }) {
                            await MainActor.run { model.deals[i].lat = coord.0; model.deals[i].lng = coord.1 }
                        } else if !c.isDeal, let i = model.leads.firstIndex(where: { $0.id == c.id }) {
                            await MainActor.run { model.leads[i].lat = coord.0; model.leads[i].lng = coord.1 }
                        }
                    }
                } else { missed.append(c.title + (c.subtitle.isEmpty ? "" : " — " + c.subtitle)) }
            }
            await MainActor.run {
                crmPins = placed; unlocated = missed; loading = false
                // First framing goes to the buyer's own pipeline: fit the CRM pins unless some
                // earlier load already framed the map (then leave the user's viewport alone).
                if !placed.isEmpty && (publicPins.isEmpty || !didInitialFit) {
                    region = Self.fit(placed.map { $0.coordinate })
                    didInitialFit = true
                }
            }
        }
    }

    private func loadPublicRecords(fitResults: Bool, includeWholeCache: Bool = false, forceParcelPins: Bool = false) {
        lastRecordReloadKey = recordReloadKey
        recordLoading = true
        recordError = ""
        recordsLoaded = true
        let q = recordQuery
        // Normalize location text to the index's format ("Georgia" → "GA", "Bibb County" → "Bibb")
        // so map pins match the same reasonable spellings the List Builder now accepts.
        let stTrim = recordState.trimmingCharacters(in: .whitespacesAndNewlines)
        let st = stTrim.isEmpty ? "" : USStates.queryState(from: stTrim)
        let co = USStates.normalizedCounty(recordCounty)
        let ci = recordCity
        let zp = recordZip
        let cat = recordCategory
        let mn = recordMinValue
        let mx = recordMaxValue
        let sa = recordSoldAfter
        let sb = recordSoldBefore
        let unfiltered = [q, st, co, ci, zp, cat, sa, sb].allSatisfy { $0.trimmedMapFilter.isEmpty } && mn == nil && mx == nil
        // A continental / multi-state viewport must NOT issue a bounded pin scan. The records table is
        // partitioned by state, so an unfiltered bbox spanning many states scans many partitions and
        // blows past the 20s client timeout (server-side pruning keeps single-state/metro views fast,
        // but a genuinely wide view still overlaps too many partitions). At this zoom the fast
        // pre-materialized national sample is both quick and the right content — 5,000 parcel pins
        // only cluster into blobs this far out. Bounded fetches resume once the buyer zooms into a
        // state/metro. Single-state views (≈5–8° after fit padding) stay on the bounded path.
        let regionIsWide = Self.isWideViewport(region.span)
        let bounds = unfiltered && (includeWholeCache || regionIsWide) ? Self.wholeCacheBounds : Self.bounds(for: region)
        Task {
            do {
                let page = try await RealEstateAPI.mapRecords(bounds: bounds,
                                                              query: q,
                                                              state: st,
                                                              county: co,
                                                              city: ci,
                                                              zip: zp,
                                                              category: cat,
                                                              minValue: mn,
                                                              maxValue: mx,
                                                              soldAfter: sa,
                                                              soldBefore: sb,
                                                              perPage: recordLimit)
                let pins = page.results.compactMap(Self.publicRecordPin)
                let tier = page.tier
                await MainActor.run {
                    publicPins = pins
                    lastLoadedTier = tier
                    recordCount = pins.count
                    representedRecordCount = pins.count
                    recordSource = "Production"
                    showingRecordSummaries = false
                    recordLoading = false
                    recordError = ""
                    if fitResults && !pins.isEmpty { region = Self.fit(pins.map { $0.coordinate }); didInitialFit = true }
                    propertyMapLogger.notice("loaded public map pins source=production visible=\(pins.count, privacy: .public) fit=\(fitResults, privacy: .public)")
                    emitMapUISmoke("BLRE_MAP_UI|phase=pins|pins=\(pins.count)|cache=0|source=production", quit: true)
                    finishDeferredViewportReloadIfNeeded()
                }
            } catch {
                await MainActor.run {
                    recordLoading = false
                    // A background viewport reload that fails (timeout, blip) must NOT wipe the pins
                    // already on screen and flash "map feed offline" — keep what's shown. Only surface
                    // the error when there is nothing to display (the framing load itself failed).
                    let keptExisting = !publicPins.isEmpty && !fitResults
                    if !keptExisting {
                        publicPins = []
                        recordCount = 0
                        representedRecordCount = 0
                        recordError = error.localizedDescription
                        showingRecordSummaries = false
                    }
                    propertyMapLogger.error("failed public map pins error=\(error.localizedDescription, privacy: .public) keptExisting=\(keptExisting, privacy: .public)")
                    emitMapUISmoke("BLRE_MAP_UI|phase=error|error=\(error.localizedDescription)|kept=\(keptExisting)", quit: true)
                    finishDeferredViewportReloadIfNeeded()
                }
            }
        }
    }

    private func emitMapUISmoke(_ line: String, quit: Bool = false) {
        let env = ProcessInfo.processInfo.environment
        guard env["BLRE_MAP_UI_SMOKE"] == "1" else { return }
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8) ?? Data())
        #if os(macOS)
        if quit && env["BLRE_MAP_UI_SMOKE_QUIT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSApp.terminate(nil)
            }
        }
        #endif
    }

    private func consumePendingMapRequestIfNeeded() {
        guard let request = model.pendingPropertyMapRequest else { return }
        viewportReloadTask?.cancel()
        recordQuery = request.query
        recordState = request.state
        recordCounty = request.county
        recordCity = request.city
        recordZip = request.zip
        recordCategory = request.category
        recordMinValue = request.minValue
        recordMaxValue = request.maxValue
        recordSoldAfter = request.soldAfter
        recordSoldBefore = request.soldBefore
        recordListLabel = request.listLabel
        recordListTotal = request.total
        showListContext = true
        selected = nil
        model.pendingPropertyMapRequest = nil
        loadPublicRecords(fitResults: true)
    }

    /// Drop the guided-list filter and return to plain viewport browsing.
    private func clearListFilter() {
        recordCategory = ""; recordMinValue = nil; recordMaxValue = nil
        recordSoldAfter = ""; recordSoldBefore = ""; recordListLabel = ""
        recordListTotal = nil
        loadPublicRecords(fitResults: false)
    }

    private func scheduleVisibleRecordReload(delayNanoseconds: UInt64 = 550_000_000) {
        guard showPublicRecords, recordsLoaded else { return }
        let scheduledKey = recordReloadKey
        guard scheduledKey != lastRecordReloadKey else { return }
        viewportReloadTask?.cancel()
        viewportReloadTask = Task {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard recordReloadKey != lastRecordReloadKey else { return }
                if recordLoading {
                    needsViewportRefreshAfterLoad = true
                } else {
                    loadPublicRecords(fitResults: false)
                }
            }
        }
    }

    private func finishDeferredViewportReloadIfNeeded() {
        guard needsViewportRefreshAfterLoad else { return }
        needsViewportRefreshAfterLoad = false
        scheduleVisibleRecordReload(delayNanoseconds: 120_000_000)
    }

    private func select(_ pin: MapPin) {
        selected = pin
        if pin.isPublicRecordSummary {
            if pin.id.hasPrefix("summary-state-"), let state = pin.badge, state.count == 2 {
                recordState = state
                recordCounty = ""
                showParcelPins(preferredState: state)
            } else if pin.id.hasPrefix("summary-county-") {
                let raw = String(pin.id.dropFirst("summary-county-".count))
                let parts = raw.split(separator: "-", maxSplits: 1).map(String.init)
                if let state = parts.first, state.count == 2 { recordState = state }
                if parts.count > 1 { recordCounty = parts[1] }
                viewportReloadTask?.cancel()
                withAnimation(.easeInOut(duration: 0.4)) {
                    region = summaryDrillRegion(for: pin)
                }
                loadPublicRecords(fitResults: true)
            } else {
                withAnimation(.easeInOut(duration: 0.4)) {
                    region = summaryDrillRegion(for: pin)
                }
            }
        } else {
            focus(pin)
        }
    }

    private func showParcelPins(preferredState: String? = nil) {
        viewportReloadTask?.cancel()
        let typedState = recordState.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedSummaryParts: [String] = {
            guard selected?.id.hasPrefix("summary-county-") == true else { return [] }
            let raw = String(selected!.id.dropFirst("summary-county-".count))
            return raw.split(separator: "-", maxSplits: 1).map(String.init)
        }()
        let selectedSummaryState = selectedSummaryParts.first.flatMap { $0.count == 2 ? $0.uppercased() : nil }
        let selectedSummaryCounty = selectedSummaryParts.count > 1 ? selectedSummaryParts[1] : nil
        let selectedState = preferredState
            ?? (selected?.id.hasPrefix("summary-state-") == true ? selected?.badge : nil)
            ?? selectedSummaryState
            ?? (typedState.isEmpty ? nil : typedState.uppercased())
        if let county = selectedSummaryCounty, !county.isEmpty {
            recordCounty = county
        }
        let state = (selectedState ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !state.isEmpty { recordState = state }
        guard !state.isEmpty || selectedSummaryCounty != nil else {
            loadPublicRecords(fitResults: true, includeWholeCache: true, forceParcelPins: true)
            return
        }
        loadPublicRecords(fitResults: true, forceParcelPins: true)
    }

    private func summaryDrillRegion(for pin: MapPin) -> MKCoordinateRegion {
        let isStateSummary = pin.id.hasPrefix("summary-state-")
        let delta = isStateSummary ? 8.0 : 1.2
        return MKCoordinateRegion(center: pin.coordinate, span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta))
    }

    private func focus(_ pin: MapPin) {
        withAnimation(.easeInOut(duration: 0.4)) {
            region = MKCoordinateRegion(center: pin.coordinate, span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06))
        }
    }

    private func icon(for pin: MapPin) -> String {
        switch pin.kind {
        case .lead: return "mappin.circle.fill"
        case .deal: return "house.fill"
        case .publicRecord: return "building.2.crop.circle"
        case .publicRecordSummary: return "circle.grid.2x2.fill"
        }
    }

    private func compactCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    static func publicRecordPin(_ record: PropertyRecord) -> MapPin? {
        guard let lat = record.lat, let lng = record.lng,
              lat >= -90, lat <= 90, lng >= -180, lng <= 180,
              PropertyMapViewportPolicy.coordinateMatchesState(record.state ?? record.situs_state, lat: lat, lng: lng) else { return nil }
        let title = record.situs_address?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? record.situs_address!
            : (record.parcel_id?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? "Parcel \(record.parcel_id!)"
                : (record.owner_name ?? "Public property record"))
        var parts: [String] = []
        if let owner = record.owner_name, !owner.isEmpty { parts.append(owner) }
        let location = [record.situs_city, record.state, record.situs_zip]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        if !location.isEmpty { parts.append(location) }
        if let county = record.county, !county.isEmpty { parts.append("\(county) County") }
        if let value = record.assessed_value ?? record.land_value ?? record.last_sale_price {
            parts.append("Public value \(REMath.money(Double(value)))")
        }
        // RedevelopmentScore heat: score the parcel off its real assessor land/improvement split, or
        // render the honest "not scorable" state — never a fabricated score to fill the map.
        let score = TeardownScout.redevelopmentScore(for: record)
        if let s = score {
            parts.append("Redevelopment \(s) · \(TeardownScout.tier(for: s))")
        } else {
            parts.append("Redevelopment: not scorable (no land/improvement split)")
        }
        return MapPin(id: "public-\(record.id)", title: title, subtitle: parts.joined(separator: " · "),
                      coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng),
                      tint: MapPin.RedevelopmentHeat.band(score).color, kind: .publicRecord,
                      record: record, redevelopmentScore: score)
    }

    static func publicRecordSummaryPin(_ summary: PropertyMapSummary) -> MapPin? {
        let state = summary.state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let coordinate: CLLocationCoordinate2D
        if summary.lat >= -90, summary.lat <= 90, summary.lng >= -180, summary.lng <= 180,
           PropertyMapViewportPolicy.coordinateMatchesState(state, lat: summary.lat, lng: summary.lng) {
            coordinate = CLLocationCoordinate2D(latitude: summary.lat, longitude: summary.lng)
        } else if summary.level == .state, let center = stateCenters[state] {
            coordinate = center
        } else {
            return nil
        }
        let scope = summary.level == .state ? "state" : "county"
        let suffix = summary.count == 1 ? "record" : "records"
        return MapPin(id: summary.id,
                      title: summary.title,
                      subtitle: "\(compactStaticCount(summary.count)) local public \(suffix) in this \(scope)",
                      coordinate: coordinate,
                      tint: .blue,
                      kind: .publicRecordSummary,
                      badge: summary.level == .state ? state : compactStaticCount(summary.count))
    }

    static func productionCoverageSummaryPin(_ entry: CoverageEntry) -> MapPin? {
        let state = entry.state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let coordinate = stateCenters[state], let count = entry.properties, count > 0 else { return nil }
        let counties = entry.counties ?? 0
        let countyLabel = counties == 1 ? "county" : "counties"
        return MapPin(id: "summary-state-\(state)",
                      title: "\(state) public records",
                      subtitle: "\(compactStaticCount(count)) live public records across \(counties) \(countyLabel)",
                      coordinate: coordinate,
                      tint: .blue,
                      kind: .publicRecordSummary,
                      badge: state)
    }

    static func canUseProductionCoverageSummaries(query: String,
                                                  state: String,
                                                  county: String,
                                                  city: String,
                                                  zip: String) -> Bool {
        [query, state, county, city, zip].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func shouldSummarizeRecords(bounds: PropertyMapBounds,
                                       query: String,
                                       county: String,
                                       city: String,
                                       zip: String) -> Bool {
        PropertyMapViewportPolicy.shouldSummarizeRecords(bounds: bounds, query: query, county: county, city: city, zip: zip)
    }

    static func compactStaticCount(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private static let stateCenters: [String: CLLocationCoordinate2D] = [
        "AL": .init(latitude: 32.8067, longitude: -86.7911),
        "AK": .init(latitude: 61.3707, longitude: -152.4044),
        "AZ": .init(latitude: 33.7298, longitude: -111.4312),
        "AR": .init(latitude: 34.9697, longitude: -92.3731),
        "CA": .init(latitude: 36.1162, longitude: -119.6816),
        "CO": .init(latitude: 39.0598, longitude: -105.3111),
        "CT": .init(latitude: 41.5978, longitude: -72.7554),
        "DE": .init(latitude: 39.3185, longitude: -75.5071),
        "DC": .init(latitude: 38.9072, longitude: -77.0369),
        "FL": .init(latitude: 27.7663, longitude: -81.6868),
        "GA": .init(latitude: 33.0406, longitude: -83.6431),
        "HI": .init(latitude: 21.0943, longitude: -157.4983),
        "ID": .init(latitude: 44.2405, longitude: -114.4788),
        "IL": .init(latitude: 40.3495, longitude: -88.9861),
        "IN": .init(latitude: 39.8494, longitude: -86.2583),
        "IA": .init(latitude: 42.0115, longitude: -93.2105),
        "KS": .init(latitude: 38.5266, longitude: -96.7265),
        "KY": .init(latitude: 37.6681, longitude: -84.6701),
        "LA": .init(latitude: 31.1695, longitude: -91.8678),
        "ME": .init(latitude: 44.6939, longitude: -69.3819),
        "MD": .init(latitude: 39.0639, longitude: -76.8021),
        "MA": .init(latitude: 42.2302, longitude: -71.5301),
        "MI": .init(latitude: 43.3266, longitude: -84.5361),
        "MN": .init(latitude: 45.6945, longitude: -93.9002),
        "MS": .init(latitude: 32.7416, longitude: -89.6787),
        "MO": .init(latitude: 38.4561, longitude: -92.2884),
        "MT": .init(latitude: 46.9219, longitude: -110.4544),
        "NE": .init(latitude: 41.1254, longitude: -98.2681),
        "NV": .init(latitude: 38.3135, longitude: -117.0554),
        "NH": .init(latitude: 43.4525, longitude: -71.5639),
        "NJ": .init(latitude: 40.2989, longitude: -74.5210),
        "NM": .init(latitude: 34.8405, longitude: -106.2485),
        "NY": .init(latitude: 42.1657, longitude: -74.9481),
        "NC": .init(latitude: 35.6301, longitude: -79.8064),
        "ND": .init(latitude: 47.5289, longitude: -99.7840),
        "OH": .init(latitude: 40.3888, longitude: -82.7649),
        "OK": .init(latitude: 35.5653, longitude: -96.9289),
        "OR": .init(latitude: 44.5720, longitude: -122.0709),
        "PA": .init(latitude: 40.5908, longitude: -77.2098),
        "PR": .init(latitude: 18.2208, longitude: -66.5901),
        "RI": .init(latitude: 41.6809, longitude: -71.5118),
        "SC": .init(latitude: 33.8569, longitude: -80.9450),
        "SD": .init(latitude: 44.2998, longitude: -99.4388),
        "TN": .init(latitude: 35.7478, longitude: -86.6923),
        "TX": .init(latitude: 31.0545, longitude: -97.5635),
        "UT": .init(latitude: 40.1500, longitude: -111.8624),
        "VT": .init(latitude: 44.0459, longitude: -72.7107),
        "VA": .init(latitude: 37.7693, longitude: -78.1700),
        "WA": .init(latitude: 47.4009, longitude: -121.4905),
        "WV": .init(latitude: 38.4912, longitude: -80.9545),
        "WI": .init(latitude: 44.2685, longitude: -89.6165),
        "WY": .init(latitude: 42.7560, longitude: -107.3025)
    ]

    static func bounds(for region: MKCoordinateRegion) -> PropertyMapBounds {
        let north = min(90, region.center.latitude + region.span.latitudeDelta / 2)
        let south = max(-90, region.center.latitude - region.span.latitudeDelta / 2)
        let east = min(180, region.center.longitude + region.span.longitudeDelta / 2)
        let west = max(-180, region.center.longitude - region.span.longitudeDelta / 2)
        return PropertyMapBounds(north: north, south: south, east: east, west: west)
    }

    static let wholeCacheBounds = PropertyMapBounds(north: 90, south: -90, east: 180, west: -180)

    /// True when a viewport is continental / multi-state scale, where an unfiltered bounded pin fetch
    /// would span too many state partitions to answer before the client timeout. Such views draw the
    /// fast pre-materialized national sample instead. A single state after fit padding (~5–8°) stays
    /// under the threshold so its parcels still load on the bounded path.
    static func isWideViewport(_ span: MKCoordinateSpan) -> Bool {
        span.latitudeDelta > 8 || span.longitudeDelta > 9
    }

    /// Compute a region that frames all pins with a little padding.
    static func fit(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        guard let first = coords.first else { return MKCoordinateRegion(center: .init(latitude: 39.5, longitude: -98.35), span: .init(latitudeDelta: 48, longitudeDelta: 60)) }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for c in coords { minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude); minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude) }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.04, (maxLat - minLat) * 1.4), longitudeDelta: max(0.04, (maxLon - minLon) * 1.4))
        return MKCoordinateRegion(center: center, span: span)
    }
}

private extension String {
    var trimmedMapFilter: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif // circuit-convert
