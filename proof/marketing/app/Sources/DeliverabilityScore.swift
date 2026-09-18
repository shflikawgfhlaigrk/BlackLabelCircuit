// Black Label Marketing (lead engine, merged from Black Label Leads) — composite Deliverability Score (0–100) with a transparent explanation.
//
// WHY THIS EXISTS
//   Apollo / ZoomInfo / NeverBounce charge for a single "will this email land?" number. This is the
//   in-house, no-paid-provider equivalent (CHARTER §5.5 own-it): it fuses the app's ALREADY-REAL
//   signals — syntax, live MX (dnssd), role-address — with two new deterministic in-house signals
//   (disposable/burner domain, free consumer inbox) and a local-part quality heuristic, into ONE
//   graded score. Critically it is EXPLAINED: every point is attributed to a named factor with a
//   plain-English reason, so the buyer can see WHY an address scored what it did and act on it.
//
// HONESTY (CHARTER §5.1): the score never fabricates. Every factor traces to a real check. When the
//   MX record hasn't been looked up (Require MX off) the score is capped and says so — it does not
//   claim a confidence it doesn't have. An empty address returns `.unknown`, not a fake number.
//
// PURE CORE: `score(email:mxAccepts:)` is synchronous, deterministic, and network-free, so it is fully
//   unit-tested. The async `scoreAll` layer just fills `mxAccepts` from the in-house live MX check.
//   No SwiftUI import here — the model exposes a semantic `Tint`, and the view maps it to a color.
import Foundation

// MARK: - curated in-house domain lists (public knowledge; no paid data)

/// Throwaway / burner inbox providers. Sending here is wasted spend AND a spam-trap/reputation risk:
/// the mailbox evaporates, and many of these domains seed spam traps. Public, well-known list.
enum DisposableDomains {
    static let set: Set<String> = [
        "mailinator.com", "guerrillamail.com", "guerrillamail.info", "guerrillamail.biz",
        "guerrillamail.de", "guerrillamailblock.com", "sharklasers.com", "grr.la", "pokemail.net",
        "spam4.me", "10minutemail.com", "10minutemail.net", "temp-mail.org", "temp-mail.io",
        "tempmail.com", "tempmail.net", "tmpmail.org", "tmpmail.net", "mailtemp.net", "minuteinbox.com",
        "throwawaymail.com", "trashmail.com", "trashmail.net", "yopmail.com", "yopmail.fr",
        "getnada.com", "nada.email", "maildrop.cc", "mailnesia.com", "dispostable.com", "fakeinbox.com",
        "fake-mail.net", "mohmal.com", "emailondeck.com", "mailcatch.com", "spamgourmet.com",
        "discard.email", "discardmail.com", "moakt.com", "tempinbox.com", "burnermail.io",
        "mintemail.com", "33mail.com", "jetable.org", "spambog.com", "tempr.email", "dropmail.me",
        "1secmail.com", "1secmail.org", "1secmail.net", "mytemp.email", "inboxbear.com",
        "wegwerfemail.de", "einrot.com", "cuvox.de", "dayrep.com", "fleckens.hu", "gustr.com",
        "superrito.com", "teleworm.us", "rhyta.com", "armyspy.com",
    ]
    static func contains(_ domain: String) -> Bool { set.contains(domain.lowercased()) }
}

/// Free consumer webmail / ISP inboxes. Not disqualifying — plenty of real buyers use them — but for
/// COLD B2B outreach they filter harder and a personal inbox is a weaker business signal than a
/// company domain. A mild, honest penalty. (Business-leaning hosts like zoho/fastmail are excluded.)
enum FreeMailProviders {
    static let set: Set<String> = [
        "gmail.com", "googlemail.com",
        "yahoo.com", "ymail.com", "rocketmail.com", "yahoo.co.uk", "yahoo.ca", "yahoo.com.au",
        "yahoo.co.in", "yahoo.fr", "yahoo.de", "yahoo.es", "yahoo.it",
        "hotmail.com", "hotmail.co.uk", "hotmail.fr", "hotmail.it", "hotmail.es",
        "outlook.com", "outlook.fr", "outlook.de", "live.com", "live.co.uk", "msn.com",
        "aol.com", "aim.com",
        "icloud.com", "me.com", "mac.com",
        "gmx.com", "gmx.net", "gmx.de", "gmx.us", "mail.com", "email.com",
        "comcast.net", "verizon.net", "att.net", "sbcglobal.net", "bellsouth.net", "cox.net",
        "charter.net", "earthlink.net", "juno.com", "optonline.net", "roadrunner.com", "frontier.com",
        "yandex.com", "yandex.ru", "web.de", "t-online.de",
    ]
    static func contains(_ domain: String) -> Bool { set.contains(domain.lowercased()) }
}

// MARK: - score model

