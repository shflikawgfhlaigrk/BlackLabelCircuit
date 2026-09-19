// Sovereign — External (Anthropic) connection for the BUYER's own External account.
//
// This is the heart of the "Sovereign" promise: the assistant can run on the BUYER's own
// External login — never a bundled key, never Black Label's account. The buyer pastes a key
// they own (or signs in), it's stored in Sovereign's private Application Support directory, and every External
// brain call uses it. Nothing is baked into the shipped app.
//
// HONESTY RULES:
//  - The shipped bundle contains NO token, NO key, NO Black Label credential. Starts empty.
//  - The credential lives only in an owner-only local file on the buyer's Mac. Never written to
//    UserDefaults, never logged, never synced.
//  - If no credential is present, the External brain is honestly "not connected" — we never
//    fall back to inventing replies.
//
// Two ways a buyer connects their own External:
//  1. API key (sk-ant-...) from console.anthropic.com — pasted in Settings. Privately stored.
//  2. (Future) OAuth "Sign in to External" — the same private slot accepts an OAuth access
//     token; the brain sends it as a Bearer token with the oauth beta header. The storage and
//     send paths below already support both; the interactive OAuth flow is gated until the
//     buyer's own client registration is configured (no Black Label client id ships).
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif
#if os(macOS)
import Darwin
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

/// Result of the buyer-credential check against Anthropic's official read-only Models endpoint.
/// Only `.verified` may publish CONNECTED state. `.unverified` (we could not reach the provider)
/// and `.rejected` (the provider refused this key) are DIFFERENT FACTS and never collapse into one
/// another: an unreachable provider keeps the buyer's key on this device for a later re-check,
/// a rejection stores nothing.
enum AnthropicCredentialProbeResult: Equatable, Sendable {
    case verified
    case rejected(String)
    case unverified(String)

    var isRejected: Bool {
        if case .rejected = self { return true }
        return false
    }
    var isUnverified: Bool {
        if case .unverified = self { return true }
        return false
    }
}

/// Injectable network boundary for proving an Anthropic API key before it is persisted. The live
/// transport calls GET /v1/models?limit=1, documented by Anthropic as the read-only Models list.
struct AnthropicCredentialProbe: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport

    init(transport: @escaping Transport = { request in
        try await URLSession.shared.data(for: request)
    }) {
        self.transport = transport
    }

    nonisolated static func makeRequest(apiKey: String) -> URLRequest {
        var components = URLComponents(string: "https://api.anthropic.com/v1/models")!
        components.queryItems = [URLQueryItem(name: "limit", value: "1")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        return request
    }

    func verify(apiKey: String) async -> AnthropicCredentialProbeResult {
        do {
            let (data, response) = try await transport(Self.makeRequest(apiKey: apiKey))
            guard let http = response as? HTTPURLResponse else {
                return .unverified("Anthropic returned an unreadable response, so the key could not be verified.")
            }
            switch http.statusCode {
            case 200:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["data"] is [Any] else {
                    return .unverified("Anthropic returned an unexpected response, so the key could not be verified.")
                }
                return .verified
            case 401:
                return .rejected("Anthropic rejected that API key. Check that it is active and try again; it was not saved.")
            case 403:
                return .rejected("Anthropic did not authorize that API key. Check its permissions and try again; it was not saved.")
            default:
                return .unverified("Anthropic could not verify the key right now (HTTP \(http.statusCode)).")
            }
        } catch {
            return .unverified("Anthropic could not be reached, so the key could not be verified. Check your connection.")
        }
    }
}

typealias AnthropicAPIKeyProbe = @Sendable (String) async -> AnthropicCredentialProbeResult

/// How much PROOF exists for the stored API-key credential. Persisted as a NON-SECRET marker so a
/// key saved while the provider was unreachable is RE-CHECKED later instead of silently discarded
/// (M3, 2026-08-02: a network failure during verification used to throw the buyer's key away), and
/// so an upgrade never deletes a connection an earlier build already made (M4).
enum ExternalCredentialVerification: String, Codable, Equatable, Sendable {
    /// A live provider probe accepted this exact key.
    case verified
    /// Saved on this device but NEVER proven — the provider could not be reached at connect time.
    /// Not published as connected (we never claim a brain works unproven), and never discarded:
    /// re-checked at launch and on demand.
    case pending
    /// Written by a PRIOR build that stored API keys without a server probe. Carried forward as a
    /// working connection — an upgrade must not silently remove a brain the buyer was already
    /// using — and re-checked in the background.
    case grandfathered
    /// The provider actively REFUSED this key on a re-check. Not connected; the buyer is told the
    /// provider rejected it (a different fact from "we could not reach the provider").
    case rejected
    /// Kinds that carry no provider API key (OAuth token, CLI paths, custom-CLI spec).
    case notApplicable

