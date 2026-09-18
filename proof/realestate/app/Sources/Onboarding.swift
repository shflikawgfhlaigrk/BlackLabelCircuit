// Black Label Real Estate — ONBOARDING COPY (canonical, testable).
//
// RE-03 (FULL-STANDARD): first-run must be honest and reconciled with what the app ACTUALLY does.
// The bundled README once implied you "paste your access key when prompted" at sign-in — but there is
// no access-key field at sign-in: the Lead Database access key is entered later in Settings, and the
// real front doors are a local account, Apple/Google, or the prominent "use it now" guest path.
//
// These constants are the single source of truth for that copy so AuthView and the engine test suite
// assert the SAME strings — the onboarding contract can't silently drift back out of sync.
import Foundation

enum Onboarding {
    /// The prominent zero-friction entry — matches the README's "continue as guest" promise.
    static let guestCTA = "Continue as guest — use it now"

    /// One honest line under the guest CTA: no login, and where the access key REALLY goes (Settings),
    /// so nobody hunts for an access-key box on the sign-in screen that was never there.
    static let guestSubnote =
        "No account or access key needed. Your Lead Database access key (for higher row limits) goes in Settings → Data later — never at sign-in."

    /// Where the Lead Database access key is entered. Named so the README and the app agree.
    static let accessKeyLocation = "Settings → Data"

    /// Invariants a first-run copy test enforces (kept trivial + pure so run_tests can check them).
    static func guestCTAIsProminentAndHonest() -> Bool {
        guestCTA.localizedCaseInsensitiveContains("guest") &&
        guestCTA.localizedCaseInsensitiveContains("use it now")
    }
    static func accessKeyGuidancePointsToSettings() -> Bool {
        guestSubnote.contains(accessKeyLocation) &&
        guestSubnote.localizedCaseInsensitiveContains("access key")
    }
}
