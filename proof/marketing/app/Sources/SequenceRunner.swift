#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing (lead engine, merged from Black Label Leads) — sequence runner. Processes DUE enrollments: renders the next step's template,
// runs the deliverability + CAN-SPAM gate, picks a sending mailbox (rotation, warmup caps), delivers
// over the real SMTP path (Outreach.swift), logs the send, advances the schedule, and auto-stops on
// reply/bounce. Honest: it sends nothing the gate rejects, and every count it produces is real.
import Foundation

struct RunReport {
    var processed = 0          // enrollments examined as due
    var sent = 0               // SMTP-accepted sends
    var blocked = 0            // gate/transport-blocked (not sent)
    var skipped = 0            // capped / no mailbox / not due
    var stopped = 0            // auto-stopped this run (reply/bounce/completed)
    var messages: [String] = []
}

@MainActor
enum SequenceRunner {
    /// Process all enrollments due now. `dryRun` renders + gates but never opens a socket — used by the
    /// preview/"check" button and tests. Real runs deliver over SMTP and update the model.
    static func runDue(model: AppModel, settings: LeadEngineSettings, dryRun: Bool = false, now: Date = Date()) async -> RunReport {
        var report = RunReport()
        let pool = settings.allMailboxes
        guard !pool.isEmpty else {
            report.messages.append("No configured sending mailbox — set one up in Connectors → Mailboxes.")
            return report
        }

        // Snapshot due enrollments (active + nextDue <= now), oldest first.
        let due = model.enrollments.enumerated()
            .filter { $0.element.status.isOpen && $0.element.nextDue <= now }
            .sorted { $0.element.nextDue < $1.element.nextDue }

        for (_, enr) in due {
            report.processed += 1
            guard let eIdx = model.enrollments.firstIndex(where: { $0.id == enr.id }) else { continue }
            guard let p = model.prospect(enr.prospectID) else {
                model.enrollments[eIdx].status = .failed; continue
            }
            guard let seq = model.sequence(enr.sequenceID), seq.active else {
                model.enrollments[eIdx].status = .stopped_manual; continue
            }

            // Auto-stop on reply/bounce BEFORE sending the next step.
            if seq.stopOnReply && p.sendStatus == .replied {
                model.enrollments[eIdx].status = .stopped_reply; report.stopped += 1; continue
            }
            if seq.stopOnBounce && p.sendStatus == .bounced {
                model.enrollments[eIdx].status = .stopped_bounce; report.stopped += 1; continue
            }

            let enabledSteps = seq.steps.enumerated().filter { $0.element.enabled }
            guard model.enrollments[eIdx].stepIndex < enabledSteps.count else {
                model.enrollments[eIdx].status = .completed; report.stopped += 1; continue
            }
            let step = enabledSteps[model.enrollments[eIdx].stepIndex].element

            // Choose a mailbox: the enrollment's pinned one if still valid+under cap, else first under cap.
            let chosen = pickMailbox(pool: pool, prefer: enr.mailboxID, model: model)
            guard let mailbox = chosen else {
                report.skipped += 1
                report.messages.append("\(p.displayName): all mailboxes hit their daily cap — will retry.")
                continue
            }

            // Render (subject A/B + templated body). The deliverability gate, mailbox rotation,
            // warmup ledger, SMTP transport, and demo simulation all live in OutboundMailer — the
            // ONE send path shared with journeys. `pickMailbox` above only pre-checks capacity so
            // we can honestly report "all capped"; OutboundMailer re-picks and records the send.
            let (subjectText, arm) = step.subject(for: p.id, salt: model.enrollments[eIdx].stepIndex)
            let subject = TemplateEngine.render(subjectText, prospect: p, mailbox: mailbox, bookingLink: settings.bookingLink)
            let body = TemplateEngine.body(for: p, template: OutreachTemplate(subject: subjectText, body: step.body),
                                           mailbox: mailbox, bookingLink: settings.bookingLink)

            if dryRun {
                report.sent += 1
                report.messages.append("\(p.displayName): would send step \(model.enrollments[eIdx].stepIndex + 1) (arm \(arm)) — \"\(subject)\"")
                continue   // never mutate the model in a dry run
            }

            let result = await OutboundMailer.send(to: p.email, subject: subject, body: body,
                                                   model: model, settings: settings,
                                                   preferMailbox: mailbox.id, now: now)
            let stepIdx = model.enrollments[eIdx].stepIndex
            model.enrollments[eIdx].sends.append(StepSend(stepIndex: stepIdx, at: now,
                                                          subjectArm: arm, sent: result.sent, detail: result.detail))
            if DeliveryCursor.shouldAdvance(landed: result.sent) {
                report.sent += 1
                let suffix = result.simulated ? " — simulated" : ""
                model.log(p.id, .email_sent, "Step \(stepIdx + 1) of \(seq.name) (arm \(arm))\(suffix)")
                if let pi = model.leads.firstIndex(where: { $0.id == p.id }) {
                    model.leads[pi].lastSent = now
                    if model.leads[pi].status == .new { model.leads[pi].status = .contacted }
                    if model.leads[pi].sendStatus == .notSent { model.leads[pi].sendStatus = .sent }
                }
                if result.simulated { report.messages.append("\(p.displayName): step \(stepIdx + 1) simulated (demo).") }
                advance(model: model, eIdx: eIdx, seq: seq, enabledSteps: enabledSteps, now: now, report: &report)
            } else {
                report.blocked += 1
                report.messages.append("\(p.displayName): \(result.detail)")
            }
        }
        return report
    }

    /// Pick a sending mailbox under its daily cap. Prefers the pinned one; rotates to the least-used otherwise.
    private static func pickMailbox(pool: [Mailbox], prefer: UUID?, model: AppModel) -> Mailbox? {
        func underCap(_ m: Mailbox) -> Bool { model.sentToday(mailboxID: m.id) < max(1, m.dailyCap) }
        if let pid = prefer, let m = pool.first(where: { $0.id == pid }), underCap(m) { return m }
        // Least-used-today mailbox that's still under its cap (even rotation).
        return pool.filter(underCap).min { model.sentToday(mailboxID: $0.id) < model.sentToday(mailboxID: $1.id) }
    }

    /// Advance the enrollment to the next enabled step (or complete it) and schedule nextDue.
    private static func advance(model: AppModel, eIdx: Int, seq: OutreachSequence,
                                enabledSteps: [(offset: Int, element: SequenceStep)], now: Date, report: inout RunReport) {
        let next = model.enrollments[eIdx].stepIndex + 1
        if next >= enabledSteps.count {
            model.enrollments[eIdx].stepIndex = next
            model.enrollments[eIdx].status = .completed
            report.stopped += 1
        } else {
            model.enrollments[eIdx].stepIndex = next
            let delay = enabledSteps[next].element.delayDays
            model.enrollments[eIdx].nextDue = Calendar.current.date(byAdding: .day, value: delay, to: now) ?? now
        }
    }

    /// Count of enrollments eligible to run right now.
    static func dueCount(model: AppModel, now: Date = Date()) -> Int {
        model.enrollments.filter { $0.status.isOpen && $0.nextDue <= now }.count
    }
}
#endif // circuit-convert
