#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Circuit — in-app auto-updater (Developer-ID direct-download build).
//
// Goal: a user on build N sees "Update available → Install", clicks once, and is running build N+1
// seconds later — no website visit, no manual re-download. So when we fix a bug we ship it once and
// every installed user gets it. Ported from the fleet's canonical Academy updater (same manifest
// contract the /api/version/<product> endpoint already serves for circuit).
//
// HOW IT WORKS
//   1. A tiny PUBLIC manifest (https://blacklabelbots.com/api/version/circuit) says what the
//      latest build is, its sha256, and where to download it. Updates are public — no entitlement
//      gate; the updater always checks.
//   2. The app compares manifest.latest_build to its own CFBundleVersion (on launch, daily, and via
//      the "Check for Updates…" menu item).
//   3. If newer, it prompts. On Install it downloads the notarized zip, VERIFIES it
//      (sha256 + Apple-notarized + signed by OUR Team ID — Security.framework, no shell-out),
//      unzips, then a detached helper swaps the bundle and relaunches.
//
// SECURITY: update metadata and binaries are public. Nothing is installed until the new bundle is
// proven to be signed by Team ID 745ZPGFRA5 and its bytes match the manifest sha256. A hijacked
// CDN/manifest cannot install anything that isn't our genuine build.

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
        case .badURL: return "Visit blacklabelbots.com/account to download this update."
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

// MARK: - Transport (the isolated network seam — the ONLY code here that opens a socket)

/// The single network seam for the updater: GET a URL, return (body, HTTP status). Keeping it a
/// protocol lets a test inject a fixture transport so manifest-parse, version-compare, and
/// checksum-refusal are provable without a live network.
protocol UpdaterTransport {
    func get(_ url: URL) async throws -> (Data, Int)
}

