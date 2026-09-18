#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — in-app 14-day trial → purchase gate.
//
// The self-serve activation gap this closes: the trial lived only on the storefront/Stripe, so a
// fresh install had no in-app trial clock and nothing gated list-build/export behind a purchase.
// This adds a first-run-dated, ROLLBACK-RESISTANT 14-day trial (mirrors Black Label Academy's proven
// TrialStore) that hard-gates list-building + exporting to the storefront checkout URL when it
// expires and the buyer hasn't purchased.
//
// Nothing here touches Stripe or the storefront (CHARTER §3 owner gate on money): the app opens a
// CONFIG-DRIVEN checkout URL (the hosted offer page). A buyer who has entered a purchased Lead
// Database key (Keychain) is treated as PURCHASED — full access, no trial gate. The entitlement math
// lives in `RETrialEngine` as a PURE function so it is testable headlessly (`--selftest-trial`) and
// cannot drift from what the UI shows.
import Foundation

// PLATFORM: macOS Developer-ID (/dl) build ONLY. Neither store build may sell access outside
// StoreKit IAP (App Store Guideline 3.1.1), so the trial/checkout machinery compiles only when
// MAS_BUILD is absent (matching Academy's -DMAS_BUILD posture). The Mac App Store target sets
// MAS_BUILD in project.yml and ships full-unlocked like iOS; only build.command's Dev-ID/adhoc
// lane carries the trial.
#if os(macOS) && !MAS_BUILD

// MARK: - Config (config-driven checkout, no hardcoded Stripe object)
enum RETrialConfig {
    /// Founder ruling 2026-08-04 ("everything is changing to 2 weeks free") — was 7.
    ///
    /// MIGRATION SAFETY: the persisted record is (startedAt, lastSeen, purchased) and nothing else —
    /// no trial length is stored, and the record carries no signature or MAC. So changing this
    /// constant cannot invalidate, reset or fail-to-verify an existing buyer's state: the SAME
    /// unchanged facts are simply evaluated against a wider window, which can only ever move a
    /// buyer forward (more days, or expired -> back in trial). Proven by `--selftest-trial` and by
    /// testRETrialMigrationPreservesExistingBuyers().
    static let trialDays = 14
    /// Where the "trial ended" gate sends the buyer. Config-driven so it flips without a rebuild:
    ///   1. a user override in UserDefaults ("bl.realestate.checkout_url"), else
    ///   2. the hosted offer page (web-producer wires the active payment link there).
    static let defaultCheckoutURL = "https://blacklabelbots.com/realestate"
    static var checkoutURL: URL {
        let override = UserDefaults.standard.string(forKey: "bl.realestate.checkout_url")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty, let u = URL(string: override) { return u }
        return URL(string: defaultCheckoutURL)!
    }
}

// MARK: - Lead-Database key → purchase evidence (validated, never assumed)
//
// A typed Access Key proves a purchase ONLY after the live API authenticates it as a paid tier
// (pro/founder ride on every /v1/search envelope; preview = no purchase). The validated tier is
// bound to a hash of the exact key, so replacing or clearing the key withdraws the evidence by
// itself — an arbitrary string in the field can never unlock, and can never latch (§5.1).
enum RELeadDBValidation {
    /// Tiers the storefront actually sells — the only tiers that count as purchase evidence.
    static let paidTiers: Set<String> = ["pro", "founder"]
    private static let kTier = "bl.realestate.leaddb_validated_tier"
    private static let kHash = "bl.realestate.leaddb_validated_keyhash"

