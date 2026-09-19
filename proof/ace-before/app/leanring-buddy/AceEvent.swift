//
//  AceEvent.swift
//  Ace
//
//  ONE immutable event envelope for everything that crosses Ace's boundaries,
//  in either direction, plus the pure policies that decide what may enter.
//
//  WHY THIS FILE EXISTS
//  --------------------
//  Ace ran on a rolling, unlabeled transcript. `handleUtterance(_ transcript:
//  String)` was the single funnel into intent parsing, Gold, confirmations, and
//  dispatch — and it took a bare String. A String has no source, no direction,
//  and no turn identity, so every caller of it was, by construction, "the
//  founder". Two consequences shipped:
//
//    1. Ace's own spoken output, captured back through the open microphone on
//       the Partner / background-announcement paths, transcribed into a real
//       microphone-derived final transcript and routed as a new owner command.
//       An outbound line containing "open apple dot com" could open a browser.
//    2. A re-fired or delayed STT finalization could produce a second action for
//       one utterance, because de-duplication lived inside a single dictation
//       session and nowhere above it.
//
//  The fix is not a prompt and not a keyword filter. It is a typed envelope plus
//  two walls:
//
//    WALL 1 (acoustic, `AceSelfVoiceSuppressionWindow` + `AceCaptureWindowAudit`)
//      Ace's voice never reaches Speech Recognition. Enforced at the audio tap,
//      not after transcription, because a transcript of Ace's voice is
//      indistinguishable from a transcript of the owner's voice.
//
//    WALL 2 (structural, `AceInboundAdmission`)
//      Only a sealed, microphone-derived, `.user`-sourced, `.final` event may
//      enter routing. No outbound source has an admitted inbound payload type,
//      so Ace's *text* can never re-enter even if some future call site tries.
//
//  THE ENVELOPE IS IMMUTABLE ON PURPOSE. Every field is `let`, there are no
//  mutating members, and the state machine advances by deriving a NEW event
//  (`advanced(to:)`) that keeps session/turn/correlation identity. A mutable
//  envelope is a re-labelable envelope, and a re-labelable envelope is exactly
//  the impersonation this file exists to make impossible.
//
//  This file is pure Foundation with no app dependencies so the whole contract
//  is provable offline by `script/test_ace_event_envelope.swift`.
//

import Foundation

// MARK: - Envelope vocabulary

/// Who produced this event. `.user` is the ONLY source that may carry an owner
/// command, and only the capture boundary and an explicit human UI action may
/// mint one (see `AceInboundGate`).
///
/// `.ace` is Ace's own voice. `.gold` is the conversational orchestrator's
/// routing decisions (which are not speech). Keeping them separate is what lets
/// a diagnostic say "Gold delegated" without implying Gold spoke, and lets the
/// notes lane subscribe to Ace's speech without subscribing to routing chatter.
public enum AceEventSource: String, Sendable, CaseIterable, Equatable {
    case user
    case ace
    case gold
    case red
    case silver
    case partner
    case notes
    case system

    /// The owner. Exactly one source, and it is never a lane.
    public var isOwner: Bool { self == .user }

    /// Every source that is Ace or one of its lanes. None of these may ever
    /// appear on an admitted inbound routing event — that is the impersonation
    /// wall stated as a predicate.
    public var isAceProduced: Bool { !isOwner }
}

public enum AceEventDirection: String, Sendable, CaseIterable, Equatable {
    /// Toward Ace: the owner speaking or acting.
    case inbound
    /// Away from Ace: speech, receipts, advice, notes, timers, cards.
    case outbound
}

/// Lifecycle position. `.partial` and `.final` belong to capture; `.routed`
/// through `.cancelled` belong to work.
public enum AceEventState: String, Sendable, CaseIterable, Equatable {
    case partial
    case final
    case routed
    case executing
    case completed
    case failed
    case cancelled

    /// A terminal state cannot advance again. Late work events for a turn that
    /// already ended are stale and are dropped rather than reordered in.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .partial, .final, .routed, .executing: return false
        }
    }
}

