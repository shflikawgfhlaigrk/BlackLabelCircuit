// Black Label Real Estate — prompt-free local secret persistence + explicit legacy recovery.
//
// Secrets-at-rest live in a private, atomic Application Support document, never UserDefaults and
// never the binary. This avoids macOS login-Keychain ACL prompts after local rebuild/re-sign cycles.
// Security.framework is used only by the explicit, foreground legacy-recovery action. Used by:
//   • the optional skip-trace / outreach provider API keys (PowerScreens ProviderConfig)
//   • the "Remember me" session token (SessionStore in Model.swift)
// Lives in its own tiny file so BOTH the app and the engine-test target compile it (the test
// runner can't pull in the heavy SwiftUI Screen files where this used to live).
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#endif
#if canImport(LocalAuthentication) && !CIRCUIT_WINDOWS_SIM
import LocalAuthentication
#endif

enum SecretStoreError: LocalizedError {
    case invalidAccount
    case createDirectory
    case read
    case corrupt
    case encode
    case write
    case permissions

    var errorDescription: String? {
        switch self {
        case .invalidAccount: return "The credential account name was invalid."
        case .createDirectory: return "The private credential folder could not be created."
        case .read: return "The saved credential file could not be read."
        case .corrupt: return "The saved credential file is unreadable and was preserved unchanged."
        case .encode: return "The credential update could not be encoded."
        case .write: return "The credential update could not be saved."
        case .permissions: return "The credential file could not be restricted to this user."
        }
    }
}

struct SecretStoreSnapshot {
    fileprivate var accounts: [String: String]

    func value(account: String) -> String? { accounts[account] }
    func contains(account: String) -> Bool { accounts[account] != nil }
}

/// Prompt-free credential persistence for normal app operation.
///
/// Security.framework is deliberately not involved in this type. A versioned JSON document lives
/// in the app's Application Support directory, is atomically replaced, and is readable only by the
/// current macOS user. The lock covers both the cache and disk so startup/background readers cannot
/// race an update into a partial document.
final class RealEstateSecretStore {
    private struct Document: Codable {
        var version = 1
        var accounts: [String: String] = [:]
    }

    let storageURL: URL
    private let lock = NSLock()
    private var cached: Document?
    private let fm: FileManager

    init(baseDirectory: URL? = nil, fileManager: FileManager = .default) {
        fm = fileManager
        let base = baseDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        storageURL = base
            .appendingPathComponent("BlackLabelRealEstate", isDirectory: true)
            .appendingPathComponent("Secrets", isDirectory: true)
            .appendingPathComponent("secrets-v1.json", isDirectory: false)
    }

    func snapshot() -> Result<SecretStoreSnapshot, SecretStoreError> {
        locked {
            switch loadUnlocked() {
            case .success(let document): return .success(SecretStoreSnapshot(accounts: document.accounts))
            case .failure(let error): return .failure(error)
            }
        }
    }

    func value(account: String) -> Result<String?, SecretStoreError> {
        snapshot().map { $0.value(account: account) }
    }

    func contains(account: String) -> Result<Bool, SecretStoreError> {
        snapshot().map { $0.contains(account: account) }
    }

    @discardableResult
    func set(_ value: String, account: String) -> Result<Void, SecretStoreError> {
        locked {
            switch loadUnlocked() {
            case .failure(let error): return .failure(error)
            case .success(var document):
                document.accounts[account] = value
                return saveUnlocked(document)
            }
        }
    }

    @discardableResult
    func delete(account: String) -> Result<Void, SecretStoreError> {
        locked {
            switch loadUnlocked() {
            case .failure(let error): return .failure(error)
            case .success(var document):
                document.accounts.removeValue(forKey: account)
                return saveUnlocked(document)
            }
        }
    }

    private func locked<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    private func loadUnlocked() -> Result<Document, SecretStoreError> {
        if let cached { return .success(cached) }
        guard fm.fileExists(atPath: storageURL.path) else { return .success(Document()) }
        guard let data = try? Data(contentsOf: storageURL) else { return .failure(.read) }
        guard let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1 else {
            return .failure(.corrupt)
        }
        cached = document
        return .success(document)
    }

