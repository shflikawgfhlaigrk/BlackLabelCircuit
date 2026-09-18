// Sovereign — backend: chat history, notes vault, accounts, persistence.
// Standalone. App Sandbox-safe (writes to the app container). Network only for weather (open-meteo).
import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(CommonCrypto) && !CIRCUIT_WINDOWS_SIM
import CommonCrypto   // PBKDF2 (salted password KDF) — available on macOS + iOS
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Domain models
enum ChatRole: String, Codable { case user, assistant, system }

struct ChatMessage: Identifiable, Codable, Hashable {
    var id = UUID()
    var role: ChatRole = .user
    var text: String = ""
    var created = Date()
}

// A dispatch is one operator action: a command routed to the local CLI brain, with an audit timestamp.
// This mirrors the website's "wake phrase -> dispatch -> CLI agent, with audit trails" model — honestly,
// here dispatch is triggered by you typing a command (no always-listening voice daemon in the App Store build).
struct Dispatch: Identifiable, Codable, Hashable {
    var id = UUID()
    var command: String = ""
    var note: String = ""
    var created = Date()
}

struct Note: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = "Untitled note"
    var body: String = ""
    var created = Date()
    var updated = Date()

    var preview: String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Empty note" }
        return String(trimmed.prefix(80))
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Persistence (real backend — Codable JSON in the sandbox container)
final class AppModel: ObservableObject {
    @Published var messages: [ChatMessage] = [] { didSet { save() } }
    @Published var notes: [Note] = [] { didSet { save() } }
    @Published var dispatches: [Dispatch] = [] { didSet { save() } }

    private struct Box: Codable {
        var messages: [ChatMessage]
        var notes: [Note]
        var dispatches: [Dispatch]?
    }
    private let url: URL
    /// Demo Mode: keep synthetic sample data in memory only, never on the buyer's disk.
    private var demoEphemeral = false
    /// True only while load() is repopulating from disk — suppresses the array didSet save()s so
    /// reading the buyer's data back never re-writes it (mirrors Store / ActivityLog).
    private var loading = false

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sovereign", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("data.json")
        load()
    }

    private func load() {
        loading = true; defer { loading = false }
        guard let data = try? Data(contentsOf: url) else { return }   // no file yet — fresh install
        guard let box = try? JSONDecoder().decode(Box.self, from: data) else {
            // Unreadable ≠ empty: park the bytes where the next save can't destroy them.
            preserveCorruptBlob(at: url)
            return
        }
        messages = box.messages; notes = box.notes; dispatches = box.dispatches ?? []
    }
    private func save() {
        guard !loading, !demoEphemeral else { return }
        let box = Box(messages: messages, notes: notes, dispatches: dispatches)
        if let data = try? JSONEncoder().encode(box) { try? data.write(to: url, options: .atomic) }
    }

    /// Seed clearly-labeled SAMPLE notes (Vault) for Demo Mode — in memory only. Idempotent.
    func seedDemo() {
        demoEphemeral = true   // ephemeral first → real data on disk is untouched; restored by endDemo()
        notes = DemoSeed.notes
        dispatches = DemoSeed.dispatches
    }
    /// Leave Demo Mode: drop sample data, restore the buyer's real on-disk state, re-enable saves.
    func endDemo() {
        demoEphemeral = true   // prevent the resets below from persisting
        messages = []; notes = []; dispatches = []
        load()
        demoEphemeral = false
    }

    /// Permanently erase ALL chat history, vault notes, and the dispatch log — in memory and on disk
    /// (App Store Guideline 5.1.1(v)). Persistence is re-enabled so the empty state is written.
    func wipeAll() {
        demoEphemeral = false
        messages = []; notes = []; dispatches = []
        save()
    }

    // Chat history
    func append(_ m: ChatMessage) { messages.append(m) }
    func clearChat() { messages.removeAll() }

    // Notes CRUD
    func upsert(_ n: Note) {
        var note = n; note.updated = Date()
        if let i = notes.firstIndex(where: { $0.id == n.id }) { notes[i] = note } else { notes.insert(note, at: 0) }
    }
    func deleteNote(_ n: Note) { notes.removeAll { $0.id == n.id } }

    // Operator dispatch log — every command routed to the local brain is recorded (audit trail).
    func logDispatch(_ command: String, note: String = "") {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        dispatches.insert(Dispatch(command: c, note: note), at: 0)
        if dispatches.count > 200 { dispatches = Array(dispatches.prefix(200)) }
    }
    func clearDispatches() { dispatches.removeAll() }

    var wordCount: Int {
        notes.reduce(0) { $0 + $1.body.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count }
    }

    // How many of each store actually grounds the brain. The UI reads these so the
    // memory-source labels reflect what the brain REALLY receives (never an inflated
    // count). Single source of truth — groundingContext() and Settings share them.
    static let notesGroundingCap = 12
    static let dispatchGroundingCap = 15

    /// The number of notes that actually feed the brain (≤ total). Honest for the UI.
    var groundedNotesCount: Int { min(notes.count, Self.notesGroundingCap) }
    /// The number of dispatches that actually feed the brain (≤ total). Honest for the UI.
    var groundedDispatchCount: Int { min(dispatches.count, Self.dispatchGroundingCap) }

    /// Builds grounding context for the brain from ONLY the buyer's own local data,
    /// gated by their memory-source toggles. Returns "" when nothing is enabled or
    /// stored — the brain then answers without injected context (never fabricated).
    func groundingContext(_ sources: MemorySources) -> String {
        var parts: [String] = []
        if sources.useNotes, !notes.isEmpty {
            let snippet = notes.prefix(Self.notesGroundingCap).map { n in
                let title = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = n.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)
                return "• \(title.isEmpty ? "Note" : title): \(body)"
            }.joined(separator: "\n")
            if !snippet.isEmpty { parts.append("Notes from the user's Vault:\n" + snippet) }
        }
        if sources.useDispatchLog, !dispatches.isEmpty {
            let snippet = dispatches.prefix(Self.dispatchGroundingCap).map { "• \($0.command)" }.joined(separator: "\n")
            if !snippet.isEmpty { parts.append("Recent dispatch commands:\n" + snippet) }
        }
        return parts.joined(separator: "\n\n")
    }

    // No seed/sample/demo data. The shipped app starts empty on the buyer's own
    // data — every value in the UI traces to something the buyer created, or to a
    // real live source (weather). Empty stores render honest empty states.
}
#endif // circuit-convert