/// What the payload IS. The admission wall is a payload-type check as much as a
/// source check: microphone-derived speech and a direct human UI action are the
/// only two shapes that can carry a command, and no outbound shape is either.
public enum AceEventPayloadType: String, Sendable, CaseIterable, Equatable {

    // --- Inbound-capable shapes ---

    /// A live, still-changing microphone transcript. May update UI. May never
    /// route, invoke a tool, or reach Gold.
    case microphonePartialTranscript

    /// The sealed, microphone-derived final transcript for one turn. Exactly one
    /// of these per turn may enter routing.
    case microphoneFinalTranscript

    /// A physical human action in Ace's own UI (the setup window's live-test
    /// buttons). Hardware-attested by the click, so it carries owner authority —
    /// but it is labeled distinctly so a diagnostic can never confuse a button
    /// with speech.
    case directHumanUIAction

    /// Developer injection (the `RUN_SAY` observability flag). Admitted only in
    /// DEBUG builds; `AceInboundAdmission` rejects it outright in Release, so a
    /// shipped app has no synthetic command path at all.
    case developerInjection

    // --- Outbound-only shapes ---

    /// Ace speaking. This is the payload type that used to come back through the
    /// microphone and route as a command.
    case aceSpeech
    /// A lane reporting what it did (Red / Silver execution receipts).
    case laneReceipt
    /// Partner's advice. Advisory only — Partner has no direct effect.
    case partnerAdvice
    /// A notes-lane update.
    case notesUpdate
    /// A timer firing.
    case timer
    /// A visual card / preview surfaced to the owner.
    case card
    /// The receipt for a dispatched unit of work.
    case executionReceipt
    /// Structured diagnostics.
    case diagnostic

    /// True only for shapes that can legitimately arrive from outside Ace.
    /// Everything else is Ace's own production and can never be inbound.
    public var canBeInbound: Bool {
        switch self {
        case .microphonePartialTranscript,
             .microphoneFinalTranscript,
             .directHumanUIAction,
             .developerInjection:
            return true
        case .aceSpeech, .laneReceipt, .partnerAdvice, .notesUpdate,
             .timer, .card, .executionReceipt, .diagnostic:
            return false
        }
    }

    /// True only for the shapes that may reach intent parsing, Gold,
    /// confirmations, and dispatch.
    public var canCarryOwnerCommand: Bool {
        switch self {
        case .microphoneFinalTranscript,
             .directHumanUIAction,
             .developerInjection:
            return true
        default:
            return false
        }
    }

    /// A partial may light the UI and nothing else.
    public var isUIOnly: Bool { self == .microphonePartialTranscript }
}

/// How the audio that produced an event was captured. Not part of the envelope —
/// it is capture-boundary metadata used to decide suppression and to label the
/// resulting event's payload type.
public enum AceCaptureOrigin: String, Sendable, Equatable {
    /// The owner physically held the global push-to-talk chord. Hardware
    /// attestation: a press is an explicit claim on the floor and barges in.
    case pushToTalk
    /// The persistent microphone button.
    case microphoneButton
    /// Partner's automatic open-microphone turn. No hardware attestation, so the
    /// self-voice window applies in full.
    case partnerAutomatic

    /// Open-microphone paths cannot distinguish Ace's voice from the owner's by
    /// intent, only by timing.
    public var isOpenMicrophone: Bool { self == .partnerAutomatic }
}

// MARK: - The envelope

/// One immutable event. Constructed once, never edited.
///
/// Identity has three levels and they are not interchangeable:
///   • `sessionID`     — one app run. Survives every turn.
///   • `turnID`        — one owner turn. Every event caused by that turn, in
///                       either direction, carries it.
///   • `correlationID` — one unit of work inside a turn. A dispatch and its
///                       receipt share it, which is how a background completion
///                       that lands after two more turns still attaches to the
///                       right request instead of the newest one.
public struct AceEvent: Sendable, Equatable {
    public let sessionID: UUID
    public let turnID: UUID
    public let correlationID: UUID
    public let timestamp: Date
    public let source: AceEventSource
    public let direction: AceEventDirection
    public let state: AceEventState
    public let payloadType: AceEventPayloadType
    public let payload: String

