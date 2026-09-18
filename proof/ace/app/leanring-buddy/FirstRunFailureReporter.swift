//
//  FirstRunFailureReporter.swift
//  Ace
//
//  The channel Ace never had.
//
//  Every failure used to be a silent `return`, a line in a log file nobody
//  opens, or a sentence spoken by Ace Voice. The setup window is built on the
//  same assumption, in its own words: "Speaking needs no permission — only
//  listening does."
//
//  That assumption is false. Speaking needs macOS's built-in voice host and the
//  bundled voice runtime. If that sealed runtime is damaged, every diagnostic
//  Ace had — dictation is off, no CLI brain is signed in, the voice asset is
//  missing — could be correctly detected and then delivered through the one
//  channel guaranteed to be dead. Three recoverable setup problems presented
//  as one dead app.
//
//  This reporter is deliberately NOT the voice, and deliberately not a
//  notification either: UNUserNotification would demand its own consent prompt
//  on first run, and a declined prompt would put us straight back into silence.
//  It is persistent and inline so it never steals clicks from Ace itself.
//

#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import Foundation
import CircuitPortKit

/// A first-run problem that stops Ace from working, phrased for the owner.
struct FirstRunFailure: Equatable, Identifiable {
    /// Stable key so the same problem is reported once per launch, not per retry.
    let id: String
    let summary: String
    let remedy: String?
    /// Title of the button that fixes it, and the work it does. Nil = no
    /// one-click repair, the remedy text is the whole instruction.
    let repairButtonTitle: String?

}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class FirstRunFailureReporter: ObservableObject {

    static let shared = FirstRunFailureReporter()

    /// Everything currently wrong, for the setup window and the menu-bar panel
    /// to render inline. This persistent surface is the complete recovery
    /// channel: an interrupting modal session would consume its clicks.
    @Published private(set) var activeFailures: [FirstRunFailure] = []
    private var activeFailureStore =
        IdentifierReplacingStore<FirstRunFailure>()

    private typealias VerifiedRepairHandler =
        @MainActor () async -> PermissionRepairResult

    private var repairHandlers: [String: VerifiedRepairHandler] = [:]
    private var repairRevisions: [String: String] = [:]
    private var repairCoordinators: [String: PermissionRepairCoordinator] = [:]
    private var repairStateObservers: [String: AnyCancellable] = [:]
    private var pendingExternalConvergenceProofs:
        [String: PermissionRepairProof] = [:]
    private let sideEffectsEnabled: Bool

    init(sideEffectsEnabled: Bool = true) {
        self.sideEffectsEnabled = sideEffectsEnabled
    }

    /// Records a failure on the persistent recovery surface.
    ///
    /// `interrupt` remains source-compatible with older callers but no longer
    /// creates a modal. A pumped modal session makes the panel's buttons ghost.
    func report(
        _ failure: FirstRunFailure,
        interrupt: Bool = true
    ) {
        _ = interrupt
        record(failure, verifiedRepair: nil)
    }

    func report(
        _ failure: FirstRunFailure,
        interrupt: Bool = true,
        repairRevision: String,
        verifiedRepair: @escaping @MainActor () async
            -> PermissionRepairResult
    ) {
        _ = interrupt
        record(
            failure,
            repairRevision: repairRevision,
            verifiedRepair: verifiedRepair
        )
    }

    private func record(
        _ failure: FirstRunFailure,
        repairRevision: String? = nil,
        verifiedRepair: VerifiedRepairHandler?
    ) {
        // Copy may legitimately improve while the admitted repair is probing
        // (voice diagnostics are the common case). Only a handler revision is
        // a new generation; content refresh must not cancel its own attempt.
        let revisionChanged = repairRevisions[failure.id] != repairRevision
            || repairCoordinators[failure.id]?.state.proof != nil
        if revisionChanged {
            repairCoordinators[failure.id]?.invalidate()
            repairCoordinators[failure.id] = nil
            repairStateObservers[failure.id] = nil
            repairHandlers[failure.id] = nil
            repairRevisions[failure.id] = nil
            pendingExternalConvergenceProofs[failure.id] = nil
        }
        if let verifiedRepair {
            repairHandlers[failure.id] = verifiedRepair
            repairRevisions[failure.id] = repairRevision
            _ = repairCoordinator(for: failure.id)
        }

        activeFailureStore.upsert(failure)
        activeFailures = activeFailureStore.elements
        guard sideEffectsEnabled else { return }
        LifecycleLog.append("FIRST-RUN-FAILURE \(failure.id) — \(failure.summary)")
    }

    /// Clears a problem once it is genuinely fixed, so the banner disappears and
    /// a later regression can alert again.
    func clear(identifier: String) {
        // A repair's own readback often flows through the same refresh path
        // that normally clears this card. Keep the running generation visible;
        // its exact success will retire the card after the receipt dwell.
        guard repairCoordinators[identifier]?.state.isRunning != true,
              repairCoordinators[identifier]?.state.proof == nil else {
            return
        }
        if case let .failed(_, reason) =
            repairCoordinators[identifier]?.state,
           reason.code.contains("attestation_deferred") {
            // Local readiness is weaker than the delivery/helper/child
            // attestation promised by this card. Only a later verified repair
            // generation may retire it.
            return
        }
        retire(identifier: identifier)
    }

    private func retire(identifier: String) {
        activeFailureStore.remove(identifier: identifier)
        activeFailures = activeFailureStore.elements
        repairHandlers[identifier] = nil
        repairRevisions[identifier] = nil
        pendingExternalConvergenceProofs[identifier] = nil
        // A verified handler may itself clear the card at the instant its real
        // postcondition arrives. Keep that admitted generation alive long
        // enough to publish its terminal receipt; a later same-ID report always
        // invalidates and replaces it before becoming visible.
    }

    func clearVoiceFailures(except retainedIdentifier: String) {
        for identifier in [
            "voice.hostUnavailable",
            "voice.assetMissing",
            "voice.checkFailed"
        ] where identifier != retainedIdentifier {
            clear(identifier: identifier)
        }
    }

    @discardableResult
    func converge(
        identifier: String,
        proof: PermissionRepairProof
    ) -> Bool {
        guard externalConvergenceIsAllowed(
            identifier: identifier,
            proof: proof
        ) else { return false }
        let proofIsDeliveryAttestation =
            proof == .verifiedOperation("device_delivery_attested")
        if let coordinator = repairCoordinators[identifier] {
            if coordinator.state.isRunning {
                // Queue behind the admitted flight. The strong delivery
                // attestation keeps identical authority whenever it arrives —
                // the terminal observer applies it even through a later
                // attestation_deferred result, while a queued weaker lease is
                // discarded by exactly that terminal.
                pendingExternalConvergenceProofs[identifier] = proof
                return true
            }
            if case let .failed(_, reason) = coordinator.state,
               reason.code.contains("attestation_deferred"),
               !proofIsDeliveryAttestation {
                // Local readiness is weaker than the delivery attestation this
                // terminal is waiting on. Leave the deferred terminal intact.
                return false
            }
            if let existingProof = coordinator.state.proof {
                if existingProof == proof {
                    // Identical proof during the success dwell is idempotent:
                    // no new attempt generation, and the original dwell keeps
                    // its clock.
                    return true
                }
                if !proofIsDeliveryAttestation {
                    // A published success never downgrades to a weaker proof.
                    return true
                }
            }
            if coordinator.state != .idle,
               activeFailures.contains(where: { $0.id == identifier }) {
                coordinator.invalidate()
                _ = coordinator.start { .succeeded(proof) }
                return true
            }
        }
        if activeFailures.contains(where: { $0.id == identifier }) {
            // Idle convergence publishes an observable success generation and
            // honors the terminal receipt dwell; it never clears the card
            // directly, so the owner always sees the proof that retired it.
            let coordinator = repairCoordinator(for: identifier)
            _ = coordinator.start { .succeeded(proof) }
            return true
        }
        return true
    }

    private func externalConvergenceIsAllowed(
        identifier: String,
        proof: PermissionRepairProof
    ) -> Bool {
        guard identifier == "license.notActive",
              case let .verifiedOperation(operation) = proof else {
            return false
        }
        return operation == "validated_license_lease"
            || operation == "device_delivery_attested"
    }

    /// Returns the action only while both halves of the repair still exist.
    /// A suppressed first-run alert can therefore render the exact same live
    /// action inside setup or the menu panel instead of leaving a ghost label.
    func repairButtonTitle(for identifier: String) -> String? {
        guard repairHandlers[identifier] != nil else { return nil }
        return activeFailures.first { $0.id == identifier }?
            .repairButtonTitle
    }

    /// Runs the same repair handler from either the modal alert or an inline
    /// recovery card. Returning false lets callers keep the failure visible
    /// when Stealth won the race or the action was already retired.
    @discardableResult
    func performRepair(identifier: String) -> Bool {
        guard !StealthVisibilityGate.shared.isActive,
              !StealthEntryLatch.shared.isRaised,
              activeFailures.contains(where: { $0.id == identifier }),
              let repairHandler = repairHandlers[identifier] else {
            // Build 64 returned here in total silence — no log, no state, no
            // receipt — so a swallowed click was indistinguishable from a
            // click that worked. Every refusal is now recorded.
            LifecycleLog.append(
                "FIRST-RUN-FAILURE \(identifier) repair not admitted"
            )
            return false
        }
        let coordinator = repairCoordinator(for: identifier)
        // Log the ACTUAL admission, not the intent to admit. `start` refuses a
        // generation that is already running, so announcing acceptance first
        // printed "repair accepted" immediately followed by "repair not
        // admitted" for one click.
        let repairWasAdmitted = coordinator.start(operation: repairHandler)
        LifecycleLog.append(
            "FIRST-RUN-FAILURE \(identifier) repair "
            + (repairWasAdmitted ? "accepted" : "not admitted (already running)")
        )
        return repairWasAdmitted
    }

    /// Publishes an observable terminal when a repair click was refused. The
    /// inline recovery card is the ONLY surface during first run (alerts are
    /// suppressed while setup is on screen), so a refusal that only reaches the
    /// log leaves the owner clicking a button that never answers.
    func publishRepairNotAdmitted(identifier: String) {
        let coordinator = repairCoordinator(for: identifier)
        guard !coordinator.state.isRunning else { return }
        coordinator.start {
            .failed(
                PermissionRepairFailure(
                    code: "repair.not_admitted",
                    message: StealthVisibilityGate.shared.isActive
                        || StealthEntryLatch.shared.isRaised
                        ? "Private Mode is active, so Ace did not run this "
                            + "repair. Leave Private Mode and try again."
                        : "This repair is no longer available. Reopen Ace "
                            + "setup to try again."
                )
            )
        }
    }

    func repairState(for identifier: String) -> PermissionRepairState {
        repairCoordinators[identifier]?.state ?? .idle
    }

    private func repairCoordinator(
        for identifier: String
    ) -> PermissionRepairCoordinator {
        if let existingCoordinator = repairCoordinators[identifier] {
            return existingCoordinator
        }
        let coordinator = PermissionRepairCoordinator()
        repairCoordinators[identifier] = coordinator
        repairStateObservers[identifier] = coordinator.$state
            .dropFirst()
            .sink { [weak self, weak coordinator] state in
                guard let self, let coordinator else { return }
                LifecycleLog.append(
                    "FIRST-RUN-FAILURE \(identifier) repair \(state.accessibilityValue)"
                )
                self.objectWillChange.send()
                if case let .failed(_, terminalFailure) = state {
                    let terminalIsAttestationDeferred =
                        terminalFailure.code.contains("attestation_deferred")
                    if let pendingProof =
                        self.pendingExternalConvergenceProofs[identifier],
                       self.repairCoordinators[identifier] === coordinator,
                       !terminalIsAttestationDeferred
                           || pendingProof
                               == .verifiedOperation("device_delivery_attested") {
                        // The strong delivery attestation has identical
                        // authority before, during, and after the handler: a
                        // later attestation_deferred terminal cannot discard
                        // it. Weaker queued proof applies only when the
                        // terminal is not delivery-deferred.
                        self.pendingExternalConvergenceProofs
                            .removeValue(forKey: identifier)
                        Task { @MainActor [weak self, weak coordinator] in
                            await Task.yield()
                            guard let self, let coordinator,
                                  self.repairCoordinators[identifier]
                                    === coordinator,
                                  coordinator.state == state else { return }
                            coordinator.invalidate()
                            _ = coordinator.start { .succeeded(pendingProof) }
                        }
                        return
                    }
                    if terminalIsAttestationDeferred {
                        // A queued weaker lease is exactly the local
                        // convergence this deferred terminal outranks.
                        self.pendingExternalConvergenceProofs[identifier] = nil
                    }
                }
                guard case .succeeded = state,
                      self.repairCoordinators[identifier] === coordinator else {
                    return
                }
                // Hold the proof on-screen long enough for SwiftUI/AX to
                // observe it. Identity + terminal-state checks ensure this
                // delayed retirement can never erase a newer same-ID failure.
                Task { @MainActor [weak self, weak coordinator] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, let coordinator,
                          self.repairCoordinators[identifier] === coordinator,
                          coordinator.state == state else { return }
                    self.retire(identifier: identifier)
                }
            }
        return coordinator
    }

}
#endif // circuit-convert