// MARK: - Weather (real network — keyless open-meteo)
struct City: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let lat: Double
    let lon: Double
    // Functional picker for a keyless live weather feed (open-meteo). Generic
    // major-city list — no personal default baked in.
    static let all: [City] = [
        City(name: "New York, NY", lat: 40.71, lon: -74.01),
        City(name: "San Francisco, CA", lat: 37.77, lon: -122.42),
        City(name: "Chicago, IL", lat: 41.88, lon: -87.63),
        City(name: "Denver, CO", lat: 39.74, lon: -104.99),
        City(name: "Miami, FL", lat: 25.76, lon: -80.19)
    ]
}

// Current conditions resolved from Open-Meteo. Fahrenheit is the source unit (the
// engine requests it); Celsius is derived. Humidity, conditions text, and wind (mph)
// are folded in from the lean build's richer feed.
struct CurrentWeather: Equatable {
    var temperatureF: Double
    var windMph: Double
    var humidity: Double?            // % relative humidity (nil if the feed omits it)
    var conditions: String           // WMO-decoded conditions text
    var place: String                // resolved label (city the data is for)
    var temperatureC: Double { (temperatureF - 32) * 5/9 }
}

enum WeatherError: String, Error {
    case offline = "Couldn't reach the weather service. Check your connection and try again."
    case decode = "The weather service returned an unexpected response."
    case noMatch = "No place matched that search. Try \"City, ST\"."
}

enum WeatherService {
    /// Fetch live current conditions for a preset city (picker path).
    static func fetch(_ city: City) async -> Result<CurrentWeather, WeatherError> {
        await fetch(lat: city.lat, lon: city.lon, place: city.name)
    }

