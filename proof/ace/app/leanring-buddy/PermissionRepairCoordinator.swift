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
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import CircuitPortKit

enum PermissionKind: String, Equatable, Hashable, Sendable {
    case voice
    case microphone
    case speechRecognition
    case screenRecording
    case accessibility
    case screenContent
    case localMailAccess
    case appAutomation
}

enum PermissionSystemSettingsPane: String, Equatable, Sendable {
    case microphone
    case speechRecognition
    case dictation
    case screenRecording
    case accessibility
    case fullDiskAccess
    case automation
    case loginItems

    var stableSelectionIdentifier: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .speechRecognition: return "Privacy_SpeechRecognition"
        case .dictation: return "Dictation"
        case .screenRecording: return "Privacy_ScreenCapture"
        case .accessibility: return "Privacy_Accessibility"
        case .fullDiskAccess: return "Privacy_AllFiles"
        case .automation: return "Privacy_Automation"
        case .loginItems: return "LoginItems"
        }
    }

    var ownerFacingName: String {
        switch self {
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .dictation: return "Dictation"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .fullDiskAccess: return "Full Disk Access"
        case .automation: return "Automation"
        case .loginItems: return "Login Items"
        }
    }

    var paneIdentifier: String {
        resolvedPaneIdentifier(
            systemSettingsExtensionExists: FileManager.default.fileExists(
                atPath: systemSettingsExtensionPath
            )
        )
    }

    private var systemSettingsExtensionPath: String {
        switch self {
        case .microphone, .speechRecognition, .screenRecording,
             .accessibility, .fullDiskAccess, .automation:
            return "/System/Library/ExtensionKit/Extensions/SecurityPrivacyExtension.appex"
        case .dictation:
            return "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex"
        case .loginItems:
            return "/System/Library/ExtensionKit/Extensions/LoginItems.appex"
        }
    }

    func resolvedPaneIdentifier(
        systemSettingsExtensionExists: Bool
    ) -> String {
        switch self {
        case .microphone, .speechRecognition, .screenRecording,
             .accessibility, .fullDiskAccess, .automation:
            return systemSettingsExtensionExists
                ? "com.apple.settings.PrivacySecurity.extension"
                : "com.apple.preference.security"
        case .dictation:
            return systemSettingsExtensionExists
                ? "com.apple.Keyboard-Settings.extension"
                : "com.apple.preference.keyboard"
        case .loginItems:
            return systemSettingsExtensionExists
                ? "com.apple.LoginItems-Settings.extension"
                : "com.apple.LoginItems-Settings.extension"
        }
    }

    var deepLink: URL {
        resolvedDeepLink(
            systemSettingsExtensionExists: FileManager.default.fileExists(
                atPath: systemSettingsExtensionPath
            )
        )
    }

    func resolvedDeepLink(
        systemSettingsExtensionExists: Bool
    ) -> URL {
        let pane = resolvedPaneIdentifier(
            systemSettingsExtensionExists: systemSettingsExtensionExists
        )
        let anchor = self == .loginItems
            ? ""
            : "?" + stableSelectionIdentifier
        return URL(string: "x-apple.systempreferences:\(pane)\(anchor)")!
    }
}

enum PermissionRequestPresentationDestination: Equatable, Sendable {
    case alreadyGranted
    case systemPrompt
    case systemSettings
}

enum PermissionPromptFallbackPolicy {
    static func destination(
        hasPermissionNow: Bool,
        hasAttemptedSystemPrompt: Bool,
        settingsPane: PermissionSystemSettingsPane
    ) -> PermissionRequestPresentationDestination {
        if hasPermissionNow {
            return .alreadyGranted
        }
        if hasAttemptedSystemPrompt {
            _ = settingsPane
            return .systemSettings
        }
        return .systemPrompt
    }
}

protocol PermissionPromptAttemptStore: AnyObject {
    func hasAttempted(_ permission: PermissionKind) -> Bool
    @discardableResult func markAttempted(_ permission: PermissionKind) -> Bool
}

