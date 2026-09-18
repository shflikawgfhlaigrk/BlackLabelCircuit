// Black Label Marketing — updater UI + self-replace (AppKit; runs only on the Dev-ID build).
//
// Separated from Updater.swift so the pure update logic stays headless + unit-tested. This file owns
// the user-facing dialog ("Update available → Install / Later"), the launch/daily/menu triggers, and
// the detached helper that swaps the bundle and relaunches after the app quits.
//
// PLATFORM: macOS-only (AppKit + self-replace). Gated so the shared iOS target still compiles; the
// iOS app updates through the App Store, not this in-app direct-download path.
// Mac App Store builds must contain NO update machinery at all: App Review 2.4.5(vii)
// rejects "frameworks or APIs that may be used to update the app outside the Mac App Store",
// and build 69 was rejected twice for exactly this. DIRECT_DISTRIBUTION is defined only for the
// Dev-ID/adhoc lane (project.yml) and is stripped by scripts/mas-package.sh, so the store slice
// compiles none of this.
#if os(macOS) && DIRECT_DISTRIBUTION
import AppKit

@MainActor
enum UpdaterUI {

    // MARK: Triggers

    /// "Check for Updates…" menu action. Always reports something (update prompt OR "up to date" OR error).
    static func checkInteractively() {
        Task {
            do {
                if let m = try await Updater.checkForUpdate() {
                    presentPrompt(m)
                } else {
                    info(title: "You're up to date",
                         body: "\(AppBrand.displayName) \(Updater.currentVersionString()) · build \(Updater.currentBuild()) is the latest version.")
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
        a.messageText = "Update available — \(m.latestVersion ?? "version unknown") · build \(Updater.currentBuild()) → \(m.latestBuild)"
        let fallback = m.downloadMessage?.isEmpty == false
            ? m.downloadMessage!
            : "Sign in to your Black Label account or use your access code to download this update."
        let notes = m.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        a.informativeText = notes.isEmpty
            ? (m.hasDirectDownload ? "A new version of \(AppBrand.displayName) is ready to install." : fallback)
            : (m.hasDirectDownload ? notes : "\(notes)\n\n\(fallback)")
        a.addButton(withTitle: m.hasDirectDownload ? "Install" : "Open Account to Download")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            if m.hasDirectDownload {
                runInstall(m)
            } else if let url = URL(string: "https://blacklabelbots.com/account.html") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Install flow

    /// Receives the progress panel's Cancel click. NSControl.target is weak, so UpdaterUI retains
    /// this in `cancelTarget` for the duration of the install. Task.cancel() is thread-safe.
    private final class UpdateCancelTarget: NSObject {
        var task: Task<Void, Never>?
        @objc func cancel(_ sender: Any?) { task?.cancel() }
    }
    private static var cancelTarget: UpdateCancelTarget?

    private static func runInstall(_ m: UpdateManifest) {
        // Progress panel while we download + verify — NOT an NSAlert: outside runModal() an
        // alert grows a default OK button that cannot respond. This panel's Cancel is live (it
        // cancels the staging Task); the bundle swap only starts after staging succeeds, so
        // cancel can never half-install anything.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 118),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Updating…"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 118))
        let body = NSTextField(wrappingLabelWithString: "Downloading and verifying the new version. The app will relaunch.")
        body.font = .systemFont(ofSize: 12)
        body.frame = NSRect(x: 20, y: 70, width: 380, height: 36)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 48, width: 380, height: 14))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let target = UpdateCancelTarget()
        let cancelButton = NSButton(title: "Cancel", target: target, action: #selector(UpdateCancelTarget.cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"   // Esc cancels too
        cancelButton.sizeToFit()
        cancelButton.setFrameOrigin(NSPoint(x: 420 - 20 - cancelButton.frame.width, y: 12))
        content.addSubview(body); content.addSubview(bar); content.addSubview(cancelButton)
        panel.contentView = content
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        let task = Task {
            do {
                let stagedApp = try await Updater.stage(m)
                try Task.checkCancellation()   // cancel raced the last staging step — do not swap
                panel.orderOut(nil); cancelTarget = nil
                try performSwapAndRelaunch(stagedApp: stagedApp)
                // performSwapAndRelaunch terminates the app; control should not return.
            } catch {
                panel.orderOut(nil); cancelTarget = nil
                // A user-cancelled download is not an error state — close silently. (stage()
                // wraps transport errors, so check the Task, not the error type.)
                if !Task.isCancelled {
                    info(title: "Update not installed", body: "Nothing on your Mac was changed.\n\n\(error.localizedDescription)")
                }
            }
        }
        target.task = task
        cancelTarget = target
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
            .appendingPathComponent("blm-update-helper-\(UUID().uuidString).sh")
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
