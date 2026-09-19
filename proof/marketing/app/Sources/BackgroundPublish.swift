// Black Label Marketing — background publishing (closes the Buffer gap: the 60-second in-app
// loop only runs while Marketing is open; this makes due queue posts publish with the app CLOSED).
//
// Own-infra stance: NO cloud server ever holds the buyer's tokens. The "background service" is the
// buyer's own Mac re-running the buyer's own installed app binary headlessly (--publish-due) every
// 5 minutes via a per-user LaunchAgent. Tokens stay in the same data-protection Keychain the app
// already uses — Social.swift writes them kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly keyed to
// the stable bundle-id code-sign identifier, so a headless run of the SAME binary in the same
// logged-in session reads them silently (no prompt, no relaxation needed).
//
// Pieces:
//   • PublishSingleFlight — cross-PROCESS flock so the in-app loop and the LaunchAgent never
//     publish concurrently. ScheduledSocialPublisher.runDue takes it itself.
//   • PublishLedger — cross-process record of post IDs actually published (receipt detail + time).
//     The workspace blob is whole-store last-writer-wins between two processes, so an open app
//     with a stale in-memory queue could otherwise RE-publish a post the agent already published;
//     runDue consults the ledger first and reconciles the row instead of re-posting.
//   • BackgroundPublisher.runOnce — the headless entry: loads the REAL workspace (DemoMode is
//     always off in a fresh process), runs the exact same runDue the app uses, writes an honest
//     last-run state file the UI reads back, prints a machine-readable result line, exits.
//   • LaunchAgentManager (macOS) — install/uninstall/status of
//     ~/Library/LaunchAgents/com.blacklabel.marketing.publisher.plist pointing at the CURRENT
//     bundle executable. StartInterval=300, RunAtLoad=false (predictable: nothing fires at
//     login/load; the first check is the first interval tick).
//
// Honesty (§5.1): every count in the state file is computed from the run that actually happened;
// the sandboxed App-Store build cannot register a LaunchAgent and SAYS so instead of pretending.
import Foundation
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Shared on-disk locations (same app-support folder both processes resolve)

enum BackgroundPublishPaths {
    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var lockURL: URL { supportDirectory.appendingPathComponent("publish.lock") }
    static var ledgerURL: URL { supportDirectory.appendingPathComponent("publish-ledger.json") }
    static var stateURL: URL { supportDirectory.appendingPathComponent("background-publish-state.json") }
    static var agentLogURL: URL { supportDirectory.appendingPathComponent("background-publish.log") }
}

// MARK: - Cross-process single-flight lock

/// Advisory file lock (flock) shared by every Marketing process on this Mac. The open app's
/// 60-second loop and the LaunchAgent both run ScheduledSocialPublisher.runDue, which acquires
/// this for the whole run — so two processes can never upload the same due post concurrently.
enum PublishSingleFlight {
    /// Non-blocking acquire. nil ⇒ another Marketing process is publishing right now (callers
    /// simply skip this tick; the other process is doing the identical work).
    static func acquire() -> Int32? {
        let fd = open(BackgroundPublishPaths.lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return fd
    }

    static func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

// MARK: - Cross-process publish ledger

/// One really-published post: when it went out and the provider receipt detail shown to the buyer.
struct PublishLedgerEntry: Codable, Hashable {
    var at: Date
    var detail: String
}

/// Post-ID → receipt record for every auto-queue post that actually published, written under the
/// single-flight lock by whichever process published it. Because the workspace store is a single
/// whole-blob write (last writer wins), an open app whose in-memory queue predates an agent run
/// could still see "scheduled" for a post the agent already published — runDue checks here FIRST
/// and marks the row published with the real receipt instead of posting a duplicate.
enum PublishLedger {
    private static let maxEntries = 500   // bounded: newest wins, old receipts age out

    static func load() -> [String: PublishLedgerEntry] {
        guard let data = try? Data(contentsOf: BackgroundPublishPaths.ledgerURL),
              let entries = try? JSONDecoder().decode([String: PublishLedgerEntry].self, from: data)
        else { return [:] }
        return entries
    }

    /// Record a real publish and persist. Only terminal SUCCESS is recorded — failures stay in the
    /// workspace row so Retry keeps working.
    static func record(_ id: UUID, detail: String, at date: Date, in ledger: inout [String: PublishLedgerEntry]) {
        ledger[id.uuidString] = PublishLedgerEntry(at: date, detail: detail)
        if ledger.count > maxEntries {
            let oldestKeys = ledger.sorted { $0.value.at < $1.value.at }
                .prefix(ledger.count - maxEntries).map(\.key)
            for key in oldestKeys { ledger.removeValue(forKey: key) }
        }
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: BackgroundPublishPaths.ledgerURL, options: .atomic)
    }
}

// MARK: - Honest last-run state (written by the headless agent, read by the UI)

struct BackgroundPublishRunState: Codable, Hashable {
    var lastRunAt: Date
    var dueCount: Int
    var publishedCount: Int
    var failedCount: Int
    var message: String
}

enum BackgroundPublishStateStore {
    static func load() -> BackgroundPublishRunState? {
        guard let data = try? Data(contentsOf: BackgroundPublishPaths.stateURL) else { return nil }
        return try? JSONDecoder().decode(BackgroundPublishRunState.self, from: data)
    }

