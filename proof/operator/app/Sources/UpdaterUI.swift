// Black Label Sovereign — updater UI + self-replace (AppKit; runs only on the Dev-ID build).
//
// Separated from Updater.swift so the pure update logic stays headless + unit-tested. This file owns
// the user-facing dialog ("Update available → Install / Later"), the launch/daily/menu triggers, and
// the detached helper that swaps the bundle and relaunches after the app quits.
//
// DAEMON NOTE: Sovereign's value path can include a supervised daemon, but this updater only ever
// touches the .app bundle in /Applications. It does not stop, restart, or reach into the daemon; the
// relaunch helper simply `open`s the swapped app, and any launchd-supervised daemon continues
// untouched (the app re-attaches to it on relaunch the same way a normal cold start would).
#if os(macOS)
import AppKit

@MainActor
enum UpdaterUI {

    // MARK: Triggers

    /// "Check for Updates…" menu action. Always reports something (update prompt OR "up to date" OR error).
    static func checkInteractively() {
        // SV-16 §5.1 — a white-label build must never reach Black Label's manifest. The update it
        // would find is the BLACK-LABEL-branded build, and installing it would silently replace the
        // client's app with ours. Say so plainly instead of failing quietly.
        if let brand = WhiteLabel.installed {
            info(title: "Updates are handled by \(brand.client)",
                 body: WhiteLabel.updatesDisabledMessage(brand: brand))
            return
        }
        Task {
            do {
                if let m = try await Updater.checkForUpdate() {
                    presentPrompt(m)
                } else {
                    info(title: "You're up to date",
                         body: "Black Label Sovereign \(Updater.currentVersionString()) is the latest version.")
                }
            } catch {
                info(title: "Couldn't check for updates",
                     body: error.localizedDescription)
            }
        }
    }

    /// Silent background check (on launch + daily). Only surfaces UI if an update is actually available.
    static func checkInBackgroundIfDue() {
        // The dangerous one: unattended, on every launch and daily. In a white-label build this is
        // the path that would have swapped the client's branded app for the Black Label build
        // without anyone asking. It does not run there. (SV-16; WhiteLabel.updatesAllowed.)
        guard WhiteLabel.updatesAllowed(brand: WhiteLabel.installed) else { return }
        guard Updater.dueForBackgroundCheck() else { return }
        Task {
            if let m = try? await Updater.checkForUpdate() { presentPrompt(m) }
        }
    }

    // MARK: Dialog

    static func presentPrompt(_ m: UpdateManifest) {
        let required = m.isRequired(forCurrentBuild: Updater.currentBuild())
        let a = NSAlert()
        a.alertStyle = required ? .critical : .informational
        a.messageText = (required ? "Update required — " : "Update available — ")
            + (m.latestVersion ?? "build \(m.latestBuild)")
        let notes = (m.releaseNotes?.isEmpty == false ? m.releaseNotes! : "A new version of Black Label Sovereign is ready to install.")
        a.informativeText = required
            ? "This version is below the minimum supported build, so the update isn't optional. " + notes
            : notes
        a.addButton(withTitle: "Install")
        if !required { a.addButton(withTitle: "Later") }   // a required update offers no "Later"
        if a.runModal() == .alertFirstButtonReturn { runInstall(m) }
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
    /// Requires the non-sandboxed Dev-ID build (sandbox blocks the helper + the write to the install path).
    static func performSwapAndRelaunch(stagedApp: URL,
                                       installedApp: URL = Bundle.main.bundleURL) throws {
        let installed = installedApp.path
        let staged = stagedApp.path
        let backup = installed + ".old"
        let pid = ProcessInfo.processInfo.processIdentifier

        // DEFENSE-IN-DEPTH (self-replace injection): the staged path is already a fixed, code-controlled
        // name (Updater.stagedBundleURL), but never trust a single layer. Reject any path carrying a
        // character that has no business in a real .app location and would matter to a shell, then
        // SINGLE-QUOTE every path so sh performs no expansion on it at all.
        for p in [installed, staged, backup] where pathHasDangerousMetacharacters(p) {
            throw UpdaterError.install("refusing to install: the update path contains unsafe characters.")
        }

        // The helper is intentionally tiny + dependency-free. Every path is single-quoted (spaces are
        // fine inside single quotes, and $()/backticks/$VAR/globs are ALL inert there — unlike double
        // quotes, where they still expand). On any failure it restores the backup so the user is never
        // left with no app.
        let qInstalled = shellSingleQuote(installed)
        let qStaged = shellSingleQuote(staged)
        let qBackup = shellSingleQuote(backup)
        let script = """
        #!/bin/sh
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(qBackup)
        mv \(qInstalled) \(qBackup) || exit 1
        if ! mv \(qStaged) \(qInstalled); then
          mv \(qBackup) \(qInstalled)
          exit 1
        fi
        rm -rf \(qBackup)
        xattr -dr com.apple.quarantine \(qInstalled) 2>/dev/null
        open \(qInstalled)
        """

        let helper = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("blsov-update-helper-\(UUID().uuidString).sh")
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

    /// Single-quote a path for safe interpolation into a /bin/sh script: wrap in single quotes and
    /// escape any embedded single quote as the standard `'\''` sequence. Inside single quotes sh does
    /// NO expansion — `$()`, backticks, `$VAR`, globs and word-splitting are all inert — so an
    /// attacker-influenced path can never execute. PURE → unit-testable.
    nonisolated static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// True for a path carrying a character that has no place in a real .app install location and would
    /// matter to a shell even inside double quotes (`$`, backtick) or could split the script (newline).
    /// A tamper signal — rejected up front, on top of `shellSingleQuote`. PURE → unit-testable.
    nonisolated static func pathHasDangerousMetacharacters(_ s: String) -> Bool {
        s.contains("\n") || s.contains("\r") || s.contains("$") || s.contains("`")
    }

    static func info(title: String, body: String) {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = title
        a.informativeText = body
        a.addButton(withTitle: "OK")
        a.runModal()
    }
}
#endif
