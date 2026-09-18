#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  BuddyDictationManager.swift
//  leanring-buddy
//
//  Shared push-to-talk dictation manager for the help chat and brainstorm buddy.
//  Captures microphone audio with AVAudioEngine, routes it into the active
//  transcription provider, and hands the final draft back to the active input bar.
//

#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import Foundation
#if canImport(Speech) && !CIRCUIT_WINDOWS_SIM
import Speech
#endif
import CircuitPortKit

enum BuddyPushToTalkShortcut {
    enum ShortcutOption {
        case shiftFunction
        case controlOption
        case shiftControl
        case commandShift
        case controlOptionSpace
        case shiftControlSpace

        var displayText: String {
            switch self {
            case .shiftFunction:
                return "shift + fn"
            case .controlOption:
                return "ctrl + option"
            case .shiftControl:
                return "shift + control"
            case .commandShift:
                return "cmd + shift"
            case .controlOptionSpace:
                return "ctrl + option + space"
            case .shiftControlSpace:
                return "shift + control + space"
            }
        }

        var keyCapsuleLabels: [String] {
            switch self {
            case .shiftFunction:
                return ["shift", "fn"]
            case .controlOption:
                return ["ctrl", "option"]
            case .shiftControl:
                return ["shift", "control"]
            case .commandShift:
                return ["cmd", "shift"]
            case .controlOptionSpace:
                return ["ctrl", "option", "space"]
            case .shiftControlSpace:
                return ["shift", "control", "space"]
            }
        }

        fileprivate var modifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return [.shift, .function]
            case .controlOption:
                return [.control, .option]
            case .shiftControl:
                return [.shift, .control]
            case .commandShift:
                return [.shift, .command]
            case .controlOptionSpace, .shiftControlSpace:
                return nil
            }
        }

        /// A second modifier chord that ALSO fires the shortcut. cmd+shift is
        /// the hotkey (founder ruling 2026-07-22 — his presses arrive as
        /// cmd+shift), but ctrl+shift is kept alive so the hotkey survives any
        /// keyboard whose control key was remapped back to plain control.
        fileprivate var alternateModifierOnlyFlags: NSEvent.ModifierFlags? {
            switch self {
            case .commandShift:
                return [.shift, .control]
            case .shiftFunction, .controlOption, .shiftControl,
                 .controlOptionSpace, .shiftControlSpace:
                return nil
            }
        }

        fileprivate var spaceShortcutModifierFlags: NSEvent.ModifierFlags? {
            switch self {
            case .shiftFunction:
                return nil
            case .controlOption:
                return nil
            case .shiftControl:
                return nil
            case .commandShift:
                return nil
            case .controlOptionSpace:
                return [.control, .option]
            case .shiftControlSpace:
                return [.shift, .control]
            }
        }
    }

    enum ShortcutTransition {
        case none
        case pressed
        case released
        case cancelled
    }

    private enum ShortcutEventType {
        case flagsChanged
        case keyDown
        case keyUp
    }

    static let currentShortcutOption: ShortcutOption = .commandShift
    static let pushToTalkKeyCode: UInt16 = 49 // Space
    static let pushToTalkDisplayText = currentShortcutOption.displayText
    static let pushToTalkTooltipText = "push to talk (\(pushToTalkDisplayText))"

    static func shortcutTransition(
        for event: NSEvent,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: event.type) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    static func shortcutTransition(
        for eventType: CGEventType,
        keyCode: UInt16,
        modifierFlagsRawValue: UInt64,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        guard let shortcutEventType = shortcutEventType(for: eventType) else { return .none }

        return shortcutTransition(
            for: shortcutEventType,
            keyCode: keyCode,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(modifierFlagsRawValue))
                .intersection(.deviceIndependentFlagsMask),
            wasShortcutPreviouslyPressed: wasShortcutPreviouslyPressed
        )
    }

    private static func shortcutEventType(for eventType: NSEvent.EventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutEventType(for eventType: CGEventType) -> ShortcutEventType? {
        switch eventType {
        case .flagsChanged:
            return .flagsChanged
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        default:
            return nil
        }
    }

    private static func shortcutTransition(
        for shortcutEventType: ShortcutEventType,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        wasShortcutPreviouslyPressed: Bool
    ) -> ShortcutTransition {
        if let modifierOnlyFlags = currentShortcutOption.modifierOnlyFlags {
            let relevant = modifierFlags.intersection([.shift, .command, .control, .option, .function])
            let alternate = currentShortcutOption.alternateModifierOnlyFlags
            let chordIsHeld = relevant.contains(modifierOnlyFlags)
                || alternate.map { relevant.contains($0) } == true
            let exactChord = relevant == modifierOnlyFlags || relevant == alternate

            // A third key belongs to the foreground app's shortcut. Retire
            // this voice hold without submitting even a partial transcript.
            if shortcutEventType == .keyDown, chordIsHeld || wasShortcutPreviouslyPressed {
                return .cancelled
            }
            guard shortcutEventType == .flagsChanged else { return .none }
            if chordIsHeld && !exactChord { return .cancelled }
            let isShortcutCurrentlyPressed = exactChord

            if isShortcutCurrentlyPressed && !wasShortcutPreviouslyPressed {
                return .pressed
            }

            if !isShortcutCurrentlyPressed && wasShortcutPreviouslyPressed {
                return .released
            }

            return .none
        }

        guard let pushToTalkModifierFlags = currentShortcutOption.spaceShortcutModifierFlags else {
            return .none
        }

        let matchesModifierFlags = modifierFlags.isSuperset(of: pushToTalkModifierFlags)

        if shortcutEventType == .keyDown
            && keyCode == pushToTalkKeyCode
            && matchesModifierFlags
            && !wasShortcutPreviouslyPressed {
            return .pressed
        }

        if shortcutEventType == .keyUp
            && keyCode == pushToTalkKeyCode
            && wasShortcutPreviouslyPressed {
            return .released
        }

        return .none
    }
}

enum BuddyDictationPermissionProblem {
    case microphoneAccessDenied
    case speechRecognitionDenied
}

private enum BuddyDictationStartSource {
    case microphoneButton
    case keyboardShortcut
    case partnerAutomatic
}

private struct BuddyDictationDraftCallbacks {
    let updateDraftText: (UUID, String) -> Void
    let submitDraftText: (UUID, String) -> Void
    let shouldSubmitImmediatelyOnRelease: (String) -> Bool
}

enum BuddyAutomaticPartnerTurnTermination: Equatable {
    case silentWindowExpired
    case recognitionFailed(String)
}

nonisolated enum BuddyDictationAudioBoundaryAction: Equatable {
    case forward
    /// This call was the first observer of Stealth and synchronously cancelled
    /// the provider before returning. The tap must drop the buffer.
    case dropAndCancel
    case drop
}

nonisolated private final class BuddyTranscriptionSessionCutoffBox:
    @unchecked Sendable
{
    let session: any BuddyStreamingTranscriptionSession

    init(_ session: any BuddyStreamingTranscriptionSession) {
        self.session = session
    }

    func cancel() {
        session.cancel()
    }
}

nonisolated private final class BuddyAudioEngineCutoffBox:
    @unchecked Sendable
{
    private let audioEngine: AVAudioEngine

    init(_ audioEngine: AVAudioEngine) {
        self.audioEngine = audioEngine
    }

    /// `stop()` is synchronous and does not wait for an actor, queue, or native
    /// completion. Tap removal stays on MainActor; the provider boundary already
    /// drops every buffer after this cutoff.
    func stop() {
        audioEngine.stop()
    }
}

/// Per-tap, thread-safe transition registered directly with the Private Mode
/// entry latch. Entry
/// stops its exact native microphone engine and cancels its provider session
/// before `raiseSynchronously()` returns; the AVAudio callback then drops every
/// buffer without waiting for MainActor.
nonisolated final class BuddyDictationAudioBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private let entryLatch: StealthEntryLatch
    private let stopAudioEngine: @Sendable () -> Void
    private let cancelProvider: @Sendable () -> Void
    private var didCancelForStealth = false
    private var stealthEntryCutoffRegistration: UUID?

    init(
        entryLatch: StealthEntryLatch = .shared,
        stopAudioEngine: @escaping @Sendable () -> Void = {},
        cancelProvider: @escaping @Sendable () -> Void = {}
    ) {
        self.entryLatch = entryLatch
        self.stopAudioEngine = stopAudioEngine
        self.cancelProvider = cancelProvider
        stealthEntryCutoffRegistration =
            entryLatch.registerSynchronousEntryCutoff { [weak self] in
                self?.cancelSynchronouslyForStealth()
            }
    }

    deinit {
        if let stealthEntryCutoffRegistration {
            entryLatch.unregisterSynchronousEntryCutoff(
                stealthEntryCutoffRegistration
            )
        }
    }

    func action(stealthEntryIsRaised: Bool) -> BuddyDictationAudioBoundaryAction {
        guard stealthEntryIsRaised else {
            return lock.withLock {
                didCancelForStealth ? .drop : .forward
            }
        }
        return cancelSynchronouslyForStealth()
            ? .dropAndCancel
            : .drop
    }

    @discardableResult
    private func cancelSynchronouslyForStealth() -> Bool {
        let shouldCancel = lock.withLock {
            guard !didCancelForStealth else { return false }
            didCancelForStealth = true
            return true
        }
        if shouldCancel {
            stopAudioEngine()
            cancelProvider()
        }
        return shouldCancel
    }
}

@MainActor
final class BuddyDictationManager: NSObject, ObservableObject {
    private static let finalTranscriptInactivityDelaySeconds: TimeInterval = 2.4
    private static let finalTranscriptHardMaximumDelaySeconds: TimeInterval = 8
    private static let recordedAudioPowerHistoryLength = 44
    private static let recordedAudioPowerHistoryBaselineLevel: CGFloat = 0.02
    private static let recordedAudioPowerHistorySampleIntervalSeconds: TimeInterval = 0.07

    @Published private(set) var isRecordingFromMicrophoneButton = false
    @Published private(set) var isRecordingFromKeyboardShortcut = false
    @Published private(set) var isRecordingAutomaticPartnerTurn = false
    @Published private(set) var isKeyboardShortcutSessionActiveOrFinalizing = false
    @Published private(set) var isFinalizingTranscript = false
    @Published private(set) var isPreparingToRecord = false
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var recordedAudioPowerHistory = Array(
        repeating: BuddyDictationManager.recordedAudioPowerHistoryBaselineLevel,
        count: BuddyDictationManager.recordedAudioPowerHistoryLength
    )
    @Published private(set) var microphoneButtonRecordingStartedAt: Date?
    @Published private(set) var transcriptionProviderDisplayName = ""
    @Published var lastErrorMessage: String?
    @Published private(set) var currentPermissionProblem: BuddyDictationPermissionProblem?
    var audioSessionCoordinator: AudioSessionCoordinator?
    var onAudioSessionRefusal: ((String) -> Void)?
    var onDictationFailure: ((UUID, String) -> Void)?
    var onAudioReplayScrubBoundary:
        ((BuddyAudioReplayScrubBoundary) -> Void)?

    var isDictationInProgress: Bool {
        isPreparingToRecord || isRecordingFromMicrophoneButton
            || isRecordingFromKeyboardShortcut
            || isRecordingAutomaticPartnerTurn
            || isFinalizingTranscript
    }