    public init(
        sessionID: UUID,
        turnID: UUID,
        correlationID: UUID,
        timestamp: Date,
        source: AceEventSource,
        direction: AceEventDirection,
        state: AceEventState,
        payloadType: AceEventPayloadType,
        payload: String
    ) {
        self.sessionID = sessionID
        self.turnID = turnID
        self.correlationID = correlationID
        self.timestamp = timestamp
        self.source = source
        self.direction = direction
        self.state = state
        self.payloadType = payloadType
        self.payload = payload
    }

    /// Derive the next state while keeping identity. Returns a NEW value; the
    /// receiver is untouched. This is the only way an event "changes".
    public func advanced(
        to nextState: AceEventState,
        payload nextPayload: String? = nil,
        at nextTimestamp: Date
    ) -> AceEvent {
        AceEvent(
            sessionID: sessionID,
            turnID: turnID,
            correlationID: correlationID,
            timestamp: nextTimestamp,
            source: source,
            direction: direction,
            state: nextState,
            payloadType: payloadType,
            payload: nextPayload ?? payload
        )
    }

    /// A fresh correlation for a new unit of work inside the SAME turn — a Gold
    /// delegation, a Red dispatch, a Silver build. Session and turn are
    /// preserved so the receipt still attaches to the owner's request.
    public func branchedForWork(
        source workSource: AceEventSource,
        state workState: AceEventState,
        payloadType workPayloadType: AceEventPayloadType,
        payload workPayload: String,
        correlationID workCorrelationID: UUID,
        at workTimestamp: Date
    ) -> AceEvent {
        AceEvent(
            sessionID: sessionID,
            turnID: turnID,
            correlationID: workCorrelationID,
            timestamp: workTimestamp,
            source: workSource,
            direction: .outbound,
            state: workState,
            payloadType: workPayloadType,
            payload: workPayload
        )
    }

    /// Payload with whitespace collapsed off the ends. Routing reads this; the
    /// transcript records `payload` verbatim.
    public var trimmedPayload: String {
        payload.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmptyPayload: Bool { trimmedPayload.isEmpty }
}

// MARK: - Short identifiers for diagnostics

public enum AceEventIdentifier {
    /// First 8 hex characters of a UUID. Enough to correlate two lines in
    /// `agent.log` by eye, short enough that a receipt stays readable, and it
    /// carries no content.
    public static func short(_ identifier: UUID) -> String {
        String(identifier.uuidString.prefix(8)).lowercased()
    }
}

// MARK: - WALL 1: self-voice suppression at the capture boundary

/// The acoustic wall. Ace's voice must not reach Speech Recognition, because
/// once it has been transcribed it is a genuine microphone-derived transcript
/// and no downstream check can tell it from the owner.
///
/// The window is: while Ace is speaking, plus a tail after speech ends. The tail
/// covers the acoustic decay and the recognizer's own lag — the moment the
/// daemon reports DONE, the room has not gone quiet yet.
///
/// The tail is DELIBERATELY SHORT. Requirement: suppression must be observable
/// and must not discard actual user speech after the defined tail. 450 ms is
/// past the speaker decay and well inside the gap before a human starts a new
/// sentence; a push-to-talk press halts speech immediately, so on the hardware-
/// attested path the window collapses to the tail alone.
public enum AceSelfVoiceSuppressionWindow {

    /// Seconds after Ace's speech ends during which capture is still suppressed.
    public static let tailSeconds: TimeInterval = 0.45

    public enum Reason: String, Sendable, Equatable {
        /// Ace is speaking right now.
        case aceIsSpeaking
        /// Ace stopped, but we are inside the acoustic tail.
        case selfVoiceTail
    }

    public enum Decision: Sendable, Equatable {
        case forward
        case suppress(Reason)

        public var isSuppressed: Bool {
            if case .suppress = self { return true }
            return false
        }

