// App state. Academy is a 7-day free trial → $30/mo subscription (founder decision 2026-07-08):
// the full library is readable during the trial; on expiry a hard gate routes to checkout.
import Foundation
import CircuitPortKit
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
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

enum Pillar: String, CaseIterable, Identifiable {
    case niches, money, operations, ai, failures, wisdom, creators
    var id: String { rawValue }
    var title: String {
        switch self {
        case .niches: return "Niches"
        case .money: return "Money"
        case .operations: return "Operations"
        case .ai: return "AI Mastery"
        case .failures: return "Our Failures"
        case .wisdom: return "Wisdom"
        case .creators: return "Creator Lessons"
        }
    }
    var subtitle: String {
        switch self {
        case .niches: return "100 markets, sized & sourced"
        case .money: return "P&L, pricing, cash — the owner's floor"
        case .operations: return "Taxes, LLCs, the real mechanics"
        case .ai: return "Use AI to do the work"
        case .failures: return "What we got wrong — and the fix"
        case .wisdom: return "The canon, applied to business"
        case .creators: return "The gurus, distilled"
        }
    }
    var icon: String {
        switch self {
        case .niches: return "chart.line.uptrend.xyaxis"
        case .money: return "dollarsign.circle"
        case .operations: return "doc.text"
        case .ai: return "brain.head.profile"
        case .failures: return "exclamationmark.triangle"
        case .wisdom: return "book.closed"
        case .creators: return "play.rectangle.on.rectangle"
        }
    }
}

enum LibrarySection: Hashable, Identifiable {
    case newThisMonth
    case pillar(Pillar)

    var id: String {
        switch self {
        case .newThisMonth: return "new-this-month"
        case .pillar(let pillar): return pillar.rawValue
        }
    }

    var title: String {
        switch self {
        case .newThisMonth: return "New This Month"
        case .pillar(let pillar): return pillar.title
        }
    }

    var subtitle: String {
        switch self {
        case .newThisMonth: return "Latest active lessons"
        case .pillar(let pillar): return pillar.subtitle
        }
    }

    var icon: String {
        switch self {
        case .newThisMonth: return "sparkles"
        case .pillar(let pillar): return pillar.icon
        }
    }
}

struct LessonProgress: Equatable {
    var completed: Bool = false
    var bookmarked: Bool = false
    var notes: String = ""
    var updatedAt: String = ""
}

@MainActor
final class AppModel: ObservableObject {
    @Published var entries: [Entry] = []
    @Published var query: String = ""
    @Published private(set) var progress: [String: LessonProgress] = [:]
    /// Entry id of the last lesson the reader opened, persisted across launches (resume-last-lesson).
    @Published private(set) var lastOpenedID: String?
    /// The buyer-typed name printed on completion certificates, persisted locally (never leaves the
    /// device). Empty until the buyer types it in the Certificates sheet.
    @Published private(set) var learnerName: String = ""
    private let progressDB = ProgressDB()

    /// AC-19 spaced-repetition recall deck. Its cards are generated ONLY from the library's compiled,
    /// provenance-gated `entry_checkpoints` (H6: no card can assert an uncited figure). Drives the
    /// Daily Review surface; the schedule persists locally the same way progress + the trial clock do.
    let recall: RecallDeck

    /// AC-21 owned, honest study habit: a self-set streak (grows ONLY on real completed Daily Review
    /// sessions from the recall deck), a "due today" surface backed by the real scheduler, and the
    /// snapshot a WidgetKit widget / App Intent reads. no betting, no ranking vs. others (founder de-risk).
    let habit: StudyHabit

    /// Trial + subscription entitlement (founder decision 2026-07-08: 7-day free trial → $30/mo).
    /// The trial clock starts on first run; access is gated app-wide by `isEntitled`.
    /// macOS-only: the iOS build ships the full library FREE (App Store Guideline 3.1.1), so it
    /// carries no trial/subscription state, no entitlement gate, and no checkout at all.
    #if os(macOS) && !MAS_BUILD
    let trial = TrialStore()

    /// Full access is granted during the trial window or once subscribed; otherwise the reader is
    /// replaced by the paywall gate. (Replaces the old always-true `unlocked`.)
    var isEntitled: Bool { trial.isEntitled }
    var entitlement: Entitlement { trial.entitlement }
    #endif

