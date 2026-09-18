// Black Label Marketing — the ONE outbound messaging transport (iMessage / RCS / SMS via Sendblue).
//
// Exactly the shape of `OutboundMailer` for email: every real text in the app funnels through this
// actor so there is a single place that:
//   • runs the TCPA gate (consent + STOP opt-out + do-not-contact + 8am–9pm quiet hours) —
//     `MessagingGate.block` in Sendblue.swift, the same pure rule the tests execute;
//   • respects the buyer's per-line daily ledger;
//   • marks a send `simulated` when no Sendblue credential is connected or the app is in demo mode,
//     rather than reporting a delivery that never happened;
//   • records the message on-device and writes a real Activity on the lead's timeline.
//
// SHIP-EMPTY: no numbers, no threads, no consent records ship in the bundle. The store below starts
// as an empty file that does not exist until the buyer sends or records something.
//
// HONEST BY CONSTRUCTION: a blocked send is reported blocked; an accepted send reports the status
// Sendblue actually returned (ACCEPTED/SENT/…), never "Delivered" unless Sendblue said DELIVERED.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - the on-device message record

enum MessageDirection: String, Codable, CaseIterable {
    case outbound, inbound
}

/// One text the buyer sent or received, stored on this device only.
struct StoredMessage: Identifiable, Codable, Hashable {
    var id = UUID()
    var prospectID: UUID? = nil          // the lead this thread belongs to, when known
    var number: String = ""              // the OTHER party, E.164 (thread key)
    var lineNumber: String = ""          // the buyer's sending line, E.164 ("" = account default)
    var direction: MessageDirection = .outbound
    var body: String = ""
    var at = Date()
    var service: SendblueService? = nil  // nil until Sendblue tells us
    var status: SendblueMessageStatus? = nil
    var messageHandle: String = ""       // Apple GUID, when returned
    /// True when nothing left this machine (no credential connected, or demo mode).
    var simulated: Bool = false
    /// Truthful outcome text (accepted / blocked reason / API error).
    var detail: String = ""
    /// Set when the gate refused. A blocked row is kept so the buyer can see WHY nothing went out.
    var blockedReason: String = ""
    /// The provider was reached and did NOT accept this message (non-2xx, ERROR/DECLINED, or a 2xx
    /// with no status at all). Distinct from `blockedReason`, which means we never called out.
    var failed: Bool = false

    /// The ONLY affirmative claim. A simulated, blocked, or provider-refused row is never "sent".
    var wasSent: Bool { blockedReason.isEmpty && !simulated && !failed }

    init(id: UUID = UUID(), prospectID: UUID? = nil, number: String = "", lineNumber: String = "",
         direction: MessageDirection = .outbound, body: String = "", at: Date = Date(),
         service: SendblueService? = nil, status: SendblueMessageStatus? = nil,
         messageHandle: String = "", simulated: Bool = false, detail: String = "",
         blockedReason: String = "", failed: Bool = false) {
        self.id = id; self.prospectID = prospectID; self.number = number; self.lineNumber = lineNumber
        self.direction = direction; self.body = body; self.at = at
        self.service = service; self.status = status; self.messageHandle = messageHandle
        self.simulated = simulated; self.detail = detail; self.blockedReason = blockedReason
        self.failed = failed
    }

    // Resilient decode (same posture as Lead): a record written by an earlier build, or one missing
    // a field added later, still loads instead of dropping the buyer's whole message history.
    enum CodingKeys: String, CodingKey {
        case id, prospectID, number, lineNumber, direction, body, at
        case service, status, messageHandle, simulated, detail, blockedReason, failed
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        prospectID = try? c.decode(UUID.self, forKey: .prospectID)
        number = (try? c.decode(String.self, forKey: .number)) ?? ""
        lineNumber = (try? c.decode(String.self, forKey: .lineNumber)) ?? ""
        direction = (try? c.decode(MessageDirection.self, forKey: .direction)) ?? .outbound
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        at = (try? c.decode(Date.self, forKey: .at)) ?? Date()
        service = try? c.decode(SendblueService.self, forKey: .service)
        status = try? c.decode(SendblueMessageStatus.self, forKey: .status)
        messageHandle = (try? c.decode(String.self, forKey: .messageHandle)) ?? ""
        simulated = (try? c.decode(Bool.self, forKey: .simulated)) ?? false
        detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
        blockedReason = (try? c.decode(String.self, forKey: .blockedReason)) ?? ""
        failed = (try? c.decode(Bool.self, forKey: .failed)) ?? false
    }
}

