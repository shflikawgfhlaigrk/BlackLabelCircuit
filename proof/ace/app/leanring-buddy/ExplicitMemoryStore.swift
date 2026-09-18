#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The explicit "remember" file is separate from conversation and Partner
/// history. All operations are bounded, anchored to one owned directory, and
/// reject linked files. A successful mutation includes exact disk readback.
struct ExplicitMemoryStore {
    static let maximumBytes = 2_000_000
    let fileURL: URL

    enum Failure: LocalizedError {
        case unsafePath, unreadable, tooLarge, invalidText, changed, writeFailed
        var errorDescription: String? {
            switch self {
            case .unsafePath: return "The saved-memory path is not a private, owned regular file."
            case .unreadable: return "Ace could not read saved memory."
            case .tooLarge: return "Saved memory reached its size limit. Review the memory file before adding more."
            case .invalidText: return "The memory text is empty, too long, or contains unsupported characters."
            case .changed: return "Saved memory changed since this request. Review it and ask again."
            case .writeFailed: return "Ace could not verify the memory change on disk. Check saved memory before retrying."
            }
        }
    }

    func contents() throws -> String {
        guard let directory = try openDirectory(create: false) else { return "" }
        defer { close(directory) }
        return try read(directory: directory, name: fileURL.lastPathComponent) ?? ""
    }

    func append(_ text: String, date: Date = Date()) throws {
        let normalized = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !normalized.isEmpty, normalized.utf8.count <= 16_000,
              normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidText
        }
        let directory = try requiredDirectory()
        defer { close(directory) }
        let previous = try read(directory: directory, name: fileURL.lastPathComponent)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let current = previous ?? ""
        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        let updated = current + separator + "- [\(formatter.string(from: date))] \(normalized)\n"
        try replace(updated, previous: previous, directory: directory)
    }

    @discardableResult
    func forgetLast() throws -> Bool {
        guard let directory = try openDirectory(create: false) else { return false }
        defer { close(directory) }
        guard let previous = try read(directory: directory, name: fileURL.lastPathComponent),
              !previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var lines = previous.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeLast() }
        // Current entries occupy one line. A legacy multiline bullet is one
        // entry too; preserve every byte before that final bullet.
        if let index = lines.lastIndex(where: { $0.hasPrefix("- [") }) {
            lines.removeSubrange(index...)
        } else {
            lines.removeLast()
        }
        let updated = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try replace(updated, previous: previous, directory: directory)
        return true
    }

    /// Only the exact reviewed snapshot may be cleared. The recoverable backup
    /// remains outside active retrieval and is explicitly disclosed to the owner.
    func clear(expected: String) throws -> URL? {
        guard let directory = try openDirectory(create: false) else {
            guard expected.isEmpty else { throw Failure.changed }
            return nil
        }
        defer { close(directory) }
        let previous = try read(directory: directory, name: fileURL.lastPathComponent)
        guard (previous ?? "") == expected else { throw Failure.changed }
        guard let previous, !previous.isEmpty else { return nil }
        let backupName = "memory-wiped-\(UUID().uuidString.lowercased()).bak"
        guard renameatx_np(directory, fileURL.lastPathComponent, directory, backupName, UInt32(RENAME_EXCL)) == 0 else {
            throw Failure.writeFailed
        }
        guard try read(directory: directory, name: backupName) == previous,
              try read(directory: directory, name: fileURL.lastPathComponent) == nil,
              fsync(directory) == 0 else { throw Failure.writeFailed }
        return fileURL.deletingLastPathComponent().appendingPathComponent(backupName)
    }

    private func requiredDirectory() throws -> Int32 {
        guard let directory = try openDirectory(create: true) else { throw Failure.unsafePath }
        return directory
    }

    private func openDirectory(create: Bool) throws -> Int32? {
        let directoryURL = fileURL.deletingLastPathComponent()
        if create { try PrivateSupportDirectory.ensure(at: directoryURL) }
        let directory = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if directory < 0 {
            if !create && errno == ENOENT { return nil }
            throw Failure.unsafePath
        }
        var attributes = stat()
        guard fstat(directory, &attributes) == 0,
              attributes.st_uid == getuid(),
              attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_mode & 0o022 == 0 else {
            close(directory)
            throw Failure.unsafePath
        }
        return directory
    }

    private func read(directory: Int32, name: String) throws -> String? {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw Failure.unreadable
        }
        defer { close(descriptor) }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_uid == getuid(), attributes.st_nlink == 1 else { throw Failure.unsafePath }
        guard attributes.st_size >= 0, attributes.st_size <= Self.maximumBytes else { throw Failure.tooLarge }
        // Existing releases wrote with default permissions; migrate only the
        // verified owned inode, never chmod a linked path or another file.
        guard fchmod(descriptor, 0o600) == 0 else { throw Failure.unsafePath }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.unreadable }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.unreadable }
        return text
    }

    private func replace(_ contents: String, previous: String?, directory: Int32) throws {
        let data = Data(contents.utf8)
        guard data.count <= Self.maximumBytes else { throw Failure.tooLarge }
        let temporaryName = ".memory-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.writeFailed }
        defer { close(descriptor); unlinkat(directory, temporaryName, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.writeFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0,
              try read(directory: directory, name: temporaryName) == contents else { throw Failure.writeFailed }
        guard try read(directory: directory, name: fileURL.lastPathComponent) == previous else { throw Failure.changed }
        guard renameat(directory, temporaryName, directory, fileURL.lastPathComponent) == 0,
              fsync(directory) == 0,
              try read(directory: directory, name: fileURL.lastPathComponent) == contents else { throw Failure.writeFailed }
    }
}