    /// Pure rule: does an API-reported tier prove a purchase?
    static func isPaidTier(_ tier: String?) -> Bool {
        guard let t = tier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !t.isEmpty else { return false }
        return paidTiers.contains(t)
    }
    /// Fingerprint binding a validation verdict to the exact key it validated (never the key itself).
    static func tokenHash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
    /// The paid tier the CURRENTLY-SAVED key proved against the live API, or nil
    /// (no key / key changed since validation / validated as preview).
    static func validatedPaidTier() -> String? {
        guard let token = Keychain.leadDBToken() else { return nil }
        let d = UserDefaults.standard
        guard let tier = d.string(forKey: kTier), d.string(forKey: kHash) == tokenHash(token),
              isPaidTier(tier) else { return nil }
        return tier
    }
    /// Record what the live API just reported for `token` (non-paid verdicts clear the record).
    static func record(tier: String?, forToken token: String) {
        let d = UserDefaults.standard
        if isPaidTier(tier), let t = tier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            d.set(t, forKey: kTier); d.set(tokenHash(token), forKey: kHash)
        } else {
            d.removeObject(forKey: kTier); d.removeObject(forKey: kHash)
        }
    }
    /// Ask the live index which tier the saved key authenticates as (1-row probe over NC, the
    /// flagship covered state; the tier rides on every search envelope). Records a definitive
    /// verdict either way; a failure to answer (offline, 401 on a dead key) keeps the prior
    /// verdict — and since verdicts are hash-bound to the exact key, an unanswered NEW key
    /// stays unvalidated: fail-closed, never fail-open.
    @discardableResult
    static func revalidateSavedKey() async -> String? {
        guard let token = Keychain.leadDBToken() else {
            record(tier: nil, forToken: ""); return nil
        }
        guard let page = try? await RealEstateAPI.searchOrThrow(state: "NC", perPage: 1) else {
            return validatedPaidTier()
        }
        record(tier: page.tier, forToken: token)
        return validatedPaidTier()
    }
}

// MARK: - Entitlement state machine (pure)
enum REEntitlement: Equatable {
    case trial(daysRemaining: Int)   // in the free window; full access
    case expired                     // trial over, not purchased; HARD gate on build/export
    case purchased                   // entered a purchase key; full access

    var isEntitled: Bool {
        switch self { case .trial, .purchased: return true; case .expired: return false }
    }
    /// True only while the user still has full access AND should be gated on the paid features
    /// once expired. Drives list-build + export gating.
    var allowsPaidFeatures: Bool { isEntitled }
}

enum RETrialEngine {
    /// Evaluate access from persisted facts. `effectiveNow` is a clock-rollback-resistant clock:
    /// the caller passes max(now, lastSeen) so setting the system clock backward can never revive
    /// an expired trial or extend the window.
    static func evaluate(startedAt: Date, effectiveNow: Date, purchased: Bool,
                         trialDays: Int = RETrialConfig.trialDays) -> REEntitlement {
        if purchased { return .purchased }
        let elapsedDays = Int(floor(effectiveNow.timeIntervalSince(startedAt) / 86_400))
        let remaining = trialDays - elapsedDays
        if remaining <= 0 { return .expired }
        return .trial(daysRemaining: remaining)
    }
}

// MARK: - Persisted store (UserDefaults + Application-Support mirror; defaults-reset can't restart it)
import Combine
import CryptoKit

@MainActor
final class RETrialStore: ObservableObject {
    /// App-wide instance so any paid-feature call-site can consult the same trial clock without
    /// threading a macOS-only EnvironmentObject through every view (the iOS build has no trial).
    /// Only the app-wide instance revalidates the saved key against the live API — injected test
    /// stores stay network-silent.
    static let shared = RETrialStore(autoRevalidate: true)

    @Published private(set) var entitlement: REEntitlement = .trial(daysRemaining: RETrialConfig.trialDays)