    /// Whether a credential in this state may be published as a live connection. PURE.
    var isConnectable: Bool {
        switch self {
        case .verified, .grandfathered, .notApplicable: return true
        case .pending, .rejected: return false
        }
    }

    /// Honest one-line buyer-facing disclosure of this state (nil when there is nothing to say).
    var disclosure: String? {
        switch self {
        case .verified, .notApplicable: return nil
        case .pending:
            return "Your provider key is saved on this device but has not been verified yet — Sovereign could not reach the provider. It re-checks automatically on the next launch, or use “Verify now”."
        case .grandfathered:
            return "Your provider key was carried over from an earlier version of Sovereign and is still connected. It is re-checked in the background."
        case .rejected:
            return "The provider rejected your saved key, so it is not connected. Paste a current key to reconnect."
        }
    }
}

/// What actually happened to the buyer's key when they pressed Connect. Distinguishes, explicitly,
/// "the provider refused this key" from "we could not reach the provider" — collapsing those two
/// into one outcome is what discarded working credentials on a captive network.
enum ExternalConnectOutcome: Equatable, Sendable {
    /// A live probe accepted the key; it is stored and connected.
    case verified
    /// The provider was unreachable. The key IS SAVED on this device, marked unverified, and is
    /// not published as connected until a re-check succeeds.
    case savedPendingVerification(String)
    /// The provider refused the key. Nothing was stored.
    case rejected(String)
    /// The input isn't a provider key at all. Nothing was stored, no network call was made.
    case invalidShape(String)
    /// The probe accepted the key but the private credential store refused to save it.
    case storeFailed(String)

    /// The buyer-facing message, or nil when the connection simply succeeded.
    var message: String? {
        switch self {
        case .verified: return nil
        case .savedPendingVerification(let m), .rejected(let m), .invalidShape(let m), .storeFailed(let m): return m
        }
    }
    /// True when the buyer's key survived this attempt on disk (verified or saved-pending).
    var didPersistCredential: Bool {
        switch self {
        case .verified, .savedPendingVerification: return true
        case .rejected, .invalidShape, .storeFailed: return false
        }
    }
    /// True only when the PROVIDER refused the key.
    var providerRejected: Bool { if case .rejected = self { return true }; return false }
    /// True only when the provider could not be REACHED.
    var providerUnreachable: Bool { if case .savedPendingVerification = self { return true }; return false }
}

/// Pure credential policy: what a probe result means for the buyer's key, and what verification
/// state a stored credential is in given what's on disk. No Keychain, no network, no UI.
enum ExternalCredentialPolicy {
    /// Appended to an unreachable-provider message so the buyer knows the key was KEPT, and that
    /// "unreachable" is not "rejected".
    static let pendingSuffix = "Your key is saved on this device and Sovereign re-checks it automatically on the next launch — or use “Verify now”. The provider did not reject it."

    /// Map a probe result onto what happens to the buyer's key. PURE.
    static func outcome(for probe: AnthropicCredentialProbeResult) -> ExternalConnectOutcome {
        switch probe {
        case .verified: return .verified
        case .rejected(let message): return .rejected(message)
        case .unverified(let message): return .savedPendingVerification("\(message) \(pendingSuffix)")
        }
    }

    /// Which verification state a stored credential is in. PURE.
    ///
    /// M4 (grandfathering): a `kind` record with NO verification marker was written by a build that
    /// stored API keys without a probe. That is a connection the buyer already made and used — it
    /// is carried forward as `.grandfathered` (connected, re-checked in the background) instead of
    /// vanishing on upgrade while `settings.brainProvider` still points at `.external`.
    static func verification(kind: ExternalCredentialKind,
                             storedMarker: String?,
                             legacyVerifiedFlag: Bool,
                             kindRecordPresent: Bool) -> ExternalCredentialVerification {
        guard kind == .apiKey else { return .notApplicable }
        if let raw = storedMarker, let parsed = ExternalCredentialVerification(rawValue: raw) { return parsed }
        if legacyVerifiedFlag { return .verified }
        if kindRecordPresent { return .grandfathered }
        // No kind record, no marker, no legacy flag: nothing on this device says a connection was
        // ever made. Never publish connected on no evidence.
        return .pending
    }
}

