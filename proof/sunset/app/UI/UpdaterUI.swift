#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// UpdaterUI: updater dialogs + self-replace (AppKit) — the user-facing half of Shared/Updater.swift.
//
// Separated from Updater.swift so the pure update logic stays headless. This file owns the
// user-facing dialog ("Update available → Install / Later"), the launch/daily/menu triggers, and
// the detached helper that swaps the bundle and relaunches after the app quits.
//
// Requires the non-sandboxed Developer-ID build (the sandbox blocks the helper + the write to the
// install path). Ported from the fleet's canonical Academy updater.

import Foundation
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif

@MainActor
enum UpdaterUI {

    static let displayName = "Sunset"

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

    /// Silent background check (on launch, throttled to daily). Only surfaces UI if an update is
    /// actually available. Updates are public — always eligible to check, no entitlement gate.
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
            : "Visit sunsetmixing.com to download this update."
        a.informativeText = (m.releaseNotes?.isEmpty == false ? m.releaseNotes! : (m.hasDirectDownload ? "A new version of \(displayName) is ready to install." : fallback))
        a.addButton(withTitle: m.hasDirectDownload ? "Install" : "Open Website")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn {
            if m.hasDirectDownload {
                runInstall(m)
            } else if let url = URL(string: "https://sunsetmixing.com") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: Install flow

    /// Strong refs while the progress panel is up (the enum has no instance storage).
    private static var installPanel: NSPanel?
    private static var installTask: Task<Void, Never>?
    private static var installCancelTarget: InstallCancelTarget?

    /// AppKit target for the panel's Cancel button.
    @MainActor private final class InstallCancelTarget: NSObject {
        let onCancel: () -> Void
        init(onCancel: @escaping () -> Void) { self.onCancel = onCancel }
        @objc func cancel(_ sender: Any?) { onCancel() }
    }

    private static func runInstall(_ m: UpdateManifest) {
        // A real modeless panel, not an NSAlert: an alert shown without runModal auto-adds
        // an OK button wired to stopModal — with no modal session that button does nothing,
        // leaving a dead control and no way out of a stalled download.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 122),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Updating \(displayName)"

        let label = NSTextField(wrappingLabelWithString:
            "Downloading and verifying the new version. The app will relaunch.")
        label.font = .systemFont(ofSize: 12)
        label.frame = NSRect(x: 20, y: 74, width: 380, height: 34)

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 52, width: 380, height: 16))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)

        let target = InstallCancelTarget {
            installTask?.cancel()
            closeInstallPanel()
        }
        let cancelButton = NSButton(title: "Cancel", target: target,
                                    action: #selector(InstallCancelTarget.cancel(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 316, y: 12, width: 84, height: 30)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 122))
        content.addSubview(label)
        content.addSubview(bar)
        content.addSubview(cancelButton)
        panel.contentView = content

        installPanel = panel
        installCancelTarget = target
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        installTask = Task {
            defer { closeInstallPanel() }
            do {
                let stagedApp = try await Updater.stage(m)
                // Cancelled mid-stage: never swap the installed bundle.
                guard !Task.isCancelled else { return }
                closeInstallPanel()
                try performSwapAndRelaunch(stagedApp: stagedApp)
                // performSwapAndRelaunch terminates the app; control should not return.
            } catch is CancellationError {
                // User hit Cancel — nothing was changed; no error dialog.
            } catch let e as URLError where e.code == .cancelled {
                // Cancellation surfacing through the download transport — same as above.
            } catch {
                guard !Task.isCancelled else { return }
                info(title: "Update not installed", body: "Nothing on your Mac was changed.\n\n\(error.localizedDescription)")
            }
        }
    }

    private static func closeInstallPanel() {
        installPanel?.orderOut(nil)
        installPanel = nil
        installCancelTarget = nil
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

        // The helper is intentionally tiny + dependency-free. Double-quote every path (bundle names
        // can contain spaces). On any failure it restores the backup so the user is never left with no app.
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
            .appendingPathComponent("sunset-update-helper-\(UUID().uuidString).sh")
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
#endif // circuit-convert
