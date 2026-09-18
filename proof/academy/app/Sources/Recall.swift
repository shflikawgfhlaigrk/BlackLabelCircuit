// Black Label Academy — AC-19 Recall Engine (spaced repetition + Daily Review).
//
// A recall deck of spaced-repetition cards, each derived 1:1 from a compiled, provenance-gated
// `entry_checkpoints` row. H6 (non-negotiable): a recall card can NEVER assert a figure the lesson
// does not source — its answer is verbatim a checkpoint's SOURCED inline figure and it always carries
// that figure's own http(s) citation. The build-time provenance lint already proved every checkpoint
// honest (tools/academy/checkpoints.py: an uncited answer aborts the build); this engine only ever
// surfaces those rows, and `RecallDeck.validate` re-asserts the 1:1 + sourced invariant at runtime so
// a planted card with no backing checkpoint row is rejected (see `--selftest-recall`).
//
// The scheduling math lives in `RecallEngine` as a PURE function so it is testable headlessly and
// cannot drift from the UI. State persists to a local SQLite table the same way learner progress and
// the trial clock persist — nothing leaves the device.
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
import CircuitPortKit

/// SM-2-lite spaced-repetition schedule for a single card. `reps` counts consecutive correct
/// recalls; a miss resets it. `ease` scales the interval growth; `dueAt` is when the card next
/// surfaces in Daily Review.
struct RecallSchedule: Equatable, Hashable {
    var reps: Int = 0
    var intervalDays: Int = 0
    var ease: Double = RecallEngine.startEase
    var dueAt: Date
}

/// One spaced-repetition recall card = one compiled checkpoint row + its schedule. The display fields
/// (prompt/answer/sourceURL) are copied verbatim from the `entry_checkpoints` row; the card renders
/// no figure that is not one the lesson sources (H6).
struct RecallCard: Identifiable, Hashable {
    let entryID: String
    let entryTitle: String
    let ord: Int
    let prompt: String
    let answer: String
    let sourceURL: String
    var schedule: RecallSchedule
    /// Stable identity of the backing checkpoint row (entry_id + ord).
    var id: String { "\(entryID)#\(ord)" }
}

/// Pure SM-2-lite scheduler. Correct recall grows the interval (1 → 3 → interval·ease days) and nudges
/// ease up; a miss resets the card to due-now and nudges ease down (floored). Deterministic given a
/// clock, so the schedule-advances / resets-on-miss behaviour is provable headlessly (--selftest-recall).
enum RecallEngine {
    static let startEase = 2.5
    static let minEase = 1.3
    static let maxEase = 3.0
    static let day: TimeInterval = 86_400

    static func grade(_ s: RecallSchedule, correct: Bool, now: Date) -> RecallSchedule {
        var next = s
        if correct {
            next.reps = s.reps + 1
            switch next.reps {
            case 1:  next.intervalDays = 1
            case 2:  next.intervalDays = 3
            default: next.intervalDays = max(1, Int((Double(s.intervalDays) * s.ease).rounded()))
            }
            next.ease = min(maxEase, s.ease + 0.1)
        } else {
            next.reps = 0
            next.intervalDays = 0            // due again today — a missed card comes straight back
            next.ease = max(minEase, s.ease - 0.2)
        }
        next.dueAt = now.addingTimeInterval(Double(next.intervalDays) * day)
        return next
    }
}

/// The recall deck: builds cards ONLY from the library's compiled checkpoints, merges any persisted
/// schedule, exposes the Daily Review queue, and grades. `@MainActor` because it is an ObservableObject
/// driving the UI; a clock override + injectable DB path make it fully testable headlessly.
@MainActor
final class RecallDeck: ObservableObject {
    @Published private(set) var cards: [RecallCard] = []
    private let store: RecallDB
    private let clock: () -> Date

    init(entries: [Entry], path: String? = nil, clock: @escaping () -> Date = { Date() }) {
        self.store = RecallDB(path: path)
        self.clock = clock
        rebuild(from: entries)
    }

    /// H6 guard: a checkpoint yields a card only when its answer is non-empty and its citation is a
    /// real http(s) URL. Mirrors the build lint so nothing uncited can ever become a card.
    static func isSourced(_ url: String) -> Bool {
        url.hasPrefix("http://") || url.hasPrefix("https://")
    }

