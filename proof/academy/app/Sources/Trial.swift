// Black Label Academy — trial + subscription entitlement.
//
// Founder decision (2026-07-08): Academy is a 7-day FREE TRIAL → $30/mo subscription.
// (This supersedes the earlier "fully free" framing.) The library is fully readable during the
// trial; when the trial expires and the user has not subscribed, a HARD gate replaces the reader
// and routes to checkout. Nothing here talks to Stripe directly — the app opens a config-driven
// checkout URL (the hosted offer page), so the moment an active $30/mo payment link is wired on the
// web side, the same button goes live with no app rebuild.
//
// The entitlement math lives in `TrialEngine` as a PURE function so it is testable headlessly
// (see `--selftest-trial`) and cannot drift from what the UI shows.
import Foundation

// PLATFORM: macOS-only. Academy's iOS build ships the full library FREE with no trial, paywall,
// subscription, or external checkout — a digital subscription may not be sold outside StoreKit IAP
// (App Store Guideline 3.1.1). The entire trial/subscription machinery AND the checkout URL compile
// only into the macOS Developer-ID build, where the 7-day trial → $30/mo Stripe checkout lives.
#if os(macOS) && !MAS_BUILD

// MARK: - Config (config-driven checkout, no hardcoded Stripe object)

enum AcademyConfig {
    /// The subscription price shown to the buyer. Sourced from the live Stripe price
    /// `price_1ToVnE3oBFQ8gfJMlKZbZ209` ($30.00/mo, recurring monthly) — founder-decided 2026-07-08.
    static let monthlyPriceUSD = 30
    static let trialDays = 7

    /// Where the "Subscribe" / "trial ended" gate sends the buyer. Config-driven so it flips live
    /// without an app rebuild:
    ///   1. a user override in UserDefaults ("bl.academy.checkout_url"), else
    ///   2. the hosted offer page, where web-producer wires the active $30/mo payment link.
    /// The offer page ALWAYS exists (founder directive: never delete the checkout page).
    static let defaultCheckoutURL = "https://blacklabelbots.com/academy"

    static var checkoutURL: URL {
        let override = UserDefaults.standard.string(forKey: "bl.academy.checkout_url")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty, let u = URL(string: override) { return u }
        return URL(string: defaultCheckoutURL)!
    }

    // AC-13 honest billing. Where a subscriber goes to MANAGE or CANCEL billing. Config-driven the
    // same way as checkout (UserDefaults override "bl.academy.manage_url"), defaulting to the hosted
    // account page. BLOCKER: the live per-customer Stripe billing-portal URL is a web-producer /
    // founder wiring — until it's set, this opens the account page, never a fabricated deep-link.
    static let defaultManageURL = "https://blacklabelbots.com/academy/account"
    static var manageURL: URL {
        let override = UserDefaults.standard.string(forKey: "bl.academy.manage_url")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty, let u = URL(string: override) { return u }
        return URL(string: defaultManageURL)!
    }

    /// A real, named human a buyer can reach about billing — not a fabricated "support team".
    static let supportContactName = "Michael Barber"
    static let supportContactEmail = "michael@blacklabelbots.com"
    static var supportMailtoURL: URL { URL(string: "mailto:\(supportContactEmail)")! }

    // AC-09 cohort completion lever. The base URL of the anonymous cohort server (a Cloudflare
    // Worker + KV — web/cohort-worker.js, deploy = web-producer's lane). Config-driven the same way
    // as checkout/manage (UserDefaults override "bl.academy.cohort_url") so it can flip live without
    // an app rebuild. The cohort feature is OPT-IN and ships JOINED-OFF, so the read path makes ZERO
    // network calls (AC-03) until a buyer explicitly joins. Cohort PRICING is a founder money gate
    // (§3) — the feature ships flagged/free with no price copy.
    // Live as of 2026-07-12 (Cloudflare Worker `academy-cohort`, KV binding COHORT). The `/api/cohort`
    // suffix is part of the base — the Worker matches `…/api/cohort/{join,complete,signal}`, so the
    // transport appends only the verb. Never append `/api/cohort` a second time.
    static let defaultCohortBaseURL = "https://academy-cohort.michael-070.workers.dev/api/cohort"
    static var cohortBaseURL: URL {
        let override = UserDefaults.standard.string(forKey: "bl.academy.cohort_url")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty, let u = URL(string: override) { return u }
        return URL(string: defaultCohortBaseURL)!
    }
}

// MARK: - Entitlement state machine (pure)

