// Black Label Real Estate — LOCAL-FIRST workspace store.
//
// The buyer's own CRM (leads, deals, sequences, settings) persists ON-DEVICE as atomic JSON
// blob files in ~/Library/Application Support/BlackLabelRealEstate (BLRE_DATA_DIR overrides
// for dev/tests). No account, token, or network is ever required to keep the user's own data.
//
// PII POSTURE (POSTURE.md, local-first): the workspace NEVER leaves the device. The Lead
// Database API is queried with public params only; CRM data is never POSTed anywhere.
// A 2026-07-05 regression replaced this store with a token-gated Postgres "workspace bridge":
// a new user without a paid token silently lost every lead on quit (`try? writeBlob` swallowed
// `.missingToken`), and token holders blocked the main thread on network at launch/quit while
// their CRM PII was shipped off-device. This file restores the local-first contract.
//
// LEGACY MIGRATION: pre-07-05 builds stored blobs in workspace.sqlite3 (workspace_blobs table,
// the same file the retired local parcel index bloated to gigabytes). On a read miss we lift
// the blob out of that file READ-ONLY (the file itself is left untouched) and re-save it as a
// JSON blob file, so no earlier install loses its workspace on upgrade.
//
// The old local parcel-index helpers (withDatabase / configure / exec) still FAIL LOUDLY:
// SQLite is not a product backend for property data — the 28M-row index lives behind the API
// and is queried in pages, never imported locally.
import Foundation
#if canImport(SQLite3) && !CIRCUIT_WINDOWS_SIM
import SQLite3
#else
import SwiftToolchainCSQLite
#endif

enum RealEstateLocalDatabaseError: LocalizedError {
    case io(String)
    case badName(String)
    case localIndexDisabled

    var errorDescription: String? {
        switch self {
        case .io(let message):
            return "Workspace store failed: \(message)"
        case .badName(let name):
            return "Workspace blob name is invalid: \(name)"
        case .localIndexDisabled:
            return "Local SQLite property indexes are disabled; use the Lead Database API."
        }
    }
}

final class RealEstateLocalDatabase {
    static let appData = "appData"
    static let settings = "settings"

    /// The directory blob files live in (Application Support/BlackLabelRealEstate or BLRE_DATA_DIR).
    let url: URL

    init(baseURL: URL = RealEstateLocalDatabase.baseURL()) {
        self.url = baseURL
    }

    static func baseURL() -> URL {
        if let dir = ProcessInfo.processInfo.environment["BLRE_DATA_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelRealEstate", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Blob names are internal identifiers ("appData", "settings") — never user input. Reject
    // anything path-like so a bad caller can't escape the store directory.
    private static let nameOK = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.:-]{1,80}$")
    private func fileURL(for name: String) throws -> URL {
        let range = NSRange(name.startIndex..., in: name)
        guard Self.nameOK.firstMatch(in: name, range: range) != nil, !name.contains("..") else {
            throw RealEstateLocalDatabaseError.badName(name)
        }
        return url.appendingPathComponent("\(name).blob.json", isDirectory: false)
    }

    func readBlob(named name: String) throws -> Data? {
        let file = try fileURL(for: name)
        if FileManager.default.fileExists(atPath: file.path) {
            do { return try Data(contentsOf: file) }
            catch { throw RealEstateLocalDatabaseError.io("read \(name): \(error.localizedDescription)") }
        }
        // Read miss → one-time lift from the legacy SQLite workspace, if that file exists.
        if let legacy = try? legacyBlob(named: name) {
            try? writeBlob(legacy, named: name)   // best-effort persist in the new format
            return legacy
        }
        return nil
    }

    func writeBlob(_ payload: Data, named name: String) throws {
        let file = try fileURL(for: name)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try payload.write(to: file, options: .atomic)
        } catch {
            throw RealEstateLocalDatabaseError.io("write \(name): \(error.localizedDescription)")
        }
    }

    func deleteBlob(named name: String) throws {
        let file = try fileURL(for: name)
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do { try FileManager.default.removeItem(at: file) }
        catch { throw RealEstateLocalDatabaseError.io("delete \(name): \(error.localizedDescription)") }
    }

    // MARK: - Legacy workspace.sqlite3 migration (read-only)

    /// Lift a blob out of the pre-07-05 SQLite store. READ-ONLY open: the legacy file (which can
    /// be huge from the retired local parcel-index era) is never written, locked, or deleted here.
    private func legacyBlob(named name: String) throws -> Data? {
        let legacyPath = url.appendingPathComponent("workspace.sqlite3").path
        guard FileManager.default.fileExists(atPath: legacyPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(legacyPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM workspace_blobs WHERE name = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, name, -1, transient) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, 0))
        guard count > 0, let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: bytes, count: count)
    }

    // MARK: - Retired local parcel-index helpers (fail loudly; the property DB lives behind the API)

    func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        throw RealEstateLocalDatabaseError.localIndexDisabled
    }

    static func configure(_ db: OpaquePointer) throws {
        throw RealEstateLocalDatabaseError.localIndexDisabled
    }

    static func exec(_ sql: String, _ db: OpaquePointer) throws {
        throw RealEstateLocalDatabaseError.localIndexDisabled
    }

    static func message(_ db: OpaquePointer?) -> String {
        "local SQLite disabled"
    }
}
