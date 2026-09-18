// Black Label Marketing — file-backed secret store.
//
// Founder directive (2026-08-07): "well put them somewhere else." The Keychain
// is the reason this app can ever ask for a password. Even the correct
// data-protection routing only makes prompts RARE; the only way to make them
// impossible is to stop using the Keychain as the store at all.
//
// This mirrors Ace's R1 rule (AceRebuild/CONTRACT.md §1): secrets live in the
// app's own private data directory — directory 0700, files 0600, owned by this
// user — and are never handed to a system security agent that can put a
// password dialog on screen.
//
// WHY THIS IS NOT A DOWNGRADE from the login keychain for this app's threat
// model: a legacy keychain item's ACL is bound to the binary's CDHash, which is
// exactly what kept prompting on every rebuild. Both a 0600 file and a keychain
// item are readable by any process running as this user; macOS's protection
// boundary here is the user account, not the app. What changes is that the file
// can never summon a password dialog, and it survives rebuilds unchanged.
//
// FileVault still encrypts these bytes at rest, and the directory is excluded
// from Time Machine so credentials do not ride into backups.
import Foundation

/// Durable, prompt-free storage for Marketing's saved credentials.
enum MarketingSecretFile {

    /// `~/Library/Application Support/BlackLabel/Marketing/secrets`
    /// Created 0700 and REPAIRED to 0700 if a previous umask left it loose —
    /// the same failure that once disarmed Ace's whole bundled tool library.
    static func secretsDirectory() -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let directory = applicationSupport
            .appendingPathComponent("BlackLabel", isDirectory: true)
            .appendingPathComponent("Marketing", isDirectory: true)
            .appendingPathComponent("secrets", isDirectory: true)
            .standardizedFileURL
        do {
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                excludeFromBackup(directory)
            } else {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            }
        } catch {
            return nil
        }
        // A symlinked secrets directory is not ours; refuse rather than follow.
        guard directory.resolvingSymlinksInPath() == directory else { return nil }
        return directory
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    /// One file per credential. The name is derived from service+account and
    /// contains only characters that cannot escape the directory.
    static func fileName(service: String, account: String) -> String? {
        guard !service.isEmpty, !account.isEmpty else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        func sanitize(_ value: String) -> String {
            value.unicodeScalars.reduce(into: "") { result, scalar in
                result.append(allowed.contains(scalar) ? Character(scalar) : "_")
            }
        }
        let name = "\(sanitize(service))__\(sanitize(account)).secret"
        // Defense in depth: a sanitized name can never be a traversal, but
        // assert it rather than assume it.
        guard !name.contains("/"), !name.contains(".."), name.count <= 200 else {
            return nil
        }
        return name
    }

    private static func fileURL(service: String, account: String) -> URL? {
        guard let directory = secretsDirectory(),
              let name = fileName(service: service, account: account) else {
            return nil
        }
        let url = directory.appendingPathComponent(name, isDirectory: false)
            .standardizedFileURL
        guard url.deletingLastPathComponent() == directory else { return nil }
        return url
    }

    @discardableResult
    static func set(service: String, account: String, data: Data) -> Bool {
        guard let url = fileURL(service: service, account: account) else {
            return false
        }
        // Atomic write, then clamp permissions. Written via a temp file in the
        // same 0700 directory so a partial write can never be read as a
        // truncated credential.
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp", isDirectory: false)
        do {
            try data.write(to: temporary, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return true
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
    }

    static func copy(service: String, account: String) -> Data? {
        guard let url = fileURL(service: service, account: account),
              let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    static func exists(service: String, account: String) -> Bool {
        copy(service: service, account: account) != nil
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        guard let url = fileURL(service: service, account: account) else {
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return true }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