    private let d = UserDefaults.standard
    private let kStarted = "bl.realestate.trial_started_at"
    private let kLastSeen = "bl.realestate.trial_last_seen"
    /// Explicit checkout confirmation only (markPurchased). Pre-fix builds latched the any-string
    /// key probe into "bl.realestate.purchased"; that legacy key is no longer purchase evidence
    /// and is scrubbed on refresh.
    private let kConfirmed = "bl.realestate.purchase_confirmed"
    private let kPurchasedLegacy = "bl.realestate.purchased"
    private let mirrorURL: URL
    /// Injected so a fresh install with a purchased key is entitled from the first launch, and tests
    /// can drive both branches. Defaults to "the saved Lead Database key VALIDATED as a paid tier
    /// against the live API" — a typed-but-unvalidated string proves nothing.
    private let purchasedProbe: () -> Bool
    private var revalidationObserver: NSObjectProtocol?

    /// `dataDir` overrides where the entitlement mirror lives. Injected (not env-sniffed) so the
    /// test lane can exercise the real persistence path against a throwaway directory instead of
    /// overwriting a live buyer's `entitlement.json` on the build host. nil = production behaviour.
    init(clock: Date = Date(),
         purchasedProbe: @escaping () -> Bool = { RELeadDBValidation.validatedPaidTier() != nil },
         dataDir: URL? = nil,
         autoRevalidate: Bool = false) {
        self.purchasedProbe = purchasedProbe
        let fm = FileManager.default
        // Honor BLRE_DATA_DIR (tests/guest) so a self-test never scribbles on a real workspace.
        let base: URL
        if let dataDir {
            base = dataDir
        } else if let overridePath = ProcessInfo.processInfo.environment["BLRE_DATA_DIR"], !overridePath.isEmpty {
            base = URL(fileURLWithPath: overridePath, isDirectory: true)
        } else {
            base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        }
        let dir = base.appendingPathComponent("BlackLabelRealEstate", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        mirrorURL = dir.appendingPathComponent("entitlement.json")
        refresh(now: clock)
        if autoRevalidate {
            // Re-prove the saved key only after the buyer explicitly saves/clears/tests it in
            // Settings. Startup's normal refresh already derives the current hash-bound verdict;
            // a second credential probe plus an automatic network request added no authority and
            // made cold launch touch the secret store repeatedly.
            revalidationObserver = NotificationCenter.default.addObserver(forName: .blreLeadDBTokenChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    await RELeadDBValidation.revalidateSavedKey()
                    self?.refresh()
                }
            }
        }
    }

    var isEntitled: Bool { entitlement.isEntitled }
    var daysRemaining: Int { if case .trial(let n) = entitlement { return n }; return 0 }
    var isExpired: Bool { if case .expired = entitlement { return true }; return false }

    /// Called on launch and when returning from checkout. Starts the trial clock on first run,
    /// advances the rollback-resistant "last seen" clock, and recomputes access.
    func refresh(now: Date = Date()) {
        var started = storedDate(kStarted)
        var lastSeen = storedDate(kLastSeen)
        // Purchase evidence is DERIVED on every refresh, never latched: an explicit checkout
        // confirmation (markPurchased) or the live probe (saved key validated as a paid tier).
        // Pre-fix builds latched the any-string probe into kPurchasedLegacy/mirror.purchased —
        // an unauthenticated latch is not evidence, so it is neither honored nor rewritten.
        var confirmed = d.object(forKey: kConfirmed) as? Bool ?? false
        if started == nil, let m = readMirror() {
            started = m.started; lastSeen = m.lastSeen; confirmed = confirmed || (m.confirmed ?? false)
        }
        d.removeObject(forKey: kPurchasedLegacy)
        let purchased = confirmed || purchasedProbe()
        if started == nil {
            started = now
            NSLog("[realestate.trial] trial started at \(iso(now)) — \(RETrialConfig.trialDays)-day free trial")
        }
        let start = started!
        let prevSeen = lastSeen ?? start
        let effectiveNow = max(now, prevSeen)

        entitlement = RETrialEngine.evaluate(startedAt: start, effectiveNow: effectiveNow, purchased: purchased)

        setDate(kStarted, start)
        setDate(kLastSeen, effectiveNow)
        d.set(confirmed, forKey: kConfirmed)
        writeMirror(started: start, lastSeen: effectiveNow, purchased: purchased, confirmed: confirmed)

        if case .expired = entitlement {
            NSLog("[realestate.trial] trial EXPIRED — gating build/export to checkout \(RETrialConfig.checkoutURL.absoluteString)")
        }
    }