    /// Geocode a typed place, then fetch live current conditions for it.
    static func fetch(place query: String) async -> Result<CurrentWeather, WeatherError> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.noMatch) }
        do {
            let g = try await WeatherEngine.geocode(trimmed)
            return await fetch(lat: g.lat, lon: g.lon, place: g.name)
        } catch let e as WeatherError {
            return .failure(e)
        } catch {
            return .failure(.offline)
        }
    }

    /// Core fetch + decode against the engine's keyless Open-Meteo endpoint.
    static func fetch(lat: Double, lon: Double, place: String) async -> Result<CurrentWeather, WeatherError> {
        let url = WeatherEngine.weatherURL(lat: lat, lon: lon)
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let r = try? JSONDecoder().decode(WeatherEngine.OMResp.self, from: data),
                  let c = r.current, let t = c.temperature_2m else { return .failure(.decode) }
            return .success(CurrentWeather(
                temperatureF: t,
                windMph: c.wind_speed_10m ?? 0,
                humidity: c.relative_humidity_2m,
                conditions: WeatherEngine.conditions(for: c.weather_code),
                place: place))
        } catch {
            return .failure(.offline)
        }
    }
}

// MARK: - Local accounts (on-device, App Store 5.1.1(v) deletion supported)
enum AuthError: String, Error {
    case badEmail = "Enter a valid email address."
    case weakPw = "Password must be at least 6 characters."
    case exists = "An account with that email already exists — sign in instead."
    case noAccount = "No account found for that email — create one first."
    case wrongPw = "Incorrect password. Try again."
}
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Local password storage. Records are SALTED PBKDF2-HMAC-SHA256:
//   "pbkdf2$<iterations>$<saltBase64>$<derivedKeyBase64>"
// A random 16-byte salt per account defeats rainbow tables and makes two accounts with the same
// password store DIFFERENT bytes; the high iteration count makes brute force expensive. Legacy records
// (bare 64-hex unsalted SHA256(email::pw) from before this change) are still ACCEPTED on sign-in and
// transparently re-hashed to the salted form — no existing local account is ever locked out. Local +
// optional, exactly as before (this is an on-device convenience login, App Store 5.1.1(v) deletable).
enum AccountStore {
    static let key = "com.blacklabel.sovereign.accounts"
    static let pbkdf2Iterations = 210_000               // OWASP 2023 floor for PBKDF2-HMAC-SHA256
    private static let pbkdf2Prefix = "pbkdf2$"
    private static let derivedKeyBytes = 32
    static func load() -> [String: String] { (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:] }
    static func save(_ d: [String: String]) { UserDefaults.standard.set(d, forKey: key) }
    /// Single canonical email key. MUST trim newlines too (not just .whitespaces) — a
    /// pasted address with a trailing newline would otherwise be stored under a key the
    /// user can never reproduce by typing, permanently locking them out. Every create /
    /// signIn / delete / session-identity path routes through this so the credential key
    /// and the displayed "Signed in as" identity can never diverge.
    static func normalize(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// LEGACY unsalted hash — kept ONLY to verify + migrate pre-existing local accounts, never to
    /// store a new one. (Was the entire scheme before salting; now a compatibility shim.)
    static func legacyHash(_ e: String, _ p: String) -> String {
        SHA256.hash(data: Data((normalize(e) + "::" + p).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// PBKDF2-HMAC-SHA256 over the password with the given salt. Deterministic for a fixed salt
    /// (verification recomputes it), random across accounts because the salt is random. Pure.
    static func pbkdf2(password: String, salt: Data, iterations: Int, dkLen: Int = derivedKeyBytes) -> Data? {
        let pw = Array(password.utf8)
        guard !pw.isEmpty, !salt.isEmpty, iterations > 0, dkLen > 0 else { return nil }
        var dk = [UInt8](repeating: 0, count: dkLen)
        let status: Int32 = salt.withUnsafeBytes { saltRaw in
            pw.withUnsafeBytes { pwRaw in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwRaw.baseAddress!.assumingMemoryBound(to: CChar.self), pw.count,
                    saltRaw.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &dk, dkLen)
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(dk)
    }

    /// Build a fresh salted record for `pw` (a new random 16-byte salt each call).
    static func makeRecord(pw: String) -> String? {
        let saltData = Data(SymmetricKey(size: .bits128).withUnsafeBytes { Array($0) })   // 16 secure-random bytes
        guard let dk = pbkdf2(password: pw, salt: saltData, iterations: pbkdf2Iterations) else { return nil }
        return "\(pbkdf2Prefix)\(pbkdf2Iterations)$\(saltData.base64EncodedString())$\(dk.base64EncodedString())"
    }

    /// Constant-time equality (no early-out on the first differing byte).
    static func ctEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }

    /// Verify `pw` against a `stored` record. Returns whether it matched and whether the record is a
    /// legacy (unsalted) one that should be transparently upgraded to the salted KDF on this sign-in.
    static func verify(stored: String, email: String, pw: String) -> (ok: Bool, needsUpgrade: Bool) {
        if stored.hasPrefix(pbkdf2Prefix) {
            let parts = stored.components(separatedBy: "$")          // ["pbkdf2", iter, saltB64, dkB64]
            guard parts.count == 4, let iter = Int(parts[1]),
                  let salt = Data(base64Encoded: parts[2]), let dk = Data(base64Encoded: parts[3]),
                  let computed = pbkdf2(password: pw, salt: salt, iterations: iter, dkLen: dk.count) else {
                return (false, false)
            }
            return (ctEqual(computed, dk), false)
        }
        // Legacy unsalted SHA256(email::pw) — accept, and flag for transparent upgrade if it matched.
        let ok = ctEqual(Data(stored.utf8), Data(legacyHash(email, pw).utf8))
        return (ok, ok)
    }

    static func create(_ email: String, _ pw: String) -> Result<Void, AuthError> {
        let e = normalize(email)
        guard e.contains("@"), e.contains(".") else { return .failure(.badEmail) }
        guard pw.count >= 6 else { return .failure(.weakPw) }
        var a = load(); if a[e] != nil { return .failure(.exists) }
        guard let record = makeRecord(pw: pw) else { return .failure(.weakPw) }   // KDF failure ⇒ treat as invalid input
        a[e] = record; save(a); return .success(())
    }
    static func signIn(_ email: String, _ pw: String) -> Result<Void, AuthError> {
        let e = normalize(email); var a = load()
        guard let stored = a[e] else { return .failure(.noAccount) }
        let result = verify(stored: stored, email: e, pw: pw)
        guard result.ok else { return .failure(.wrongPw) }
        if result.needsUpgrade, let upgraded = makeRecord(pw: pw) {
            a[e] = upgraded; save(a)   // transparent migration: legacy SHA256 → salted PBKDF2, never a lockout
        }
        return .success(())
    }
    static func delete(_ email: String) { var a = load(); a[normalize(email)] = nil; save(a) }
    /// Remove EVERY local account credential. Used by the full "delete account and all data"
    /// flow (App Store Guideline 5.1.1(v)) so no email/password record survives the wipe.
    static func deleteAll() { UserDefaults.standard.removeObject(forKey: key) }
}
#endif // circuit-convert

// MARK: - Full local-data wipe (App Store Guideline 5.1.1(v))
//
// "Delete account" on a top-tier app must remove ALL of the user's data, not just the login.
// `DataWipe` is the single source of truth for every place this app persists buyer data, so the
// destructive action can erase the lot in one call and nothing is silently left behind.
//
//  - JSON stores in ~/Library/Containers/<bundle>/…/Application Support/Sovereign/ (Codable boxes)
//  - UserDefaults keys (settings, memory, prompts, skills, custom agents, profiles, accounts,
//    connector toggles, onboarding flag)
//  - the active private credential files (removed by their owning stores)
//
// The in-memory @Published state is cleared by the live stores' own `wipeAll()` methods (called
// alongside this) so the UI empties instantly; this enum guarantees the on-disk truth matches.
enum DataWipe {
    /// Every UserDefaults key this app writes. Kept here next to the stores that own them so a new
    /// persisted key is a one-line addition and the wipe can never drift out of sync.
    static let userDefaultsKeys: [String] = [
        "com.blacklabel.sovereign.settings.v1",
        "com.blacklabel.sovereign.memory.v1",
        "com.blacklabel.sovereign.memory.enabled.v1",
        "com.blacklabel.sovereign.prompts.v1",
        "com.blacklabel.sovereign.skills.v1",
        "com.blacklabel.sovereign.customagents.v1",
        "com.blacklabel.sovereign.profiles.v1",
        "com.blacklabel.sovereign.accounts",
        "com.blacklabel.sovereign.calendar.enabled.v1",
        "com.blacklabel.sovereign.filesources.v1",
        "com.blacklabel.sovereign.external.kind.v1",
        "com.blacklabel.sovereign.external.api-key-verified.v1",
        "com.blacklabel.sovereign.external.masked-label.v1",
        "com.blacklabel.sovereign.session.remembered-identity.v2",
        // M3/M4: the non-secret credential-verification marker (verified/pending/grandfathered/
        // rejected). A wipe must clear it too, or a re-install reads a stale proof state.
        "com.blacklabel.sovereign.external.verification.v2",
        "com.blacklabel.sovereign.onboarded",
        "com.blacklabel.sovereign.ambient.enabled.v1",
        // SV-18 recall vault: the entries blob, both opt-in flags, and the sampling interval. Omitting
        // these left the OCR'd screen-text vault on disk after a full "delete account and all data".
        "com.blacklabel.sovereign.recall.v1",
        "com.blacklabel.sovereign.recall.optin.v1",
        "com.blacklabel.sovereign.recall.scheduled.optin.v1",
        "com.blacklabel.sovereign.recall.scheduled.interval.v1",
    ]

    /// The JSON files written under Application Support/Sovereign/.
    static let storeFilenames: [String] = ["store.json", "data.json", "activity.json", "crm.json"]

    /// The Application Support/Sovereign directory holding the JSON stores.
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Sovereign", isDirectory: true)
    }

    static var credentialDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabel/Sovereign/secrets", isDirectory: true)
    }

    /// Erase every on-disk artifact: JSON stores, active credential files, and UserDefaults keys.
    static func wipeDisk() {
        let dir = supportDirectory
        for name in storeFilenames {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
        // The ambient timeline (SQLite) lives under Sovereign/ambient/ — wipe the whole subdir so
        // no captured on-screen context survives a "delete all data".
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("ambient", isDirectory: true))
        // This is the explicit delete-all path. Normal disconnects delete one active file and retain
        // all legacy Keychain rows; only the buyer's full wipe removes the complete private store.
        try? FileManager.default.removeItem(at: credentialDirectory)
        let d = UserDefaults.standard
        for key in userDefaultsKeys { d.removeObject(forKey: key) }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - "Remember me" — persist the signed-in identity across cold starts.
//
// The local account/identity lives in UserDefaults. "Remember me" persists JUST the identity (an
// email string, never a password) in UserDefaults, so restoring it is metadata-only and can never
// involve SecurityAgent. Unchecked = unchanged behavior
// (no persistence; signed out on next launch). HONEST: only a real prior sign-in is restored; the
// guest/demo identities are never remembered.
enum RememberedSession {
    private static let service = "com.blacklabel.sovereign.session"
    private static let account = "remembered-identity"
    private static let identityKey = "com.blacklabel.sovereign.session.remembered-identity.v2"

    /// Persist the signed-in email so the next launch can auto-restore. Never stores a password.
    static func remember(email: String) {
        let e = AccountStore.normalize(email)
        // Don't remember the ephemeral guest/demo identities — they aren't real accounts.
        guard !e.isEmpty, e != "guest", e != "demo", let data = e.data(using: .utf8) else { return }
        _ = data
        UserDefaults.standard.set(e, forKey: identityKey)
    }

    /// The remembered email, or nil if "Remember me" was never used (or was cleared / signed out).
    static func restore() -> String? {
        guard let email = UserDefaults.standard.string(forKey: identityKey), !email.isEmpty else { return nil }
        return email
    }

    /// Forget the remembered identity (sign out, "Remember me" unchecked, or full data wipe).
    static func forget() {
        UserDefaults.standard.removeObject(forKey: identityKey)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SovereignKeychain.delete(q)
    }

    /// The old Keychain session is read only after a buyer presses the recovery button. The row is
    /// retained; only the non-secret normalized identity is copied into the metadata store.
    static func recoverLegacy() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        guard SovereignKeychain.recoverLegacy(q) == .recovered,
              let data = SovereignKeychain.copy(q),
              let email = String(data: data, encoding: .utf8) else { return false }
        let normalized = AccountStore.normalize(email)
        guard !normalized.isEmpty, normalized != "guest", normalized != "demo" else { return false }
        UserDefaults.standard.set(normalized, forKey: identityKey)
        return true
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
final class Session: ObservableObject {
    @Published var signedIn = false
    @Published var email = ""
    init() {
        if let remembered = RememberedSession.restore() {
            email = remembered
            signedIn = true
        }
    }
}
#endif // circuit-convert
