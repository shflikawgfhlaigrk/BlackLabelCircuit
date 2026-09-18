#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SQLite3) && !CIRCUIT_WINDOWS_SIM
import SQLite3
#else
import SwiftToolchainCSQLite
#endif

nonisolated enum FloatingInboxMailError: Error, LocalizedError {
    case unavailable, changed
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Connect an account in Apple Mail and check Local Mail Access in Ace Setup."
        case .changed: return "Apple Mail's inbox could not be read. Open Mail, let it sync, then refresh."
        }
    }
}

private nonisolated final class FloatingInboxReadDeadline {
    let cancellation: FloatingInboxCancellation
    let expires = ProcessInfo.processInfo.systemUptime + 5
    init(_ cancellation: FloatingInboxCancellation) { self.cancellation = cancellation }
    func shouldStop() -> Bool {
        do { try cancellation.check() } catch { return true }
        return ProcessInfo.processInfo.systemUptime >= expires
    }
}

/// Reads only the buyer's local Mail index. No Apple Events, remote content,
/// mailbox passwords, SQLite writes, or persistent previews are involved.
nonisolated enum FloatingInboxAppleMail {
    static func currentIndex(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let root = home.appendingPathComponent("Library/Mail", isDirectory: true)
        guard root.resolvingSymlinksInPath().path == root.standardizedFileURL.path,
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
            throw FloatingInboxMailError.unavailable
        }
        let versions = names.compactMap { name -> (String, Int)? in
            guard name.first == "V", name.count <= 5, name.count > 1,
                  name.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(name.dropFirst()) else { return nil }
            return (name, number)
        }
        guard let version = versions.max(by: { $0.1 < $1.1 })?.0 else { throw FloatingInboxMailError.unavailable }
        let index = root.appendingPathComponent(version + "/MailData/Envelope Index")
        guard index.resolvingSymlinksInPath().path == index.standardizedFileURL.path,
              let values = try? index.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { throw FloatingInboxMailError.unavailable }
        return index
    }

    static func snapshot(cancellation: FloatingInboxCancellation,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> FloatingInboxSnapshot {
        try cancellation.check()
        let index = try currentIndex(home: home)
        var database: OpaquePointer?
        guard sqlite3_open_v2(index.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK,
              let database else {
            if let database { sqlite3_close(database) }
            throw FloatingInboxMailError.unavailable
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 200)
        guard sqlite3_exec(database, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF;", nil, nil, nil) == SQLITE_OK else {
            throw FloatingInboxMailError.changed
        }
        let deadline = FloatingInboxReadDeadline(cancellation)
        sqlite3_progress_handler(database, 1000, { pointer in
            guard let pointer else { return 1 }
            return Unmanaged<FloatingInboxReadDeadline>.fromOpaque(pointer).takeUnretainedValue().shouldStop() ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
        defer { sqlite3_progress_handler(database, 0, nil, nil); withExtendedLifetime(deadline) {} }

        // Older Mail schemas may lack the RFC Message-ID column. Previews still
        // work; the corresponding action honestly opens Mail without a deep link.
        let hasHeader = canPrepare(database, "SELECT message_id_header, message_id FROM message_global_data LIMIT 0")
        let header = hasHeader ? "substr(g.message_id_header,1,1000)" : "NULL"
        let join = hasHeader ? "LEFT JOIN message_global_data g ON g.ROWID=m.global_message_id AND g.message_id=m.message_id" : ""
        let sql = """
        WITH inbox AS (
          SELECT DISTINCT sm.message
          FROM server_messages sm
          JOIN server_labels sl ON sl.server_message=sm.ROWID
          JOIN mailboxes mb ON mb.ROWID=sl.label
          WHERE sm.deleted=0 AND sm.read=0 AND typeof(mb.url)='text'
            AND lower(rtrim(mb.url,'/')) GLOB '*://*/inbox'
            AND length(rtrim(mb.url,'/'))-length(replace(rtrim(mb.url,'/'),'/',''))=3
        )
        SELECT m.ROWID, m.message_id, substr(m.document_id,1,1024),
          substr(coalesce(a.comment,''),1,512), substr(coalesce(a.address,''),1,512),
          substr(coalesce(s.subject,'(No subject)'),1,1024), substr(coalesce(y.summary,''),1,4096),
          m.date_received, \(header), count(*) OVER()
        FROM inbox JOIN messages m ON m.ROWID=inbox.message
        LEFT JOIN addresses a ON a.ROWID=m.sender
        LEFT JOIN subjects s ON s.ROWID=m.subject
        LEFT JOIN summaries y ON y.ROWID=m.summary
        \(join)
        WHERE m.deleted=0
        ORDER BY m.date_received DESC,m.ROWID DESC LIMIT 20
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw FloatingInboxMailError.changed
        }
        defer { sqlite3_finalize(statement) }
        var messages: [FloatingEmail] = [], count = 0
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        while true {
            try cancellation.check()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw FloatingInboxMailError.changed }
            let row = sqlite3_column_int64(statement, 0)
            guard row > 0 else { throw FloatingInboxMailError.changed }
            count = Int(clamping: sqlite3_column_int64(statement, 9))
            let comment = text(statement, 3), address = text(statement, 4)
            let sender = comment.isEmpty ? address : address.isEmpty ? comment : "\(comment) <\(address)>"
            let date = sqlite3_column_int64(statement, 7)
            let received = (-62_135_596_800...253_402_300_799).contains(date)
                ? formatter.string(from: Date(timeIntervalSince1970: Double(date))) : ""
            messages.append(FloatingEmail(account: "Apple Mail", uidValidity: 0, uid: UInt64(row), gmailID: 0,
                sender: sender.isEmpty ? "Unknown sender" : sender,
                subject: text(statement, 5), preview: text(statement, 6), date: received,
                appleMailIdentity: "\(row)/\(sqlite3_column_int64(statement, 1))/\(text(statement, 2))",
                appleMailMessageID: text(statement, 8)))
        }
        try cancellation.check()
        return FloatingInboxSnapshot(messages: messages, unreadCount: max(0, count))
    }

    private static func canPrepare(_ database: OpaquePointer, _ sql: String) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        return sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        let bytes = UnsafeBufferPointer(start: pointer, count: Int(sqlite3_column_bytes(statement, column)))
        let value = String(decoding: bytes, as: UTF8.self)
        return String(value.unicodeScalars.filter { $0.value >= 32 || $0 == "\n" || $0 == "\t" }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif // circuit-convert