        public var reason: Reason? {
            if case let .suppress(reason) = self { return reason }
            return nil
        }
    }

    /// Pure. `speechEndedAt` is the instant Ace's last utterance stopped
    /// (`distantPast` when Ace has never spoken).
    public static func decision(
        aceIsSpeaking: Bool,
        speechEndedAt: Date,
        now: Date,
        tailSeconds: TimeInterval = tailSeconds
    ) -> Decision {
        if aceIsSpeaking { return .suppress(.aceIsSpeaking) }
        let secondsSinceSpeechEnded = now.timeIntervalSince(speechEndedAt)
        if secondsSinceSpeechEnded < tailSeconds { return .suppress(.selfVoiceTail) }
        return .forward
    }
}

/// The second half of Wall 1. Suppressing buffers stops Ace's voice from
/// reaching the recognizer, but a recognizer that was already holding Ace's
/// words can still emit a final. So each dictation session counts what it
/// actually forwarded, and a session that forwarded NOTHING cannot produce an
/// admitted final — there was no owner audio in it by construction.
///
/// A session that forwarded even one buffer DID contain owner audio and its
/// final is admitted: that is the "must not discard actual user speech" half of
/// the requirement, stated as a rule rather than a hope.
public struct AceCaptureWindowAudit: Sendable, Equatable {
    public private(set) var forwardedBufferCount: Int
    public private(set) var suppressedBufferCount: Int
    public private(set) var lastSuppressionReason: AceSelfVoiceSuppressionWindow.Reason?

    public init(
        forwardedBufferCount: Int = 0,
        suppressedBufferCount: Int = 0,
        lastSuppressionReason: AceSelfVoiceSuppressionWindow.Reason? = nil
    ) {
        self.forwardedBufferCount = forwardedBufferCount
        self.suppressedBufferCount = suppressedBufferCount
        self.lastSuppressionReason = lastSuppressionReason
    }

    public mutating func recordForwarded() { forwardedBufferCount += 1 }

    public mutating func recordSuppressed(
        _ reason: AceSelfVoiceSuppressionWindow.Reason
    ) {
        suppressedBufferCount += 1
        lastSuppressionReason = reason
    }

    /// Any owner audio at all reached the recognizer.
    public var admitsFinalTranscript: Bool { forwardedBufferCount > 0 }

    /// True when the session was suppressed end to end — the shape of Ace
    /// hearing itself and nothing else.
    public var wasFullySuppressed: Bool {
        forwardedBufferCount == 0 && suppressedBufferCount > 0
    }

    public var didSuppressAnything: Bool { suppressedBufferCount > 0 }
}

// MARK: - Turn ledger: idempotency, ordering, cancellation

public enum AceFinalAdmission: Sendable, Equatable {
    /// First sealed final for this turn. Route it.
    case admitted
    /// A second final arrived for a turn that is already sealed.
    case duplicateTurn
    /// A different turn carrying the same words landed inside the duplicate
    /// window — the shape of one utterance finalized twice by the recognizer.
    case duplicateTranscript
    /// The turn was cancelled (barge-in, Private Mode, replacement) before its
    /// final arrived.
    case cancelledTurn

    public var routes: Bool { self == .admitted }
}

/// Per-session record of which turns have been sealed, cancelled, or completed.
///
/// Value type on purpose: the ledger is owned by the MainActor bus and mutated
/// through it, so there is no second copy to disagree with.
public struct AceTurnLedger: Sendable {

    /// Two finals carrying the same words inside this window are one utterance
    /// finalized twice. It is deliberately tight: the owner genuinely repeating
    /// a command ("open apple.com", then again two minutes later) must route
    /// both times. Anything longer starts eating real repeats.
    public static let duplicateTranscriptWindowSeconds: TimeInterval = 2.5

    private struct SealedFinal {
        let turnID: UUID
        let fingerprint: String
        let at: Date
    }

    private var sealedTurns: Set<UUID> = []
    private var cancelledTurns: Set<UUID> = []
    private var terminatedCorrelations: Set<UUID> = []
    private var recentFinals: [SealedFinal] = []

