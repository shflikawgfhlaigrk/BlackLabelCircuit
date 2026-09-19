#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  NativeLocationManager.swift
//  Ace
//
//  The only Ace component that touches CLLocationManager. It performs one
//  explicit, owner-requested permission/fix cycle and retains no location.
//

#if canImport(CoreLocation) && !CIRCUIT_WINDOWS_SIM
@preconcurrency import CoreLocation
#endif
import Foundation

private final class NativeLocationDelegate: NSObject, CLLocationManagerDelegate {
    var onAuthorization: @MainActor @Sendable (NativeLocationAuthorization) -> Void = { _ in }
    var onLocation:
        @MainActor @Sendable (Double, Double, Double, Date) -> Void = { _, _, _, _ in }
    var onFailure: @MainActor @Sendable () -> Void = {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = nativeLocationAuthorization(from: manager.authorizationStatus)
        Task { @MainActor [onAuthorization] in
            onAuthorization(authorization)
        }
    }

    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else {
            Task { @MainActor [onFailure] in onFailure() }
            return
        }
        let latitude = location.coordinate.latitude
        let longitude = location.coordinate.longitude
        let accuracy = location.horizontalAccuracy
        let observedAt = location.timestamp
        Task { @MainActor [onLocation] in
            onLocation(latitude, longitude, accuracy, observedAt)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [onFailure] in onFailure() }
    }
}

private func nativeLocationAuthorization(
    from status: CLAuthorizationStatus
) -> NativeLocationAuthorization {
    switch status {
    case .notDetermined:
        return .notDetermined
    case .restricted:
        return .restricted
    case .denied:
        return .denied
    case .authorized, .authorizedAlways, .authorizedWhenInUse:
        return .authorized
    @unknown default:
        return .denied
    }
}

@MainActor
final class NativeLocationManager: NSObject, NativeLocationEffectProviding
{
    static let requestTimeout: TimeInterval = 30

    private let manager = CLLocationManager()
    private let delegate = NativeLocationDelegate()
    private var coordinator: NativeLocationRequestCoordinator?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        delegate.onAuthorization = { [weak self] authorization in
            self?.coordinator?.authorizationDidChange(authorization)
        }
        delegate.onLocation = { [weak self] latitude, longitude, accuracy, observedAt in
            self?.coordinator?.didReceiveLocation(
                latitude: latitude,
                longitude: longitude,
                horizontalAccuracy: accuracy,
                observedAt: observedAt
            )
        }
        delegate.onFailure = { [weak self] in
            self?.coordinator?.didFail()
        }
        manager.delegate = delegate
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestCurrentFixJustInTime(
        completion: @escaping (NativeLocationRequestOutcome) -> Void
    ) {
        timeoutTask?.cancel()
        coordinator = nil

        let coordinator = NativeLocationRequestCoordinator(provider: self)
        self.coordinator = coordinator
        coordinator.start(
            servicesAvailable: CLLocationManager.locationServicesEnabled(),
            authorization: nativeLocationAuthorization(from: manager.authorizationStatus)
        ) { [weak self] outcome in
            guard let self else { return }
            self.timeoutTask?.cancel()
            self.timeoutTask = nil
            self.coordinator = nil
            completion(outcome)
        }

        guard coordinator.state != .completed else { return }
        timeoutTask = Task { @MainActor [weak self, weak coordinator] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000)
            )
            guard !Task.isCancelled,
                  let self,
                  self.coordinator === coordinator else { return }
            coordinator?.timeout()
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        coordinator = nil
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestSingleLocation() {
        manager.requestLocation()
    }

}
#endif // circuit-convert
