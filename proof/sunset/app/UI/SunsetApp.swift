// SunsetApp: @main entry — owns the single AppState and hosts the main window in the Black Label shell.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@main
struct SunsetApp: App {
    // One shared model for the whole app; engines read a snapshot, UI observes it.
    @StateObject private var state = AppState()

    init() {
        // Headless updater self-test (`Sunset --selftest-updater`): prove the five updater safety
        // properties and exit — never shows a window, never touches the installed bundle.
        if CommandLine.arguments.contains("--selftest-updater") { runUpdaterSelfTest() }

        // A .hiddenTitleBar window can open behind other apps when launched from a tool/script;
        // force regular activation policy and bring us to front so the window is usable immediately.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Silent update check on launch, throttled to daily inside dueForBackgroundCheck().
        // Only surfaces UI if a strictly-newer build is actually available.
        UpdaterUI.checkInBackgroundIfDue()
    }

    var body: some Scene {
        WindowGroup {
            StudioDashboardView()
            .environmentObject(state)
            .frame(minWidth: 1180, minHeight: 760)
            .background(Palette.bg)
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // App menu, right under "About Sunset" — the manual update trigger.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdaterUI.checkInteractively() }
            }
        }
    }
}
#endif // circuit-convert
