// Sovereign — REVIEWER / SAMPLE ("Demo") MODE.
//
// WHY THIS EXISTS (App Store Guideline 2.1):
// The shipped product runs on the BUYER's own brain — the private on-device Apple model, or
// the buyer's own External login. An App Store reviewer has neither configured, so the app would
// otherwise start empty and a reviewer could not exercise a single signature feature. That is an
// automatic 2.1 rejection. Demo Mode lets a reviewer (or a prospective buyer) experience the FULL
// app with ZERO external accounts: no External login, no API key, no mailbox, no sign-in.
//
// HONESTY / SHIP-NO-DATA (Michael's binding — above all else):
//   • Demo Mode is OFF by default. It is entered ONLY by an explicit, clearly-labeled
//     "Explore with sample data" button on the sign-in screen, or the SOV_DEMO=1 env var
//     (used for screenshots). The shipped real path is never affected.
//   • Every record it shows is SYNTHETIC and obviously fictional (Demo Personas, lorem-style
//     facts) — no real leads, metrics, memories, conversations, tokens, or personal data.
//   • The synthetic data is seeded IN MEMORY ONLY. While Demo Mode is active, every store
//     SUPPRESSES persistence, so nothing demo ever touches the on-disk JSON / UserDefaults /
//     Keychain. Quit the app and the demo evaporates; the buyer's real (empty) state is intact.
//   • Any action that would reach an external service (a brain call, an email send, an account
//     write) is SAFELY SIMULATED and labeled "Demo" — no real network egress, no login required.
//
// Result: a reviewer sees a fully-populated, end-to-end product; a buyer's real install still
// starts empty on their own accounts. The two never mix.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// App-wide flag for reviewer/sample mode. A single source of truth the whole app reads.
/// `@Published` so banners and the simulated brain react live the instant it flips on.
@MainActor
final class DemoMode: ObservableObject {
    static let shared = DemoMode()

    /// True only while the reviewer/sample experience is active. Default OFF.
    @Published private(set) var active = false

    private init() {}

    /// Honors the screenshot/preview env gate so a build snapshot can launch straight into the
    /// populated app WITHOUT shipping that behavior on (the gate is read, never baked true).
    static var envRequested: Bool {
        let v = ProcessInfo.processInfo.environment["SOV_DEMO"]?.lowercased()
        return v == "1" || v == "true" || v == "yes"
    }

    func enter() { active = true }
    func exit()  { active = false }

    /// The canned, clearly-labeled assistant reply used in Demo Mode in place of a real brain
    /// call (no AI account exists in demo). Deterministic, obviously a sample, and on-topic enough
    /// to demonstrate the chat surface. NEVER presented as a real model answer.
    static func cannedReply(to prompt: String) -> String {
        let p = prompt.lowercased()
        let body: String
        if p.contains("weather") {
            body = "In the full app I'd ground this on the live, keyless weather feed (which already works without any account — open the Weather tab to see real conditions). For now, here's the shape of a real answer: I'd pull the current temperature, conditions, and wind for the place you named and summarize what to expect today."
        } else if p.contains("email") || p.contains("draft") || p.contains("reply") {
            body = "Here's how a real draft would look:\n\nSubject: Following up on our conversation\n\nHi Priya — thanks again for your time today. To recap, we agreed I'd send Cedar & Vine Catering the updated proposal by Friday, and you'd loop in your operations lead. I'll have it over by end of week. Anything else you need from me in the meantime?\n\nBest,\nMarcus Okafor\n\nIn the full app this is generated live by YOUR chosen brain — Ornith 1.0 locally through Ollama by default, or the private on-device model where available."
        } else if p.contains("summar") || p.contains("notes") || p.contains("action") {
            body = "A real run would read your text and return tight, faithful bullets — for example:\n\n• Kickoff with Harborlight Studios scheduled; scope locked to phase one\n• Open item: pricing sign-off (owner: Finance)\n• Risk: Riverstone Logistics lead time — mitigate by ordering early\n\nThe full app produces this live from YOUR input, grounded on your own notes and memory."
        } else if p.contains("plan") || p.contains("project") {
            body = "Here's the kind of plan you'd get:\n\n1. Define the goal and the done-state\n2. Break it into 3–5 milestones with owners\n3. Sequence the first week of tasks\n4. Set a check-in cadence\n\nIn the full app I'd ask for your goal and deadline, then tailor each step — running on the brain you own."
        } else {
            body = "This is a SAMPLE reply so you can see the chat experience end-to-end without setup. In the full app, every answer is generated live by the brain YOU choose — Ornith 1.0 locally through Ollama by default, or Apple's private on-device model where available — and grounded on your own memory, knowledge, and notes. Connect a brain in Settings to switch from this sample to real, live answers."
        }
        return body
    }

    /// Visible label appended to a demo assistant reply so it can never be mistaken for a real
    /// model answer (zero-hallucination binding). Rendered by the chat as a muted footnote.
    static let replyFootnote = "— Sample reply (Demo Mode · no AI account used)"
}
