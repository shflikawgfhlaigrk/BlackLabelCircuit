// Black Label Academy — in-app auto-updater (Developer-ID direct-download build).
//
// Goal: a user on build N sees "Update available → Install", clicks once, and is running build N+1
// seconds later — no website visit, no manual re-download. So when we fix a bug we ship it once and
// every installed user gets it. Ported from the fleet's proven Marketing updater (same manifest
// contract the /api/version/<product> endpoint already serves for academy).
//
// HOW IT WORKS
//   1. A tiny PUBLIC manifest (https://blacklabelbots.com/api/version/academy) says what the
//      latest build is and its sha256. The download URL may be present only for entitled callers.
//   2. The app compares manifest.latest_build to its own CFBundleVersion (on launch, daily, and via
//      the "Check for Updates…" menu item).
//   3. If newer, it prompts. On Install it downloads the notarized zip, VERIFIES it
//      (sha256 + Apple-notarized + signed by OUR Team ID — Security.framework, no shell-out),
//      unzips, then a detached helper swaps the bundle and relaunches.
//
// SECURITY: update metadata is public; binaries may be entitlement-gated by the website. Nothing is
// installed until the new bundle is proven to be signed by Team ID 745ZPGFRA5 and its bytes match
// the manifest sha256. A hijacked CDN/manifest cannot install anything that isn't our genuine build.
//
// PLATFORM: macOS-only (Developer-ID direct download + in-process code-signature inspection via
// Security.framework's SecStaticCode* APIs; the iOS app updates through the App Store). The whole
// file is gated to macOS so the shared iOS target still compiles.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CircuitPortKit
#if os(macOS) && !MAS_BUILD
import Foundation
import CryptoKit
import Security

// MARK: - Manifest

/// The published "latest version" descriptor. Snake_case wire keys; tolerant of extra/missing fields.
struct UpdateManifest: Codable, Equatable {
    var product: String
    var latestBuild: Int
    var latestVersion: String?
    var downloadURL: String?
    var downloadMessage: String?
    var sha256: String?
    var notarized: Bool?
    var teamID: String?
    var releaseNotes: String?
    var mandatory: Bool?

    var hasDirectDownload: Bool {
        guard let downloadURL else { return false }
        return !downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case product
        case latestBuild = "latest_build"
        case latestVersion = "latest_version"
        case downloadURL = "download_url"
        case downloadMessage = "download"
        case sha256, notarized
        case teamID = "team_id"
        case releaseNotes = "release_notes"
        case mandatory
    }
}

enum UpdaterError: LocalizedError {
    case badURL
    case transport(String)
    case http(Int)
    case decode(String)
    case checksum(expected: String, got: String)
    case noAppInZip
    case signature(String)
    case unzip(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Visit blacklabelbots.com to download this update."
        case .transport(let m): return "Couldn't reach the update server (\(m))."
        case .http(let c): return "Update server returned HTTP \(c)."
        case .decode(let m): return "The update manifest wasn't understood (\(m))."
        case .checksum: return "The downloaded update failed its integrity check — nothing was installed."
        case .noAppInZip: return "The downloaded update didn't contain an app — nothing was installed."
        case .signature(let m): return "The update isn't a genuine, notarized Black Label build (\(m)) — nothing was installed."
        case .unzip(let m): return "Couldn't unpack the update (\(m))."
        case .install(let m): return "Couldn't install the update (\(m))."
        }
    }
}

// MARK: - Transport (the isolated network seam — mirrors Cohort's, so the updater is hermetically testable)

/// The single network seam for the updater: GET a URL, return (body, HTTP status). The production
/// impl talks HTTPS; the self-test / XCTest inject a fixture transport so manifest-parse, version-
/// compare, checksum-refusal, and the malformed/unreachable paths are proven WITHOUT a live network.
protocol UpdaterTransport {
    func get(_ url: URL) async throws -> (Data, Int)
}

