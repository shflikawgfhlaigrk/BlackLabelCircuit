//
//  AceEventBus.swift
//  Ace
//
//  The runtime half of the sessioned bidirectional event system. `AceEvent.swift`
//  holds the envelope and the pure policies; this file holds the two live
//  objects that enforce them:
//
//    • `AceSelfVoiceCaptureGate` — nonisolated, lock-guarded, consulted by the
//      AVAudioEngine tap on the render thread. It is WALL 1: Ace's voice never
//      reaches Speech Recognition.
//
//    • `AceEventBus` — MainActor. It is WALL 2: the single admission point into
//      routing, the single publish point for outbound events, the owner of the
//      turn ledger, and the writer of the structured diagnostics.
//
//  TWO INVARIANTS THIS FILE EXISTS TO HOLD
//  ---------------------------------------
//  1. `publishOutbound` has no path — not one — back into `admitInbound`,
//     Speech Recognition, `AceTranscript.record(role: .you)`, intent parsing, or
//     delegation. Outbound events reach subscribers and the diagnostics file and
//     stop there. This is checked structurally by
//     `script/test_ace_event_isolation.sh`, not by convention.
//
//  2. Only `AceEventBus.beginOwnerTurn` mints a `.user`-sourced inbound event,
//     and it is called from exactly two kinds of place: the microphone capture
//     boundary and an explicit human action in Ace's own UI. Nothing Ace
//     produces can construct one, because `AceInboundAdmission` refuses every
//     Ace-produced payload type outright.
//
//  Transport is the app's own process: Combine publishers and direct MainActor
//  calls, exactly like `LaneManager` bridges the existing subsystems. No socket,
//  no daemon, no cloud, no key, no second runtime.
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

enum AceDirectHumanUIAction: String, CaseIterable, Sendable {
    case appleMailSenderChoice = "panel.apple-mail.sender-choice"
    case appleMailConnect = "panel.apple-mail.connect"
    case appleMailPendingCancel = "panel.apple-mail.pending-cancel"
    case appleMessagesRecipientChoice =
        "panel.apple-messages.recipient-choice"
    case appleMessagesOpen = "panel.apple-messages.open"
    case appleMessagesPendingCancel =
        "panel.apple-messages.pending-cancel"
    case optionalAutomationTarget = "panel.automation.target"
}

enum AceDirectHumanUIActionOutcome: String, Sendable {
    case completed
    case failed
    case cancelled

    var eventState: AceEventState {
        switch self {
        case .completed: return .completed
        case .failed: return .failed
        case .cancelled: return .cancelled
        }
    }
}

struct AceDirectHumanUIActionLineage: Equatable, Sendable {
    let action: AceDirectHumanUIAction
    let turnID: UUID
    let correlationID: UUID
}

struct AceOwnerTurnReplacement: Equatable, Sendable {
    let previousTurnID: UUID
    let newTurnID: UUID
}

// MARK: - WALL 1: the capture boundary gate

