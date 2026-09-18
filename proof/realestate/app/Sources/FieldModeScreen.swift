// Black Label Real Estate — RE-20 FIELD MODE UI + Core Location fix (app-only, not test-compiled).
//
// The pure engine (FieldMode.swift) owns the parse, the point-in-parcel test, the accuracy classifier,
// and the drive-log logic. THIS file owns the two things that touch the machine:
//   • FieldLocator — a thin CLLocationManager wrapper that reports the Mac's Wi-Fi/IP position and its
//     real horizontalAccuracy. macOS has no GPS radio; we surface the accuracy envelope honestly and
//     never imply GPS precision.
//   • FieldModeSheet — download a county's parcel polygons for OFFLINE use (on Wi-Fi), then, in the
//     field, resolve the parcel you're standing on with ZERO network via the cached layer, and log it.
//
// Nothing here fabricates a parcel: an uncovered county, an empty download, or a point with no cached
// parcel all render the engine's honest empty state.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(CoreLocation) && !CIRCUIT_WINDOWS_SIM
import CoreLocation
#endif
#if canImport(MapKit) && !CIRCUIT_WINDOWS_SIM
import MapKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Location permission link + copy (the DOD-3 denial surface).
// The deep link and every sentence shown on denial live here, in one place, so the flow is
// coherent: WHAT happened, WHAT STILL WORKS (everything but Field Mode; cached layers and the
// drive log are preserved), and the NEXT ACTION — with a real Open Settings control, not prose
// alone. The pane path is accurate for EVERY supported OS version: LSMinimumSystemVersion is 13.0
// and macOS 13/14/15 all name it "System Settings → Privacy & Security → Location Services"
// (the "System Preferences" naming died with macOS 12, which this app cannot run on).
enum LocationPermissionUX {
    #if os(macOS)
    /// Apple's documented scheme for opening the Privacy → Location Services pane directly.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
    static let settingsButtonLabel = "Open System Settings"
    static let deniedNote = "Location access is off for Black Label Real Estate, so Field Mode cannot resolve the parcel you are standing on. Everything else in the app still works, and your cached county layers and drive log are preserved exactly as they were. Turn access on in System Settings → Privacy & Security → Location Services, then come back — this screen confirms the moment access is granted."
    #else
    /// iOS: the app's own Settings page (the supported way to reach its Location toggle).
    static let settingsURL = URL(string: UIApplication.openSettingsURLString)!
    static let settingsButtonLabel = "Open Settings"
    static let deniedNote = "Location access is off for Black Label Real Estate, so Field Mode cannot resolve the parcel you are standing on. Everything else in the app still works, and your cached county layers and drive log are preserved exactly as they were. Turn access on in Settings → Black Label Real Estate → Location, then come back — this screen confirms the moment access is granted."
    #endif
    /// Shown when authorization flips to granted AFTER a recorded denial — the deny-return-confirm
    /// loop closes with an explicit confirmation instead of silently starting to work.
    static let grantedConfirmation = "Location access is on — Field Mode can resolve the parcel you are standing on now."
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Core Location wrapper (the ONLY thing that touches CLLocationManager).
// macOS locates by Wi-Fi/IP trilateration — NOT GPS. We keep the last fix + its accuracy and let the
// pure engine classify it; we never round a coarse fix up to "precise".
final class FieldLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D? = nil
    @Published var horizontalAccuracy: Double = -1          // meters; <0 == invalid (CLLocation sentinel)
    @Published var authorized = false
    @Published var lastError: String = ""
    /// Non-empty only after a deny→grant round trip: the user came back from Settings and access is
    /// now on. Rendered as the green confirmation row (DOD-3.4's confirm leg).
    @Published var grantedAfterDenial: String = ""
    /// Set once a denial has been observed, so a later grant is confirmable as a RETURN, not a first ask.
    private var sawDenial = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest    // best the Wi-Fi radio can do — still not GPS
    }

    /// Ask for permission and start updating. On macOS this returns a Wi-Fi/IP fix within a few seconds.
    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }
    func stop() { manager.stopUpdatingLocation() }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .authorizedAlways, .authorized:
            authorized = true
            lastError = ""
            // Close the deny-return-confirm loop explicitly: this delegate fires again when the
            // user returns from Settings, so a grant AFTER a recorded denial gets a visible
            // confirmation instead of the screen just silently starting to work.
            if sawDenial { grantedAfterDenial = LocationPermissionUX.grantedConfirmation }
            m.startUpdatingLocation()
        case .restricted, .denied:
            authorized = false
            sawDenial = true
            grantedAfterDenial = ""
            lastError = LocationPermissionUX.deniedNote
        default: authorized = false
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        coordinate = loc.coordinate
        horizontalAccuracy = loc.horizontalAccuracy      // negative if the fix is invalid — kept honest
        lastError = ""
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        lastError = "Couldn't get a Wi-Fi location fix: \(error.localizedDescription). Nothing was lost — your cached county layers and drive log are untouched. Move nearer a Wi-Fi network (or check your connection) and try Resolve again."
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Field Mode sheet.
struct FieldModeSheet: View {
    @EnvironmentObject var model: AppModel
    /// The current Property Map viewport — the extent a "download for offline" pull covers.
    var region: MKCoordinateRegion