    private func saveUnlocked(_ document: Document) -> Result<Void, SecretStoreError> {
        let directory = storageURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: NSNumber(value: 0o700)])
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
        } catch {
            return .failure(.createDirectory)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(document) else { return .failure(.encode) }
        // Create a private sibling first, then rename/replace in the same directory. The temporary
        // document is 0600 from creation (there is no world-readable interval), and the final swap
        // is atomic so readers see either the previous complete document or the new complete one.
        let temporaryURL = directory.appendingPathComponent(".secrets-v1.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temporaryURL.path, contents: data,
                            attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            return .failure(.write)
        }
        do {
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: temporaryURL.path)
        } catch {
            try? fm.removeItem(at: temporaryURL)
            return .failure(.permissions)
        }
        do {
            if fm.fileExists(atPath: storageURL.path) {
                _ = try fm.replaceItemAt(storageURL, withItemAt: temporaryURL,
                                         backupItemName: nil, options: [])
            } else {
                try fm.moveItem(at: temporaryURL, to: storageURL)
            }
            try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: storageURL.path)
        } catch {
            try? fm.removeItem(at: temporaryURL)
            return .failure(.write)
        }
        cached = document
        return .success(())
    }
}

enum LegacyCredentialRead {
    case value(String)
    case missing
    case failed
}

struct LegacyRecoveryReport {
    var imported = 0
    var existing = 0
    var missing = 0
    var failed = 0