    var isActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
            || isRecordingFromKeyboardShortcut
            || isRecordingAutomaticPartnerTurn
    }

    var isMicrophoneButtonActivelyRecordingAudio: Bool {
        isRecordingFromMicrophoneButton
    }

    var isMicrophoneButtonSessionBusy: Bool {
        activeStartSource == .microphoneButton
            && (isPreparingToRecord || isRecordingFromMicrophoneButton || isFinalizingTranscript)
    }

    var needsInitialPermissionPrompt: Bool {
        if let initialPermissionPromptCheck {
            return initialPermissionPromptCheck()
        }
        if transcriptionProvider.requiresSpeechRecognitionPermission {
            return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
                || SFSpeechRecognizer.authorizationStatus() == .notDetermined
        }

        return AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    private let transcriptionProvider: any BuddyTranscriptionProvider
    private let eventBus: AceEventBus
    private let permissionAuthorizer: (@MainActor () async -> Bool)?
    private let initialPermissionPromptCheck: (@MainActor () -> Bool)?
    private let audioCaptureFactory:
        @MainActor () throws -> any BuddyDictationAudioCapturing
    private var audioCaptureLease: (any BuddyDictationAudioCapturing)?
    private var audioConfigurationChangeObserver: NSObjectProtocol?
    private var audioConfigurationRecoveryCount = 0
    private var lastAudioConfigurationRecoveryUptime: TimeInterval?
    private var activeTranscriptionSession: (any BuddyStreamingTranscriptionSession)?
    private var activeStartSource: BuddyDictationStartSource?
    private var draftCallbacks: BuddyDictationDraftCallbacks?
    private var draftTextBeforeCurrentDictation = ""
    private var latestRecognizedText = ""
    private var shouldAutomaticallySubmitFinalDraft = false
    private var hasFinishedCurrentDictationSession = false
    private var finalizeFallbackWorkItem: DispatchWorkItem?
    private var finalizationCoordinator:
        BuddyDictationFinalizationCoordinator?
    private var physicalGenerationGate =
        BuddyDictationPhysicalGenerationGate()
    private var claimedPhysicalGenerationIdentifier: UUID?
    private var pendingStartRequestIdentifier = UUID()
    private var activeDictationSessionIdentifier: UUID?
    private var activeOwnerTurnIdentifier: UUID?
    private var activeRecognitionAttemptIdentifier: UUID?
    private var audioReplayBuffer: BuddyAudioReplayBuffer?
    private var speechRecoveryAttemptCount = 0
    private var speechRecoveryTask: Task<Void, Never>?
    private var pendingContextualCaptureContext:
        SpeechContextualCaptureContext?
    private var activeTranscriptionVocabulary:
        SpeechContextualVocabulary?
    private var lastRecordedAudioPowerSampleDate = Date.distantPast
    private var automaticPartnerTurnTimer: Timer?
    private var automaticPartnerTurnStartedAt: Date?
    private var automaticPartnerTranscriptLastChangedAt: Date?
    private var lastAutomaticPartnerAudioActivityAt: Date?
    private var automaticPartnerSpeechActivity = PartnerSpeechActivity()
    private var automaticPartnerTurnTermination:
        ((BuddyAutomaticPartnerTurnTermination) -> Void)?
    private var activePermissionRequestTask: (
        identifier: UUID,
        task: Task<Bool, Never>
    )?
    /// Timestamp of the last completed permission request, used to debounce
    /// rapid follow-up requests that arrive before macOS updates its cache.
    private var lastPermissionRequestCompletedAt: Date?
    private var activeAudioCaptureOwner: AudioCaptureOwner?
    /// WALL 1. Consulted for every audio buffer, on the audio thread. Held as a
    /// property rather than reached through `.shared` inside the tap so tests
    /// can substitute a gate with a synthetic speech-activity source.
    private let selfVoiceCaptureGate: AceSelfVoiceCaptureGate

    /// How the CURRENT session's audio is being captured. Decides how a
    /// suppressed session is reported, and labels the resulting owner event.
    private var activeCaptureOrigin: AceCaptureOrigin?

    /// Maps this file's private start-source vocabulary onto the event system's
    /// capture origin. One mapping, one place.
    private static func captureOrigin(
        for startSource: BuddyDictationStartSource
    ) -> AceCaptureOrigin {
        switch startSource {
        case .keyboardShortcut:  return .pushToTalk
        case .microphoneButton:  return .microphoneButton
        case .partnerAutomatic:  return .partnerAutomatic
        }
    }

    override init() {
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        self.selfVoiceCaptureGate = .shared
        self.eventBus = .shared
        self.permissionAuthorizer = nil
        self.initialPermissionPromptCheck = nil
        self.audioCaptureFactory = { try BuddyDictationAudioCaptureLease() }
        super.init()
        observeOwnerTurnReplacement()
    }

    /// Test seam: substitute a gate whose speech-activity source is synthetic,
    /// so the suppression contract is provable without an audio daemon.
    init(selfVoiceCaptureGate: AceSelfVoiceCaptureGate) {
        let transcriptionProvider = BuddyTranscriptionProviderFactory.makeDefaultProvider()
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        self.selfVoiceCaptureGate = selfVoiceCaptureGate
        self.eventBus = .shared
        self.permissionAuthorizer = nil
        self.initialPermissionPromptCheck = nil
        self.audioCaptureFactory = { try BuddyDictationAudioCaptureLease() }
        super.init()
        observeOwnerTurnReplacement()
    }

    init(
        transcriptionProvider: any BuddyTranscriptionProvider,
        eventBus: AceEventBus,
        selfVoiceCaptureGate: AceSelfVoiceCaptureGate,
        permissionAuthorizer: @escaping @MainActor () async -> Bool,
        needsInitialPermissionPrompt:
            @escaping @MainActor () -> Bool,
        audioCaptureFactory:
            @escaping @MainActor () throws -> any BuddyDictationAudioCapturing
    ) {
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionProviderDisplayName = transcriptionProvider.displayName
        self.eventBus = eventBus
        self.selfVoiceCaptureGate = selfVoiceCaptureGate
        self.permissionAuthorizer = permissionAuthorizer
        self.initialPermissionPromptCheck = needsInitialPermissionPrompt
        self.audioCaptureFactory = audioCaptureFactory
        super.init()
        observeOwnerTurnReplacement()
    }

    deinit {
        audioReplayBuffer?.scrub(.deinitialization)
    }

    func updateContextualCaptureContext(
        _ captureContext: SpeechContextualCaptureContext
    ) {
        pendingContextualCaptureContext = captureContext
    }

    func startPersistentDictationFromMicrophoneButton(
        ownerTurnID: UUID,
        currentDraftText: String,
        updateDraftText: @escaping (UUID, String) -> Void,
        submitDraftText: @escaping (UUID, String) -> Void
    ) async {
        await startPushToTalk(
            startSource: .microphoneButton,
            ownerTurnID: ownerTurnID,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldSubmitImmediatelyOnRelease: { _ in false },
            shouldAutomaticallySubmitFinalDraftOnStop: false
        )
    }

    func startPushToTalkFromKeyboardShortcut(
        ownerTurnID: UUID,
        currentDraftText: String,
        updateDraftText: @escaping (UUID, String) -> Void,
        submitDraftText: @escaping (UUID, String) -> Void,
        shouldSubmitImmediatelyOnRelease:
            @escaping (String) -> Bool = { _ in false }
    ) async {
        await startPushToTalk(
            startSource: .keyboardShortcut,
            ownerTurnID: ownerTurnID,
            currentDraftText: currentDraftText,
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldSubmitImmediatelyOnRelease:
                shouldSubmitImmediatelyOnRelease,
            shouldAutomaticallySubmitFinalDraftOnStop: currentDraftText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    func stopPersistentDictationFromMicrophoneButton() {
        stopPushToTalk(expectedStartSource: .microphoneButton)
    }

    func stopPushToTalkFromKeyboardShortcut() {
        stopPushToTalk(expectedStartSource: .keyboardShortcut)
    }

    func startAutomaticPartnerTurn(
        ownerTurnID: UUID,
        updateDraftText: @escaping (UUID, String) -> Void,
        submitDraftText: @escaping (UUID, String) -> Void,
        onTermination:
            @escaping (BuddyAutomaticPartnerTurnTermination) -> Void
    ) async {
        await startPushToTalk(
            startSource: .partnerAutomatic,
            ownerTurnID: ownerTurnID,
            currentDraftText: "",
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldSubmitImmediatelyOnRelease: { _ in false },
            shouldAutomaticallySubmitFinalDraftOnStop: true,
            automaticPartnerTurnTermination: onTermination
        )
    }

    func stopAutomaticPartnerTurn() {
        stopPushToTalk(expectedStartSource: .partnerAutomatic)
    }

    /// An explicit keyboard hold owns its own release boundary. Retire the
    /// automatic Partner capture, including a pending start, without routing
    /// its partial text or ending the surrounding conversation.
    @discardableResult
    func yieldAutomaticPartnerTurnForKeyboardShortcut() -> Bool {
        guard activeStartSource == .partnerAutomatic else { return false }
        cancelCurrentDictation(preserveDraftText: false)
        return true
    }

    /// Speech may retire an empty automatic listening window, never an
    /// explicit hold, recognized words, or audio still awaiting recognition.
    @discardableResult
    func yieldIdleAutomaticPartnerTurnForSpeech(now: Date = Date()) -> Bool {
        guard activeStartSource == .partnerAutomatic,
              isRecordingAutomaticPartnerTurn,
              !isPreparingToRecord, !isFinalizingTranscript,
              latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let startedAt = automaticPartnerTurnStartedAt,
              now.timeIntervalSince(startedAt) >= 3,
              now.timeIntervalSince(lastAutomaticPartnerAudioActivityAt ?? startedAt)
                >= PartnerAutomaticTurnBoundary.minimumSpeechQuietSeconds else {
            return false
        }
        cancelCurrentDictation(preserveDraftText: false)
        return true
    }

    /// A new push-to-talk press arrived while the previous session was only
    /// FINALIZING (waiting on the last transcript, no longer recording). The
    /// normal guards would drop that press, and because modifier flagsChanged
    /// only fires on transitions no further press arrives — the user speaks a
    /// whole utterance into a dead mic. Finish the finalizing session now
    /// (submitting whatever it recognized) and fully tear down its recognition
    /// task, so the new press can claim the single recognition slot without
    /// tripping the one-task-per-process limit. Returns true if it acted (the
    /// caller may then start the new session); false if a session is actively
    /// recording or preparing (in which case the press should still be ignored).
    func finishFinalizingSessionForRestart() -> Bool {
        guard isFinalizingTranscript, !isActivelyRecordingAudio, !isPreparingToRecord else { return false }
        if var finalizationCoordinator {
            _ = finalizationCoordinator.cancelForRestart()
            self.finalizationCoordinator = finalizationCoordinator
        }
        if let activeDictationSessionIdentifier {
            appendDictationTimingReceipt(
                "cancelled",
                sessionIdentifier: activeDictationSessionIdentifier,
                detail: "reason=rapid-repress"
            )
        }
        // The new press is an owner interruption. Never route a provisional
        // transcript from the generation it is replacing; the current turn is
        // cancelled by CompanionManager immediately after this returns.
        hasFinishedCurrentDictationSession = true
        cancelCurrentDictation(preserveDraftText: false)
        return true
    }

    func cancelCurrentDictation(preserveDraftText: Bool = true) {
        cancelCurrentDictation(
            preserveDraftText: preserveDraftText,
            replayScrubBoundary: .cancellation
        )
    }

    func cancelCurrentDictationForStop() {
        cancelCurrentDictation(
            preserveDraftText: false,
            replayScrubBoundary: .stop
        )
    }

    func cancelCurrentDictationForProviderSwitch() {
        cancelCurrentDictation(
            preserveDraftText: false,
            replayScrubBoundary: .providerSwitch
        )
    }

    private func cancelCurrentDictation(
        preserveDraftText: Bool,
        replayScrubBoundary: BuddyAudioReplayScrubBoundary
    ) {
        let shouldTearDownAudioSession = activeDictationSessionIdentifier != nil
            || activeTranscriptionSession != nil
            || isActivelyRecordingAudio
            || isFinalizingTranscript

        pendingStartRequestIdentifier = UUID()
        activePermissionRequestTask?.task.cancel()
        activePermissionRequestTask = nil

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        if preserveDraftText,
           !StealthEntryLatch.shared.isRaised,
           isDictationInProgress,
           let ownerTurnID = activeOwnerTurnIdentifier,
           ownerTurnIsCurrentAndUncancelled(ownerTurnID) {
            let currentDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
            draftCallbacks?.updateDraftText(ownerTurnID, currentDraftText)
        }

        if shouldTearDownAudioSession {
            if let activeDictationSessionIdentifier,
               !hasFinishedCurrentDictationSession {
                appendDictationTimingReceipt(
                    "cancelled",
                    sessionIdentifier: activeDictationSessionIdentifier,
                    detail: "reason=teardown"
                )
            }
            stopCurrentAudioCapture()
            activeTranscriptionSession?.cancel()
        }

        resetSessionState(scrubBoundary: replayScrubBoundary)
    }

    /// Stealth entry is a hard cancellation boundary, not a normal push-to-talk
    /// stop. It invalidates starts that are queued or suspended in permission /
    /// provider setup, tears down active and finalizing sessions, and deliberately
    /// never updates or submits the current draft.
    func cancelCurrentDictationForStealth() {
        cancelCurrentDictation(
            preserveDraftText: false,
            replayScrubBoundary: .privateMode
        )
    }

    func requestInitialPushToTalkPermissionsIfNeeded() async {
        guard needsInitialPermissionPrompt else { return }
        guard !isDictationInProgress else { return }
        guard !Task.isCancelled,
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else { return }

        // Issue the generation before the first suspension. Cancellation must
        // invalidate this exact request; a resumed task must never mint a fresh
        // generation and escape the cancellation boundary.
        let startRequestIdentifier = UUID()
        pendingStartRequestIdentifier = startRequestIdentifier

        lastErrorMessage = nil
        currentPermissionProblem = nil
        isPreparingToRecord = true

        guard canContinueStartRequest(startRequestIdentifier) else {
            abandonStartRequestIfCurrent(startRequestIdentifier)
            return
        }
        guard SetupVisibleEffectAdmission.commit(effect: {
            NSApplication.shared.activate(ignoringOtherApps: true)
            return true
        }) else {
            abandonStartRequestIfCurrent(startRequestIdentifier)
            return
        }

        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            abandonStartRequestIfCurrent(startRequestIdentifier)
            return
        }

        guard canContinueStartRequest(startRequestIdentifier) else {
            abandonStartRequestIfCurrent(startRequestIdentifier)
            return
        }

        // The individual microphone and Speech request calls repeat this check
        // directly at each OS permission boundary.
        let hasPermissions = await authorizeMicrophoneAndSpeechPermissions()
        guard canContinueStartRequest(startRequestIdentifier) else {
            abandonStartRequestIfCurrent(startRequestIdentifier)
            return
        }

        resetSessionState(scrubBoundary: .success)

        if hasPermissions {
            lastErrorMessage = nil
        }
    }

    private func startPushToTalk(
        startSource: BuddyDictationStartSource,
        ownerTurnID: UUID,
        currentDraftText: String,
        updateDraftText: @escaping (UUID, String) -> Void,
        submitDraftText: @escaping (UUID, String) -> Void,
        shouldSubmitImmediatelyOnRelease:
            @escaping (String) -> Bool,
        shouldAutomaticallySubmitFinalDraftOnStop: Bool,
        automaticPartnerTurnTermination:
            ((BuddyAutomaticPartnerTurnTermination) -> Void)? = nil
    ) async {
        // Every refusal below leaves a receipt. These three guards used to
        // return in complete silence, so a press that produced no waveform and
        // no transcription left NO evidence anywhere of why — the owner saw the
        // chord "do nothing" and the log had nothing to say about it. Stealth
        // and the duplicate-press gate must still refuse; they just may not
        // refuse invisibly.
        let startRequestIdentifier = UUID()
        guard !isDictationInProgress else {
            appendDictationTimingReceipt(
                "press-refused",
                sessionIdentifier: startRequestIdentifier,
                detail: "source=\(startSource) reason=already-recording")
            return
        }
        guard !Task.isCancelled,
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive,
              eventBus.currentTurnID == ownerTurnID,
              !eventBus.isTurnCancelled(ownerTurnID) else {
            appendDictationTimingReceipt(
                "press-refused",
                sessionIdentifier: startRequestIdentifier,
                detail: "source=\(startSource) reason=cancelled-or-private-mode")
            return
        }

        // Claim the physical generation before the first permission or provider
        // suspension. A duplicate press can otherwise enter while the first
        // task is sleeping for the macOS prompt and open a second audio lease.
        guard physicalGenerationGate.claim(startRequestIdentifier) else {
            appendDictationTimingReceipt(
                "press-refused",
                sessionIdentifier: startRequestIdentifier,
                detail: "source=\(startSource) reason=superseded-by-newer-press")
            return
        }
        claimedPhysicalGenerationIdentifier = startRequestIdentifier
        pendingStartRequestIdentifier = startRequestIdentifier
        activeOwnerTurnIdentifier = ownerTurnID
        let captureContext = pendingContextualCaptureContext
            ?? SpeechContextualCaptureContext(
                backend: .codex(resolvedModelLabel: nil)
            )
        pendingContextualCaptureContext = nil
        activeTranscriptionVocabulary =
            SpeechContextualVocabulary.validated(capture: captureContext)
        audioReplayBuffer = BuddyAudioReplayBuffer(turnID: ownerTurnID)
        draftTextBeforeCurrentDictation = currentDraftText
        latestRecognizedText = ""
        draftCallbacks = BuddyDictationDraftCallbacks(
            updateDraftText: updateDraftText,
            submitDraftText: submitDraftText,
            shouldSubmitImmediatelyOnRelease:
                shouldSubmitImmediatelyOnRelease
        )
        activeStartSource = startSource
        isPreparingToRecord = true
        appendDictationTimingReceipt(
            "press",
            sessionIdentifier: startRequestIdentifier,
            detail: "source=\(startSource)"
        )

        let requestedAudioOwner: AudioCaptureOwner =
            startSource == .partnerAutomatic ? .partner : .pushToTalk
        if let audioSessionCoordinator {
            let decision = audioSessionCoordinator.acquireCapture(
                requestedAudioOwner
            )
            if let visibleFailure = decision.visibleFailure {
                lastErrorMessage = visibleFailure
                onAudioSessionRefusal?(visibleFailure)
                resetSessionState()
                return
            }
            activeAudioCaptureOwner = requestedAudioOwner
        }

        print("🎙️ BuddyDictationManager: start requested (\(startSource))")

        if needsInitialPermissionPrompt {
            print("🎙️ BuddyDictationManager: requesting initial permissions")
            guard canContinueStartRequest(startRequestIdentifier) else {
                abandonStartRequestIfCurrent(startRequestIdentifier)
                return
            }
            guard SetupVisibleEffectAdmission.commit(effect: {
                NSApplication.shared.activate(
                    ignoringOtherApps: true
                )
                return true
            }) else {
                abandonStartRequestIfCurrent(startRequestIdentifier)
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                abandonStartRequestIfCurrent(startRequestIdentifier)
                return
            }

            guard canContinueStartRequest(startRequestIdentifier) else {
                abandonStartRequestIfCurrent(startRequestIdentifier)
                return
            }
        }

        lastErrorMessage = nil
        currentPermissionProblem = nil
        // This is intentionally immediately before the permission path. The
        // lower-level request functions repeat the gate at each OS prompt.
        guard canContinueStartRequest(startRequestIdentifier) else {
            abandonStartRequestIfCurrent(startRequestIdentifier)
            return
        }
        let hasPermissions = await authorizeMicrophoneAndSpeechPermissions()
        guard canContinueStartRequest(startRequestIdentifier) else {
            abandonStartRequestIfCurrent(startRequestIdentifier)
            return
        }
        guard hasPermissions else {
            print("🎙️ BuddyDictationManager: permissions missing or denied")
            abandonStartRequestIfCurrent(startRequestIdentifier)
            return
        }

        activeStartSource = startSource
        self.automaticPartnerTurnTermination =
            automaticPartnerTurnTermination
        activeDictationSessionIdentifier = startRequestIdentifier
        activeRecognitionAttemptIdentifier = nil
        speechRecoveryAttemptCount = 0
        speechRecoveryTask?.cancel()
        speechRecoveryTask = nil
        finalizationCoordinator = BuddyDictationFinalizationCoordinator(
            sessionIdentifier: startRequestIdentifier,
            startedAt: ProcessInfo.processInfo.systemUptime,
            inactivityDelaySeconds:
                Self.finalTranscriptInactivityDelaySeconds,
            hardMaximumDelaySeconds:
                Self.finalTranscriptHardMaximumDelaySeconds
        )
        // WALL 1 opens with the session. From here every audio buffer is
        // screened against Ace's own mouth before it can reach Speech
        // Recognition, and this session's audit records what was forwarded so
        // finalization can prove whether any owner audio was present at all.
        activeCaptureOrigin = Self.captureOrigin(for: startSource)
        audioConfigurationRecoveryCount = 0
        lastAudioConfigurationRecoveryUptime = nil
        selfVoiceCaptureGate.beginCaptureSession(
            startRequestIdentifier,
            origin: Self.captureOrigin(for: startSource)
        )
        shouldAutomaticallySubmitFinalDraft = shouldAutomaticallySubmitFinalDraftOnStop
        hasFinishedCurrentDictationSession = false
        isFinalizingTranscript = false
        isRecordingFromMicrophoneButton = startSource == .microphoneButton
        isRecordingFromKeyboardShortcut = startSource == .keyboardShortcut
        isRecordingAutomaticPartnerTurn =
            startSource == .partnerAutomatic
        isKeyboardShortcutSessionActiveOrFinalizing = startSource == .keyboardShortcut
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast

        guard canContinueStartRequest(startRequestIdentifier) else {
            print("🎙️ BuddyDictationManager: start cancelled (shortcut released before recording began)")
            abandonStartRequestIfCurrent(startRequestIdentifier)
            return
        }

        do {
            try await startRecognitionSession(for: startRequestIdentifier)
            guard canContinueStartRequest(startRequestIdentifier) else {
                print("🎙️ BuddyDictationManager: start cancelled (shortcut released during session start)")
                abandonStartRequestIfCurrent(startRequestIdentifier)
                return
            }
            if startSource == .microphoneButton
                || startSource == .partnerAutomatic {
                microphoneButtonRecordingStartedAt = Date()
            }
            isPreparingToRecord = false
            if startSource == .partnerAutomatic {
                beginAutomaticPartnerTurnBoundary()
            }
            print("🎙️ BuddyDictationManager: recognition session started")
        } catch {
            guard canContinueStartRequest(startRequestIdentifier) else {
                abandonStartRequestIfCurrent(startRequestIdentifier)
                return
            }

            isPreparingToRecord = false
            let failureMessage = userFacingErrorMessage(
                from: error,
                fallback: "couldn't start voice input. try again."
            )
            print("❌ BuddyDictationManager: failed to start recognition session (\(transcriptionProvider.displayName)): \(error)")

            // Apple Speech correctly refuses when this Mac has never had
            // Dictation switched on — the default state of every new Mac. That
            // refusal has always been worded well and always been delivered by
            // SPEAKING it, which is useless on a Mac whose voice is also not
            // working yet (the usual case on day one). Send it somewhere that
            // does not depend on Ace being able to talk.
            if let refusal = error as? AppleSpeechTranscriptionProviderError {
                FirstRunFailureReporter.shared.report(
                    .listeningUnavailable(providerMessage: refusal.errorDescription),
                    interrupt: !AceIntroWindowController.shared.isVisible,
                    repairRevision: "speech-settings-v1",
                    verifiedRepair: {
                        await WindowPositionManager
                            .openSettingsAndWaitForReadback(
                                .dictation,
                                permission: .speechRecognition,
                                readback: {
                                    AppleSpeechTranscriptionProvider
                                        .currentReadiness.isReady
                                }
                            )
                    }
                )
            }
            failSpeechRecoveryVisibly(
                failureMessage,
                scrubBoundary: .failure
            )
        }
    }

    private func stopPushToTalk(expectedStartSource: BuddyDictationStartSource) {
        pendingStartRequestIdentifier = UUID()

        guard !StealthEntryLatch.shared.isRaised else {
            cancelCurrentDictation(preserveDraftText: false)
            return
        }
        guard activeStartSource == expectedStartSource else {
            isPreparingToRecord = false
            return
        }
        if isPreparingToRecord {
            failSpeechRecoveryVisibly(
                SpeechRecognitionRecoveryPolicy.releasedBeforeReadyMessage,
                scrubBoundary: .failure
            )
            return
        }
        guard !isFinalizingTranscript else { return }

        print("🎙️ BuddyDictationManager: stop requested (\(expectedStartSource))")

        if let activeDictationSessionIdentifier {
            let captureAudit = selfVoiceCaptureGate.audit(
                for: activeDictationSessionIdentifier
            )
            appendDictationTimingReceipt(
                "release",
                sessionIdentifier: activeDictationSessionIdentifier,
                detail:
                    "forwarded=\(captureAudit.forwardedBufferCount) "
                    + "suppressed=\(captureAudit.suppressedBufferCount) "
                    + "audioMs=\(Int(((audioReplayBuffer?.bufferedDurationSeconds ?? 0) * 1000).rounded())) "
                    + "power=\(Int((currentAudioPowerLevel * 100).rounded()))"
            )
        }

        // Publish finalizing first. CombineLatest otherwise observes a false
        // recording flag before this true flag and briefly drives the overlay
        // to idle/completed while Speech is still producing its final result.
        isFinalizingTranscript = true
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isRecordingAutomaticPartnerTurn = false

        let recognizedText = latestRecognizedText
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        let isInstantCommand =
            draftCallbacks?
                .shouldSubmitImmediatelyOnRelease(
                    recognizedText
                ) ?? false
        if BuddyDictationReleasePolicy
            .shouldSubmitImmediately(
                sourceIsKeyboardShortcut:
                    expectedStartSource == .keyboardShortcut,
                automaticallySubmits:
                    shouldAutomaticallySubmitFinalDraft,
                recognizedText: recognizedText,
                isInstantCommand: isInstantCommand
            ) {
            LifecycleLog.append(
                "DICTATION instant command submitted on key release "
                    + "characters=\(recognizedText.count)"
            )
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: true
            )
            return
        }

        stopCurrentAudioCapture()
        releaseAudioCaptureIfNeeded()
        activeTranscriptionSession?.requestFinalTranscript()

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil
        guard let finalizingSessionIdentifier = activeDictationSessionIdentifier,
              var finalizationCoordinator else {
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft,
                expectedSessionIdentifier: activeDictationSessionIdentifier
            )
            return
        }

        let releaseDecision = finalizationCoordinator.markReleased(
            at: ProcessInfo.processInfo.systemUptime
        )
        self.finalizationCoordinator = finalizationCoordinator
        handleFinalizationDecision(
            releaseDecision,
            sessionIdentifier: finalizingSessionIdentifier
        )
    }

    private func startRecognitionSession(for sessionIdentifier: UUID) async throws {
        guard canContinueStartRequest(sessionIdentifier),
              activeDictationSessionIdentifier == sessionIdentifier else {
            throw CancellationError()
        }

        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil

        print("🎙️ BuddyDictationManager: opening transcription provider \(transcriptionProvider.displayName)")
        let recognitionAttemptIdentifier = UUID()
        activeRecognitionAttemptIdentifier = recognitionAttemptIdentifier
        let activeTranscriptionSession = try await makeTranscriptionSession(
            sessionIdentifier: sessionIdentifier,
            recognitionAttemptIdentifier: recognitionAttemptIdentifier
        )

        guard canContinueStartRequest(sessionIdentifier),
              activeDictationSessionIdentifier == sessionIdentifier,
              activeRecognitionAttemptIdentifier
                == recognitionAttemptIdentifier else {
            activeTranscriptionSession.cancel()
            throw CancellationError()
        }

        if var finalizationCoordinator,
           finalizationCoordinator.sessionIdentifier == sessionIdentifier {
            _ = finalizationCoordinator.configureFinalizationTiming(
                inactivityDelaySeconds:
                    activeTranscriptionSession
                        .finalTranscriptInactivityDelaySeconds,
                hardMaximumDelaySeconds:
                    activeTranscriptionSession
                        .finalTranscriptHardMaximumDelaySeconds
            )
            self.finalizationCoordinator = finalizationCoordinator
        }

        self.activeTranscriptionSession = activeTranscriptionSession
        print("🎙️ BuddyDictationManager: provider ready, starting audio engine")

        do {
            try startAudioCapture(
                for: sessionIdentifier,
                transcriptionSession: activeTranscriptionSession
            )
            appendDictationTimingReceipt(
                "capture-start",
                sessionIdentifier: sessionIdentifier
            )
        } catch {
            activeTranscriptionSession.cancel()
            self.activeTranscriptionSession = nil
            throw error
        }
    }

    private func makeTranscriptionSession(
        sessionIdentifier: UUID,
        recognitionAttemptIdentifier: UUID
    ) async throws -> any BuddyStreamingTranscriptionSession {
        guard let ownerTurnIdentifier = activeOwnerTurnIdentifier,
              ownerTurnIsCurrentAndUncancelled(ownerTurnIdentifier) else {
            throw CancellationError()
        }
        return try await transcriptionProvider.startStreamingSession(
            vocabulary: activeTranscriptionVocabulary
                ?? SpeechContextualVocabulary.validated(
                    capture: SpeechContextualCaptureContext(
                        backend: .codex(resolvedModelLabel: nil)
                    )
                ),
            onTranscriptUpdate: { [weak self] transcriptText in
                self?.scheduleTranscriptUpdate(
                    transcriptText,
                    sessionIdentifier: sessionIdentifier,
                    ownerTurnIdentifier: ownerTurnIdentifier,
                    recognitionAttemptIdentifier:
                        recognitionAttemptIdentifier
                )
            },
            onFinalTranscriptReady: { [weak self] transcriptText in
                self?.scheduleFinalTranscript(
                    transcriptText,
                    sessionIdentifier: sessionIdentifier,
                    ownerTurnIdentifier: ownerTurnIdentifier,
                    recognitionAttemptIdentifier:
                        recognitionAttemptIdentifier
                )
            },
            onError: { [weak self] error in
                self?.scheduleRecognitionError(
                    error,
                    sessionIdentifier: sessionIdentifier,
                    ownerTurnIdentifier: ownerTurnIdentifier,
                    recognitionAttemptIdentifier:
                        recognitionAttemptIdentifier
                )
            }
        )
    }

    private nonisolated func scheduleTranscriptUpdate(
        _ transcriptText: String,
        sessionIdentifier: UUID,
        ownerTurnIdentifier: UUID,
        recognitionAttemptIdentifier: UUID
    ) {
        _ = StealthEntryLatch.shared.performUnlessRaised {
            Task { @MainActor [weak self] in
                guard let self,
                      !StealthEntryLatch.shared.isRaised,
                      !StealthVisibilityGate.shared.isActive,
                      self.activeDictationSessionIdentifier
                        == sessionIdentifier,
                      self.activeOwnerTurnIdentifier
                        == ownerTurnIdentifier,
                      self.ownerTurnIsCurrentAndUncancelled(
                        ownerTurnIdentifier
                      ),
                      self.activeRecognitionAttemptIdentifier
                        == recognitionAttemptIdentifier,
                      var finalizationCoordinator =
                        self.finalizationCoordinator,
                      finalizationCoordinator.sessionIdentifier
                        == sessionIdentifier else { return }
                let now = ProcessInfo.processInfo.systemUptime
                let previousRecognizedText = self.latestRecognizedText
                let transcriptDidProgress =
                    finalizationCoordinator.recordPartial(
                        transcriptText,
                        at: now
                    )
                guard transcriptDidProgress else { return }
                self.latestRecognizedText =
                    finalizationCoordinator.latestCoherentTranscript
                if self.activeStartSource == .partnerAutomatic,
                   PartnerAutomaticTurnBoundary.transcriptDidChange(
                    previous: previousRecognizedText,
                    current: self.latestRecognizedText
                   ) {
                    self.automaticPartnerTranscriptLastChangedAt = Date()
                }
                self.draftCallbacks?.updateDraftText(
                    ownerTurnIdentifier,
                    self.composeDraftText(
                        withTranscribedText: self.latestRecognizedText
                    )
                )
                self.appendDictationTimingReceipt(
                    "partial-progress",
                    sessionIdentifier: sessionIdentifier
                )

                let deadlineDecision = self.isFinalizingTranscript
                    ? finalizationCoordinator.deadlineDecision(at: now)
                    : nil
                self.finalizationCoordinator = finalizationCoordinator
                if let deadlineDecision {
                    self.handleFinalizationDecision(
                        deadlineDecision,
                        sessionIdentifier: sessionIdentifier
                    )
                }
            }
            return true
        }
    }

    private nonisolated func scheduleFinalTranscript(
        _ transcriptText: String,
        sessionIdentifier: UUID,
        ownerTurnIdentifier: UUID,
        recognitionAttemptIdentifier: UUID
    ) {
        _ = StealthEntryLatch.shared.performUnlessRaised {
            Task { @MainActor [weak self] in
                guard let self,
                      !StealthEntryLatch.shared.isRaised,
                      !StealthVisibilityGate.shared.isActive,
                      self.activeDictationSessionIdentifier
                        == sessionIdentifier,
                      self.activeOwnerTurnIdentifier
                        == ownerTurnIdentifier,
                      self.ownerTurnIsCurrentAndUncancelled(
                        ownerTurnIdentifier
                      ),
                      self.activeRecognitionAttemptIdentifier
                        == recognitionAttemptIdentifier,
                      var finalizationCoordinator =
                        self.finalizationCoordinator,
                      finalizationCoordinator.sessionIdentifier
                        == sessionIdentifier else { return }
                let completion = finalizationCoordinator.recordFinal(
                    transcriptText,
                    at: ProcessInfo.processInfo.systemUptime
                )
                self.finalizationCoordinator = finalizationCoordinator
                self.latestRecognizedText =
                    finalizationCoordinator.latestCoherentTranscript
                self.appendDictationTimingReceipt(
                    "apple-final",
                    sessionIdentifier: sessionIdentifier,
                    detail: transcriptText.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty ? "empty=true" : "empty=false"
                )
                if self.isFinalizingTranscript, let completion {
                    self.applyFinalizationCompletion(
                        completion,
                        sessionIdentifier: sessionIdentifier
                    )
                }
            }
            return true
        }
    }

    private nonisolated func scheduleRecognitionError(
        _ error: Error,
        sessionIdentifier: UUID,
        ownerTurnIdentifier: UUID,
        recognitionAttemptIdentifier: UUID
    ) {
        _ = StealthEntryLatch.shared.performUnlessRaised {
            Task { @MainActor [weak self] in
                guard let self,
                      !StealthEntryLatch.shared.isRaised,
                      !StealthVisibilityGate.shared.isActive,
                      self.activeDictationSessionIdentifier
                        == sessionIdentifier,
                      self.activeOwnerTurnIdentifier
                        == ownerTurnIdentifier,
                      self.ownerTurnIsCurrentAndUncancelled(
                        ownerTurnIdentifier
                      ),
                      self.activeRecognitionAttemptIdentifier
                        == recognitionAttemptIdentifier else { return }
                self.handleRecognitionError(error)
            }
            return true
        }
    }

    private func startAudioCapture(
        for sessionIdentifier: UUID,
        transcriptionSession activeTranscriptionSession:
            any BuddyStreamingTranscriptionSession
    ) throws {

        let audioCaptureLease = try audioCaptureFactory()
        self.audioCaptureLease = audioCaptureLease
        let inputFormat = audioCaptureLease.inputFormat
        LifecycleLog.append(
            "DICTATION audio lease rate=\(Int(inputFormat.sampleRate)) "
                + "channels=\(inputFormat.channelCount)"
        )
        let transcriptionSessionForAudioTap = activeTranscriptionSession
        guard let ownerTurnIdentifierForAudioTap =
                activeOwnerTurnIdentifier,
              let audioReplayBufferForAudioTap = audioReplayBuffer else {
            throw CancellationError()
        }
        // The tap runs on AVAudio's render thread and cannot touch MainActor
        // state. The gate is `nonisolated` and lock-guarded precisely so it can
        // be captured and consulted from there, same idiom as the cutoff boxes
        // below.
        let selfVoiceCaptureGateForAudioTap = selfVoiceCaptureGate
        let transcriptionSessionCutoffBox =
            BuddyTranscriptionSessionCutoffBox(
                transcriptionSessionForAudioTap
            )
        let stopAudioEngine: @Sendable () -> Void
        if let synchronousAudioEngine =
                audioCaptureLease.synchronousAudioEngine {
            let audioEngineCutoffBox = BuddyAudioEngineCutoffBox(
                synchronousAudioEngine
            )
            stopAudioEngine = {
                audioEngineCutoffBox.stop()
            }
        } else {
            stopAudioEngine = {}
        }
        let audioBoundary = BuddyDictationAudioBoundary(
            stopAudioEngine: stopAudioEngine,
            cancelProvider: {
                transcriptionSessionCutoffBox.cancel()
            }
        )

        let didInstallAudioTap = StealthEntryLatch.shared
            .performUnlessRaised {
                audioCaptureLease.installTap(
                    bufferSize: 1024
                ) { [weak self] buffer, _ in
                    switch audioBoundary.action(
                        stealthEntryIsRaised:
                            StealthEntryLatch.shared.isRaised
                    ) {
                    case .drop:
                        return
                    case .dropAndCancel:
                        return
                    case .forward:
                        break
                    }

                    // WALL 1 — SELF-VOICE SUPPRESSION AT THE CAPTURE BOUNDARY.
                    //
                    // Screened HERE, before the buffer reaches the recognizer,
                    // because a transcript of Ace's own voice is byte-for-byte
                    // indistinguishable from a transcript of the owner's. Once
                    // Ace's words have been transcribed, no downstream check can
                    // tell them apart — which is exactly how an outbound line
                    // containing "open apple dot com" used to open a browser.
                    //
                    // Every call is counted, suppressed or not, so the audit can
                    // prove afterwards whether this session heard the owner at
                    // all. Suppression is observable, never silent.
                    let selfVoiceDecision =
                        selfVoiceCaptureGateForAudioTap.admitAudioBuffer(
                            session: sessionIdentifier
                        )
                    guard case .forward = selfVoiceDecision else { return }

                    // This is the exact X-chord ordering point for every
                    // provider: either this bounded append commits first, or
                    // the entry latch rises first and the buffer never reaches
                    // the provider.
                    let didAppend: Bool? =
                        StealthEntryLatch.shared.performUnlessRaised {
                            guard audioReplayBufferForAudioTap.append(
                                buffer,
                                for: ownerTurnIdentifierForAudioTap,
                                atUptime:
                                    ProcessInfo.processInfo.systemUptime
                            ) else { return false }
                            transcriptionSessionForAudioTap
                                .appendAudioBuffer(buffer)
                            return true
                        }
                    guard didAppend == true else {
                        _ = audioBoundary.action(
                            stealthEntryIsRaised: true
                        )
                        return
                    }

                    guard !StealthEntryLatch.shared.isRaised else {
                        _ = audioBoundary.action(
                            stealthEntryIsRaised: true
                        )
                        return
                    }
                    self?.updateAudioPowerLevel(from: buffer, sessionIdentifier: sessionIdentifier)
                }
                return true
            }

        guard didInstallAudioTap == true,
              canContinueStartRequest(sessionIdentifier),
              activeDictationSessionIdentifier == sessionIdentifier else {
            audioCaptureLease.stop()
            if self.audioCaptureLease === audioCaptureLease {
                self.audioCaptureLease = nil
            }
            throw CancellationError()
        }

        // Native microphone admission is linearized with X. This closure
        // contains only AVAudioEngine's bounded synchronous prepare/start call.
        // If start wins, the already-registered audio boundary stops the exact
        // engine when entry raises; if entry wins, neither call is made.
        do {
            let didStartAudioEngine = try StealthEntryLatch.shared
                .performUnlessRaised {
                    try audioCaptureLease.start()
                    return true
                }
            guard didStartAudioEngine == true,
                  canContinueStartRequest(sessionIdentifier),
                  activeDictationSessionIdentifier == sessionIdentifier else {
                throw CancellationError()
            }
            observeAudioConfigurationChanges(
                for: audioCaptureLease,
                sessionIdentifier: sessionIdentifier
            )
        } catch {
            audioCaptureLease.stop()
            if self.audioCaptureLease === audioCaptureLease {
                self.audioCaptureLease = nil
            }
            throw error
        }
    }

    private func observeAudioConfigurationChanges(
        for lease: any BuddyDictationAudioCapturing,
        sessionIdentifier: UUID
    ) {
        if let audioConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(
                audioConfigurationChangeObserver
            )
        }
        guard let notificationObject =
                lease.configurationChangeNotificationObject else { return }
        let leaseIdentifier = ObjectIdentifier(lease)
        audioConfigurationChangeObserver = NotificationCenter.default
            .addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: notificationObject,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                          let lease = self.audioCaptureLease,
                          ObjectIdentifier(lease) == leaseIdentifier else {
                        return
                    }
                    self.recoverAudioCaptureAfterConfigurationChange(
                        for: lease,
                        sessionIdentifier: sessionIdentifier
                    )
                }
            }
    }

    private func recoverAudioCaptureAfterConfigurationChange(
        for lease: any BuddyDictationAudioCapturing,
        sessionIdentifier: UUID
    ) {
        guard audioCaptureLease === lease,
              activeDictationSessionIdentifier == sessionIdentifier,
              !isFinalizingTranscript,
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else { return }

        guard lease.needsConfigurationRecovery else {
            LifecycleLog.append("DICTATION audio configuration settled; capture retained")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastRecovery = lastAudioConfigurationRecoveryUptime,
           now - lastRecovery >= 2 {
            // Bound a burst of failed restarts, not all device changes during
            // a long Partner conversation.
            audioConfigurationRecoveryCount = 0
        }
        lastAudioConfigurationRecoveryUptime = now

        let recoveryAttempt = audioConfigurationRecoveryCount + 1
        LifecycleLog.append(
            "DICTATION audio configuration changed; recovering "
                + "attempt=\(recoveryAttempt)"
        )
        stopCurrentAudioCapture()

        guard recoveryAttempt <= 2,
              let activeTranscriptionSession else {
            failAudioConfigurationRecovery()
            return
        }
        audioConfigurationRecoveryCount = recoveryAttempt

        do {
            try startAudioCapture(
                for: sessionIdentifier,
                transcriptionSession: activeTranscriptionSession
            )
            guard let recoveredFormat = audioCaptureLease?.inputFormat else {
                throw BuddyDictationAudioCaptureError.unusableInputFormat(
                    sampleRate: 0,
                    channels: 0
                )
            }
            LifecycleLog.append(
                "DICTATION audio configuration recovered "
                    + "attempt=\(recoveryAttempt) "
                    + "rate=\(Int(recoveredFormat.sampleRate)) "
                    + "channels=\(recoveredFormat.channelCount)"
            )
        } catch {
            LifecycleLog.append(
                "DICTATION audio configuration recovery failed "
                    + "attempt=\(recoveryAttempt) error=\(error.localizedDescription)"
            )
            failAudioConfigurationRecovery()
        }
    }

    private func failAudioConfigurationRecovery() {
        // A real device fault, so it stays — but it says what actually
        // happened (the input device changed mid-sentence and two restarts
        // did not take), and it says what survived: `preserveDraftText: true`
        // below writes the partial transcript back to the draft, so the owner
        // is not being told to start over.
        let message = "your audio input device changed mid-sentence and two "
            + "restarts didn't take, so recording stopped. what you'd already "
            + "said is kept in the draft. press push to talk once the device settles."
        lastErrorMessage = message
        let partnerTermination = automaticPartnerTurnTermination
        cancelCurrentDictation(preserveDraftText: true)
        onAudioSessionRefusal?(message)
        partnerTermination?(.recognitionFailed(message))
    }

    private func handleFinalizationDecision(
        _ decision:
            BuddyDictationFinalizationCoordinator.DeadlineDecision,
        sessionIdentifier: UUID
    ) {
        guard activeDictationSessionIdentifier == sessionIdentifier else {
            return
        }

        switch decision {
        case .notReleased, .finished:
            return
        case .wait(let deadlineUptime):
            scheduleFinalizationDeadline(
                at: deadlineUptime,
                sessionIdentifier: sessionIdentifier
            )
        case .complete(let completion, let reason):
            finalizeFallbackWorkItem?.cancel()
            finalizeFallbackWorkItem = nil
            switch reason {
            case .appleFinal:
                break
            case .inactivity:
                appendDictationTimingReceipt(
                    "fallback",
                    sessionIdentifier: sessionIdentifier,
                    detail: "reason=inactivity"
                )
                if case .finishWithoutTranscript = completion {
                    scrubReplayAudio(.timeout)
                }
            case .hardMaximum:
                appendDictationTimingReceipt(
                    "fallback",
                    sessionIdentifier: sessionIdentifier,
                    detail: "reason=hard-maximum"
                )
                if case .finishWithoutTranscript = completion {
                    scrubReplayAudio(.timeout)
                }
            }
            applyFinalizationCompletion(
                completion,
                sessionIdentifier: sessionIdentifier
            )
        }
    }

    private func scheduleFinalizationDeadline(
        at deadlineUptime: TimeInterval,
        sessionIdentifier: UUID
    ) {
        finalizeFallbackWorkItem?.cancel()
        let delaySeconds = max(
            0,
            deadlineUptime - ProcessInfo.processInfo.systemUptime
        )
        let deadlineWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.isFinalizingTranscript,
                      self.activeDictationSessionIdentifier
                        == sessionIdentifier,
                      var finalizationCoordinator =
                        self.finalizationCoordinator,
                      finalizationCoordinator.sessionIdentifier
                        == sessionIdentifier else { return }
                let nextDecision =
                    finalizationCoordinator.deadlineDecision(
                        at: ProcessInfo.processInfo.systemUptime
                    )
                self.finalizationCoordinator =
                    finalizationCoordinator
                self.handleFinalizationDecision(
                    nextDecision,
                    sessionIdentifier: sessionIdentifier
                )
            }
        }
        finalizeFallbackWorkItem = deadlineWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delaySeconds,
            execute: deadlineWorkItem
        )
    }

    private func applyFinalizationCompletion(
        _ completion: BuddyDictationFinalizationCoordinator.Completion,
        sessionIdentifier: UUID
    ) {
        guard activeDictationSessionIdentifier == sessionIdentifier else {
            return
        }
        switch completion {
        case .submit(let transcript):
            latestRecognizedText = transcript
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft:
                    shouldAutomaticallySubmitFinalDraft,
                expectedSessionIdentifier: sessionIdentifier
            )
        case .finishWithoutTranscript:
            latestRecognizedText = ""
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft:
                    shouldAutomaticallySubmitFinalDraft,
                expectedSessionIdentifier: sessionIdentifier
            )
        case .cancelledForRestart:
            cancelCurrentDictation(preserveDraftText: false)
        }
    }

    private func appendDictationTimingReceipt(
        _ event: String,
        sessionIdentifier: UUID,
        detail: String? = nil
    ) {
        var receipt = "DICTATION session="
            + String(sessionIdentifier.uuidString.prefix(8))
            + " event=" + event
            + " uptimeMs=\(Int((ProcessInfo.processInfo.systemUptime * 1000).rounded()))"
        if let detail, !detail.isEmpty {
            receipt += " " + detail
        }
        LifecycleLog.append(receipt)
    }

    private func beginSingleSpeechReplay(
        sessionIdentifier: UUID,
        ownerTurnIdentifier: UUID
    ) {
        let recognitionAttemptIdentifier = UUID()
        activeRecognitionAttemptIdentifier = recognitionAttemptIdentifier
        activeTranscriptionSession?.cancel()
        activeTranscriptionSession = nil
        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        speechRecoveryTask?.cancel()
        speechRecoveryTask = Task { @MainActor [weak self] in
            guard let self,
                  !Task.isCancelled,
                  !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive,
                  self.activeDictationSessionIdentifier
                    == sessionIdentifier,
                  self.activeOwnerTurnIdentifier
                    == ownerTurnIdentifier,
                  self.activeRecognitionAttemptIdentifier
                    == recognitionAttemptIdentifier,
                  self.eventBus.currentTurnID
                    == ownerTurnIdentifier,
                  !self.eventBus.isTurnCancelled(
                    ownerTurnIdentifier
                  ),
                  let audioReplayBuffer = self.audioReplayBuffer else {
                return
            }

            do {
                let replaySession = try await self.makeTranscriptionSession(
                    sessionIdentifier: sessionIdentifier,
                    recognitionAttemptIdentifier:
                        recognitionAttemptIdentifier
                )
                guard !Task.isCancelled,
                      !StealthEntryLatch.shared.isRaised,
                      !StealthVisibilityGate.shared.isActive,
                      self.activeDictationSessionIdentifier
                        == sessionIdentifier,
                      self.activeOwnerTurnIdentifier
                        == ownerTurnIdentifier,
                      self.activeRecognitionAttemptIdentifier
                        == recognitionAttemptIdentifier,
                      self.eventBus.currentTurnID
                        == ownerTurnIdentifier,
                      !self.eventBus.isTurnCancelled(
                        ownerTurnIdentifier
                      ) else {
                    replaySession.cancel()
                    self.scrubReplayAudio(.wrongTurn)
                    return
                }

                let replayResult = audioReplayBuffer.replayOnce(
                    for: ownerTurnIdentifier,
                    atUptime: ProcessInfo.processInfo.systemUptime,
                    isCancelled: false
                ) { buffers in
                    for buffer in buffers {
                        replaySession.appendAudioBuffer(buffer)
                    }
                }
                guard case .replayed(let replayBufferCount) = replayResult else {
                    replaySession.cancel()
                    let scrubBoundary: BuddyAudioReplayScrubBoundary
                    if case .refused(.expired) = replayResult {
                        scrubBoundary = .timeout
                    } else if case .refused(.wrongTurn) = replayResult {
                        scrubBoundary = .wrongTurn
                    } else {
                        scrubBoundary = .cancellation
                    }
                    self.failSpeechRecoveryVisibly(
                        "couldn't transcribe that. press Command Shift and try again.",
                        scrubBoundary: scrubBoundary
                    )
                    return
                }
                self.scrubReplayAudio(.replayCompletion)

                self.activeTranscriptionSession = replaySession
                let now = ProcessInfo.processInfo.systemUptime
                var replayFinalization =
                    BuddyDictationFinalizationCoordinator(
                        sessionIdentifier: sessionIdentifier,
                        startedAt: now,
                        inactivityDelaySeconds:
                            replaySession
                                .finalTranscriptInactivityDelaySeconds,
                        hardMaximumDelaySeconds:
                            replaySession
                                .finalTranscriptHardMaximumDelaySeconds
                    )
                let deadline = replayFinalization.markReleased(at: now)
                self.finalizationCoordinator = replayFinalization
                replaySession.requestFinalTranscript()
                self.appendDictationTimingReceipt(
                    "replay",
                    sessionIdentifier: sessionIdentifier,
                    detail:
                        "attempt=1 buffers=\(replayBufferCount)"
                )
                self.handleFinalizationDecision(
                    deadline,
                    sessionIdentifier: sessionIdentifier
                )
                if self.activeRecognitionAttemptIdentifier
                    == recognitionAttemptIdentifier {
                    self.speechRecoveryTask = nil
                }
            } catch {
                guard self.activeDictationSessionIdentifier
                        == sessionIdentifier,
                      self.activeRecognitionAttemptIdentifier
                        == recognitionAttemptIdentifier else { return }
                self.failSpeechRecoveryVisibly(
                    self.userFacingErrorMessage(
                        from: error,
                        fallback:
                            "couldn't transcribe that. press Command Shift and try again."
                    ),
                    scrubBoundary: .cancellation
                )
            }
        }
    }

    private func failSpeechRecoveryVisibly(
        _ message: String,
        scrubBoundary: BuddyAudioReplayScrubBoundary
    ) {
        guard let ownerTurnID = activeOwnerTurnIdentifier,
              ownerTurnIsCurrentAndUncancelled(ownerTurnID),
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else {
            cancelCurrentDictation(
                preserveDraftText: false,
                replayScrubBoundary: scrubBoundary
            )
            return
        }
        lastErrorMessage = message
        let partnerTermination = activeStartSource == .partnerAutomatic
            ? automaticPartnerTurnTermination : nil
        if let sessionIdentifier = activeDictationSessionIdentifier
            ?? claimedPhysicalGenerationIdentifier {
            appendDictationTimingReceipt(
                "failed",
                sessionIdentifier: sessionIdentifier,
                detail: "reason=voice-input source=\(String(describing: activeStartSource))"
            )
        }
        hasFinishedCurrentDictationSession = true
        cancelCurrentDictation(
            preserveDraftText: false,
            replayScrubBoundary: .failure
        )
        guard ownerTurnIsCurrentAndUncancelled(ownerTurnID),
              !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else { return }
        onDictationFailure?(ownerTurnID, message)
        partnerTermination?(.recognitionFailed(message))
    }

    private func handleRecognitionError(_ error: Error) {
        if hasFinishedCurrentDictationSession {
            return
        }

        if let activeDictationSessionIdentifier {
            let captureAudit = selfVoiceCaptureGate.audit(
                for: activeDictationSessionIdentifier
            )
            let nativeError = error as NSError
            appendDictationTimingReceipt(
                "recognition-error",
                sessionIdentifier: activeDictationSessionIdentifier,
                detail:
                    "domain=\(nativeError.domain) "
                    + "code=\(nativeError.code) "
                    + "finalizing=\(isFinalizingTranscript) "
                    + "characters=\(latestRecognizedText.count) "
                    + "forwarded=\(captureAudit.forwardedBufferCount) "
                    + "suppressed=\(captureAudit.suppressedBufferCount)"
            )
        }

        guard let sessionIdentifier = activeDictationSessionIdentifier,
              let ownerTurnIdentifier = activeOwnerTurnIdentifier else {
            failSpeechRecoveryVisibly(
                "couldn't transcribe that. press Command Shift and try again.",
                scrubBoundary: .cancellation
            )
            return
        }

        let ownerTurnWasCancelled =
            eventBus.isTurnCancelled(ownerTurnIdentifier)
        let audioEligibility: BuddyAudioReplayEligibility
        if eventBus.currentTurnID != ownerTurnIdentifier {
            scrubReplayAudio(.wrongTurn)
            audioEligibility = .wrongTurn
        } else if let audioReplayBuffer {
            audioEligibility = audioReplayBuffer.eligibility(
                for: ownerTurnIdentifier,
                atUptime: ProcessInfo.processInfo.systemUptime,
                isCancelled: ownerTurnWasCancelled
            )
        } else {
            audioEligibility = .missing
        }

        let nativeError = error as NSError
        let action = SpeechRecognitionRecoveryPolicy.action(
            for: SpeechRecognitionRecoveryRequest(
                provider: transcriptionProvider.recoveryProvider,
                errorDomain: nativeError.domain,
                errorCode: nativeError.code,
                isFinalizing: isFinalizingTranscript,
                retainedText: latestRecognizedText,
                replayAttemptCount: speechRecoveryAttemptCount,
                audioEligibility: audioEligibility
            )
        )
        switch action {
        case .replayOnce:
            speechRecoveryAttemptCount += 1
            beginSingleSpeechReplay(
                sessionIdentifier: sessionIdentifier,
                ownerTurnIdentifier: ownerTurnIdentifier
            )
        case .submitRetainedText(let retainedText):
            latestRecognizedText = retainedText
            appendDictationTimingReceipt(
                "retained-text",
                sessionIdentifier: sessionIdentifier,
                detail: "characters=\(retainedText.count)"
            )
            finishCurrentDictationSessionIfNeeded(
                shouldSubmitFinalDraft: shouldAutomaticallySubmitFinalDraft,
                expectedSessionIdentifier: sessionIdentifier
            )
        case .failVisible(let fallbackMessage):
            print(
                "❌ Buddy dictation error "
                    + "(\(transcriptionProvider.displayName)): \(error)"
            )
            let isAppleNoTextError =
                nativeError.domain == SpeechRecognitionRecoveryPolicy.appleNoTextErrorDomain
                    && nativeError.code == SpeechRecognitionRecoveryPolicy.appleNoTextErrorCode
            let errorMessage = isAppleNoTextError
                ? fallbackMessage
                : userFacingErrorMessage(from: error, fallback: fallbackMessage)
            let scrubBoundary: BuddyAudioReplayScrubBoundary
            switch audioEligibility {
            case .wrongTurn:
                scrubBoundary = .wrongTurn
            case .expired:
                scrubBoundary = .timeout
            case .cancelled:
                scrubBoundary = .cancellation
            case .authorized, .missing, .alreadyReplayed:
                scrubBoundary = .cancellation
            }
            failSpeechRecoveryVisibly(
                errorMessage,
                scrubBoundary: scrubBoundary
            )
        }
    }

    private func finishCurrentDictationSessionIfNeeded(
        shouldSubmitFinalDraft: Bool,
        expectedSessionIdentifier: UUID? = nil
    ) {
        if let expectedSessionIdentifier {
            guard activeDictationSessionIdentifier == expectedSessionIdentifier else { return }
        }
        guard !StealthEntryLatch.shared.isRaised,
              !StealthVisibilityGate.shared.isActive else {
            cancelCurrentDictation(preserveDraftText: false)
            return
        }
        guard let capturedOwnerTurnID = activeOwnerTurnIdentifier,
              ownerTurnIsCurrentAndUncancelled(capturedOwnerTurnID) else {
            cancelCurrentDictation(
                preserveDraftText: false,
                replayScrubBoundary: .wrongTurn
            )
            return
        }
        guard !hasFinishedCurrentDictationSession else { return }
        if activeStartSource == .keyboardShortcut,
           shouldSubmitFinalDraft,
           latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failSpeechRecoveryVisibly(
                SpeechRecognitionRecoveryPolicy.noSpeechMessage,
                scrubBoundary: .failure
            )
            return
        }
        hasFinishedCurrentDictationSession = true

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil

        let finalDraftText = composeDraftText(withTranscribedText: latestRecognizedText)
        let finalTranscriptText = latestRecognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentDraftCallbacks = draftCallbacks

        // WALL 1, second half — asked once, at the one finalization point.
        //
        // Suppressing buffers keeps Ace's voice out of the recognizer, but a
        // recognizer that was ALREADY holding Ace's words can still emit a
        // final. So: a session that forwarded nothing contained no owner audio
        // by construction, and its transcript — however microphone-derived and
        // however command-shaped — is not the owner speaking.
        //
        // A session that forwarded even one buffer DID contain owner audio, and
        // its final is submitted normally. That is the half of the rule that
        // keeps suppression from eating real speech after the tail.
        let capturingSessionIdentifier = activeDictationSessionIdentifier
        let captureOrigin = activeCaptureOrigin ?? .pushToTalk
        var selfVoiceBlockedThisFinal = false
        if let capturingSessionIdentifier {
            let audit = selfVoiceCaptureGate.audit(for: capturingSessionIdentifier)
            selfVoiceBlockedThisFinal = !selfVoiceCaptureGate
                .admitsFinalTranscript(session: capturingSessionIdentifier)
            if audit.didSuppressAnything {
                let outcome = selfVoiceBlockedThisFinal
                    ? "final-blocked-self-voice"
                    : "final-admitted"
                let observedOrigin = captureOrigin
                let observedAudit = audit
                eventBus.recordCaptureGate(
                    origin: observedOrigin,
                    audit: observedAudit,
                    outcome: outcome,
                    turnID: capturedOwnerTurnID
                )
            }
            selfVoiceCaptureGate.endCaptureSession(capturingSessionIdentifier)
        }

        if !shouldSubmitFinalDraft && !finalDraftText.isEmpty && !selfVoiceBlockedThisFinal {
            currentDraftCallbacks?.updateDraftText(
                capturedOwnerTurnID,
                finalDraftText
            )
        }

        stopCurrentAudioCapture()
        releaseAudioCaptureIfNeeded()
        activeTranscriptionSession?.cancel()

        if let capturingSessionIdentifier {
            let outcome: String
            if selfVoiceBlockedThisFinal {
                outcome = "blocked-self-voice"
            } else if finalTranscriptText.isEmpty {
                outcome = "empty"
            } else if shouldSubmitFinalDraft {
                outcome = "submitted"
            } else {
                outcome = "draft-updated"
            }
            appendDictationTimingReceipt(
                "routed-final",
                sessionIdentifier: capturingSessionIdentifier,
                detail: "outcome=\(outcome)"
            )
        }

        resetSessionState(scrubBoundary: .success)

        guard shouldSubmitFinalDraft else { return }
        guard !finalTranscriptText.isEmpty else { return }
        // Ace heard only itself. Nothing is submitted, nothing is routed, and
        // the receipt above already says so.
        guard !selfVoiceBlockedThisFinal else { return }
        guard eventBus.currentTurnID == capturedOwnerTurnID,
              !eventBus.isTurnCancelled(capturedOwnerTurnID) else { return }

        currentDraftCallbacks?.submitDraftText(
            capturedOwnerTurnID,
            finalDraftText
        )
    }

    private func composeDraftText(withTranscribedText transcribedText: String) -> String {
        let trimmedTranscriptText = transcribedText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTranscriptText.isEmpty else {
            return draftTextBeforeCurrentDictation
        }

        let trimmedExistingDraftText = draftTextBeforeCurrentDictation
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedExistingDraftText.isEmpty else {
            return trimmedTranscriptText
        }

        if draftTextBeforeCurrentDictation.hasSuffix(" ") || draftTextBeforeCurrentDictation.hasSuffix("\n") {
            return draftTextBeforeCurrentDictation + trimmedTranscriptText
        }

        return draftTextBeforeCurrentDictation + " " + trimmedTranscriptText
    }

    private func resetSessionState(
        scrubBoundary: BuddyAudioReplayScrubBoundary = .cancellation
    ) {
        stopCurrentAudioCapture()
        releaseAudioCaptureIfNeeded()
        speechRecoveryTask?.cancel()
        speechRecoveryTask = nil
        scrubReplayAudio(scrubBoundary)
        audioReplayBuffer = nil
        // The capture session is over on every teardown path — normal finish,
        // cancellation, Stealth, error. Leaving its audit behind would let a
        // later session inherit a suppression verdict that was never about it.
        if let finishedSessionIdentifier = activeDictationSessionIdentifier {
            selfVoiceCaptureGate.endCaptureSession(finishedSessionIdentifier)
        }
        activeCaptureOrigin = nil
        audioConfigurationRecoveryCount = 0
        automaticPartnerTurnTimer?.invalidate()
        automaticPartnerTurnTimer = nil
        automaticPartnerTurnStartedAt = nil
        automaticPartnerTranscriptLastChangedAt = nil
        lastAutomaticPartnerAudioActivityAt = nil
        automaticPartnerSpeechActivity = PartnerSpeechActivity()
        automaticPartnerTurnTermination = nil
        finalizationCoordinator = nil
        if let claimedPhysicalGenerationIdentifier {
            _ = physicalGenerationGate.release(
                claimedPhysicalGenerationIdentifier
            )
            self.claimedPhysicalGenerationIdentifier = nil
        }
        pendingStartRequestIdentifier = UUID()
        activeDictationSessionIdentifier = nil
        activeOwnerTurnIdentifier = nil
        activeRecognitionAttemptIdentifier = nil
        activeTranscriptionSession = nil
        pendingContextualCaptureContext = nil
        activeTranscriptionVocabulary = nil
        speechRecoveryAttemptCount = 0
        draftCallbacks = nil
        activeStartSource = nil
        draftTextBeforeCurrentDictation = ""
        latestRecognizedText = ""
        shouldAutomaticallySubmitFinalDraft = false
        hasFinishedCurrentDictationSession = false
        isPreparingToRecord = false
        isRecordingFromMicrophoneButton = false
        isRecordingFromKeyboardShortcut = false
        isRecordingAutomaticPartnerTurn = false
        isKeyboardShortcutSessionActiveOrFinalizing = false
        isFinalizingTranscript = false
        currentAudioPowerLevel = 0
        recordedAudioPowerHistory = Array(
            repeating: Self.recordedAudioPowerHistoryBaselineLevel,
            count: Self.recordedAudioPowerHistoryLength
        )
        microphoneButtonRecordingStartedAt = nil
        lastRecordedAudioPowerSampleDate = .distantPast
    }

    private func scrubReplayAudio(
        _ boundary: BuddyAudioReplayScrubBoundary
    ) {
        audioReplayBuffer?.scrub(boundary)
        onAudioReplayScrubBoundary?(boundary)
    }

    private func releaseAudioCaptureIfNeeded() {
        guard let activeAudioCaptureOwner else { return }
        self.activeAudioCaptureOwner = nil
        _ = audioSessionCoordinator?.releaseCapture(
            activeAudioCaptureOwner
        )
    }

    private func beginAutomaticPartnerTurnBoundary() {
        automaticPartnerTurnTimer?.invalidate()
        let startTime = Date()
        automaticPartnerTurnStartedAt = startTime
        automaticPartnerTranscriptLastChangedAt = startTime
        let boundaryTimer = Timer(
            timeInterval: 0.15,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.activeStartSource == .partnerAutomatic,
                      self.isRecordingAutomaticPartnerTurn,
                      let startedAt =
                        self.automaticPartnerTurnStartedAt,
                      let transcriptChangedAt =
                        self.automaticPartnerTranscriptLastChangedAt else {
                    return
                }
                let now = Date()
                let secondsSinceStart =
                    now.timeIntervalSince(startedAt)
                let transcript = self.latestRecognizedText
                switch PartnerAutomaticTurnBoundary.action(
                    transcript: transcript,
                    secondsSinceTranscriptChanged:
                        now.timeIntervalSince(
                            transcriptChangedAt
                        ),
                    secondsSinceRecordingStarted:
                        secondsSinceStart,
                    currentAudioPowerLevel:
                        Double(self.currentAudioPowerLevel),
                    secondsSinceSpeechActivity:
                        now.timeIntervalSince(self.lastAutomaticPartnerAudioActivityAt ?? startedAt)
                ) {
                case .keepListening:
                    return
                case .renewSilentListeningWindow:
                    let partnerTermination =
                        self.automaticPartnerTurnTermination
                    self.cancelCurrentDictation(
                        preserveDraftText: false
                    )
                    partnerTermination?(
                        .silentWindowExpired
                    )
                    return
                case .finalizeTranscript:
                    self.appendDictationTimingReceipt(
                        "automatic-boundary",
                        sessionIdentifier: self.activeDictationSessionIdentifier ?? UUID(),
                        detail: "stableMs=\(Int(now.timeIntervalSince(transcriptChangedAt) * 1000)) "
                            + "speechQuietMs=\(Int(now.timeIntervalSince(self.lastAutomaticPartnerAudioActivityAt ?? startedAt) * 1000)) "
                            + "threshold=\(self.automaticPartnerSpeechActivity.threshold)"
                    )
                    self.stopAutomaticPartnerTurn()
                }
            }
        }
        automaticPartnerTurnTimer = boundaryTimer
        RunLoop.main.add(boundaryTimer, forMode: .common)
    }

    private func canContinueStartRequest(_ startRequestIdentifier: UUID) -> Bool {
        let activeTurnIsValid = activeOwnerTurnIdentifier.map {
            ownerTurnIsCurrentAndUncancelled($0)
        } ?? true
        return !Task.isCancelled
            && !StealthEntryLatch.shared.isRaised
            && !StealthVisibilityGate.shared.isActive
            && pendingStartRequestIdentifier == startRequestIdentifier
            && activeTurnIsValid
    }

    private func ownerTurnIsCurrentAndUncancelled(_ turnID: UUID) -> Bool {
        eventBus.currentTurnID == turnID
            && !eventBus.isTurnCancelled(turnID)
    }

    private func observeOwnerTurnReplacement() {
        _ = eventBus.observeOwnerTurnReplacements { [weak self] replacement in
            guard let self else { return false }
            guard self.activeOwnerTurnIdentifier
                    == replacement.previousTurnID else { return true }

            // This callback is synchronous inside AceEventBus.beginOwnerTurn.
            // No queued provider callback can observe the replacement as its
            // own authority before the exact audio/task/context is torn down.
            self.pendingStartRequestIdentifier = UUID()
            self.activePermissionRequestTask?.task.cancel()
            self.activePermissionRequestTask = nil
            self.finalizeFallbackWorkItem?.cancel()
            self.finalizeFallbackWorkItem = nil
            self.speechRecoveryTask?.cancel()
            self.speechRecoveryTask = nil
            self.stopCurrentAudioCapture()
            self.activeTranscriptionSession?.cancel()
            self.resetSessionState(scrubBoundary: .wrongTurn)
            return true
        }
    }

    private func abandonStartRequestIfCurrent(_ startRequestIdentifier: UUID) {
        guard pendingStartRequestIdentifier == startRequestIdentifier
                || activeDictationSessionIdentifier == startRequestIdentifier else {
            return
        }

        finalizeFallbackWorkItem?.cancel()
        finalizeFallbackWorkItem = nil
        if activeDictationSessionIdentifier == startRequestIdentifier
            || activeTranscriptionSession != nil {
            stopCurrentAudioCapture()
            activeTranscriptionSession?.cancel()
        }
        resetSessionState()
    }

    private func stopCurrentAudioCapture() {
        if let audioConfigurationChangeObserver {
            NotificationCenter.default.removeObserver(
                audioConfigurationChangeObserver
            )
            self.audioConfigurationChangeObserver = nil
        }
        audioCaptureLease?.stop()
        audioCaptureLease = nil
    }

    private var permissionRequestsAreAllowed: Bool {
        !Task.isCancelled
            && !StealthEntryLatch.shared.isRaised
            && !StealthVisibilityGate.shared.isActive
    }

    private func authorizeMicrophoneAndSpeechPermissions() async -> Bool {
        if let permissionAuthorizer {
            return await permissionAuthorizer()
        }
        return await requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts()
    }

    private func updateAudioPowerLevel(from audioBuffer: AVAudioPCMBuffer, sessionIdentifier: UUID) {
        guard !StealthEntryLatch.shared.isRaised else { return }
        guard let channelData = audioBuffer.floatChannelData else { return }

        let channelSamples = channelData[0]
        let frameCount = Int(audioBuffer.frameLength)
        guard frameCount > 0 else { return }

        var summedSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelSamples[sampleIndex]
            summedSquares += sample * sample
        }

        let rootMeanSquare = sqrt(summedSquares / Float(frameCount))
        let boostedLevel = min(max(rootMeanSquare * 10.2, 0), 1)

        _ = StealthEntryLatch.shared.performUnlessRaised {
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !StealthEntryLatch.shared.isRaised,
                      self.activeDictationSessionIdentifier == sessionIdentifier else { return }

                let smoothedAudioPowerLevel = max(
                    CGFloat(boostedLevel),
                    self.currentAudioPowerLevel * 0.72
                )
                self.currentAudioPowerLevel = smoothedAudioPowerLevel

                let now = Date()
                if self.activeStartSource == .partnerAutomatic,
                   self.automaticPartnerSpeechActivity.observe(
                    level: Double(boostedLevel), at: now.timeIntervalSinceReferenceDate
                   ) {
                    self.lastAutomaticPartnerAudioActivityAt = now
                }
                if now.timeIntervalSince(self.lastRecordedAudioPowerSampleDate)
                    >= Self.recordedAudioPowerHistorySampleIntervalSeconds {
                    self.lastRecordedAudioPowerSampleDate = now
                    self.appendRecordedAudioPowerSample(
                        max(CGFloat(boostedLevel), Self.recordedAudioPowerHistoryBaselineLevel)
                    )
                }
            }
            return true
        }
    }

    private func appendRecordedAudioPowerSample(_ audioPowerSample: CGFloat) {
        var updatedRecordedAudioPowerHistory = recordedAudioPowerHistory
        updatedRecordedAudioPowerHistory.append(audioPowerSample)

        if updatedRecordedAudioPowerHistory.count > Self.recordedAudioPowerHistoryLength {
            updatedRecordedAudioPowerHistory.removeFirst(
                updatedRecordedAudioPowerHistory.count - Self.recordedAudioPowerHistoryLength
            )
        }

        recordedAudioPowerHistory = updatedRecordedAudioPowerHistory
    }

    private func requestMicrophoneAndSpeechPermissionsIfNeeded() async -> Bool {
        guard permissionRequestsAreAllowed else { return false }

        let hasMicrophonePermission = await requestMicrophonePermissionIfNeeded()
        guard hasMicrophonePermission else {
            guard permissionRequestsAreAllowed else { return false }
            lastErrorMessage = "microphone permission is required for push to talk."
            return false
        }

        guard permissionRequestsAreAllowed else { return false }
        guard transcriptionProvider.requiresSpeechRecognitionPermission else {
            return true
        }

        let hasSpeechRecognitionPermission = await requestSpeechRecognitionPermissionIfNeeded()
        guard hasSpeechRecognitionPermission else {
            guard permissionRequestsAreAllowed else { return false }
            lastErrorMessage = "speech recognition permission is required for push to talk."
            return false
        }

        return true
    }

    /// macOS can show the microphone/speech sheet again if we accidentally fan out
    /// multiple permission requests before the first one finishes. We keep exactly
    /// one in-flight request task so rapid repeat presses all await the same result.
    ///
    /// After the task completes, we skip re-requesting for a short cooldown period
    /// so macOS has time to update its authorization cache. This prevents the
    /// permission dialog from popping up again on rapid follow-up presses.
    private func requestMicrophoneAndSpeechPermissionsWithoutDuplicatePrompts() async -> Bool {
        guard permissionRequestsAreAllowed else { return false }

        // If a permission request is already in-flight, reuse it.
        if let activePermissionRequestTask {
            return await activePermissionRequestTask.task.value
        }

        // If we just finished a permission request very recently, skip re-requesting.
        // macOS can briefly report .notDetermined even after the user tapped Allow,
        // so we trust the cached result for a short window.
        if let lastPermissionRequestCompletedAt,
           Date().timeIntervalSince(lastPermissionRequestCompletedAt) < 1.0 {
            // Require an actual grant. `!= .denied && != .restricted` also
            // accepted `.notDetermined` — i.e. "macOS has never been asked" was
            // treated as permission. A first press refused inside the Stealth
            // wrapper still stamps this timestamp while the status stays
            // `.notDetermined`, so a second press within one second returned
            // true, the engine started with no microphone grant, macOS
            // delivered all-zero buffers, and the overlay showed "listening"
            // with a flat waveform and an empty transcript and no error
            // anywhere. Speech recognition is checked too, since the shipped
            // provider requires it.
            let microphoneIsGranted =
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let speechIsGranted =
                SFSpeechRecognizer.authorizationStatus() == .authorized
            if microphoneIsGranted && speechIsGranted { return true }
            // Otherwise fall through to the real request path, which sets the
            // problem state the UI reads instead of failing mute.
        }

        guard permissionRequestsAreAllowed else { return false }

        let permissionRequestIdentifier = UUID()
        let permissionRequestTask = Task { @MainActor in
            guard !Task.isCancelled,
                  !StealthEntryLatch.shared.isRaised,
                  !StealthVisibilityGate.shared.isActive else { return false }
            return await self.requestMicrophoneAndSpeechPermissionsIfNeeded()
        }

        activePermissionRequestTask = (
            identifier: permissionRequestIdentifier,
            task: permissionRequestTask
        )

        let hasPermissions = await permissionRequestTask.value
        if activePermissionRequestTask?.identifier == permissionRequestIdentifier {
            activePermissionRequestTask = nil
            lastPermissionRequestCompletedAt = Date()
        }
        return hasPermissions
    }

    private func requestMicrophonePermissionIfNeeded() async -> Bool {
        guard permissionRequestsAreAllowed else { return false }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                // The callback registration is the one bounded native commit:
                // X either raises first and no TCC request is issued, or this
                // request is registered first and later X invalidates its owner.
                let didRequest = StealthEntryLatch.shared
                    .performUnlessRaised {
                        AVCaptureDevice.requestAccess(for: .audio) {
                            isGranted in
                            continuation.resume(returning: isGranted)
                        }
                        return true
                    }
                if didRequest != true {
                    continuation.resume(returning: false)
                }
            }
            guard permissionRequestsAreAllowed else { return false }
            currentPermissionProblem = isGranted ? nil : .microphoneAccessDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        @unknown default:
            currentPermissionProblem = .microphoneAccessDenied
            return false
        }
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        guard permissionRequestsAreAllowed else { return false }

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            currentPermissionProblem = nil
            return true
        case .notDetermined:
            let isGranted = await withCheckedContinuation { continuation in
                // Repeat the same linearization after the microphone await so
                // Speech cannot surface a second clean-Mac prompt after X.
                let didRequest = StealthEntryLatch.shared
                    .performUnlessRaised {
                        SFSpeechRecognizer.requestAuthorization {
                            authorizationStatus in
                            continuation.resume(
                                returning:
                                    authorizationStatus == .authorized
                            )
                        }
                        return true
                    }
                if didRequest != true {
                    continuation.resume(returning: false)
                }
            }
            guard permissionRequestsAreAllowed else { return false }
            currentPermissionProblem = isGranted ? nil : .speechRecognitionDenied
            return isGranted
        case .denied, .restricted:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        @unknown default:
            currentPermissionProblem = .speechRecognitionDenied
            return false
        }
    }

    func openRelevantPrivacySettings() {
        let settingsURLString: String

        switch currentPermissionProblem {
        case .microphoneAccessDenied:
            settingsURLString = PermissionSystemSettingsPane.microphone.deepLink.absoluteString
        case .speechRecognitionDenied:
            settingsURLString = PermissionSystemSettingsPane.speechRecognition.deepLink.absoluteString
        case nil:
            settingsURLString = PermissionSystemSettingsPane.microphone.deepLink.absoluteString
        }

        guard let settingsURL = URL(string: settingsURLString) else { return }
        _ = SetupVisibleEffectAdmission.commit {
            return NSWorkspace.shared.open(settingsURL)
        }
    }

    private func userFacingErrorMessage(from error: Error, fallback: String) -> String {
        if let localizedError = error as? LocalizedError,
           let errorDescription = localizedError.errorDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !errorDescription.isEmpty {
            return errorDescription
        }

        let errorDescription = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorDescription.isEmpty,
           errorDescription != "The operation couldn’t be completed." {
            return errorDescription
        }

        return fallback
    }
}
#endif // circuit-convert
