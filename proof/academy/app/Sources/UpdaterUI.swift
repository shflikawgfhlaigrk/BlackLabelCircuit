// Black Label Academy — updater UI + self-replace (AppKit; runs only on the Dev-ID build).
//
// Separated from Updater.swift so the pure update logic stays headless. This file owns the
// user-facing dialog ("Update available → Install / Later"), the launch/daily/menu triggers, and
// the detached helper that swaps the bundle and relaunches after the app quits.
//
// PLATFORM: macOS-only (AppKit + self-replace). Gated so the shared iOS target still compiles; the
// iOS app updates through the App Store, not this in-app direct-download path.
#if os(macOS) && !MAS_BUILD
import AppKit

@MainActor
enum UpdaterUI {

    static let displayName = "Black Label Academy"

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
            : "Visit blacklabelbots.com to download this update."
        a.informativeText = (m.releaseNotes?.isEmpty == false ? m.releaseNotes! : (m.hasDirectDownload ? "A new version of \(displayName) is ready to install." : fallback))
        a.addButton(withTitle: m.hasDirectDownload ? "Install" : "Open Website")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            if m.hasDirectDownload {
                runInstall(m)
            } else if let url = URL(string: "https://blacklabelbots.com/academy") {
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
    /// Requires the non-sandboxed Dev-ID build (sandbox blocks the helper + the write to the install path).
    static func performSwapAndRelaunch(stagedApp: URL,
                                       installedApp: URL = Bundle.main.bundleURL) throws {
        let installed = installedApp.path
        let staged = stagedApp.path
        let backup = installed + ".old-" + UUID().uuidString
        let pid = ProcessInfo.processInfo.processIdentifier

        // The helper source is fixed. Paths travel only as argument-vector values,
        // so shell syntax in an archive name remains data. Restore on swap failure.
        let script = """
        #!/bin/sh
        set -u
        pid="$1"
        installed="$2"
        staged="$3"
        backup="$4"
        case "$pid" in ''|*[!0-9]*) exit 1;; esac
        trap 'rm -f -- "$0"' EXIT
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        [ ! -e "$backup" ] && [ ! -L "$backup" ] || exit 1
        mv "$installed" "$backup" || exit 1
        if ! mv "$staged" "$installed"; then
          mv "$backup" "$installed"
          exit 1
        fi
        rm -rf "$backup"
        xattr -dr com.apple.quarantine "$installed" 2>/dev/null
        open "$installed"
        """

        let helper = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bla-update-helper-\(UUID().uuidString).sh")
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        } catch {
            throw UpdaterError.install("couldn't write installer helper: \(error.localizedDescription)")
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [helper.path, String(pid), installed, staged, backup]
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
#endif
