#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  AceUpdateCheck.swift
//
//  A shipped Ace has no way to learn that a newer build exists: the app is a
//  one-time DMG download, and until 2026-07-28 nothing on the Mac ever asked.
//  This checker closes that loop against the storefront's release manifest
//  (/api/ace/version), which the release lane bumps alongside every R2 upload
//  — package_buyer.sh prints the reminder.
//
//  Identity note: build numbers are ordering, never identity. The public
//  manifest carries the receipt-backed source, DMG, executable, and capability
//  fields, while the sealed app carries its source/capability identity. That
//  lets a same-build replacement remain visible instead of silently treating
//  reused build numbers as current.
//
//  Explicit Update & Restart uses the existing licence, verifies the exact
//  package and Developer ID, stages a rollback copy, and proves the new runtime.
//

#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class AceUpdateCheck {
    static let shared = AceUpdateCheck()

    /// The manifest the storefront publishes for exactly this purpose. Public
    /// endpoint, no session — an update check must work before sign-in.
    private static let manifestURL = URL(string: "https://ace-bl.tech/api/ace/version")!
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var alertShowing = false
    private var initialCheckTask: Task<Void, Never>?
    private var manifestFetchTask: Task<Void, Never>?
    private var deferredRetryTask: Task<Void, Never>?
    private var fetchGeneration: UInt64 = 0
    private var lastInstalledIdentityFailure: AceInstalledIdentityField?
    private var lastRejectedManifestDigest: String?
    /// "Later" is a session-level dismissal. A same-build replacement remains
    /// visible again after the next launch, but foregrounding Ace repeatedly
    /// must not reopen the same modal while the owner is presenting or working.
    private var offeredReleaseIdentityThisLaunch: String?

    private init() {}

    /// Called once from launch. First check is deferred well off the launch
    /// path (the intro tour and permission prompts outrank an update surface),
    /// then repeats hourly. Wake and foreground edges also fetch a fresh
    /// no-store manifest so every installed Mac converges on the same release.
    func beginPeriodicChecks() {
        guard timer == nil else { return }
        initialCheckTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            guard let self,
                  await self.waitUntilPresentationAllowed() else { return }
            self.initialCheckTask = nil
            self.checkNow()
        }
        let hourlyUpdateTimer = Timer(timeInterval: 60 * 60, repeats: true) { _ in
            Task { @MainActor in AceUpdateCheck.shared.checkNow() }
        }
        hourlyUpdateTimer.tolerance = 5 * 60
        RunLoop.main.add(hourlyUpdateTimer, forMode: .common)
        timer = hourlyUpdateTimer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AceUpdateCheck.shared.checkNow() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AceUpdateCheck.shared.checkNow() }
        }
    }

    /// One manifest fetch → at most one alert. Every failure path is silent:
    /// an offline Mac, a dead site, or a malformed manifest must never produce
    /// an error surface — the next hourly, wake or activation check tries again.
    func checkNow() {
        guard !alertShowing else { return }
        guard manifestFetchTask == nil else { return }
        guard !StealthVisibilityGate.shared.isActive else {
            scheduleDeferredRetry()
            return
        }
        // Never talk over first-run setup; the tour window owns the screen.
        guard !AceIntroWindowController.shared.isVisible else {
            scheduleDeferredRetry()
            return
        }
        let installedIdentity = Self.currentInstalledIdentity()
        if let failure = AceUpdateManifestPolicy.installedIdentityFailure(
            installedIdentity
        ) {
            if lastInstalledIdentityFailure != failure {
                LifecycleLog.append(
                    "UPDATE installed identity invalid field=\(failure.rawValue)"
                )
            }
            lastInstalledIdentityFailure = failure
            return
        }
        lastInstalledIdentityFailure = nil

        var request = URLRequest(url: Self.manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        fetchGeneration &+= 1
        let generation = fetchGeneration
        manifestFetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let responseTuple = await self.fetchManifestResponse(request)

            guard !Task.isCancelled,
                  self.fetchGeneration == generation else { return }

            // A result arriving behind either visibility wall is discarded, not
            // queued for presentation. Wait without mutating checker/UI/log
            // state, then perform a fresh fetch after the wall is down.
            if !self.presentationIsAllowed {
                guard await self.waitUntilPresentationAllowed(),
                      self.fetchGeneration == generation else { return }
                self.manifestFetchTask = nil
                self.checkNow()
                return
            }

            self.manifestFetchTask = nil
            guard let (data, response) = responseTuple,
                  (response as? HTTPURLResponse)?.statusCode == 200 else {
                return
            }
            guard self.presentationIsAllowed, !Task.isCancelled else { return }
            switch AceUpdateManifestPolicy.evaluate(
                installed: installedIdentity,
                manifestData: data
            ) {
            case .manifestUnavailable:
                let digest = SHA256.hash(data: data).description
                if self.lastRejectedManifestDigest != digest {
                    LifecycleLog.append("UPDATE manifest rejected: malformed or incompatible release identity")
                    self.lastRejectedManifestDigest = digest
                }
                return
            case .current:
                self.lastRejectedManifestDigest = nil
                return
            case let .installedIdentityInvalid(failure):
                if self.lastInstalledIdentityFailure != failure {
                    LifecycleLog.append(
                        "UPDATE installed identity invalid field=\(failure.rawValue)"
                    )
                }
                self.lastInstalledIdentityFailure = failure
            case let .update(remote):
                self.lastRejectedManifestDigest = nil
                self.offerIfUpdateAvailable(
                    remote: remote,
                    currentBuild: Int(installedIdentity.build ?? "") ?? 0
                )
            }
        }
    }

    /// Cancel the actual URLSession task promptly when Stealth rises. The
    /// caller still re-checks the presentation latch after this await, so both
    /// cancellation latency and a response race fail closed.
    private func fetchManifestResponse(
        _ request: URLRequest
    ) async -> (Data, URLResponse)? {
        do {
            return try await StealthURLSessionRequest().perform(request)
        } catch {
            return nil
        }
    }

    private func offerIfUpdateAvailable(
        remote: AceValidatedPublicRelease,
        currentBuild: Int
    ) {
        guard !StealthVisibilityGate.shared.isActive,
              !AceIntroWindowController.shared.isVisible else {
            scheduleDeferredRetry()
            return
        }
        guard !alertShowing else { return }
        guard offeredReleaseIdentityThisLaunch != remote.skippedIdentity else {
            return
        }

        LifecycleLog.append(
            "UPDATE-AVAILABLE remote=\(remote.build) local=\(currentBuild) "
            + "source=\(remote.sourceSha256.prefix(12))"
        )
        alertShowing = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.alertShowing = false }
            await self.presentUpdateOffer(
                remote: remote
            )
        }
    }

    /// Retained entry point for existing native command routes. Admission starts
    /// an observable update transaction; it is never an installation receipt.
    func openDownloadPageFromOwnerRequest(
        completion: ((AceNativeUpdateOutcome) -> Void)? = nil
    ) -> Bool {
        guard presentationIsAllowed else { return false }
        return AceNativeUpdate.shared.startFromOwnerRequest(completion: completion)
    }

    private func presentUpdateOffer(remote: AceValidatedPublicRelease) async {
        guard presentationIsAllowed, !Task.isCancelled else { return }
        let alert = NSAlert()
        alert.messageText = "Ace \(remote.version) (build \(remote.build)) is available"
        alert.informativeText = "Download with your existing licence, verify the signed app, and restart Ace. Your settings and provider logins are preserved."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Update & Restart")
            .setAccessibilityIdentifier("ace.update.install")
        alert.addButton(withTitle: "Later")
            .setAccessibilityIdentifier("ace.update.later")
        guard let choice = await SetupVisibleEffectAdmission.runModalIfAdmitted(alert),
              StealthModalActionPolicy.accepts(choice, expected: choice,
                effectsAreAllowed: presentationIsAllowed && !Task.isCancelled),
              choice == .alertFirstButtonReturn || choice == .alertSecondButtonReturn else { return }
        offeredReleaseIdentityThisLaunch = remote.skippedIdentity
        guard choice == .alertFirstButtonReturn else { return }
        _ = openDownloadPageFromOwnerRequest()
    }

    private func scheduleDeferredRetry() {
        guard deferredRetryTask == nil else { return }
        deferredRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return
            }
            guard let self,
                  await self.waitUntilPresentationAllowed() else { return }
            self.deferredRetryTask = nil
            self.checkNow()
        }
    }

    private var presentationIsAllowed: Bool {
        !Task.isCancelled
            && !StealthVisibilityGate.shared.isActive
            && !StealthEntryLatch.shared.isRaised
            && !AceIntroWindowController.shared.isVisible
    }

    /// Do not mutate retry/fetch/UI/log state while either visibility wall is
    /// raised. Sleeping tasks are cancellable and resume with a fresh check.
    private func waitUntilPresentationAllowed() async -> Bool {
        while !presentationIsAllowed {
            guard !Task.isCancelled else { return false }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    static func currentInstalledIdentity()
        -> AceInstalledReleaseIdentitySnapshot {
        let info = Bundle.main.infoDictionary ?? [:]
        return AceInstalledReleaseIdentitySnapshot(
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            sourceSha256: info["BLAppSourceSHA256"] as? String,
            includesQwen: info["BLIncludesQwen"] as? Bool,
            includesBackgroundHelper:
                info["BLIncludesBackgroundHelper"] as? Bool
        )
    }
}
#endif // circuit-convert