    /// (Re)build the deck from the compiled checkpoints, preserving any saved schedule. A card the
    /// library no longer contains is dropped; a brand-new card is due immediately.
    func rebuild(from entries: [Entry]) {
        let saved = store.loadAll()
        var built: [RecallCard] = []
        for e in entries {
            for c in e.checkpoints {
                guard !c.answer.isEmpty, Self.isSourced(c.sourceURL) else { continue }  // H6
                let key = "\(e.id)#\(c.ord)"
                let sched = saved[key] ?? RecallSchedule(dueAt: clock())
                built.append(RecallCard(entryID: e.id, entryTitle: e.title, ord: c.ord,
                                        prompt: c.prompt, answer: c.answer,
                                        sourceURL: c.sourceURL, schedule: sched))
            }
        }
        cards = built
    }

    /// Cards due right now (dueAt ≤ now), soonest-due first — the Daily Review queue.
    var dueCards: [RecallCard] {
        let now = clock()
        return cards.filter { $0.schedule.dueAt <= now }
                    .sorted { $0.schedule.dueAt < $1.schedule.dueAt }
    }
    var dueCount: Int { dueCards.count }
    var totalCount: Int { cards.count }

    /// Grade a card (SM-2-lite) and persist its new schedule.
    func grade(_ card: RecallCard, correct: Bool) {
        guard let idx = cards.firstIndex(where: { $0.id == card.id }) else { return }
        let graded = RecallEngine.grade(cards[idx].schedule, correct: correct, now: clock())
        cards[idx].schedule = graded
        store.save(id: card.id, graded)
    }

    /// Runtime 1:1 + H6 invariant. Every card MUST map to exactly one compiled checkpoint row
    /// (same entry_id, ord, answer, source_url) and carry an http(s) citation. Returns the list of
    /// violations — a planted card with no backing row (or an unsourced answer) makes it non-empty.
    static func validate(cards: [RecallCard], against entries: [Entry]) -> [String] {
        var index: [String: EntryCheckpoint] = [:]
        for e in entries { for c in e.checkpoints { index["\(e.id)#\(c.ord)"] = c } }
        var errors: [String] = []
        for card in cards {
            guard let row = index[card.id] else {
                errors.append("recall card \(card.id) has NO backing entry_checkpoints row (fabricated card)")
                continue
            }
            if card.answer != row.answer {
                errors.append("recall card \(card.id) answer '\(card.answer)' != checkpoint '\(row.answer)'")
            }
            if card.sourceURL != row.sourceURL || !isSourced(card.sourceURL) {
                errors.append("recall card \(card.id) citation is not the checkpoint's sourced http(s) URL")
            }
        }
        return errors
    }
}

// MARK: - Persisted schedule store (local SQLite, same posture as ProgressDB / the trial clock)

final class RecallDB {
    private let path: String