/// One attributed contributor to the score — the "explanation" the buyer reads.
struct DeliverabilityFactor: Identifiable, Hashable {
    enum Kind: String { case confirm, penalty, hardFail }
    let id = UUID()
    let label: String     // short name, e.g. "Role address"
    let impact: Int       // signed points contributed (0 for a pure confirmation)
    let detail: String    // plain-English why-it-matters / what-to-do
    let kind: Kind
}

/// The composite result. `verdict` projects onto the app's existing 5-way `EmailVerdict` so all the
/// existing verdict UI/summaries keep working; `score`+`factors` are the new fine-grained signal.
struct DeliverabilityScore: Hashable {
    var score: Int                       // 0…100
    var grade: Grade
    var verdict: EmailVerdict            // backward-compatible projection
    var factors: [DeliverabilityFactor]
    var mxChecked: Bool                  // was the MX record actually looked up?

    enum Tint: String { case green, blue, amber, red, gray }
    enum Grade: String, CaseIterable {
        case excellent = "Excellent", good = "Good", fair = "Fair",
             risky = "Risky", poor = "Poor", undeliverable = "Undeliverable", unknown = "Unknown"
        var tint: Tint {
            switch self {
            case .excellent, .good: return .green
            case .fair: return .blue
            case .risky: return .amber
            case .poor, .undeliverable: return .red
            case .unknown: return .gray
            }
        }
    }

    /// One-line human summary (used in the timeline note + row subtitle).
    var summary: String {
        let top = factors.filter { $0.kind != .confirm }.sorted { abs($0.impact) > abs($1.impact) }.first
        if let t = top { return "\(score)/100 · \(grade.rawValue) — \(t.label)" }
        return "\(score)/100 · \(grade.rawValue)"
    }
}

