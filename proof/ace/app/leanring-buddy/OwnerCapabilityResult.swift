//
//  OwnerCapabilityResult.swift
//  Ace
//
//  One content-bounded terminal returned by every owner capability executor.
//

import Foundation

nonisolated enum OwnerCapabilityStatus: String, Equatable, Sendable {
    case verified
    case attempted
    case failed
    case cancelled
    case unavailable
}

nonisolated struct OwnerCapabilityResult: Equatable, Sendable {
    let status: OwnerCapabilityStatus
    let spokenSummary: String
    let contentFreeReceipt: String
    let recoveryReference: String?

    var isSuccessful: Bool {
        status == .verified || status == .attempted
    }

    var isTerminal: Bool { true }
}