// MARK: - The specific first-run failures

extension FirstRunFailure {

    static func voice(_ state: VoiceReadinessState) -> FirstRunFailure? {
        switch state {
        case .ready, .unknown:
            return nil
        case .voiceHostUnavailable:
            return FirstRunFailure(
                id: "voice.hostUnavailable",
                summary: state.ownerFacingSummary,
                remedy: state.ownerFacingRemedy,
                repairButtonTitle: "Check again"
            )
        case .voiceAssetMissing:
            return FirstRunFailure(
                id: "voice.assetMissing",
                summary: state.ownerFacingSummary,
                remedy: state.ownerFacingRemedy,
                repairButtonTitle: "Check again"
            )
        case .voiceCheckFailed:
            return FirstRunFailure(
                id: "voice.checkFailed",
                summary: state.ownerFacingSummary,
                remedy: state.ownerFacingRemedy,
                repairButtonTitle: "Check again"
            )
        }
    }

    /// Apple Speech refuses on a Mac where Dictation has never been switched on
    /// — the default state of every new Mac — and separately while the
    /// on-device model has not finished downloading. The refusals were already
    /// correct and well-worded in AppleSpeechTranscriptionProvider; they were
    /// only ever SPOKEN. The provider's own diagnostic rides along here because
    /// the two problems share a remedy but should not share a description.
    static func listeningUnavailable(providerMessage: String?) -> FirstRunFailure {
        FirstRunFailure(
            id: "listening.appleSpeechRefused",
            summary: "Ace can't hear you yet — "
                + (providerMessage ?? "this Mac's dictation isn't turned on."),
            remedy: "System Settings → Keyboard → Dictation, switch it on (macOS downloads "
                + "the on-device speech model with it), then try the hotkey again.",
            repairButtonTitle: "Open Settings"
        )
    }

