//
//  PendingMailDraftIntent.swift
//  Ace
//
//  Session-only continuation for an exact Mail draft request whose local
//  Apple Mail account is not ready yet. This file deliberately contains no
//  Codable, UserDefaults, filesystem, receipt, or logging path.
//

import Foundation

/// Private authoring context, independent of an expired turn's effect authority.
/// A reply gets a fresh admission and the normal exact-message review.
struct PrivateMailClarification {
    let sessionID: UUID
    let sender: String
    let request: String
    let question: String
    let createdAt: Date

    func resuming(
        answer: String,
        sessionID: UUID,
        currentSender: String?,
        now: Date = Date()
    ) -> String? {
        let age = now.timeIntervalSince(createdAt)
        guard self.sessionID == sessionID, currentSender == sender,
              age >= 0, age <= PendingMailDraftIntent.lifetime,
              !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.count + question.count + answer.count <= 200_000 else {
            return nil
        }
        return request + "\n\nAce asked: " + question
            + "\nOwner answered: " + answer
    }
}

struct PendingMailDraftIntent: Equatable {
    static let lifetime: TimeInterval = 5 * 60
    static let accountSetupDestination = URL(
        fileURLWithPath: "/System/Applications/Mail.app"
    )

    let id: UUID
    let turnID: UUID
    let exactRequest: String
    let createdAt: Date

    func isCurrent(at date: Date) -> Bool {
        let age = date.timeIntervalSince(createdAt)
        return age >= 0 && age <= Self.lifetime
    }
}

/// Owns private Mail continuation content only for this process lifetime.
/// Readiness may release one exact resume attempt; the intent itself remains
/// until its matching terminal, cancellation, replacement, or expiry.
final class PendingMailDraftIntentStore {
    private(set) var pendingIntent: PendingMailDraftIntent?
    private var resumedIntentID: UUID?

    @discardableResult
    func retain(
        id: UUID = UUID(),
        turnID: UUID,
        exactRequest: String,
        createdAt: Date = Date()
    ) -> PendingMailDraftIntent {
        cancel()
        let intent = PendingMailDraftIntent(
            id: id,
            turnID: turnID,
            exactRequest: exactRequest,
            createdAt: createdAt
        )
        pendingIntent = intent
        return intent
    }

    func resumeIfAccountReady(
        _ isReady: Bool,
        now: Date = Date()
    ) -> PendingMailDraftIntent? {
        guard let pendingIntent else { return nil }
        guard pendingIntent.isCurrent(at: now) else {
            cancel()
            return nil
        }
        guard isReady, resumedIntentID != pendingIntent.id else {
            return nil
        }
        resumedIntentID = pendingIntent.id
        return pendingIntent
    }

    func complete(intentID: UUID) {
        guard pendingIntent?.id == intentID else { return }
        cancel()
    }

    func cancel() {
        pendingIntent = nil
        resumedIntentID = nil
    }

    deinit {
        cancel()
    }
}
