// Black Label Marketing — shared, deterministic outbound-email safety rules.
//
// These helpers are deliberately free of UI, network, credential, and tenant state. Callers pass
// the buyer's own configuration and CRM facts explicitly, which keeps the package reusable and
// makes the exact rules executable in the fast test lane.
import Foundation

enum EmailSuppression {
    static func normalized(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A compact set of explicit CRM tags that mean "do not email". Exact normalized matches avoid
    /// accidentally suppressing an unrelated tag such as "stopping by".
    private static let suppressionTags: Set<String> = [
        "unsubscribe", "unsubscribed", "opt out", "opt-out",
        "do not contact", "do-not-contact", "suppressed", "email suppressed"
    ]

    static func hasSuppressionTag(_ tags: [String]) -> Bool {
        tags.contains { suppressionTags.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
    }

    /// Central suppression decision used by sequences, journeys, manual newsletters, and the
    /// Cloudflare cadence runner. A known bounce is always suppressed; explicit tenant-configured
    /// addresses and opt-out CRM tags are also honored.
    static func isSuppressed(_ email: String, configured: [String], bounced: Bool, tags: [String]) -> Bool {
        let key = normalized(email)
        guard !key.isEmpty else { return true }
        if bounced || hasSuppressionTag(tags) { return true }
        return configured.contains { normalized($0) == key }
    }
}

enum SendPacing {
    /// Whole seconds until a mailbox may send again. Uses ceil so a positive sub-second remainder
    /// cannot be rounded down to an unsafe zero.
    static func secondsRemaining(lastSentAt: Date?, minimumSeconds: Int, now: Date) -> Int {
        guard minimumSeconds > 0, let lastSentAt else { return 0 }
        let remaining = Double(minimumSeconds) - now.timeIntervalSince(lastSentAt)
        return remaining > 0 ? Int(ceil(remaining)) : 0
    }
}

enum DeliveryCursor {
    /// A queue cursor may move only after the shared transport reports a landed/provider-accepted
    /// delivery. Preview, gate rejection, pacing, suppression, and transport failure all stay due.
    static func shouldAdvance(landed: Bool) -> Bool { landed }
}
