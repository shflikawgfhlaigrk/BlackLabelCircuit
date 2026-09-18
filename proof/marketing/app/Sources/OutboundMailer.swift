#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — the ONE outbound email transport (2026-07 Leads merge).
//
// Every real send in the app — cold-outreach sequences (SequenceRunner), journey sends,
// and one-off spotlight/compose — funnels through this actor so there is a single place
// that: runs the in-house deliverability + CAN-SPAM gate, picks a warmup-capped mailbox
// from the rotation, delivers over the buyer's OWN mailbox via the real SMTP path
// (Outreach.swift's SMTPClient), and records the send in the per-mailbox daily ledger.
//
// Honest by construction: a send the gate rejects, or that has no configured mailbox /
// app-password, is reported as blocked — never logged as delivered. In demo mode nothing
// touches a socket; the result is clearly marked simulated.
import Foundation

struct MailerResult {
    var sent: Bool
    var detail: String
    var mailboxID: UUID?
    var simulated: Bool = false
}

@MainActor
enum OutboundMailer {
    /// Configuration fields are not credentials. This is the single runtime truth used by both the
    /// newsletter UI and the delivery path: SMTP needs a readable Keychain secret; OAuth needs the
    /// provider token; disabled mailboxes never qualify.
    static func sendReadyMailboxes(_ settings: LeadEngineSettings) -> [Mailbox] {
        settings.allMailboxes.filter { mailbox in
            guard mailbox.enabled else { return false }
            if let provider = mailbox.authKind.provider {
                return EmailTokenStore.hasToken(provider: provider, address: mailbox.fromEmail)
            }
            let account = mailbox.username.trimmingCharacters(in: .whitespacesAndNewlines)
            return !account.isEmpty && SendKeychain.hasReadablePassword(account: account)
        }
    }

    /// Deliver one email to `address` using the shared gate + rotation + SMTP transport.
    /// `preferMailbox` pins a sending identity when the caller has one (e.g. a sequence
    /// enrollment); otherwise the least-used mailbox still under its daily cap is chosen.
    static func send(to address: String, subject: String, body: String,
                     model: AppModel, settings: LeadEngineSettings,
                     preferMailbox: UUID? = nil, extraHeaders: [(name: String, value: String)] = [],
                     now: Date = Date()) async -> MailerResult {
        let normalized = EmailSuppression.normalized(address)
        let lead = model.leads.first { EmailSuppression.normalized($0.email) == normalized }
        if EmailSuppression.isSuppressed(address, configured: settings.suppressedEmails,
                                         bounced: lead?.sendStatus == .bounced, tags: lead?.tags ?? []) {
            return MailerResult(sent: false, detail: "Suppressed — this address is on the buyer's do-not-email list or has bounced.", mailboxID: nil)
        }

        let credentialed = sendReadyMailboxes(settings)
        guard !credentialed.isEmpty else {
            return MailerResult(sent: false,
                                detail: "No enabled mailbox has a readable password or OAuth token — reconnect one in Connectors → Mailboxes.",
                                mailboxID: nil)
        }
        let underCap = credentialed.filter { model.sentToday(mailboxID: $0.id) < max(1, $0.dailyCap) }
        guard !underCap.isEmpty else {
            return MailerResult(sent: false, detail: "All mailboxes hit their daily cap — will retry.", mailboxID: nil)
        }
        let paced = underCap.filter {
            SendPacing.secondsRemaining(lastSentAt: model.lastSentAt(mailboxID: $0.id),
                                        minimumSeconds: settings.minSecondsBetweenSends, now: now) == 0
        }
        guard let mailbox = pickMailbox(pool: paced, prefer: preferMailbox, model: model) else {
            let wait = underCap.map {
                SendPacing.secondsRemaining(lastSentAt: model.lastSentAt(mailboxID: $0.id),
                                            minimumSeconds: settings.minSecondsBetweenSends, now: now)
            }.filter { $0 > 0 }.min() ?? max(1, settings.minSecondsBetweenSends)
            return MailerResult(sent: false,
                                detail: "Pacing — retry in \(wait) second\(wait == 1 ? "" : "s").",
                                mailboxID: nil)
        }

        // Demo mode: simulate exactly as an accepted send, no socket, no live DNS.
        if DemoMode.active {
            model.recordSend(mailboxID: mailbox.id, at: now)
            return MailerResult(sent: true, detail: "Simulated send (demo) — no real email sent",
                                mailboxID: mailbox.id, simulated: true)
        }

        var gateSettings = settings; gateSettings.mailbox = mailbox
        let gate = await Deliverability.gate(email: address, settings: gateSettings)
        guard gate.canSend else {
            return MailerResult(sent: false, detail: "Held: " + gate.reasons.joined(separator: "; "), mailboxID: mailbox.id)
        }

        // Real provider-API lane: a mailbox the buyer connected via OAuth sends over Gmail API /
        // Microsoft Graph with their own token — never SMTP, never an app-password. Honest failure
        // (missing/expired token, non-2xx) is reported as blocked, never logged as delivered.
        if mailbox.usesProviderAPI {
            let r = await EmailAPISender.send(mailbox: mailbox, to: address, subject: subject, body: body,
                                              extraHeaders: extraHeaders)
            if r.ok { model.recordSend(mailboxID: mailbox.id, at: now) }
            return MailerResult(sent: r.ok, detail: r.detail, mailboxID: mailbox.id)
        }

        let pw = SendKeychain.password(account: mailbox.username) ?? ""
        guard !pw.isEmpty else {
            return MailerResult(sent: false, detail: "No app password for \(mailbox.fromEmail)", mailboxID: mailbox.id)
        }
        do {
            try await SMTPClient(mailbox: mailbox, password: pw).send(to: address, subject: subject, body: body,
                                                                       extraHeaders: extraHeaders)
            model.recordSend(mailboxID: mailbox.id, at: now)
            return MailerResult(sent: true, detail: "Sent from \(mailbox.fromEmail)", mailboxID: mailbox.id)
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return MailerResult(sent: false, detail: detail, mailboxID: mailbox.id)
        }
    }