/// Consent + suppression + ledger state for messaging, persisted next to the other on-device stores.
/// Deliberately NOT part of AppModel's workspace snapshot: it is device/line state, and consent must
/// survive independently of a workspace restore rather than being silently overwritten by one.
enum MessageStore {
    struct State: Codable, Equatable {
        var messages: [StoredMessage] = []
        /// Numbers that sent STOP (or the buyer marked opted-out). E.164 keys.
        var optedOut: [String] = []
        /// Numbers with recorded prior express consent. E.164 keys.
        var consented: [String] = []
        /// Do-not-contact numbers the buyer added by hand.
        var suppressed: [String] = []
        /// Per-line daily send ledger: ["<line>|yyyy-MM-dd": count]. "" line = account default.
        var lineLedger: [String: Int] = [:]
    }

    static func fileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Messages.json")
    }

    static func load() -> State {
        guard let data = try? Data(contentsOf: fileURL()),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return s
    }

    static func save(_ state: State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL(), options: .atomic)
    }

    // MARK: pure helpers (executed by the tests, not re-implemented by them)

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func ledgerKey(line: String, at: Date = Date()) -> String { "\(line)|\(dayKey(at))" }

    static func contains(_ list: [String], _ number: String) -> Bool {
        let key = PhoneNumber.key(number)
        return list.contains { PhoneNumber.key($0) == key }
    }

    /// The consent/suppression facts for one number, plus today's line count — exactly what
    /// `MessagingGate.block` needs.
    static func facts(for number: String, line: String, state: State, at: Date = Date()) -> MessageConsentFacts {
        MessageConsentFacts(hasConsent: contains(state.consented, number),
                            optedOut: contains(state.optedOut, number),
                            suppressed: contains(state.suppressed, number),
                            sentOnLineToday: state.lineLedger[ledgerKey(line: line, at: at)] ?? 0,
                            dailyLineCap: SendblueConfig.dailyLineCap)
    }

    // MARK: mutations

    static func record(_ message: StoredMessage) {
        var s = load()
        s.messages.insert(message, at: 0)
        if s.messages.count > 5000 { s.messages = Array(s.messages.prefix(5000)) }
        save(s)
    }

    static func countSend(line: String, at: Date = Date()) {
        var s = load()
        let key = ledgerKey(line: line, at: at)
        s.lineLedger[key] = (s.lineLedger[key] ?? 0) + 1
        save(s)
    }

    static func setConsent(_ granted: Bool, for number: String) {
        guard let e164 = PhoneNumber.e164(number) else { return }
        var s = load()
        s.consented.removeAll { PhoneNumber.key($0) == PhoneNumber.key(e164) }
        if granted { s.consented.append(e164) }
        save(s)
    }

    static func setOptedOut(_ optedOut: Bool, for number: String) {
        guard let e164 = PhoneNumber.e164(number) else { return }
        var s = load()
        s.optedOut.removeAll { PhoneNumber.key($0) == PhoneNumber.key(e164) }
        if optedOut { s.optedOut.append(e164) }
        save(s)
    }

    static func setSuppressed(_ suppressed: Bool, for number: String) {
        guard let e164 = PhoneNumber.e164(number) else { return }
        var s = load()
        s.suppressed.removeAll { PhoneNumber.key($0) == PhoneNumber.key(e164) }
        if suppressed { s.suppressed.append(e164) }
        save(s)
    }

    /// Newest-first thread for one number.
    static func thread(_ number: String, in state: State) -> [StoredMessage] {
        let key = PhoneNumber.key(number)
        return state.messages.filter { PhoneNumber.key($0.number) == key }
    }

    /// Distinct thread keys, newest activity first.
    static func threads(in state: State) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for m in state.messages {
            let key = PhoneNumber.key(m.number)
            if seen.insert(key).inserted { out.append(m.number) }
        }
        return out
    }
}

// MARK: - the send chokepoint

struct MessagingResult {
    var sent: Bool
    var detail: String
    var simulated: Bool = false
    var blocked: MessageBlockReason? = nil
    var service: SendblueService? = nil
    var status: SendblueMessageStatus? = nil
    var messageHandle: String = ""
    var stored: StoredMessage? = nil
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
enum MessagingSender {

