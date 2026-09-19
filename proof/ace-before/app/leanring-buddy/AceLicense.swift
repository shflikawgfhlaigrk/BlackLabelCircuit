//
//  AceLicense.swift
//  Ace
//
//  The check Ace never had.
//
//  Until 2026-07-29 Ace had NO licensing of any kind. The storefront's /dl gate
//  stopped a stranger DOWNLOADING the app and stopped there — the installed copy
//  never asked who owned it. So one buyer could hand the .dmg to a dorm floor and
//  every copy ran forever, and a buyer who cancelled kept full use indefinitely.
//  On a $50-75/month subscription that made every month after the first an
//  honour system.
//
//  What this is honest about: a check that runs on the buyer's own Mac can be
//  patched out by someone determined enough, and no amount of cleverness here
//  changes that. This is not built to beat a cracker. It is built so the ORDINARY
//  path fails: a friend who is handed the app opens it and is asked for a key
//  they do not have, and a cancelled subscription actually ends access.
//
//  Two rules it must never break, because both would punish the people who DID
//  pay:
//
//  1. A network failure must never lock anyone out. The server issues a lease
//     good for a week; Ace re-checks daily and keeps working the whole time on
//     the last good one. A paying buyer on a plane, or behind a captive portal,
//     or during one of our own outages, notices nothing.
//  2. Failure is never silent. Every refusal names itself and says what to do,
//     through the same FirstRunFailureReporter channel as every other first-run
//     problem — the alternative is the exact bug that shipped in build 4's fix.
//

#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import Foundation
#if canImport(IOKit) && !CIRCUIT_WINDOWS_SIM
import IOKit
#endif
#if canImport(Network) && !CIRCUIT_WINDOWS_SIM
import Network
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CircuitPortKit

extension Notification.Name {
    /// Posted synchronously on MainActor exactly when entitlement changes from
    /// closed to usable. The app delegate consumes this to finish the startup
    /// tail that a locked clean launch deliberately skipped.
    static let aceEntitlementDidBecomeUsable = Notification.Name(
        "com.blacklabel.ace.entitlement-did-become-usable"
    )
}

