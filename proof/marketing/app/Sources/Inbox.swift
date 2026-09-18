// Black Label Marketing (lead engine, merged from Black Label Leads) — reply detection (inbox) model + matching logic.
//
// The website promises "automated reply and bounce detection." This is the real, in-house engine:
// a read-only IMAP poll of the buyer's OWN mailbox (see IMAPClient.swift) fetches recent message
// envelopes; this file turns those envelopes into `InboxMessage` records, MATCHES them to saved
// leads by sender address, classifies replies vs. auto-bounces, and folds the result back into
// the CRM (flips sendStatus → .replied / .bounced, logs the activity, auto-stops the sequence).
//
// Pure, deterministic, on-device. No fabricated data: a message exists only because the buyer's real
// mailbox returned it. Starts empty. No third-party SDK.
import Foundation

// MARK: - a fetched inbox message (envelope only — we never store full bodies, just enough to match)
struct InboxMessage: Identifiable, Codable, Hashable {
    var id: String                       // IMAP UID-scoped stable id: "<folder>:<uid>"
    var fromEmail: String = ""           // parsed sender address (lowercased)
    var fromName: String = ""
    var subject: String = ""
    var snippet: String = ""             // short text preview (first ~200 chars), if fetched
    var date: Date = Date()
    var matchedProspectID: UUID? = nil   // set when we matched it to a saved prospect
    var classification: Classification = .other
    var seen = false                     // has the buyer viewed it in the in-app Inbox?

    enum Classification: String, Codable, CaseIterable {
        case reply       // a human reply from a prospect we contacted
        case bounce      // a delivery-failure / mailer-daemon notice
        case autoReply   // out-of-office / vacation autoresponder
        case other       // unmatched / unrelated
        var label: String {
            switch self {
            case .reply: return "Reply"; case .bounce: return "Bounce"
            case .autoReply: return "Auto-reply"; case .other: return "Other"
            }
        }
        var icon: String {
            switch self {
            case .reply: return "arrowshape.turn.up.left.fill"
            case .bounce: return "exclamationmark.arrow.circlepath"
            case .autoReply: return "moon.zzz.fill"
            case .other: return "envelope"
            }
        }
    }

    // Resilient decode (older inbox JSON tolerates missing fields).
    init(id: String, fromEmail: String = "", fromName: String = "", subject: String = "",
         snippet: String = "", date: Date = Date(), matchedProspectID: UUID? = nil,
         classification: Classification = .other, seen: Bool = false) {
        self.id = id; self.fromEmail = fromEmail; self.fromName = fromName; self.subject = subject
        self.snippet = snippet; self.date = date; self.matchedProspectID = matchedProspectID
        self.classification = classification; self.seen = seen
    }
    enum CodingKeys: String, CodingKey {
        case id, fromEmail, fromName, subject, snippet, date, matchedProspectID, classification, seen
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        fromEmail = (try? c.decode(String.self, forKey: .fromEmail)) ?? ""
        fromName = (try? c.decode(String.self, forKey: .fromName)) ?? ""
        subject = (try? c.decode(String.self, forKey: .subject)) ?? ""
        snippet = (try? c.decode(String.self, forKey: .snippet)) ?? ""
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        matchedProspectID = try? c.decode(UUID.self, forKey: .matchedProspectID)
        classification = (try? c.decode(Classification.self, forKey: .classification)) ?? .other
        seen = (try? c.decode(Bool.self, forKey: .seen)) ?? false
    }
}

// MARK: - classification (deterministic, in-house) — bounce vs. autoreply vs. human reply
enum InboxClassifier {
    /// Mailer-daemon / delivery-status senders that indicate a BOUNCE rather than a real reply.
    static let bounceSenders: Set<String> = [
        "mailer-daemon", "postmaster", "mail-daemon", "mdaemon",
        "no-reply", "noreply", "bounce", "bounces"
    ]
    /// Subject fragments typical of a delivery failure.
    static let bouncePhrases = [
        "undeliverable", "delivery status notification", "delivery failure", "mail delivery failed",
        "returned mail", "failure notice", "undelivered mail returned", "address not found",
        "recipient address rejected", "message not delivered", "delivery has failed"
    ]
    /// Subject/snippet fragments typical of an auto-responder.
    static let autoReplyPhrases = [
        "out of office", "out-of-office", "automatic reply", "auto-reply", "autoreply",
        "vacation", "away from my", "currently away", "on leave", "i am currently out"
    ]

