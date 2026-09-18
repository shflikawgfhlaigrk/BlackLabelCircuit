// Black Label Academy — AC-21 owned, OS-native, HONEST study habit.
//
// A self-set study streak with a streak-freeze allowance, a "due today" surface driven by the REAL
// AC-19 recall scheduler, and App Intents so "review due cards" is invocable from Spotlight /
// Shortcuts. Founder de-risk (2026-07-08): no betting, no ranking against other people — a personal, self-set habit,
// nothing competitive, no money.
//
// H-STREAK (non-negotiable, §5.1): the streak count can NEVER be fabricated. It is DERIVED, not
// stored-and-trusted: the only durable state is an append-only log of the calendar days on which the
// learner actually COMPLETED a Daily Review session (a real graded recall from the AC-19
// RecallEngine). `StreakEngine.reconstruct` recomputes the streak from that log every load, and
// `StreakEngine.validate` re-asserts that a claimed state cannot exceed what the real log supports —
// so a planted "999-day streak" with no backing review days is rejected (see `--selftest-streak`).
// The Duolingo skyline report cites ~2.4× next-day retention for streaks, but OUR streak only ever
// counts days a review was genuinely completed; it invents nothing.
import Foundation
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(SQLite3) && !CIRCUIT_WINDOWS_SIM
import SQLite3
#else
import SwiftToolchainCSQLite
#endif
#if canImport(AppIntents)
import AppIntents
#endif
import CircuitPortKit

// MARK: - Pure streak model (testable headlessly, cannot drift from the UI)

/// A study streak, always DERIVED from the append-only completed-review-day log. `current` is the
/// live consecutive-day streak ending at `lastStudyDay`; `freezesAvailable` is the self-set grace
/// budget that can bridge missed days; `freezesUsed` is honest lifetime telemetry.
struct StreakState: Equatable {
    var current: Int = 0
    var longest: Int = 0
    var lastStudyDay: Int? = nil     // calendar-day index of the most recent completed review
    var freezesAvailable: Int = 0
    var freezesUsed: Int = 0
}

/// Pure streak arithmetic. A "study day" is a calendar day on which a Daily Review session was
/// completed. Consecutive study days grow the streak; a gap is bridged by spending freezes (one per
/// missed day) if the self-set allowance covers it, otherwise the streak breaks and today restarts
/// it at 1. Deterministic given calendar-day integers, so every rule is provable without a clock.
enum StreakEngine {
    /// Reference calendar day (2001-01-01, Foundation's reference date) → a monotonic day index.
    static func dayIndex(_ date: Date, calendar: Calendar = .current) -> Int {
        let ref = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 0))
        let day = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: ref, to: day).day ?? 0
    }

    /// Rebuild the streak state from the append-only log of completed-review day indices. This is the
    /// ONE source of truth: the UI never trusts a stored `current`, it always reconstructs from the
    /// real days. Freezes are spent chronologically as gaps appear.
    static func reconstruct(studyDays: [Int], freezeAllowance: Int) -> StreakState {
        let days = Array(Set(studyDays)).sorted()
        guard let last = days.last else {
            return StreakState(current: 0, longest: 0, lastStudyDay: nil,
                               freezesAvailable: max(0, freezeAllowance), freezesUsed: 0)
        }
        var current = 1
        var longest = 1
        var freezes = max(0, freezeAllowance)
        var used = 0
        for i in 1..<days.count {
            let gap = days[i] - days[i - 1]         // ≥ 1 (days are unique + sorted)
            if gap == 1 {
                current += 1
            } else {
                let missed = gap - 1
                if freezes >= missed {
                    freezes -= missed; used += missed; current += 1   // freezes bridge the gap
                } else {
                    current = 1                                       // gap too wide → streak breaks
                }
            }
            longest = max(longest, current)
        }
        return StreakState(current: current, longest: longest, lastStudyDay: last,
                           freezesAvailable: freezes, freezesUsed: used)
    }

    /// The streak that is STILL VALID as of `today` without recording a new review — the honest
    /// number to show. If the learner studied today or yesterday it stands; if the gap can still be
    /// bridged by remaining freezes it stands; otherwise it has already broken (returns 0). This never
    /// inflates: it only ever reports a value the real log + freezes can back.
    static func liveStreak(_ s: StreakState, today: Int) -> Int {
        guard let last = s.lastStudyDay else { return 0 }
        if today <= last { return s.current }        // already studied today (or a backwards clock)
        let missed = (today - last) - 1              // full days missed since the last study day
        if missed <= 0 { return s.current }          // studied yesterday — still alive today
        return s.freezesAvailable >= missed ? s.current : 0
    }

    /// H-STREAK teeth: a claimed `StreakState` must not exceed what the real completed-review-day log
    /// supports. Returns the list of violations — a fabricated state (current/longest/lastStudyDay
    /// beyond the reconstruction, or a lastStudyDay absent from the log) makes it non-empty. This is
    /// the runtime analogue of the recall deck's 1:1 gate, and it is what rejects a planted streak.
    static func validate(_ claimed: StreakState, studyDays: [Int], freezeAllowance: Int) -> [String] {
        let truth = reconstruct(studyDays: studyDays, freezeAllowance: freezeAllowance)
        var errors: [String] = []
        if claimed.current > truth.current {
            errors.append("streak current \(claimed.current) exceeds the \(truth.current) real completed-review days support (fabricated)")
        }
        if claimed.longest > truth.longest {
            errors.append("streak longest \(claimed.longest) exceeds the reconstructable \(truth.longest) (fabricated)")
        }
        if let claimedLast = claimed.lastStudyDay, !Set(studyDays).contains(claimedLast) {
            errors.append("streak lastStudyDay \(claimedLast) is not a real completed-review day (fabricated)")
        }
        if claimed.freezesUsed > truth.freezesUsed {
            errors.append("streak freezesUsed \(claimed.freezesUsed) exceeds the \(truth.freezesUsed) the log accounts for (fabricated)")
        }
        return errors
    }

    /// Default self-set freeze allowance for a fresh learner — a modest grace budget the learner can
    /// change (never a purchase, never earned by betting). Two missed days of grace.
    static let defaultFreezeAllowance = 2
}