    #if os(iOS) || MAS_BUILD
    /// b21: StoreKit 2 auto-renewable subscription (App Store Connect product
    /// `com.blacklabel.academy.full.monthly`, group "Academy Full Access"). The iOS build sells
    /// the full library THROUGH StoreKit (3.1.1); the freemium tier below stays genuinely useful
    /// so the app is never a hollow shell (4.2.2 posture). No free trial (founder rule 07-21).
    /// b102: the Mac App Store build (MAS_BUILD) sells the SAME app-level subscription through the
    /// SAME StoreKit code — one product, one price, both platforms. Only the Developer-ID macOS
    /// build keeps the separate Stripe trial in Trial.swift.
    let store = AcademyStore()

    var isSubscribed: Bool { store.isSubscribed }

    /// Free-forever lesson ids, derived from the compiled library — never a hardcoded list:
    /// the FIRST lesson of every pillar (library display order) plus the entire New This Month
    /// section. Deterministic for a given content build.
    var freeLessonIDs: Set<String> {
        var ids = Set(newThisMonthEntries.map(\.id))
        for pillar in Pillar.allCases {
            if let first = entries(for: pillar).first { ids.insert(first.id) }
        }
        return ids
    }

    /// The single access question. Subscribed unlocks everything; otherwise only the free set.
    func isUnlocked(_ entry: Entry) -> Bool {
        store.isSubscribed || freeLessonIDs.contains(entry.id)
    }
    func isLocked(_ entry: Entry) -> Bool { !isUnlocked(entry) }

    /// The lessons the native tools operate over: everything when subscribed, the free set
    /// otherwise. Keeps Daily Review / the Tutor honest — they never surface (or leak the
    /// sourced figures of) a lesson the reader cannot open.
    var accessibleEntries: [Entry] {
        store.isSubscribed ? entries : entries.filter { freeLessonIDs.contains($0.id) }
    }

    /// Recall cards scoped to accessible lessons (all cards when subscribed).
    var accessibleRecallCards: [RecallCard] {
        store.isSubscribed ? recall.cards : recall.cards.filter { freeLessonIDs.contains($0.entryID) }
    }
    /// The Daily Review queue scoped the same way — due cards from accessible lessons only.
    var accessibleDueCards: [RecallCard] {
        store.isSubscribed ? recall.dueCards : recall.dueCards.filter { freeLessonIDs.contains($0.entryID) }
    }
    #endif

    private var cancellables = Set<AnyCancellable>()

    init() {
        let loaded = ContentDB.load()
        entries = loaded
        let deck = RecallDeck(entries: loaded)
        recall = deck
        habit = StudyHabit(deck: deck)
        progress = progressDB.load()
        lastOpenedID = progressDB.loadLastOpened()
        learnerName = progressDB.loadMeta("learner_name") ?? ""
        // Re-emit when the recall deck grades a card so the Daily Review badge/queue refresh.
        recall.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Re-emit when the study habit updates (a completed review / freeze change) so the streak chip
        // and "due today" surface refresh.
        habit.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        #if os(macOS) && !MAS_BUILD
        // Re-emit when the nested trial store changes so gated views refresh.
        trial.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        #endif
        #if os(iOS) || MAS_BUILD
        // Re-emit when the StoreKit store changes (purchase, restore, renewal, product load) so
        // lock badges, the paywall, and the access banner refresh.
        store.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        #endif
    }

    func entries(for pillar: Pillar) -> [Entry] {
        entries.filter { $0.pillar == pillar.rawValue }
    }

    func entries(for section: LibrarySection) -> [Entry] {
        switch section {
        case .newThisMonth: return newThisMonthEntries
        case .pillar(let pillar): return entries(for: pillar)
        }
    }

    func count(_ pillar: Pillar) -> Int { entries(for: pillar).count }
    func count(_ section: LibrarySection) -> Int { entries(for: section).count }
    var totalCount: Int { entries.count }

    // MARK: - Provenance receipts (computed live from the bundled, lint-gated library — never hardcoded)
    // The content DB the app bundles is produced ONLY by the provenance-lint-gated compile
    // (tools/academy: an unsourced figure aborts the build), so every shipped entry already passed
    // the lint. These properties re-derive the trust numbers at runtime from the loaded entries so
    // the buy-surface badge can never drift from the actual library (§5.1: no fabricated figure,
    // even in UI chrome — this is why we do NOT reintroduce the old "234/6" hardcode).

