#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Vigil — the live CoreLocation home-geofence monitor. The ONLY file that talks to
// CoreLocation; it converts the OS's region crossings + authorization into the pure,
// Foundation-only Geofence* types in HomeCore.swift and hands them to HomeStore. Honest
// by construction: a crossing is routed (in HomeStore) through GeofenceModel.event, which
// fails closed when access is missing or no region is set, and the authorization state is
// surfaced verbatim — the app never fabricates an arrive/leave the OS didn't actually
// report (§5.1). Own-it/§5.5: the buyer's own device monitors one region they set; there
// is no hosted location service.

import Foundation
#if canImport(CoreLocation) && !CIRCUIT_WINDOWS_SIM
import CoreLocation
#endif

private typealias GeofenceLocationFix = (lat: Double, lon: Double)

private final class GeofenceLocationDelegate: NSObject, CLLocationManagerDelegate {
    var onAuthorization: @MainActor @Sendable (Int) -> Void = { _ in }
    var onCrossing: @MainActor @Sendable (String, GeofenceCrossing) -> Void = { _, _ in }
    var onLocationFix: @MainActor @Sendable (GeofenceLocationFix?) -> Void = { _ in }
    var onLocationFailure: @MainActor @Sendable () -> Void = {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let raw = Int(manager.authorizationStatus.rawValue)
        Task { @MainActor [onAuthorization] in onAuthorization(raw) }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        let identifier = region.identifier
        Task { @MainActor [onCrossing] in onCrossing(identifier, .entered) }
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let identifier = region.identifier
        Task { @MainActor [onCrossing] in onCrossing(identifier, .left) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coord = locations.last?.coordinate
        let fix = coord.map { GeofenceLocationFix(lat: $0.latitude, lon: $0.longitude) }
        Task { @MainActor [onLocationFix] in onLocationFix(fix) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [onLocationFailure] in onLocationFailure() }
    }
}

@MainActor
final class GeofenceMonitor: NSObject {
    private let manager = CLLocationManager()
    private let delegate = GeofenceLocationDelegate()
    private let regionID = "com.blacklabel.homefront.home"
    private var wantLocationFix = false

    /// Pushed to HomeStore whenever the OS authorization changes (cold-boot read included).
    var onAuth: ((GeofenceAuthState) -> Void)?
    /// Pushed on a REAL region crossing (didEnter/didExit). HomeStore routes it through
    /// GeofenceModel.event so an event is acted on only when access + region are live.
    var onCrossing: ((GeofenceCrossing) -> Void)?
    /// Pushed once after a requested one-shot location fix, so the buyer can set "home" to
    /// where they are now. nil = the fix failed/was denied (no fabricated coordinate, §5.1).
    var onLocationFix: (((lat: Double, lon: Double)?) -> Void)?

    override init() {
        super.init()
        delegate.onAuthorization = { [weak self] raw in
            self?.onAuth?(GeofenceAuthState.from(rawValue: raw))
        }
        delegate.onCrossing = { [weak self] identifier, crossing in
            guard let self, identifier == self.regionID else { return }
            self.onCrossing?(crossing)
        }
        delegate.onLocationFix = { [weak self] fix in
            guard let self, self.wantLocationFix else { return }
            self.wantLocationFix = false
            self.onLocationFix?(fix)
        }
        delegate.onLocationFailure = { [weak self] in
            guard let self, self.wantLocationFix else { return }
            self.wantLocationFix = false
            self.onLocationFix?(nil)
        }
        manager.delegate = delegate
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    /// Current authorization as the honest pure state (read synchronously).
    var authState: GeofenceAuthState {
        GeofenceAuthState.from(rawValue: Int(manager.authorizationStatus.rawValue))
    }

    /// Raise the system permission prompt (only effective while notDetermined; once the
    /// status is determined the OS won't re-prompt and the UI routes to System Settings).
    func requestAccess() { manager.requestAlwaysAuthorization() }

    /// Begin monitoring the configured home region. No-op when unconfigured or
    /// unauthorized — never starts a phantom region (the OS would reject it anyway).
    func startMonitoring(_ region: GeofenceRegion) {
        guard region.isConfigured, authState.monitoringEligible else { return }
        for r in manager.monitoredRegions where r.identifier == regionID { manager.stopMonitoring(for: r) }
        let center = CLLocationCoordinate2D(latitude: region.latitude, longitude: region.longitude)
        let circ = CLCircularRegion(center: center, radius: region.radiusMeters, identifier: regionID)
        circ.notifyOnEntry = true
        circ.notifyOnExit = true
        manager.startMonitoring(for: circ)
    }

    /// Stop monitoring (called when the buyer clears the home region).
    func stopMonitoring() {
        for r in manager.monitoredRegions where r.identifier == regionID { manager.stopMonitoring(for: r) }
    }

    /// Request a single current-location fix so the buyer can set "home" to here. Honest:
    /// without access it reports nil (never a fabricated coordinate).
    func captureCurrentLocation() {
        guard authState.monitoringEligible else { onLocationFix?(nil); return }
        wantLocationFix = true
        manager.requestLocation()
    }

}
#endif // circuit-convert
