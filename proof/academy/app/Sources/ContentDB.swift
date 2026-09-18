// Reads the bundled, compiled content database (raw sqlite3 C API — fleet pattern).
import Foundation
#if canImport(SQLite3) && !CIRCUIT_WINDOWS_SIM
import SQLite3
#else
import SwiftToolchainCSQLite
#endif

struct EntrySource: Hashable { let label: String; let url: String }

/// AC-10 recall checkpoint: a fill-in-the-blank prompt whose answer is a figure the lesson SOURCES
/// inline, plus that figure's own citation. Compiled + provenance-checked at build time — the app
/// only renders what the pipeline proved honest (a checkpoint can never assert an uncited figure).
struct EntryCheckpoint: Hashable, Identifiable {
    let ord: Int
    let prompt: String
    let answer: String
    let sourceURL: String
    var id: Int { ord }
}

struct EntryMetric: Hashable {
    let key: String
    let value: Double
    let unit: String
    let source: String?
    let estimateMethod: String?
    let confidence: String?
    var provenance: String { source ?? estimateMethod.map { "est: \($0)" } ?? "—" }
    var display: String {
        // Compact money/number formatting.
        if unit.uppercased() == "USD" {
            return "$" + Self.compact(value)
        }
        if unit.hasPrefix("score") { return "\(Int(value))/100" }
        return Self.compact(value) + (unit.isEmpty ? "" : " " + unit)
    }
    static func compact(_ v: Double) -> String {
        let a = abs(v)
        switch a {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 1_000...: return String(format: "%.0fK", v / 1_000)
        default: return String(format: "%.0f", v)
        }
    }
}

struct Entry: Identifiable, Hashable {
    let id: String
    let title: String
    let pillar: String
    let difficulty: String
    let estReadMin: Int
    let lastUpdated: String
    let status: String
    let attributionCreator: String?
    let attributionLink: String?
    let disclaimer: String?
    /// Post-mortem proof-link (failures pillar): a public URL, the literal "no-public-proof",
    /// or nil for non-failures entries. Compiled from the lint-gated `postmortem.proof` field.
    let postmortemProof: String?
    let body: String
    var tags: [String] = []
    var sources: [EntrySource] = []
    var metrics: [EntryMetric] = []
    var checkpoints: [EntryCheckpoint] = []
}

extension Entry {
    /// Quantitative claims (figures) this lesson asserts. Derived only from the compiled
    /// entry_metrics — a prose lesson with no figures has zero claims, shown truthfully.
    var claimCount: Int { metrics.count }
    /// Claims backed by a primary linked source (not merely an estimate method). Mirrors the
    /// build-time provenance lint's source/estimate distinction (§5.1) so the receipts chip can
    /// never overstate: a lesson with figures but no citations shows "0/N sourced" honestly.
    var sourcedClaimCount: Int { metrics.filter { $0.source != nil }.count }
    /// True when this lesson makes at least one quantitative claim worth a receipts chip.
    var hasClaims: Bool { !metrics.isEmpty }
}

enum ContentDB {
    static func load() -> [Entry] {
        guard let path = Bundle.main.path(forResource: "BlackLabelAcademy", ofType: "sqlite") else { return [] }
        return load(path: path)
    }

    /// Load from an explicit DB path. The shipped app always goes through `load()` (the bundled
    /// resource); this overload exists so the XCTest bundle — whose `Bundle.main` is the xctest
    /// runner, not the app — can read the SAME lint-gated artifact the build emits. Identical code
    /// path: the tests exercise the real loader, never a reimplementation of it.
    static func load(path: String) -> [Entry] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        var entries: [String: Entry] = [:]
        var order: [String] = []

        query(db, "SELECT id,title,pillar,difficulty,est_read_min,last_updated,status,attribution_creator,attribution_link,disclaimer,postmortem_proof,body FROM entries ORDER BY pillar,title") { st in
            let id = col(st, 0)
            entries[id] = Entry(
                id: id, title: col(st, 1), pillar: col(st, 2), difficulty: col(st, 3),
                estReadMin: Int(sqlite3_column_int(st, 4)), lastUpdated: col(st, 5), status: col(st, 6),
                attributionCreator: colOpt(st, 7), attributionLink: colOpt(st, 8),
                disclaimer: colOpt(st, 9), postmortemProof: colOpt(st, 10), body: col(st, 11))
            order.append(id)
        }
        query(db, "SELECT entry_id,tag FROM entry_tags") { st in
            entries[col(st, 0)]?.tags.append(col(st, 1))
        }
        query(db, "SELECT entry_id,label,url FROM entry_sources") { st in
            entries[col(st, 0)]?.sources.append(EntrySource(label: col(st, 1), url: col(st, 2)))
        }
        query(db, "SELECT entry_id,key,value,unit,source,estimate_method,confidence FROM entry_metrics") { st in
            entries[col(st, 0)]?.metrics.append(EntryMetric(
                key: col(st, 1), value: sqlite3_column_double(st, 2), unit: col(st, 3),
                source: colOpt(st, 4), estimateMethod: colOpt(st, 5), confidence: colOpt(st, 6)))
        }
        // AC-10 recall checkpoints (table added b25; guard so an older DB without it still loads).
        query(db, "SELECT entry_id,ord,prompt,answer,source_url FROM entry_checkpoints ORDER BY entry_id,ord") { st in
            entries[col(st, 0)]?.checkpoints.append(EntryCheckpoint(
                ord: Int(sqlite3_column_int(st, 1)), prompt: col(st, 2),
                answer: col(st, 3), sourceURL: col(st, 4)))
        }
        return order.compactMap { entries[$0] }
    }

    private static func query(_ db: OpaquePointer?, _ sql: String, _ row: (OpaquePointer?) -> Void) {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(st) }
        while sqlite3_step(st) == SQLITE_ROW { row(st) }
    }
    private static func col(_ st: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(st, i) else { return "" }
        return String(cString: c)
    }
    private static func colOpt(_ st: OpaquePointer?, _ i: Int32) -> String? {
        guard sqlite3_column_type(st, i) != SQLITE_NULL, let c = sqlite3_column_text(st, i) else { return nil }
        return String(cString: c)
    }
}