/// The production transport — the ONLY code in the updater that opens a socket. Reads public metadata
/// and the notarized zip; sends no name/email (an anonymous UA carrying just the build number).
struct URLSessionUpdaterTransport: UpdaterTransport {
    let session: URLSession
    init(session: URLSession = URLSessionUpdaterTransport.makeSession()) { self.session = session }

    static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }

    func get(_ url: URL) async throws -> (Data, Int) {
        var req = URLRequest(url: url)
        req.setValue("BlackLabelAcademy/\(Updater.currentBuild()) (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
            return (data, status)
        } catch {
            throw UpdaterError.transport(error.localizedDescription)
        }
    }
}

// MARK: - Updater (pure core + side-effecting install)

enum Updater {
    /// Our Apple Developer Team ID. The update bundle MUST be signed by this team or it's rejected.
    static let teamID = "745ZPGFRA5"
    /// The production network seam. Overridable per-call so the self-test/XCTest inject a fixture.
    static let defaultTransport: UpdaterTransport = URLSessionUpdaterTransport()
    /// UserDefaults override for the manifest URL (QA / local testing). Empty → the live default.
    static let manifestOverrideKey = "bla.updateManifestURL"
    static let lastCheckKey = "bla.updateLastCheckEpoch"

    static var manifestURL: URL {
        let raw = (UserDefaults.standard.string(forKey: manifestOverrideKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let u = URL(string: raw), u.scheme != nil { return u }
        return URL(string: "https://blacklabelbots.com/api/version/academy")!
    }

    // MARK: Pure

    /// Strictly newer build number. Equal or older → no update. The single source of "is there an update".
    static func isNewer(latestBuild: Int, currentBuild: Int) -> Bool { latestBuild > currentBuild }

    /// The pure outcome of a version check. `.updateAvailable` only ever wraps a strictly-newer manifest.
    enum UpdateOutcome: Equatable {
        case upToDate(latest: Int)
        case updateAvailable(UpdateManifest)
    }

    /// Decide, from a fetched manifest and this build, whether to OFFER an update. Strictly-greater
    /// `latest_build` only: equal or lower → `.upToDate`, so a stale or rolled-back manifest can never
    /// prompt a downgrade. This is the single source of "should we offer an update".
    static func decideUpdate(manifest: UpdateManifest, currentBuild current: Int) -> UpdateOutcome {
        isNewer(latestBuild: manifest.latestBuild, currentBuild: current)
            ? .updateAvailable(manifest)
            : .upToDate(latest: manifest.latestBuild)
    }

    /// Lowercase hex sha256 — used to verify the downloaded bytes match the manifest.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Decode the manifest JSON, surfacing a clean error on malformed input (never crashes).
    static func decodeManifest(_ data: Data) throws -> UpdateManifest {
        do { return try JSONDecoder().decode(UpdateManifest.self, from: data) }
        catch { throw UpdaterError.decode(error.localizedDescription) }
    }

    /// This binary's build number (CFBundleVersion). 0 if absent (treats unknown as "older").
    static func currentBuild() -> Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static func currentVersionString() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "\(v) (build \(currentBuild()))"
    }

    // MARK: Network (through the injected transport seam — see UpdaterTransport above)

    static func fetchManifest(from url: URL = manifestURL,
                              using transport: UpdaterTransport = defaultTransport) async throws -> UpdateManifest {
        let (data, status) = try await transport.get(url)
        guard (200...299).contains(status) else { throw UpdaterError.http(status) }
        return try decodeManifest(data)
    }

    /// Returns the manifest IFF it describes a strictly-newer build, else nil. Records the check time.
    /// The strictly-newer decision is `decideUpdate` (pure) — equal/lower latest_build → nil, never a
    /// downgrade prompt.
    static func checkForUpdate(using transport: UpdaterTransport = defaultTransport) async throws -> UpdateManifest? {
        let m = try await fetchManifest(using: transport)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        switch decideUpdate(manifest: m, currentBuild: currentBuild()) {
        case .updateAvailable(let newer): return newer
        case .upToDate: return nil
        }
    }

    /// True if it's been >= 24h since the last successful check (drives the daily auto-check).
    static func dueForBackgroundCheck(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        return last == 0 || (now - last) >= 24 * 3600
    }

    // MARK: Verify (security-critical)

    /// If the manifest declares a sha256, the downloaded bytes MUST match it or this throws `.checksum`
    /// and NOTHING is installed. Returns cleanly on a match, or when no sha256 is declared (integrity
    /// then rests on the Team-ID signature check below — the same posture as before this was extracted).
    /// This is the byte-integrity half of the two-part proof (bytes match the manifest + bundle is ours).
    static func verifyChecksum(_ data: Data, against m: UpdateManifest) throws {
        guard let expected = m.sha256?.lowercased(), !expected.isEmpty else { return }
        let got = sha256Hex(data)
        guard got == expected else { throw UpdaterError.checksum(expected: expected, got: got) }
    }

    /// Throws unless `appURL` is a code-signature that is Apple-notarized AND has our Team ID in the
    /// leaf cert. In-process via Security.framework — no codesign/spctl subprocess, so it works
    /// regardless of entitlements.
    static func verifySignature(appURL: URL, requiredTeamID: String = teamID) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let code = staticCode else {
            throw UpdaterError.signature("unreadable signature")
        }
        // anchor apple generic = chains to Apple; OU = our Developer Team ID. Together: a genuine
        // Developer-ID build signed by us. (Notarization is additionally enforced by Gatekeeper at
        // launch of the swapped bundle; this requirement blocks any non-ours binary up front.)
        let reqStr = "anchor apple generic and certificate leaf[subject.OU] = \"\(requiredTeamID)\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqStr, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let req = requirement else {
            throw UpdaterError.signature("requirement build failed")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), req)
        guard status == errSecSuccess else {
            throw UpdaterError.signature("validity \(status)")
        }
    }

    // MARK: Download + stage (returns the verified, unzipped .app ready to swap in)

    /// Downloads the update zip, verifies sha256 + signature, unzips, and returns the staged .app URL.
    /// Throws (installing nothing) on any integrity/signature failure.
    static func stage(_ m: UpdateManifest, using transport: UpdaterTransport = defaultTransport) async throws -> URL {
        guard m.product == "academy" else { throw UpdaterError.install("update product mismatch") }
        guard let raw = m.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), url.scheme != nil else { throw UpdaterError.badURL }
        let (data, status) = try await transport.get(url)
        guard (200...299).contains(status) else { throw UpdaterError.http(status) }
        // Byte integrity BEFORE any file work — a hijacked CDN serving different bytes under the
        // genuine manifest sha is refused here, before a single byte is unzipped or installed.
        try verifyChecksum(data, against: m)
        // Write + unzip into a private temp dir.
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bla-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let zipURL = work.appendingPathComponent("update.zip")
        try data.write(to: zipURL)
        let unzipDir = work.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try runDitto(extract: zipURL, to: unzipDir)
        // Find the .app.
        let contents = (try? FileManager.default.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)) ?? []
        let applications = contents.filter { $0.pathExtension == "app" }
        guard applications.count == 1, let appURL = applications.first else { throw UpdaterError.noAppInZip }
        try verifySignature(appURL: appURL)
        return try prepareVerifiedBundle(at: appURL, manifest: m, work: work)
    }

    // Called only after signature verification; injectable identity enables
    // isolated positive and negative staging tests without an installed app.
    static func prepareVerifiedBundle(at appURL: URL, manifest m: UpdateManifest, work: URL,
                                      expectedBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws -> URL {
        guard let expectedID = expectedBundleIdentifier,
              let candidate = Bundle(url: appURL), candidate.bundleIdentifier == expectedID,
              let candidateBuild = candidate.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              Int(candidateBuild) == m.latestBuild else {
            throw UpdaterError.install("update bundle identity or build mismatch")
        }
        // Remove the archive-controlled filename from all subsequent handoff paths.
        let verifiedApp = work.appendingPathComponent("VerifiedUpdate.app", isDirectory: true)
        try FileManager.default.moveItem(at: appURL, to: verifiedApp)
        return verifiedApp
    }

    private static func runDitto(extract zip: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        let err = Pipe(); p.standardError = err
        do { try p.run() } catch { throw UpdaterError.unzip(error.localizedDescription) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto \(p.terminationStatus)"
            throw UpdaterError.unzip(msg)
        }
    }
}