nonisolated enum AceBrainRoute: String, Codable, Equatable, Sendable {
    case customerOwned = "customer_owned"
    case founderHosted = "founder_hosted"

    private static let defaultsKey = "aceBrainRouteV1"

    static var current: Self {
        get {
            guard let rawValue = UserDefaults.standard.string(
                forKey: defaultsKey
            ) else {
                return .customerOwned
            }
            return Self(rawValue: rawValue) ?? .customerOwned
        }
        set {
            UserDefaults.standard.set(
                newValue.rawValue,
                forKey: defaultsKey
            )
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

enum AceLicenseServerVerdict: Equatable {
    case success(
        expiry: Date,
        brainRoute: AceBrainRoute,
        brainToken: String?,
        trialEndsAt: Date?,
        signedLease: AceSignedLeaseEnvelope
    )
    case refused(message: String)
    case unreachable
    case invalidResponse
}

enum AceLicenseServerResponsePolicy {
    static let minimumAcceptedLeaseLifetime: TimeInterval = 5 * 60
    static let explicitRefusalStatusCodes: Set<Int> = [
        400, 401, 403, 409, 422,
    ]

    static func classify(
        httpStatusCode: Int,
        data: Data,
        expectedLicenseKey: String,
        expectedDeviceIdentifier: String,
        now: Date,
        publicKeysByKeyID: [String: Data] =
            AceSignedLeasePolicy.pinnedPublicKeysByKeyID
    ) -> AceLicenseServerVerdict {
        // Only a successful HTTP response can assert a new lease. A gateway,
        // rate limit or server outage is unavailable, regardless of its body.
        guard httpStatusCode == 200
                || explicitRefusalStatusCodes.contains(httpStatusCode) else {
            return .unreachable
        }
        guard let parsed =
                try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
            return .invalidResponse
        }

        if httpStatusCode == 200,
           parsed["ok"] as? Bool == true {
            guard let expiresAtNumber = parsed["expiresAt"] as? NSNumber,
                  let rawRoute = parsed["brainRoute"] as? String,
                  let brainRoute = AceBrainRoute(rawValue: rawRoute),
                  let leaseKeyId = parsed["leaseKeyId"] as? String,
                  let leasePayload = parsed["leasePayload"] as? String,
                  let leaseSignature = parsed["leaseSignature"] as? String else {
                return .invalidResponse
            }
            let signedLease = AceSignedLeaseEnvelope(
                keyId: leaseKeyId,
                payload: leasePayload,
                signature: leaseSignature
            )
            guard let signedClaims = AceSignedLeasePolicy.verify(
                signedLease,
                expectedLicenseKey: expectedLicenseKey,
                expectedDeviceIdentifier: expectedDeviceIdentifier,
                expectedBrainRoute: rawRoute,
                now: now,
                minimumRemainingLifetime:
                    minimumAcceptedLeaseLifetime,
                publicKeysByKeyID: publicKeysByKeyID
            ) else {
                return .invalidResponse
            }
            let expiresAtMilliseconds = expiresAtNumber.doubleValue
            guard expiresAtMilliseconds.isFinite,
                  expiresAtMilliseconds
                    == Double(signedClaims.expiresAt) else {
                return .invalidResponse
            }
            let expiry = Date(
                timeIntervalSince1970: expiresAtMilliseconds / 1_000
            )
            guard expiry.timeIntervalSince1970.isFinite,
                  expiry.timeIntervalSince(now)
                    >= minimumAcceptedLeaseLifetime else {
                return .invalidResponse
            }

            let brainToken: String?
            switch brainRoute {
            case .customerOwned:
                guard parsed["brainToken"] == nil else {
                    return .invalidResponse
                }
                brainToken = nil
            case .founderHosted:
                guard let rawBrainToken = parsed["brainToken"] as? String else {
                    return .invalidResponse
                }
                let candidate = rawBrainToken.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard candidate.count >= 32,
                      candidate.count <= 256,
                      candidate.unicodeScalars.allSatisfy({
                        CharacterSet.alphanumerics.contains($0)
                            || $0 == "-" || $0 == "_"
                      }) else {
                    return .invalidResponse
                }
                brainToken = candidate
            }

            let trialEndsAt: Date?
            if let rawTrialEndsAt = parsed["trialEndsAt"] {
                if rawTrialEndsAt is NSNull {
                    trialEndsAt = nil
                } else if let value = rawTrialEndsAt as? String,
                          let date = Self.parseISO8601(value) {
                    trialEndsAt = date
                } else {
                    return .invalidResponse
                }
            } else {
                trialEndsAt = nil
            }
            return .success(
                expiry: expiry,
                brainRoute: brainRoute,
                brainToken: brainToken,
                trialEndsAt: trialEndsAt,
                signedLease: signedLease
            )
        }

        guard (httpStatusCode == 200
                || explicitRefusalStatusCodes.contains(httpStatusCode)),
              parsed["ok"] as? Bool == false,
              let rawMessage = parsed["message"] as? String else {
            return .invalidResponse
        }
        let message = rawMessage.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !message.isEmpty else {
            return .invalidResponse
        }
        return .refused(message: message)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return fractional.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }
}

/// A suspended URLSession task whose first byte on the wire is ordered against
/// the process-wide Stealth entry latch. The task is registered before
/// `resume()`, so X either prevents the request from starting or synchronously
/// cancels the already-admitted request without waiting for MainActor teardown.
nonisolated final class StealthURLSessionRequest:
    @unchecked Sendable
{
    typealias Output = (Data, URLResponse)

    private let session: URLSession
    private let entryLatch: StealthEntryLatch
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Output, Error>?
    private var cutoffRegistration: UUID?
    private var cancelled = false
    private var completed = false

    init(
        session: URLSession = .shared,
        entryLatch: StealthEntryLatch = .shared
    ) {
        self.session = session
        self.entryLatch = entryLatch
    }

    func perform(_ request: URLRequest) async throws -> Output {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(request, continuation: continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func install(
        _ request: URLRequest,
        continuation newContinuation:
            CheckedContinuation<Output, Error>
    ) {
        let newTask = session.dataTask(with: request) {
            [weak self] data,
            response,
            error in
            guard let self else { return }
            if let error {
                finish(.failure(error))
            } else if let data, let response {
                finish(.success((data, response)))
            } else {
                finish(
                    .failure(
                        URLError(.badServerResponse)
                    )
                )
            }
        }

        let rejectedBeforeInstall = lock.withLock {
            guard !completed else { return true }
            task = newTask
            continuation = newContinuation
            if cancelled {
                completed = true
                continuation = nil
                task = nil
                return true
            }
            return false
        }
        if rejectedBeforeInstall {
            newTask.cancel()
            newContinuation.resume(throwing: CancellationError())
            return
        }

        let registration =
            entryLatch.registerSynchronousEntryCutoff {
                [weak self] in
                self?.cancel()
            }
        let unregisterImmediately = lock.withLock {
            if completed {
                return true
            }
            cutoffRegistration = registration
            return false
        }
        if unregisterImmediately {
            entryLatch.unregisterSynchronousEntryCutoff(
                registration
            )
            return
        }

        let admitted =
            entryLatch.performUnlessRaised {
                let mayResume = self.lock.withLock {
                    !self.cancelled && !self.completed
                }
                if mayResume {
                    newTask.resume()
                }
                return mayResume
            } ?? false
        if !admitted {
            cancel()
        }
    }

    private func cancel() {
        let completion = lock.withLock {
            cancelled = true
            task?.cancel()
            guard !completed, let continuation else {
                return (
                    nil as CheckedContinuation<Output, Error>?,
                    nil as UUID?
                )
            }
            completed = true
            self.continuation = nil
            task = nil
            let registration = cutoffRegistration
            cutoffRegistration = nil
            return (continuation, registration)
        }
        if let registration = completion.1 {
            entryLatch.unregisterSynchronousEntryCutoff(
                registration
            )
        }
        completion.0?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<Output, Error>) {
        let completion = lock.withLock {
            guard !completed, let continuation else {
                return (
                    nil as CheckedContinuation<Output, Error>?,
                    nil as UUID?
                )
            }
            completed = true
            self.continuation = nil
            task = nil
            let registration = cutoffRegistration
            cutoffRegistration = nil
            return (continuation, registration)
        }
        if let registration = completion.1 {
            entryLatch.unregisterSynchronousEntryCutoff(
                registration
            )
        }
        guard let continuation = completion.0 else { return }
        continuation.resume(with: result)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class AceLicense: ObservableObject {

    static let shared = AceLicense()

    @Published private(set) var state: AceLicenseState = .unknown {
        didSet {
            AceEntitlementRuntimeAdmissionGate.shared.publish(state)
            let observers = Array(entitlementStateObservers.values)
            for observer in observers {
                observer(state)
            }
            scheduleExactLeaseExpiryBoundary()
            if AceEntitlementAdmissionPolicy.runtimeTransition(
                from: oldValue,
                to: state
            ) == .openNewPremiumAdmission {
                let completions = deviceAuthorizationCompletionHandlers
                deviceAuthorizationCompletionHandlers.removeAll()
                NotificationCenter.default.post(
                    name: .aceEntitlementDidBecomeUsable,
                    object: self
                )
                for completion in completions {
                    completion()
                }
            }
        }
    }

    @Published private(set) var deviceAuthorizationState:
        AceDeviceAuthorizationState = .idle {
        didSet {
            switch deviceAuthorizationState {
            case .starting, .checkingLegacyKey:
                if deviceAuthorizationBusySince == nil {
                    deviceAuthorizationBusySince = Date()
                }
            case .idle, .awaitingApproval, .linked, .failed, .finishing:
                // .finishing carries no wedge clock: the acknowledgement has
                // its own bounded HTTP timeout and renders an actionable
                // retry state on deferral.
                deviceAuthorizationBusySince = nil
            }
        }
    }

    /// When the busy states entered. A network stall or lost task can leave the
    /// flow parked in .starting/.checkingLegacyKey forever, which in Build 61
    /// left "Link this Mac" permanently disabled with no recovery. After this
    /// window, another click restarts the flow instead of doing nothing.
    private var deviceAuthorizationBusySince: Date?
    private let deviceAuthorizationBusyRecoveryInterval: TimeInterval = 20

    /// The gate the rest of the app asks. A live server-issued lease is the only
    /// usable state. A paying buyer remains uninterrupted while that lease is
    /// current; an unverified launch never becomes a temporary bypass.
    var allowsUse: Bool {
        admits(.premiumRuntimeStartup)
    }

    func admits(
        _ surface: AceEntitlementSurface,
        now: Date = Date()
    ) -> Bool {
        guard !InstallReadinessCoordinator.shared.nativeUpdateHandoffIsActive
                || AceEntitlementAdmissionPolicy.admitsDuringNativeUpdate(surface) else { return false }
        return AceEntitlementAdmissionPolicy.admits(
            surface,
            state: state,
            now: now
        )
    }

    private let activateURL = URL(string: "https://ace-bl.tech/api/ace/activate")!
    private let deviceAuthorizationStartURL = URL(
        string: "https://ace-bl.tech/api/ace/device/start"
    )!
    private let deviceAuthorizationStatusURL = URL(
        string: "https://ace-bl.tech/api/ace/device/status"
    )!
    private let deviceAuthorizationAcknowledgeURL = URL(
        string: "https://ace-bl.tech/api/ace/device/ack"
    )!
    @Published private(set) var purchaseRecoveryStatus: String?
    @Published private(set) var purchaseRecoveryStatusIsFailure = false
    private var purchaseRecoveryTask: Task<Void, Never>?

    private let keyDefaultsKey = "aceLicenseKey"
    /// Builds before authenticated lease storage used these mutable defaults.
    /// They are migration debris only and are deleted before every boot choice.
    private let legacyLeaseExpiryDefaultsKey = "aceLicenseLeaseExpiry"
    private let legacyLeaseKeyDefaultsKey = "aceLicenseLeaseKeyV1"
    private let trialEndsAtDefaultsKey = "aceTrialEndsAtV1"

    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshStatus: String?
    private var renewalObservers: [NSObjectProtocol] = []
    private var renewalPathMonitor: NWPathMonitor?
    private var lastNetworkWasOnline: Bool?
    private var lastRefreshAttempt: Date?

    private var renewalTimer: Timer?
    private var leaseExpiryTimer: Timer?
    private var lifecycleStarted = false
    private var entitlementStateObservers:
        [UUID: @MainActor (AceLicenseState) -> Void] = [:]
    private var deviceAuthorizationTask: Task<Void, Never>?
    private var activeDeviceAuthorizationSession:
        AceDeviceAuthorizationSession?
    private var deviceAuthorizationCompletionHandlers: [() -> Void] = []
    private var keyEntryPresentationTask: Task<Void, Never>?

    private init() {}

    /// Existing work must be torn down in the same MainActor turn that applies
    /// a server refusal. Combine remains available for presentation, but the
    /// premium runtime consumes this synchronous observer boundary.
    @discardableResult
    func addSynchronousEntitlementObserver(
        _ observer: @escaping @MainActor (AceLicenseState) -> Void
    ) -> UUID {
        let identifier = UUID()
        entitlementStateObservers[identifier] = observer
        return identifier
    }

    func removeSynchronousEntitlementObserver(_ identifier: UUID) {
        entitlementStateObservers.removeValue(forKey: identifier)
    }

    // MARK: - Stored state

    /// The buyer's key. UserDefaults rather than the Keychain on purpose: a key
    /// is not a secret worth a Keychain prompt — it is printed on their account
    /// page and emailed to them. Keychain access here would only add a consent
    /// dialog to first run for no security we actually gain, since the server,
    /// not the client, decides what the key is worth.
    var storedKey: String? {
        get {
            if let credentialKey = try? PromptFreeCredentialStore.shared
                    .load()
                    .licenseToken,
               let normalized = AceLicensePolicy.normalizedKey(
                   credentialKey
               ) {
                return normalized
            }
            return AceLicensePolicy.normalizedKey(
                UserDefaults.standard.string(forKey: keyDefaultsKey)
            )
        }
        set {
            UserDefaults.standard.set(
                AceLicensePolicy.normalizedKey(newValue) ?? "",
                forKey: keyDefaultsKey
            )
        }
    }

    private struct StoredLeaseSnapshot {
        let expiry: Date?
        let key: String?
        let brainRoute: AceBrainRoute?
    }

    /// The local document is only a cache. Offline admission opens exclusively
    /// after the pinned server signature and every key/device/route/time claim
    /// validate again for this exact process.
    private func loadStoredLease(now: Date = Date()) -> StoredLeaseSnapshot {
        do {
            guard let normalizedKey = storedKey else {
                return StoredLeaseSnapshot(
                    expiry: nil,
                    key: nil,
                    brainRoute: nil
                )
            }
            let document = try PromptFreeCredentialStore.shared.load()
            guard let keyId = document.signedLicenseLeaseKeyId,
                  let payload = document.signedLicenseLeasePayload,
                  let signature = document.signedLicenseLeaseSignature,
                  let claims = AceSignedLeasePolicy.verify(
                      AceSignedLeaseEnvelope(
                          keyId: keyId,
                          payload: payload,
                          signature: signature
                      ),
                      expectedLicenseKey: normalizedKey,
                      expectedDeviceIdentifier: deviceIdentifier,
                      now: now
                  ),
                  let brainRoute = AceBrainRoute(
                      rawValue: claims.brainRoute
                  ) else {
                return StoredLeaseSnapshot(
                    expiry: nil,
                    key: nil,
                    brainRoute: nil
                )
            }
            return StoredLeaseSnapshot(
                expiry: Date(
                    timeIntervalSince1970:
                        Double(claims.expiresAt) / 1_000
                ),
                key: normalizedKey,
                brainRoute: brainRoute
            )
        } catch {
            LifecycleLog.append(
                "LICENSE authenticated lease read failed — online verification required"
            )
            return StoredLeaseSnapshot(
                expiry: nil,
                key: nil,
                brainRoute: nil
            )
        }
    }

    /// Lease, bound key, and hosted credential commit as one authenticated
    /// document. State is never opened unless this transaction succeeds.
    @discardableResult
    private func storeServerCredentialState(
        licenseKey: String?,
        signedLease: AceSignedLeaseEnvelope?,
        hostedBrainToken: String?
    ) -> Bool {
        do {
            try PromptFreeCredentialStore.shared.update {
                $0.licenseToken = licenseKey
                $0.signedLicenseLeaseKeyId = signedLease?.keyId
                $0.signedLicenseLeasePayload = signedLease?.payload
                $0.signedLicenseLeaseSignature = signedLease?.signature
                $0.hostedBrainToken = hostedBrainToken
            }
            return true
        } catch {
            LifecycleLog.append(
                "LICENSE authenticated credential write failed"
            )
            CompanionAppDelegate.reportCredentialStoreFailure(error)
            return false
        }
    }

    private(set) var trialEndsAt: Date? {
        get {
            let seconds = UserDefaults.standard.double(
                forKey: trialEndsAtDefaultsKey
            )
            return seconds > 0
                ? Date(timeIntervalSince1970: seconds)
                : nil
        }
        set {
            UserDefaults.standard.set(
                newValue?.timeIntervalSince1970 ?? 0,
                forKey: trialEndsAtDefaultsKey
            )
        }
    }

    /// The hosted-brain bearer token lives in Ace's prompt-free, mode-0600
    /// credential document. Legacy Keychain items are deliberately ignored:
    /// reading, migrating, or deleting them could invoke SecurityAgent.
    private var storedBrainToken: String? {
        do {
            return try PromptFreeCredentialStore.shared
                .load()
                .hostedBrainToken
        } catch {
            LifecycleLog.append(
                "BRAIN credential file read failed"
            )
            return nil
        }
    }

    /// This Mac, stably, across relaunches and reinstalls. The IOKit platform
    /// UUID is the same value Apple uses to identify the machine. Stability is the
    /// whole point: one key covers ONE Mac (founder ruling 2026-07-29), so an
    /// identifier that changed on reinstall would burn the buyer's only slot and
    /// lock them out of their own purchase.
    private var deviceIdentifier: String {
        let matching = IOServiceMatching("IOPlatformExpertDevice")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        defer { if service != 0 { IOObjectRelease(service) } }
        guard service != 0,
              let cf = IORegistryEntryCreateCFProperty(
                  service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
              )?.takeRetainedValue() as? String
        else {
            // No platform UUID should be impossible, but a hard failure here
            // would lock the buyer out of their own purchase. Fall back to a
            // per-install identifier: worse for device counting, never a lockout.
            let fallbackKey = "aceLicenseFallbackDeviceId"
            if let existing = UserDefaults.standard.string(forKey: fallbackKey) { return existing }
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: fallbackKey)
            return generated
        }
        return cf
    }

    private var deviceName: String { Host.current().localizedName ?? "Mac" }

    /// Uses the existing purchase licence and device binding. Neither the key
    /// nor the buyer's private receipt URL is persisted in update artifacts.
    func nativeUpdateRequest(for release: AceValidatedPublicRelease) throws -> URLRequest {
        guard !StealthEntryLatch.shared.isRaised, let key = storedKey, !key.isEmpty else {
            throw AceNativeUpdateError.rejected("Enter the licence from your original purchase in Buyer Recovery, then try Update & Restart again.")
        }
        var request = URLRequest(url: URL(string: "https://ace-bl.tech/api/ace/update")!)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "key": key, "deviceId": deviceIdentifier, "deviceName": deviceName,
            "build": release.build, "sourceSha256": release.sourceSha256,
            "dmgSha256": release.dmgSha256,
        ])
        return request
    }

    var hostedBrainCredentials: HostedBrainCredentials? {
        guard AceBrainRoute.current == .founderHosted,
              allowsUse,
              let licenseKey = storedKey,
              let accessToken = storedBrainToken else {
            return nil
        }
        return HostedBrainCredentials(
            licenseKey: licenseKey,
            deviceIdentifier: deviceIdentifier,
            accessToken: accessToken
        )
    }

    // MARK: - Lifecycle

    /// Restores only local server-issued truth. This is intentionally safe
    /// before dashboard-host dispatch: it performs no network/UI work and does
    /// not construct any premium runtime.
    func restoreLocalAdmissionForLaunch() {
        let now = Date()
        let storedLease = loadStoredLease(now: now)
        let rawStoredKey = storedKey
        switch AceLicensePolicy.bootDecision(
            storedKey: rawStoredKey,
            leaseExpiry: storedLease.expiry,
            leaseKey: storedLease.key,
            now: now
        ) {
        case .needsKey:
            state = .needsKey
        case .licensed(_, let expiry):
            guard let brainRoute = storedLease.brainRoute else {
                state = .requiresOnlineVerification(
                    message: Self.onlineVerificationRequiredMessage
                )
                return
            }
            AceBrainRoute.current = brainRoute
            if AceDeviceLinkTransactionStore
                .loadAcknowledgementPending() != nil,
               !deliveryAttestationIsDurable {
                // The unfinished piece here is the WEBSITE's delivery record,
                // not the entitlement: the lease below is server-signed and
                // already verified. Withholding `.licensed` for it locked out
                // paying customers — approve in the browser, have the follow-up
                // `/device/ack` POST miss (502, sleep, Wi-Fi drop), then open
                // Ace offline the next morning and be told "Ace needs to verify
                // this key once… try the key again" with no key to type. The
                // hold also protected nothing: `refresh()` publishes `.licensed`
                // from this same lease with no attestation check at all, so it
                // only ever bit the offline customer. Keep the pending delivery
                // visible in the device-link phase and let the retry finish it.
                deviceAuthorizationState = .finishing(
                    message: Self.deliveryVerificationPendingMessage
                )
            }
            state = .licensed(until: expiry)
        case .requiresOnlineVerification(let normalizedKey):
            _ = normalizedKey
            state = .requiresOnlineVerification(
                message: Self.onlineVerificationRequiredMessage
            )
        }
    }

    /// Called once at launch after the private support boundary is safe.
    /// Restores the last good lease immediately, normalizes stale credentials,
    /// then refreshes in the background and re-checks daily.
    func start() {
        guard !lifecycleStarted else { return }
        lifecycleStarted = true
        UserDefaults.standard.removeObject(
            forKey: legacyLeaseExpiryDefaultsKey
        )
        UserDefaults.standard.removeObject(
            forKey: legacyLeaseKeyDefaultsKey
        )
        restoreLocalAdmissionForLaunch()

        let storedLease = loadStoredLease()
        let rawStoredKey = storedKey
        switch AceLicensePolicy.bootDecision(
            storedKey: rawStoredKey,
            leaseExpiry: storedLease.expiry,
            leaseKey: storedLease.key,
            now: Date()
        ) {
        case .needsKey:
            storedKey = nil
            storeServerCredentialState(
                licenseKey: nil,
                signedLease: nil,
                hostedBrainToken: nil
            )
            trialEndsAt = nil
            AceBrainRoute.reset()
            HostedBrainConnectionProof.invalidate()
        case .licensed(let normalizedKey, _):
            storedKey = normalizedKey
        case .requiresOnlineVerification(let normalizedKey):
            storedKey = normalizedKey
            storeServerCredentialState(
                licenseKey: normalizedKey,
                signedLease: nil,
                hostedBrainToken: nil
            )
            trialEndsAt = nil
            AceBrainRoute.reset()
            HostedBrainConnectionProof.invalidate()
        }
        LifecycleLog.append("LICENSE start state=\(describe(state))")

        resumePersistedDeviceLinkIfNeeded()
        retryPendingAcknowledgementIfNeeded()

        installRenewalObservers()
        Task { await refresh() }

        renewalTimer?.invalidate()
        renewalTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func installRenewalObservers() {
        guard renewalPathMonitor == nil else { return }
        renewalObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAfterLifecycleChange() }
        })
        renewalObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshAfterLifecycleChange() }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let isOnline = path.status == .satisfied
            Task { @MainActor in
                self?.handleConnectivityChange(isOnline: isOnline)
            }
        }
        renewalPathMonitor = monitor
        monitor.start(queue: DispatchQueue(label: "com.blacklabel.ace.licence-recovery"))
    }

    private func handleConnectivityChange(isOnline: Bool) {
        let wasOnline = lastNetworkWasOnline
        lastNetworkWasOnline = isOnline
        // Launch already refreshes. Only a real reconnect starts another check.
        guard wasOnline == false, isOnline else { return }
        refreshAfterLifecycleChange()
    }

    private func refreshAfterLifecycleChange() {
        guard mayCommitAsyncResult, storedKey != nil, !isRefreshing else { return }
        // Active-window notifications can be frequent. Locked customers must be
        // able to recover immediately; healthy leases need at most one per minute.
        guard !allowsUse
                || lastRefreshAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        Task { await refresh() }
    }

    private func scheduleExactLeaseExpiryBoundary() {
        leaseExpiryTimer?.invalidate()
        leaseExpiryTimer = nil
        guard case .licensed(let until) = state else { return }
        let interval = until.timeIntervalSinceNow
        guard interval > 0 else {
            state = .requiresOnlineVerification(
                message: Self.onlineVerificationRequiredMessage
            )
            return
        }
        leaseExpiryTimer = Timer.scheduledTimer(
            withTimeInterval: interval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      !self.allowsUse else { return }
                self.state = .requiresOnlineVerification(
                    message: Self.onlineVerificationRequiredMessage
                )
                self.reportToOwner()
                await self.refresh()
            }
        }
    }

    /// Re-checks the stored key with the server. Never downgrades a live lease
    /// because of a network error — only the SERVER may take access away.
    func refresh() async {
        guard mayCommitAsyncResult, !isRefreshing else { return }
        guard let key = storedKey else {
            refreshStatus = "Link this Mac with your original purchase account."
            state = .needsKey
            reportToOwner()
            return
        }
        isRefreshing = true
        refreshStatus = "Checking your existing Ace subscription…"
        lastRefreshAttempt = Date()
        defer { isRefreshing = false }
        let verdict = await contactServer(key: key)
        // URLSession cancellation and the process-wide visibility wall are both
        // commit barriers. A response that arrives after Stealth begins may not
        // alter a lease, present repair UI, or append a durable receipt. A new
        // linked/key account also retires this older account's response.
        guard mayCommitAsyncResult, storedKey == key else {
            refreshStatus = nil
            return
        }
        switch verdict {
        case .success(
            let expiry,
            let brainRoute,
            let brainToken,
            let serverTrialEndsAt,
            let signedLease
        ):
            guard storeServerCredentialState(
                licenseKey: key,
                signedLease: signedLease,
                hostedBrainToken: brainToken
            ) else {
                state = .requiresOnlineVerification(
                    message:
                        "Ace could not save this Mac's credential. "
                        + "Use Check or recover in the saved-credentials repair card, then try again."
                )
                refreshStatus = "Ace could not save this Mac's credential. Use Check or recover in the saved-credentials repair card, then select Check again."
                reportToOwner()
                return
            }
            refreshStatus = "Your Ace subscription is verified."
            trialEndsAt = serverTrialEndsAt
            AceBrainRoute.current = brainRoute
            state = .licensed(until: expiry)
            FirstRunFailureReporter.shared.converge(
                identifier: FirstRunFailure.licenseProblem(message: "").id,
                proof: .verifiedOperation("validated_license_lease")
            )
            LifecycleLog.append("LICENSE ok until \(expiry)")
        case .refused(let message):
            refreshStatus = message
            storeServerCredentialState(
                licenseKey: key,
                signedLease: nil,
                hostedBrainToken: nil
            )
            trialEndsAt = nil
            AceBrainRoute.reset()
            HostedBrainConnectionProof.invalidate()
            state = .refused(message: message)
            LifecycleLog.append("LICENSE refused")
            reportToOwner()
        case .invalidResponse:
            refreshStatus = Self.invalidVerificationResponseMessage
            // A malformed or unverifiable reply is not an authoritative refusal.
            // Retain the last signed lease until its own expiry.
            if !AceEntitlementAdmissionPolicy.hasCurrentEntitlement(state: state) {
                state = .requiresOnlineVerification(
                    message: Self.invalidVerificationResponseMessage
                )
                reportToOwner()
            }
        case .unreachable:
            refreshStatus = AceEntitlementAdmissionPolicy.hasCurrentEntitlement(state: state)
                ? "The licence service is unavailable. Your current verified access remains active until its lease expires."
                : Self.onlineVerificationRequiredMessage
            // A service failure preserves the verified lease. Whatever lease we hold
            // stands until it lapses on its own.
            let storedLease = loadStoredLease()
            LifecycleLog.append(
                "LICENSE server unreachable — keeping lease "
                    + (storedLease.expiry.map(String.init(describing:))
                        ?? "none")
            )
            if !AceEntitlementAdmissionPolicy.hasCurrentEntitlement(state: state) {
                state = .requiresOnlineVerification(
                    message: Self.onlineVerificationRequiredMessage
                )
                reportToOwner()
            }
        }
    }

    /// Stores a key the owner typed and immediately proves it. Returns the
    /// server's sentence on failure so the entry sheet can show it inline.
    func activate(key typed: String) async -> String? {
        guard mayCommitAsyncResult else {
            return "Unlock was paused while Private Mode is active."
        }
        guard let key = AceLicensePolicy.normalizedKey(typed) else {
            return "Enter the complete key in the form ACE-XXXX-XXXX-XXXX-XXXX."
        }
        let originalStoredKey = storedKey
        let verdict = await contactServer(key: key)
        guard mayCommitAsyncResult else {
            return "Unlock was paused while Private Mode is active."
        }
        guard storedKey == originalStoredKey else {
            return "The linked account changed while this key was being checked. Review the current account, then try again."
        }
        switch verdict {
        case .success(
            let expiry,
            let brainRoute,
            let brainToken,
            let serverTrialEndsAt,
            let signedLease
        ):
            guard storeServerCredentialState(
                licenseKey: key,
                signedLease: signedLease,
                hostedBrainToken: brainToken
            ) else {
                return "Ace could not save this Mac's credential. Use Check or recover in the saved-credentials repair card, then try again."
            }
            storedKey = key
            trialEndsAt = serverTrialEndsAt
            AceBrainRoute.current = brainRoute
            HostedBrainConnectionProof.invalidate()
            state = .licensed(until: expiry)
            FirstRunFailureReporter.shared.converge(
                identifier: FirstRunFailure.licenseProblem(message: "").id,
                proof: .verifiedOperation("validated_license_lease")
            )
            LifecycleLog.append("LICENSE activated until \(expiry)")
            return nil
        case .refused(let message):
            // A refusal for the key currently authorizing this process closes
            // every surface immediately. An unrelated rejected key never
            // replaces the saved account, including an expired/offline account
            // or one temporarily held by the updater.
            if storedKey == key {
                storeServerCredentialState(
                    licenseKey: key,
                    signedLease: nil,
                    hostedBrainToken: nil
                )
                trialEndsAt = nil
                AceBrainRoute.reset()
                HostedBrainConnectionProof.invalidate()
                state = .refused(message: message)
                reportToOwner()
            }
            return message
        case .invalidResponse:
            return Self.invalidVerificationResponseMessage
        case .unreachable:
            return "Couldn't reach the licence server. Check your connection and try again."
        }
    }

    // MARK: - Browser account linking

    /// Normal buyer recovery is account-first: the app names this Mac, opens a
    /// signed-in browser approval, and waits for the server-issued credential.
    /// Manual key entry remains available from that window for legacy buyers.
    @discardableResult
    func presentDeviceAuthorization(
        onActivated: (() -> Void)? = nil
    ) -> Bool {
        if allowsUse {
            onActivated?()
            return true
        }
        if case .linked = deviceAuthorizationState {
            // A prior link receipt is not authority after its lease expired or
            // the server refused it. Return to a linkable state so this owner
            // action always starts a fresh server transaction.
            cancelDeviceAuthorization()
        }
        if let onActivated {
            deviceAuthorizationCompletionHandlers.append(onActivated)
        }
        let linkWindowIsVisible =
            AceDeviceAuthorizationWindowController.shared.present()
        if !linkWindowIsVisible {
            deviceAuthorizationState = .failed(
                message:
                    "Ace couldn't open the linking window. Try again, or use a licence key instead."
            )
            return false
        }
        switch deviceAuthorizationState {
        case .idle, .failed:
            startDeviceAuthorization()
        case .starting, .checkingLegacyKey:
            // A busy state older than the recovery window is a wedge, not
            // progress — restart instead of ignoring the user's click.
            if let busySince = deviceAuthorizationBusySince,
               Date().timeIntervalSince(busySince)
                   > deviceAuthorizationBusyRecoveryInterval {
                cancelDeviceAuthorization()
                startDeviceAuthorization()
            }
        case .awaitingApproval:
            // The awaiting UI and the poller's liveness are separate facts. A
            // cancelled poll task (Stealth entry mid-cycle, task abort) left
            // Build 61 stuck on this screen forever while the website already
            // said "linked". A dead poller here means restart, not wait.
            if deviceAuthorizationTask == nil {
                cancelDeviceAuthorization()
                startDeviceAuthorization()
            }
        case .linked:
            assertionFailure("inactive authorization must not remain linked")
            cancelDeviceAuthorization()
            startDeviceAuthorization()
        case .finishing:
            // Delivery verification owns this phase. A dead task means the
            // launch retry never started — startDeviceAuthorization resumes
            // the pending acknowledgement rather than opening a new session.
            if deviceAuthorizationTask == nil {
                startDeviceAuthorization()
            }
        }
        if case .failed = deviceAuthorizationState { return false }
        return true
    }

    func startDeviceAuthorization() {
        guard mayCommitAsyncResult,
              deviceAuthorizationTask == nil else {
            return
        }
        if let pendingSession = pendingAcknowledgementForRetry() {
            // Gate on the PENDING SESSION, not on a global attestation flag.
            // `deviceLinkDeliveryAttestedAtMs` is written once and never
            // cleared anywhere, so it is a Mac-lifetime marker: on any re-link
            // (a buyer resubscribing after a refusal, or linking again after a
            // lapse) it was already true, this branch was skipped, and Try
            // Again — the button the UI tells them to press — discarded the
            // approval they had just completed and opened a brand-new browser
            // session instead. They approve, are told to press Try Again, and
            // are sent back to the browser, forever.
            //
            // The credential is already committed; Try Again means "finish
            // the delivery verification", never "start a new link session".
            pendingAcknowledgementSession = pendingSession
            deviceAuthorizationState = .finishing(
                message: Self.deliveryVerificationPendingMessage
            )
            deviceAuthorizationTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.acknowledgeDeviceAuthorization(pendingSession)
                self.deviceAuthorizationTask = nil
            }
            return
        }
        activeDeviceAuthorizationSession = nil
        deviceAuthorizationState = .starting
        deviceAuthorizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDeviceAuthorization()
            self.deviceAuthorizationTask = nil
        }
    }

    func cancelDeviceAuthorization() {
        deviceAuthorizationTask?.cancel()
        deviceAuthorizationTask = nil
        activeDeviceAuthorizationSession = nil
        guard mayCommitAsyncResult else { return }
        deviceAuthorizationState = .idle
    }

    /// Reopens only the server-validated URL for the active request and records
    /// the Workspace result in the visible state instead of dropping a failed
    /// click. The polling secret never enters this URL.
    @discardableResult
    func openDeviceAuthorizationPage() -> Bool {
        guard let session = activeDeviceAuthorizationSession else {
            deviceAuthorizationState = .failed(
                message:
                    "This link request is no longer active. Start again."
            )
            return false
        }
        let didOpen = openRecoveryURL(
            session.verificationURL,
            surface: .activation
        )
        deviceAuthorizationState = .awaitingApproval(
            userCode: session.userCode,
            verificationURL: session.verificationURL,
            expiresAt: session.expiresAt,
            message: didOpen
                ? "Ace requested the approval page in your default browser. Sign in, choose your Ace purchase, then select Approve and link this Mac. Ace will finish here automatically."
                : "Ace couldn't open your browser. Select Open approval page to try again, or use a licence key instead.",
            messageIsFailure: !didOpen
        )
        return didOpen
    }

    private func runDeviceAuthorization() async {
        let request = AceDeviceAuthorizationProtocol.makeStartRequest(
            endpoint: deviceAuthorizationStartURL,
            deviceIdentifier: deviceIdentifier,
            deviceName: deviceName
        )
        let startResult: AceDeviceAuthorizationStartVerdict
        do {
            let (data, response) =
                try await StealthURLSessionRequest().perform(request)
            guard mayCommitAsyncResult,
                  let httpResponse = response as? HTTPURLResponse else {
                return
            }
            startResult = AceDeviceAuthorizationProtocol.classifyStart(
                httpStatusCode: httpResponse.statusCode,
                data: data
            )
        } catch is CancellationError {
            return
        } catch {
            guard mayCommitAsyncResult else { return }
            deviceAuthorizationState = .failed(
                message:
                    "Ace couldn't reach the account server. Check your connection and try again, or use a licence key instead."
            )
            return
        }

        guard mayCommitAsyncResult else { return }
        switch startResult {
        case .ready(let session):
            activeDeviceAuthorizationSession = session
            if !AceDeviceLinkTransactionStore.save(session) {
                LifecycleLog.append(
                    "LICENSE device link persistence failed — a relaunch will not resume \(session.requestID)"
                )
            }
            deviceAuthorizationState = .awaitingApproval(
                userCode: session.userCode,
                verificationURL: session.verificationURL,
                expiresAt: session.expiresAt,
                message: "Opening your secure Ace account approval…",
                messageIsFailure: false
            )
            _ = openDeviceAuthorizationPage()
            await pollDeviceAuthorization(session)
        case .refused(let message):
            deviceAuthorizationState = .failed(message: message)
        case .retryable:
            deviceAuthorizationState = .failed(
                message:
                    "The account server is temporarily unavailable. Try again in a moment, or use a licence key instead."
            )
        case .invalidResponse:
            deviceAuthorizationState = .failed(
                message:
                    "The account server returned an invalid link response. Try again, or use a licence key instead."
            )
        }
    }

    /// A relaunch after a quit, crash, or Private Mode entry mid-link resumes
    /// the persisted transaction instead of stranding a website-approved
    /// purchase. One immediate status check claims an already-approved
    /// credential (the server retains approved requests beyond the pending
    /// window); a still-pending unexpired request re-enters the normal poll.
    private func resumePersistedDeviceLinkIfNeeded() {
        guard !allowsUse,
              deviceAuthorizationTask == nil,
              let session = AceDeviceLinkTransactionStore.load() else {
            return
        }
        // Past the server's approved-row retention there is nothing left to
        // claim; drop the stale transaction quietly.
        guard Date().timeIntervalSince(session.expiresAt) < 24 * 3600 else {
            AceDeviceLinkTransactionStore.clear()
            return
        }
        LifecycleLog.append(
            "LICENSE resuming persisted device link \(session.requestID)"
        )
        activeDeviceAuthorizationSession = session
        updateAwaitingApproval(
            session,
            message: "Finishing an earlier link request…",
            messageIsFailure: false
        )
        deviceAuthorizationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.resumeDeviceAuthorization(session)
            self.deviceAuthorizationTask = nil
        }
    }

    /// One immediate server status check, shared by launch resume and the
    /// poll loop's final look. Returns nil when the result may not be
    /// committed (Stealth, cancellation) or the server was unreachable.
    private func performSingleStatusCheck(
        _ session: AceDeviceAuthorizationSession
    ) async -> AceDeviceAuthorizationStatusVerdict? {
        let request = AceDeviceAuthorizationProtocol
            .makeStatusRequest(
                endpoint: deviceAuthorizationStatusURL,
                session: session
            )
        do {
            let (data, response) =
                try await StealthURLSessionRequest().perform(request)
            guard mayCommitAsyncResult,
                  let httpResponse = response as? HTTPURLResponse else {
                return nil
            }
            return AceDeviceAuthorizationProtocol.classifyStatus(
                httpStatusCode: httpResponse.statusCode,
                data: data
            )
        } catch {
            return nil
        }
    }

    private func resumeDeviceAuthorization(
        _ session: AceDeviceAuthorizationSession
    ) async {
        guard let statusResult = await performSingleStatusCheck(session) else {
            guard mayCommitAsyncResult else { return }
            // Offline at launch: keep the transaction for the next launch and
            // fall back to the normal poll while this process lives.
            await pollDeviceAuthorization(session)
            return
        }

        guard mayCommitAsyncResult else { return }
        switch statusResult {
        case .approved(let credential):
            applyApprovedDeviceCredential(credential, session: session)
        case .pending:
            await pollDeviceAuthorization(session)
        case .retryable, .invalidResponse:
            await pollDeviceAuthorization(session)
        case .expired, .invalid:
            // An old request that never completed is launch noise, not an
            // error the owner caused just now — reset quietly to a fresh
            // Link this Mac button.
            activeDeviceAuthorizationSession = nil
            AceDeviceLinkTransactionStore.clear()
            deviceAuthorizationState = .idle
        }
    }

    private func pollDeviceAuthorization(
        _ session: AceDeviceAuthorizationSession
    ) async {
        var intervalSeconds = session.intervalSeconds
        while mayCommitAsyncResult,
              !Task.isCancelled,
              Date() < session.expiresAt {
            do {
                try await Task.sleep(
                    for: .seconds(intervalSeconds)
                )
            } catch {
                return
            }
            guard mayCommitAsyncResult,
                  activeDeviceAuthorizationSession?.requestID
                    == session.requestID else {
                return
            }

            let request = AceDeviceAuthorizationProtocol
                .makeStatusRequest(
                    endpoint: deviceAuthorizationStatusURL,
                    session: session
                )
            let statusResult: AceDeviceAuthorizationStatusVerdict
            do {
                let (data, response) =
                    try await StealthURLSessionRequest().perform(request)
                guard mayCommitAsyncResult,
                      let httpResponse = response as? HTTPURLResponse else {
                    return
                }
                statusResult =
                    AceDeviceAuthorizationProtocol.classifyStatus(
                        httpStatusCode: httpResponse.statusCode,
                        data: data
                    )
            } catch is CancellationError {
                return
            } catch {
                guard mayCommitAsyncResult else { return }
                updateAwaitingApproval(
                    session,
                    message:
                        "The account server isn't responding yet. Ace is still waiting and will retry automatically.",
                    messageIsFailure: true
                )
                continue
            }

            guard mayCommitAsyncResult else { return }
            switch statusResult {
            case .pending(_, let serverInterval):
                intervalSeconds = serverInterval
                updateAwaitingApproval(
                    session,
                    message:
                        "Waiting for approval in your browser. Ace will finish here automatically.",
                    messageIsFailure: false
                )
            case .approved(let credential):
                applyApprovedDeviceCredential(
                    credential,
                    session: session
                )
                return
            case .expired(let message), .invalid(let message):
                activeDeviceAuthorizationSession = nil
                AceDeviceLinkTransactionStore.clear()
                deviceAuthorizationState = .failed(message: message)
                return
            case .retryable:
                updateAwaitingApproval(
                    session,
                    message:
                        "The account server is busy. Ace is still waiting and will retry automatically.",
                    messageIsFailure: true
                )
            case .invalidResponse:
                activeDeviceAuthorizationSession = nil
                AceDeviceLinkTransactionStore.clear()
                deviceAuthorizationState = .failed(
                    message:
                        "The account server returned an invalid approval response. Start again, or use a licence key instead."
                )
                return
            }
        }

        guard mayCommitAsyncResult, !Task.isCancelled else { return }
        // The local clock passing expiresAt is not the server's verdict: an
        // approval that landed in the final polling interval would otherwise
        // strand (the server retains approved requests well past the pending
        // window). One last real status check decides.
        if let finalVerdict = await performSingleStatusCheck(session),
           case .approved(let credential) = finalVerdict {
            applyApprovedDeviceCredential(credential, session: session)
            return
        }
        guard mayCommitAsyncResult, !Task.isCancelled else { return }
        activeDeviceAuthorizationSession = nil
        AceDeviceLinkTransactionStore.clear()
        deviceAuthorizationState = .failed(
            message:
                "This link request expired before it was approved. Start again, or use a licence key instead."
        )
    }

    private func updateAwaitingApproval(
        _ session: AceDeviceAuthorizationSession,
        message: String,
        messageIsFailure: Bool
    ) {
        deviceAuthorizationState = .awaitingApproval(
            userCode: session.userCode,
            verificationURL: session.verificationURL,
            expiresAt: session.expiresAt,
            message: message,
            messageIsFailure: messageIsFailure
        )
    }

    private func applyApprovedDeviceCredential(
        _ credential: AceDeviceAuthorizationCredential,
        session: AceDeviceAuthorizationSession
    ) {
        let committed: AceCommittedDeviceCredential
        switch AceDeviceAuthorizationCredentialCommitter.commit(
            credential,
            expectedDeviceIdentifier: deviceIdentifier
        ) {
        case .success(let verifiedCredential):
            committed = verifiedCredential
        case .failure(.invalidCredential):
            activeDeviceAuthorizationSession = nil
            deviceAuthorizationState = .failed(
                message:
                    "Ace received an approval that did not verify for this Mac. Start again, or use a licence key instead."
            )
            return
        case .failure(.persistenceFailed):
            reportCredentialPersistenceFailure()
            activeDeviceAuthorizationSession = nil
            deviceAuthorizationState = .failed(
                message:
                    "Ace could not save this Mac's credential. Use Check or recover in the saved-credentials repair card, then try again."
            )
            return
        }

        // Compatibility projection for Build 45/60 installs. Authority already
        // committed atomically with the signed lease above.
        storedKey = committed.licenseKey
        trialEndsAt = committed.trialEndsAt
        AceBrainRoute.current = committed.brainRoute
        HostedBrainConnectionProof.invalidate()
        activeDeviceAuthorizationSession = nil
        AceDeviceLinkTransactionStore.clear()
        // The committer has verified and saved this Mac's signed lease. Local
        // entitlement must survive a lost website-delivery acknowledgement,
        // just as the launch and ordinary lease-refresh paths already do.
        // Linked/delivery proof still waits for a verified durable acknowledgement.
        let acknowledgementPhasePersisted =
            AceDeviceLinkTransactionStore.saveAcknowledgementPending(session)
        pendingAcknowledgementSession = session
        state = .licensed(until: committed.expiry)
        deviceAuthorizationState = .finishing(
            message: Self.deliveryVerificationPendingMessage
        )
        LifecycleLog.append(
            "LICENSE device credential committed until \(committed.expiry); "
                + "delivery verification pending"
                + (acknowledgementPhasePersisted ? "" : " (phase unpersisted)")
        )
        Task { @MainActor [weak self] in
            await self?.acknowledgeDeviceAuthorization(session)
        }
    }

    private func reportCredentialPersistenceFailure() {
        do {
            _ = try PromptFreeCredentialStore.shared.load()
            CompanionAppDelegate.reportCredentialStoreFailure(PromptFreeCredentialStoreError.atomicReplaceFailed)
        } catch {
            CompanionAppDelegate.reportCredentialStoreFailure(error)
        }
    }

    private var pendingAcknowledgementSession: AceDeviceAuthorizationSession?

    private func pendingAcknowledgementForRetry() -> AceDeviceAuthorizationSession? {
        guard let session = AceDeviceLinkTransactionStore.loadAcknowledgementPending() else { return nil }
        guard Date().timeIntervalSince(session.expiresAt) < 24 * 3600 else {
            AceDeviceLinkTransactionStore.clearAcknowledgementPending()
            pendingAcknowledgementSession = nil
            return nil
        }
        return session
    }

    private static let deliveryVerificationPendingMessage =
        "Approved. Verifying delivery with the Ace server…"

    private func persistDeliveryAttestation() -> Bool {
        do {
            try PromptFreeCredentialStore.shared.update {
                $0.deviceLinkDeliveryAttestedAtMs =
                    Date().timeIntervalSince1970 * 1000
            }
            return true
        } catch {
            return false
        }
    }

    private var deliveryAttestationIsDurable: Bool {
        ((try? PromptFreeCredentialStore.shared.load())?
            .deviceLinkDeliveryAttestedAtMs) != nil
    }

    /// Website-linked state and the strong reporter proof require the durable
    /// delivery attestation. This acknowledgement never extends a local lease.
    private func publishAttestedDeviceLink() {
        guard mayCommitAsyncResult else { return }
        let decision = DeviceLinkPublicationPolicy.decide(
            credentialCommitted: true,
            acknowledgementVerified: true,
            deliveryAttestedDurably: deliveryAttestationIsDurable
        )
        guard decision.mayPublishLinked else { return }
        pendingAcknowledgementSession = nil
        deviceAuthorizationState = .linked(
            message: allowsUse ? "This Mac is linked. Finish any remaining setup checks to start using Ace."
                : "This Mac is linked. Confirm your subscription online to use Ace."
        )
        if decision.mayEmitDeliveryAttestedProof, allowsUse {
            FirstRunFailureReporter.shared.converge(
                identifier: FirstRunFailure.licenseProblem(message: "").id,
                proof: .verifiedOperation("device_delivery_attested")
            )
        }
        LifecycleLog.append(
            "LICENSE device delivery attested; linked published"
        )
    }

    /// A deferred/rejected acknowledgement keeps an actionable non-success
    /// state; it never erases the committed credential or the pending phase,
    /// and never publishes linked.
    private func publishDeliveryVerificationRetry() {
        guard mayCommitAsyncResult,
              case .finishing = deviceAuthorizationState else { return }
        deviceAuthorizationState = .failed(
            message: allowsUse
                ? "Ace access is active. Website delivery confirmation is still pending; choose Try Again to finish that confirmation."
                : "This Mac is approved, but delivery is not verified yet. Choose Try Again to finish, then confirm subscription access."
        )
    }

    private func acknowledgeDeviceAuthorization(
        _ session: AceDeviceAuthorizationSession
    ) async {
        let expectedLicenseKey = storedKey
        guard pendingAcknowledgementSession == session else { return }
        let request = AceDeviceAuthorizationProtocol
            .makeAcknowledgeRequest(
                endpoint: deviceAuthorizationAcknowledgeURL,
                session: session
            )
        do {
            let (data, response) =
                try await StealthURLSessionRequest().perform(request)
            guard mayCommitAsyncResult,
                  pendingAcknowledgementSession == session,
                  storedKey == expectedLicenseKey,
                  let httpResponse = response as? HTTPURLResponse else {
                return
            }
            if AceDeviceAuthorizationProtocol.isAcknowledged(
                httpStatusCode: httpResponse.statusCode,
                data: data
            ) {
                if persistDeliveryAttestation() {
                    AceDeviceLinkTransactionStore.clearAcknowledgementPending()
                    LifecycleLog.append(
                        "LICENSE device authorization acknowledged; delivery attested"
                    )
                    publishAttestedDeviceLink()
                } else {
                    LifecycleLog.append(
                        "LICENSE delivery attestation persistence failed"
                    )
                    publishDeliveryVerificationRetry()
                }
            } else {
                LifecycleLog.append(
                    "LICENSE device authorization acknowledgement deferred"
                )
                publishDeliveryVerificationRetry()
            }
        } catch {
            guard mayCommitAsyncResult, pendingAcknowledgementSession == session,
                  storedKey == expectedLicenseKey else { return }
            // Local activation already succeeded, but the website only calls
            // this Mac linked once the server records delivery — so a lost
            // acknowledgement persists (ack-pending file) and retries on the
            // next launch instead of stranding the account page on
            // "waiting for your Mac".
            LifecycleLog.append(
                "LICENSE device authorization acknowledgement deferred"
            )
            publishDeliveryVerificationRetry()
        }
    }

    /// Launch-time repair for an acknowledgement that never landed: the local
    /// credential is committed, the website still shows approved-awaiting-Mac,
    /// and only this retry can converge them. One attempt now, one more after
    /// a minute; the pending file survives until the server confirms.
    private func retryPendingAcknowledgementIfNeeded() {
        guard let pendingSession = pendingAcknowledgementForRetry() else { return }
        pendingAcknowledgementSession = pendingSession
        LifecycleLog.append(
            "LICENSE retrying deferred acknowledgement \(pendingSession.requestID)"
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.acknowledgeDeviceAuthorization(pendingSession)
            guard AceDeviceLinkTransactionStore
                .loadAcknowledgementPending() != nil else { return }
            try? await Task.sleep(for: .seconds(60))
            guard self.mayCommitAsyncResult else { return }
            await self.acknowledgeDeviceAuthorization(pendingSession)
        }
    }

    // MARK: - Network

    private func contactServer(key: String) async -> AceLicenseServerVerdict {
        var request = URLRequest(url: activateURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15
        let body: [String: String] = [
            "key": key,
            "deviceId": deviceIdentifier,
            "deviceName": deviceName,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) =
                try await StealthURLSessionRequest().perform(request)
            guard mayCommitAsyncResult else {
                return .unreachable
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unreachable
            }
            return AceLicenseServerResponsePolicy.classify(
                httpStatusCode: httpResponse.statusCode,
                data: data,
                expectedLicenseKey: key,
                expectedDeviceIdentifier: deviceIdentifier,
                now: Date()
            )
        } catch {
            return .unreachable
        }
    }

    // MARK: - Telling the owner

    private func reportToOwner() {
        guard mayCommitAsyncResult else { return }
        let message: String
        switch state {
        case .needsKey:
            message = "Link this Mac with the Ace account that owns your purchase. You can still use an older licence key if needed."
        case .requiresOnlineVerification(let verificationMessage):
            message = verificationMessage
        case .refused(let serverMessage):
            message = serverMessage
        default:
            return
        }
        // NEVER as an interrupting modal: the locked menu-bar panel always
        // shows this exact truth with the full recovery controls, and a
        // modal session eats every click aimed at that panel (proven live —
        // worksWhenModal does not survive the 25ms runModalSession pump).
        // Build 61 shipped with this alert covering a fresh locked panel,
        // and every button appeared dead for as long as it stayed open.
        FirstRunFailureReporter.shared.report(
            .licenseProblem(message: message),
            interrupt: false,
            repairRevision: "device-authorization-v1",
            verifiedRepair: { [weak self] in
                guard let self else {
                    return .failed(
                        PermissionRepairFailure(
                            code: "license.owner_released",
                            message: "The account-link controller is no longer available."
                        )
                    )
                }
                self.presentDeviceAuthorization()
                return await PermissionRepairObservation.wait(
                    // The browser approval can last 30 minutes, plus request/commit time.
                    maximumPollCount: 19_200
                ) {
                    switch self.deviceAuthorizationState {
                    case .linked:
                        // .linked is published only after the durable server
                        // delivery attestation — the strong proof is real now.
                        return .succeeded(
                            .verifiedOperation("device_delivery_attested")
                        )
                    case .finishing:
                        return nil
                    case let .failed(message):
                        return .failed(
                            PermissionRepairFailure(
                                code: "license.device_link_failed",
                                message: message
                            )
                        )
                    case .idle:
                        return .failed(
                            PermissionRepairFailure(
                                code: "license.device_link_cancelled",
                                message: "Account linking ended without a server-approved device."
                            )
                        )
                    case .starting, .checkingLegacyKey, .awaitingApproval:
                        return nil
                    }
                }
            }
        )
    }

    /// Legacy recovery for Build 45/60 keys. The normal buyer path is browser
    /// linking above. This alert uses the shared cancellable modal-session
    /// presenter so it remains clickable in Ace's LSUIElement process.
    func presentKeyEntry(
        prefilledError: String? = nil,
        onActivated: (() -> Void)? = nil
    ) {
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised else {
            LifecycleLog.append("LICENSE key entry deferred (stealth)")
            return
        }
        guard keyEntryPresentationTask == nil else { return }
        keyEntryPresentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runLegacyKeyEntry(
                initialError: prefilledError,
                onActivated: onActivated
            )
            self.keyEntryPresentationTask = nil
        }
    }

    private func runLegacyKeyEntry(
        initialError: String?,
        onActivated: (() -> Void)?
    ) async {
        var visibleError = initialError
        var enteredKey = storedKey ?? ""
        while mayCommitAsyncResult {
            let alert = NSAlert()
            alert.alertStyle = visibleError == nil
                ? .informational
                : .warning
            alert.messageText = "Use a licence key"
            alert.informativeText =
                (visibleError.map { $0 + "\n\n" } ?? "")
                + "Enter the licence key from your original purchase receipt or account. One key covers one Mac."

            let field = NSTextField(
                frame: NSRect(x: 0, y: 0, width: 300, height: 24)
            )
            field.placeholderString = "ACE-XXXX-XXXX-XXXX-XXXX"
            field.stringValue = enteredKey
            field.setAccessibilityIdentifier("ace.license-key.field")
            alert.accessoryView = field

            alert.addButton(withTitle: "Unlock")
                .setAccessibilityIdentifier("ace.license-key.submit")
            alert.addButton(withTitle: "Open Account Page")
                .setAccessibilityIdentifier("ace.license-key.open-account")
            alert.addButton(withTitle: "Later")
                .setAccessibilityIdentifier("ace.license-key.later")
            alert.window.initialFirstResponder = field

            guard let choice =
                    await SetupVisibleEffectAdmission
                        .runModalIfAdmitted(alert),
                  mayCommitAsyncResult else {
                return
            }
            enteredKey = field.stringValue
            if StealthModalActionPolicy.accepts(
                choice,
                expected: .alertFirstButtonReturn,
                effectsAreAllowed: mayCommitAsyncResult
            ) {
                deviceAuthorizationState = .checkingLegacyKey
                if let failure = await activate(key: field.stringValue) {
                    guard mayCommitAsyncResult else { return }
                    visibleError = failure
                    deviceAuthorizationState = .failed(message: failure)
                    continue
                }
                deviceAuthorizationState = .linked(
                    message: "This Mac is linked. Finish any remaining setup checks to start using Ace."
                )
                onActivated?()
                return
            }
            if StealthModalActionPolicy.accepts(
                choice,
                expected: .alertSecondButtonReturn,
                effectsAreAllowed: mayCommitAsyncResult
            ) {
                guard openAccountPage() else {
                    visibleError =
                        purchaseRecoveryStatus
                        ?? "Ace couldn't open the account page. Check your default browser and try again."
                    deviceAuthorizationState = .failed(
                        message: visibleError ?? "Ace couldn't open the account page."
                    )
                    continue
                }
                deviceAuthorizationState = .idle
                return
            }
            if !allowsUse {
                deviceAuthorizationState = .idle
            }
            return
        }
    }

    @discardableResult
    func openAccountPage(completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
        beginPurchaseRecovery(.account, surface: .account, completion: completion)
    }

    @discardableResult
    func openSubscriptionCancellation(completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
        beginPurchaseRecovery(.billing, surface: .subscriptionCancellation, completion: completion)
    }

    @discardableResult
    func contactSupport(completion: @escaping (Bool) -> Void = { _ in }) -> Bool {
        beginPurchaseRecovery(.support, surface: .support, completion: completion)
    }

    func cancelPurchaseRecovery() {
        purchaseRecoveryTask?.cancel()
    }

    /// A true return means resolution started. Only the completion reports a
    /// browser handoff, and neither claims the browser loaded the destination.
    private func beginPurchaseRecovery(
        _ action: AcePurchaseRecoveryAction,
        surface: AceEntitlementSurface,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard admits(surface), mayCommitAsyncResult else { completion(false); return false }
        guard purchaseRecoveryTask == nil else { completion(false); return false }
        guard let key = storedKey else {
            purchaseRecoveryStatus = AcePurchaseRecoveryError.missingLicence.localizedDescription
            purchaseRecoveryStatusIsFailure = true
            completion(false)
            return false
        }
        let device = deviceIdentifier
        purchaseRecoveryStatus = "Finding your original purchase…"
        purchaseRecoveryStatusIsFailure = false
        purchaseRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { completion(false); return }
            defer { self.purchaseRecoveryTask = nil }
            do {
                let destination = try await AcePurchaseRecovery.resolve(
                    action: action, key: key, deviceIdentifier: device
                )
                guard self.mayCommitAsyncResult, self.storedKey == key,
                      self.deviceIdentifier == device else {
                    if !StealthEntryLatch.shared.isRaised {
                        self.purchaseRecoveryStatus = Task.isCancelled
                            ? "Purchase recovery was cancelled."
                            : "The linked purchase changed. Open its recovery page again."
                        self.purchaseRecoveryStatusIsFailure = true
                    }
                    completion(false)
                    return
                }
                let opened = self.openRecoveryURL(destination, surface: surface)
                self.purchaseRecoveryStatus = opened
                    ? "The original purchase page was requested in your browser. Page loading is not yet verified."
                    : "The browser handoff did not start. Use your original purchase receipt or email hello@ace-bl.tech."
                self.purchaseRecoveryStatusIsFailure = !opened
                completion(opened)
            } catch {
                if !StealthEntryLatch.shared.isRaised {
                    self.purchaseRecoveryStatus = Task.isCancelled
                        ? "Purchase recovery was cancelled."
                        : (error as? AcePurchaseRecoveryError ?? .unavailable).localizedDescription
                    self.purchaseRecoveryStatusIsFailure = true
                }
                completion(false)
            }
        }
        return true
    }

    private func openRecoveryURL(
        _ url: URL,
        surface: AceEntitlementSurface
    ) -> Bool {
        guard admits(surface),
              !StealthVisibilityGate.shared.isActive else {
            return false
        }
        // Decide under the latch; open OUTSIDE it. `performUnlessRaised` holds a
        // non-recursive NSLock across its closure, so running
        // `NSWorkspace.open` there put a runloop-spinning LaunchServices call
        // under that lock — any re-entry into the latch on this thread wedged
        // the main thread permanently, and "Open Account Page" never opened
        // anything. This is the locked panel's only route back to an account, so
        // a buyer who could not unlock also could not reach the page that fixes
        // it. The admission decision is still atomic; only the effect moved out.
        let openIsAdmitted = StealthEntryLatch.shared.performUnlessRaised {
            !StealthVisibilityGate.shared.isActive
        } ?? false
        guard openIsAdmitted else { return false }
        return AceRecoveryURLHandoff.open(url)
    }

    private func describe(_ value: AceLicenseState) -> String {
        switch value {
        case .unknown: return "unknown"
        case .licensed(let until): return "licensed until \(until)"
        case .needsKey: return "needsKey"
        case .requiresOnlineVerification: return "requiresOnlineVerification"
        case .refused: return "refused"
        }
    }

    /// Every async server result is untrusted until this main-actor commit
    /// latch is re-checked. Stealth can rise while URLSession is suspended, and
    /// task cancellation may race the response callback.
    private var mayCommitAsyncResult: Bool {
        !Task.isCancelled
            && !StealthVisibilityGate.shared.isActive
            && !StealthEntryLatch.shared.isRaised
    }

    private static let onlineVerificationRequiredMessage =
        "Ace needs to confirm your subscription online. Connect to the internet "
        + "and select Check again to verify the account already linked to this Mac. "
        + "After verification, Ace can work offline for up to seven days."

    private static let invalidVerificationResponseMessage =
        "The licence server replied, but its signed approval could not be verified for this Mac. "
        + "Check that this Mac's date and time are correct, then select Check again. "
        + "If this continues, contact support using your original purchase receipt."
}
#endif // circuit-convert