    /// Lessons whose figures satisfy the runtime provenance invariant that mirrors the build lint:
    /// every metric carries EXACTLY ONE of a source or an estimate_method. A prose lesson with no
    /// numeric metrics trivially passes (nothing to source). Equals `totalCount` for a correctly
    /// gated bundle; would drop below it — and expose the badge — if an unlinted entry ever slipped in.
    var provenancePassCount: Int {
        entries.filter { entry in
            entry.metrics.allSatisfy { ($0.source != nil) != ($0.estimateMethod != nil) }
        }.count
    }

    /// Lessons that cite at least one linked primary source (the strongest, non-trivial receipt).
    var sourcedCount: Int { entries.filter { !$0.sources.isEmpty }.count }

    /// Total linked sources across the whole library.
    var totalSourceCount: Int { entries.reduce(0) { $0 + $1.sources.count } }

    var completedCount: Int { progress.values.filter(\.completed).count }
    func completedCount(for section: LibrarySection) -> Int {
        entries(for: section).filter { isCompleted($0) }.count
    }

    var newestContentMonth: String? {
        entries.compactMap { entry in
            entry.lastUpdated.count >= 7 ? String(entry.lastUpdated.prefix(7)) : nil
        }.max()
    }

    var newThisMonthEntries: [Entry] {
        guard let month = newestContentMonth else { return [] }
        return entries
            .filter { $0.lastUpdated.hasPrefix(month) }
            .sorted {
                if $0.lastUpdated == $1.lastUpdated { return $0.title < $1.title }
                return $0.lastUpdated > $1.lastUpdated
            }
    }

    func progress(for entry: Entry) -> LessonProgress {
        progress[entry.id] ?? LessonProgress()
    }

    /// Record the lesson the reader just opened so the next launch can resume it. Persisted to the
    /// local progress DB; ignored if the id isn't in the current library (stale/removed entry).
    func recordOpened(_ entry: Entry) {
        #if os(iOS) || MAS_BUILD
        // b21: a locked lesson's tap lands on the paywall, not the reader — recording it would
        // make the next launch "resume" into a gate and lie about the last lesson read.
        guard isUnlocked(entry) else { return }
        #endif
        guard lastOpenedID != entry.id else { return }
        lastOpenedID = entry.id
        progressDB.saveLastOpened(entry.id)
    }

    /// The entry to auto-select on launch (resume-last-lesson): the last opened lesson if it still
    /// exists in the library, else nil (fall back to the empty state).
    var resumeEntry: Entry? {
        guard let id = lastOpenedID else { return nil }
        return entries.first { $0.id == id }
    }

    /// Update and locally persist the name printed on completion certificates.
    func setLearnerName(_ name: String) {
        learnerName = name
        progressDB.saveMeta("learner_name", name)
    }

    func isCompleted(_ entry: Entry) -> Bool {
        progress(for: entry).completed
    }

    func isBookmarked(_ entry: Entry) -> Bool {
        progress(for: entry).bookmarked
    }

    func toggleCompleted(_ entry: Entry) {
        var next = progress(for: entry)
        next.completed.toggle()
        save(next, for: entry)
    }

    func toggleBookmark(_ entry: Entry) {
        var next = progress(for: entry)
        next.bookmarked.toggle()
        save(next, for: entry)
    }

    func updateNotes(_ entry: Entry, _ notes: String) {
        var next = progress(for: entry)
        next.notes = notes
        save(next, for: entry)
    }

    var searchResults: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return entries.filter {
            $0.title.lowercased().contains(q)
            || $0.body.lowercased().contains(q)
            || $0.tags.contains { $0.lowercased().contains(q) }
        }
    }

    private func save(_ next: LessonProgress, for entry: Entry) {
        var copy = next
        copy.updatedAt = Self.timestamp()
        progress[entry.id] = copy
        progressDB.save(copy, entryID: entry.id)
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}

final class ProgressDB {
    private let path: String

    /// Default init writes to Application Support. `path:` is an injectable override so the
    /// resume/round-trip flow can be proven headlessly against a temp DB (see `--selftest-resume`).
    init(path: String? = nil) {
        if let path {
            self.path = path
            return
        }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("BlackLabelAcademy", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent("learner-progress.sqlite").path
    }

    func load() -> [String: LessonProgress] {
        guard let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        migrate(db)

        var rows: [String: LessonProgress] = [:]
        var st: OpaquePointer?
        let sql = "SELECT entry_id, completed, bookmarked, notes, updated_at FROM lesson_progress"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(st) }

        while sqlite3_step(st) == SQLITE_ROW {
            let id = text(st, 0)
            rows[id] = LessonProgress(
                completed: sqlite3_column_int(st, 1) == 1,
                bookmarked: sqlite3_column_int(st, 2) == 1,
                notes: text(st, 3),
                updatedAt: text(st, 4)
            )
        }
        return rows
    }

