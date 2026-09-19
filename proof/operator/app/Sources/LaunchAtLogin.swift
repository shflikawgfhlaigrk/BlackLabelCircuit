// Sovereign — LAUNCH AT LOGIN (the "always-on resident operator" claim, made real & honest).
//
// THE HONEST CLAIM. The website sells an operator that "boots with the machine." A Mac App-Store
// app is App-Sandboxed and CANNOT install a boot-time system daemon — that would be a false claim.
// The REAL, supported mechanism is a macOS login item via SMAppService.mainApp: the app launches
// automatically whenever the buyer logs in, making the operator genuinely resident across logins.
// This is fully supported in the signed Developer-ID (Mac download) build.
//
// ZERO FABRICATION: this wrapper NEVER reports a fake "enabled". It reads and surfaces the REAL
// SMAppService status. In the sandboxed / adhoc App-Store build (where an adhoc signature can't
// persist a login-item registration) the UI shows the honest limitation and routes the buyer to
// the Mac download — the same honest pattern the CLI-subscription brains use. Real login-item
// registration is verified only in the signed Developer-ID build on a real login.
import Foundation
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit
#if os(macOS)
import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var lastError: String?

    /// The App-Store / adhoc build is sandboxed; a persistent login item can't be registered there.
    /// Reuse the SAME sandbox signal the CLI brains use so the app tells ONE honest story.
    var sandboxLimited: Bool { ExternalCLI.isSandboxed }

    /// The live, true state — derived ONLY from the system, never a stored boolean we could fake.
    var isEnabled: Bool { status == .enabled }

    func refresh() { status = SMAppService.mainApp.status }

    /// Register / unregister the login item and surface the REAL outcome (including any error).
    /// Never claims success it didn't get — `refresh()` re-reads the system truth afterward.
    func setEnabled(_ on: Bool) {
        lastError = nil
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Buyer-facing live status text. Pure mapping of the system status → honest copy.
    /// Static so it is unit-testable without a real login-item registration (which can only be
    /// verified in the signed Developer-ID build on a real login).
    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled:          return "On — Sovereign launches automatically when you log in."
        case .notRegistered:    return "Off — Sovereign does not launch at login."
        case .requiresApproval: return "Approval needed — enable Sovereign in System Settings → General → Login Items."
        case .notFound:         return "Unavailable for this copy — run the installed, signed Mac app."
        @unknown default:       return "Login-item status unknown."
        }
    }
    var statusText: String { Self.describe(status) }
}
#endif