/// Consulted by the audio tap for EVERY buffer. Must be cheap and must never
/// block: it takes one uncontended lock and returns.
///
/// The gate does not own the notion of "Ace is speaking" — `NoraSpeechActivityLatch`
/// does, and it is already marked from all three of NoraVoice's speak paths. The
/// gate adds the tail timestamp and the per-session audit.
nonisolated final class AceSelfVoiceCaptureGate: @unchecked Sendable {

    static let shared = AceSelfVoiceCaptureGate()

    /// Injected so the gate is testable without an audio daemon. The shared
    /// instance reads the real latch.
    private let speechActivity: @Sendable () -> (isSpeaking: Bool, endedAt: Date)

    private let lock = NSLock()
    private var auditsBySession: [UUID: AceCaptureWindowAudit] = [:]
    private var originsBySession: [UUID: AceCaptureOrigin] = [:]

    init(
        speechActivity: @escaping @Sendable () -> (isSpeaking: Bool, endedAt: Date) = {
            (
                NoraSpeechActivityLatch.shared.isSpeaking,
                NoraSpeechActivityLatch.shared.speechEndedAt
            )
        }
    ) {
        self.speechActivity = speechActivity
    }

    /// A dictation session opened. Resets that session's audit.
    func beginCaptureSession(_ sessionIdentifier: UUID, origin: AceCaptureOrigin) {
        lock.withLock {
            auditsBySession[sessionIdentifier] = AceCaptureWindowAudit()
            originsBySession[sessionIdentifier] = origin
        }
    }

    func endCaptureSession(_ sessionIdentifier: UUID) {
        lock.withLock {
            auditsBySession.removeValue(forKey: sessionIdentifier)
            originsBySession.removeValue(forKey: sessionIdentifier)
        }
    }

    /// The per-buffer decision. Called on the AVAudio render thread.
    ///
    /// Returns `.forward` when the buffer may reach the recognizer. Every call
    /// is counted so the session's audit can prove afterwards whether any owner
    /// audio was present at all.
    func admitAudioBuffer(
        session sessionIdentifier: UUID,
        now: Date = Date()
    ) -> AceSelfVoiceSuppressionWindow.Decision {
        let activity = speechActivity()
        let decision = AceSelfVoiceSuppressionWindow.decision(
            aceIsSpeaking: activity.isSpeaking,
            speechEndedAt: activity.endedAt,
            now: now
        )
        lock.withLock {
            var audit = auditsBySession[sessionIdentifier] ?? AceCaptureWindowAudit()
            switch decision {
            case .forward:
                audit.recordForwarded()
            case let .suppress(reason):
                audit.recordSuppressed(reason)
            }
            auditsBySession[sessionIdentifier] = audit
        }
        return decision
    }

    func audit(for sessionIdentifier: UUID) -> AceCaptureWindowAudit {
        lock.withLock { auditsBySession[sessionIdentifier] ?? AceCaptureWindowAudit() }
    }

    func origin(for sessionIdentifier: UUID) -> AceCaptureOrigin? {
        lock.withLock { originsBySession[sessionIdentifier] }
    }

    /// The second half of Wall 1, asked once per finalization: may this session's
    /// final transcript become an owner event?
    ///
    /// A session that forwarded nothing contained no owner audio — every buffer
    /// was Ace's own voice or its tail — so its transcript, however
    /// microphone-derived and however command-shaped, is not the owner speaking.
    ///
    /// A session that forwarded ANY buffer did contain owner audio and its final
    /// is admitted. That is the guarantee that suppression does not eat real
    /// speech after the tail.
    func admitsFinalTranscript(session sessionIdentifier: UUID) -> Bool {
        let audit = audit(for: sessionIdentifier)
        // A session with no recorded buffers at all (a provider that finalized
        // without the tap ever running, or a synthetic test session) is not
        // evidence of self-voice; only an actively-suppressed session is.
        guard audit.didSuppressAnything else { return true }
        return audit.admitsFinalTranscript
    }
}

// MARK: - Outbound subscribers

/// A labeled consumer. Lanes subscribe through this rather than reading a global
/// transcript, so "notes sees Partner's aside" stops being possible.
@MainActor
final class AceEventSubscriber {
    let name: String
    let subscription: AceEventSubscription
    private let receive: (AceEvent) -> Void

    init(
        name: String,
        subscription: AceEventSubscription,
        receive: @escaping (AceEvent) -> Void
    ) {
        self.name = name
        self.subscription = subscription
        self.receive = receive
    }

    fileprivate func deliverIfAccepted(_ event: AceEvent) -> Bool {
        guard subscription.accepts(event) else { return false }
        receive(event)
        return true
    }
}

// MARK: - WALL 2: the bus

@MainActor
final class AceEventBus: ObservableObject {

    static let shared = AceEventBus()

