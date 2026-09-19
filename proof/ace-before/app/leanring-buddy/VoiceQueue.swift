//
//  VoiceQueue.swift
//  leanring-buddy
//
//  Ported from utah-Ace 2026-07-26 (founder: "port all of it") — written there,
//  never wired there. Wired HERE inside NoraVoice, so every one of the ~80
//  speech call sites gets one-mouth semantics without being touched.
//
//  Lanes (gold Q&A, red agent, blue notetaker, purple trading) are independent
//  and can all be lit at once — but Nora is not independent. There is one mouth.
//  Every lane posts its speech here and the queue speaks ONE item at a time, so
//  two lanes can never talk over each other. If gold is mid-answer and the red
//  agent finishes, red's "done" waits its turn instead of cutting in.
//
//  Two rules make this safe rather than buggy:
//    1. A fresh user-facing answer (.foreground) jumps ahead of background
//       announcements (.background) — a live reply never waits behind a stale
//       "your timer went off."
//    2. "stop" / barge-in BYPASSES the queue: it flushes everything and halts
//       current speech immediately. It is an interrupt, never a queued item —
//       a queued stop is the exact shape of the notes-inversion / clipped-stop
//       bugs the shipping Ace already fought.
//
//  Decoupled from NoraTTSClient via injected closures (mirrors how the
//  notetaker is wired) so it is unit-testable without audio.
//

import Foundation

@MainActor
final class VoiceQueue {

    /// Which lane an utterance came from. Kept on every item so a delayed
    /// background announcement can be framed by its source ("the red agent came
    /// back and finished that") and so the route log names the speaker.
    enum Lane: String {
        case gold, red, blue, purple, green
    }

    /// `.foreground` is what the user is actively waiting on right now — a gold
    /// answer, a chart read. `.background` is a lane surfacing on its own — the
    /// red agent completing, a timer firing. Foreground always drains first.
    enum Priority {
        case foreground
        case background
    }

    /// The only successful safety receipt is `.completed`, returned by the
    /// sound-producing daemon after it emits DONE for this exact queue item.
    /// Everything else is deliberately non-authorizing.
    enum Completion: Equatable, Sendable {
        case completed
        case interrupted
        case failed
    }

    /// Ordinary speech is part of Ace's durable conversation and outbound
    /// event stream. Local sensitive readouts (for example, inbox previews)
    /// may be spoken and shown but must never persist their text or publish it
    /// as an event payload.
    enum Persistence: Equatable {
        case durableTranscriptAndEvents
        case volatile
    }

    private struct Item {
        let id: UUID
        let lane: Lane
        let priority: Priority
        let text: String
        let persistence: Persistence
        let speechOverride: (@MainActor (String) async throws -> Completion)?
    }

    /// Speak one utterance to completion. Wraps `NoraVoice`'s daemon speak-to-completion.
    private let speak: (String) async throws -> Completion

    /// Halt any in-flight utterance immediately (barge-in). Wraps
    /// the daemon halt.
    private let haltCurrent: () -> Void
    private let activityDidChange: (Bool) -> Void
    private let stealthEntryLatch: StealthEntryLatch

    /// Publishes each spoken item onto the outbound event stream. INJECTED with
    /// a no-op default so this file stays standalone-testable — `NoraVoice`
    /// supplies the real `AceEventBus` sink when it builds the queue.
    ///
    /// This is the outbound half of the event system's central rule: everything
    /// Ace says is a labeled OUTBOUND event, and an outbound event has no path
    /// back into transcription, the owner's transcript, intent parsing, or
    /// delegation. Publishing here rather than at the ~80 call sites means a new
    /// speech site cannot forget to label itself.
    private let publishOutbound:
        @MainActor (Lane, AceEventState, String, UUID) -> Void

    private var lastResponse: (text: String, beganAt: Date)?

    var repeatableResponseText: String? {
        guard !stealthEntryLatch.isRaised, let response = lastResponse,
              (0...300).contains(Date().timeIntervalSince(response.beganAt)) else { return nil }
        return response.text
    }

    func forgetRepeatableResponse() {
        lastResponse = nil
    }

    private var queue: [Item] = []
    private var isDraining = false
    private var drainTask: Task<Void, Never>?
    private var currentItemID: UUID?
    private var completionWaiters:
        [UUID: CheckedContinuation<Completion, Never>] = [:]

