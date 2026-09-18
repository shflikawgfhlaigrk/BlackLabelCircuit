// Black Label Real Estate — OUTREACH AUTOMATION: direct-mail multi-touch sequences + BYO
// dialer/SMS/RVM provider gate + 10DLC registration step.
//
// Two honest builds here, both real on the buyer's own data and channels:
//
//  1) DIRECT-MAIL MULTI-TOUCH SEQUENCES — PropStream's postcards are one-and-done; the deals
//     close on touch 5–7. This builds a real, scheduled multi-touch cadence: a sequence of mail
//     pieces (postcard / yellow-letter / typed letter) with day-offsets, each merged with the
//     lead's real fields. The app generates the merged pieces + a dated mail-drop schedule the
//     buyer runs through their own mail house. It never claims to physically mail — it produces
//     the real artifacts + the calendar, and tracks which touches are done.
//
//  2) DIALER / SMS / RINGLESS VOICEMAIL — phone outreach requires a carrier (Twilio, etc.) and
//     10DLC-registered messaging; the product never fabricates a send. It ships the real config
//     UI + an honest gate: connect YOUR provider key (stored in the Keychain, never bundled) and
//     complete 10DLC brand/campaign registration before SMS can run. Until then the channel shows
//     exactly what's missing — same honest pattern as skip trace's phone tier.
import Foundation

// MARK: ===================== DIRECT-MAIL MULTI-TOUCH SEQUENCES =====================

enum MailPieceKind: String, Codable, CaseIterable, Identifiable {
    case postcard, yellowLetter, typedLetter
    var id: String { rawValue }
    var label: String { switch self { case .postcard: return "Postcard"; case .yellowLetter: return "Yellow letter"; case .typedLetter: return "Typed letter" } }
    var icon: String { switch self { case .postcard: return "rectangle.fill"; case .yellowLetter: return "doc.plaintext.fill"; case .typedLetter: return "doc.text.fill" } }
}

// One touch in a sequence: a piece, a day-offset from enrollment, and a merge template.
struct MailTouch: Identifiable, Codable, Hashable {
    var id = UUID()
    var dayOffset: Int = 0          // days after enrollment this piece drops
    var kind: MailPieceKind = .postcard
    var template: String = ""        // body with {{name}} {{property}} {{county}} {{owner}} tokens
}

// A reusable multi-touch direct-mail cadence (e.g. "Probate 5-touch").
struct MailSequence: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var touches: [MailTouch] = []
    var created = Date()
    var touchCount: Int { touches.count }
    var spanDays: Int { (touches.map { $0.dayOffset }.max() ?? 0) }
}

// A lead enrolled in a sequence, with per-touch completion (real, persisted progress).
struct MailEnrollment: Identifiable, Codable, Hashable {
    var id = UUID()
    var leadID: UUID
    var sequenceID: UUID
    var enrolledOn = Date()
    var completedTouchIDs: Set<UUID> = []
}

// A single scheduled, fully-merged mail piece ready to run (the artifact + its drop date).
struct ScheduledMailPiece: Hashable, Identifiable {
    var id: UUID                     // the touch id
    var enrollmentID: UUID           // owning enrollment — lets the UI mark a piece dropped
    var dropDate: Date
    var kind: MailPieceKind
    var merged: String               // the lead-merged body
    var done: Bool
    var leadName: String
}