    @StateObject private var locator = FieldLocator()
    @State private var county: String = ParcelRegistry.coveredCounties.first ?? ""
    @State private var layers: [OfflineParcelLayer] = []
    @State private var driveLog: [DrivenParcel] = []
    @State private var status: String = ""
    @State private var downloading = false
    @State private var standing: (OfflineParcelLayer, FieldParcel)? = nil
    @State private var standMiss: String = ""
    @State private var confirmClearLog = false

    private let layerStore = OfflineParcelLayerStore()
    private let logStore = FieldDriveLogStore()

    private var accuracyNote: String {
        locator.coordinate == nil ? FieldModeEngine.accuracyPreamble
                                  : FieldModeEngine.accuracyNote(horizontalMeters: locator.horizontalAccuracy)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                permissionBanner
                accuracyBanner
                downloadCard
                standCard
                driveLogCard
                if !status.isEmpty {
                    Text(status).font(BLFont.mono(11)).foregroundColor(BLTheme.text.opacity(0.7))
                }
            }
            .blScreenPadding(24)
        }
        .sheetFrame(560, 720)
        .onAppear {
            layers = layerStore.load()
            driveLog = logStore.load()
            locator.start()
        }
        .onDisappear { locator.stop() }
    }

    // MARK: Header
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Field Mode").font(BLFont.display(26, .semibold)).foregroundColor(BLTheme.text)
            Text("Download a county's parcels on Wi-Fi, then stand on a lot in the field — with no signal — and Black Label tells you whose parcel it is from the cached county layer. Wi-Fi location, not GPS; nothing invented.")
                .font(BLFont.body(12)).foregroundColor(BLTheme.text.opacity(0.6))
        }
    }

    // MARK: Permission banner — the denial surface (DOD-3.1/3.3/3.4).
    // Denied: the full what-happened / what-still-works / next-action copy WITH a real
    // Open Settings control that deep-links straight to the Location pane. Granted after a
    // denial: an explicit green confirmation, so returning from Settings visibly completes.
    @ViewBuilder private var permissionBanner: some View {
        if !locator.authorized && !locator.lastError.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "location.slash.fill").font(.blSystem(size: 12, weight: .bold)).foregroundColor(BLTheme.gold)
                    Text(locator.lastError).font(BLFont.body(11.5)).foregroundColor(BLTheme.text.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                GhostButton(label: LocationPermissionUX.settingsButtonLabel, icon: "gearshape", tint: BLTheme.gold) {
                    NSWorkspace.shared.open(LocationPermissionUX.settingsURL)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(BLTheme.bg2).cornerRadius(10)
        } else if !locator.grantedAfterDenial.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.blSystem(size: 12, weight: .bold)).foregroundColor(BLTheme.green)
                Text(locator.grantedAfterDenial).font(BLFont.body(11.5)).foregroundColor(BLTheme.text.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(BLTheme.bg2).cornerRadius(10)
        }
    }

    // MARK: Accuracy banner (always honest about Wi-Fi vs GPS)
    private var accuracyBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "wifi").font(.blSystem(size: 12, weight: .bold)).foregroundColor(BLTheme.gold)
            Text(accuracyNote).font(BLFont.body(11.5)).foregroundColor(BLTheme.text.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).cornerRadius(10)
    }

    // MARK: Download-for-offline
    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1 · Download parcels for offline use").font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
            if ParcelRegistry.coveredCounties.isEmpty {
                Text(FieldModeEngine.uncoveredCountyNote).font(BLFont.body(11.5)).foregroundColor(BLTheme.text.opacity(0.6))
            } else {
                Picker("County", selection: $county) {
                    ForEach(ParcelRegistry.coveredCounties, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu).labelsHidden()
                GhostButton(label: downloading ? "Downloading…" : "Download this map area", icon: "arrow.down.circle", tint: BLTheme.gold) {
                    if !downloading { downloadCurrentArea() }
                }
                if let cached = layers.first(where: { $0.county.lowercased() == county.lowercased() }) {
                    Text(cached.sourceLine).font(BLFont.mono(10.5)).foregroundColor(BLTheme.text.opacity(0.6))
                } else {
                    Text(FieldModeEngine.noLayerNote).font(BLFont.body(11)).foregroundColor(BLTheme.text.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).cornerRadius(10)
    }

    // MARK: Stand-on-parcel
    private var standCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2 · What parcel am I standing on?").font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
            GhostButton(label: "Resolve my location (offline)", icon: "mappin.and.ellipse", tint: BLTheme.gold) {
                resolveStanding()
            }
            if let (layer, p) = standing {
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.label).font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
                    if !p.owner.isEmpty { Text("Owner: \(p.owner)").font(BLFont.body(11.5)).foregroundColor(BLTheme.text.opacity(0.7)) }
                    if !p.parcelID.isEmpty { Text("Parcel \(p.parcelID)").font(BLFont.mono(10.5)).foregroundColor(BLTheme.text.opacity(0.6)) }
                    Text(layer.sourceLine).font(BLFont.mono(10)).foregroundColor(BLTheme.text.opacity(0.5))
                    GhostButton(label: "I'm standing here — log it", icon: "checkmark.circle", tint: BLTheme.green) {
                        logStanding(layer: layer, parcel: p)
                    }
                }
                .padding(.top, 2)
            } else if !standMiss.isEmpty {
                Text(standMiss).font(BLFont.body(11.5)).foregroundColor(BLTheme.text.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).cornerRadius(10)
    }

    // MARK: Drive log
    private var driveLogCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Drive log").font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
                Spacer()
                if !driveLog.isEmpty {
                    Text("\(FieldDriveLog.distinctParcelCount(driveLog)) parcel\(FieldDriveLog.distinctParcelCount(driveLog) == 1 ? "" : "s") worked")
                        .font(BLFont.mono(10.5)).foregroundColor(BLTheme.text.opacity(0.6))
                }
            }
            if driveLog.isEmpty {
                Text(FieldDriveLog.emptyNote).font(BLFont.body(11)).foregroundColor(BLTheme.text.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(driveLog.reversed()) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.situs.isEmpty ? (d.parcelID.isEmpty ? "Parcel" : "Parcel \(d.parcelID)") : d.situs)
                            .font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.text)
                        HStack(spacing: 8) {
                            Text(d.drivenAt.formatted(date: .abbreviated, time: .shortened))
                            if !d.accuracyLabel.isEmpty { Text("· \(d.accuracyLabel)") }
                        }.font(BLFont.mono(10)).foregroundColor(BLTheme.text.opacity(0.55))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
                Button("Clear drive log") { confirmClearLog = true }
                    .font(BLFont.body(11.5, .semibold)).foregroundColor(BL.danger).buttonStyle(.plain)
                    .confirmationDialog("Clear the drive log?", isPresented: $confirmClearLog, titleVisibility: .visible) {
                        Button("Clear", role: .destructive) { driveLog = logStore.clear() }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("This permanently erases every logged canvassing stop on this \(kThisDeviceWord).") }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).cornerRadius(10)
    }

    // MARK: Actions
    private func downloadCurrentArea() {
        guard let source = ParcelRegistry.source(for: county) else {
            status = FieldModeEngine.uncoveredCountyNote; return
        }
        let c = region.center, s = region.span
        let minLng = c.longitude - s.longitudeDelta / 2, maxLng = c.longitude + s.longitudeDelta / 2
        let minLat = c.latitude - s.latitudeDelta / 2, maxLat = c.latitude + s.latitudeDelta / 2
        guard s.latitudeDelta < 2.5, s.longitudeDelta < 2.5 else {
            status = "Zoom the Property Map into your target neighborhood first — a whole-state view is too large to cache."; return
        }
        downloading = true; status = "Downloading \(county) parcels for offline use…"
        let url = FieldModeEngine.layerQueryURL(source: source, minLng: minLng, minLat: minLat, maxLng: maxLng, maxLat: maxLat)
        var req = URLRequest(url: url); req.timeoutInterval = 30
        req.setValue("BlackLabelRealEstate/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let ok = (resp as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } ?? false
                let parcels = ok ? FieldModeEngine.parseParcels(data, source: source) : []
                let layer = FieldModeEngine.makeLayer(county: county, source: source.url,
                                                      bbox: [minLng, minLat, maxLng, maxLat], parcels: parcels)
                await MainActor.run {
                    downloading = false
                    if layer.isEmpty {
                        status = "No parcels returned for this area — the county layer may not cover it, or it timed out. Nothing was cached."
                    } else {
                        layers = layerStore.upsert(layer)
                        status = "Cached \(layer.renderableCount) \(county) parcels for offline field use."
                    }
                }
            } catch {
                await MainActor.run { downloading = false; status = "Download failed: \(error.localizedDescription). Nothing was cached." }
            }
        }
    }

    private func resolveStanding() {
        standing = nil; standMiss = ""
        guard let coord = locator.coordinate else {
            standMiss = "Waiting for a Wi-Fi location fix… make sure Location Services is enabled for this app."; return
        }
        if let hit = layerStore.parcelAt(lng: coord.longitude, lat: coord.latitude) {
            standing = hit
        } else {
            // Distinguish "off my download" from "no parcel here" honestly.
            let onSomeLayer = layerStore.load().contains { $0.covers(lng: coord.longitude, lat: coord.latitude) }
            standMiss = onSomeLayer ? FieldModeEngine.noParcelHereNote : FieldModeEngine.offDownloadNote
        }
    }

    private func logStanding(layer: OfflineParcelLayer, parcel: FieldParcel) {
        let coord = locator.coordinate
        let entry = DrivenParcel(parcelID: parcel.parcelID, owner: parcel.owner, situs: parcel.situs,
                                 lng: coord?.longitude ?? parcel.centroid.0, lat: coord?.latitude ?? parcel.centroid.1,
                                 accuracyMeters: locator.horizontalAccuracy >= 0 ? locator.horizontalAccuracy : nil)
        driveLog = logStore.log(entry)
        status = "Logged \(parcel.label) to your drive log."
    }
}
#endif // circuit-convert
