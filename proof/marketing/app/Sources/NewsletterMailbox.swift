// Black Label Marketing — NON-DEVELOPER newsletter send over the buyer's OWN mailbox.
//
// The gap this closes: the original newsletter path only sent through a Cloudflare Worker the buyer
// had to deploy with `wrangler` — a hard wall for a non-technical owner. This file is the honest,
// zero-config alternative: a newsletter goes out over the SAME mailbox the buyer already connected
// for outreach (Connectors → Mailboxes), through the SAME warmup-capped rotation + deliverability
// gate + per-mailbox daily ledger (OutboundMailer). No Worker, no wrangler, no shared secret.
//
// Compliance is built in, not bolted on:
//   • CAN-SPAM: every message carries the sender identity + a physical postal address + a plain-text
//     unsubscribe line in the body (a real footer, appended here — never assumed).
//   • RFC 8058 / one-click: a `List-Unsubscribe` (+ `List-Unsubscribe-Post`) header rides on the SMTP
//     and Gmail-API lanes so Gmail/Apple Mail show a native "Unsubscribe" button.
//   • Warmup caps: the send never exceeds the buyer's combined daily mailbox capacity — recipients
//     beyond today's capacity are DEFERRED (honestly reported), never silently dropped or blasted.
//   • Honest results: the caller sees a per-recipient outcome (sent / failed-with-reason / deferred);
//     a newsletter only advances its cadence when at least one real send succeeded.
//
// Everything here is PURE (no I/O, no SwiftUI, no AppModel) except `run`, which takes an injected
// `deliver` closure — so the compose/header/capacity/loop logic is unit-tested with a transport fake.
import Foundation

// MARK: - per-recipient outcome (honest; never a blanket "sent")

struct NewsletterRecipientOutcome: Hashable {
    enum State: String { case sent, failed, deferred }
    var email: String
    var state: State
    var detail: String
}