    static func write(_ state: BackgroundPublishRunState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: BackgroundPublishPaths.stateURL, options: .atomic)
    }
}

// MARK: - Headless entry (--publish-due)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum BackgroundPublisher {
    /// One headless publish pass: load the buyer's REAL workspace, run the exact runDue the app
    /// uses (same lock, same ledger, same provider clients), persist an honest result, exit code 0.
    /// A fresh process never has DemoMode on, so this can never touch or publish demo data.
    @MainActor
    static func runOnce() async -> Int32 {
        guard !DemoMode.active else {
            print("publish_due|state=Skipped|reason=demo_mode")
            return 0
        }
        let startedAt = Date()
        let model = AppModel()
        let dueIDs = Set(model.posts.filter {
            $0.autoPublish == true
                && ($0.publishState == nil || $0.publishState == "scheduled" || $0.publishState == "publishing")
                && $0.scheduledAt <= startedAt
        }.map(\.id))

        let newlyPublished = await ScheduledSocialPublisher.runDue(model: model)

        let processed = model.posts.filter { dueIDs.contains($0.id) }
        let publishedTotal = processed.filter { $0.publishState == "published" }.count
        let failed = processed.filter { $0.publishState == "failed" }.count
        let reconciled = max(0, publishedTotal - newlyPublished)

        let message: String
        if ScheduledSocialPublisher.lastRunSkippedByLock {
            message = "Skipped — another Marketing process was already publishing."
        } else if dueIDs.isEmpty {
            message = "No queued posts were due."
        } else {
            var parts = ["Published \(newlyPublished) of \(dueIDs.count) due"]
            if failed > 0 { parts.append("\(failed) failed") }
            if reconciled > 0 { parts.append("\(reconciled) already published by an earlier run") }
            message = parts.joined(separator: "; ") + "."
        }
        BackgroundPublishStateStore.write(BackgroundPublishRunState(
            lastRunAt: startedAt, dueCount: dueIDs.count,
            publishedCount: newlyPublished, failedCount: failed, message: message))
        print("publish_due|due=\(dueIDs.count)|published=\(newlyPublished)|failed=\(failed)|detail=\(message)")
        return 0
    }

    /// Synchronous bridge for main.swift's top-level CLI section (which cannot await): schedules
    /// runOnce on the main actor, spins the main run loop until it finishes, and exits the process.
    /// A watchdog guarantees a hung provider upload can never leave a zombie agent process behind
    /// (URLSession timeouts normally end runs long before this fires).
    static func runOnceBlockingAndExit() -> Never {
        DispatchQueue.global().asyncAfter(deadline: .now() + 30 * 60) {
            BackgroundPublishStateStore.write(BackgroundPublishRunState(
                lastRunAt: Date(), dueCount: 0, publishedCount: 0, failedCount: 0,
                message: "Run abandoned after 30 minutes (watchdog) — a provider upload hung."))
            print("publish_due|state=Error|reason=watchdog_timeout")
            exit(3)
        }
        Task { @MainActor in
            exit(await runOnce())
        }
        while true {
            RunLoop.main.run(mode: .default, before: .distantFuture)
        }
    }
}
#endif // circuit-convert