final class UserDefaultsPermissionPromptAttemptStore:
    PermissionPromptAttemptStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "com.learningbuddy.permissionPromptAttempt."
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func hasAttempted(_ permission: PermissionKind) -> Bool {
        let newKey = keyPrefix + permission.rawValue
        if defaults.bool(forKey: newKey) { return true }
        guard let legacyKey = legacyKey(for: permission),
              defaults.bool(forKey: legacyKey) else { return false }
        // Build 61-63 wrote separate names. Upgrade that durable evidence on
        // read so a previously denied buyer never gets a ghost first click.
        defaults.set(true, forKey: newKey)
        return true
    }

    @discardableResult
    func markAttempted(_ permission: PermissionKind) -> Bool {
        let key = keyPrefix + permission.rawValue
        defaults.set(true, forKey: key)
        guard defaults.synchronize(), defaults.bool(forKey: key) else {
            defaults.removeObject(forKey: key)
            return false
        }
        return true
    }

    private func legacyKey(for permission: PermissionKind) -> String? {
        switch permission {
        case .accessibility:
            return "com.learningbuddy.hasAttemptedAccessibilitySystemPrompt"
        case .screenRecording:
            return "com.learningbuddy.hasAttemptedScreenRecordingSystemPrompt"
        case .voice, .microphone, .speechRecognition, .screenContent,
             .localMailAccess, .appAutomation:
            return nil
        }
    }
}

enum PermissionPromptAdmission {
    static func invoke(
        store: PermissionPromptAttemptStore,
        permission: PermissionKind,
        commit: (_ effect: () -> Bool) -> Bool,
        prompt: () -> Void
    ) -> Bool {
        withoutActuallyEscaping(prompt) { escapablePrompt in
            commit {
                guard store.markAttempted(permission) else { return false }
                escapablePrompt()
                return true
            }
        }
    }
}

struct PermissionSettingsPaneSnapshot: Equatable, Sendable {
    let applicationBundleIdentifier: String
    /// Stable AX identifier/deep-link identity, never localized visible text.
    let selectedPaneIdentifier: String?
}

struct PermissionSettingsPaneObserver {
    let maximumPollCount: Int
    let pollDelayNanoseconds: UInt64
    let snapshot: @MainActor () async -> PermissionSettingsPaneSnapshot?
    var unavailableFailureCode = "settings.pane_not_observed"

    @MainActor
    func observe(
        _ pane: PermissionSystemSettingsPane
    ) async -> PermissionRepairResult {
        var lastWrongSelection: String?
        for _ in 0..<maximumPollCount {
            if let snapshot = await snapshot() {
                guard snapshot.applicationBundleIdentifier
                        == "com.apple.systempreferences" else {
                    return .failed(
                        PermissionRepairFailure(
                            code: "settings.noncanonical_application",
                            message: "The observed settings process was not the canonical com.apple.systempreferences application."
                        )
                    )
                }
                guard let selectedPaneIdentifier =
                        snapshot.selectedPaneIdentifier else {
                    return .failed(
                        PermissionRepairFailure(
                            code: unavailableFailureCode,
                            message:
                                "System Settings opened, but macOS did not expose a prompt-free way to verify the selected \(pane.ownerFacingName) pane. Finish the change there, then retry."
                        )
                    )
                }
                guard selectedPaneIdentifier
                        == pane.stableSelectionIdentifier else {
                    lastWrongSelection = selectedPaneIdentifier
                    if pollDelayNanoseconds > 0 {
                        try? await Task.sleep(
                            nanoseconds: pollDelayNanoseconds
                        )
                    } else {
                        await Task.yield()
                    }
                    continue
                }
                return .failed(
                    PermissionRepairFailure(
                        code: "settings.awaiting_owner.\(pane.rawValue)",
                        message:
                            "Opened \(pane.ownerFacingName) Settings and verified the selected pane. Finish the macOS change, then retry so Ace can read back the result."
                    )
                )
            }
            if pollDelayNanoseconds > 0 {
                try? await Task.sleep(
                    nanoseconds: pollDelayNanoseconds
                )
            } else {
                await Task.yield()
            }
        }
        if let lastWrongSelection {
            return .failed(
                PermissionRepairFailure(
                    code: "settings.selection_mismatch",
                    message:
                        "System Settings exposed selection \(lastWrongSelection), not the requested \(pane.stableSelectionIdentifier) pane."
                )
            )
        }
        return .failed(
            PermissionRepairFailure(
                code: "settings.application_not_observed",
                message:
                    "The canonical System Settings process did not become observable while opening the requested "
                    + pane.ownerFacingName
                    + " pane."
            )
        )
    }
}