    /// Bumped by every flush or current-item cancellation. The retained drain
    /// task is cancelled immediately so a cooperative preflight cannot cross its
    /// speech commit; the generation then makes that stale loop exit after it
    /// unwinds and starts a fresh loop for any later items.
    private var generation = 0

    init(
        speak: @escaping (String) async throws -> Completion,
        haltCurrent: @escaping () -> Void,
        activityDidChange: @escaping (Bool) -> Void = { _ in },
        stealthEntryLatch: StealthEntryLatch = .shared,
        publishOutbound: @escaping @MainActor (Lane, AceEventState, String, UUID) -> Void
            = { _, _, _, _ in }
    ) {
        self.speak = speak
        self.haltCurrent = haltCurrent
        self.activityDidChange = activityDidChange
        self.stealthEntryLatch = stealthEntryLatch
        self.publishOutbound = publishOutbound
    }

    /// True while something is playing or waiting. A lane consults this to decide
    /// whether its announcement needs source-framing (it will surface behind
    /// other speech) or can be spoken plainly (the voice is idle).
    var hasPendingOrSpeaking: Bool {
        !stealthEntryLatch.isRaised
            && (isDraining || !queue.isEmpty)
    }

    /// Post an utterance from a lane. Empty/whitespace text is dropped. Foreground
    /// items are inserted ahead of the first queued background item (FIFO within
    /// each tier) so a live answer never queues behind a stale announcement.
    @discardableResult
    func enqueue(
        _ text: String,
        from lane: Lane,
        priority: Priority = .background,
        persistence: Persistence = .durableTranscriptAndEvents
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let item = Item(
            id: UUID(),
            lane: lane,
            priority: priority,
            text: trimmed,
            persistence: persistence,
            speechOverride: nil
        )

        // Queue admission and the event-tap raise share one linearization lock:
        // an item is either committed before X (and invalidated by that entry)
        // or rejected after X. It can never appear in the queue behind the wall.
        return stealthEntryLatch.performUnlessRaised {
            insert(item)
            startDrainingIfNeeded()
            return true
        } ?? false
    }