    /// Accessibility declined, so `GlobalPushToTalkShortcutMonitor` has no event
    /// tap and Command+Shift does nothing at all.
    ///
    /// This was the last silent killer left on a clean Mac. `refreshAllPermissions`
    /// has always DETECTED the denial — it even stops the tap on the spot — but
    /// said so only to a `print`, and Ace has no dock icon and no window, so the
    /// owner holds the hotkey, gets no gem, no sound, and no error. Identical on
    /// screen to an app that never launched. A buyer who clicks "Don't Allow"
    /// once (or lets the prompt time out) owns a permanently dead app with
    /// nothing anywhere telling them why.
    static let accessibilityDenied = FirstRunFailure(
        id: "permissions.accessibilityDenied",
        summary: "Ace can't see the hotkey — macOS Accessibility isn't switched on for it.",
        remedy: "System Settings → Privacy & Security → Accessibility, switch Ace on. "
            + "Holding Command+Shift does nothing at all until it is.",
        repairButtonTitle: "Open Settings"
    )

    /// Screen Recording declined. Ace still hears and still answers — it just
    /// answers about a screen it cannot see, which reads as a confidently wrong
    /// assistant rather than a permission problem. Worth its own alert precisely
    /// because nothing visibly breaks.
    static let screenRecordingDenied = FirstRunFailure(
        id: "permissions.screenRecordingDenied",
        summary: "Ace is answering blind — macOS Screen Recording isn't switched on for it.",
        remedy: "System Settings → Privacy & Security → Screen & System Audio Recording, "
            + "switch Ace on, then quit and reopen Ace. Until then it can hear you "
            + "but cannot see what you're asking about.",
        repairButtonTitle: "Open Settings"
    )