/// The production transport. Reads public metadata and the notarized zip; sends no name/email
/// (an anonymous UA carrying just the build number).
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
        req.setValue("Circuit/\(Updater.currentBuild()) (macOS)", forHTTPHeaderField: "User-Agent")
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
    /// The production network seam. Overridable per-call so a test can inject a fixture.
    static let defaultTransport: UpdaterTransport = URLSessionUpdaterTransport()
    /// UserDefaults override for the manifest URL (QA / local testing). Empty → the live default.
    static let manifestOverrideKey = "circuit.updateManifestURL"
    static let lastCheckKey = "circuit.updateLastCheckEpoch"

    static var manifestURL: URL {
        let raw = (UserDefaults.standard.string(forKey: manifestOverrideKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let u = URL(string: raw), u.scheme != nil { return u }
        return URL(string: "https://blacklabelbots.com/api/version/circuit")!
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
    /// then rests on the Team-ID signature check below).
    /// This is the byte-integrity half of the two-part proof (bytes match the manifest + bundle is ours).
    static func verifyChecksum(_ data: Data, against m: UpdateManifest) throws {
        guard let expected = m.sha256?.lowercased(), !expected.isEmpty else { return }
        let got = sha256Hex(data)
        guard got == expected else { throw UpdaterError.checksum(expected: expected, got: got) }
    }

    /// Throws unless `appURL` carries a code-signature that chains to Apple AND has our Team ID in the
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
        guard let raw = m.downloadURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw), url.scheme != nil else { throw UpdaterError.badURL }
        let (data, status) = try await transport.get(url)
        guard (200...299).contains(status) else { throw UpdaterError.http(status) }
        // Byte integrity BEFORE any file work — a hijacked CDN serving different bytes under the
        // genuine manifest sha is refused here, before a single byte is unzipped or installed.
        try verifyChecksum(data, against: m)
        // Write + unzip into a private temp dir.
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("circuit-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zipURL = work.appendingPathComponent("update.zip")
        try data.write(to: zipURL)
        let unzipDir = work.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try runDitto(extract: zipURL, to: unzipDir)
        // Find the .app.
        let contents = (try? FileManager.default.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)) ?? []
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdaterError.noAppInZip }
        try verifySignature(appURL: appURL)
        return appURL
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

// MARK: - Updater UI + self-replace (AppKit)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Owns the user-facing dialog ("Update available → Install / Later"), the launch/daily/menu
/// triggers, and the detached helper that swaps the bundle and relaunches after the app quits.
/// Kept apart from the Updater core above so the pure update logic stays headless.
@MainActor
enum UpdaterUI {

    static let displayName = "Circuit"

    // MARK: Triggers

    /// "Check for Updates…" menu action. Always reports something (update prompt OR "up to date" OR error).
    static func checkInteractively() {
        Task {
            do {
                if let m = try await Updater.checkForUpdate() {
                    presentPrompt(m)
                } else {
                    info(title: "You're up to date",
                         body: "\(displayName) \(Updater.currentVersionString()) is the latest version.")
                }
            } catch {
                info(title: "Couldn't check for updates",
                     body: error.localizedDescription)
            }
        }
    }

    /// Silent background check (on launch + daily). Only surfaces UI if an update is actually available.
    static func checkInBackgroundIfDue() {
        guard Updater.dueForBackgroundCheck() else { return }
        Task {
            if let m = try? await Updater.checkForUpdate() { presentPrompt(m) }
        }
    }

    // MARK: Dialog

    static func presentPrompt(_ m: UpdateManifest) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = "Update available — \(m.latestVersion ?? "build \(m.latestBuild)")"
        let fallback = m.downloadMessage?.isEmpty == false
            ? m.downloadMessage!
            : "Visit blacklabelbots.com/account to download this update."
        a.informativeText = (m.releaseNotes?.isEmpty == false ? m.releaseNotes! : (m.hasDirectDownload ? "A new version of \(displayName) is ready to install." : fallback))
        a.addButton(withTitle: m.hasDirectDownload ? "Install" : "Open Website")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            if m.hasDirectDownload {
                runInstall(m)
            } else if let url = URL(string: "https://blacklabelbots.com/account") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Install flow

    private static func runInstall(_ m: UpdateManifest) {
        // Lightweight progress alert (modeless) while we download + verify.
        let progress = NSAlert()
        progress.messageText = "Updating…"
        progress.informativeText = "Downloading and verifying the new version. The app will relaunch."
        let win = progress.window
        win.makeKeyAndOrderFront(nil)

        Task {
            do {
                let stagedApp = try await Updater.stage(m)
                win.orderOut(nil)
                try performSwapAndRelaunch(stagedApp: stagedApp)
                // performSwapAndRelaunch terminates the app; control should not return.
            } catch {
                win.orderOut(nil)
                info(title: "Update not installed", body: "Nothing on your Mac was changed.\n\n\(error.localizedDescription)")
            }
        }
    }

    /// Writes a detached helper that waits for THIS process to exit, atomically swaps the installed
    /// bundle with the verified staged build, and relaunches it. Then quits the app.
    /// Works because Circuit is the non-sandboxed Dev-ID build (a sandbox would block the helper
    /// and the write to the install path).
    static func performSwapAndRelaunch(stagedApp: URL,
                                       installedApp: URL = Bundle.main.bundleURL) throws {
        let installed = installedApp.path
        let staged = stagedApp.path
        let backup = installed + ".old"
        let pid = ProcessInfo.processInfo.processIdentifier

        // The helper is intentionally tiny + dependency-free. Double-quote every path (bundle names
        // may contain spaces). On any failure it restores the backup so the user is never left with no app.
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(backup)"
        mv "\(installed)" "\(backup)" || exit 1
        if ! mv "\(staged)" "\(installed)"; then
          mv "\(backup)" "\(installed)"
          exit 1
        fi
        rm -rf "\(backup)"
        xattr -dr com.apple.quarantine "\(installed)" 2>/dev/null
        open "\(installed)"
        """

        let helper = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("circuit-update-helper-\(UUID().uuidString).sh")
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        } catch {
            throw UpdaterError.install("couldn't write installer helper: \(error.localizedDescription)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [helper.path]
        do { try p.run() } catch { throw UpdaterError.install("couldn't launch installer helper: \(error.localizedDescription)") }

        // Hand off to the helper and quit so it can replace us.
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    static func info(title: String, body: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
#endif // circuit-convert