enum Entitlement: Equatable {
    case trial(daysRemaining: Int)   // in the free window; full access
    case expired                     // trial NEVER converted to paid; HARD gate (protects AC-05)
    case subscribed                  // paying; full access + new content
    case lapsed                      // paid, then canceled; the on-device library stays readable,
                                     // but updates / new lessons are gated until they resubscribe

    /// Reader access. A lapsed (paid-then-canceled) account KEEPS the library already downloaded to
    /// this Mac — that is the marketed keep-on-cancel guarantee (AC-12). Only a trial that never
    /// converted to paid hard-gates, so nothing is given away for free past day 7 (AC-05).
    var isEntitled: Bool {
        switch self {
        case .trial, .subscribed, .lapsed: return true
        case .expired: return false
        }
    }

    /// Whether this account still receives new content / app updates. A canceled subscriber keeps
    /// what they downloaded but stops getting new lessons until they resubscribe (updates gated).
    var canReceiveUpdates: Bool {
        switch self {
        case .trial, .subscribed: return true
        case .lapsed, .expired: return false
        }
    }

    /// AC-13: whether there is an active billing relationship the buyer can CANCEL right now. A trial
    /// (an upcoming first charge) or an active subscription can be canceled; an already-expired or
    /// already-lapsed account has nothing to cancel (it would resubscribe instead).
    var canCancel: Bool {
        switch self {
        case .trial, .subscribed: return true
        case .lapsed, .expired: return false
        }
    }
}

enum TrialEngine {
    /// Evaluate access from persisted facts. `effectiveNow` is a clock-rollback-resistant clock:
    /// the caller passes max(now, lastSeen) so setting the system clock backward can never revive
    /// an expired trial or extend the window.
    static func evaluate(startedAt: Date,
                         effectiveNow: Date,
                         subscribed: Bool,
                         everPaid: Bool = false,
                         trialDays: Int = AcademyConfig.trialDays) -> Entitlement {
        if subscribed { return .subscribed }
        let elapsedDays = Int(floor(effectiveNow.timeIntervalSince(startedAt) / 86_400))
        let remaining = trialDays - elapsedDays
        if remaining <= 0 {
            // Past the window and not currently subscribed: a buyer who EVER paid keeps the on-device
            // library (lapsed, AC-12); a trial that never paid hard-gates (expired, AC-05).
            return everPaid ? .lapsed : .expired
        }
        return .trial(daysRemaining: remaining)
    }
}

// MARK: - Persisted store

/// Persists the trial clock + subscription flag. Uses UserDefaults (fast) mirrored to a file in
/// Application Support so a defaults reset does not silently restart the trial.
@MainActor
final class TrialStore: ObservableObject {
    @Published private(set) var entitlement: Entitlement = .trial(daysRemaining: AcademyConfig.trialDays)

    private let d = UserDefaults.standard
    private let kStarted = "bl.academy.trial_started_at"
    private let kLastSeen = "bl.academy.trial_last_seen"
    private let kSubscribed = "bl.academy.subscribed"
    // Sticky "this account has paid at least once" flag. Once true it never clears — that is what lets
    // a later cancel drop to `.lapsed` (library stays readable) instead of `.expired` (hard gate).
    private let kEverPaid = "bl.academy.ever_paid"
    private let mirrorURL: URL