    init(path: String? = nil) {
        if let path { self.path = path; return }
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("BlackLabelAcademy", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.path = dir.appendingPathComponent("recall-schedule.sqlite").path
    }

    func loadAll() -> [String: RecallSchedule] {
        guard let db = open() else { return [:] }
        defer { sqlite3_close(db) }
        migrate(db)
        var rows: [String: RecallSchedule] = [:]
        var st: OpaquePointer?
        let sql = "SELECT card_id, reps, interval_days, ease, due_at FROM recall_schedule"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW {
            let id = String(cString: sqlite3_column_text(st, 0))
            rows[id] = RecallSchedule(
                reps: Int(sqlite3_column_int(st, 1)),
                intervalDays: Int(sqlite3_column_int(st, 2)),
                ease: sqlite3_column_double(st, 3),
                dueAt: Date(timeIntervalSince1970: sqlite3_column_double(st, 4)))
        }
        return rows
    }

    func save(id: String, _ s: RecallSchedule) {
        guard let db = open() else { return }
        defer { sqlite3_close(db) }
        migrate(db)
        let sql = """
        INSERT INTO recall_schedule (card_id, reps, interval_days, ease, due_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(card_id) DO UPDATE SET
          reps = excluded.reps, interval_days = excluded.interval_days,
          ease = excluded.ease, due_at = excluded.due_at
        """
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int(st, 2, Int32(s.reps))
        sqlite3_bind_int(st, 3, Int32(s.intervalDays))
        sqlite3_bind_double(st, 4, s.ease)
        sqlite3_bind_double(st, 5, s.dueAt.timeIntervalSince1970)
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
        CREATE TABLE IF NOT EXISTS recall_schedule (
          card_id TEXT PRIMARY KEY,
          reps INTEGER NOT NULL DEFAULT 0,
          interval_days INTEGER NOT NULL DEFAULT 0,
          ease REAL NOT NULL DEFAULT 2.5,
          due_at REAL NOT NULL DEFAULT 0
        );
        PRAGMA user_version = 1;
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }
}

// MARK: - Headless self-test (proves scheduling + the 1:1/H6 invariant without a WindowServer)

/// `Black Label Academy --selftest-recall`. Builds the deck from the real bundled checkpoints and
/// asserts: (1) every card maps 1:1 to a compiled checkpoint row (a planted card with no backing row
/// FAILS validation); (2) the schedule advances on a correct recall and resets on a miss. This is the
/// reproducible proof for AC-19 (wired into tests/smoke.sh). Platform-agnostic (recall ships on both).
@MainActor
func runRecallSelfTest() -> Never {
    print("== Black Label Academy — recall (spaced repetition) self-test ==")
    var ok = true

    let entries = ContentDB.load()
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("bl-academy-recall-\(ProcessInfo.processInfo.processIdentifier).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let deck = RecallDeck(entries: entries, path: tmp.path, clock: { t0 })
    print("  built \(deck.totalCount) recall cards from \(entries.count) entries; \(deck.dueCount) due at T0")

    // 1:1 + H6 — the honest deck must have zero violations.
    let clean = RecallDeck.validate(cards: deck.cards, against: entries)
    if clean.isEmpty {
        print("  1:1 + H6 invariant OK — every recall card maps to a sourced checkpoint row")
    } else {
        print("FAIL: honest deck has \(clean.count) validation violation(s): \(clean.prefix(3).joined(separator: "; "))")
        ok = false
    }

    // Fresh deck: every card is due.
    if deck.dueCount != deck.totalCount { print("FAIL: fresh deck not all-due (\(deck.dueCount)/\(deck.totalCount))"); ok = false }

    // Planted card with NO backing checkpoint row -> validation MUST reject it (else the 1:1 gate is a lie).
    if let real = deck.cards.first {
        let fabricated = RecallCard(entryID: "does-not-exist", entryTitle: "Ghost", ord: 99,
                                    prompt: "A fabricated recall card", answer: "$999",
                                    sourceURL: "https://example.com",
                                    schedule: RecallSchedule(dueAt: t0))
        let planted = RecallDeck.validate(cards: [fabricated], against: entries)
        if planted.isEmpty { print("FAIL: planted card with no checkpoint row PASSED validation (1:1 gate broken)"); ok = false }
        else { print("  planted-card rejection OK — \(planted.first!)") }

        // Unsourced answer -> H6 rejection.
        let unsourced = RecallCard(entryID: real.entryID, entryTitle: real.entryTitle, ord: real.ord,
                                   prompt: real.prompt, answer: real.answer,
                                   sourceURL: "not-a-url", schedule: RecallSchedule(dueAt: t0))
        if RecallDeck.validate(cards: [unsourced], against: entries).isEmpty {
            print("FAIL: unsourced-citation card PASSED validation (H6 gate broken)"); ok = false
        }

        // Schedule advances on correct.
        let s0 = real.schedule
        let s1 = RecallEngine.grade(s0, correct: true, now: t0)
        print("  correct: reps \(s0.reps)->\(s1.reps), interval \(s0.intervalDays)->\(s1.intervalDays)d, due +\(Int(s1.dueAt.timeIntervalSince(t0)/86_400))d")
        if !(s1.reps == 1 && s1.intervalDays >= 1 && s1.dueAt > t0) { print("FAIL: schedule did not advance on correct recall"); ok = false }
        let s2 = RecallEngine.grade(s1, correct: true, now: t0)
        if !(s2.intervalDays > s1.intervalDays) { print("FAIL: interval did not grow on a second correct recall"); ok = false }

        // Resets on miss.
        let sMiss = RecallEngine.grade(s2, correct: false, now: t0)
        print("  miss:    reps \(s2.reps)->\(sMiss.reps), interval \(s2.intervalDays)->\(sMiss.intervalDays)d (due today)")
        if !(sMiss.reps == 0 && sMiss.intervalDays == 0 && sMiss.dueAt <= t0) { print("FAIL: schedule did not reset on a miss"); ok = false }
    } else {
        print("FAIL: deck is empty — no checkpoints compiled?"); ok = false
    }

    print(ok ? "RECALL SELFTEST OK — spaced-repetition schedule advances/resets and every card maps 1:1 to a sourced checkpoint"
             : "RECALL SELFTEST FAILED")
    exit(ok ? 0 : 1)
}
