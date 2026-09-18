#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Away Alerts — the first-class, self-monitored off-device alerting surface.
//
// Vigil is self-monitored: a critical alert (fall / no-breathing / intrusion) is POSTed to
// an endpoint the BUYER controls — their phone (via ntfy / Pushover / Apple Shortcuts), a
// caregiver, a chat webhook — IN ADDITION to the desktop banner. Vigil runs no server of
// its own and calls no monitoring center (§5.5, own-it). This card is where a buyer sets
// that up, PROVES it with a real test POST, and reads the honest delivery health — the
// direct answer to the #1 security-buyer objection ("what happens when I'm not home?").
//
// Honesty (§5.1/§5.2): ships empty (no default endpoint); a malformed URL is rejected, not
// silently kept; the "Send test alert" button fires a REAL POST and shows the REAL outcome
// — never a fake instant "sent"; the self-monitored disclaimer (AwayAlerts.selfMonitored-
// Disclaimer) is rendered verbatim so the app never implies professional dispatch.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct AwayAlertsCard: View {
    @EnvironmentObject var store: HomeStore
    @State private var draft: String = ""
    @State private var showEditor: Bool = false
    @State private var invalid: Bool = false

    private static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    var body: some View {
        Card(title: "Away Alerts", subtitle: "reach your phone when you're not at this Mac") {
            disclaimerRow
            Divider().overlay(Palette.stroke).padding(.vertical, 2)
            relayStatusRow
            if let health = RelayHealth.forCard(isConfigured: store.state.relay.isConfigured,
                                                last: store.state.relay.lastDelivery) {
                healthRow(health)
            }
            if store.state.relay.isConfigured { testAlertRow }
            if showEditor { editor }
            recipeHint
        }
    }

    // The load-bearing honesty line — verbatim from the canonical constant so the promise
    // the app makes matches the docs and the storefront exactly (§5.1).
    private var disclaimerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shield.lefthalf.filled").font(.system(size: 12)).foregroundColor(Palette.gold)
            Text(AwayAlerts.selfMonitoredDisclaimer)
                .font(.system(size: 11)).foregroundColor(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var relayStatusRow: some View {
        let relay = store.state.relay
        return HStack(spacing: 8) {
            Image(systemName: relay.isConfigured ? "antenna.radiowaves.left.and.right" : "wifi.slash")
                .foregroundColor(relay.isConfigured ? .green : Palette.gold)
            Text(relay.statusLabel).font(.system(size: 11)).foregroundColor(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            GhostButton(title: showEditor ? "Close" : (relay.isConfigured ? "Edit" : "Add endpoint")) {
                draft = relay.webhook; invalid = false; showEditor.toggle()
            }
        }
    }

    private func healthRow(_ health: RelayHealth) -> some View {
        HStack(spacing: 6) {
            Image(systemName: health.symbol).font(.system(size: 10))
                .foregroundColor(health.ok ? .green : (health == .noneSent ? Palette.dim : .red))
            Text(health.text(clock: health.at.map(Self.clock) ?? ""))
                .font(.system(size: 10))
                .foregroundColor(health == .noneSent ? Palette.dim : (health.ok ? Palette.dim : .red))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
        }
    }

    // The PROVE-IT control. A real POST, a real outcome — the honest analogue of a
    // monitoring company's test signal (which Vigil, being self-monitored, has none of).
    private var testAlertRow: some View {
        HStack(spacing: 8) {
            if store.testAlertInFlight {
                ProgressView().controlSize(.small)
                Text("Sending a test alert to your relay…")
                    .font(.system(size: 11)).foregroundColor(Palette.goldTxt)
            } else {
                GhostButton(title: "Send test alert") { store.sendTestAlert() }
                Text("Fires a real, clearly-labelled TEST to your endpoint so you can confirm it reaches your phone.")
                    .font(.system(size: 10)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
        }
    }

    private var editor: some View {
        let relay = store.state.relay
        return VStack(alignment: .leading, spacing: 6) {
            TextField("https://ntfy.sh/your-topic  (or any webhook URL you control)", text: $draft)
                .textFieldStyle(.roundedBorder).font(.system(size: 11))
            if invalid {
                Text("That isn't a valid http(s) URL — not saved.")
                    .font(.system(size: 10)).foregroundColor(.red)
            }
            HStack(spacing: 8) {
                GhostButton(title: "Save") {
                    if store.setRelayWebhook(draft) { invalid = false; showEditor = false }
                    else { invalid = true }
                }
                if relay.isConfigured {
                    GhostButton(title: "Remove") {
                        store.clearRelayWebhook(); draft = ""; invalid = false; showEditor = false
                    }
                }
                Spacer()
            }
        }
    }

    private var recipeHint: some View {
        Text("Free phone setup: create a topic at ntfy.sh, install the ntfy app, subscribe to that topic, and paste its URL above. Also works with Pushover or an Apple Shortcuts webhook. See DOCUMENTATION.md ▸ Away Alerts.")
            .font(.system(size: 10)).foregroundColor(Palette.dim)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// VG-27 — Elder / solo monitor mode. Fuses gate-passing breathing + heart readings with
// fused presence into a single concern, debounced 20s (VitalsMonitor), and pages a
// DESIGNATED CONTACT through the same buyer-owned Away Alerts relay. Honesty rails: the
// card renders the not-a-medical-device / no-dispatch line verbatim; monitor mode can only
// claim "on" when a relay endpoint actually exists (MonitorConfig.statusLabel); a concern
// is raised only off a real gate-passing reading (never a fabricated number, §5.1).
struct MonitorModeCard: View {
    @EnvironmentObject var store: HomeStore
    @State private var contactDraft: String = ""
    @State private var editingContact = false

    var body: some View {
        Card(title: "Monitor mode", subtitle: "elder / solo vitals watch — breathing + heart + presence") {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 12)).foregroundColor(Palette.gold)
                Text("Vigil is NOT a medical device and does NOT contact emergency services. Monitor mode pages a designated contact when a gated vitals reading is unusual for 20 seconds — a nudge to check in, never a diagnosis or a dispatch.")
                    .font(.system(size: 11)).foregroundColor(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Palette.stroke).padding(.vertical, 2)
            Toggle(isOn: Binding(get: { store.state.monitor.enabled },
                                 set: { store.setMonitorMode(enabled: $0) })) {
                Text("Monitor mode").font(.system(size: 12)).foregroundColor(.white)
            }.tint(Palette.gold)
            Text(store.state.monitor.statusLabel(relayConfigured: store.state.relay.isConfigured))
                .font(.system(size: 11)).foregroundColor(Palette.dim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").font(.system(size: 12)).foregroundColor(Palette.gold)
                let who = store.state.monitor.designatedContact
                Text(who.isEmpty ? "Designated contact: —" : "Designated contact: \(who)")
                    .font(.system(size: 11)).foregroundColor(Palette.dim)
                Spacer(minLength: 6)
                GhostButton(title: editingContact ? "Close" : "Edit") {
                    contactDraft = who; editingContact.toggle()
                }
            }
            if editingContact {
                HStack(spacing: 8) {
                    TextField("Contact name (e.g. Sarah, daughter)", text: $contactDraft)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11))
                    GhostButton(title: "Save") { store.setDesignatedContact(contactDraft); editingContact = false }
                }
            }
            if !store.state.relay.isConfigured {
                Text("Set up an Away Alerts relay above so a concern can actually reach your contact off this Mac.")
                    .font(.system(size: 10)).foregroundColor(Palette.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
#endif // circuit-convert