    /// Pick from an already credential/cap/pacing-filtered pool. Prefers the pinned one; otherwise
    /// rotates to the least-used mailbox.
    private static func pickMailbox(pool: [Mailbox], prefer: UUID?, model: AppModel) -> Mailbox? {
        if let pid = prefer, let m = pool.first(where: { $0.id == pid }) { return m }
        return pool.min { model.sentToday(mailboxID: $0.id) < model.sentToday(mailboxID: $1.id) }
    }
}

// MARK: - Journey delivery over the shared transport
//
// The visual Journey builder (segments → waits → email sends) shares the exact same real
// send path as cold-outreach sequences: JourneyExecutor.tick computes what is DUE, and this
// bridge delivers each due send through OutboundMailer, rendering the journey's email
// campaign body per contact. Result: one automation engine, one transport, one warmup ledger.
@MainActor
extension JourneyExecutor {
    struct JourneyRunReport {
        var due = 0
        var sent = 0
        var blocked = 0
        var messages: [String] = []
    }

    /// Advance every enrolled journey run to `now` and actually deliver the due emails over
    /// the shared SMTP transport (the buyer's own mailbox). Persists advanced runs + send
    /// ledger on `model`. `dryRun` renders + gates but opens no socket (preview/tests).
    static func runDue(model: AppModel, settings: LeadEngineSettings, dryRun: Bool = false, now: Date = Date()) async -> JourneyRunReport {
        var report = JourneyRunReport()
        if !dryRun { _ = model.enrollJourneyContacts(now: now) }
        let senderLabel: (UUID) -> String = { jid in
            model.journeys.first { $0.id == jid }?.name ?? "Journey"
        }
        let (due, normalizedRuns) = tick(journeys: model.journeys, runs: model.journeyRuns, now: now,
                                         dailyCap: settings.dailySendCap, senderLabel: senderLabel)
        if !dryRun, normalizedRuns != model.journeyRuns { model.journeyRuns = normalizedRuns }
        report.due = due.count
        for d in due {
            let campaign = model.campaigns.first { $0.name == d.campaignName }
            let subject = campaign?.subject.isEmpty == false ? campaign!.subject : d.campaignName
            let body = (campaign?.blocks ?? []).map { block -> String in
                switch block.kind {
                case .button: return block.text.isEmpty ? block.url : "\(block.text): \(block.url)"
                default:      return block.text
                }
            }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            if dryRun {
                report.sent += 1
                report.messages.append("\(d.contactEmail): would send \"\(subject)\" from \(d.senderLabel)")
                continue
            }
            let r = await OutboundMailer.send(to: d.contactEmail, subject: subject, body: body,
                                              model: model, settings: settings, now: now)
            if DeliveryCursor.shouldAdvance(landed: r.sent) {
                var runs = model.journeyRuns
                if markLanded(d, runs: &runs, at: now) { model.journeyRuns = runs }
                report.sent += 1
                report.messages.append("\(d.contactEmail): \(r.detail)")
            } else {
                report.blocked += 1
                report.messages.append("\(d.contactEmail): \(r.detail)")
            }
        }
        return report
    }
}
#endif // circuit-convert