// MARK: - the scorer (pure core + async MX layer)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum DeliverabilityScorer {
    /// A local part that looks machine-generated / trap-like (long, mostly-digits, or vowel-less).
    /// Deliberately conservative to avoid flagging legit locals like "j.smith2" or "a.k.gupta".
    static func localPartLooksLowQuality(_ local: String) -> Bool {
        let l = local.lowercased()
        guard !l.isEmpty else { return false }
        if l.count > 40 { return true }
        let digits = l.filter { $0.isNumber }.count
        let letters = l.filter { $0.isLetter }.count
        // Almost-all-digits addresses (e.g. 8374629105@) — rarely a real person's inbox.
        if letters == 0 && digits >= 6 { return true }
        if l.count >= 12 && Double(digits) / Double(l.count) > 0.55 { return true }
        // Long, letter-heavy, but no vowel at all → random consonant string.
        if letters >= 12 {
            let vowels = l.filter { "aeiouy".contains($0) }.count
            if vowels == 0 { return true }
        }
        return false
    }

    /// PURE, deterministic, network-free. `mxAccepts`:
    ///   true  → the domain publishes MX/A (confirmed can-receive),
    ///   false → confirmed NO mail server (hard undeliverable),
    ///   nil   → not looked up (Require MX off) → score is capped and a factor says so.
    static func score(email rawEmail: String, mxAccepts: Bool?) -> DeliverabilityScore {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty → honest unknown (never a fabricated number).
        guard !email.isEmpty else {
            return DeliverabilityScore(score: 0, grade: .unknown, verdict: .unknown,
                factors: [DeliverabilityFactor(label: "No email address", impact: 0,
                    detail: "This lead has no email on file yet — enrich it before scoring.", kind: .confirm)],
                mxChecked: false)
        }

        // Hard fail: bad syntax. Nothing else matters.
        guard Deliverability.validSyntax(email) else {
            return DeliverabilityScore(score: 0, grade: .undeliverable, verdict: .invalid,
                factors: [DeliverabilityFactor(label: "Invalid email format", impact: -100,
                    detail: "Not a valid address (needs exactly one @ and a dotted domain). It cannot be delivered.", kind: .hardFail)],
                mxChecked: mxAccepts != nil)
        }

        let domain = Deliverability.domain(of: email)
        let local = String(email.split(separator: "@").first ?? "")
        var factors: [DeliverabilityFactor] = []
        factors.append(DeliverabilityFactor(label: "Valid format", impact: 0,
            detail: "Well-formed address syntax.", kind: .confirm))

        // Hard fail: confirmed no mail server.
        if mxAccepts == false {
            factors.append(DeliverabilityFactor(label: "No mail server (MX)", impact: -100,
                detail: "The domain \(domain) publishes no MX or A record — it cannot receive mail. Sending here bounces.", kind: .hardFail))
            return DeliverabilityScore(score: 0, grade: .undeliverable, verdict: .undeliverable,
                factors: factors, mxChecked: true)
        }

        // Hard fail: disposable / burner domain (blocks regardless of MX — the mailbox is throwaway).
        if DisposableDomains.contains(domain) {
            factors.append(DeliverabilityFactor(label: "Disposable / burner domain", impact: -85,
                detail: "\(domain) is a throwaway inbox provider. The mailbox evaporates and many seed spam traps — never send to it.", kind: .hardFail))
            return DeliverabilityScore(score: 8, grade: .undeliverable, verdict: .undeliverable,
                factors: factors, mxChecked: mxAccepts != nil)
        }

        // Start from a clean 100 and attribute every deduction.
        var score = 100

        // MX signal.
        switch mxAccepts {
        case .some(true):
            factors.append(DeliverabilityFactor(label: "Domain accepts mail (MX)", impact: 0,
                detail: "\(domain) publishes a live mail server — it can receive mail.", kind: .confirm))
        case .none:
            score -= 8
            factors.append(DeliverabilityFactor(label: "MX not verified", impact: -8,
                detail: "The mail server wasn't checked (Require MX is off). Turn it on to confirm the domain can receive mail.", kind: .penalty))
        case .some(false):
            break // handled above
        }

        // Role address (info@, sales@…): low reply rate + spam-trap risk.
        let isRole = Deliverability.isRoleAddress(email)
        if isRole {
            score -= 30
            factors.append(DeliverabilityFactor(label: "Role address", impact: -30,
                detail: "\(local)@ is a shared role inbox, not a person. Lower reply rates and a higher spam-complaint / trap risk.", kind: .penalty))
        } else {
            factors.append(DeliverabilityFactor(label: "Individual inbox", impact: 0,
                detail: "Addressed to a person, not a shared role mailbox.", kind: .confirm))
        }

        // Free consumer inbox vs business domain.
        if FreeMailProviders.contains(domain) {
            score -= 18
            factors.append(DeliverabilityFactor(label: "Free consumer inbox", impact: -18,
                detail: "\(domain) is a personal webmail/ISP inbox. For cold B2B it filters harder and is a weaker business signal than a company domain.", kind: .penalty))
        } else {
            factors.append(DeliverabilityFactor(label: "Business domain", impact: 0,
                detail: "A company domain, not a free consumer inbox — a stronger B2B signal.", kind: .confirm))
        }

        // Local-part quality.
        if localPartLooksLowQuality(local) {
            score -= 12
            factors.append(DeliverabilityFactor(label: "Low-quality local part", impact: -12,
                detail: "The part before @ looks machine-generated (very long, mostly digits, or random). Double-check it's a real mailbox.", kind: .penalty))
        }

        score = max(0, min(100, score))

        let grade: DeliverabilityScore.Grade
        switch score {
        case 90...100: grade = .excellent
        case 75...89:  grade = .good
        case 55...74:  grade = .fair
        case 35...54:  grade = .risky
        default:       grade = .poor
        }

        // Verdict projection onto the existing 5-way scheme (keeps all existing verdict UI working).
        let verdict: EmailVerdict = isRole ? .risky : .deliverable

        return DeliverabilityScore(score: score, grade: grade, verdict: verdict,
                                   factors: factors, mxChecked: mxAccepts != nil)
    }

    /// True when the address must NEVER be sent to, no matter the buyer's toggles (anti-footgun floor):
    /// invalid syntax, a disposable/burner domain, or a confirmed-dead MX. Pure.
    static func isHardFail(email: String, mxAccepts: Bool?) -> Bool {
        let s = score(email: email, mxAccepts: mxAccepts)
        return s.factors.contains { $0.kind == .hardFail }
    }
}
#endif // circuit-convert

// MARK: - async batch layer (fills mxAccepts from the in-house live MX check, deduped per domain)

/// One scored address for the UI (prospect id + email + its composite score).
struct EmailScore: Identifiable, Hashable {
    let id: UUID          // prospect id
    let email: String
    let score: DeliverabilityScore
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension DeliverabilityScorer {
    /// Score every prospect that has an email. Live MX via the same in-house resolver the send-gate
    /// uses, cached per domain. Honest: a prospect with no email is skipped (nothing to score).
    static func scoreAll(_ leads: [Lead], requireMX: Bool) async -> [EmailScore] {
        var mxCache: [String: Bool] = [:]
        var out: [EmailScore] = []
        for p in leads where !p.email.trimmingCharacters(in: .whitespaces).isEmpty {
            var mx: Bool? = nil
            if requireMX, Deliverability.validSyntax(p.email) {
                let d = Deliverability.domain(of: p.email)
                if let cached = mxCache[d] { mx = cached }
                else { let ok = await Deliverability.domainAcceptsMail(d); mxCache[d] = ok; mx = ok }
            }
            out.append(EmailScore(id: p.id, email: p.email, score: score(email: p.email, mxAccepts: mx)))
        }
        return out
    }

    /// Average score across a scored set (honest 0 when empty). Drives the panel's headline number.
    static func averageScore(_ scores: [EmailScore]) -> Int {
        guard !scores.isEmpty else { return 0 }
        return Int((Double(scores.map { $0.score.score }.reduce(0, +)) / Double(scores.count)).rounded())
    }
}
#endif // circuit-convert