    var summary: String {
        "Recovered \(imported) saved item\(imported == 1 ? "" : "s"). "
        + "\(existing) already current, \(missing) not found, \(failed) could not be read. "
        + "Original macOS Keychain items were left unchanged."
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// The only Security.framework read path in the app. Callers must place it behind an explicit,
/// foreground user action. It never deletes or updates legacy rows.
enum LegacyKeychainRecovery {
    static let knownAccounts = [
        "blre.session.remembered",
        "blre.leadDBToken",
        "blre.censusAPIKey",
        "com.blacklabel.realestate.mailvendor",
        "com.blacklabel.realestate.telephony",
        "com.blacklabel.realestate.skiptrace",
        "com.blacklabel.realestate.skiptrace.batchData",
        "com.blacklabel.realestate.skiptrace.rocketSkip",
    ]

    static func importAccounts(_ accounts: [String], into store: RealEstateSecretStore,
                               reader: (String) -> LegacyCredentialRead) -> LegacyRecoveryReport {
        var report = LegacyRecoveryReport()
        let existing: SecretStoreSnapshot
        switch store.snapshot() {
        case .success(let snapshot): existing = snapshot
        case .failure:
            report.failed = accounts.count
            return report
        }

        for account in accounts {
            if existing.contains(account: account) {
                report.existing += 1
                continue
            }
            switch reader(account) {
            case .missing:
                report.missing += 1
            case .failed:
                report.failed += 1
            case .value(let value):
                switch store.set(value, account: account) {
                case .success: report.imported += 1
                case .failure: report.failed += 1
                }
            }
        }
        return report
    }

    static func recoverKnownAccounts(into store: RealEstateSecretStore) -> LegacyRecoveryReport {
        importAccounts(knownAccounts, into: store, reader: readLegacyAccount)
    }

    private static func readLegacyAccount(_ account: String) -> LegacyCredentialRead {
        let context = LAContext()
        context.interactionNotAllowed = false
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // This context may interact because this operation is reachable only from the explicit
            // foreground recovery button. Passive/status/startup code never reaches this function.
            kSecUseAuthenticationContext as String: context,
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = out as? Data,
              let value = String(data: data, encoding: .utf8) else { return .failed }
        return .value(value)
    }
}
#endif // circuit-convert

/// Compatibility facade retained for provider modules that already build a generic-password query.
/// Despite the historical name, every normal call routes only to the private prompt-free file.
enum RealEstateKeychain {
    static let store = RealEstateSecretStore()

    private static func account(from base: [String: Any]) -> Result<String, SecretStoreError> {
        guard let account = base[kSecAttrAccount as String] as? String, !account.isEmpty else {
            return .failure(.invalidAccount)
        }
        return .success(account)
    }

    @discardableResult
    static func set(_ base: [String: Any], data: Data) -> Result<Void, SecretStoreError> {
        guard let value = String(data: data, encoding: .utf8) else { return .failure(.encode) }
        switch account(from: base) {
        case .failure(let error): return .failure(error)
        case .success(let account): return store.set(value, account: account)
        }
    }

    static func copyResult(_ base: [String: Any]) -> Result<Data?, SecretStoreError> {
        switch account(from: base) {
        case .failure(let error): return .failure(error)
        case .success(let account): return store.value(account: account).map { $0.map { Data($0.utf8) } }
        }
    }

    /// Legacy optional facade for provider request paths. UI save/session paths use the typed
    /// variants and surface failures rather than collapsing them into "not configured."
    static func copy(_ base: [String: Any]) -> Data? {
        guard case .success(let data) = copyResult(base) else { return nil }
        return data
    }

    @discardableResult
    static func delete(_ base: [String: Any]) -> Result<Void, SecretStoreError> {
        switch account(from: base) {
        case .failure(let error): return .failure(error)
        case .success(let account): return store.delete(account: account)
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum Keychain {
    private static var memoryStore: [String: String] = [:]
    private static var usesMemoryStore: Bool {
        ProcessInfo.processInfo.environment["BLRE_ENGINE_TEST_KEYCHAIN_MEMORY"] == "1"
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }
    @discardableResult
    static func set(_ value: String, account: String) -> Result<Void, SecretStoreError> {
        if usesMemoryStore {
            memoryStore[account] = value
            return .success(())
        }
        return RealEstateKeychain.set(base(account), data: Data(value.utf8))
    }
    static func getResult(account: String) -> Result<String?, SecretStoreError> {
        if usesMemoryStore { return .success(memoryStore[account]) }
        return RealEstateKeychain.copyResult(base(account)).map { data in
            data.flatMap { String(data: $0, encoding: .utf8) }
        }
    }
    static func get(account: String) -> String? {
        guard case .success(let value) = getResult(account: account) else { return nil }
        return value
    }
    @discardableResult
    static func delete(account: String) -> Result<Void, SecretStoreError> {
        if usesMemoryStore {
            memoryStore.removeValue(forKey: account)
            return .success(())
        }
        return RealEstateKeychain.delete(base(account))
    }

    static func recoverKnownLegacyAccounts() -> LegacyRecoveryReport {
        LegacyKeychainRecovery.recoverKnownAccounts(into: RealEstateKeychain.store)
    }

    // MARK: Lead Database access token (blre_… / storefront key)
    // Raises the API row-cap tier (preview 25 / pro 500 / founder 2000). A secret-at-rest, so it
    // lives in the private local store — never UserDefaults, never the binary. Read by RealEstateAPI as the
    // `Authorization: Bearer` header; no token = preview tier (still works, just capped).
    static let leadDBTokenAccount = "blre.leadDBToken"

    static func leadDBTokenResult() -> Result<String?, SecretStoreError> {
        getResult(account: leadDBTokenAccount).map { value in
            guard let token = value?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                return nil
            }
            return token
        }
    }
    /// The saved Lead Database token, or nil if none (→ preview tier).
    static func leadDBToken() -> String? {
        guard case .success(let token) = leadDBTokenResult() else { return nil }
        return token
    }
    /// True when a Lead Database key is stored AND readable on this device — i.e. exactly when
    /// `RealEstateAPI.authorize()` would actually attach it. Settings renders this as the
    /// connected/not-connected line, replacing the signal the un-prefilled SecureField lost.
    ///
    /// Deliberately defined as `leadDBToken() != nil` and NOT as a `kSecReturnAttributes`
    /// existence probe: an existence probe answers TRUE for an item the app cannot read (a
    /// legacy item whose signature-bound ACL denies a re-signed build returns
    /// errSecInteractionNotAllowed on the data read while still matching on attributes —
    /// reproduced 2026-08-03). That would print "a key is saved" while every request went out on
    /// the capped preview tier. The value is read, tested and DISCARDED here; it is never handed
    /// to the view, so the screen still never holds the secret.
    static func hasLeadDBToken() -> Bool { leadDBToken() != nil }
    static func hasLeadDBTokenResult() -> Result<Bool, SecretStoreError> {
        leadDBTokenResult().map { $0 != nil }
    }
    /// Store (or, on nil/empty, clear) the Lead Database token.
    @discardableResult
    static func setLeadDBToken(_ token: String?) -> Result<Void, SecretStoreError> {
        let t = (token ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return delete(account: leadDBTokenAccount) }
        return set(t, account: leadDBTokenAccount)
    }
}
#endif // circuit-convert