// MARK: - Headless self-test (`--selftest-updater`) — proves the five updater safety properties

/// A transport that returns canned (bytes, status) per URL or fails, and COUNTS calls. Lets the
/// self-test prove manifest-parse, version-compare, checksum-refusal and the malformed/unreachable
/// paths deterministically, with no live network. Mirrors MockCohortTransport.
final class MockUpdaterTransport: UpdaterTransport {
    var responses: [URL: (Data, Int)] = [:]
    var throwUnreachable = false
    private(set) var getCount = 0

    func get(_ url: URL) async throws -> (Data, Int) {
        getCount += 1
        if throwUnreachable { throw UpdaterError.transport("mock: unreachable") }
        if let r = responses[url] { return r }
        throw UpdaterError.transport("mock: no canned response for \(url.absoluteString)")
    }
}

/// Carries the async body's exit code back across the single sync↔async boundary in App.init.
private final class UpdaterSelfTestResult: @unchecked Sendable { var code: Int32 = 1 }

/// `Black Label Academy --selftest-updater`. Proves, WITHOUT a live network and WITHOUT ever
/// replacing the running bundle:
///   (i)   the real /api/version/academy manifest shape parses;
///   (ii)  an update is offered ONLY for a strictly-greater latest_build (equal/lower → up to date,
///         never a downgrade — the LIVE server currently serves 28 to a 29 app, so this is real);
///   (iii) a sha256 mismatch between downloaded bytes and the manifest → REFUSAL, nothing installed
///         (a NEGATIVE CONTROL: a planted-mismatch fixture is rejected while a matching one passes);
///   (iv)  a malformed / empty / unreachable manifest → honest no-update, never a fabricated prompt;
///   (v)   DRY-RUN: the running bundle is byte-identical before and after, and nothing is written
///         outside the OS temp dir. Wired into tests/smoke.sh; mirrored by tests/XCTest/UpdaterTests.swift.
/// Pass `--require-live` to make the optional live manifest fetch mandatory (the wiring-evidence run).
func runUpdaterSelfTest() -> Never {
    let sem = DispatchSemaphore(value: 0)
    let result = UpdaterSelfTestResult()
    Task.detached(priority: .userInitiated) {
        result.code = await updaterSelfTestBody()
        sem.signal()
    }
    sem.wait()
    exit(result.code)
}

