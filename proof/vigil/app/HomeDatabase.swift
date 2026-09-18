// Vigil — local SQLite workspace store.
// Stores the existing Codable HomeState document as a named blob in the app-container database.
// Legacy home.json remains migration/fallback only.
import Foundation
#if canImport(SQLite3) && !CIRCUIT_WINDOWS_SIM
import SQLite3
#else
import SwiftToolchainCSQLite
#endif

enum VigilDatabaseError: LocalizedError {
    case open(String)
    case exec(String)
    case prepare(String)
    case bind(String)
    case step(String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "SQLite open failed: \(message)"
        case .exec(let message): return "SQLite exec failed: \(message)"
        case .prepare(let message): return "SQLite prepare failed: \(message)"
        case .bind(let message): return "SQLite bind failed: \(message)"
        case .step(let message): return "SQLite step failed: \(message)"
        }
    }
}

final class VigilDatabase {
    static let homeState = "homeState"

    let url: URL

    init(baseURL: URL = VigilDatabase.baseURL()) {
        self.url = baseURL.appendingPathComponent("workspace.sqlite3")
    }

    static func baseURL() -> URL {
        if let dir = ProcessInfo.processInfo.environment["HOMEFRONT_DATA_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Homefront", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func readBlob(named name: String) throws -> Data? {
        try withDatabase { db in
            let sql = "SELECT payload FROM workspace_blobs WHERE name = ? LIMIT 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw VigilDatabaseError.prepare(Self.message(db))
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_bind_text(stmt, 1, name, -1, homefrontSQLiteTransient) == SQLITE_OK else {
                throw VigilDatabaseError.bind(Self.message(db))
            }
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                let count = Int(sqlite3_column_bytes(stmt, 0))
                guard let bytes = sqlite3_column_blob(stmt, 0), count > 0 else { return Data() }
                return Data(bytes: bytes, count: count)
            }
            guard result == SQLITE_DONE else { throw VigilDatabaseError.step(Self.message(db)) }
            return nil
        }
    }

    func writeBlob(_ payload: Data, named name: String) throws {
        try withDatabase { db in
            try Self.exec("BEGIN IMMEDIATE", db)
            do {
                let sql = "INSERT OR REPLACE INTO workspace_blobs(name, payload, updated_at) VALUES(?, ?, ?)"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw VigilDatabaseError.prepare(Self.message(db))
                }
                defer { sqlite3_finalize(stmt) }
                guard sqlite3_bind_text(stmt, 1, name, -1, homefrontSQLiteTransient) == SQLITE_OK else {
                    throw VigilDatabaseError.bind(Self.message(db))
                }
                try payload.withUnsafeBytes { raw in
                    guard sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(raw.count), homefrontSQLiteTransient) == SQLITE_OK else {
                        throw VigilDatabaseError.bind(Self.message(db))
                    }
                }
                let now = ISO8601DateFormatter().string(from: Date())
                guard sqlite3_bind_text(stmt, 3, now, -1, homefrontSQLiteTransient) == SQLITE_OK else {
                    throw VigilDatabaseError.bind(Self.message(db))
                }
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw VigilDatabaseError.step(Self.message(db))
                }
                try Self.exec("COMMIT", db)
            } catch {
                try? Self.exec("ROLLBACK", db)
                throw error
            }
        }
    }

    func deleteBlob(named name: String) throws {
        try withDatabase { db in
            let sql = "DELETE FROM workspace_blobs WHERE name = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw VigilDatabaseError.prepare(Self.message(db))
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_bind_text(stmt, 1, name, -1, homefrontSQLiteTransient) == SQLITE_OK else {
                throw VigilDatabaseError.bind(Self.message(db))
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw VigilDatabaseError.step(Self.message(db))
            }
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            let message = Self.message(db)
            if db != nil { sqlite3_close(db) }
            throw VigilDatabaseError.open(message)
        }
        defer { sqlite3_close(db) }
        try Self.configure(db)
        return try body(db)
    }

    private static func configure(_ db: OpaquePointer) throws {
        try exec("PRAGMA foreign_keys=ON", db)
        try exec("PRAGMA journal_mode=WAL", db)
        try exec("""
        CREATE TABLE IF NOT EXISTS workspace_blobs (
            name TEXT PRIMARY KEY NOT NULL,
            payload BLOB NOT NULL,
            updated_at TEXT NOT NULL
        )
        """, db)
    }

    private static func exec(_ sql: String, _ db: OpaquePointer) throws {
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &error) != SQLITE_OK {
            let message = error.map { String(cString: $0) } ?? message(db)
            if error != nil { sqlite3_free(error) }
            throw VigilDatabaseError.exec(message)
        }
    }

    private static func message(_ db: OpaquePointer?) -> String {
        guard let db, let raw = sqlite3_errmsg(db) else { return "unknown error" }
        return String(cString: raw)
    }
}

private let homefrontSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
