#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — the live newsletter cadence runner (AppModel-coupled).
//
// Kept separate from CloudflareEmail.swift so that file's pure send/config/due logic stays unit-
// testable in isolation. This is the one place that reads the buyer's own newsletters + contacts and
// drives the Cloudflare send path automatically (see MainView's .task) or on demand.
import Foundation

extension NewsletterDispatch {
    /// Run every due newsletter through Cloudflare, marking each sent (lastSentAt) only on success.
    /// Honest by construction: if Cloudflare isn't configured, or there are no recipients, nothing is
    /// marked sent and the reason is reported. Never touches a socket in demo mode.
    @MainActor
    static func runDue(model: AppModel, settings: LeadEngineSettings, now: Date = Date()) async -> Report {
        var report = Report()
        let dueList = due(model.newsletters, now: now)
        guard !dueList.isEmpty else { return report }

        guard !DemoMode.active else {
            report.messages.append("Demo mode — \(dueList.count) newsletter\(dueList.count == 1 ? "" : "s") would send via Cloudflare. No real email sent.")
            return report
        }
        let endpoint = CloudflareEmailConfig.endpoint
        let fromEmail = CloudflareEmailConfig.fromEmail
        guard let token = CloudflareEmailConfig.token,
              CloudflareEmailConfig.isConfigured(endpoint: endpoint, fromEmail: fromEmail, hasToken: true) else {
            report.messages.append("Cloudflare newsletter sending isn't configured — set it up in Connectors → Newsletters (Cloudflare).")
            return report
        }
        let compatibility = await CloudflareMailer.verifyCompatibility(endpoint: endpoint, token: token)
        guard compatibility.ok else {
            report.messages.append(compatibility.detail)
            return report
        }
        var suppressed = Set(settings.suppressedEmails.map(EmailSuppression.normalized))
        for lead in model.leads where EmailSuppression.isSuppressed(
            lead.email, configured: settings.suppressedEmails,
            bounced: lead.sendStatus == .bounced, tags: lead.tags
        ) {
            suppressed.insert(EmailSuppression.normalized(lead.email))
        }
        let currentList = recipients(from: model.allContacts, suppressed: suppressed)
        let fromName = CloudflareEmailConfig.fromName

        for n in dueList {
            report.attempted += 1
            var updated = n
            var progress = n.deliveryProgress ?? NewsletterDeliveryProgress(
                recipients: currentList,
                deliveryID: NewsletterDeliveryProgress.stableDeliveryID(newsletterID: n.id, lastSentAt: n.lastSentAt),
                startedAt: now
            )
            progress.markSuppressed(suppressed)
            guard !progress.recipients.isEmpty else {
                report.failed += 1
                report.messages.append("\(n.subject.isEmpty ? n.name : n.subject): no unsuppressed contacts with a valid email.")
                continue
            }
            if progress.isComplete {
                updated.lastSentAt = now
                updated.deliveryProgress = nil
                model.upsertNewsletter(updated)
                report.sent += 1
                report.messages.append("\(n.subject.isEmpty ? n.name : n.subject): delivery already complete (\(progress.completedCount) sent · \(progress.suppressedCount) suppressed).")
                continue
            }
            let chunk = Array(progress.retryableRecipients.prefix(CloudflareMailer.maxRecipientsPerRequest))
            let payload = CloudflareMailer.Payload(
                from: fromEmail, fromName: fromName.isEmpty ? n.name : fromName,
                subject: n.subject, text: n.body, html: CloudflareMailer.htmlWrap(n.body),
                recipients: chunk, deliveryID: progress.deliveryID)
            let r = await CloudflareMailer.send(endpoint: endpoint, token: token, payload: payload)
            progress.apply(r, attempted: chunk)
            updated.deliveryProgress = progress
            if progress.isComplete {
                report.sent += 1
                updated.lastSentAt = now
                updated.deliveryProgress = nil
                report.messages.append("\(n.subject.isEmpty ? n.name : n.subject): complete — \(progress.completedCount) sent · \(progress.suppressedCount) suppressed.")
            } else {
                if !r.ok { report.failed += 1 }
                report.messages.append("\(n.subject.isEmpty ? n.name : n.subject): \(progress.completedCount)/\(progress.recipients.count) sent · \(progress.remainingCount) remain. \(r.detail)")
            }
            // Persist after every bounded chunk. If the app closes, the next cadence tick resumes
            // only failed/pending recipients with the same Worker idempotency key.
            model.upsertNewsletter(updated)
        }
        return report
    }
}
#endif // circuit-convert