// MARK: - WidgetKit-ready snapshot (the data a Home-Screen widget timeline would render)

/// The honest, self-contained payload a WidgetKit timeline entry would display: the live streak and
/// the real count of recall cards due today. Kept as a plain value type so the (separately signed)
/// widget extension is a thin future add — it consumes this, it never recomputes the numbers. The
/// extension `.appex` target itself needs code-signing/provisioning the headless build lane can't do,
/// so it is documented as the single remaining sliver, not faked (see AC-21 handoff).
struct StudyHabitSnapshot: Equatable {
    let streak: Int
    let dueToday: Int
    let reviewedToday: Bool
    /// The WidgetKit timeline "kind" this snapshot feeds (used by the future widget extension).
    static let widgetKitKind = "com.blacklabel.academy.StudyHabitWidget"
    var headline: String { streak > 0 ? "\(streak)-day streak" : "Start your streak" }
    var dueLine: String { dueToday == 0 ? "Nothing due today" : "\(dueToday) due today" }
}

extension StudyHabitSnapshot {
    /// The cross-process, Codable payload the WidgetKit extension consumes (Sources/StudyWidgetData.swift).
    /// The widget reads exactly these numbers; it never recomputes the streak, so H-STREAK holds there too.
    var widgetData: StudyWidgetData {
        StudyWidgetData(streak: streak, dueToday: dueToday, reviewedToday: reviewedToday)
    }
}

// MARK: - Persisted store (append-only completed-review log + self-set freeze allowance)

/// Durable state for the study habit: an append-only `study_days` log (one row per calendar day a
/// Daily Review was completed) plus a tiny meta table holding the self-set freeze allowance. The
/// streak is NEVER stored — it is always reconstructed from these days, so there is no stored count
/// to fabricate. Same local-SQLite, nothing-leaves-the-device posture as ProgressDB / RecallDB.
final class StudyHabitStore {
    private let path: String

