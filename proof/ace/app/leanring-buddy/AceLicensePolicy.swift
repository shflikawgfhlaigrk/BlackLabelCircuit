//
//  AceLicensePolicy.swift
//  Ace
//
//  Pure, offline policy for deciding whether stored licence state may unlock
//  this launch. The network and UI stay in AceLicense; this file keeps the
//  fail-closed boot rules deterministic and headlessly testable.
//

import Foundation

enum AceLicenseBootDecision: Equatable {
    case needsKey
    case licensed(normalizedKey: String, until: Date)
    case requiresOnlineVerification(normalizedKey: String)
}

enum AceLicensePolicy {
    /// Purchase keys have one documented shape. Rejecting everything else before
    /// reading a cached lease prevents an arbitrary UserDefaults string from
    /// turning an offline `.unknown` launch into an unlocked one.
    static func normalizedKey(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let normalized = candidate
            .replacingOccurrences(
                of: #"\s+"#,
                with: "",
                options: .regularExpression
            )
            .uppercased()
        guard normalized.range(
            of: #"^ACE-[A-Z0-9]{4}(?:-[A-Z0-9]{4}){3}$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        return normalized
    }

    /// A launch may work offline only from an unexpired lease that belongs to
    /// the same normalized key. An unbound legacy date is not authority: it was
    /// stored in mutable preferences and must be refreshed by the server once.
    static func bootDecision(
        storedKey: String?,
        leaseExpiry: Date?,
        leaseKey: String?,
        now: Date
    ) -> AceLicenseBootDecision {
        guard let normalizedStoredKey = normalizedKey(storedKey) else {
            return .needsKey
        }

        guard let leaseExpiry, leaseExpiry > now else {
            return .requiresOnlineVerification(normalizedKey: normalizedStoredKey)
        }

        if let normalizedLeaseKey = normalizedKey(leaseKey) {
            guard normalizedLeaseKey == normalizedStoredKey else {
                return .requiresOnlineVerification(normalizedKey: normalizedStoredKey)
            }
            return .licensed(
                normalizedKey: normalizedStoredKey,
                until: leaseExpiry
            )
        }

        return .requiresOnlineVerification(
            normalizedKey: normalizedStoredKey
        )
    }
}