    func save(_ progress: LessonProgress, entryID: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        migrate(db)

        let sql = """
        INSERT INTO lesson_progress (entry_id, completed, bookmarked, notes, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(entry_id) DO UPDATE SET
          completed = excluded.completed,
          bookmarked = excluded.bookmarked,
          notes = excluded.notes,
          updated_at = excluded.updated_at
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }

        bind(st, 1, entryID)
        sqlite3_bind_int(st, 2, progress.completed ? 1 : 0)
        sqlite3_bind_int(st, 3, progress.bookmarked ? 1 : 0)
        bind(st, 4, progress.notes)
        bind(st, 5, progress.updatedAt)
        sqlite3_step(st)
    }

    /// Persist a single key/value fact. Same DB, tiny meta table.
    func saveMeta(_ key: String, _ value: String) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        migrate(db)
        let sql = """
        INSERT INTO meta (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        bind(st, 1, key)
        bind(st, 2, value)
        sqlite3_step(st)
    }

    func loadMeta(_ key: String) -> String? {
        guard let db = open() else { return nil }
        defer { sqlite3_close(db) }
        migrate(db)
        var st: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        bind(st, 1, key)
        guard sqlite3_step(st) == SQLITE_ROW else { return nil }
        let v = text(st, 0)
        return v.isEmpty ? nil : v
    }

    /// Convenience wrappers for the last-opened lesson id (resume-last-lesson).
    func saveLastOpened(_ entryID: String) { saveMeta("last_opened_entry", entryID) }
    func loadLastOpened() -> String? { loadMeta("last_opened_entry") }

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
        CREATE TABLE IF NOT EXISTS lesson_progress (
          entry_id TEXT PRIMARY KEY,
          completed INTEGER NOT NULL DEFAULT 0,
          bookmarked INTEGER NOT NULL DEFAULT 0,
          notes TEXT NOT NULL DEFAULT '',
          updated_at TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS meta (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL DEFAULT ''
        );
        PRAGMA user_version = 2;
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func text(_ st: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }

    private func bind(_ st: OpaquePointer?, _ i: Int32, _ value: String) {
        sqlite3_bind_text(st, i, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}

// MARK: - Headless self-test for resume-last-lesson (proves persistence without a WindowServer)

/// Round-trips the last-opened entry id through a fresh on-disk ProgressDB and asserts a *second*
/// ProgressDB reopening the same file reads it back — the exact flow behind resume-last-lesson.
/// Invoked via `Black Label Academy --selftest-resume`; wired into tests/smoke.sh as reproducible proof.
func runResumeSelfTest() -> Never {
    print("== Black Label Academy — resume-last-lesson self-test ==")
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("bl-academy-resume-\(ProcessInfo.processInfo.processIdentifier).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }

    var ok = true
    let writer = ProgressDB(path: tmp.path)
    // 1. Nothing opened yet -> no resume target.
    if writer.loadLastOpened() != nil { print("FAIL: fresh DB already has a last-opened id"); ok = false }
    // 2. Record an opened lesson, then reopen the file with a SECOND handle (simulates next launch).
    let sample = "niches-pressure-washing"
    writer.saveLastOpened(sample)
    let reader = ProgressDB(path: tmp.path)
    let got = reader.loadLastOpened()
    print("  wrote last-opened=\(sample) -> reopened DB read=\(got ?? "nil")")
    if got != sample { print("FAIL: reopened DB did not resume the last-opened lesson"); ok = false }
    // 3. Overwrite -> most recent wins (single-row upsert, not append).
    writer.saveLastOpened("money-owner-pay")
    if ProgressDB(path: tmp.path).loadLastOpened() != "money-owner-pay" {
        print("FAIL: last-opened did not update to the most recent lesson"); ok = false
    }

    print(ok ? "RESUME SELFTEST OK — last-opened lesson persists and is restored on next launch"
             : "RESUME SELFTEST FAILED")
    exit(ok ? 0 : 1)
}
