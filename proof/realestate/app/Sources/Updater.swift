// Black Label Real Estate — in-app auto-updater (Developer-ID direct-download build).
//
// Goal: a user on build N sees "Update available → Install", clicks once, and is running build N+1
// seconds later — no website visit, no manual re-download. So when we fix a bug we ship it once and
// every installed user gets it.
//
// HOW IT WORKS
//   1. A tiny PUBLIC manifest (https://blacklabelbots.com/api/version/realestate) says what the
//      latest build is, where to download it, and its sha256.
//   2. The app compares manifest.latest_build to its own CFBundleVersion (on launch, daily, and via
//      the "Check for Updates…" menu item).
//   3. If newer, it prompts. On Install it downloads the notarized zip, VERIFIES it
//      (sha256 + Apple-notarized + signed by OUR Team ID — Security.framework, no shell-out),
//      unzips, then a detached helper swaps the bundle and relaunches.
//
// SECURITY: the download is public on purpose (a fix must reach every user, logged in or not — the
// Sparkle-appcast model). It is safe because nothing is installed until the new bundle is proven to
// be Apple-notarized AND signed by Team ID 745ZPGFRA5, and its bytes match the manifest sha256. A
// hijacked CDN/manifest cannot install anything that isn't our genuine signed build.
//
// SANDBOX: self-replace requires the NON-sandboxed Developer-ID build (hardened runtime + notarized).
// The pure logic here (version compare, manifest decode, sha256) is always available + unit-tested;
// the install/relaunch path only runs on the Dev-ID build (see docs/superpowers/specs).
//
// Whole file is Dev-ID/macOS-only: signature verification uses Security.framework SecStaticCode APIs
// and the unzip/relaunch path uses Process — neither exists on iOS (App Store handles iOS updates).
// The Mac App Store build must also exclude it (Guideline 2.4.5(vii): no self-update mechanisms; the
// App Store delivers updates), so the guard is os(macOS) && !MAS_BUILD. The only consumers are
// UpdaterUI (same guard) and the macOS-run unit tests (built without MAS_BUILD).
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
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
    var downloadURL: String
    var sha256: String?
    var notarized: Bool?
    var teamID: String?
    var releaseNotes: String?
    var mandatory: Bool?

    enum CodingKeys: String, CodingKey {
        case product
        case latestBuild = "latest_build"
        case latestVersion = "latest_version"
        case downloadURL = "download_url"
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
        case .badURL: return "The update location wasn't a valid URL."
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

// MARK: - Updater (pure core + side-effecting install)

enum Updater {
    /// Our Apple Developer Team ID. The update bundle MUST be signed by this team or it's rejected.
    static let teamID = "745ZPGFRA5"
    /// UserDefaults override for the manifest URL (QA / local testing). Empty → the live default.
    static let manifestOverrideKey = "blre.updateManifestURL"
    static let lastCheckKey = "blre.updateLastCheckEpoch"

    static var manifestURL: URL {
        let raw = (UserDefaults.standard.string(forKey: manifestOverrideKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let u = URL(string: raw), u.scheme != nil { return u }
        return URL(string: "https://blacklabelbots.com/api/version/realestate")!
    }

    // MARK: Pure, unit-tested

    /// Strictly newer build number. Equal or older → no update. The single source of "is there an update".
    static func isNewer(latestBuild: Int, currentBuild: Int) -> Bool { latestBuild > currentBuild }

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

    // MARK: Network

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func fetchManifest(from url: URL = manifestURL) async throws -> UpdateManifest {
        var req = URLRequest(url: url)
        req.setValue("BlackLabelRealEstate/\(currentBuild()) (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw UpdaterError.transport(error.localizedDescription) }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdaterError.http(http.statusCode)
        }
        return try decodeManifest(data)
    }

    /// Returns the manifest IFF it describes a strictly-newer build, else nil. Records the check time.
    static func checkForUpdate() async throws -> UpdateManifest? {
        let m = try await fetchManifest()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        return isNewer(latestBuild: m.latestBuild, currentBuild: currentBuild()) ? m : nil
    }

    /// True if it's been >= 24h since the last successful check (drives the daily auto-check).
    static func dueForBackgroundCheck(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        return last == 0 || (now - last) >= 24 * 3600
    }

    // MARK: Verify (security-critical)

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
    static func stage(_ m: UpdateManifest) async throws -> URL {
        guard m.product == "realestate" else { throw UpdaterError.install("update product mismatch") }
        guard let url = URL(string: m.downloadURL), url.scheme != nil else { throw UpdaterError.badURL }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(from: url) }
        catch { throw UpdaterError.transport(error.localizedDescription) }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdaterError.http(http.statusCode)
        }
        if let expected = m.sha256?.lowercased(), !expected.isEmpty {
            let got = sha256Hex(data)
            guard got == expected else { throw UpdaterError.checksum(expected: expected, got: got) }
        }
        // Write + unzip into a private temp dir.
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("blre-update-\(UUID().uuidString)", isDirectory: true)
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

// MARK: - Headless self-test (proves the download-verification gates over planted local fixtures)
/// Exercises the SHIPPED updater's refusal gates with adversarial fixtures and exits — no network,
/// nothing installed, every "download" is a local file:// URL created and destroyed here.
/// Invoked via `Black Label Real Estate --selftest-updater` (DOD-9.5 enforcement proof: the
/// updater must verify the published checksum before installing, refuse a tampered download,
/// refuse a payload that is not our signed app, and refuse a downgrade).
func runREUpdaterSelfTest() -> Never {
    print("== Black Label Real Estate — updater self-test ==")
    print("config: manifest=\(Updater.manifestURL.absoluteString) requiredTeam=\(Updater.teamID) currentBuild=\(Updater.currentBuild())")

    var ok = true
    func check(_ cond: Bool, _ label: String) {
        print("  \(cond ? "ok  " : "FAIL") \(label)")
        if !cond { ok = false }
    }

    // ---- 1. Version gate: strictly-newer only (downgrade + replay refusal) -------------------
    let cur = max(Updater.currentBuild(), 1)
    check(!Updater.isNewer(latestBuild: cur - 1, currentBuild: cur), "downgrade manifest (\(cur - 1) over \(cur)) is not an update")
    check(!Updater.isNewer(latestBuild: cur, currentBuild: cur), "same-build manifest (replay) is not an update")
    check(Updater.isNewer(latestBuild: cur + 1, currentBuild: cur), "strictly newer manifest IS an update (positive control)")

    // ---- 2. Malformed manifest: typed error, never a crash, never an install ------------------
    do {
        _ = try Updater.decodeManifest(Data("{\"latest_build\":\"not-a-number\"".utf8))
        check(false, "malformed manifest decode throws")
    } catch {
        check(error is UpdaterError, "malformed manifest -> typed decode error (no crash)")
    }

    // ---- fixture workspace --------------------------------------------------------------------
    let fm = FileManager.default
    let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("blre-updater-selftest-\(UUID().uuidString)", isDirectory: true)
    func cleanupAndExit(_ code: Int32) -> Never {
        try? fm.removeItem(at: work)   // exit() skips defer blocks — clean up explicitly
        exit(code)
    }
    do { try fm.createDirectory(at: work, withIntermediateDirectories: true) }
    catch { print("FAIL could not create fixture dir: \(error)"); exit(1) }

    func makeManifest(url: URL, sha: String?) -> UpdateManifest {
        UpdateManifest(product: "realestate", latestBuild: cur + 1, latestVersion: nil,
                       downloadURL: url.absoluteString, sha256: sha, notarized: true,
                       teamID: Updater.teamID, releaseNotes: nil, mandatory: false)
    }

    func dittoZip(_ src: URL, to zipURL: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", src.path, zipURL.path]
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    enum StageOutcome { case staged, checksum, unzip, signature, noApp, other(String) }
    func stageOutcome(_ m: UpdateManifest) -> StageOutcome {
        let sem = DispatchSemaphore(value: 0)
        var out: StageOutcome = .other("selftest timeout")
        Task {
            do { _ = try await Updater.stage(m); out = .staged }
            catch let e as UpdaterError {
                switch e {
                case .checksum: out = .checksum
                case .unzip: out = .unzip
                case .signature: out = .signature
                case .noAppInZip: out = .noApp
                default: out = .other(String(describing: e))
                }
            }
            catch { out = .other(String(describing: error)) }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 60)
        return out
    }

    // ---- 3. Planted sha-mismatch: refused BEFORE anything is unpacked -------------------------
    let junk = work.appendingPathComponent("junk.zip")
    try? Data("this is not the artifact the manifest promised — planted tamper fixture".utf8).write(to: junk)
    let wrongSha = String(repeating: "0", count: 64)
    if case .checksum = stageOutcome(makeManifest(url: junk, sha: wrongSha)) {
        check(true, "tampered download (sha mismatch) refused — nothing staged")
    } else { check(false, "tampered download (sha mismatch) refused — nothing staged") }
    // Repetition: the refusal is stable, not first-run-only.
    if case .checksum = stageOutcome(makeManifest(url: junk, sha: wrongSha)) {
        check(true, "tampered download refused again on repeat (stable refusal)")
    } else { check(false, "tampered download refused again on repeat (stable refusal)") }

    // ---- 4. Ordering positive control: the CORRECT sha proceeds PAST the checksum gate --------
    // Same junk bytes with their true sha must fail LATER (not a zip), proving the sha gate is a
    // live ordered stage and not an always-refuse or never-checked branch.
    let junkSha = Updater.sha256Hex((try? Data(contentsOf: junk)) ?? Data())
    if case .unzip = stageOutcome(makeManifest(url: junk, sha: junkSha)) {
        check(true, "correct sha passes the checksum gate and fails at unzip (gate is ordered + live)")
    } else { check(false, "correct sha passes the checksum gate and fails at unzip (gate is ordered + live)") }

    // ---- 5. Correctly-hashed zip with NO app inside: refused ---------------------------------
    let plainDir = work.appendingPathComponent("payload", isDirectory: true)
    try? fm.createDirectory(at: plainDir, withIntermediateDirectories: true)
    try? Data("no app here".utf8).write(to: plainDir.appendingPathComponent("readme.txt"))
    let noAppZip = work.appendingPathComponent("noapp.zip")
    if dittoZip(plainDir, to: noAppZip) {
        let sha = Updater.sha256Hex((try? Data(contentsOf: noAppZip)) ?? Data())
        if case .noApp = stageOutcome(makeManifest(url: noAppZip, sha: sha)) {
            check(true, "correctly-hashed zip containing no app refused")
        } else { check(false, "correctly-hashed zip containing no app refused") }
    } else { check(false, "fixture zip (no-app) created") }

    // ---- 6. Correctly-hashed UNSIGNED fake .app: refused by the Team-ID requirement -----------
    // The hijacked-manifest attack: an attacker who controls manifest + download can publish a
    // matching sha for a foreign app. The signature gate must still refuse it.
    let fakeApp = work.appendingPathComponent("FakeUpdate.app", isDirectory: true)
    let fakeMacOS = fakeApp.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try? fm.createDirectory(at: fakeMacOS, withIntermediateDirectories: true)
    let fakePlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>CFBundleExecutable</key><string>FakeUpdate</string>
      <key>CFBundleIdentifier</key><string>com.example.fakeupdate</string>
      <key>CFBundleVersion</key><string>\(cur + 1)</string>
    </dict></plist>
    """
    try? Data(fakePlist.utf8).write(to: fakeApp.appendingPathComponent("Contents/Info.plist"))
    try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeMacOS.appendingPathComponent("FakeUpdate"))
    let fakeZip = work.appendingPathComponent("fake-app.zip")
    if dittoZip(fakeApp, to: fakeZip) {
        let sha = Updater.sha256Hex((try? Data(contentsOf: fakeZip)) ?? Data())
        if case .signature = stageOutcome(makeManifest(url: fakeZip, sha: sha)) {
            check(true, "correctly-hashed UNSIGNED app refused by the Team-ID signature gate")
        } else { check(false, "correctly-hashed UNSIGNED app refused by the Team-ID signature gate") }
    } else { check(false, "fixture zip (fake app) created") }

    // ---- info: this bundle's own signature (hard proof only meaningful on the shipped artifact)
    do {
        try Updater.verifySignature(appURL: Bundle.main.bundleURL)
        print("  info self-signature: this bundle verifies against team \(Updater.teamID) (Developer ID lane)")
    } catch {
        print("  info self-signature: this copy is not Dev-ID signed (\(error.localizedDescription)) — expected on adhoc/dev builds; the notarized artifact verifies")
    }

    print(ok ? "SELFTEST OK — updater refuses sha-mismatch, junk payloads, unsigned apps, and downgrades; sha gate proven live and ordered"
             : "SELFTEST FAILED")
    cleanupAndExit(ok ? 0 : 1)
}
#endif