struct PermissionRepairReadbackObserver {
    let maximumPollCount: Int
    let pollDelayNanoseconds: UInt64
    let readback: @MainActor () async -> Bool

    @MainActor
    func observe(
        permission: PermissionKind,
        timeoutMessage: String
    ) async -> PermissionRepairResult {
        for _ in 0..<maximumPollCount {
            if await readback() {
                return .succeeded(
                    .permissionReadback(permission: permission)
                )
            }
            if Task.isCancelled { break }
            if pollDelayNanoseconds > 0 {
                try? await Task.sleep(
                    nanoseconds: pollDelayNanoseconds
                )
            } else {
                await Task.yield()
            }
        }
        return .failed(
            PermissionRepairFailure(
                code: "\(permission.rawValue).readback_timeout",
                message: timeoutMessage
            )
        )
    }
}

struct PermissionRepairFailure: Error, Equatable, Sendable {
    let code: String
    let message: String
}

enum PermissionRepairProof: Equatable, Sendable {
    case permissionReadback(permission: PermissionKind)
    case screenCapture(width: Int, height: Int)
    case verifiedOperation(String)

    var code: String {
        switch self {
        case let .permissionReadback(permission):
            return "permission_readback.\(permission.rawValue)"
        case .screenCapture:
            return "screen_capture"
        case let .verifiedOperation(operation):
            return "operation.\(operation)"
        }
    }

    var ownerFacingDescription: String {
        switch self {
        case let .permissionReadback(permission):
            return "\(permission.ownerFacingName) access verified."
        case let .screenCapture(width, height):
            return "Screen capture verified (\(width)×\(height))."
        case let .verifiedOperation(operation):
            return "Verified \(operation.replacingOccurrences(of: "_", with: " "))."
        }
    }
}

private extension PermissionKind {
    var ownerFacingName: String {
        switch self {
        case .voice: return "Voice"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech Recognition"
        case .screenRecording: return "Screen Recording"
        case .accessibility: return "Accessibility"
        case .screenContent: return "Screen Content"
        case .localMailAccess: return "Local Mail Access"
        case .appAutomation: return "App Automation"
        }
    }
}

/// Boolean-only proof that Ace can open Mail's current local index. The probe
/// never reads a byte, returns a path, logs an account name, or follows a
/// symlink. Its sole result is whether the exact regular file could be opened
/// read-only by this process.
enum LocalMailAccessProbe {
    static func hasAccess(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        let mailRoot = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Mail", isDirectory: true)

        guard pathHasType(mailRoot.path, expectedType: S_IFDIR),
              let entries = try? fileManager.contentsOfDirectory(
                  atPath: mailRoot.path
              ),
              let currentVersion = entries.compactMap(mailVersion)
                .max(by: { $0.version < $1.version }) else {
            return false
        }

        let versionDirectory = mailRoot.appendingPathComponent(
            currentVersion.name,
            isDirectory: true
        )
        let mailDataDirectory = versionDirectory.appendingPathComponent(
            "MailData",
            isDirectory: true
        )
        let envelopeIndex = mailDataDirectory.appendingPathComponent(
            "Envelope Index",
            isDirectory: false
        )

        guard pathHasType(versionDirectory.path, expectedType: S_IFDIR),
              pathHasType(mailDataDirectory.path, expectedType: S_IFDIR),
              pathHasType(envelopeIndex.path, expectedType: S_IFREG) else {
            return false
        }

        let descriptor = envelopeIndex.path.withCString { path in
            Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return false }
        _ = Darwin.close(descriptor)
        return true
    }