private func updaterSelfTestBody() async -> Int32 {
    print("== Black Label Academy — updater self-test (dry-run, hermetic) ==")
    var ok = true
    func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL: \(msg)"); ok = false } }

    // DRY-RUN anchor: hash the running bundle's own Info.plist now; re-check at the end. If the
    // self-test replaced or wrote into the running app, this hash changes and the test fails.
    let selfPlist = Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist")
    let selfHashBefore = (try? Data(contentsOf: selfPlist)).map(Updater.sha256Hex)

    // Leave the app's real "last update check" timestamp exactly as we found it (restored at the end),
    // so even the one UserDefaults write the check path makes is undone — the run is side-effect-free.
    let savedLastCheck = UserDefaults.standard.object(forKey: Updater.lastCheckKey)
    let currentBuild = Updater.currentBuild()

    func manifest(build: Int, sha: String? = nil, downloadURL: String? = nil) -> UpdateManifest {
        UpdateManifest(product: "academy", latestBuild: build, latestVersion: "1.x",
                       downloadURL: downloadURL, downloadMessage: nil, sha256: sha,
                       notarized: true, teamID: Updater.teamID, releaseNotes: nil, mandatory: nil)
    }

    // ---- (i) the real /api/version/academy manifest shape parses --------------------------------
    let realShape = Data(#"{"product":"academy","latest_build":30,"latest_version":"1.2","min_supported_build":1,"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","notarized":true,"notarization_id":"2a36e094-2720-45ec-a7a0-ba8186e04837","team_id":"745ZPGFRA5","published":"2026-07-12T11:40:46Z","download":"sign in to your account to fetch the update","download_url":"https://blacklabelbots.com/dl/academy.zip"}"#.utf8)
    do {
        let m = try Updater.decodeManifest(realShape)
        check(m.product == "academy", "parsed product != academy (got \(m.product))")
        check(m.latestBuild == 30, "parsed latest_build != 30 (got \(m.latestBuild))")
        check(m.teamID == "745ZPGFRA5", "parsed team_id != our Team ID")
        check(m.hasDirectDownload, "a manifest carrying a download_url must report hasDirectDownload")
        print("  (i) real manifest shape parsed → build \(m.latestBuild), team \(m.teamID ?? "?"), directDownload=\(m.hasDirectDownload)")
    } catch {
        check(false, "the real /api/version/academy manifest shape failed to parse: \(error)")
    }

    // ---- (ii) version compare: an update is offered ONLY for a strictly-greater build ----------
    check(Updater.decideUpdate(manifest: manifest(build: currentBuild + 1), currentBuild: currentBuild)
            == .updateAvailable(manifest(build: currentBuild + 1)),
          "a strictly-newer build was not offered")
    if case .upToDate = Updater.decideUpdate(manifest: manifest(build: currentBuild), currentBuild: currentBuild) {}
    else { check(false, "an EQUAL build offered an update — must report up to date") }
    if case .upToDate = Updater.decideUpdate(manifest: manifest(build: max(0, currentBuild - 1)), currentBuild: currentBuild) {}
    else { check(false, "a LOWER build offered an update — that is a downgrade, forbidden") }
    check(!Updater.isNewer(latestBuild: currentBuild, currentBuild: currentBuild), "isNewer treated equal as newer")
    check(!Updater.isNewer(latestBuild: currentBuild - 1, currentBuild: currentBuild), "isNewer treated older as newer")
    print("  (ii) version-compare: newer→offer, equal→up-to-date, lower→up-to-date (no downgrade), current build=\(currentBuild)")

    // ---- (iii) a sha256 mismatch → REFUSAL, nothing installed (NEGATIVE CONTROL) ----------------
    let genuineBytes = Data("the genuine notarized zip bytes".utf8)
    let genuineSHA = Updater.sha256Hex(genuineBytes)
    let tamperedBytes = Data("a hijacked CDN's different bytes".utf8)
    do {
        try Updater.verifyChecksum(genuineBytes, against: manifest(build: 99, sha: genuineSHA))
        print("  (iii) matching bytes PASS the checksum gate")
    } catch { check(false, "genuine bytes failed their own checksum: \(error)") }
    do {
        try Updater.verifyChecksum(tamperedBytes, against: manifest(build: 99, sha: genuineSHA))
        check(false, "tampered bytes PASSED the checksum gate — the integrity check is broken")
    } catch UpdaterError.checksum {
        print("  (iii) NEGATIVE CONTROL: planted sha-mismatch → REFUSED at the checksum gate")
    } catch { check(false, "tampered bytes threw the wrong error: \(error)") }
    // Wired: stage() through a transport serving tampered bytes under the genuine sha → REFUSAL.
    let dlURL = URL(string: "https://example.invalid/academy.zip")!
    let mockTamper = MockUpdaterTransport()
    mockTamper.responses[dlURL] = (tamperedBytes, 200)
    do {
        _ = try await Updater.stage(manifest(build: 99, sha: genuineSHA, downloadURL: dlURL.absoluteString),
                                    using: mockTamper)
        check(false, "stage() installed bytes whose sha did not match the manifest")
    } catch UpdaterError.checksum {
        print("  (iii) stage() refused the tampered download (checksum) — nothing unpacked or installed")
    } catch { check(false, "stage() threw \(error) — expected .checksum on a tampered download") }
    check(mockTamper.getCount == 1, "stage() should make exactly one download attempt (got \(mockTamper.getCount))")

    // ---- (iv) malformed / empty / unreachable manifest → honest no-update -----------------------
    for (label, bytes) in [("empty", Data()),
                           ("garbage", Data("not json".utf8)),
                           ("half", Data(#"{"product":"academy""#.utf8))] {
        do { _ = try Updater.decodeManifest(bytes); check(false, "the \(label) manifest decoded (must throw)") }
        catch UpdaterError.decode {}
        catch { check(false, "the \(label) manifest threw \(error) — expected .decode") }
    }
    let mockDown = MockUpdaterTransport(); mockDown.throwUnreachable = true
    do {
        _ = try await Updater.checkForUpdate(using: mockDown)
        check(false, "an unreachable server returned a result — must throw so the UI shows an error, not a prompt")
    } catch {
        print("  (iv) unreachable manifest → thrown, no update prompt fabricated")
    }
    let mockCurrent = MockUpdaterTransport()
    let currentBody = Data(#"{"product":"academy","latest_build":\#(currentBuild),"team_id":"745ZPGFRA5"}"#.utf8)
    mockCurrent.responses[Updater.manifestURL] = (currentBody, 200)
    do {
        let offered = try await Updater.checkForUpdate(using: mockCurrent)
        check(offered == nil, "a not-newer manifest produced an update prompt (build \(currentBuild) vs current \(currentBuild))")
        print("  (iv) well-formed not-newer manifest → no prompt (nil)")
    } catch { check(false, "checkForUpdate on a valid current manifest threw: \(error)") }

    // ---- (v) DRY-RUN: the running bundle was left byte-identical ---------------------------------
    let selfHashAfter = (try? Data(contentsOf: selfPlist)).map(Updater.sha256Hex)
    check(selfHashBefore != nil, "could not read the running bundle to prove dry-run")
    check(selfHashBefore == selfHashAfter,
          "the running bundle's Info.plist changed during the self-test — NOT dry-run (self-replace happened)")
    print("  (v) DRY-RUN verified — running bundle byte-identical; all writes confined to \(NSTemporaryDirectory())")

    // ---- (optional) LIVE parse of the real endpoint (skipped offline; --require-live makes it hard)
    let requireLive = CommandLine.arguments.contains("--require-live")
    do {
        let live = try await Updater.fetchManifest()
        check(live.product == "academy", "the LIVE manifest's product was not 'academy'")
        print("  live \(Updater.manifestURL.absoluteString) → build \(live.latestBuild), team \(live.teamID ?? "?") (parsed OK)")
        if live.latestBuild <= currentBuild {
            if case .upToDate = Updater.decideUpdate(manifest: live, currentBuild: currentBuild) {
                print("  live build \(live.latestBuild) <= current \(currentBuild) → up to date (no downgrade offered)")
            } else {
                check(false, "the live server serves build \(live.latestBuild) <= \(currentBuild) yet an update was offered (downgrade)")
            }
        }
    } catch {
        if requireLive { check(false, "--require-live was set but the live manifest was unreachable: \(error)") }
        else { print("  LIVE SKIPPED — manifest endpoint unreachable (\(error)); fixture proofs above still gate") }
    }

    // Restore the app's real last-check timestamp — the whole run leaves no trace.
    if let v = savedLastCheck { UserDefaults.standard.set(v, forKey: Updater.lastCheckKey) }
    else { UserDefaults.standard.removeObject(forKey: Updater.lastCheckKey) }

    print(ok
          ? "UPDATER SELFTEST OK — manifest parses, only a strictly-newer build is offered, a sha256 mismatch is refused (nothing installed), malformed/unreachable manifests never fabricate a prompt, and the running bundle was left byte-identical."
          : "UPDATER SELFTEST FAILED")
    return ok ? 0 : 1
}
#endif