    /// Deliver ONE text. Mirrors `OutboundMailer.send`: gate → ledger → transport → record → log.
    ///
    /// `model` is optional so the headless CLI path can send without a workspace; when present the
    /// send lands on the lead's real activity timeline.
    static func send(to number: String, body: String,
                     model: AppModel? = nil, prospectID: UUID? = nil,
                     sendStyle: SendblueSendStyle? = nil, mediaURL: String = "",
                     now: Date = Date(), enforceQuietHours: Bool = true) async -> MessagingResult {

        let line = SendblueConfig.fromNumber
        var state = MessageStore.load()
        let facts = MessageStore.facts(for: number, line: line, state: state, at: now)

        // 1) The gate. One rule, one place — the same pure function the safety suite executes.
        if let reason = MessagingGate.block(number: number, body: body, facts: facts,
                                            now: now, enforceQuietHours: enforceQuietHours) {
            let record = StoredMessage(prospectID: prospectID,
                                       number: PhoneNumber.e164(number) ?? number,
                                       lineNumber: line, direction: .outbound, body: body, at: now,
                                       detail: reason.detail, blockedReason: reason.rawValue)
            state.messages.insert(record, at: 0)
            MessageStore.save(state)
            if let model, let pid = prospectID {
                model.log(pid, .message_blocked, reason.detail)
            }
            return MessagingResult(sent: false, detail: reason.detail, blocked: reason, stored: record)
        }

        let recipient = PhoneNumber.e164(number)!   // the gate proved this parses

        // 2) Unconfigured or demo → SIMULATED. No socket, no fabricated delivery, clearly labelled.
        if DemoMode.active || !SendblueConfig.isConfigured {
            let why = DemoMode.active
                ? "Simulated (demo mode) — no text was sent."
                : "Simulated — connect your own Sendblue account in Connectors → Messaging to send for real. Nothing was sent."
            let record = StoredMessage(prospectID: prospectID, number: recipient, lineNumber: line,
                                       direction: .outbound, body: body, at: now,
                                       simulated: true, detail: why)
            state.messages.insert(record, at: 0)
            MessageStore.save(state)
            if let model, let pid = prospectID { model.log(pid, .message_sent, why) }
            return MessagingResult(sent: false, detail: why, simulated: true, stored: record)
        }

        // 3) Transmission consent. The TCPA gate above protects the RECIPIENT; this protects the
        // BUYER: the message body, the recipient's number and the Sendblue credential are about to
        // leave this Mac for a third party, so an explicit, current, per-provider grant must be on
        // file. No grant → nothing is sent, and the refusal is recorded on the thread rather than
        // silently dropped. (See Sources/ProviderConsent.swift.)
        if let refusal = TransmissionConsentStore.refusal(for: .sendblue) {
            let record = StoredMessage(prospectID: prospectID, number: recipient, lineNumber: line,
                                       direction: .outbound, body: body, at: now,
                                       detail: refusal, blockedReason: "providerConsent")
            state.messages.insert(record, at: 0)
            MessageStore.save(state)
            if let model, let pid = prospectID { model.log(pid, .message_blocked, refusal) }
            return MessagingResult(sent: false, detail: refusal, stored: record)
        }

        // 4) Real send over the buyer's own Sendblue account.
        guard let credential = SendblueConfig.credential else {
            let detail = "Your saved Sendblue credential could not be read from the Keychain — reconnect it in Connectors → Messaging. Nothing was sent."
            return MessagingResult(sent: false, detail: detail)
        }
        let payload = SendbluePayload(number: recipient, fromNumber: line, content: body,
                                      mediaURL: mediaURL, sendStyle: sendStyle,
                                      statusCallback: SendblueConfig.statusCallback)
        guard let request = SendblueAPI.sendMessageRequest(base: SendblueConfig.baseURL,
                                                           keyID: credential.keyID, secret: credential.secret,
                                                           payload: payload) else {
            let detail = "The request could not be built for \(recipient) — nothing was sent."
            return MessagingResult(sent: false, detail: detail)
        }

        let outcome: SendblueSendResult
        do {
            // Through the choke point (Sources/ConsentedEgress.swift), which re-consults the gate
            // itself. Step 3 above is the buyer-facing message for the refusal; this is the wall.
            let (data, response) = try await ConsentedEgress.send(request, to: .sendblue)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            outcome = SendblueAPI.parseSendResponse(statusCode: code, data: data)
        } catch {
            let detail = "Sendblue could not be reached: \(error.localizedDescription). Nothing was sent."
            return MessagingResult(sent: false, detail: detail)
        }

        let record = StoredMessage(prospectID: prospectID, number: recipient, lineNumber: line,
                                   direction: .outbound, body: body, at: now,
                                   service: outcome.service, status: outcome.status,
                                   messageHandle: outcome.messageHandle,
                                   simulated: false,
                                   detail: outcome.detail,
                                   // Not `blockedReason`: the gate cleared this and we DID call out.
                                   // The provider refused (or answered unintelligibly), which is a
                                   // different truth and must never read as sent.
                                   failed: !outcome.ok)
        state.messages.insert(record, at: 0)
        if outcome.ok {
            let key = MessageStore.ledgerKey(line: line, at: now)
            state.lineLedger[key] = (state.lineLedger[key] ?? 0) + 1
        }
        MessageStore.save(state)

        if let model, let pid = prospectID {
            let label = [outcome.service?.label, outcome.status?.label].compactMap { $0 }.joined(separator: " · ")
            model.log(pid, outcome.ok ? .message_sent : .message_blocked,
                      label.isEmpty ? outcome.detail : "\(label) — \(outcome.detail)")
        }
        return MessagingResult(sent: outcome.ok, detail: outcome.detail, simulated: false,
                               service: outcome.service, status: outcome.status,
                               messageHandle: outcome.messageHandle, stored: record)
    }

