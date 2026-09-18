// Black Label Marketing (lead engine, merged from Black Label Leads) — bulk enrichment + import-time email verification (Tier-2).
//
// Two real capabilities:
//   1. IMPORT-TIME / BULK VERIFICATION — in-house, free: run every prospect's email through the
//      same deliverability checks the send-gate uses (syntax, role, live MX) and surface a verdict
//      per lead. No paid provider needed; reuses Deliverability.* + DNSResolver.
//   2. BULK ENRICHMENT (provider-backed email/phone discovery) — needs a paid data provider
//      (Hunter / Clearbit / Apollo-class). We ship the real UI + an honest "connect a provider"
//      gate; we NEVER fabricate an email or phone. When no provider is connected, the only
//      enrichment offered is the in-house, honest pattern-CANDIDATE generator (clearly labelled a
//      guess, validated by MX before it's trusted) — never presented as a verified provider result.
//
// On-device. Provider API key (when connected) lives in the Keychain. No fabricated data.
import Foundation

// MARK: - per-email verification verdict (the result of an in-house check)

enum EmailVerdict: String, Codable, CaseIterable {
    case deliverable     // valid syntax, non-role, domain accepts mail (MX/A)
    case risky           // valid + accepts mail, but role address (info@/sales@…)
    case undeliverable   // no MX / no domain
    case invalid         // bad syntax
    case unknown         // not checked yet
    var label: String {
        switch self {
        case .deliverable: return "Deliverable"; case .risky: return "Risky (role)"
        case .undeliverable: return "Undeliverable"; case .invalid: return "Invalid"; case .unknown: return "Unknown"
        }
    }
    var icon: String {
        switch self {
        case .deliverable: return "checkmark.seal.fill"; case .risky: return "exclamationmark.triangle.fill"
        case .undeliverable: return "xmark.seal.fill"; case .invalid: return "xmark.octagon.fill"; case .unknown: return "questionmark.circle"
        }
    }
}

struct VerificationResult: Identifiable, Hashable {
    var id: UUID                 // prospect id
    var email: String
    var verdict: EmailVerdict
    var note: String
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum EmailVerifier {
    /// Verify ONE email with the in-house gate. Caches MX answers per domain via the caller's dict.
    static func verify(_ email: String, requireMX: Bool, mxCache: inout [String: Bool]) async -> (EmailVerdict, String) {
        let e = email.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return (.unknown, "no email") }
        guard Deliverability.validSyntax(e) else { return (.invalid, "bad syntax") }
        let role = Deliverability.isRoleAddress(e)
        let domain = Deliverability.domain(of: e)
        var acceptsMail = true
        if requireMX {
            if let cached = mxCache[domain] { acceptsMail = cached }
            else { acceptsMail = await Deliverability.domainAcceptsMail(domain); mxCache[domain] = acceptsMail }
        }
        if requireMX && !acceptsMail { return (.undeliverable, "domain has no mail server (MX)") }
        if role { return (.risky, "role address — accepts mail but low-conversion / deliverability risk") }
        return (.deliverable, requireMX ? "valid, non-role, domain accepts mail" : "valid syntax, non-role")
    }

    /// Bulk-verify a set of leads. Returns one result per prospect with an email. Live DNS for MX;
    /// dedupes lookups per domain. Pure-honest: a prospect with no email yields `.unknown`.
    static func verifyAll(_ leads: [Lead], requireMX: Bool) async -> [VerificationResult] {
        var mxCache: [String: Bool] = [:]
        var out: [VerificationResult] = []
        for p in leads {
            if p.email.isEmpty { out.append(VerificationResult(id: p.id, email: "", verdict: .unknown, note: "no email on file")); continue }
            let (v, note) = await verify(p.email, requireMX: requireMX, mxCache: &mxCache)
            out.append(VerificationResult(id: p.id, email: p.email, verdict: v, note: note))
        }
        return out
    }

    /// Roll a result set into honest counts for the UI summary.
    static func summarize(_ results: [VerificationResult]) -> [EmailVerdict: Int] {
        var c: [EmailVerdict: Int] = [:]
        for r in results { c[r.verdict, default: 0] += 1 }
        return c
    }
}
#endif // circuit-convert

// MARK: - enrichment provider config (BYO; honest "connect a provider" gate)

enum EnrichmentProvider: String, Codable, CaseIterable, Identifiable {
    case none          // no provider connected — in-house pattern candidates only
    case hunter
    case apollo
    case prospeo
    case clearbit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "No provider (in-house only)"; case .hunter: return "Hunter.io"
        case .apollo: return "Apollo"; case .prospeo: return "Prospeo"; case .clearbit: return "Clearbit"
        }
    }
    var needsKey: Bool { self != .none }
    var blurb: String {
        switch self {
        case .none: return "Without a data provider, the only enrichment is an in-house best-guess email pattern (name + domain), which is then MX-verified before it's trusted. It's a candidate, not a confirmed address."
        case .hunter: return "Connect your own Hunter.io API key to find + verify professional emails by name and domain."
        case .apollo: return "Connect your own Apollo API key to enrich contacts with verified emails, phones, and titles."
        case .prospeo: return "Connect your own Prospeo API key to find professional emails by name and domain."
        case .clearbit: return "Connect your own Clearbit key to enrich companies and contacts from a domain."
        }
    }
}

struct EnrichmentConfig: Codable, Hashable {
    var provider: EnrichmentProvider = .none
    var hasKey: Bool = false
    /// MK-17 waterfall: the buyer's OWN ordered provider chain (Hunter/Apollo/Prospeo). The waterfall
    /// runs these vendors IN ORDER until the first confirmed hit; each vendor's key lives in the
    /// Keychain (EnrichmentKeychain, keyed by vendor). Empty → the single-provider path above.
    var enrichmentChain: [EnrichmentVendor] = []
    var keychainAccount: String { "enrichment:\(provider.rawValue)" }
    /// True only when a real provider is connected with a stored key.
    var providerReady: Bool { provider.needsKey && hasKey }
    /// True when the buyer has ordered a multi-provider waterfall (at least one vendor in the chain).
    var chainReady: Bool { !enrichmentChain.isEmpty }

    init() {}
    enum CodingKeys: String, CodingKey { case provider, hasKey, enrichmentChain }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        provider = (try? c.decode(EnrichmentProvider.self, forKey: .provider)) ?? .none
        hasKey = (try? c.decode(Bool.self, forKey: .hasKey)) ?? false
        enrichmentChain = (try? c.decode([EnrichmentVendor].self, forKey: .enrichmentChain)) ?? []
    }
}

// NOTE: the in-house pattern-GUESS lane lives in Sources/EmailGuess.swift (LeadEmailDisplay +
// EmailGuessEngine). It stores a guess in the SEPARATE `Lead.guessedEmail` field and never writes
// the confirmed `email`, so a guess can never render as a verified address. The earlier
// `CandidateEnricher`/`EnrichmentCandidate` pair wrote its guess straight into `email` (a fake-green
// trap) and was removed — see EmailGuessTests for the honesty invariants that lock the new lane.
