#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while the assistant is running in
//  the background. Uses a consuming CGEvent tap so the one deliberate Private
//  Mode chord can be swallowed; every other event is passed through.
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
@preconcurrency import CoreFoundation
#if canImport(CoreGraphics)
@preconcurrency import CoreGraphics
#endif
import Foundation
import CircuitPortKit

/// The tap thread publishes its run loop through this small nonisolated box.
/// MainActor lifecycle code can then stop/remove the source without mutating an
/// actor-isolated property from `Thread`'s Sendable closure.
nonisolated private final class EventTapRunLoopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var runLoop: CFRunLoop?

    func store(_ runLoop: CFRunLoop) {
        lock.withLock {
            self.runLoop = runLoop
        }
    }

    func take() -> CFRunLoop? {
        lock.withLock {
            defer { runLoop = nil }
            return runLoop
        }
    }
}

// BEGIN MODIFIER_CHORD_ADMISSION
nonisolated struct AceModifierChordAdmission {
    enum Input { case press, release, cancel, reset }
    enum Output: Equatable { case none, schedule(UInt64), released, cancelled }
    private(set) var generation: UInt64 = 0
    private(set) var isHeld = false
    private(set) var isAdmitted = false
    private var isSuppressed = false

    mutating func handle(_ input: Input) -> Output {
        switch input {
        case .press:
            guard !isHeld else { return .none }
            isHeld = true
            generation &+= 1
            return .schedule(generation)
        case .cancel:
            generation &+= 1
            isHeld = true
            isSuppressed = true
            let wasAdmitted = isAdmitted
            isAdmitted = false
            return wasAdmitted ? .cancelled : .none
        case .release, .reset:
            generation &+= 1
            let wasAdmitted = isAdmitted
            isHeld = false
            isAdmitted = false
            isSuppressed = false
            if !wasAdmitted { return .none }
            if case .reset = input { return .cancelled }
            return .released
        }
    }

    mutating func admit(_ token: UInt64) -> Bool {
        guard token == generation, isHeld, !isSuppressed, !isAdmitted else { return false }
        isAdmitted = true
        return true
    }
}
// END MODIFIER_CHORD_ADMISSION

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    /// With Caps Lock toggled on, Shift+Z enters Private Mode when needed and
    /// performs its private read without requiring Caps Lock to remain held.
    let stealthAnswerTriggerPublisher = PassthroughSubject<Void, Never>()

    /// Mirrors `StealthMode.isActive` so the tap knows whether the read chord is
    /// live. Written from the main actor on every stealth entry/exit, read from
    /// the tap thread on every keystroke — hence the lock.
    var privateModeIsActive: Bool {
        get { privateModeStateLock.withLock { privateModeIsActiveStorage } }
        set { privateModeStateLock.withLock { privateModeIsActiveStorage = newValue } }
    }
    private var privateModeIsActiveStorage = false
    /// Raised synchronously on the event-tap thread the instant the keyboard
    /// Private Mode entry chord lands. Main-queue delivery can be delayed behind
    /// a final STT callback, so direct effects must consult this latch rather than
    /// waiting for `StealthMode.isActive`.
    var privateModeEntryIsRequested: Bool {
        privateModeStateLock.withLock {
            privateModeEntryIsRequestedStorage
        }
    }
    private var privateModeEntryIsRequestedStorage = false
    var privateModeEntryIsPending: Bool {
        privateModeStateLock.withLock {
            privateModeEntryIsPendingStorage
        }
    }
    private var privateModeEntryIsPendingStorage = false
    private let privateModeStateLock = NSLock()

    struct PrivateModeEntryRegistration: Equatable {
        let shouldPublish: Bool
        let entryIsPending: Bool
        let entryIsRequested: Bool
    }

    /// Pure one-way entry policy shared by the event-tap path and deterministic
    /// tests. Once active, Z remains an answer command and can never become an
    /// exit toggle. At most one entry may cross the main-queue boundary at once.
    static func privateModeEntryRegistration(
        isActive: Bool,
        entryIsPending: Bool,
        entryIsRequested: Bool
    ) -> PrivateModeEntryRegistration {
        guard !isActive, !entryIsPending else {
            return PrivateModeEntryRegistration(
                shouldPublish: false,
                entryIsPending: entryIsPending,
                entryIsRequested: entryIsRequested
            )
        }
        return PrivateModeEntryRegistration(
            shouldPublish: true,
            entryIsPending: true,
            entryIsRequested: true
        )
    }

    /// Atomically registers a Z-delivered entry before any main-queue hop. The
    /// fail-closed latch is raised synchronously and repeated events cannot queue
    /// more than one entry transition.
    func registerPrivateModeEntryFromEventTap() -> Bool {
        let registration = privateModeStateLock.withLock {
            let registration = Self.privateModeEntryRegistration(
                isActive: privateModeIsActiveStorage,
                entryIsPending: privateModeEntryIsPendingStorage,
                entryIsRequested: privateModeEntryIsRequestedStorage
            )
            privateModeEntryIsPendingStorage = registration.entryIsPending
            privateModeEntryIsRequestedStorage = registration.entryIsRequested
            return registration
        }
        if registration.shouldPublish {
            let externallyVisible =
                StealthEntryLatch.shared.raiseSynchronously()
            if !externallyVisible {
                DispatchQueue.main.async {
                    LifecycleLog.append(
                        "PRIVATE MODE entry latch publication FAILED — "
                        + "in-process effects remain blocked"
                    )
                }
            }
        }
        return registration.shouldPublish
    }

    /// CompanionManager calls this after entry fully activates or is refused.
    func resolvePrivateModeEntryRequest() {
        privateModeStateLock.withLock {
            privateModeEntryIsPendingStorage = false
            privateModeEntryIsRequestedStorage = false
        }
    }

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?

    /// The tap runs on its OWN thread, never the main run loop. A `.defaultTap`
    /// sits in the synchronous delivery path for every keystroke in the session:
    /// on the main thread, any moment Ace blocks — a subprocess wait, a consent
    /// dialog, a stalled brain call — becomes a system-wide input freeze until
    /// macOS force-disables the tap. Off the main thread, Ace can be as busy as
    /// it likes and the keyboard stays instant.
    // MainActor owns every live mutation. `deinit` is nonisolated in Swift 6,
    // but runs only after that owner has released the monitor; exposing these
    // two teardown handles there avoids stranding a tap thread or timer.
    nonisolated(unsafe) private var tapThread: Thread?
    private let tapRunLoopBox = EventTapRunLoopBox()

    /// The press state the tap thread computes transitions against. Separate
    /// from the `@Published` mirror below, which is updated asynchronously on
    /// main for the UI and must never be read to decide a transition.
    private var isShortcutPressedOnTapThread = false
    // Admit the exact modifier chord immediately. A later non-modifier key
    // cancels this generation and discards its audio without submitting it.
    private var shortcutAdmission = AceModifierChordAdmission()
    private let shortcutEpochLock = NSLock()
    private var shortcutEpoch: UInt64 = 0
    private var privateModeChordState = PrivateModeChordState()

    /// True once the CGEvent tap is actually installed. tapCreate returns nil
    /// when Accessibility/Input Monitoring is revoked — the hotkey then dies
    /// SILENTLY unless someone checks this and says so.
    @Published private(set) var didInstallEventTap = false

    /// Live authority used before Stealth hides its own escape UI. The historical
    /// `didInstallEventTap` bit only says creation once succeeded; the mach port
    /// may since have been invalidated or disabled.
    var isEventTapOperational: Bool {
        guard didInstallEventTap, let globalEventTap else { return false }
        return CFMachPortIsValid(globalEventTap)
            && CGEvent.tapIsEnabled(tap: globalEventTap)
    }

    /// Best-effort local recovery used while Stealth remains fail-closed. A
    /// dead tap is never permission to reveal Ace; re-enable in place when
    /// possible, otherwise replace the port and report whether the silent
    /// owner chord is operational again.
    @discardableResult
    func repairEventTapIfNeeded() -> Bool {
        if let globalEventTap, CFMachPortIsValid(globalEventTap) {
            if !CGEvent.tapIsEnabled(tap: globalEventTap) {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            if CGEvent.tapIsEnabled(tap: globalEventTap) {
                didInstallEventTap = true
                return true
            }
        }
        stop()
        start()
        return isEventTapOperational
    }

    /// Watchdog: macOS disables an event tap whose process stalls
    /// (tapDisabledByTimeout). The in-callback re-enable only runs if the dead
    /// tap still delivers that disable event — on 2026-07-18 00:19Z it did not
    /// (codex kill + notetaker teardown in the same second), the tap stayed
    /// dead, and even synthetic ctrl+shift produced nothing until relaunch.
    /// This timer independently re-enables a disabled tap and fully reinstalls
    /// a dead mach port, with receipts, so the hotkey can never die silently.
    nonisolated(unsafe) private var tapHealthWatchdogTimer: Timer?
    /// Main-thread mirror of the tap thread's press state. Published so the
    /// overlay can hide immediately on key release without waiting for the async
    /// dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        tapHealthWatchdogTimer?.invalidate()
        tapThread?.cancel()
        if let tapRunLoop = tapRunLoopBox.take() {
            if let globalEventTapRunLoopSource {
                CFRunLoopRemoveSource(
                    tapRunLoop,
                    globalEventTapRunLoopSource,
                    .commonModes
                )
            }
            CFRunLoopStop(tapRunLoop)
        }
        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
        }
    }

    func start() {
        // If the event tap is already running, don't restart it.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions → start() every few seconds.
        guard globalEventTap == nil else { return }
        didInstallEventTap = false
        guard StealthEntryLatch.shared.prepareExternalReceipt() else {
            print(
                "⚠️ Global push-to-talk: couldn't prepare the Private Mode "
                + "entry boundary"
            )
            return
        }

        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        // NOT listen-only. A listen-only tap physically cannot swallow an event,
        // so the Private Mode chord always reached the foreground app too —
        // Caps Lock-on Shift+Z is a command in no app, so AppKit beeped, and with
        // Accessibility's "flash the screen when an alert sound occurs" enabled
        // that beep is a FULL-SCREEN WHITE FLASH. A mode whose entire purpose is
        // to be unnoticeable was announcing itself on every keypress. Only the
        // the one chord below is ever consumed; every other event is returned
        // untouched, exactly as before.
        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("⚠️ Global push-to-talk: couldn't create CGEvent tap")
            return
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("⚠️ Global push-to-talk: couldn't create event tap run loop source")
            return
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        // Hand the source to a dedicated thread and wait just long enough to
        // learn its run loop, so stop() has something to tear down.
        let tapRunLoopIsReady = DispatchSemaphore(value: 0)
        let tapRunLoopBox = tapRunLoopBox
        let tapThread: Thread = Thread {
            guard let thisThreadsRunLoop = CFRunLoopGetCurrent() else {
                tapRunLoopIsReady.signal()
                return
            }
            tapRunLoopBox.store(thisThreadsRunLoop)
            CFRunLoopAddSource(thisThreadsRunLoop, globalEventTapRunLoopSource, .commonModes)
            tapRunLoopIsReady.signal()
            // A run loop with only a mach-port source exits immediately, so run
            // it explicitly rather than trusting CFRunLoopRun's default.
            while !Thread.current.isCancelled {
                CFRunLoopRunInMode(.defaultMode, 10, false)
            }
        }
        tapThread.name = "com.blacklabel.assistant.hotkey-tap"
        // Above default so a busy Mac can never make the keyboard feel laggy —
        // every keystroke in the session waits on this thread.
        tapThread.qualityOfService = QualityOfService.userInteractive
        tapThread.start()
        self.tapThread = tapThread
        _ = tapRunLoopIsReady.wait(timeout: .now() + 2)

        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        didInstallEventTap = true
        startTapHealthWatchdog()
    }

    /// Every 20s: a disabled tap is re-enabled in place; an invalidated mach
    /// port means the tap is unrecoverable — tear down and reinstall. Both
    /// paths leave a lifecycle receipt so "the hotkey doesn't work" always has
    /// an explanation in the log.
    private func startTapHealthWatchdog() {
        guard tapHealthWatchdogTimer == nil else { return }
        tapHealthWatchdogTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self,
                      let globalEventTap = self.globalEventTap else {
                    return
                }
                if !CFMachPortIsValid(globalEventTap) {
                    LifecycleLog.append(
                        "HOTKEY watchdog: tap mach port DEAD — reinstalling"
                    )
                    self.stop()
                    self.start()
                    return
                }
                if !CGEvent.tapIsEnabled(tap: globalEventTap) {
                    defer { self.objectWillChange.send() }
                    CGEvent.tapEnable(tap: globalEventTap, enable: true)
                    if CGEvent.tapIsEnabled(tap: globalEventTap) {
                        LifecycleLog.append(
                            "HOTKEY watchdog: re-enabled a disabled tap"
                        )
                    } else {
                        LifecycleLog.append(
                            "HOTKEY watchdog: re-enable FAILED — "
                                + "reinstalling tap"
                        )
                        self.stop()
                        self.start()
                    }
                }
            }
        }
    }

    func stop() {
        shortcutEpochLock.withLock { shortcutEpoch &+= 1 }
        receiveShortcutInput(.reset)
        didInstallEventTap = false
        isShortcutCurrentlyPressed = false
        isShortcutPressedOnTapThread = false
        privateModeChordState.reset()

        tapHealthWatchdogTimer?.invalidate()
        tapHealthWatchdogTimer = nil

        let tapRunLoop = tapRunLoopBox.take()
        if let globalEventTapRunLoopSource, let tapRunLoop {
            CFRunLoopRemoveSource(tapRunLoop, globalEventTapRunLoopSource, .commonModes)
        }
        globalEventTapRunLoopSource = nil

        tapThread?.cancel()
        if let tapRunLoop {
            CFRunLoopStop(tapRunLoop)
        }
        tapThread = nil

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }
    }

    /// Diagnostic: the first modifier events per session are logged with their
    /// decoded flags, so "the hotkey doesn't work" shows EXACTLY what the
    /// keyboard emitted (e.g. a lingering control→command remap).
    private var diagnosticFlagsLogCount = 0

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let inputEpoch = shortcutEpochLock.withLock { shortcutEpoch }
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            privateModeChordState.reset()
            isShortcutPressedOnTapThread = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shortcutEpochLock.withLock({ self.shortcutEpoch }) == inputEpoch else { return }
                self.receiveShortcutInput(.reset)
            }
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
                let disableReason = eventType == .tapDisabledByTimeout ? "timeout" : "user-input"
                DispatchQueue.main.async { [weak self] in
                    self?.objectWillChange.send()
                    LifecycleLog.append("HOTKEY tap re-enabled after \(disableReason) disable event")
                }
            }
            return Unmanaged.passUnretained(event)
        }

        // Nothing in this callback may block: it runs inside the synchronous
        // delivery path for every keystroke in the session. Logging and Combine
        // sends are handed to main; only the consume/pass decision is made here.
        if eventType == .flagsChanged, diagnosticFlagsLogCount < 20 {
            diagnosticFlagsLogCount += 1
            let flags = event.flags
            let diagnosticLine =
                "HOTKEY flagsChanged raw=0x\(String(flags.rawValue, radix: 16))"
                + " ctrl=\(flags.contains(.maskControl)) shift=\(flags.contains(.maskShift))"
                + " cmd=\(flags.contains(.maskCommand)) opt=\(flags.contains(.maskAlternate))"
            DispatchQueue.main.async { LifecycleLog.append(diagnosticLine) }
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let physicalLeftShiftIsDown = CGEventSource.keyState(
            .combinedSessionState,
            key: 56
        )
        let physicalRightShiftIsDown = CGEventSource.keyState(
            .combinedSessionState,
            key: 60
        )
        let capsLockIsOn = event.flags.contains(.maskAlphaShift)
        let chordEventKind: PrivateModeChordInput.Kind
        switch eventType {
        case .flagsChanged:
            chordEventKind = .flagsChanged
        case .keyDown:
            chordEventKind = .keyDown
        case .keyUp:
            chordEventKind = .keyUp
        default:
            return Unmanaged.passUnretained(event)
        }
        let privateModeChordAction = privateModeChordState.handle(
            PrivateModeChordInput(
                kind: chordEventKind,
                keyCode: .init(rawValue: eventKeyCode),
                physicalLeftShiftIsDown: physicalLeftShiftIsDown,
                physicalRightShiftIsDown: physicalRightShiftIsDown,
                capsLockIsOn: capsLockIsOn,
                reportedShiftFlagIsDown:
                    event.flags.contains(.maskShift),
                commandIsDown:
                    event.flags.contains(.maskCommand),
                controlIsDown:
                    event.flags.contains(.maskControl),
                optionIsDown:
                    event.flags.contains(.maskAlternate),
                isAutorepeat:
                    event.getIntegerValueField(
                        .keyboardEventAutorepeat
                    ) != 0,
                privateModeIsActive: privateModeIsActive
            )
        )

        if eventType == .keyDown, eventKeyCode == 6 {
            let chordDiagnostic = Self.privateModeChordDiagnostic(
                flags: event.flags,
                capsLockIsOn: capsLockIsOn,
                chordStateAccepted:
                    privateModeChordAction == .privateRead,
                physicalShiftIsDown:
                    physicalLeftShiftIsDown
                        || physicalRightShiftIsDown,
                isAutorepeat:
                    event.getIntegerValueField(
                        .keyboardEventAutorepeat
                    ) != 0
            )
            if chordDiagnostic.isNearMatch {
                let receipt = chordDiagnostic.contentFreeReceipt(
                    privateModeIsActive: privateModeIsActive
                )
                DispatchQueue.main.async {
                    LifecycleLog.append(receipt)
                }
            }
        }

        switch privateModeChordAction {
        case .pass:
            break
        case .consume:
            return nil
        case .privateRead:
            if !privateModeIsActive {
                guard registerPrivateModeEntryFromEventTap() else {
                    return nil
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.stealthAnswerTriggerPublisher.send(())
            }
            return nil
        }

        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutPressedOnTapThread
        )

        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutPressedOnTapThread = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.didInstallEventTap,
                      self.shortcutEpochLock.withLock({ self.shortcutEpoch }) == inputEpoch else { return }
                self.receiveShortcutInput(.press)
            }
        case .released:
            isShortcutPressedOnTapThread = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shortcutEpochLock.withLock({ self.shortcutEpoch }) == inputEpoch else { return }
                self.receiveShortcutInput(.release)
            }
        case .cancelled:
            // Keep physical tracking active until the core chord is released,
            // so repeated keys/extra-modifier releases cannot reopen voice.
            isShortcutPressedOnTapThread = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shortcutEpochLock.withLock({ self.shortcutEpoch }) == inputEpoch else { return }
                self.receiveShortcutInput(.cancel)
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func receiveShortcutInput(_ input: AceModifierChordAdmission.Input) {
        let output = shortcutAdmission.handle(input)
        switch output {
        case .none: break
        case let .schedule(token):
            guard didInstallEventTap, shortcutAdmission.admit(token) else { return }
            isShortcutCurrentlyPressed = true
            shortcutTransitionPublisher.send(.pressed)
        case .released, .cancelled:
            isShortcutCurrentlyPressed = false
            shortcutTransitionPublisher.send(output == .released ? .released : .cancelled)
        }
    }

    /// Caps Lock toggled on plus Shift, with no other modifier.
    static func isPrivateModeChord(
        _ flags: CGEventFlags,
        capsLockIsOn: Bool
    ) -> Bool {
        capsLockIsOn
            && flags.contains(.maskShift)
            && !flags.contains(.maskCommand)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
    }

    enum PrivateModeChordDiagnosticReason: String, Equatable, Sendable {
        case accepted
        case autorepeat
        case capsLockOff = "caps-lock-off"
        case shiftNotHeld = "shift-not-held"
        case commandPresent = "command-present"
        case controlPresent = "control-present"
        case optionPresent = "option-present"
    }

    struct PrivateModeChordDiagnostic: Equatable, Sendable {
        let reason: PrivateModeChordDiagnosticReason
        let rawFlags: UInt64
        let capsLockIsOn: Bool
        let shiftIsDown: Bool
        let commandIsDown: Bool
        let controlIsDown: Bool
        let optionIsDown: Bool
        let isAutorepeat: Bool

        var isAccepted: Bool { reason == .accepted }

        /// A normal unmodified Z is not diagnostic. Record only events that
        /// contain at least part of the deliberate chord, plus every accepted
        /// chord, so a rejected attempt is explainable without key-content logs.
        var isNearMatch: Bool {
            isAccepted || capsLockIsOn || shiftIsDown
        }

        func contentFreeReceipt(privateModeIsActive: Bool) -> String {
            "PRIVATE-MODE chord \(isAccepted ? "accepted" : "rejected")"
                + " key=z"
                + " rawFlags=0x\(String(rawFlags, radix: 16))"
                + " capsLogical=\(capsLockIsOn)"
                + " shift=\(shiftIsDown)"
                + " cmd=\(commandIsDown)"
                + " ctrl=\(controlIsDown)"
                + " opt=\(optionIsDown)"
                + " autorepeat=\(isAutorepeat)"
                + " active=\(privateModeIsActive)"
                + " reason=\(reason.rawValue)"
        }
    }

    static func privateModeChordDiagnostic(
        flags: CGEventFlags,
        capsLockIsOn: Bool,
        chordStateAccepted: Bool? = nil,
        physicalShiftIsDown: Bool? = nil,
        isAutorepeat: Bool
    ) -> PrivateModeChordDiagnostic {
        let shiftIsDown = physicalShiftIsDown
            ?? flags.contains(.maskShift)
        let commandIsDown = flags.contains(.maskCommand)
        let controlIsDown = flags.contains(.maskControl)
        let optionIsDown = flags.contains(.maskAlternate)
        let reason: PrivateModeChordDiagnosticReason
        if chordStateAccepted == true {
            reason = .accepted
        } else if isAutorepeat {
            reason = .autorepeat
        } else if commandIsDown {
            reason = .commandPresent
        } else if controlIsDown {
            reason = .controlPresent
        } else if optionIsDown {
            reason = .optionPresent
        } else if !shiftIsDown {
            reason = .shiftNotHeld
        } else if chordStateAccepted == false
                    || !capsLockIsOn {
            reason = .capsLockOff
        } else {
            reason = .accepted
        }
        return PrivateModeChordDiagnostic(
            reason: reason,
            rawFlags: flags.rawValue,
            capsLockIsOn: capsLockIsOn,
            shiftIsDown: shiftIsDown,
            commandIsDown: commandIsDown,
            controlIsDown: controlIsDown,
            optionIsDown: optionIsDown,
            isAutorepeat: isAutorepeat
        )
    }

}
#endif // circuit-convert