    public init() {}

    /// Normalize for duplicate detection only. Never used for routing — routing
    /// always sees the owner's exact words.
    public static func fingerprint(_ text: String) -> String {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// The one-final-per-turn seal. Idempotent by construction: calling it twice
    /// for the same turn admits once.
    public mutating func admitFinal(
        turnID: UUID,
        payload: String,
        at now: Date,
        duplicateWindowSeconds: TimeInterval = duplicateTranscriptWindowSeconds,
        deduplicateAcrossTurns: Bool = true
    ) -> AceFinalAdmission {
        if cancelledTurns.contains(turnID) { return .cancelledTurn }
        if sealedTurns.contains(turnID) { return .duplicateTurn }

        let mark = Self.fingerprint(payload)
        recentFinals.removeAll { now.timeIntervalSince($0.at) > duplicateWindowSeconds }
        if deduplicateAcrossTurns,
           !mark.isEmpty,
           recentFinals.contains(where: { $0.fingerprint == mark }) {
            // Seal the turn anyway so a third copy of the same finalization
            // cannot walk in behind it once the window lapses.
            sealedTurns.insert(turnID)
            return .duplicateTranscript
        }

        sealedTurns.insert(turnID)
        if deduplicateAcrossTurns {
            recentFinals.append(SealedFinal(turnID: turnID, fingerprint: mark, at: now))
        }
        return .admitted
    }

    /// Barge-in, Private Mode, or a replacement utterance ends a turn. A final
    /// that arrives afterwards is stale and never routes.
    public mutating func cancel(turnID: UUID) {
        cancelledTurns.insert(turnID)
    }

    public func isCancelled(turnID: UUID) -> Bool { cancelledTurns.contains(turnID) }
    public func isSealed(turnID: UUID) -> Bool { sealedTurns.contains(turnID) }

    /// Background completion ordering. A unit of work reports terminal state
    /// exactly once; a retry that lands after the first completion is dropped
    /// rather than delivered twice.
    public mutating func admitTerminalWork(correlationID: UUID) -> Bool {
        guard !terminatedCorrelations.contains(correlationID) else { return false }
        terminatedCorrelations.insert(correlationID)
        return true
    }

    public func hasTerminated(correlationID: UUID) -> Bool {
        terminatedCorrelations.contains(correlationID)
    }
}

// MARK: - WALL 2: inbound admission

public enum AceAdmissionRefusal: String, Sendable, Equatable {
    /// An outbound event tried to enter the inbound stream. This is the exact
    /// impersonation the envelope exists to make impossible.
    case wrongDirection
    /// A non-owner source claimed owner authority. Ace, Gold, Red, Silver,
    /// Partner, notes, and system can never speak as the owner.
    case notOwnerSource
    /// A payload shape Ace produces (speech, receipt, advice, card) can never be
    /// inbound regardless of what source label it carries.
    case aceProducedPayload
    /// A partial. It may update the UI; it may not route.
    case partialNotFinal
    /// Wrong lifecycle state for routing.
    case notFinalState
    /// Empty after trimming.
    case emptyPayload
    /// Developer injection reaching a Release build.
    case developerInjectionInRelease
    /// Session mismatch — an event minted before a relaunch cannot route now.
    case foreignSession
}

public enum AceInboundAdmissionResult: Sendable, Equatable {
    /// Route it: intent parsing, Gold, confirmations, dispatch.
    case admitForRouting
    /// Show it and nothing else.
    case admitForUIOnly
    case refuse(AceAdmissionRefusal)

    public var routes: Bool { self == .admitForRouting }

    public var refusal: AceAdmissionRefusal? {
        if case let .refuse(refusal) = self { return refusal }
        return nil
    }
}

/// The structural wall. Pure, total, and checked in exactly one place so there
/// is one thing to reason about.
///
/// Read the rules as a single sentence: an event may route only if it is
/// inbound, sourced to the owner, carries a payload shape Ace does not produce,
/// is in the final state, and is not empty.
public enum AceInboundAdmission {