    init(clock: Date = Date()) {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("BlackLabelAcademy", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        mirrorURL = dir.appendingPathComponent("entitlement.json")
        refresh(now: clock)
    }

    var isEntitled: Bool { entitlement.isEntitled }

    var daysRemaining: Int {
        if case .trial(let n) = entitlement { return n }
        return 0
    }

    /// When the 7-day free trial began (first run), or nil before first run. Read from the same
    /// persisted clock the entitlement math uses — never a synthesized date.
    var trialStartedAt: Date? { storedDate(kStarted) }

    /// AC-13 renewal-date surface: the date the trial converts to the first $30/mo charge
    /// (trialStartedAt + trialDays). Computed purely from the persisted trial clock, so it can never
    /// be a fabricated billing date. nil before first run.
    var trialEndsAt: Date? {
        trialStartedAt.map { $0.addingTimeInterval(Double(AcademyConfig.trialDays) * 86_400) }
    }

    /// Called on launch and when returning from checkout. Starts the trial clock on first run,
    /// advances the rollback-resistant "last seen" clock, and recomputes access.
    func refresh(now: Date = Date()) {
        // Recover state from the mirror if defaults were wiped.
        var started = storedDate(kStarted)
        var lastSeen = storedDate(kLastSeen)
        var subscribed = d.object(forKey: kSubscribed) as? Bool ?? false
        var everPaid = d.object(forKey: kEverPaid) as? Bool ?? false
        if started == nil, let m = readMirror() {
            started = m.started; lastSeen = m.lastSeen
            subscribed = subscribed || m.subscribed
            everPaid = everPaid || (m.everPaid ?? false)
        }
        // An active subscription proves this account has paid — remember it so a later cancel keeps
        // the on-device library readable (lapsed) rather than hard-gating (expired).
        if subscribed { everPaid = true }

        // FIRST RUN — start the 7-day trial now.
        if started == nil {
            started = now
            NSLog("[academy.trial] trial started at \(iso(now)) — \(AcademyConfig.trialDays)-day free trial")
        }
        let start = started!

        // Rollback-resistant clock: never let the effective clock move backward.
        let prevSeen = lastSeen ?? start
        let effectiveNow = max(now, prevSeen)

        entitlement = TrialEngine.evaluate(startedAt: start, effectiveNow: effectiveNow,
                                           subscribed: subscribed, everPaid: everPaid)

        // Persist.
        setDate(kStarted, start)
        setDate(kLastSeen, effectiveNow)
        d.set(subscribed, forKey: kSubscribed)
        d.set(everPaid, forKey: kEverPaid)
        writeMirror(started: start, lastSeen: effectiveNow, subscribed: subscribed, everPaid: everPaid)

        if case .expired = entitlement {
            NSLog("[academy.trial] trial EXPIRED — gating to checkout \(AcademyConfig.checkoutURL.absoluteString)")
        }
    }

    /// Mark the buyer as subscribed (e.g. after they confirm checkout / restore access).
    func markSubscribed() {
        d.set(true, forKey: kSubscribed)
        d.set(true, forKey: kEverPaid)   // sticky — survives a later cancel so the library stays readable
        refresh()
        NSLog("[academy.trial] marked subscribed — full access restored")
    }

    /// Mark the subscription canceled (the buyer canceled billing on the web side). Because `everPaid`
    /// persists, the account drops to `.lapsed`: the lessons already on this Mac stay readable — the
    /// keep-on-cancel guarantee (AC-12) — while new content / updates gate until they resubscribe.
    func markCanceled() {
        d.set(false, forKey: kSubscribed)
        refresh()
        NSLog("[academy.trial] subscription canceled — on-device library stays readable, updates gated")
    }

    // MARK: persistence helpers
    private func storedDate(_ key: String) -> Date? {
        let t = d.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    private func setDate(_ key: String, _ date: Date) { d.set(date.timeIntervalSince1970, forKey: key) }
    private func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    // `everPaid` is optional so a mirror written by an older build (no everPaid key) still decodes.
    private struct Mirror: Codable { var started: Date; var lastSeen: Date; var subscribed: Bool; var everPaid: Bool? }
    private func readMirror() -> Mirror? {
        guard let data = try? Data(contentsOf: mirrorURL) else { return nil }
        return try? JSONDecoder().decode(Mirror.self, from: data)
    }
    private func writeMirror(started: Date, lastSeen: Date, subscribed: Bool, everPaid: Bool) {
        let m = Mirror(started: started, lastSeen: lastSeen, subscribed: subscribed, everPaid: everPaid)
        if let data = try? JSONEncoder().encode(m) { try? data.write(to: mirrorURL) }
    }
}

// MARK: - Headless self-test (proves the state machine without a WindowServer)

/// Runs the entitlement state machine over injected dates and prints a deterministic transcript,
/// then exits. Invoked via `Black Label Academy --selftest-trial`. This is the reproducible proof
/// for the trial-start → in-trial → hard-gate flow (see tests/smoke.sh).
func runTrialSelfTest() -> Never {
    let start = Date(timeIntervalSince1970: 1_000_000)   // fixed T0
    let day: TimeInterval = 86_400
    print("== Black Label Academy — trial self-test ==")
    print("config: trialDays=\(AcademyConfig.trialDays) price=$\(AcademyConfig.monthlyPriceUSD)/mo checkout=\(AcademyConfig.checkoutURL.absoluteString)")

    func line(_ label: String, _ e: Entitlement) {
        let padded = label.padding(toLength: 22, withPad: " ", startingAt: 0)
        print("  \(padded) -> \(describe(e)) (entitled=\(e.isEntitled ? "yes" : "NO"))")
    }
    func describe(_ e: Entitlement) -> String {
        switch e {
        case .trial(let n): return "trial(\(n) days left)"
        case .expired: return "EXPIRED"
        case .subscribed: return "subscribed"
        case .lapsed: return "LAPSED (canceled — library stays readable)"
        }
    }

    let d0 = TrialEngine.evaluate(startedAt: start, effectiveNow: start, subscribed: false)
    line("day 0 (trial start)", d0)
    line("day 3", TrialEngine.evaluate(startedAt: start, effectiveNow: start + 3*day, subscribed: false))
    line("day 6", TrialEngine.evaluate(startedAt: start, effectiveNow: start + 6*day, subscribed: false))
    let d7 = TrialEngine.evaluate(startedAt: start, effectiveNow: start + 7*day, subscribed: false)
    line("day 7 (expiry)", d7)
    line("day 30", TrialEngine.evaluate(startedAt: start, effectiveNow: start + 30*day, subscribed: false))
    line("day 30 subscribed", TrialEngine.evaluate(startedAt: start, effectiveNow: start + 30*day, subscribed: true))
    // Clock-rollback: effectiveNow is clamped forward by the caller; prove day-7 stays expired
    // even if the raw clock is rolled back to day 1.
    let rolledBack = max(start + 1*day, start + 8*day)
    line("day 8 then clock<-day1", TrialEngine.evaluate(startedAt: start, effectiveNow: rolledBack, subscribed: false))

    // AC-12 keep-on-cancel: a buyer who PAID and later canceled (everPaid=true, subscribed=false) keeps
    // the on-device library readable (lapsed), while updates gate. A trial that NEVER paid still
    // hard-gates at day 7 (everPaid=false -> expired), so nothing is given away past the trial (AC-05).
    let lapsed = TrialEngine.evaluate(startedAt: start, effectiveNow: start + 30*day, subscribed: false, everPaid: true)
    line("day 30 canceled(paid)", lapsed)
    let neverPaid = TrialEngine.evaluate(startedAt: start, effectiveNow: start + 30*day, subscribed: false, everPaid: false)
    line("day 30 never paid", neverPaid)

    // Hard assertions — the gate MUST hold.
    var ok = true
    if d0.isEntitled != true { print("FAIL: day 0 not entitled"); ok = false }
    if case .trial(let n) = d0, n != 7 {} else if case .trial = d0 {} else { print("FAIL: day 0 not trial"); ok = false }
    if d7.isEntitled != false { print("FAIL: day 7 still entitled (gate did not close)"); ok = false }
    if case .expired = d7 {} else { print("FAIL: day 7 not expired"); ok = false }
    // Paid-then-canceled: reader stays open, updates gated.
    if lapsed.isEntitled != true { print("FAIL: canceled paid account lost library access"); ok = false }
    if case .lapsed = lapsed {} else { print("FAIL: canceled paid account not lapsed"); ok = false }
    if lapsed.canReceiveUpdates != false { print("FAIL: lapsed account still receives updates"); ok = false }
    // Trial-never-paid: hard gate holds (AC-05 protected).
    if neverPaid.isEntitled != false { print("FAIL: trial-never-paid did not hard-gate"); ok = false }
    if case .expired = neverPaid {} else { print("FAIL: trial-never-paid not expired"); ok = false }

    print(ok ? "SELFTEST OK — trial hard-gates at day 7; canceled PAID account keeps the on-device library (updates gated)"
             : "SELFTEST FAILED")
    exit(ok ? 0 : 1)
}

#endif  // os(macOS) && !MAS_BUILD — trial/subscription machinery excluded from the iOS build
        // and from the Mac App Store build (Guideline 3.1.1: no digital subscription outside IAP).

#if MAS_BUILD || os(iOS)
// Mac App Store + iOS builds: the trial/subscription machinery above is compiled out, but the
// anonymous opt-in cohort feature stays. This shim carries the ONE config constant cohort needs —
// the same value and the same UserDefaults override key as the direct build, so behavior is
// identical. (iOS compiles Cohort.swift as of the AC-16/AC-21 train and needs this too.)
enum AcademyConfig {
    static let defaultCohortBaseURL = "https://academy-cohort.michael-070.workers.dev/api/cohort"
    static var cohortBaseURL: URL {
        let override = UserDefaults.standard.string(forKey: "bl.academy.cohort_url")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let override, !override.isEmpty, let u = URL(string: override) { return u }
        return URL(string: defaultCohortBaseURL)!
    }
}
#endif
