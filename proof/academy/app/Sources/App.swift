#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

@main
struct BlackLabelAcademyApp: App {
    init() {
        // Headless proof hook: `Black Label Academy --selftest-resume` round-trips the last-opened
        // lesson through the on-disk progress DB and exits, proving resume-last-lesson without a
        // WindowServer. Platform-agnostic (progress persistence exists on both targets).
        if CommandLine.arguments.contains("--selftest-resume") { runResumeSelfTest() }
        // Headless proof hook: `Black Label Academy --selftest-certificates` runs the completion-
        // detection logic and renders a real certificate PDF to a temp dir, then exits — proving the
        // on-device certificates without a WindowServer. Platform-agnostic (certificates ship on both).
        if CommandLine.arguments.contains("--selftest-certificates") { runCertificateSelfTest() }
        // Headless proof hook: `Black Label Academy --selftest-spotlight` builds the CoreSpotlight
        // payload for every lesson and asserts it is sourced-only, then exits (AC-18). Platform-
        // agnostic (Spotlight indexing ships on both targets).
        if CommandLine.arguments.contains("--selftest-spotlight") { runSpotlightSelfTest() }
        // Headless proof hook: `Black Label Academy --selftest-recall` runs the AC-19 spaced-repetition
        // scheduler + the 1:1/H6 recall-card invariant and exits. Platform-agnostic (recall ships on both).
        if CommandLine.arguments.contains("--selftest-recall") { runRecallSelfTest() }
        // Headless proof hook: `Black Label Academy --selftest-tutor` proves the AC-20 grounded tutor's
        // cite-or-refuse contract and exits. Platform-agnostic (the library tutor ships on both targets).
        if CommandLine.arguments.contains("--selftest-tutor") { runTutorSelfTest() }
        // Headless proof hook: `Black Label Academy --selftest-streak` proves the AC-21 study habit —
        // the streak grows only on real completed reviews, freezes bridge honestly, a planted streak is
        // rejected, and "due today" is the real scheduler count. Platform-agnostic (habit ships on both).
        if CommandLine.arguments.contains("--selftest-streak") { runStudyHabitSelfTest() }
        // Headless proof hook: `Black Label Academy --selftest-cohort` proves the AC-09 cohort peer
        // signal's three honesty invariants — not-joined→zero network, joined+empty→honest empty, a
        // planted peer count rejected — and exits. Platform-agnostic (cohort ships on both targets).
        if CommandLine.arguments.contains("--selftest-cohort") { runCohortSelfTest() }
        // Headless proof hook: `Black Label Academy --selftest-provenance` proves the AC-16 per-claim
        // provenance surface — a planted estimate/unsourced figure renders the honest state (never
        // dressed as sourced) and a real claim maps 1:1 to its compiled source, audited against the
        // whole lint-gated library. Platform-agnostic (the tappable reader ships on both targets).
        if CommandLine.arguments.contains("--selftest-provenance") { runProvenanceSelfTest() }
        #if os(macOS) && !MAS_BUILD
        // Headless proof hook: `Black Label Academy --selftest-trial` runs the entitlement state
        // machine and exits, so the trial → hard-gate flow is verifiable without a WindowServer.
        // macOS-only: the iOS build carries no trial/subscription machinery (App Store 3.1.1),
        // and the Mac App Store build carries neither trial nor updater (2.4.5/3.1.1).
        if CommandLine.arguments.contains("--selftest-trial") { runTrialSelfTest() }
        // Headless proof hook: `Black Label Academy --selftest-updater` runs the in-app auto-updater's
        // five safety properties (manifest parse, strictly-newer-only, sha256-mismatch refusal,
        // malformed/unreachable → no prompt, dry-run) and exits. macOS-only: the updater is the
        // Developer-ID direct-download path; the iOS app updates through the App Store.
        if CommandLine.arguments.contains("--selftest-updater") { runUpdaterSelfTest() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            // The silent daily update check runs from RootView's onAppear, gated on the account's
            // entitlement (a canceled/lapsed reader keeps its library but stops pulling new content).
            RootView()
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        #endif
        #if os(macOS) && !MAS_BUILD
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { UpdaterUI.checkInteractively() }
            }
        }
        #endif
    }
}
#endif // circuit-convert