    public static func decide(
        _ event: AceEvent,
        sessionID: UUID,
        isDebugBuild: Bool
    ) -> AceInboundAdmissionResult {

        // Direction first. An outbound event has no business here at all, and
        // saying so before anything else means the refusal reason names the
        // real problem rather than a downstream symptom.
        guard event.direction == .inbound else { return .refuse(.wrongDirection) }

        // A payload shape Ace produces cannot be inbound even if something
        // mislabeled its source. Checked BEFORE the source check so a forged
        // `.user` label on Ace speech is refused for the honest reason.
        guard event.payloadType.canBeInbound else { return .refuse(.aceProducedPayload) }

        // Only the owner. No lane, no orchestrator, no system announcement.
        guard event.source.isOwner else { return .refuse(.notOwnerSource) }

        guard event.sessionID == sessionID else { return .refuse(.foreignSession) }

        // Partials update the waveform and the caption. They never route, never
        // invoke a tool, and never reach Gold.
        if event.payloadType.isUIOnly {
            return event.state == .partial
                ? .admitForUIOnly
                : .refuse(.partialNotFinal)
        }

        guard event.state == .final else { return .refuse(.notFinalState) }
        guard !event.isEmptyPayload else { return .refuse(.emptyPayload) }

        if event.payloadType == .developerInjection, !isDebugBuild {
            return .refuse(.developerInjectionInRelease)
        }

        guard event.payloadType.canCarryOwnerCommand else {
            return .refuse(.aceProducedPayload)
        }

        return .admitForRouting
    }
}

// MARK: - Outbound admission

public enum AceOutboundRefusal: String, Sendable, Equatable {
    /// An inbound event tried to be published outbound.
    case wrongDirection
    /// The owner is not a producer of outbound events. Ace never publishes
    /// anything "as" the owner — that is how a rolling transcript loses the
    /// distinction in the first place.
    case ownerCannotProduceOutbound
    /// An inbound-only payload shape (a microphone transcript) cannot be
    /// republished outbound, because a subscriber could then treat Ace's echo of
    /// the owner as new owner input.
    case inboundOnlyPayload
    case emptyPayload
}

public enum AceOutboundAdmissionResult: Sendable, Equatable {
    case publish
    case refuse(AceOutboundRefusal)

    public var publishes: Bool { self == .publish }

    public var refusal: AceOutboundRefusal? {
        if case let .refuse(refusal) = self { return refusal }
        return nil
    }
}

public enum AceOutboundAdmission {
    public static func decide(_ event: AceEvent) -> AceOutboundAdmissionResult {
        guard event.direction == .outbound else { return .refuse(.wrongDirection) }
        guard !event.source.isOwner else { return .refuse(.ownerCannotProduceOutbound) }
        guard !event.payloadType.canBeInbound else { return .refuse(.inboundOnlyPayload) }
        guard !event.isEmptyPayload else { return .refuse(.emptyPayload) }
        return .publish
    }
}

// MARK: - Lane isolation

/// Which labeled events a consumer is allowed to see. Lanes are isolated
/// consumers as well as isolated producers: the notes lane subscribing to
/// "everything" is how a Partner aside ends up in the owner's meeting notes.
public enum AceEventSubscription: String, Sendable, CaseIterable {
    /// Everything outbound — the UI event stream and diagnostics.
    case allOutbound
    /// Ace's speech and execution receipts, which is what a notes lane needs to
    /// record what happened. Never Partner advice.
    case notesLane
    /// Partner sees the owner's turn and its own advice. It never sees Red or
    /// Silver internals and it has no direct effect.
    case partnerLane
    /// Execution receipts only.
    case receiptsOnly