    /// Classify a message from its sender + subject (+ optional snippet). Deterministic.
    ///
    /// Auto-reply detection matches the SUBJECT ONLY — never the body snippet — because a genuine
    /// human reply that quotes "out of office" or says "I'm back from vacation, let's talk" must stay
    /// a `.reply` (demoting it to `.autoReply` would silently swallow the reply and keep the sequence
    /// sending). The subject is the reliable autoresponder signal ("Automatic reply: …").
    static func classify(fromEmail: String, fromName: String, subject: String, snippet: String = "") -> InboxMessage.Classification {
        let local = String(fromEmail.split(separator: "@").first ?? "").lowercased()
        let subj = subject.lowercased()
        let name = fromName.lowercased()

        // Bounce: from a daemon, OR subject screams delivery failure.
        if bounceSenders.contains(local) || name.contains("mail delivery") || name.contains("mailer-daemon") {
            return .bounce
        }
        if bouncePhrases.contains(where: { subj.contains($0) }) { return .bounce }

        // Auto-reply (out of office) — subject only; still a live mailbox, but not a human reply.
        if autoReplyPhrases.contains(where: { subj.contains($0) }) { return .autoReply }

        // Otherwise it's a human reply (the caller only matches it when the sender is a known prospect).
        return .reply
    }

    /// Parse "Display Name <addr@host>" or a bare address into (name, lowercased-email).
    static func parseAddress(_ raw: String) -> (name: String, email: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lt = s.firstIndex(of: "<"), let gt = s.firstIndex(of: ">"), lt < gt {
            let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces).lowercased()
            var name = String(s[s.startIndex..<lt]).trimmingCharacters(in: .whitespaces)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return (name, email)
        }
        return ("", s.lowercased())
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - folding fetched messages into the CRM (the part that updates real prospect state)
extension AppModel {
    /// Index of saved leads by lowercased email for O(1) sender→prospect matching.
    private func prospectIndexByEmail() -> [String: UUID] {
        var idx: [String: UUID] = [:]
        for p in leads where !p.email.isEmpty { idx[p.email.lowercased()] = p.id }
        return idx
    }

    /// Result of an inbox sync — honest counts the UI reports verbatim.
    struct InboxSyncResult: Equatable {
        var fetched = 0          // total envelopes considered
        var newMessages = 0      // not previously in the local inbox
        var matchedReplies = 0   // matched a contacted prospect AND classified as a human reply
        var matchedBounces = 0   // matched a prospect AND classified as a bounce
        var sequencesStopped = 0 // enrollments auto-stopped because of a reply/bounce
        var workflowsFired = 0   // automation rules that fired on these new replies/bounces
        // Prospects that just received their FIRST reply / bounce this poll (drives workflow triggers).
        var repliedProspectIDs: [UUID] = []
        var bouncedProspectIDs: [UUID] = []
    }

    /// Merge freshly-fetched envelopes into the local inbox and fold matches into prospect state.
    /// Idempotent: re-ingesting the same message id is a no-op for CRM side effects.
    @discardableResult
    func ingestInbox(_ fetched: [InboxMessage], now: Date = Date()) -> InboxSyncResult {
        var r = InboxSyncResult(); r.fetched = fetched.count
        let byEmail = prospectIndexByEmail()
        let existingIDs = Set(inbox.map { $0.id })

        for raw in fetched {
            var msg = raw
            let isNew = !existingIDs.contains(msg.id)

            // Match to a saved prospect by sender email.
            if msg.matchedProspectID == nil { msg.matchedProspectID = byEmail[msg.fromEmail.lowercased()] }

            // Upsert into the local inbox (preserve `seen` if it already existed).
            if let i = inbox.firstIndex(where: { $0.id == msg.id }) {
                let wasSeen = inbox[i].seen
                inbox[i] = msg; inbox[i].seen = wasSeen
            } else {
                inbox.insert(msg, at: 0)
                r.newMessages += 1
            }

            // CRM side effects fire ONCE, only for genuinely new + matched messages.
            guard isNew, let pid = msg.matchedProspectID,
                  let pi = leads.firstIndex(where: { $0.id == pid }) else { continue }

            switch msg.classification {
            case .reply:
                if leads[pi].sendStatus != .replied {
                    leads[pi].sendStatus = .replied
                    if leads[pi].status == .new || leads[pi].status == .contacted {
                        leads[pi].status = .replied
                    }
                    log(pid, .email_replied, "Reply: \(msg.subject)")
                    if stopOpenEnrollment(for: pid, reason: .stopped_reply) { r.sequencesStopped += 1 }
                    r.matchedReplies += 1
                    r.repliedProspectIDs.append(pid)
                }
            case .bounce:
                if leads[pi].sendStatus != .bounced && leads[pi].sendStatus != .replied {
                    leads[pi].sendStatus = .bounced
                    log(pid, .email_bounced, "Bounce: \(msg.subject)")
                    if stopOpenEnrollment(for: pid, reason: .stopped_bounce) { r.sequencesStopped += 1 }
                    r.matchedBounces += 1
                    r.bouncedProspectIDs.append(pid)
                }
            case .autoReply, .other:
                break   // a live mailbox, but not actionable — recorded in the inbox, no status change
            }
        }
        // Keep the local inbox bounded.
        if inbox.count > 2000 { inbox = Array(inbox.prefix(2000)) }
        return r
    }

