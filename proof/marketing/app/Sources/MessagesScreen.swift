#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Messages screen (iMessage / RCS / SMS over the buyer's OWN Sendblue line).
//
// Structural twin of CallsScreen: an honest provider banner, a compose surface over the buyer's own
// leads, and a real thread history. Every send goes through the ONE chokepoint (MessagingSender),
// so the TCPA gate, the per-line ledger and the simulated-when-unconfigured rule apply here exactly
// as they do to a cadence step or the MCP tool.
//
// §5.1 / §5.2: this screen ships EMPTY. Every count is a real count over saved messages; the iMessage
// vs SMS badge is only ever painted from a live `/api/evaluate-service` answer — never guessed from
// the number, never assumed blue.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct MessagesScreen: View {
    @EnvironmentObject var model: AppModel

    @State private var state = MessageStore.load()
    @State private var search = ""
    @State private var toNumber = ""
    @State private var body_ = ""
    @State private var selectedLead: UUID? = nil
    @State private var selectedThread: String? = nil
    @State private var sendStyle: SendblueSendStyle? = nil
    @State private var evaluation: SendblueServiceEvaluation? = nil
    @State private var evaluating = false
    @State private var sending = false
    @State private var toast = ""
    @State private var toastIsError = false

    private var configured: Bool { SendblueConfig.isConfigured }
    private var needsReconnect: Bool { SendblueConfig.credentialNeedsReconnect }

    /// Leads with a number we can actually normalize to E.164, search-filtered.
    private var textable: [Lead] {
        let withPhone = model.leads.filter { PhoneNumber.e164($0.phone) != nil }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return withPhone }
        return withPhone.filter {
            $0.displayName.lowercased().contains(q) || $0.company.lowercased().contains(q)
            || $0.phone.lowercased().contains(q) || $0.email.lowercased().contains(q)
        }
    }
    private var allWithPhone: Int { model.leads.filter { PhoneNumber.e164($0.phone) != nil }.count }

    private var threads: [String] { MessageStore.threads(in: state) }
    private var visibleThread: [StoredMessage] {
        guard let selectedThread else { return state.messages }
        return MessageStore.thread(selectedThread, in: state)
    }
    private var sentCount: Int { state.messages.filter { $0.direction == .outbound && $0.wasSent }.count }
    private var blockedCount: Int { state.messages.filter { !$0.blockedReason.isEmpty }.count }
    private var failedCount: Int { state.messages.filter { $0.failed }.count }
    private var simulatedCount: Int { state.messages.filter { $0.simulated }.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(title: "Messages",
                             subtitle: "Text your own leads over your own Sendblue line — iMessage where the number supports it, SMS/RCS where it doesn't. Consent, STOP and quiet hours are enforced before anything sends, and nothing here is fabricated: only messages you actually sent or received.")

                providerPanel
                composePanel
                historyPanel

                if !toast.isEmpty {
                    Text(toast)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(toastIsError ? BLTheme.danger : BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
        }
        .onAppear { state = MessageStore.load() }
    }

    // MARK: - honest provider banner

    private var providerPanel: some View {
        Panel(title: "Messaging setup", icon: "message.badge.waveform.fill") {
            HStack(spacing: 8) {
                StatusPill(text: configured ? "Sendblue connected" : (needsReconnect ? "Saved key needs reconnect" : "Not connected"),
                           tint: configured ? BLTheme.green : (needsReconnect ? BLTheme.gold : BLTheme.sub))
                if !SendblueConfig.fromNumber.isEmpty {
                    StatusPill(text: "from \(SendblueConfig.fromNumber)", tint: BLTheme.gold)
                }
                if SendblueConfig.dailyLineCap > 0 {
                    StatusPill(text: "cap \(SendblueConfig.dailyLineCap)/day", tint: BLTheme.sub)
                }
            }
            Text(setupNote)
                .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Stat(label: "Messages sent (all time)", value: "\(sentCount)")
            Stat(label: "Simulated (nothing left this Mac)", value: "\(simulatedCount)")
            Stat(label: "Blocked by the consent gate", value: "\(blockedCount)")
            Stat(label: "Refused by Sendblue", value: "\(failedCount)")
            Stat(label: "Numbers that replied STOP", value: "\(state.optedOut.count)")
        }
    }

    private var setupNote: String {
        if configured {
            return "Sends run on your own Sendblue account. Sendblue picks iMessage, RCS or SMS per number — the badge below shows what a live capability check returned, never a guess. Every send still passes the consent + STOP + 8am–9pm quiet-hours gate first."
        }
        if needsReconnect {
            return "Your Sendblue key is saved but this build can't read it from the Keychain. Re-enter it in Connectors → Messaging. Until then every send is simulated and nothing leaves this Mac."
        }
        return "Not connected. Add your own Sendblue API key id + secret in Connectors → Messaging. Until then you can still compose and the consent gate still runs, but every send is marked simulated — nothing leaves this Mac."
    }

    // MARK: - compose

    private var composePanel: some View {
        Panel(title: "New message", icon: "square.and.pencil") {
            if model.leads.isEmpty {
                EmptyState(icon: "person.badge.plus", title: "No leads yet",
                           hint: "Add or import leads in Leads (CRM). Leads with a phone number appear here, or type any number below.")
            } else if allWithPhone == 0 {
                EmptyState(icon: "phone.badge.plus", title: "No leads with phone numbers",
                           hint: "None of your \(model.leads.count) lead\(model.leads.count == 1 ? " has" : "s have") a phone number yet. Add one in Leads (CRM), or type a number below.")
            }

            if allWithPhone > 0 {
                Field(title: "Search your leads", text: $search, prompt: "Name, company, phone, or email…")
                if textable.isEmpty {
                    Text("No lead with a textable number matches \"\(search)\".")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(textable.prefix(50)) { lead in leadRow(lead) }
                    }
                    if textable.count > 50 {
                        Text("Showing 50 of \(textable.count) — narrow the search to see the rest.")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
            }

            Field(title: "To (E.164)", text: $toNumber, prompt: "+15551234567")
            serviceBadgeRow
            consentRow

            VStack(alignment: .leading, spacing: 5) {
                Text("MESSAGE").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
                TextEditor(text: $body_)
                    .font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 90)
                    .padding(8).background(BLTheme.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                Text("\(body_.count) / \(SendblueAPI.contentCharacterLimit) characters")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(body_.count > SendblueAPI.contentCharacterLimit ? BLTheme.danger : BLTheme.sub)
            }

            sendStylePicker

            HStack(spacing: 10) {
                GhostButton(label: evaluating ? "Checking…" : "Check iMessage", icon: "questionmark.circle") { evaluate() }
                    .disabled(evaluating || PhoneNumber.e164(toNumber) == nil)
                GoldButton(label: sending ? "Sending…" : (configured ? "Send" : "Send (simulated)"), icon: "paperplane.fill") { send() }
                    .disabled(sending)
                Spacer()
            }
        }
    }

    @ViewBuilder private func leadRow(_ lead: Lead) -> some View {
        let normalized = PhoneNumber.e164(lead.phone) ?? lead.phone
        let on = selectedLead == lead.id
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lead.displayName)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                Text([lead.company, normalized].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
            Spacer()
            if MessageStore.contains(state.optedOut, normalized) {
                StatusPill(text: "opted out", tint: BLTheme.danger)
            } else if MessageStore.contains(state.consented, normalized) {
                StatusPill(text: "consent on file", tint: BLTheme.green)
            } else {
                StatusPill(text: "no consent", tint: BLTheme.sub)
            }
            GhostButton(label: on ? "Selected" : "Text", icon: "message.fill") {
                selectedLead = lead.id
                toNumber = normalized
                evaluation = nil
                selectedThread = normalized
            }
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? BLTheme.gold.opacity(0.6) : BLTheme.stroke, lineWidth: 1))
    }

    /// The iMessage / SMS badge — painted ONLY from a live evaluate-service answer.
    @ViewBuilder private var serviceBadgeRow: some View {
        HStack(spacing: 8) {
            if let e = evaluation, let service = e.service, e.ok {
                StatusPill(text: service.label, tint: service == .iMessage ? .blue : BLTheme.green)
                Text(e.detail).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            } else if let e = evaluation {
                StatusPill(text: "unknown", tint: BLTheme.sub)
                Text(e.detail).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            } else {
                StatusPill(text: "service unchecked", tint: BLTheme.sub)
                Text("Sendblue routes iMessage → RCS → SMS on its own. Run the capability check to see what this number actually supports.")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    /// Consent is a hard TCPA gate, so it is a first-class control — not buried in settings.
    @ViewBuilder private var consentRow: some View {
        let normalized = PhoneNumber.e164(toNumber)
        let hasConsent = normalized.map { MessageStore.contains(state.consented, $0) } ?? false
        let optedOut = normalized.map { MessageStore.contains(state.optedOut, $0) } ?? false
        HStack(spacing: 10) {
            if optedOut {
                StatusPill(text: "STOP on file — sending is blocked", tint: BLTheme.danger)
                GhostButton(label: "Clear opt-out (they asked back in)", icon: "arrow.uturn.left") {
                    guard let normalized else { return }
                    MessageStore.setOptedOut(false, for: normalized)
                    state = MessageStore.load()
                }
            } else {
                StatusPill(text: hasConsent ? "Consent recorded" : "No consent recorded",
                           tint: hasConsent ? BLTheme.green : BLTheme.sub)
                GhostButton(label: hasConsent ? "Withdraw consent" : "I have prior express consent",
                            icon: hasConsent ? "xmark.circle" : "checkmark.seal") {
                    guard let normalized else { flash("Enter a valid number first.", error: true); return }
                    MessageStore.setConsent(!hasConsent, for: normalized)
                    state = MessageStore.load()
                }
            }
            Spacer()
        }
    }

    private var sendStylePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("SEND STYLE (iMESSAGE ONLY)").font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.sub).tracking(0.7)
            Picker("", selection: $sendStyle) {
                Text("None").tag(SendblueSendStyle?.none)
                ForEach(SendblueSendStyle.allCases) { s in Text(s.label).tag(SendblueSendStyle?.some(s)) }
            }
            .labelsHidden().frame(width: 240)
            Text("An SMS or RCS fallback drops the effect — Sendblue decides the transport, so treat this as a bonus, not a guarantee.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - history

    private var historyPanel: some View {
        Panel(title: "Messages (\(visibleThread.count))", icon: "bubble.left.and.bubble.right.fill") {
            if state.messages.isEmpty {
                EmptyState(icon: "bubble.left.and.bubble.right", title: "No messages yet",
                           hint: "Send your first message above. Every send — real, simulated, or blocked by the consent gate — is recorded here and on the lead's timeline.")
            } else {
                threadFilterBar
                LazyVStack(spacing: 8) {
                    ForEach(visibleThread.prefix(200)) { m in messageRow(m) }
                }
                if visibleThread.count > 200 {
                    Text("Showing the latest 200 of \(visibleThread.count) — filter by thread to narrow down.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
        }
    }

    private var threadFilterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All threads") { selectedThread = nil }
                ForEach(threads, id: \.self) { n in Button(threadLabel(n)) { selectedThread = n } }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 12, weight: .bold))
                    Text(selectedThread.map(threadLabel) ?? "All threads").lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(.vertical, 7).padding(.horizontal, 12)
                .background(BLTheme.bg2).clipShape(Capsule())
                .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain).fixedSize()
            if selectedThread != nil {
                GhostButton(label: "Clear filter", icon: "xmark") { selectedThread = nil }
            }
            Spacer()
        }
    }

    private func threadLabel(_ number: String) -> String {
        let key = PhoneNumber.key(number)
        if let lead = model.leads.first(where: { PhoneNumber.key($0.phone) == key }) {
            return "\(lead.displayName) · \(number)"
        }
        return number
    }

    @ViewBuilder private func messageRow(_ m: StoredMessage) -> some View {
        let blocked = !m.blockedReason.isEmpty
        let tint: Color = (blocked || m.failed) ? BLTheme.danger
            : m.simulated ? BLTheme.gold
            : m.direction == .inbound ? BLTheme.green : .blue
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: blocked ? "hand.raised.fill"
                  : m.failed ? "exclamationmark.triangle.fill"
                  : (m.direction == .inbound ? "bubble.left.fill" : "paperplane.fill"))
                .font(.system(size: 12, weight: .bold)).foregroundColor(tint)
                .frame(width: 28, height: 28)
                .background(tint.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(threadLabel(m.number))
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                    if let service = m.service {
                        StatusPill(text: service.label, tint: service == .iMessage ? .blue : BLTheme.green)
                    }
                    if let status = m.status {
                        StatusPill(text: status.label, tint: status.isFailure ? BLTheme.danger : (status.isDelivered ? BLTheme.green : BLTheme.sub))
                    }
                    if m.simulated { StatusPill(text: "simulated", tint: BLTheme.gold) }
                    if blocked { StatusPill(text: "blocked", tint: BLTheme.danger) }
                    if m.failed { StatusPill(text: "not sent", tint: BLTheme.danger) }
                }
                if !m.body.isEmpty {
                    Text(m.body).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                        .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                }
                Text(Self.timeFmt.string(from: m.at) + (m.detail.isEmpty ? "" : " · " + m.detail))
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    // MARK: - actions

    private func evaluate() {
        evaluating = true
        let number = toNumber
        Task {
            let result = await MessagingSender.evaluateService(number)
            await MainActor.run {
                evaluating = false
                evaluation = result
                if !result.ok { flash(result.detail, error: true) }
            }
        }
    }

    private func send() {
        sending = true
        let number = toNumber
        let text = body_
        let style = sendStyle
        let lead = selectedLead.flatMap { id in model.leads.first { $0.id == id } }
        let pid = (lead.map { PhoneNumber.key($0.phone) == PhoneNumber.key(number) } ?? false) ? lead?.id : nil
        Task {
            let result = await MessagingSender.send(to: number, body: text, model: model,
                                                    prospectID: pid, sendStyle: style)
            await MainActor.run {
                sending = false
                state = MessageStore.load()
                selectedThread = PhoneNumber.e164(number) ?? number
                if result.sent { body_ = "" }
                flash(result.detail, error: result.blocked != nil)
            }
        }
    }

    private func flash(_ message: String, error: Bool) {
        toast = message
        toastIsError = error
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { if toast == message { toast = "" } }
    }
}
#endif // circuit-convert