    /// Enqueues one safety-sensitive line and waits for the result of this exact
    /// queue item. Flush, cancellation, STOPPED, BLOCKED, daemon failure, and a
    /// start timeout all resolve non-successfully. Callers must authorize only
    /// `.completed`.
    func enqueueAndWait(
        _ text: String,
        from lane: Lane,
        priority: Priority = .foreground,
        persistence: Persistence = .durableTranscriptAndEvents,
        speechOverride: (@MainActor (String) async throws -> Completion)? = nil
    ) async -> Completion {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !Task.isCancelled,
              !stealthEntryLatch.isRaised else {
            if stealthEntryLatch.isRaised {
                return .interrupted
            }
            return Task.isCancelled ? .interrupted : .failed
        }

        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .interrupted)
                    return
                }
                let didEnqueue: Bool =
                    stealthEntryLatch.performUnlessRaised {
                        completionWaiters[id] = continuation
                        insert(
                            Item(
                                id: id,
                                lane: lane,
                                priority: priority,
                                text: trimmed,
                                persistence: persistence,
                                speechOverride: speechOverride
                            )
                        )
                        startDrainingIfNeeded()
                        return true
                    } ?? false
                if !didEnqueue {
                    continuation.resume(
                        returning: .interrupted
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelAwaitedItem(id)
            }
        }
    }

    private func insert(_ item: Item) {
        if item.priority == .foreground {
            let insertAt = queue.firstIndex { $0.priority == .background } ?? queue.count
            queue.insert(item, at: insertAt)
        } else {
            queue.append(item)
        }
    }

    /// Barge-in / "stop": clear the queue, cancel any preflight, and halt current
    /// speech NOW. A stale loop exits on its bumped generation after unwinding.
    func interruptAndFlush() {
        queue.removeAll()
        generation &+= 1
        let retiredDrainTask = drainTask
        drainTask = nil
        isDraining = false
        currentItemID = nil
        retiredDrainTask?.cancel()
        haltCurrent()
        activityDidChange(false)
        let waiters = completionWaiters
        completionWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume(returning: .interrupted)
        }
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else { return }
        isDraining = true
        activityDidChange(true)
        let myGeneration = generation
        drainTask = Task { [weak self] in
            await self?.drain(generation: myGeneration)
        }
    }

    private func drain(generation myGeneration: Int) async {
        while true {
            if stealthEntryLatch.isRaised {
                interruptAndFlush()
                isDraining = false
                drainTask = nil
                return
            }
            // A flush during the previous `await speak` invalidates this loop.
            if myGeneration != generation {
                // The interrupt boundary already retired this generation and
                // may have started a replacement. A stale loop has no authority
                // to clear the replacement's state.
                return
            }
            guard !queue.isEmpty else {
                isDraining = false
                drainTask = nil
                activityDidChange(false)
                return
            }
            let item = queue.removeFirst()
            currentItemID = item.id
            lastResponse = (item.text, Date())
            // The mouth is opening. Published BEFORE the await so a subscriber
            // (and the capture-boundary diagnostics) sees the speech begin
            // rather than learning about it only once it is over.
            if item.persistence == .durableTranscriptAndEvents {
                publishOutbound(item.lane, .executing, item.text, item.id)
            }
            // A failed utterance must not wedge the queue — swallow and move on.
            // A preview owns its delivery and cleanup inside this item, so
            // the next queued line cannot inherit its temporary voice.
            let delivery = item.speechOverride ?? speak
            let completion = (try? await delivery(item.text)) ?? .failed
            let effectiveCompletion: Completion =
                stealthEntryLatch.isRaised
                    || myGeneration != generation
                ? .interrupted
                : completion
            // ONE MOUTH, one record. NoraVoice's three speak paths all funnel
            // into this queue, so this is the single point that sees
            // everything Ace says — including deterministic routes ("open
            // safari", the canned capability answer, memory recall) that
            // never reach the model.
            //
            // Recorded here rather than at enqueue on purpose: a line queued
            // moments before Private Mode is invalidated above, and
            // AceTranscript.record itself refuses to write under Stealth.
            // Interrupted and failed lines ARE recorded, with an explicit
            // marker: dropping them silently left dialogue holes ("the
            // transcript breaks in some areas") and erased the only durable
            // copy of an answer whose speech never finished. The panel's
            // visible-response card is the live text channel; the transcript
            // is the durable one — both must survive a failed voice.
            if item.persistence == .durableTranscriptAndEvents {
                switch effectiveCompletion {
                case .completed:
                    AceTranscript.record(role: .ace, text: item.text)
                case .interrupted:
                    AceTranscript.record(
                        role: .ace,
                        text: item.text + "\n\n*(speech interrupted before finishing)*"
                    )
                case .failed:
                    AceTranscript.record(
                        role: .ace,
                        text: item.text + "\n\n*(speech failed — delivered as text only)*"
                    )
                }
            }
            // The outbound terminal state for this exact spoken item, carrying
            // the same identifier the `.executing` event carried. An interrupted
            // line is published as `.cancelled`, not `.completed`: barge-in ends
            // the outbound turn and the record must say so.
            if item.persistence == .durableTranscriptAndEvents {
                publishOutbound(
                    item.lane,
                    Self.outboundState(for: effectiveCompletion),
                    item.text,
                    item.id
                )
            }
            if currentItemID == item.id {
                currentItemID = nil
            }
            finishAwaitedItem(item.id, with: effectiveCompletion)
        }
    }

    /// Speech completion → outbound event state. Pure so the contract is
    /// testable without audio.
    static func outboundState(for completion: Completion) -> AceEventState {
        switch completion {
        case .completed:   return .completed
        case .interrupted: return .cancelled
        case .failed:      return .failed
        }
    }

    private func cancelAwaitedItem(_ id: UUID) {
        guard completionWaiters[id] != nil else { return }
        if let queuedIndex = queue.firstIndex(where: { $0.id == id }) {
            queue.remove(at: queuedIndex)
        } else if currentItemID == id {
            generation &+= 1
            let retiredDrainTask = drainTask
            drainTask = nil
            isDraining = false
            currentItemID = nil
            retiredDrainTask?.cancel()
            haltCurrent()
        }
        activityDidChange(hasPendingOrSpeaking)
        finishAwaitedItem(id, with: .interrupted)
        if !queue.isEmpty, !stealthEntryLatch.isRaised {
            startDrainingIfNeeded()
        }
    }

    private func finishAwaitedItem(_ id: UUID, with completion: Completion) {
        guard let continuation = completionWaiters.removeValue(forKey: id) else {
            return
        }
        continuation.resume(returning: completion)
    }
}