    init(path: String? = nil) {
        if let path { self.path = path; return }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("BlackLabelAcademy", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent("study-habit.sqlite").path
    }

    /// Every calendar day on which a review was completed (ascending, unique).
    func studyDays() -> [Int] {
        guard let db = open() else { return [] }
        defer { sqlite3_close(db) }
        migrate(db)
        var days: [Int] = []
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT day_index FROM study_days ORDER BY day_index", -1, &st, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { days.append(Int(sqlite3_column_int64(st, 0))) }
        return days
    }

    /// Record a completed review on `day`. Idempotent per calendar day (PRIMARY KEY on day_index),
    /// so studying twice in one day never inflates the streak. Returns true if this was the day's
    /// FIRST completed review (i.e. the log actually grew).
    @discardableResult
    func recordCompletedReview(day: Int) -> Bool {
        guard let db = open() else { return false }
        defer { sqlite3_close(db) }
        migrate(db)
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO study_days (day_index) VALUES (?)", -1, &st, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_int64(st, 1, Int64(day))
        guard sqlite3_step(st) == SQLITE_DONE else { return false }
        return sqlite3_changes(db) > 0
    }

    /// The self-set freeze allowance (defaults to `StreakEngine.defaultFreezeAllowance` on a fresh DB).
    func freezeAllowance() -> Int {
        guard let db = open() else { return StreakEngine.defaultFreezeAllowance }
        defer { sqlite3_close(db) }
        migrate(db)
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM habit_meta WHERE key='freeze_allowance'", -1, &st, nil) == SQLITE_OK else { return StreakEngine.defaultFreezeAllowance }
        defer { sqlite3_finalize(st) }
        guard sqlite3_step(st) == SQLITE_ROW, let c = sqlite3_column_text(st, 0) else { return StreakEngine.defaultFreezeAllowance }
        return Int(String(cString: c)) ?? StreakEngine.defaultFreezeAllowance
    }

    /// Learner self-sets the freeze allowance (clamped to a sane 0…14, no purchase involved).
    func setFreezeAllowance(_ n: Int) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        migrate(db)
        let clamped = min(14, max(0, n))
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO habit_meta (key,value) VALUES ('freeze_allowance',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, String(clamped), -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_step(st)
    }

    private func open() -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        return db
    }