    private static func mailVersion(_ name: String) -> (
        name: String,
        version: UInt64
    )? {
        guard name.first == "V", name.count > 1 else { return nil }
        let digits = name.dropFirst()
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let version = UInt64(digits) else { return nil }
        return (name, version)
    }

    private static func pathHasType(
        _ path: String,
        expectedType: mode_t
    ) -> Bool {
        var metadata = stat()
        guard path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
            return false
        }
        guard (metadata.st_mode & S_IFMT) != S_IFLNK else { return false }
        return (metadata.st_mode & S_IFMT) == expectedType
    }
}

enum NativeMailSetupSurface: String, Equatable, Sendable {
    case internetAccounts
    case appleMail
}

enum NativeMailSetupDestination {
    private static let modernExtensionPath =
        "/System/Library/ExtensionKit/Extensions/InternetAccountsSettingsExtension.appex"

    static func internetAccountsDeepLink(
        modernExtensionExists: Bool
    ) -> URL {
        let pane = modernExtensionExists
            ? "com.apple.Internet-Accounts-Settings.extension"
            : "com.apple.preference.internetaccounts"
        return URL(string: "x-apple.systempreferences:\(pane)")!
    }

    static var internetAccountsDeepLink: URL {
        internetAccountsDeepLink(
            modernExtensionExists: FileManager.default.fileExists(
                atPath: modernExtensionPath
            )
        )
    }

    static let appleMailApplication = URL(
        fileURLWithPath: "/System/Applications/Mail.app",
        isDirectory: true
    )
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Shared optional state for the intro and permanent panel. Opening Settings,
/// Internet Accounts, or Apple Mail never grants itself anything and never
/// handles account credentials. Every launch remains an explicit owner action.
@MainActor
final class LocalMailAccessController: ObservableObject {
    static let shared = LocalMailAccessController()

    @Published private(set) var hasAccess: Bool
    @Published private(set) var didOpenFullDiskAccessSettings = false
    @Published private(set) var restartFailureMessage: String?

    private let probe: () -> Bool
    private let settingsOpener: (URL) -> Bool
    private let appleMailOpener: (URL) -> Bool
    private let restartRequester: (
        URL,
        @escaping @Sendable (NSRunningApplication?, Error?) -> Void
    ) -> Void

    init(
        probe: @escaping () -> Bool = { LocalMailAccessProbe.hasAccess() },
        settingsOpener: @escaping (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        },
        appleMailOpener: @escaping (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        },
        restartRequester: @escaping (
            URL,
            @escaping @Sendable (NSRunningApplication?, Error?) -> Void
        ) -> Void = { bundleURL, completion in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: bundleURL,
                configuration: configuration,
                completionHandler: completion
            )
        }
    ) {
        self.probe = probe
        self.settingsOpener = settingsOpener
        self.appleMailOpener = appleMailOpener
        self.restartRequester = restartRequester
        hasAccess = probe()
    }

    @discardableResult
    func checkAgain() -> Bool {
        let currentResult = probe()
        hasAccess = currentResult
        if currentResult { restartFailureMessage = nil }
        return currentResult
    }

    @discardableResult
    func openFullDiskAccessSettings() -> Bool {
        let opened = settingsOpener(
            PermissionSystemSettingsPane.fullDiskAccess.deepLink
        )
        if opened {
            didOpenFullDiskAccessSettings = true
            restartFailureMessage = nil
        }
        return opened
    }

    @discardableResult
    func openAppleMail() -> Bool {
        appleMailOpener(NativeMailSetupDestination.appleMailApplication)
    }

    /// Explicit setup requests go first to macOS Internet Accounts. If that
    /// surface is unavailable, Apple Mail is the bounded native fallback.
    /// Neither path asks Ace for a password or grants mail mutation authority.
    @discardableResult
    func openMailAccountSetup() -> NativeMailSetupSurface? {
        if settingsOpener(
            NativeMailSetupDestination.internetAccountsDeepLink
        ) {
            return .internetAccounts
        }
        return openAppleMail() ? .appleMail : nil
    }