    /// One app run. Every event carries it; an event minted before a relaunch
    /// cannot route into this one.
    let sessionID: UUID

    /// The most recent event in each direction, for the UI and the HUD.
    @Published private(set) var lastInboundEvent: AceEvent?
    @Published private(set) var lastOutboundEvent: AceEvent?

    /// Published outbound stream. `LaneManager`-style bridge for SwiftUI.
    let outbound = PassthroughSubject<AceEvent, Never>()

    /// Turn identity for the turn currently being captured or routed.
    private(set) var currentTurnID: UUID?

    private var ledger = AceTurnLedger()
    private var subscribers: [AceEventSubscriber] = []
    private var ownerTurnReplacementObservers: [
        UUID: (AceOwnerTurnReplacement) -> Bool
    ] = [:]
    private let diagnostics: AceEventDiagnosticsWriter

    /// DEBUG builds admit the `RUN_SAY` observability path; Release refuses it,
    /// so a shipped app has no synthetic command channel at all.
    private let isDebugBuild: Bool

    init(
        sessionID: UUID = UUID(),
        diagnostics: AceEventDiagnosticsWriter = .shared,
        isDebugBuild: Bool = AceEventBus.compiledAsDebug
    ) {
        self.sessionID = sessionID
        self.diagnostics = diagnostics
        self.isDebugBuild = isDebugBuild
    }

    nonisolated static var compiledAsDebug: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: Subscribers

    func subscribe(_ subscriber: AceEventSubscriber) {
        subscribers.append(subscriber)
    }

    func removeSubscriber(named name: String) {
        subscribers.removeAll { $0.name == name }
    }

    /// The observer runs synchronously inside `beginOwnerTurn`, after the new
    /// ID becomes current and before the method returns. Returning false prunes
    /// a weak/deallocated observer without retaining capture owners forever.
    @discardableResult
    func observeOwnerTurnReplacements(
        _ observer: @escaping (AceOwnerTurnReplacement) -> Bool
    ) -> UUID {
        let identifier = UUID()
        ownerTurnReplacementObservers[identifier] = observer
        return identifier
    }

    func removeOwnerTurnReplacementObserver(_ identifier: UUID) {
        ownerTurnReplacementObservers.removeValue(forKey: identifier)
    }

    // MARK: Inbound

    /// Open a turn. The capture boundary calls this when the owner claims the
    /// floor (push-to-talk press, microphone button, Partner turn opening) and
    /// the UI calls it for an explicit human action.
    ///
    /// A new turn CANCELS the previous one in the ledger: a late final from the
    /// turn the owner just replaced is stale and must not create a second
    /// action.
    @discardableResult
    func beginOwnerTurn(cancellingPrevious: Bool = true) -> UUID {
        let previousTurnID = currentTurnID
        if cancellingPrevious, let previous = previousTurnID {
            ledger.cancel(turnID: previous)
        }
        let turnID = UUID()
        currentTurnID = turnID
        if cancellingPrevious,
           let previousTurnID, previousTurnID != turnID {
            let replacement = AceOwnerTurnReplacement(
                previousTurnID: previousTurnID,
                newTurnID: turnID
            )
            var staleObserverIdentifiers: [UUID] = []
            for (identifier, observer) in ownerTurnReplacementObservers {
                if !observer(replacement) {
                    staleObserverIdentifiers.append(identifier)
                }
            }
            for identifier in staleObserverIdentifiers {
                ownerTurnReplacementObservers.removeValue(forKey: identifier)
            }
        }
        return turnID
    }

    /// A click or explicit command submission is a new physical owner action,
    /// even when its text matches the action that just completed. It must never
    /// inherit a sealed turn from setup, reconnect, or another panel control.
    @discardableResult
    func beginDirectHumanTurn() -> UUID {
        beginOwnerTurn(cancellingPrevious: true)
    }