// MARK: - LaunchAgent install / uninstall / status (macOS only)

#if os(macOS)
enum LaunchAgentManager {
    static let label = "com.blacklabel.marketing.publisher"
    static let intervalSeconds = 300

    struct Status {
        var sandboxBlocked: Bool
        var installed: Bool          // plist file exists in ~/Library/LaunchAgents
        var loaded: Bool             // launchctl print finds the job in the gui domain
        var plistExecutablePath: String?
        var executableMatchesThisBuild: Bool
        var lastRun: BackgroundPublishRunState?
    }

    /// The App-Store build runs in the App Sandbox: its "home" is the container, launchd's real
    /// ~/Library/LaunchAgents is unreachable, and spawning launchctl is denied. Detected honestly
    /// so the UI explains instead of writing a plist into the container that launchd never reads.
    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static var agentsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }
    static var plistURL: URL { agentsDirectory.appendingPathComponent("\(label).plist") }

    private static var currentExecutablePath: String? {
        Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }

    static func status() -> Status {
        var status = Status(sandboxBlocked: isSandboxed, installed: false, loaded: false,
                            plistExecutablePath: nil, executableMatchesThisBuild: false,
                            lastRun: BackgroundPublishStateStore.load())
        guard !status.sandboxBlocked else { return status }
        status.installed = FileManager.default.fileExists(atPath: plistURL.path)
        if status.installed,
           let data = try? Data(contentsOf: plistURL),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let args = plist["ProgramArguments"] as? [String], let exe = args.first {
            status.plistExecutablePath = exe
            status.executableMatchesThisBuild = (exe == currentExecutablePath)
        }
        status.loaded = launchctl(["print", "gui/\(getuid())/\(label)"]).status == 0
        return status
    }

    /// Write the plist pointing at THIS build's executable and bootstrap it into the user's gui
    /// domain. RunAtLoad stays false: loading never fires an immediate pass — the first check is
    /// the first 5-minute tick (or an explicit "Check now").
    @discardableResult
    static func install() -> (ok: Bool, message: String) {
        guard !isSandboxed else {
            return (false, "This sandboxed build can't register a LaunchAgent. Use the direct-download build.")
        }
        guard let exe = currentExecutablePath else {
            return (false, "Couldn't resolve this app's executable path.")
        }
        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--publish-due"],
            "StartInterval": intervalSeconds,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",   // login session only — Keychain + network live here
            "StandardOutPath": BackgroundPublishPaths.agentLogURL.path,
            "StandardErrorPath": BackgroundPublishPaths.agentLogURL.path,
        ]
        do {
            try FileManager.default.createDirectory(at: agentsDirectory, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return (false, "Couldn't write the LaunchAgent plist: \(error.localizedDescription)")
        }
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])   // replace any older registration
        let result = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, "launchctl bootstrap failed (\(result.status))\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return (true, "On — checks every 5 minutes while your Mac is on and awake, even with Marketing closed.")
    }

    @discardableResult
    static func uninstall() -> (ok: Bool, message: String) {
        guard !isSandboxed else {
            return (false, "This sandboxed build can't manage LaunchAgents.")
        }
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])   // fails harmlessly when not loaded
        if FileManager.default.fileExists(atPath: plistURL.path) {
            do { try FileManager.default.removeItem(at: plistURL) }
            catch { return (false, "Unloaded, but couldn't delete the plist: \(error.localizedDescription)") }
        }
        return (true, "Off — posts publish only while Marketing is open.")
    }

    /// Fire one pass immediately (real end-to-end proof of the installed agent).
    @discardableResult
    static func runNow() -> (ok: Bool, message: String) {
        guard !isSandboxed else { return (false, "Unavailable in the sandboxed build.") }
        let result = launchctl(["kickstart", "gui/\(getuid())/\(label)"])
        guard result.status == 0 else {
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return (false, "Couldn't start a check\(detail.isEmpty ? "" : ": \(detail)")")
        }
        return (true, "Check started — the result appears under “Last background run” when it finishes.")
    }

    private static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
#endif