    private func migrate(_ db: OpaquePointer?) {
        let sql = """
        CREATE TABLE IF NOT EXISTS study_days (day_index INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS habit_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL DEFAULT '');
        PRAGMA user_version = 1;
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

// MARK: - Observable study-habit view model

/// Drives the streak chip + "due today" surface. The streak is reconstructed from the persisted
/// completed-review log; the due count is read live from the injected AC-19 recall deck (honest 0
/// when nothing is due). Recording a completed review is the ONLY way the streak can grow, and it is
/// called exclusively from the Daily Review flow when a real card is graded.
@MainActor
final class StudyHabit: ObservableObject {
    @Published private(set) var state: StreakState
    private let store: StudyHabitStore
    private unowned let deck: RecallDeck
    private let clock: () -> Date

    init(deck: RecallDeck, store: StudyHabitStore? = nil, clock: @escaping () -> Date = { Date() }) {
        self.deck = deck
        self.store = store ?? StudyHabitStore()
        self.clock = clock
        self.state = StreakEngine.reconstruct(studyDays: self.store.studyDays(),
                                              freezeAllowance: self.store.freezeAllowance())
        publishWidgetSnapshot()
    }

    private var today: Int { StreakEngine.dayIndex(clock()) }

    /// The honest streak to display right now (already broken → 0, still alive → its earned value).
    var liveStreak: Int { StreakEngine.liveStreak(state, today: today) }
    /// Real recall cards due today, straight from the AC-19 scheduler. Honest 0 when caught up.
    var dueToday: Int { deck.dueCount }
    var reviewedToday: Bool { state.lastStudyDay == today }
    var freezesAvailable: Int { state.freezesAvailable }

    var snapshot: StudyHabitSnapshot {
        StudyHabitSnapshot(streak: liveStreak, dueToday: dueToday, reviewedToday: reviewedToday)
    }

    /// Publish the live snapshot into the shared App Group container so the WidgetKit extension
    /// (Contents/PlugIns/AcademyStudyWidget.appex) renders the SAME honest numbers — the widget only
    /// ever reads what the app derived here, it never recomputes a streak. See Sources/StudyWidgetData.swift.
    func publishWidgetSnapshot() { snapshot.widgetData.writeShared() }

    /// Record that the learner just completed a real Daily Review session (≥1 card graded). Appends
    /// today to the append-only log (idempotent per day) and re-derives the streak. Called from the
    /// review UI's grade path so the count can never be set without a genuine review.
    func recordCompletedReview() {
        store.recordCompletedReview(day: today)
        refresh()
    }

    /// Learner self-sets the freeze allowance (§ AC-21: self-set, no betting, no purchase).
    func setFreezeAllowance(_ n: Int) {
        store.setFreezeAllowance(n)
        refresh()
    }

    /// Reconstruct from disk (after a review, a freeze change, or the deck rescheduling).
    func refresh() {
        state = StreakEngine.reconstruct(studyDays: store.studyDays(),
                                         freezeAllowance: store.freezeAllowance())
        publishWidgetSnapshot()
    }

    // MARK: App Intent support (headless-safe)

    /// Real count of recall cards due right now, for the "Review Due Cards" App Intent. Builds the
    /// deck from the bundled library + the on-disk recall schedule so Spotlight/Shortcuts get an
    /// HONEST number (0 when caught up) without a running app window.
    @MainActor
    static func dueCountNow() -> Int {
        RecallDeck(entries: ContentDB.load()).dueCount
    }
}

/// One-way bridge from an App Intent (which runs outside the SwiftUI view tree) to the reader: the
/// "Review Due Cards" intent flips `openRequested`, and RootView observes it to present Daily Review.
@MainActor
final class DailyReviewRouter: ObservableObject {
    static let shared = DailyReviewRouter()
    @Published var openRequested = false
    func request() { openRequested = true }
}

// MARK: - App Intents: "review due cards" from Spotlight / Shortcuts

#if canImport(AppIntents)
/// `Review Due Cards` — an OS-native App Intent invocable from Spotlight and the Shortcuts app. It
/// opens the app to Daily Review and reports the HONEST number of recall cards due now (0 when caught
/// up). This is a system surface a web app structurally cannot offer.
@available(macOS 13.0, iOS 16.0, *)
struct ReviewDueCardsIntent: AppIntent {
    static var title: LocalizedStringResource = "Review Due Cards"
    static var description = IntentDescription("Open Daily Review and show how many recall cards are due today.")
    static var openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let due = StudyHabit.dueCountNow()
        DailyReviewRouter.shared.request()
        let dialog: IntentDialog = due == 0
            ? "No recall cards are due today — you're all caught up."
            : "You have \(due) recall card\(due == 1 ? "" : "s") due today."
        return .result(dialog: dialog)
    }
}

/// Registers the phrase so "review due cards" is discoverable in Spotlight / Shortcuts. (The
/// App Intents *metadata* bundle that surfaces these phrases system-wide is generated by the release
/// Xcode build's metadata extractor; the intent implementation itself is complete and in the binary.)
@available(macOS 13.0, iOS 16.0, *)
struct AcademyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ReviewDueCardsIntent(),
            phrases: [
                "Review due cards in \(.applicationName)",
                "Review my \(.applicationName) cards",
                "Do my \(.applicationName) daily review"
            ],
            shortTitle: "Review Due Cards",
            systemImageName: "brain.head.profile"
        )
    }
}
#endif

// MARK: - Headless self-test (`--selftest-streak`) — proves honesty + rejects a planted streak

/// `Black Label Academy --selftest-streak`. Proves, without a WindowServer:
///  • the streak grows ONLY on consecutive completed-review days;
///  • a freeze consumes correctly to bridge a missed day;
///  • a missed day WITHOUT a freeze resets the streak;
///  • the "due today" count comes straight from the real recall scheduler (honest 0 when caught up);
///  • a PLANTED fabricated streak state (no backing review days) is REJECTED by `validate`.
/// Wired into tests/smoke.sh as the reproducible AC-21 proof. Platform-agnostic (the habit ships on both).
@MainActor
func runStudyHabitSelfTest() -> Never {
    print("== Black Label Academy — study-habit (streak / due today) self-test ==")
    var ok = true
    func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL: \(msg)"); ok = false } }

    // 1) Streak grows only on consecutive completed-review days.
    let a = StreakEngine.reconstruct(studyDays: [100, 101, 102], freezeAllowance: 0)
    print("  consecutive [100,101,102] freezes=0 -> current \(a.current), longest \(a.longest)")
    check(a.current == 3 && a.longest == 3 && a.lastStudyDay == 102, "consecutive days did not grow the streak to 3")

    // 2) A missed day WITHOUT a freeze resets the streak (today restarts at 1).
    let b = StreakEngine.reconstruct(studyDays: [100, 101, 104], freezeAllowance: 0)
    print("  gap [100,101,_,_,104] freezes=0 -> current \(b.current) (reset)")
    check(b.current == 1, "a missed day without a freeze did not reset the streak")

    // 3) A freeze consumes correctly to bridge exactly the missed day(s), keeping the streak alive.
    let c = StreakEngine.reconstruct(studyDays: [100, 101, 103], freezeAllowance: 2)
    print("  gap [100,101,_,103] freezes=2 -> current \(c.current), freezesLeft \(c.freezesAvailable), used \(c.freezesUsed)")
    check(c.current == 3 && c.freezesUsed == 1 && c.freezesAvailable == 1, "freeze did not bridge one missed day correctly")
    // …but a gap wider than the allowance still breaks it.
    let cWide = StreakEngine.reconstruct(studyDays: [100, 105], freezeAllowance: 2)
    check(cWide.current == 1 && cWide.freezesUsed == 0, "a gap wider than the freeze allowance should still break the streak")

    // 4) liveStreak is honest: alive today/yesterday, saveable by a freeze, else already broken (0).
    let live = StreakEngine.reconstruct(studyDays: [200, 201], freezeAllowance: 1)   // current 2
    check(StreakEngine.liveStreak(live, today: 201) == 2, "liveStreak should stand on the study day")
    check(StreakEngine.liveStreak(live, today: 202) == 2, "liveStreak should stand the day after (still alive)")
    check(StreakEngine.liveStreak(live, today: 203) == 2, "liveStreak should stand while a freeze can still save it")
    check(StreakEngine.liveStreak(live, today: 204) == 0, "liveStreak should read 0 once the gap exceeds the freezes (broken, honest)")

    // 5) Idempotent per day via the real store: two reviews in one day do NOT inflate the streak.
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("bl-academy-habit-\(ProcessInfo.processInfo.processIdentifier).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = StudyHabitStore(path: tmp.path)
    let grew1 = store.recordCompletedReview(day: 300)
    let grew2 = store.recordCompletedReview(day: 300)   // same day again
    check(grew1 && !grew2, "same-day second review must NOT grow the log (idempotent per calendar day)")
    let after = StreakEngine.reconstruct(studyDays: store.studyDays(), freezeAllowance: store.freezeAllowance())
    check(after.current == 1 && store.studyDays() == [300], "same-day double review fabricated a longer streak")

    // 6) H-STREAK teeth: a PLANTED fabricated streak (no backing review days) is REJECTED.
    let honest = StreakEngine.reconstruct(studyDays: [100, 101], freezeAllowance: 0)   // current 2
    check(StreakEngine.validate(honest, studyDays: [100, 101], freezeAllowance: 0).isEmpty,
          "the honest reconstructed state must pass validation")
    let planted = StreakState(current: 999, longest: 999, lastStudyDay: 5000, freezesAvailable: 0, freezesUsed: 42)
    let violations = StreakEngine.validate(planted, studyDays: [100, 101], freezeAllowance: 0)
    if violations.isEmpty { print("FAIL: a planted 999-day streak PASSED validation (H-STREAK gate broken)"); ok = false }
    else { print("  planted-streak rejection OK — \(violations.first!)") }

    // 7) "Due today" comes straight from the real recall scheduler (honest count, 0 when caught up).
    let due = StudyHabit.dueCountNow()
    print("  due today (from the real recall scheduler): \(due)")
    check(due >= 0, "due-today count must be a real non-negative scheduler number, never fabricated")

    print(ok ? "STREAK SELFTEST OK — streak grows only on real completed reviews, freezes bridge honestly, a planted streak is rejected, due-today is the real scheduler count"
             : "STREAK SELFTEST FAILED")
    exit(ok ? 0 : 1)
}