    /// Admits one physical panel/setup click without routing private selection
    /// values through a transcript-shaped payload. Every call creates a new
    /// turn and correlation, even for consecutive clicks of the same control.
    func beginDirectHumanUIAction(
        _ action: AceDirectHumanUIAction
    ) -> AceDirectHumanUIActionLineage? {
        let turnID = beginDirectHumanTurn()
        let event = ownerEvent(
            turnID: turnID,
            state: .final,
            payloadType: .directHumanUIAction,
            payload: action.rawValue
        )
        guard case let .route(admitted) = admitInbound(event) else {
            return nil
        }
        return AceDirectHumanUIActionLineage(
            action: action,
            turnID: admitted.turnID,
            correlationID: admitted.correlationID
        )
    }

    /// Publishes the immediate control result on the exact click lineage. The
    /// payload contains only a closed control/result identifier; recipient,
    /// sender, body, and target values remain outside durable event payloads.
    @discardableResult
    func completeDirectHumanUIAction(
        _ lineage: AceDirectHumanUIActionLineage,
        outcome: AceDirectHumanUIActionOutcome
    ) -> Bool {
        publishTerminalWork(
            source: .system,
            state: outcome.eventState,
            payloadType: .executionReceipt,
            payload: lineage.action.rawValue + "." + outcome.rawValue,
            turnID: lineage.turnID,
            correlationID: lineage.correlationID
        )
    }

    /// Build a `.user` inbound event. This is the ONLY constructor of owner
    /// authority in the app.
    func ownerEvent(
        turnID: UUID,
        state: AceEventState,
        payloadType: AceEventPayloadType,
        payload: String,
        at now: Date = Date()
    ) -> AceEvent {
        AceEvent(
            sessionID: sessionID,
            turnID: turnID,
            correlationID: UUID(),
            timestamp: now,
            source: .user,
            direction: .inbound,
            state: state,
            payloadType: payloadType,
            payload: payload
        )
    }

    enum InboundOutcome: Equatable {
        /// Route it through intent parsing, Gold, confirmations, dispatch.
        case route(AceEvent)
        /// Update the UI only.
        case uiOnly(AceEvent)
        /// Dropped, with the reason recorded.
        case dropped(String)

        var routedEvent: AceEvent? {
            if case let .route(event) = self { return event }
            return nil
        }

        var routes: Bool { routedEvent != nil }
    }

    /// The single admission point. Everything that wants to become an owner
    /// command passes through here or does not happen.
    func admitInbound(_ event: AceEvent, at now: Date = Date()) -> InboundOutcome {
        let decision = AceInboundAdmission.decide(
            event,
            sessionID: sessionID,
            isDebugBuild: isDebugBuild
        )

        switch decision {
        case .refuse(let refusal):
            diagnostics.append(
                AceEventDiagnostics.line(
                    for: event,
                    decision: "refused",
                    detail: refusal.rawValue
                )
            )
            return .dropped(refusal.rawValue)

        case .admitForUIOnly:
            lastInboundEvent = event
            // Deliberately NOT written to agent.log: a partial fires many times
            // per second and its only effect is a caption. Logging each one
            // would bury the routing decisions this channel exists to prove.
            return .uiOnly(event)

        case .admitForRouting:
            let admission = ledger.admitFinal(
                turnID: event.turnID,
                payload: event.payload,
                at: now,
                deduplicateAcrossTurns:
                    event.payloadType == .microphoneFinalTranscript
            )
            guard admission.routes else {
                diagnostics.append(
                    AceEventDiagnostics.line(
                        for: event,
                        decision: "not-routed",
                        detail: String(describing: admission)
                    )
                )
                return .dropped(String(describing: admission))
            }
            lastInboundEvent = event
            diagnostics.append(
                AceEventDiagnostics.line(for: event, decision: "routed")
            )
            return .route(event)
        }
    }