    /// Called only by the visible Restart Ace button. The existing instance
    /// stays alive unless Launch Services returns a distinct replacement.
    func restartAceAfterOwnerRequest() {
        restartFailureMessage = nil
        let currentProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        restartRequester(Bundle.main.bundleURL) { [weak self] application, error in
            DispatchQueue.main.async {
                guard error == nil,
                      let application,
                      application.processIdentifier != currentProcessIdentifier else {
                    self?.restartFailureMessage =
                        "Ace stayed open. Quit and reopen Ace once, then Check again."
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}
#endif // circuit-convert

enum PermissionRepairResult: Equatable, Sendable {
    case succeeded(PermissionRepairProof)
    case failed(PermissionRepairFailure)
}

enum PermissionRepairState: Equatable, Sendable {
    case idle
    case running(attempt: UInt64)
    case succeeded(attempt: UInt64, proof: PermissionRepairProof)
    case failed(attempt: UInt64, reason: PermissionRepairFailure)

    var attempt: UInt64? {
        switch self {
        case .idle:
            return nil
        case let .running(attempt),
             let .succeeded(attempt, _),
             let .failed(attempt, _):
            return attempt
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var proof: PermissionRepairProof? {
        guard case let .succeeded(_, proof) = self else { return nil }
        return proof
    }

    var visibleStatus: String? {
        switch self {
        case .idle:
            return nil
        case .running:
            return "Checking…"
        case let .succeeded(_, proof):
            return "Last check: \(proof.ownerFacingDescription)"
        case let .failed(_, reason):
            return reason.message
        }
    }

    var accessibilityValue: String {
        switch self {
        case .idle:
            return "idle"
        case let .running(attempt):
            return "attempt=\(attempt);phase=running"
        case let .succeeded(attempt, proof):
            return "attempt=\(attempt);phase=succeeded;proof=\(proof.code)"
        case let .failed(attempt, reason):
            return "attempt=\(attempt);phase=failed;code=\(reason.code)"
        }
    }
}

@MainActor
final class PermissionRepairCoordinator: ObservableObject {
    @Published private(set) var state: PermissionRepairState = .idle

    private var currentEpoch: UInt64 = 0
    private var operationTask: Task<Void, Never>?

    @discardableResult
    func start(
        operation: @MainActor @escaping () async -> PermissionRepairResult
    ) -> Bool {
        guard !state.isRunning else { return false }
        currentEpoch &+= 1
        let admittedEpoch = currentEpoch
        state = .running(attempt: admittedEpoch)
        operationTask = Task { @MainActor [weak self] in
            // Keep the running receipt observable for one UI frame even when a
            // local rejection completes synchronously.
            try? await Task.sleep(nanoseconds: 25_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.currentEpoch == admittedEpoch else {
                return
            }
            let result = await operation()
            guard !Task.isCancelled,
                  self.currentEpoch == admittedEpoch else {
                return
            }
            switch result {
            case let .succeeded(proof):
                self.state = .succeeded(
                    attempt: admittedEpoch,
                    proof: proof
                )
            case let .failed(reason):
                self.state = .failed(
                    attempt: admittedEpoch,
                    reason: reason
                )
            }
            self.operationTask = nil
        }
        return true
    }

    func invalidate() {
        currentEpoch &+= 1
        operationTask?.cancel()
        operationTask = nil
        state = .idle
    }

    /// Reconciles a previously terminal permission receipt with the current,
    /// exact OS readback. A late grant after timeout owns a fresh generation;
    /// a later revoke immediately removes stale green proof. Idle/running
    /// attempts are deliberately untouched, so an observation from an older
    /// generation cannot satisfy a newly revised attempt.
    func reconcilePermissionReadback(
        permission: PermissionKind,
        isGranted: Bool,
        successDwellNanoseconds: UInt64 = 2_000_000_000
    ) {
        let expectedProof = PermissionRepairProof.permissionReadback(
            permission: permission
        )
        switch state {
        case .succeeded(_, let proof) where proof == expectedProof:
            if !isGranted { invalidate() }
        case .failed where isGranted:
            guard start(operation: { .succeeded(expectedProof) }),
                  let convergenceAttempt = state.attempt else { return }
            Task { @MainActor [weak self] in
                if successDwellNanoseconds > 0 {
                    try? await Task.sleep(
                        nanoseconds: successDwellNanoseconds
                    )
                } else {
                    await Task.yield()
                }
                guard let self,
                      self.state == .succeeded(
                        attempt: convergenceAttempt,
                        proof: expectedProof
                      ) else { return }
                self.invalidate()
            }
        default:
            break
        }
    }

    @discardableResult
    func startPromptResolution(
        permission: PermissionKind,
        maximumPollCount: Int = 300,
        pollDelayNanoseconds: UInt64 = 100_000_000,
        requestPrompt: @MainActor @escaping () -> Bool,
        readback: @MainActor @escaping () async -> Bool
    ) -> Bool {
        start {
            guard requestPrompt() else {
                return .failed(
                    PermissionRepairFailure(
                        code: "\(permission.rawValue).prompt_not_admitted",
                        message: "Ace did not invoke the macOS prompt because its durable attempt receipt or visibility gate was unavailable."
                    )
                )
            }
            for _ in 0..<maximumPollCount {
                if await readback() {
                    return .succeeded(
                        .permissionReadback(permission: permission)
                    )
                }
                if Task.isCancelled { break }
                if pollDelayNanoseconds > 0 {
                    try? await Task.sleep(
                        nanoseconds: pollDelayNanoseconds
                    )
                } else {
                    await Task.yield()
                }
            }
            return .failed(
                PermissionRepairFailure(
                    code: "\(permission.rawValue).prompt_unresolved",
                    message:
                        "macOS did not report a resolved \(permission.ownerFacingName) grant before the check timed out."
                )
            )
        }
    }
}

enum ActionReceiptVisibilityPolicy {
    static func allowsVisibleReceipt(
        entryLatchIsRaised: Bool,
        visibilityIsBlocked: Bool
    ) -> Bool {
        !entryLatchIsRaised && !visibilityIsBlocked
    }
}

/// One-claim presentation lease for surfaces that retain a single window at a
/// time (the diagnostic review card). `claim()` admits exactly one holder;
/// `release()` is idempotent, and every close path — in-view dismiss and
/// titlebar close alike — must route through the same release so a closed
/// window can never keep suppressing every later offer for the launch.
final class SingleWindowPresentationLease {
    private(set) var isHeld = false

    @discardableResult
    func claim() -> Bool {
        if isHeld { return false }
        isHeld = true
        return true
    }

    func release() { isHeld = false }
}

/// Every buyer-visible setup control is declared exactly once. Views consume
/// these values instead of inventing fallback identifiers.
enum SetupControlID {
    static let introProviderConnectCodex = "ace.intro.provider.codex.connect"
    static let introProviderConnectClaude = "ace.intro.provider.claude.connect"
    static let introProviderConnectQwen = "ace.intro.provider.qwen.connect"
    static let introProviderRetryCodex = "ace.intro.provider.codex.retry"
    static let introProviderRetryClaude = "ace.intro.provider.claude.retry"
    static let introProviderRetryQwen = "ace.intro.provider.qwen.retry"
    static let panelProviderConnectCodex = "ace.panel.provider.codex.connect"
    static let panelProviderConnectClaude = "ace.panel.provider.claude.connect"
    static let panelProviderConnectQwen = "ace.panel.provider.qwen.connect"
    static let introVoice = "ace.intro.permission.voice"
    static let introMicrophone = "ace.intro.permission.microphone"
    static let introSpeechRecognition = "ace.intro.permission.speech-recognition"
    static let introScreenRecording = "ace.intro.permission.screen-recording"
    static let introAccessibility = "ace.intro.permission.accessibility"
    static let introScreenContent = "ace.intro.permission.screen-content"
    static let introLocalMailAccess = "ace.intro.permission.local-mail-access"
    static let introLocalMailOpenAppleMail =
        "ace.intro.permission.local-mail-access.open-apple-mail"
    static let introAppAutomation = "ace.intro.permission.app-automation"
    static let panelMicrophone = "ace.panel.permission.microphone"
    static let panelSpeechRecognition = "ace.panel.permission.speech-recognition"
    static let panelScreenRecording = "ace.panel.permission.screen-recording"
    static let panelAccessibility = "ace.panel.permission.accessibility"
    static let panelAccessibilityFindApp = "ace.panel.permission.accessibility.find-app"
    static let panelScreenContent = "ace.panel.permission.screen-content"
    static let panelLocalMailAccess = "ace.panel.permission.local-mail-access"
    static let panelLocalMailOpenAppleMail =
        "ace.panel.permission.local-mail-access.open-apple-mail"
    static let panelAppAutomation = "ace.panel.permission.app-automation"
    static let panelRepairAll = "ace.panel.permission.repair-all"
    static let panelSetupWindow = "ace.panel.setup"
    static let panelSetupRepair = "ace.panel.setup-repair"
}

@MainActor
final class SetupControlCoordinatorBank {
    static let shared = SetupControlCoordinatorBank()

    let voice = PermissionRepairCoordinator()
    let microphone = PermissionRepairCoordinator()
    let speechRecognition = PermissionRepairCoordinator()
    let screenContent = PermissionRepairCoordinator()
    let appAutomation = PermissionRepairCoordinator()
    let panelRepairAll = PermissionRepairCoordinator()
    let panelAccessibilityFindApp = PermissionRepairCoordinator()
    let panelSetupWindow = PermissionRepairCoordinator()
    let panelSetupRepair = PermissionRepairCoordinator()

    private init() {}
}

enum PermissionRepairObservation {
    @MainActor
    static func wait(
        maximumPollCount: Int = 300,
        pollDelayNanoseconds: UInt64 = 100_000_000,
        terminal: @MainActor () async -> PermissionRepairResult?
    ) async -> PermissionRepairResult {
        for _ in 0..<maximumPollCount {
            if let result = await terminal() { return result }
            if Task.isCancelled {
                return .failed(
                    PermissionRepairFailure(
                        code: "repair.cancelled",
                        message: "The repair was superseded by a newer request."
                    )
                )
            }
            if pollDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: pollDelayNanoseconds)
            } else {
                await Task.yield()
            }
        }
        return .failed(
            PermissionRepairFailure(
                code: "repair.postcondition_timeout",
                message: "Ace did not observe the requested postcondition before the bounded check ended."
            )
        )
    }
}

enum SetupWalkthroughOwnedRunOutcome: Equatable {
    case completed
    case stopped
    case cancelled
}

enum SetupWalkthroughOwnedRunWaiter {
    @MainActor
    static func wait(
        pollDelayNanoseconds: UInt64 = 100_000_000,
        completed: @MainActor () -> Bool,
        isRunning: @MainActor () -> Bool,
        cancelAndWait: @MainActor () async -> Void
    ) async -> SetupWalkthroughOwnedRunOutcome {
        while true {
            if completed() { return .completed }
            if Task.isCancelled {
                await cancelAndWait()
                while isRunning() { await Task.yield() }
                return .cancelled
            }
            if !isRunning() { return .stopped }
            if pollDelayNanoseconds > 0 {
                try? await Task.sleep(
                    nanoseconds: pollDelayNanoseconds
                )
            } else {
                await Task.yield()
            }
        }
    }
}

struct IdentifierReplacingStore<Element: Identifiable>
where Element.ID == String {
    private(set) var elements: [Element] = []

    mutating func upsert(_ element: Element) {
        if let existingIndex = elements.firstIndex(
            where: { $0.id == element.id }
        ) {
            elements[existingIndex] = element
        } else {
            elements.append(element)
        }
    }

    mutating func remove(identifier: String) {
        elements.removeAll { $0.id == identifier }
    }
}