    /// Record an INBOUND message (webhook relay / manual log). Honors Sendblue's built-in STOP
    /// detection locally: a STOP body flips the number to opted-out immediately, and a START
    /// clears it — so the very next send through this chokepoint is blocked (or unblocked).
    @discardableResult
    static func receive(from number: String, body: String, service: SendblueService? = nil,
                        messageHandle: String = "", model: AppModel? = nil, prospectID: UUID? = nil,
                        at: Date = Date()) -> StoredMessage {
        let normalized = PhoneNumber.e164(number) ?? number
        var state = MessageStore.load()
        let record = StoredMessage(prospectID: prospectID, number: normalized,
                                   lineNumber: SendblueConfig.fromNumber, direction: .inbound,
                                   body: body, at: at, service: service, messageHandle: messageHandle,
                                   detail: "Received")
        state.messages.insert(record, at: 0)
        if SendblueOptOut.isOptOut(body) {
            if !MessageStore.contains(state.optedOut, normalized) { state.optedOut.append(normalized) }
            state.consented.removeAll { PhoneNumber.key($0) == PhoneNumber.key(normalized) }
        } else if SendblueOptOut.isOptIn(body) {
            state.optedOut.removeAll { PhoneNumber.key($0) == PhoneNumber.key(normalized) }
        }
        MessageStore.save(state)
        if let model, let pid = prospectID {
            model.log(pid, .message_received, SendblueOptOut.isOptOut(body) ? "STOP — opted out, further texts blocked" : body)
        }
        return record
    }

    /// Live iMessage-capability check for one number, over the buyer's own credential.
    /// Returns an honest not-connected evaluation rather than guessing a service.
    static func evaluateService(_ number: String) async -> SendblueServiceEvaluation {
        guard let e164 = PhoneNumber.e164(number) else {
            return SendblueServiceEvaluation(ok: false, number: number, service: nil,
                                             detail: "Not a dialable number.")
        }
        // A capability check still ships the lead's phone number to Sendblue, so it needs the same
        // recorded transmission consent the send does.
        if let refusal = TransmissionConsentStore.refusal(for: .sendblue) {
            return SendblueServiceEvaluation(ok: false, number: e164, service: nil, detail: refusal)
        }
        guard let credential = SendblueConfig.credential else {
            return SendblueServiceEvaluation(ok: false, number: e164, service: nil,
                                             detail: "Not connected — add your own Sendblue key in Connectors → Messaging to check whether this number has iMessage.")
        }
        guard let request = SendblueAPI.evaluateServiceRequest(base: SendblueConfig.baseURL,
                                                               keyID: credential.keyID,
                                                               secret: credential.secret, number: e164) else {
            return SendblueServiceEvaluation(ok: false, number: e164, service: nil, detail: "Could not build the request.")
        }
        do {
            let (data, response) = try await ConsentedEgress.send(request, to: .sendblue)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return SendblueAPI.parseEvaluateService(statusCode: code, data: data)
        } catch {
            return SendblueServiceEvaluation(ok: false, number: e164, service: nil,
                                             detail: "Sendblue could not be reached: \(error.localizedDescription)")
        }
    }

    /// The credential probe behind the Connectors card. Green ONLY after a real authenticated 2xx.
    ///
    /// This probe ships the buyer's Sendblue key id and secret to Sendblue, so it is a transmission
    /// like any other and goes through the same choke point. A buyer who has not yet allowed
    /// Sendblue under Connectors → Data sharing gets the refusal text back instead of a probe — the
    /// allow control and this button live on the same screen.
    static func verifyCredential(keyID: String, secret: String,
                                 base: String = SendblueConfig.baseURL) async -> (ok: Bool, detail: String) {
        guard let request = SendblueAPI.linesRequest(base: base, keyID: keyID, secret: secret) else {
            return (false, "Enter both the API key id and the secret.")
        }
        do {
            let (data, response) = try await ConsentedEgress.send(request, to: .sendblue)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return SendblueAPI.probeDetail(statusCode: code, data: data)
        } catch let refusal as ConsentedEgressError {
            return (false, refusal.errorDescription ?? "Nothing was sent.")
        } catch {
            return (false, "Sendblue could not be reached: \(error.localizedDescription)")
        }
    }
}
#endif // circuit-convert