    static let microphoneDenied = FirstRunFailure(
        id: "permissions.microphoneDenied",
        summary: "Ace can't hear you — macOS Microphone access isn't switched on for it.",
        remedy: "System Settings → Privacy & Security → Microphone, switch Ace on. "
            + "Ace keeps this failure visible until the operating system reports a real grant.",
        repairButtonTitle: "Open Settings"
    )

    /// This copy isn't licensed — no account approval on this Mac, or the server
    /// refused the stored credential (cancelled subscription or another Mac).
    ///
    /// The id is deliberately CONSTANT across every message, so `clear(identifier:)`
    /// can retire it once the key checks out without having to reproduce whichever
    /// sentence the server sent, and so a buyer retrying a bad key is not alerted
    /// once per attempt.
    static func licenseProblem(message: String) -> FirstRunFailure {
        FirstRunFailure(
            id: "license.notActive",
            summary: "Ace isn't unlocked on this Mac.",
            remedy: message,
            repairButtonTitle: "Link This Mac"
        )
    }

    /// No verified model connection. Buyers repair the hosted entitlement;
    /// internal developer machines retain the explicit local-CLI lane.
    static var noBrainConnected: FirstRunFailure {
        FirstRunFailure(
            id: "brain.notConnected",
            summary: "Ace can hear you, but its brain isn't connected yet.",
            remedy: AceBrainRoute.current == .customerOwned
                ? "Open Setup from the menu bar, then sign in to the Codex included with Ace using your ChatGPT account."
                : "Open Setup from the menu bar and run the private hosted-brain check.",
            repairButtonTitle: "Open Setup"
        )
    }
}