struct MailDropExportRow: Hashable, Identifiable {
    var id: String { "\(enrollmentID.uuidString)-\(touchID.uuidString)" }
    var enrollmentID: UUID
    var touchID: UUID
    var leadID: UUID
    var dropDate: Date
    var sequenceName: String
    var touchLabel: String
    var pieceKind: MailPieceKind
    var leadName: String
    var ownerName: String
    var mailingAddress: String
    var propertyAddress: String
    var county: String
    var body: String
    var blockers: [String]
    var ready: Bool { blockers.isEmpty }
    var status: String { ready ? "READY" : "NEEDS_REVIEW" }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct MailDropExportPacket: Hashable {
    var rows: [MailDropExportRow]
    var readyCount: Int { rows.filter(\.ready).count }
    var reviewCount: Int { rows.count - readyCount }

    var csv: String {
        let header = [
            "Drop Date", "Status", "Review Notes", "Lead Name", "Owner Name",
            "Mailing Address", "Property Address", "County", "Sequence",
            "Touch", "Piece Kind", "Body"
        ]
        var out = [header.map(MailDropExport.csvEscape).joined(separator: ",")]
        for row in rows {
            let cols = [
                MailDropExport.dateString(row.dropDate),
                row.status,
                row.blockers.joined(separator: "; "),
                row.leadName,
                row.ownerName,
                row.mailingAddress,
                row.propertyAddress,
                row.county,
                row.sequenceName,
                row.touchLabel,
                row.pieceKind.label,
                row.body
            ]
            out.append(cols.map(MailDropExport.csvEscape).joined(separator: ","))
        }
        return out.joined(separator: "\n")
    }

    var textPacket: String {
        var parts = [
            "BLACK LABEL REAL ESTATE - DIRECT MAIL DROP PACKET",
            "Ready: \(readyCount)",
            "Needs review: \(reviewCount)",
            "Total due: \(rows.count)"
        ]
        for row in rows {
            parts.append("""

            ---
            \(row.status) | \(MailDropExport.dateString(row.dropDate)) | \(row.pieceKind.label) | \(row.leadName)
            Sequence: \(row.sequenceName) / \(row.touchLabel)
            Mailing: \(row.mailingAddress.isEmpty ? "[missing mailing address]" : row.mailingAddress)
            Property: \(row.propertyAddress.isEmpty ? "[missing property address]" : row.propertyAddress)
            County: \(row.county.isEmpty ? "[county]" : row.county)
            Review: \(row.blockers.isEmpty ? "none" : row.blockers.joined(separator: "; "))

            \(row.body)
            """)
        }
        return parts.joined(separator: "\n")
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum MailDropExport {
    static func build(enrollments: [MailEnrollment], sequences: [MailSequence], leads: [Lead],
                      asOf: Date = Date()) -> MailDropExportPacket {
        let sequencesByID = Dictionary(uniqueKeysWithValues: sequences.map { ($0.id, $0) })
        let leadsByID = Dictionary(uniqueKeysWithValues: leads.map { ($0.id, $0) })
        var rows: [MailDropExportRow] = []

        for enrollment in enrollments {
            guard let sequence = sequencesByID[enrollment.sequenceID],
                  let lead = leadsByID[enrollment.leadID] else { continue }
            for piece in MailMerge.due(MailMerge.schedule(enrollment, sequence: sequence, lead: lead), asOf: asOf) {
                rows.append(MailDropExportRow(
                    enrollmentID: enrollment.id,
                    touchID: piece.id,
                    leadID: lead.id,
                    dropDate: piece.dropDate,
                    sequenceName: sequence.name.isEmpty ? "Untitled sequence" : sequence.name,
                    touchLabel: "Day \(sequence.touches.first(where: { $0.id == piece.id })?.dayOffset ?? 0)",
                    pieceKind: piece.kind,
                    leadName: lead.name.isEmpty ? "Unnamed lead" : lead.name,
                    ownerName: lead.ownerName.isEmpty ? lead.name : lead.ownerName,
                    mailingAddress: lead.mailingAddress,
                    propertyAddress: lead.propertyAddress,
                    county: lead.county,
                    body: piece.merged,
                    blockers: blockers(for: lead, body: piece.merged)
                ))
            }
        }

        rows.sort {
            if $0.dropDate == $1.dropDate { return $0.leadName < $1.leadName }
            return $0.dropDate < $1.dropDate
        }
        return MailDropExportPacket(rows: rows)
    }

    static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func csvEscape(_ value: String) -> String {
        (value.contains(",") || value.contains("\"") || value.contains("\n"))
            ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : value
    }

    private static func blockers(for lead: Lead, body: String) -> [String] {
        var out: [String] = []
        if lead.mailingAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("missing mailing address")
        }
        if body.contains("[") && body.contains("]") {
            out.append("unresolved merge/sender placeholder")
        }
        return out
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum MailMerge {
    /// Merge a template with a lead's REAL fields. Missing field → an honest bracket placeholder,
    /// never a fabricated value (so the buyer sees what to fill before the piece goes out).
    static func merge(_ template: String, lead l: Lead) -> String {
        let map: [String: String] = [
            "{{name}}": l.name.isEmpty ? "[owner name]" : l.name,
            "{{owner}}": l.ownerName.isEmpty ? (l.name.isEmpty ? "[owner]" : l.name) : l.ownerName,
            "{{property}}": l.propertyAddress.isEmpty ? "[property address]" : l.propertyAddress,
            "{{mailing}}": l.mailingAddress.isEmpty ? "[mailing address]" : l.mailingAddress,
            "{{county}}": l.county.isEmpty ? "[county]" : l.county,
        ]
        var out = template
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out
    }

    /// Build the dated, merged drop schedule for one enrollment (the real mail calendar).
    static func schedule(_ enr: MailEnrollment, sequence: MailSequence, lead: Lead) -> [ScheduledMailPiece] {
        let cal = Calendar.current
        return sequence.touches.sorted { $0.dayOffset < $1.dayOffset }.map { t in
            let drop = cal.date(byAdding: .day, value: t.dayOffset, to: enr.enrolledOn) ?? enr.enrolledOn
            return ScheduledMailPiece(id: t.id, enrollmentID: enr.id, dropDate: drop, kind: t.kind,
                                      merged: merge(t.template, lead: lead),
                                      done: enr.completedTouchIDs.contains(t.id), leadName: lead.name)
        }
    }

    /// Pieces due on/before `asOf` that aren't done yet — the buyer's "mail to drop now" queue.
    static func due(_ schedule: [ScheduledMailPiece], asOf: Date = Date()) -> [ScheduledMailPiece] {
        schedule.filter { !$0.done && $0.dropDate <= asOf }
    }
}
#endif // circuit-convert

// Starter sequences (templates, not data) the buyer can clone + edit. Real merge tokens.
enum MailSequenceTemplates {
    static var all: [MailSequence] {
        [
            MailSequence(name: "Probate 5-touch", touches: [
                MailTouch(dayOffset: 0,  kind: .postcard,    template: "Hello {{name}} — I'm a local cash buyer interested in {{property}} in {{county}} County. No fees, no repairs, close on your timeline. — [your name], [your phone]"),
                MailTouch(dayOffset: 14, kind: .yellowLetter, template: "{{name}}, following up on {{property}}. I buy as-is for cash and can handle the estate process. Call me anytime. — [your name]"),
                MailTouch(dayOffset: 30, kind: .typedLetter,  template: "Dear {{owner}}, regarding the property at {{property}} — I'd like to make you a fair cash offer with a flexible close. — [your name], [your phone]"),
                MailTouch(dayOffset: 50, kind: .postcard,     template: "{{name}} — still interested in {{property}}. Cash, as-is, you pick the date. — [your name]"),
                MailTouch(dayOffset: 75, kind: .yellowLetter, template: "Last note, {{name}} — my cash offer on {{property}} stands. A quick call is all it takes. — [your name], [your phone]"),
            ]),
            MailSequence(name: "Absentee 3-touch", touches: [
                MailTouch(dayOffset: 0,  kind: .postcard,    template: "{{name}}, I'd like to buy your property at {{property}}. Cash, as-is, no agent fees. — [your name], [your phone]"),
                MailTouch(dayOffset: 21, kind: .yellowLetter, template: "{{name}} — following up on {{property}} in {{county}} County. I can close fast and handle everything remotely. — [your name]"),
                MailTouch(dayOffset: 45, kind: .typedLetter,  template: "Dear {{owner}}, my cash offer for {{property}} still stands. Tired of managing it from afar? Let's talk. — [your name], [your phone]"),
            ]),
        ]
    }
}

// MARK: ===================== DIALER / SMS / RVM — BYO PROVIDER GATE =====================

enum PhoneChannelKind: String, Codable, CaseIterable, Identifiable {
    case dialer, sms, rvm
    var id: String { rawValue }
    var label: String { switch self { case .dialer: return "Power dialer"; case .sms: return "2-way SMS"; case .rvm: return "Ringless voicemail" } }
    var icon: String { switch self { case .dialer: return "phone.arrow.up.right.fill"; case .sms: return "bubble.left.and.bubble.right.fill"; case .rvm: return "recordingtape" } }
    /// SMS additionally requires 10DLC registration in the US; calls/RVM need only a carrier.
    var needs10DLC: Bool { self == .sms }
}

// 10DLC brand/campaign registration state (US A2P messaging). Tracked, never faked.
struct TenDLCRegistration: Codable, Hashable {
    var brandRegistered = false
    var campaignRegistered = false
    var brandName: String = ""
    var ein: String = ""            // business EIN used for the brand (stored locally only)
    var useCase: String = "Real-estate lead follow-up"
    var complete: Bool { brandRegistered && campaignRegistered }
}

// The buyer's own telephony provider config. The engine stores ONLY whether a key is present
// (the key text lives in the Keychain via the caller), never the secret itself.
struct PhoneProvider: Codable, Hashable {
    var name: String = ""            // "Twilio", "Telnyx", etc.
    var apiKeyPresent = false
    var fromNumber: String = ""      // the buyer's own provisioned number
    var tenDLC = TenDLCRegistration()
    var connected: Bool { apiKeyPresent && !name.isEmpty && !fromNumber.isEmpty }
}

// What a channel needs before it can run — the honest gate the UI renders.
struct ChannelReadiness: Hashable {
    var kind: PhoneChannelKind
    var ready: Bool
    var blockers: [String]           // exactly what's missing (empty when ready)
}

enum PhoneOutreach {
    /// Does a real call/SMS/RVM TRANSPORT ship in this build? Provider config + 10DLC are
    /// buyer-typed paperwork and two self-attested toggles — neither dials a number nor hands a
    /// message to a carrier. Verified 2026-08-03 on this worktree:
    ///   grep -rniE "twilio|telnyx|api\.twilio|Messages\.json|Calls\.json" Sources/*.swift
    ///     → only a prose comment; no endpoint, no request builder
    ///   grep -n "URLSession" Sources/OutreachEngine.swift Sources/OutreachScreens.swift → no hits
    ///   `canSend` has exactly two callers (the send-PREVIEW presenter and EngineTests) — neither
    ///   performs I/O, so nothing this app runs can place a call or send a text.
    /// RE-18 / ⛔H4 require the texting path to be consent-gated OR disabled, and disabled must LOOK
    /// disabled — so the UI reads `sendState(_:provider:)`, NEVER `readiness().ready`, before it is
    /// allowed to say anything sendable. Flip this to true in the SAME commit that lands the
    /// provider HTTP client (the way MailSend.send already throws unless the vendor returns a real
    /// letter id) — never before, and never to make a screen look finished.
    static let transportShipped = false

    /// The one sentence the UI shows in place of a fabricated "Ready".
    static let transportNotEnabledReason =
        "Sending is not enabled in this build — no call/SMS transport ships yet."

    /// What the provider panel is allowed to say about saved credentials. Saving them performs NO
    /// handshake with the carrier — there is no request builder to perform one (see the grep
    /// evidence above) — so the UI must never call the provider "connected" or the key "verified".
    static let providerStorageOnlyNote =
        "This panel only RECORDS your provider details and 10DLC paperwork on this device. It performs no handshake with your carrier and does not verify your API key. " + transportNotEnabledReason

    /// What the UI is permitted to SAY about a channel. Provider-configured is deliberately its own
    /// case: it is not "Ready", because nothing can leave the app.
    enum ChannelSendState: Hashable {
        case gated([String])           // provider / 10DLC prerequisites still missing
        case configuredNoTransport     // paperwork complete, but this build has no transport
        case sendable                  // only reachable once `transportShipped` is true

        /// Pill text. Never "Ready" unless a send could actually happen.
        var pillText: String {
            switch self {
            case .gated: return "Gated"
            case .configuredNoTransport: return "Provider configured — sending not enabled"
            case .sendable: return "Ready"
            }
        }
    }

    /// Compose provider readiness with the transport truth. This is what the Dialer screen renders.
    static func sendState(_ kind: PhoneChannelKind, provider: PhoneProvider) -> ChannelSendState {
        let r = readiness(kind, provider: provider)
        if !r.ready { return .gated(r.blockers) }
        return transportShipped ? .sendable : .configuredNoTransport
    }

    /// Evaluate PROVIDER readiness for one channel — never returns ready unless EVERY real
    /// precondition is met (provider key, from-number, and for SMS, completed 10DLC). No fabricated
    /// "ready". NOTE: provider-ready ≠ able to send; that is `sendState(_:provider:)`.
    static func readiness(_ kind: PhoneChannelKind, provider: PhoneProvider) -> ChannelReadiness {
        var blockers: [String] = []
        if provider.name.isEmpty { blockers.append("Choose a telephony provider (e.g. Twilio).") }
        if !provider.apiKeyPresent { blockers.append("Add your provider API key (stored in your Keychain).") }
        if provider.fromNumber.isEmpty { blockers.append("Set your provisioned from-number.") }
        if kind.needs10DLC {
            if !provider.tenDLC.brandRegistered { blockers.append("Register your 10DLC brand (A2P).") }
            if !provider.tenDLC.campaignRegistered { blockers.append("Register your 10DLC campaign.") }
        }
        return ChannelReadiness(kind: kind, ready: blockers.isEmpty, blockers: blockers)
    }

    /// The COMPLIANCE verdict for one recipient: permitted only when the channel is provider-ready
    /// AND it passes the same gate every other channel uses (TCPA window + suppression + consent).
    /// This answers "would this contact be lawful", NOT "can this build send" — the transport check
    /// lives in `sendState(_:provider:)` and must be applied by every caller that shows a verdict
    /// to the buyer (OutreachPreviewPresenter.channelSendPreview does).
    static func canSend(_ kind: PhoneChannelKind, to phone: String, provider: PhoneProvider,
                        suppression: Suppression, consent: ContactConsent = .none,
                        now: Date = Date()) -> (ok: Bool, reasons: [String]) {
        let r = readiness(kind, provider: provider)
        if !r.ready { return (false, r.blockers) }
        let channel: ContactChannel = (kind == .sms) ? .sms : .call
        // RE-18: the SMS path additionally requires prior express written consent (TCPA); dialer/RVM
        // are live-call channels gated by the window + suppression only.
        let c = ComplianceEngine.check(channel: channel, phone: phone, email: "",
                                       suppression: suppression, consent: consent, now: now)
        return (c.allowed, c.allowed ? [] : c.reasons)
    }
}