    /// Barge-in, Private Mode entry, or a replacement utterance. Ends the named
    /// turn so a final that arrives afterwards cannot route.
    ///
    /// It ends ONLY that turn. The next valid human turn is untouched — that is
    /// the difference between cancelling a turn and muting the product.
    func cancelTurn(_ turnID: UUID, reason: String) {
        ledger.cancel(turnID: turnID)
        if currentTurnID == turnID { currentTurnID = nil }
        diagnostics.append(
            [
                "TURN-CANCEL",
                "session=\(AceEventIdentifier.short(sessionID))",
                "turn=\(AceEventIdentifier.short(turnID))",
                "reason=\(AceEventDiagnostics.sanitize(reason))",
            ].joined(separator: " ")
        )
    }

    func isTurnCancelled(_ turnID: UUID) -> Bool { ledger.isCancelled(turnID: turnID) }

    // MARK: Outbound

    /// Publish anything Ace produces. Speech, lane receipts, Partner advice,
    /// notes updates, timers, cards, execution receipts.
    ///
    /// There is no branch in this method that leads back into `admitInbound`,
    /// Speech Recognition, or the owner's transcript. That is the whole point.
    @discardableResult
    func publishOutbound(_ event: AceEvent) -> Bool {
        switch AceOutboundAdmission.decide(event) {
        case .refuse(let refusal):
            diagnostics.append(
                AceEventDiagnostics.line(
                    for: event,
                    decision: "refused-outbound",
                    detail: refusal.rawValue
                )
            )
            return false
        case .publish:
            lastOutboundEvent = event
            outbound.send(event)
            for subscriber in subscribers {
                _ = subscriber.deliverIfAccepted(event)
            }
            diagnostics.append(
                AceEventDiagnostics.line(for: event, decision: "published")
            )
            return true
        }
    }

    /// Convenience for a lane emitting into the turn that caused it. Falls back
    /// to a standalone turn when a lane surfaces on its own (a timer firing with
    /// no owner turn in flight).
    @discardableResult
    func publishOutbound(
        source: AceEventSource,
        state: AceEventState,
        payloadType: AceEventPayloadType,
        payload: String,
        turnID: UUID? = nil,
        correlationID: UUID = UUID(),
        at now: Date = Date()
    ) -> Bool {
        publishOutbound(
            AceEvent(
                sessionID: sessionID,
                turnID: turnID ?? currentTurnID ?? UUID(),
                correlationID: correlationID,
                timestamp: now,
                source: source,
                direction: .outbound,
                state: state,
                payloadType: payloadType,
                payload: payload
            )
        )
    }

    /// Terminal work state, exactly once per unit of work. A retry or a
    /// duplicated completion that lands after the first is dropped rather than
    /// delivered twice — this is the background-completion ordering rule.
    @discardableResult
    func publishTerminalWork(
        source: AceEventSource,
        state: AceEventState,
        payloadType: AceEventPayloadType,
        payload: String,
        turnID: UUID?,
        correlationID: UUID,
        at now: Date = Date()
    ) -> Bool {
        guard state.isTerminal else {
            return publishOutbound(
                source: source,
                state: state,
                payloadType: payloadType,
                payload: payload,
                turnID: turnID,
                correlationID: correlationID,
                at: now
            )
        }
        guard ledger.admitTerminalWork(correlationID: correlationID) else {
            diagnostics.append(
                [
                    "WORK-DUPLICATE",
                    "src=\(source.rawValue)",
                    "corr=\(AceEventIdentifier.short(correlationID))",
                    "state=\(state.rawValue)",
                ].joined(separator: " ")
            )
            return false
        }
        return publishOutbound(
            source: source,
            state: state,
            payloadType: payloadType,
            payload: payload,
            turnID: turnID,
            correlationID: correlationID,
            at: now
        )
    }

    // MARK: Capture-boundary receipts