/// The kind of credential the buyer connected — determines how the brain authenticates.
enum ExternalCredentialKind: String, Codable {
    case apiKey        // x-api-key: sk-ant-...
    case oauth         // Authorization: Bearer <token> + oauth beta header
    case cli           // the buyer's own External SUBSCRIPTION via the `external` CLI (macOS-only).
                       // No secret travels through Sovereign — auth lives in the CLI's own
                       // `external login` session on disk (~/.external). Sovereign just shells out.
    case secondaryCLI      // the buyer's own Secondary CLI session (macOS-only). No API key is stored in
                       // Sovereign; auth stays inside Secondary while Sovereign uses clean exec flags.
    case customCLI     // ANY prompt-capable CLI on PATH (macOS-only). The `secret` is the buyer's
                       // command TEMPLATE (a non-sensitive JSON spec), NOT an API key. Sovereign runs
                       // the buyer's own command on this device; nothing is bundled or billed.
}

/// A stored External credential. The secret is loaded only to build an authenticated request.
struct ExternalCredential: Equatable {
    let kind: ExternalCredentialKind
    let secret: String
    /// Label shown in the UI — masked, never the full secret.
    var masked: String {
        // CLI subscription carries NO secret (the `secret` field holds the non-sensitive CLI path);
        // show an honest label instead of masking a path as if it were a key.
        if kind == .cli || kind == .secondaryCLI { return "legacy external CLI" }
        if kind == .customCLI {
            if let spec = CustomCLISpec.decode(secret) { return "your \(spec.displayName) CLI" }
            return "your custom CLI"
        }
        guard secret.count > 8 else { return "••••" }
        let head = secret.prefix(7), tail = secret.suffix(4)
        return "\(head)…\(tail)"
    }
}

/// Headless-test Keychain bypass. The pure-logic suite (Tests/run.command) compiles the REAL
/// Sources into an UNSIGNED, windowless executable. That binary is NOT on the access-control list
/// of Keychain items the real signed app previously wrote, so a live `SecItem*` read of an existing
/// credential blocks FOREVER on a keychain-authorization prompt no one can answer — which is exactly
/// the silent hang the room hit (BrainRouter() -> ExternalAuth.shared.init -> refresh -> load).
///
/// When `SOV_HEADLESS_TESTS=1` (exported ONLY by Tests/run.command), the credential/session stores
/// below use this process-local in-memory map instead of the real Keychain: hermetic, prompt-free,
/// and never touching the developer's login Keychain. With the env var UNSET (every production
/// build, every real app launch) the code path is byte-identical to before — nothing ships changed.
enum HeadlessKeychain {
    static let active = ProcessInfo.processInfo.environment["SOV_HEADLESS_TESTS"] == "1"
    nonisolated(unsafe) private static var items: [String: Data] = [:]
    static func get(_ key: String) -> Data? { items[key] }
    static func set(_ key: String, _ data: Data) { items[key] = data }
    static func delete(_ key: String) { items[key] = nil }
}

