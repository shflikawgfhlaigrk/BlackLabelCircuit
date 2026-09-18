// Black Label Real Estate — OUTREACH COMPLIANCE ENGINE (TCPA / DNC / opt-out).
//
// Real, free, on-device legal-safety logic — the thing every paid RE-investor outreach tool
// gates sends behind, and the single feature category most competitors' clones forget:
//   • TCPA calling/texting window — no contact before 8:00am or after 9:00pm in the
//     RECIPIENT's local time (statutory federal window; some states are stricter). Per-recipient
//     timezone is inferred from the area code / state, never assumed to be the sender's clock.
//   • DNC suppression — the buyer's own internal Do-Not-Contact list (numbers/emails the
//     owner asked not to be contacted, plus anyone who texted STOP). A hard pre-send gate.
//   • STOP / opt-out capture — record an opt-out so the lead is permanently suppressed.
//
// HONESTY: this engine never claims to scrub against the *federal* National DNC Registry
// (that requires a paid SAN subscription) — it gates on the buyer's OWN suppression list and
// the statutory time window, and says so. No fabricated "compliant ✓" when it can't verify.
import Foundation

// MARK: - Channel a contact attempt uses (windows differ; email has no TCPA window).
enum ContactChannel: String, Codable, CaseIterable, Identifiable {
    case call, sms, email, mail
    var id: String { rawValue }
    var label: String { switch self { case .call: return "Call"; case .sms: return "Text"; case .email: return "Email"; case .mail: return "Direct mail" } }
    /// TCPA time-window applies to live calls + texts; email/physical mail are exempt.
    var hasTimeWindow: Bool { self == .call || self == .sms }
}

// MARK: - Timezone inference from a US phone area code (no network; honest fallback).
// Maps the common area codes to an IANA tz. Unknown → nil (caller treats unknown as "can't
// verify the local time" and flags rather than silently allowing).
enum USPhoneZone {
    /// Digits only; returns the 3-digit area code when the number is a plausible US number.
    static func areaCode(_ phone: String) -> String? {
        let d = phone.filter(\.isNumber)
        let core = (d.count == 11 && d.first == "1") ? String(d.dropFirst()) : d
        guard core.count == 10 else { return nil }
        return String(core.prefix(3))
    }

    // Area code → UTC offset bucket (standard time); DST handled by Calendar/TimeZone below.
    // A pragmatic, free, on-device table covering the bulk of US area codes by region.
    private static let zoneByArea: [String: String] = {
        var m: [String: String] = [:]
        let eastern = ["201","202","203","207","212","215","216","240","267","301","302","305","321","339","347","351","386","401","404","407","410","412","413","434","443","470","475","478","484","508","513","516","517","518","540","551","561","570","571","585","603","607","610","614","616","617","631","646","678","703","704","716","717","718","724","727","732","734","740","754","757","762","770","772","774","781","786","802","803","804","810","813","814","843","845","848","850","856","857","860","862","863","864","865","878","901","904","908","912","914","917","919","929","937","941","947","954","959","970x"]
        let central = ["205","210","214","217","224","225","228","251","254","256","262","270","281","309","312","314","316","318","319","320","325","330","331","334","337","361","380","402","405","409","414","417","430","432","435","440","458","469","479","501","504","507","512","515","563","573","580","601","605","608","612","618","620","630","636","641","651","660","662","682","701","708","712","713","715","731","737","763","769","773","779","785","806","815","816","817","830","832","847","870","901c","903","913","915","918","920","936","940","952","956","972","979","985"]
        let mountain = ["303","307","385","406","435m","480","505","520","575","602","623","719","720","801","915m","928","970"]
        let pacific = ["206","209","213","253","279","310","323","341","360","408","415","424","442","458p","503","510","530","541","559","562","619","626","628","650","657","661","669","707","714","747","760","805","818","820","831","858","909","916","925","949","951","971"]
        let alaska = ["907"]; let hawaii = ["808"]
        for a in eastern { m[String(a.prefix(3))] = "America/New_York" }
        for a in central { m[String(a.prefix(3))] = "America/Chicago" }
        for a in mountain { m[String(a.prefix(3))] = "America/Denver" }
        for a in pacific { m[String(a.prefix(3))] = "America/Los_Angeles" }
        for a in alaska { m[a] = "America/Anchorage" }
        for a in hawaii { m[a] = "Pacific/Honolulu" }
        return m
    }()

    static func timeZone(forPhone phone: String) -> TimeZone? {
        guard let ac = areaCode(phone), let id = zoneByArea[ac] else { return nil }
        return TimeZone(identifier: id)
    }
}

// MARK: - Prior-express-written-consent state (RE-18). Under the TCPA a one-tap cold TEXT (and an
// autodialed/prerecorded call) to a residential/wireless number requires PRIOR EXPRESS WRITTEN
// consent — a signed opt-in on file. We never fake it: absent a recorded written opt-in the texting
// path is HARD-blocked, and the buyer is nudged to a call or mailer (which don't require it) or to
// capture consent first. Tracked per lead, never assumed.
enum ContactConsent: String, Codable, Hashable, CaseIterable {
    case none                  // no recorded consent
    case priorExpressWritten   // signed written opt-in on file (TCPA-compliant for texting)
    var label: String {
        switch self { case .none: return "No recorded consent"; case .priorExpressWritten: return "Prior express written consent on file" }
    }
    var allowsTexting: Bool { self == .priorExpressWritten }
}