    /// Stop the prospect's open sequence enrollment for the given reason. Returns true if one was stopped.
    @discardableResult
    private func stopOpenEnrollment(for prospectID: UUID, reason: Enrollment.Status) -> Bool {
        var stopped = false
        for i in enrollments.indices where enrollments[i].prospectID == prospectID && enrollments[i].status.isOpen {
            enrollments[i].status = reason; stopped = true
        }
        return stopped
    }

    // MARK: - inbox queries (real counts only)
    var unseenInboxCount: Int { inbox.filter { !$0.seen }.count }
    var replyInbox: [InboxMessage] { inbox.filter { $0.classification == .reply }.sorted { $0.date > $1.date } }
    func markInboxSeen(_ id: String) {
        if let i = inbox.firstIndex(where: { $0.id == id }) { inbox[i].seen = true }
    }
    func markAllInboxSeen() { for i in inbox.indices { inbox[i].seen = true } }
    func inboxMessages(for prospectID: UUID) -> [InboxMessage] {
        inbox.filter { $0.matchedProspectID == prospectID }.sorted { $0.date > $1.date }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - inbox sync coordinator (config + Keychain → IMAP fetch → classify → ingest)
struct InboxSyncResultUI {
    var ok: Bool
    var message: String                     // honest, human-readable outcome
    var result: AppModel.InboxSyncResult?   // nil when the run failed before fetching
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum InboxSync {
    /// Build the IMAP config from the buyer's settings + Keychain. IMAP password is looked up by the
    /// IMAP username; if none is stored there, falls back to the SMTP mailbox password (same mailbox).
    static func config(from settings: LeadEngineSettings) -> IMAPConfig? {
        guard settings.imapEnabled else { return nil }
        let host = settings.imapHost.trimmingCharacters(in: .whitespaces)
        let user = settings.imapUsername.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty, !user.isEmpty else { return nil }
        let pw = SendKeychain.password(account: user)
            ?? SendKeychain.password(account: settings.mailbox.username) ?? ""
        return IMAPConfig(host: host, port: UInt16(settings.imapPort), username: user, password: pw)
    }

    /// Run a full reply-detection poll on the MainActor's model. Pure-failure honest: returns the
    /// real reason if anything goes wrong; never invents results.
    @MainActor
    static func run(model: AppModel, settings: LeadEngineSettings) async -> InboxSyncResultUI {
        guard settings.imapEnabled else {
            return InboxSyncResultUI(ok: false, message: "Reply detection is off. Turn it on in Connectors → Inbox.", result: nil)
        }
        guard let cfg = config(from: settings) else {
            return InboxSyncResultUI(ok: false, message: "Add your IMAP host, username, and app password in Connectors → Inbox.", result: nil)
        }
        guard cfg.isConfigured else {
            return InboxSyncResultUI(ok: false, message: "No app password saved for your inbox mailbox — add it in Connectors → Inbox.", result: nil)
        }
        do {
            let raw = try await IMAPClient(config: cfg).fetchRecent()
            // Classify every fetched envelope (deterministic, in-house).
            let classified = raw.map { msg -> InboxMessage in
                var m = msg
                m.classification = InboxClassifier.classify(fromEmail: m.fromEmail, fromName: m.fromName,
                                                            subject: m.subject, snippet: m.snippet)
                return m
            }
            var r = model.ingestInbox(classified)
            // Fire automation rules on the leads that just replied/bounced (real events, real stages).
            for pid in r.repliedProspectIDs { r.workflowsFired += model.runWorkflows(trigger: .replyReceived, prospectID: pid, stages: settings.stages) }
            for pid in r.bouncedProspectIDs { r.workflowsFired += model.runWorkflows(trigger: .bounceReceived, prospectID: pid, stages: settings.stages) }
            let summary = "Checked \(r.fetched) recent message\(r.fetched == 1 ? "" : "s") · "
                + "\(r.matchedReplies) repl\(r.matchedReplies == 1 ? "y" : "ies"), \(r.matchedBounces) bounce\(r.matchedBounces == 1 ? "" : "s") matched"
                + (r.sequencesStopped > 0 ? " · \(r.sequencesStopped) sequence\(r.sequencesStopped == 1 ? "" : "s") auto-stopped" : "")
                + "."
            return InboxSyncResultUI(ok: true, message: summary, result: r)
        } catch let e as IMAPError {
            return InboxSyncResultUI(ok: false, message: e.errorDescription ?? "Inbox check failed.", result: nil)
        } catch {
            return InboxSyncResultUI(ok: false, message: error.localizedDescription, result: nil)
        }
    }
}
#endif // circuit-convert