/// The active credential backend. Secrets live in Sovereign's private Application Support
/// directory instead of Security.framework so a local/ad-hoc rebuild can never turn a background
/// read into a macOS password dialog. The directory and files are owner-only and writes are
/// same-directory atomic replacements.
struct SovereignSecretFileStore {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/BlackLabel/Sovereign/secrets",
                                    isDirectory: true)
            .standardizedFileURL
    }

    func fileURL(service: String, account: String) -> URL? {
        guard !service.isEmpty, !account.isEmpty else { return nil }
        let identity = Data("\(service)\u{0}\(account)".utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        guard !identity.isEmpty, identity.count <= 180 else { return nil }
        let url = directoryURL.appendingPathComponent("\(identity).secret", isDirectory: false)
            .standardizedFileURL
        guard url.deletingLastPathComponent() == directoryURL else { return nil }
        return url
    }

    @discardableResult
    func set(service: String, account: String, data: Data) -> Bool {
        guard !data.isEmpty, prepareDirectory(),
              let destination = fileURL(service: service, account: account) else { return false }
        if entryExists(destination), !isPrivateRegularFile(destination) { return false }
        let temporary = directoryURL.appendingPathComponent(".credential-\(UUID().uuidString).tmp")
        #if os(macOS)
        let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        var wroteAll = false
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { wroteAll = true; return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if count <= 0 { return }
                offset += count
            }
            wroteAll = Darwin.fsync(fd) == 0
        }
        _ = Darwin.close(fd)
        guard wroteAll,
              Darwin.rename(temporary.path, destination.path) == 0,
              Darwin.chmod(destination.path, 0o600) == 0,
              isPrivateRegularFile(destination) else {
            _ = Darwin.unlink(temporary.path)
            return false
        }
        synchronizeDirectory()
        return true
        #else
        return false
        #endif
    }

    func copy(service: String, account: String) -> Data? {
        guard let url = fileURL(service: service, account: account),
              isPrivateRegularFile(url) else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    func exists(service: String, account: String) -> Bool {
        guard let url = fileURL(service: service, account: account),
              isPrivateRegularFile(url) else { return false }
        #if os(macOS)
        var info = Darwin.stat()
        return Darwin.lstat(url.path, &info) == 0 && info.st_size > 0
        #else
        return false
        #endif
    }

    @discardableResult
    func delete(service: String, account: String) -> Bool {
        guard let url = fileURL(service: service, account: account) else { return false }
        guard entryExists(url) else { return true }
        guard isPrivateRegularFile(url) else { return false }
        #if os(macOS)
        let deleted = Darwin.unlink(url.path) == 0
        if deleted { synchronizeDirectory() }
        return deleted
        #else
        return false
        #endif
    }

    private func prepareDirectory() -> Bool {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            guard directoryURL.resolvingSymlinksInPath() == directoryURL,
                  isPrivateDirectory(directoryURL) else { return false }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            guard isPrivateDirectory(directoryURL) else { return false }
            var mutable = directoryURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? mutable.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    private func entryExists(_ url: URL) -> Bool {
        #if os(macOS)
        var info = Darwin.stat()
        return Darwin.lstat(url.path, &info) == 0
        #else
        return fileManager.fileExists(atPath: url.path)
        #endif
    }

    private func isPrivateDirectory(_ url: URL) -> Bool {
        #if os(macOS)
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == geteuid()
            && info.st_nlink >= 1 && (info.st_mode & 0o777) == 0o700
        #else
        return false
        #endif
    }

    private func isPrivateRegularFile(_ url: URL) -> Bool {
        #if os(macOS)
        var info = Darwin.stat()
        guard Darwin.lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid()
            && info.st_nlink == 1 && (info.st_mode & 0o777) == 0o600
        #else
        return false
        #endif
    }

    private func synchronizeDirectory() {
        #if os(macOS)
        let fd = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { _ = Darwin.fsync(fd); _ = Darwin.close(fd) }
        #endif
    }
}

/// The only gate through which a legacy Keychain read may run. All passive/background callers pass
/// false; a foreground button passes true. The closure seam is intentionally testable without
/// touching the developer's login Keychain.
enum SovereignCredentialReadPolicy {
    static func resolve(fileData: Data?, allowLegacyRecovery: Bool,
                        recoverLegacy: () -> Data?) -> Data? {
        if let fileData { return fileData }
        guard allowLegacyRecovery else { return nil }
        return recoverLegacy()
    }
}

enum SovereignLegacyRecoveryResult: Equatable {
    case recovered
    case unavailable
    case storeFailed
}

/// Compatibility boundary for old callers. Normal reads, writes, and deletes are file-only.
/// Security.framework is used solely by `recoverLegacy`, which is wired to explicit foreground UI.
enum SovereignKeychain {
    private static let activeStore = SovereignSecretFileStore()

    private static func identity(_ base: [String: Any]) -> (service: String, account: String)? {
        guard let service = base[kSecAttrService as String] as? String,
              let account = base[kSecAttrAccount as String] as? String,
              !service.isEmpty, !account.isEmpty else { return nil }
        return (service, account)
    }

    @discardableResult
    static func set(_ base: [String: Any], data: Data) -> Bool {
        guard let item = identity(base) else { return false }
        let stored = activeStore.set(service: item.service, account: item.account, data: data)
        if stored {
            clearLegacyReadMarker(base)
            UserDefaults.standard.removeObject(forKey: recoverySuppressedKey(item))
        }
        return stored
    }

    static func copy(_ base: [String: Any]) -> Data? {
        guard let item = identity(base) else { return nil }
        return SovereignCredentialReadPolicy.resolve(
            fileData: activeStore.copy(service: item.service, account: item.account),
            allowLegacyRecovery: false,
            recoverLegacy: { nil }
        )
    }

    static func exists(_ base: [String: Any]) -> Bool {
        guard let item = identity(base) else { return false }
        return activeStore.exists(service: item.service, account: item.account)
    }

    @discardableResult
    static func delete(_ base: [String: Any]) -> Bool {
        guard let item = identity(base) else { return false }
        let deleted = activeStore.delete(service: item.service, account: item.account)
        if deleted { UserDefaults.standard.set(true, forKey: recoverySuppressedKey(item)) }
        clearLegacyReadMarker(base)
        return deleted
    }

    /// Explicit, foreground, non-destructive recovery. It may display the old ACL prompt once.
    /// Successful bytes are copied into the active store and verified; the Keychain row is retained.
    static func recoverLegacy(_ base: [String: Any]) -> SovereignLegacyRecoveryResult {
        guard let item = identity(base),
              !UserDefaults.standard.bool(forKey: recoverySuppressedKey(item)) else {
            return .unavailable
        }
        let recovered = SovereignCredentialReadPolicy.resolve(
            fileData: activeStore.copy(service: item.service, account: item.account),
            allowLegacyRecovery: true
        ) {
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var output: AnyObject?
            var dataProtection = query
            dataProtection[kSecUseDataProtectionKeychain as String] = true
            if SecItemCopyMatching(dataProtection as CFDictionary, &output) == errSecSuccess,
               let data = output as? Data { return data }
            output = nil
            guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess,
                  let data = output as? Data else { return nil }
            return data
        }
        guard let recovered else { return .unavailable }
        if activeStore.copy(service: item.service, account: item.account) == recovered {
            return .recovered
        }
        guard activeStore.set(service: item.service, account: item.account, data: recovered),
              activeStore.copy(service: item.service, account: item.account) == recovered else {
            return .storeFailed
        }
        clearLegacyReadMarker(base)
        return .recovered
    }

    private static func clearLegacyReadMarker(_ base: [String: Any]) {
        guard let key = legacyReadMarkerKey(base) else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func legacyReadMarkerKey(_ base: [String: Any]) -> String? {
        guard let service = base[kSecAttrService as String] as? String,
              let account = base[kSecAttrAccount as String] as? String,
              !service.isEmpty, !account.isEmpty else { return nil }
        return "sov.keychain.legacy-readable.\(service).\(account)"
    }

    private static func recoverySuppressedKey(_ item: (service: String, account: String)) -> String {
        "sov.keychain.legacy-recovery-suppressed.\(item.service).\(item.account)"
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Prompt-free store for the buyer's own External credential. Pure of any bundled secret.
@MainActor
final class ExternalAuth: ObservableObject {
    static let shared = ExternalAuth()
    nonisolated static let keychainService = "com.blacklabel.sovereign.external"
    nonisolated static let keychainAccount = "buyer-external-credential"
    nonisolated static let kindUserDefaultsKey = "com.blacklabel.sovereign.external.kind.v1"
    nonisolated static let apiKeyVerifiedUserDefaultsKey = "com.blacklabel.sovereign.external.api-key-verified.v1"
    nonisolated static let maskedLabelUserDefaultsKey = "com.blacklabel.sovereign.external.masked-label.v1"
    /// Non-secret verification marker (see `ExternalCredentialVerification`). Supersedes the legacy
    /// boolean above, which is still written for `.verified` so older read paths keep working.
    nonisolated static let verificationUserDefaultsKey = "com.blacklabel.sovereign.external.verification.v2"

    /// Published so the UI reflects connection state live. Mirrors non-secret store metadata.
    @Published private(set) var connectedKind: ExternalCredentialKind?
    @Published private(set) var maskedLabel: String = ""
    /// How much proof exists for what is stored (nil = nothing stored on this device).
    @Published private(set) var verification: ExternalCredentialVerification?
    /// Masked label for a credential that is SAVED but not connectable (pending/rejected), so the
    /// UI can say which key is waiting on a re-check instead of pretending nothing is there.
    @Published private(set) var unverifiedMaskedLabel: String = ""
    /// True when old non-secret metadata exists but no active file does. Recovery is never attempted
    /// automatically; the buyer must deliberately request the one-time foreground Keychain read.
    @Published private(set) var legacyRecoveryAvailable = false

    /// Legacy external-account model id. The shipped default brain is Ornith/Ollama.
    /// (Kept here so the one authoritative model id lives next to the auth that uses it.)
    nonisolated static let defaultModel = "external-legacy"

    private let service = ExternalAuth.keychainService
    private let account = ExternalAuth.keychainAccount
    private let kindKey = ExternalAuth.kindUserDefaultsKey   // non-secret: which kind is stored
    private let apiKeyVerifiedKey = ExternalAuth.apiKeyVerifiedUserDefaultsKey
    private let verificationKey = ExternalAuth.verificationUserDefaultsKey
    private let maskedKey = ExternalAuth.maskedLabelUserDefaultsKey
    private let apiKeyProbe: AnthropicAPIKeyProbe

    /// Optional ledger so connecting/disconnecting the External account writes a real
    /// proof-of-execution receipt at the moment the grant changes. Wired at app init. Never
    /// records the secret — only that a credential of a given kind was connected/removed.
    weak var activity: ActivityLog?

    var isConnected: Bool { connectedKind != nil }
    /// True when a key is saved on this device but is not (yet) a published connection — the buyer
    /// connected while the provider was unreachable, or a re-check was refused.
    var hasUnverifiedSavedCredential: Bool { !unverifiedMaskedLabel.isEmpty }
    /// The one honest sentence describing the stored credential's proof state (nil when there is
    /// nothing to disclose). Surfaced in onboarding, Settings, and the workspace banner.
    var verificationDisclosure: String? { verification?.disclosure }

    init(apiKeyProbe: @escaping AnthropicAPIKeyProbe = { key in
        await AnthropicCredentialProbe().verify(apiKey: key)
    }) {
        self.apiKeyProbe = apiKeyProbe
        refreshMetadata()
    }

    /// Startup/status path: reads only UserDefaults and file metadata, never credential bytes and
    /// never Security.framework.
    func refreshMetadata() {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let kindRecord = UserDefaults.standard.string(forKey: kindKey)
        let hasActiveCredential = HeadlessKeychain.active
            ? HeadlessKeychain.get("\(service)/\(account)") != nil
            : SovereignKeychain.exists(base)
        legacyRecoveryAvailable = kindRecord != nil && !hasActiveCredential
        guard hasActiveCredential else {
            connectedKind = nil
            maskedLabel = ""
            verification = nil
            unverifiedMaskedLabel = ""
            return
        }
        let kind = ExternalCredentialKind(rawValue: kindRecord ?? "") ?? .apiKey
        let state = ExternalCredentialPolicy.verification(
            kind: kind,
            storedMarker: UserDefaults.standard.string(forKey: verificationKey),
            legacyVerifiedFlag: UserDefaults.standard.bool(forKey: apiKeyVerifiedKey),
            kindRecordPresent: kindRecord != nil)
        verification = state
        let masked = UserDefaults.standard.string(forKey: maskedKey) ?? "Saved credential"
        if state.isConnectable {
            connectedKind = kind
            maskedLabel = masked
            unverifiedMaskedLabel = ""
        } else {
            connectedKind = nil
            maskedLabel = ""
            unverifiedMaskedLabel = masked
        }
    }

    /// Reload connection state from the active private store after foreground changes.
    /// A SAVED-but-unproven credential is published as "saved, not connected" — never dropped on
    /// the floor, never advertised as a working brain.
    func refresh() {
        guard let (cred, state) = loadStored() else {
            connectedKind = nil
            maskedLabel = ""
            verification = nil
            unverifiedMaskedLabel = ""
            legacyRecoveryAvailable = UserDefaults.standard.string(forKey: kindKey) != nil
            return
        }
        legacyRecoveryAvailable = false
        UserDefaults.standard.set(cred.masked, forKey: maskedKey)
        verification = state
        if state.isConnectable {
            connectedKind = cred.kind
            maskedLabel = cred.masked
            unverifiedMaskedLabel = ""
        } else {
            connectedKind = nil
            maskedLabel = ""
            unverifiedMaskedLabel = cred.masked
        }
    }

    /// Validate an API key's shape WITHOUT a network call (offline, honest, no false "valid").
    /// Real validity is proven the first time the brain makes a call — we never claim it works
    /// until a request actually succeeds.
    nonisolated static func looksLikeAPIKey(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("sk-ant-") && s.count >= 24
    }

    nonisolated static func storedCredentialKindForSmoke() -> String? {
        // Smoke output is status metadata only. Do not read the Keychain here: stale legacy ACLs can
        // block headless installed-app proof before it prints any connector verdict.
        guard let kindRaw = UserDefaults.standard.string(forKey: kindUserDefaultsKey),
              !kindRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let kind = ExternalCredentialKind(rawValue: kindRaw) ?? .apiKey
        let state = ExternalCredentialPolicy.verification(
            kind: kind,
            storedMarker: UserDefaults.standard.string(forKey: verificationUserDefaultsKey),
            legacyVerifiedFlag: UserDefaults.standard.bool(forKey: apiKeyVerifiedUserDefaultsKey),
            kindRecordPresent: true)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let exists = HeadlessKeychain.active
            ? HeadlessKeychain.get("\(keychainService)/\(keychainAccount)") != nil
            : SovereignKeychain.exists(base)
        return state.isConnectable && exists ? kind.rawValue : nil
    }

    /// Connect the buyer's own External API key. Shape is only an input gate; a real Anthropic
    /// Models request must succeed before the app publishes "connected".
    ///
    /// M3 (2026-08-02): a NETWORK failure no longer discards the key. Unreachable ⇒ the key is
    /// SAVED in the private store, marked `.pending`, honestly reported as unverified, and re-checked on
    /// launch or on demand. Only an actual provider REJECTION stores nothing.
    @discardableResult
    func connect(apiKey raw: String) async -> ExternalConnectOutcome {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.looksLikeAPIKey(s) else {
            return .invalidShape("That doesn't look like an Anthropic API key. Keys start with “sk-ant-”. Get one at console.anthropic.com.")
        }
        let outcome = ExternalCredentialPolicy.outcome(for: await apiKeyProbe(s))
        switch outcome {
        case .rejected, .invalidShape, .storeFailed:
            return outcome
        case .verified:
            guard store(ExternalCredential(kind: .apiKey, secret: s), verification: .verified) else {
                return .storeFailed("Anthropic verified the key, but Sovereign could not save it in its private credential store.")
            }
            refresh()
            guard isConnected else {
                disconnect()
                return .storeFailed("Anthropic verified the key, but Sovereign could not save it in its private credential store. It is not connected; check storage access and try again.")
            }
            activity?.record(kind: .connector, title: "External account",
                             detail: "Connected an external API key stored in Sovereign's private on-device credential directory.",
                             outcome: .success)
            return .verified
        case .savedPendingVerification(let message):
            guard store(ExternalCredential(kind: .apiKey, secret: s), verification: .pending) else {
                return .storeFailed("Sovereign could not save the key in its private credential store.")
            }
            refresh()
            guard savedUnverifiedCredential() != nil else {
                return .storeFailed("Sovereign could not save the key in its private credential store. Check storage access and try again.")
            }
            activity?.record(kind: .connector, title: "External account",
                             detail: "Saved an external API key that could NOT be verified yet — the provider was unreachable. It stays on this device and is re-checked; it is not connected until a check succeeds.",
                             outcome: .info)
            return .savedPendingVerification(message)
        }
    }

    /// Message-only wrapper kept for callers that just need "did this fail, and what do I say".
    @discardableResult
    func connectAPIKey(_ raw: String) async -> String? { await connect(apiKey: raw).message }

    /// Re-check a key that is saved but unproven (`.pending`), carried over from an older build
    /// (`.grandfathered`), or previously refused (`.rejected`). Called at launch and by the buyer's
    /// "Verify now". A provider we still cannot REACH never downgrades the stored state — the key
    /// stays exactly where it is. Returns the state after the check.
    @discardableResult
    func reverifyIfNeeded() async -> ExternalCredentialVerification? {
        guard let (cred, state) = loadStored(), cred.kind == .apiKey else { return verification }
        guard state == .pending || state == .grandfathered || state == .rejected else { return state }
        switch await apiKeyProbe(cred.secret) {
        case .verified:
            store(cred, verification: .verified)
            refresh()
            return .verified
        case .rejected:
            store(cred, verification: .rejected)
            refresh()
            return .rejected
        case .unverified:
            // Still unreachable. The key is untouched and stays saved for the next attempt.
            return state
        }
    }

    /// Connect an OAuth access token (the buyer's own External login). Used by the Sign in flow.
    func connectOAuthToken(_ token: String) {
        let s = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        guard store(ExternalCredential(kind: .oauth, secret: s)) else { return }
        refresh()
        activity?.record(kind: .connector, title: "External account",
                         detail: "Connected an external OAuth token stored in Sovereign's private on-device credential directory.",
                         outcome: .success)
    }

    /// Connect the buyer's own External SUBSCRIPTION via the `external` CLI (macOS-only). No secret is
    /// stored — auth lives in the CLI's own `external login` session. We persist only the non-sensitive
    /// resolved CLI path so the brain can find the binary. The CALLER must have already PROVEN a real
    /// `external -p` round-trip succeeds before calling this — we never store "connected" on faith.
    func connectCLI(cliPath: String) {
        let p = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        guard store(ExternalCredential(kind: .cli, secret: p)) else { return }
        refresh()
        activity?.record(kind: .connector, title: "External CLI",
                         detail: "Connected a legacy external CLI path on this device.",
                         outcome: .success)
    }

    /// Connect the buyer's own Secondary CLI. No OpenAI API key is stored here — Secondary keeps auth in
    /// its own CLI account/config. The caller must already have proven a real `secondary exec` round-trip.
    func connectSecondaryCLI(cliPath: String) {
        let p = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else { return }
        guard store(ExternalCredential(kind: .secondaryCLI, secret: p)) else { return }
        refresh()
        activity?.record(kind: .connector, title: "External CLI",
                         detail: "Connected a legacy external CLI path on this device.",
                         outcome: .success)
    }

    /// Connect ANY prompt-capable CLI on PATH as the brain. No API key is stored — the `secret` is
    /// the buyer's command TEMPLATE (a non-sensitive JSON spec). The CALLER must have already PROVEN a
    /// real round-trip succeeds before calling this — we never store "connected" on faith.
    func connectCustomCLI(spec: CustomCLISpec) {
        let encoded = spec.encoded()
        guard !encoded.isEmpty else { return }
        guard store(ExternalCredential(kind: .customCLI, secret: encoded)) else { return }
        refresh()
        activity?.record(kind: .connector, title: "Custom CLI brain",
                         detail: "Connected your own `\(spec.displayName)` command as the brain (no API key stored — Sovereign runs your command on this device).",
                         outcome: .success)
    }

    /// Disconnect — removes only the active private credential file on this device.
    func disconnect() {
        let wasConnected = isConnected
        if HeadlessKeychain.active {
            HeadlessKeychain.delete("\(service)/\(account)")
        } else {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            SovereignKeychain.delete(q)
        }
        UserDefaults.standard.removeObject(forKey: kindKey)
        UserDefaults.standard.removeObject(forKey: apiKeyVerifiedKey)
        UserDefaults.standard.removeObject(forKey: verificationKey)
        UserDefaults.standard.removeObject(forKey: maskedKey)
        refreshMetadata()
        if wasConnected {
            activity?.record(kind: .connector, title: "External account",
                             detail: "Disconnected the external credential from Sovereign's private on-device credential directory.",
                             outcome: .info)
        }
    }

    /// Read the credential for a brain call. Returns nil when not connected.
    /// Intentionally NOT @Published — the secret is fetched only at send time.
    func currentCredential() -> ExternalCredential? { load() }

    /// The credential that is SAVED on this device but not published as connected (unreachable
    /// provider at connect time, or a refused re-check). Proof that the buyer's key was kept.
    func savedUnverifiedCredential() -> ExternalCredential? {
        guard let (cred, state) = loadStored(), !state.isConnectable else { return nil }
        return cred
    }

    /// One-time, foreground, non-destructive import of the credential left by an older build.
    @discardableResult
    func recoverLegacyCredential() -> SovereignLegacyRecoveryResult {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let result = SovereignKeychain.recoverLegacy(base)
        if result == .recovered { refresh() }
        return result
    }

    // MARK: - Prompt-free private-file primitives

    @discardableResult
    private func store(_ cred: ExternalCredential, verification state: ExternalCredentialVerification) -> Bool {
        guard let data = cred.secret.data(using: .utf8) else { return false }
        let stored: Bool
        if HeadlessKeychain.active {
            HeadlessKeychain.set("\(service)/\(account)", data)
            stored = true
        } else {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            stored = SovereignKeychain.set(base, data: data)
        }
        guard stored else { return false }
        UserDefaults.standard.set(cred.kind.rawValue, forKey: kindKey)
        UserDefaults.standard.set(cred.masked, forKey: maskedKey)
        let resolved: ExternalCredentialVerification = cred.kind == .apiKey ? state : .notApplicable
        UserDefaults.standard.set(resolved.rawValue, forKey: verificationKey)
        // Legacy boolean stays in sync for older read paths: true ONLY on a live-probe verification.
        if resolved == .verified { UserDefaults.standard.set(true, forKey: apiKeyVerifiedKey) }
        else { UserDefaults.standard.removeObject(forKey: apiKeyVerifiedKey) }
        return true
    }

    /// Non-API-key kinds carry no provider secret to verify.
    @discardableResult
    private func store(_ cred: ExternalCredential) -> Bool { store(cred, verification: .notApplicable) }

    /// The stored credential AND how much proof exists for it. Nil only when nothing is stored.
    private func loadStored() -> (ExternalCredential, ExternalCredentialVerification)? {
        let kindRecord = UserDefaults.standard.string(forKey: kindKey)
        let kind = ExternalCredentialKind(rawValue: kindRecord ?? "") ?? .apiKey
        let state = ExternalCredentialPolicy.verification(
            kind: kind,
            storedMarker: UserDefaults.standard.string(forKey: verificationKey),
            legacyVerifiedFlag: UserDefaults.standard.bool(forKey: apiKeyVerifiedKey),
            kindRecordPresent: kindRecord != nil)
        let data: Data
        if HeadlessKeychain.active {
            guard let d = HeadlessKeychain.get("\(service)/\(account)") else { return nil }
            data = d
        } else {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            guard let d = SovereignKeychain.copy(q) else { return nil }
            data = d
        }
        guard let secret = String(data: data, encoding: .utf8), !secret.isEmpty else { return nil }
        return (ExternalCredential(kind: kind, secret: secret), state)
    }

    /// The credential a brain call may use: connectable states only. An unproven key is never
    /// handed to a brain as if it were a working connection.
    private func load() -> ExternalCredential? {
        guard let (cred, state) = loadStored(), state.isConnectable else { return nil }
        return cred
    }
}
#endif // circuit-convert
