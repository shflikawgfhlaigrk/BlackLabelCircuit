//
//  AceProviderTurn.swift
//  Ace
//
//  Immutable provider identity for one admitted owner turn.
//

import Foundation

nonisolated struct AceProviderTurn: Equatable, Sendable {
    let id: UUID
    let provider: BrainCLI

    init(
        id: UUID = UUID(),
        provider: BrainCLI
    ) {
        self.id = id
        self.provider = provider
    }

    static func capture(
        _ selection: () -> BrainCLI
    ) -> AceProviderTurn {
        AceProviderTurn(provider: selection())
    }
}

/// A failed live invocation revokes an older connection claim until a newer
/// real probe succeeds. Only a classified cause is stored, never raw output.
nonisolated struct AceProviderRuntimeFailure: Codable, Equatable, Sendable {
    let turnID: UUID
    let providerIdentifier: String
    let startedAt: Date
    let failedAt: Date
    let cause: String

    func supersedesProbe(answeredAt: Date?) -> Bool {
        answeredAt.map { $0 <= startedAt } ?? true
    }
}

nonisolated struct AceProviderInvocationReceipt:
    Codable, Equatable, Sendable {
    enum Phase: String, Codable, Equatable, Sendable {
        case processing
        case completed
        case failed
        case cancelled
    }

    let turnID: UUID
    let providerIdentifier: String
    let phase: Phase
    let startedAt: Date
    let updatedAt: Date
}

extension Notification.Name {
    static let aceProviderInvocationReceiptDidChange =
        Notification.Name("ace.provider-invocation-receipt.changed")
}

/// Provider activity is rendered only from these actual invocation receipts.
/// Selection and connection proof never imply Processing or Last used.
nonisolated enum AceProviderInvocationReceiptStore {
    private static let lock = NSLock()
    private static let keyPrefix = "AceProviderInvocationReceipt.v1"

    static func recordStarted(_ turn: AceProviderTurn) {
        save(
            AceProviderInvocationReceipt(
                turnID: turn.id,
                providerIdentifier: turn.provider.rawValue,
                phase: .processing,
                startedAt: Date(),
                updatedAt: Date()
            )
        )
    }

    static func recordFinished(
        _ turn: AceProviderTurn,
        phase: AceProviderInvocationReceipt.Phase
    ) {
        let prior = receipt(for: turn.provider)
        save(
            AceProviderInvocationReceipt(
                turnID: turn.id,
                providerIdentifier: turn.provider.rawValue,
                phase: phase,
                startedAt: prior?.turnID == turn.id
                    ? prior?.startedAt ?? Date() : Date(),
                updatedAt: Date()
            )
        )
    }

    static func receipt(
        for provider: BrainCLI
    ) -> AceProviderInvocationReceipt? {
        lock.withLock {
            guard let data = UserDefaults.standard.data(
                forKey: key(for: provider)
            ) else { return nil }
            return try? JSONDecoder().decode(
                AceProviderInvocationReceipt.self,
                from: data
            )
        }
    }

    static func recordRuntimeFailure(
        _ turn: AceProviderTurn,
        startedAt: Date,
        cause: String,
        at timestamp: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        let failure = AceProviderRuntimeFailure(
            turnID: turn.id, providerIdentifier: turn.provider.rawValue,
            startedAt: startedAt, failedAt: timestamp, cause: cause
        )
        let changed = lock.withLock {
            let key = "AceProviderRuntimeFailure.v1." + turn.provider.rawValue
            if let data = defaults.data(forKey: key),
               let newer = try? JSONDecoder().decode(AceProviderRuntimeFailure.self, from: data),
               newer.startedAt > startedAt { return false }
            guard let data = try? JSONEncoder().encode(failure) else { return false }
            defaults.set(data, forKey: key)
            return true
        }
        if changed {
            NotificationCenter.default.post(name: .aceProviderInvocationReceiptDidChange, object: nil)
        }
    }

    static func runtimeFailure(
        for provider: BrainCLI,
        defaults: UserDefaults = .standard
    ) -> AceProviderRuntimeFailure? {
        lock.withLock {
            guard let data = defaults.data(forKey: "AceProviderRuntimeFailure.v1." + provider.rawValue),
                  let failure = try? JSONDecoder().decode(AceProviderRuntimeFailure.self, from: data),
                  failure.providerIdentifier == provider.rawValue else { return nil }
            return failure
        }
    }

    private static func save(_ receipt: AceProviderInvocationReceipt) {
        let encoded = try? JSONEncoder().encode(receipt)
        lock.withLock {
            UserDefaults.standard.set(
                encoded,
                forKey: keyPrefix + "." + receipt.providerIdentifier
            )
        }
        NotificationCenter.default.post(
            name: .aceProviderInvocationReceiptDidChange,
            object: nil
        )
    }

    private static func key(for provider: BrainCLI) -> String {
        keyPrefix + "." + provider.rawValue
    }
}