    /// Mark purchased (after the buyer confirms checkout).
    func markPurchased() {
        d.set(true, forKey: kConfirmed)
        refresh()
        NSLog("[realestate.trial] marked purchased — full access")
    }

    // persistence helpers
    private func storedDate(_ key: String) -> Date? {
        let t = d.double(forKey: key); return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    private func setDate(_ key: String, _ date: Date) { d.set(date.timeIntervalSince1970, forKey: key) }
    private func iso(_ dd: Date) -> String { ISO8601DateFormatter().string(from: dd) }

    /// `purchased` stays for format compatibility (legacy records decode; the field is written as
    /// the derived live value). `confirmed` is the only field read back as purchase evidence —
    /// optional so legacy records (whose `purchased` was the any-string latch) decode to nil.
    private struct Mirror: Codable { var started: Date; var lastSeen: Date; var purchased: Bool; var confirmed: Bool? }
    private func readMirror() -> Mirror? {
        guard let data = try? Data(contentsOf: mirrorURL) else { return nil }
        return try? JSONDecoder().decode(Mirror.self, from: data)
    }
    private func writeMirror(started: Date, lastSeen: Date, purchased: Bool, confirmed: Bool) {
        if let data = try? JSONEncoder().encode(Mirror(started: started, lastSeen: lastSeen, purchased: purchased, confirmed: confirmed)) {
            try? data.write(to: mirrorURL)
        }
    }
}

// MARK: - Headless self-test (proves the state machine without a WindowServer)
/// Runs the entitlement state machine over injected dates + asserts the gate holds, then exits.
/// Invoked via `Black Label Real Estate --selftest-trial`.
func runRETrialSelfTest() -> Never {
    let start = Date(timeIntervalSince1970: 1_000_000)
    let day: TimeInterval = 86_400
    print("== Black Label Real Estate — trial self-test ==")
    print("config: trialDays=\(RETrialConfig.trialDays) checkout=\(RETrialConfig.checkoutURL.absoluteString)")

    func describe(_ e: REEntitlement) -> String {
        switch e { case .trial(let n): return "trial(\(n) days left)"; case .expired: return "EXPIRED"; case .purchased: return "purchased" }
    }
    func line(_ label: String, _ e: REEntitlement) {
        print("  \(label.padding(toLength: 24, withPad: " ", startingAt: 0)) -> \(describe(e)) (entitled=\(e.isEntitled ? "yes" : "NO"))")
    }

    /// Days left, or nil when not in a counting-down trial. Used by the migration assertions so
    /// "never shorter" is compared numerically rather than eyeballed from the printed walk.
    func remaining(_ e: REEntitlement) -> Int? { if case .trial(let n) = e { return n }; return nil }

    let d0 = RETrialEngine.evaluate(startedAt: start, effectiveNow: start, purchased: false)
    line("day 0 (trial start)", d0)
    line("day 3", RETrialEngine.evaluate(startedAt: start, effectiveNow: start + 3*day, purchased: false))
    let d13 = RETrialEngine.evaluate(startedAt: start, effectiveNow: start + 13*day, purchased: false)
    line("day 13", d13)
    let d14 = RETrialEngine.evaluate(startedAt: start, effectiveNow: start + 14*day, purchased: false)
    line("day 14 (expiry)", d14)
    line("day 30", RETrialEngine.evaluate(startedAt: start, effectiveNow: start + 30*day, purchased: false))
    line("day 30 purchased", RETrialEngine.evaluate(startedAt: start, effectiveNow: start + 30*day, purchased: true))
    let rolledBack = max(start + 1*day, start + 15*day)   // caller clamps forward
    line("day 15 then clock<-day1", RETrialEngine.evaluate(startedAt: start, effectiveNow: rolledBack, purchased: false))

    // MIGRATION (founder ruling 2026-08-04: 7 -> 14 days). An existing buyer's persisted record is
    // (startedAt, lastSeen, purchased) — no stored length, no signature — so the SAME facts are
    // re-evaluated against the wider window. Asserted below: never shorter, never a lockout.
    print("-- migration: existing records under the old 7-day window --")
    let mid = start + 5*day
    let midOld = RETrialEngine.evaluate(startedAt: start, effectiveNow: mid, purchased: false, trialDays: 7)
    let midNew = RETrialEngine.evaluate(startedAt: start, effectiveNow: mid, purchased: false)
    line("day 5 (old 7-day build)", midOld)
    line("day 5 (this build)", midNew)
    let lapsedOld = RETrialEngine.evaluate(startedAt: start, effectiveNow: start + 9*day, purchased: false, trialDays: 7)
    let lapsedNew = RETrialEngine.evaluate(startedAt: start, effectiveNow: start + 9*day, purchased: false)
    line("day 9 (old 7-day build)", lapsedOld)
    line("day 9 (this build)", lapsedNew)
    let boughtOld = RETrialEngine.evaluate(startedAt: start, effectiveNow: start + 99*day, purchased: true, trialDays: 7)
    let boughtNew = RETrialEngine.evaluate(startedAt: start, effectiveNow: start + 99*day, purchased: true)
    line("purchased (old build)", boughtOld)
    line("purchased (this build)", boughtNew)

    var ok = true
    if !d0.isEntitled { print("FAIL: day 0 not entitled"); ok = false }
    if case .trial = d0 {} else { print("FAIL: day 0 not trial"); ok = false }
    if remaining(d0) != RETrialConfig.trialDays { print("FAIL: day 0 not \(RETrialConfig.trialDays) days left"); ok = false }
    if !d13.isEntitled { print("FAIL: day 13 not entitled (gate closed early)"); ok = false }
    if d14.isEntitled { print("FAIL: day 14 still entitled (gate did not close)"); ok = false }
    if case .expired = d14 {} else { print("FAIL: day 14 not expired"); ok = false }
    let rb = RETrialEngine.evaluate(startedAt: start, effectiveNow: rolledBack, purchased: false)
    if rb.isEntitled { print("FAIL: rollback revived an expired trial"); ok = false }
    // Mid-trial buyer: strictly MORE days, same startedAt, still entitled.
    if !midNew.isEntitled { print("FAIL: mid-trial buyer lost entitlement across the change"); ok = false }
    guard let midOldN = remaining(midOld), let midNewN = remaining(midNew), midNewN > midOldN else {
        print("FAIL: mid-trial window did not widen (7->14)"); ok = false
        print("SELFTEST FAILED"); exit(1)
    }
    // A buyer already past day 7 was expired under the old window; the wider window can only give
    // access back. It must never take access away.
    if lapsedOld.isEntitled { print("FAIL: fixture wrong — day 9 should be expired at 7 days"); ok = false }
    if !lapsedNew.isEntitled { print("FAIL: day-9 buyer lost access under the wider window"); ok = false }
    // Purchase always wins and is unaffected by the length change.
    if boughtOld != .purchased || boughtNew != .purchased { print("FAIL: purchased buyer disturbed by the change"); ok = false }

    print("  migration: day-5 buyer \(midOldN)d -> \(midNewN)d left (never shorter); startedAt untouched;")
    print("             record is (startedAt,lastSeen,purchased) with no stored length and no signature.")
    print(ok ? "SELFTEST OK — trial starts, counts down, hard-gates at day \(RETrialConfig.trialDays), rollback-resistant, existing records widen"
             : "SELFTEST FAILED")
    exit(ok ? 0 : 1)
}

#endif  // os(macOS) && !MAS_BUILD
#endif // circuit-convert