struct NewsletterSendReport {
    var results: [NewsletterRecipientOutcome] = []
    var sent: Int { results.filter { $0.state == .sent }.count }
    var failed: Int { results.filter { $0.state == .failed }.count }
    var deferred: Int { results.filter { $0.state == .deferred }.count }
    var anyDelivered: Bool { sent > 0 }
    func isComplete(expected: Int) -> Bool {
        expected > 0 && sent == expected && failed == 0 && deferred == 0
    }
    /// One-line human summary for the UI.
    var summary: String {
        var parts = ["\(sent) sent"]
        if failed > 0 { parts.append("\(failed) failed") }
        if deferred > 0 { parts.append("\(deferred) deferred (over today's cap)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - capacity planning (for the recipient-count confirm sheet)

/// The warmup capacity of one mailbox today = its daily cap minus what it already sent, floored at 0.
struct MailboxCapacity: Hashable {
    var dailyCap: Int
    var sentToday: Int
    var enabled: Bool
    var remaining: Int { enabled ? max(0, dailyCap - sentToday) : 0 }
}

struct NewsletterPlan: Hashable {
    var recipientCount: Int
    var capacityToday: Int
    /// How many go out in this run (min of recipients and capacity).
    var willSend: Int { min(recipientCount, capacityToday) }
    /// How many are deferred to a later day because the warmup cap is reached.
    var willDefer: Int { max(0, recipientCount - capacityToday) }
    var fitsInOneDay: Bool { recipientCount <= capacityToday }
}

enum NewsletterMailbox {
    /// Total sendable recipients today across the buyer's enabled mailboxes (sum of each one's
    /// remaining warmup headroom). Pure so the confirm sheet and the runner agree exactly.
    static func remainingCapacityToday(_ mailboxes: [MailboxCapacity]) -> Int {
        mailboxes.reduce(0) { $0 + $1.remaining }
    }

    static func plan(recipientCount: Int, mailboxes: [MailboxCapacity]) -> NewsletterPlan {
        NewsletterPlan(recipientCount: max(0, recipientCount),
                       capacityToday: remainingCapacityToday(mailboxes))
    }

    // MARK: readiness — honest blockers shown BEFORE the confirm sheet (never a dead "Send" button).
    static func readiness(mailboxCount: Int, recipientCount: Int, hasFromIdentity: Bool,
                          hasPhysicalAddress: Bool) -> [String] {
        var blockers: [String] = []
        if mailboxCount == 0 { blockers.append("Connect a sending mailbox in Connectors → Mailboxes.") }
        if recipientCount == 0 { blockers.append("No contacts with a valid email yet — add your list first.") }
        if !hasFromIdentity { blockers.append("Add a from name/email to your mailbox in Connectors → Mailboxes.") }
        if !hasPhysicalAddress { blockers.append("Add your physical mailing address (CAN-SPAM) in Connectors → Mailboxes.") }
        return blockers
    }

    // MARK: CAN-SPAM footer (appended to the body — a real footer, never assumed present)

    /// The compliant footer: sender identity · postal address, then a plain-text unsubscribe line.
    /// `unsubscribe` is a mailto:/https line the recipient can act on even with no header support.
    static func footer(fromName: String, fromEmail: String, physicalAddress: String, unsubscribe: String) -> String {
        let identity = [fromName, fromEmail, physicalAddress].map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " · ")
        var lines: [String] = []
        if !identity.isEmpty { lines.append(identity) }
        let unsub = unsubscribe.trimmingCharacters(in: .whitespaces)
        if !unsub.isEmpty { lines.append("Unsubscribe: \(unsub)") }
        lines.append("You're receiving this because you're on \(fromName.isEmpty ? "our" : "\(fromName)'s") list. This is a commercial message.")
        return lines.joined(separator: "\n")
    }

    /// Append the CAN-SPAM footer to the newsletter body (idempotent: if the same physical address is
    /// already present, the buyer wrote their own footer and we don't double it).
    static func composeBody(_ body: String, fromName: String, fromEmail: String,
                            physicalAddress: String, unsubscribe: String) -> String {
        let base = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let addr = physicalAddress.trimmingCharacters(in: .whitespaces)
        if !addr.isEmpty && base.contains(addr) { return base }
        let f = footer(fromName: fromName, fromEmail: fromEmail, physicalAddress: physicalAddress, unsubscribe: unsubscribe)
        return base.isEmpty ? f : base + "\n\n—\n" + f
    }

    // MARK: List-Unsubscribe headers (RFC 2369 / RFC 8058 one-click)

    /// Build the `List-Unsubscribe` (+ `List-Unsubscribe-Post`) header pair. A `mailto:` is always
    /// included when a from-email exists (every provider honors it); an https one-click URL is added
    /// when the buyer configured one. Returns [] when nothing valid can be built (no fake header).
    static func listUnsubscribeHeaders(mailtoEmail: String, oneClickURL: String?) -> [(name: String, value: String)] {
        var targets: [String] = []
        let mail = mailtoEmail.trimmingCharacters(in: .whitespaces)
        if mail.contains("@") { targets.append("<mailto:\(mail)?subject=unsubscribe>") }
        var hasHTTPS = false
        if let raw = oneClickURL?.trimmingCharacters(in: .whitespaces), let u = URL(string: raw),
           u.scheme?.lowercased() == "https" {
            targets.append("<\(raw)>"); hasHTTPS = true
        }
        guard !targets.isEmpty else { return [] }
        var headers: [(name: String, value: String)] = [("List-Unsubscribe", targets.joined(separator: ", "))]
        // One-click POST is only meaningful with an https endpoint (RFC 8058).
        if hasHTTPS { headers.append(("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")) }
        return headers
    }

    // MARK: the send loop (honest, cap-respecting). `deliver` is the injected transport.

    /// Send `recipients` one at a time via `deliver`, stopping real attempts once `capacity` is used
    /// and marking every remaining recipient DEFERRED (honest — not failed, not silently dropped). A
    /// `deliver` that returns ok=false records a per-recipient FAILURE with the provider's reason.
    static func run(recipients: [String], capacity: Int,
                    deliver: (String) async -> (ok: Bool, detail: String)) async -> NewsletterSendReport {
        var report = NewsletterSendReport()
        var used = 0
        for email in recipients {
            if used >= capacity {
                report.results.append(.init(email: email, state: .deferred,
                                            detail: "Deferred — today's warmup cap reached; will go out on the next run."))
                continue
            }
            used += 1
            let r = await deliver(email)
            report.results.append(.init(email: email, state: r.ok ? .sent : .failed, detail: r.detail))
        }
        return report
    }
}