// MARK: - The compliance verdict for one contact attempt.
struct ComplianceCheck: Hashable {
    var allowed: Bool
    var reasons: [String]            // human-readable why-blocked (empty when allowed)
    var warnings: [String]           // allowed-but-unverifiable notes (e.g. unknown timezone)
    var recipientLocalTime: String?  // the recipient's inferred local time, when known
}

// MARK: - The buyer's own suppression list + STOP/opt-out registry (persisted by the model).
struct Suppression: Codable, Hashable {
    var phones: Set<String> = []     // normalized digits
    var emails: Set<String> = []     // lowercased
    /// Normalize a phone to bare digits (drop a leading US 1) for stable matching.
    static func normPhone(_ p: String) -> String {
        let d = p.filter(\.isNumber)
        return (d.count == 11 && d.first == "1") ? String(d.dropFirst()) : d
    }
    static func normEmail(_ e: String) -> String { e.trimmingCharacters(in: .whitespaces).lowercased() }

    func suppresses(phone: String) -> Bool { let n = Suppression.normPhone(phone); return !n.isEmpty && phones.contains(n) }
    func suppresses(email: String) -> Bool { let n = Suppression.normEmail(email); return !n.isEmpty && emails.contains(n) }

    mutating func add(phone: String) { let n = Suppression.normPhone(phone); if !n.isEmpty { phones.insert(n) } }
    mutating func add(email: String) { let n = Suppression.normEmail(email); if !n.isEmpty { emails.insert(n) } }
    mutating func remove(phone: String) { phones.remove(Suppression.normPhone(phone)) }
    mutating func remove(email: String) { emails.remove(Suppression.normEmail(email)) }
}

// MARK: - The engine.
enum ComplianceEngine {
    static let earliestHour = 8       // 8:00am recipient-local (TCPA)
    static let latestHour = 21        // 9:00pm recipient-local (TCPA) — block AT/after 21:00

    /// Verify ONE contact attempt at `now` (defaults to the actual current moment).
    /// `phone`/`email` are the recipient's; `suppression` is the buyer's own DNC/STOP list;
    /// `consent` is the recorded opt-in state for the lead (RE-18 texting gate).
    static func check(channel: ContactChannel, phone: String, email: String,
                      suppression: Suppression, consent: ContactConsent = .none,
                      now: Date = Date()) -> ComplianceCheck {
        var reasons: [String] = []; var warnings: [String] = []; var localTime: String?

        // 1) Suppression / opt-out — a HARD block on either matching identifier.
        if !phone.isEmpty, suppression.suppresses(phone: phone) {
            reasons.append("This number is on your Do-Not-Contact / opt-out list.")
        }
        if !email.isEmpty, suppression.suppresses(email: email) {
            reasons.append("This email is on your Do-Not-Contact / opt-out list.")
        }

        // 2) TCPA prior-express-written-consent — a cold TEXT with no signed opt-in on file is
        // unlawful. HARD-block SMS unless written consent is recorded; call/mail/email are the
        // default nudge paths and don't require it. (Warn on a text without a phone rather than pass.)
        if channel == .sms {
            if phone.isEmpty {
                reasons.append("No phone on file to text.")
            } else if !consent.allowsTexting {
                reasons.append("Texting requires prior express WRITTEN consent from this contact (TCPA). No signed opt-in on file — use a call or mailer, or capture consent first.")
            }
        }

        // 3) TCPA quiet-hours — only for live calls + texts, in the RECIPIENT's local time.
        if channel.hasTimeWindow {
            if phone.isEmpty {
                warnings.append("No phone on file — can't verify the recipient's local calling window.")
            } else if let tz = USPhoneZone.timeZone(forPhone: phone) {
                var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
                let hour = cal.component(.hour, from: now)
                let df = DateFormatter(); df.timeZone = tz; df.dateFormat = "h:mm a zzz"
                localTime = df.string(from: now)
                if hour < earliestHour || hour >= latestHour {
                    reasons.append("Outside the 8am–9pm calling window in the recipient's time zone (now \(localTime ?? "")).")
                }
            } else {
                warnings.append("Couldn't infer the recipient's time zone from that number — verify it's 8am–9pm local before sending.")
            }
        }

        return ComplianceCheck(allowed: reasons.isEmpty, reasons: reasons, warnings: warnings, recipientLocalTime: localTime)
    }

    /// Minutes until the next legal send opens for a phone, or 0 if it's open now (nil if unknown tz).
    static func minutesUntilOpen(phone: String, now: Date = Date()) -> Int? {
        guard let tz = USPhoneZone.timeZone(forPhone: phone) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let hour = cal.component(.hour, from: now), minute = cal.component(.minute, from: now)
        let mins = hour * 60 + minute
        let open = earliestHour * 60, close = latestHour * 60
        if mins >= open && mins < close { return 0 }
        if mins < open { return open - mins }
        return (24 * 60 - mins) + open   // after close → wait to next morning
    }
}