    public func accepts(_ event: AceEvent) -> Bool {
        switch self {
        case .allOutbound:
            return event.direction == .outbound

        case .notesLane:
            guard event.direction == .outbound else { return false }
            switch event.source {
            case .ace, .red, .silver, .notes, .system:
                return event.payloadType != .partnerAdvice
            case .partner, .gold, .user:
                return false
            }

        case .partnerLane:
            guard event.direction == .outbound else { return false }
            switch event.source {
            case .partner:
                return true
            case .ace:
                return event.payloadType == .aceSpeech
            case .red, .silver, .notes, .gold, .system, .user:
                return false
            }

        case .receiptsOnly:
            return event.direction == .outbound
                && (event.payloadType == .executionReceipt
                    || event.payloadType == .laneReceipt)
        }
    }
}

/// Partner advises; it never acts. Stated as a predicate so the test can prove
/// it rather than trusting the call sites.
public enum AceLaneAuthority {
    /// May this source cause a direct effect (open an app, send mail, run a
    /// tool)?
    public static func mayCauseDirectEffect(_ source: AceEventSource) -> Bool {
        switch source {
        case .red, .silver:
            return true
        case .user, .ace, .gold, .partner, .notes, .system:
            return false
        }
    }

    /// May this source select a lane and delegate work? Gold only — and Gold
    /// delegates the owner's unchanged words through the existing dispatcher; it
    /// does not author an executable instruction.
    public static func mayDelegate(_ source: AceEventSource) -> Bool {
        source == .gold
    }
}

// MARK: - Structured diagnostics

/// One line per event, appended to the existing `agent.log` channel.
///
/// CONTENT NEVER APPEARS. The owner's words, Ace's answers, model prompts, and
/// raw audio are all absent by construction: the line carries identity, source,
/// direction, state, payload TYPE, the routing decision, byte count, and a
/// non-reversible digest. Private Mode already forbids transcript content in
/// logs, and a diagnostic that leaked it would be the same bug wearing a
/// different name.
public enum AceEventDiagnostics {

    /// Non-reversible, collision-tolerant fingerprint. Enough to prove two
    /// receipts refer to the same utterance; useless for recovering it.
    public static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in Array(text.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%08x", UInt32(truncatingIfNeeded: hash >> 32))
    }

    public static func line(
        for event: AceEvent,
        decision: String,
        detail: String? = nil
    ) -> String {
        var fields: [String] = [
            "EVENT",
            "src=\(event.source.rawValue)",
            "dir=\(event.direction.rawValue)",
            "state=\(event.state.rawValue)",
            "type=\(event.payloadType.rawValue)",
            "session=\(AceEventIdentifier.short(event.sessionID))",
            "turn=\(AceEventIdentifier.short(event.turnID))",
            "corr=\(AceEventIdentifier.short(event.correlationID))",
            "route=\(sanitize(decision))",
            "bytes=\(event.payload.utf8.count)",
            "digest=\(digest(event.payload))",
        ]
        if let detail, !detail.isEmpty {
            fields.append("detail=\(sanitize(detail))")
        }
        return fields.joined(separator: " ")
    }

    /// A capture-boundary receipt. Suppression must be observable — this is the
    /// observation. It names counts and a reason, never audio.
    public static func suppressionLine(
        origin: AceCaptureOrigin,
        audit: AceCaptureWindowAudit,
        outcome: String,
        turnID: UUID
    ) -> String {
        [
            "CAPTURE-GATE",
            "origin=\(origin.rawValue)",
            "turn=\(AceEventIdentifier.short(turnID))",
            "forwarded=\(audit.forwardedBufferCount)",
            "suppressed=\(audit.suppressedBufferCount)",
            "reason=\(audit.lastSuppressionReason?.rawValue ?? "none")",
            "outcome=\(sanitize(outcome))",
        ].joined(separator: " ")
    }

    /// Log fields are single tokens: whitespace and control characters would let
    /// a crafted transcript forge extra fields or a second line.
    public static func sanitize(_ value: String) -> String {
        let collapsed = value.unicodeScalars.map { scalar -> String in
            if CharacterSet.controlCharacters.contains(scalar) { return "-" }
            if CharacterSet.whitespaces.contains(scalar) { return "-" }
            return String(scalar)
        }.joined()
        return collapsed.isEmpty ? "-" : collapsed
    }
}