    /// Suppression must be observable. This is where it becomes observable.
    func recordCaptureGate(
        origin: AceCaptureOrigin,
        audit: AceCaptureWindowAudit,
        outcome: String,
        turnID: UUID
    ) {
        guard audit.didSuppressAnything else { return }
        diagnostics.append(
            AceEventDiagnostics.suppressionLine(
                origin: origin,
                audit: audit,
                outcome: outcome,
                turnID: turnID
            )
        )
    }
}

/// Production microphone ingress. A callback must present the immutable turn
/// captured when the microphone was admitted; current global state is only a
/// validator and is never substituted as ownership.
@MainActor
final class CapturedOwnerSpeechIngress {
    private let eventBus: AceEventBus

    init(eventBus: AceEventBus) {
        self.eventBus = eventBus
    }

    func admitPartial(
        _ transcript: String,
        ownerTurnID: UUID
    ) -> AceEventBus.InboundOutcome {
        admit(
            transcript,
            ownerTurnID: ownerTurnID,
            state: .partial,
            payloadType: .microphonePartialTranscript
        )
    }

    func admitFinal(
        _ transcript: String,
        ownerTurnID: UUID
    ) -> AceEventBus.InboundOutcome {
        admit(
            transcript,
            ownerTurnID: ownerTurnID,
            state: .final,
            payloadType: .microphoneFinalTranscript
        )
    }

    private func admit(
        _ transcript: String,
        ownerTurnID: UUID,
        state: AceEventState,
        payloadType: AceEventPayloadType
    ) -> AceEventBus.InboundOutcome {
        guard eventBus.currentTurnID == ownerTurnID,
              !eventBus.isTurnCancelled(ownerTurnID) else {
            return .dropped("stale-capture-turn")
        }
        return eventBus.admitInbound(
            eventBus.ownerEvent(
                turnID: ownerTurnID,
                state: state,
                payloadType: payloadType,
                payload: transcript
            )
        )
    }
}

// MARK: - Diagnostics writer

/// Appends to the existing `agent.log` channel, on a serial queue so neither the
/// MainActor nor the audio thread ever waits on the filesystem.
///
/// Same 0700 support-directory boundary every other Ace receipt uses. Content is
/// never written here — see `AceEventDiagnostics`.
nonisolated final class AceEventDiagnosticsWriter: @unchecked Sendable {

    static let shared = AceEventDiagnosticsWriter()

    private let queue = DispatchQueue(label: "com.blacklabel.ace.event-diagnostics")
    private let directoryOverride: URL?

    /// Test seam: the offline battery redirects receipts instead of writing into
    /// the owner's real log.
    init(directory: URL? = nil) {
        self.directoryOverride = directory
    }

    func append(_ line: String) {
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        let directory = directoryOverride ?? AceEventDiagnosticsWriter.defaultDirectory()
        queue.async {
            guard let directory else { return }
            guard (try? PrivateSupportDirectory.ensure(at: directory)) != nil else { return }
            let fileURL = directory.appendingPathComponent("agent.log")
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(stamped.utf8))
            } else {
                try? Data(stamped.utf8).write(to: fileURL, options: .atomic)
            }
        }
    }

    static func defaultDirectory() -> URL? {
        if let override = ProcessInfo.processInfo.environment["ACE_TRANSCRIPT_DIRECTORY"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BlackLabel", isDirectory: true)
    }
}

// MARK: - Lane mapping

extension AceEventSource {
    /// The voice queue's lane vocabulary predates the envelope. One mapping, in
    /// one place, so a lane rename cannot silently relabel an event source.
    ///
    /// Gold's SPEECH is Ace's voice (`.ace`); Gold's ROUTING DECISIONS are
    /// `.gold`. Keeping those apart is what lets a receipt say "gold delegated"
    /// without implying Gold spoke.
    static func forVoiceLane(_ lane: VoiceQueue.Lane) -> AceEventSource {
        switch lane {
        case .gold:   return .ace
        case .red:    return .red
        case .green:  return .silver
        case .blue:   return .notes
        case .purple: return .system
        }
    }
}
