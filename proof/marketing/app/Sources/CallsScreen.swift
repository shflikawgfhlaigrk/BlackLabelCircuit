#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Calls screen (Apollo-gap: the click-to-call surface over the existing
// Dialer engine). Searchable list of the buyer's OWN leads that have phone numbers, one-click
// tel: hand-off (FaceTime / iPhone Continuity on macOS), a post-call quick-log sheet writing to
// the real call-log store, and a per-lead-filterable call history. Honest provider banner: where
// the DialPlan lacks a server voice token (Twilio/Telnyx in-app calling) we say so — the call
// still goes through the system dialer and logs as 'tel'. §5.1: every number on this screen is a
// real count over saved data; the screen ships EMPTY until the buyer adds leads with phones.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - post-call quick-log target (which lead + how the call was placed)

struct CallLogTarget: Identifiable {
    let id = UUID()
    var lead: Lead
    var phone: String
    var provider: String     // "tel" when handed to the system dialer, "manual" when logged only
}

// MARK: - Calls screen

struct CallsScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var leadEngine: LeadEngineStore
    @State private var search = ""
    @State private var logTarget: CallLogTarget?
    @State private var historyFilter: UUID? = nil    // nil = all leads
    @State private var toast = ""

    private var config: TelephonyConfig { leadEngine.settings.telephony }

    /// Leads that can actually be dialed (a tel:-valid phone on the record), search-filtered.
    private var callable: [Lead] {
        let withPhone = model.leads.filter { Dialer.telURL(for: $0.phone) != nil }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return withPhone }
        return withPhone.filter {
            $0.displayName.lowercased().contains(q) || $0.company.lowercased().contains(q)
            || $0.phone.lowercased().contains(q) || Dialer.normalize($0.phone).contains(q)
            || $0.email.lowercased().contains(q)
        }
    }
    private var allWithPhone: Int { model.leads.filter { Dialer.telURL(for: $0.phone) != nil }.count }

    /// Leads that appear in the call log (for the per-lead history filter), newest call first.
    private var calledLeads: [Lead] {
        var seen = Set<UUID>()
        var out: [Lead] = []
        for log in model.callLogs where seen.insert(log.prospectID).inserted {
            if let lead = model.prospect(log.prospectID) { out.append(lead) }
        }
        return out
    }
    private var filteredHistory: [CallLog] {
        guard let id = historyFilter else { return model.callLogs }
        return model.callLogs.filter { $0.prospectID == id }   // callLogs is already newest-first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if os(iOS)
                ScreenHeader(title: "Calls",
                             subtitle: "One-tap calling on your own leads — dial from this \(PlatformWords.device), tag the outcome, and every call lands on the lead's timeline. Nothing here is fabricated: only calls you place or log.")
                #else
                ScreenHeader(title: "Calls",
                             subtitle: "One-click calling on your own leads — dial through your Mac, tag the outcome, and every call lands on the lead's timeline. Nothing here is fabricated: only calls you place or log.")
                #endif

                providerPanel

                dialPanel

                historyPanel

                if !toast.isEmpty {
                    Text(toast).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
        }
        .sheet(item: $logTarget) { target in
            CallQuickLogSheet(target: target).environmentObject(model)
        }
    }

    // MARK: provider banner (honest DialPlan state)

    private var providerPanel: some View {
        Panel(title: "Calling setup", icon: "phone.badge.waveform.fill") {
            HStack(spacing: 8) {
                StatusPill(text: config.provider.label, tint: BLTheme.gold)
                if config.provider.needsCredential {
                    StatusPill(text: config.canPlaceProgrammatic ? "credentials connected" : "no credential",
                               tint: config.canPlaceProgrammatic ? BLTheme.green : BLTheme.sub)
                }
            }
            Text(Dialer.setupNote(config: config))
                .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Stat(label: "Calls today", value: "\(model.callsTodayTotal)")
            Stat(label: "Calls logged (all time)", value: "\(model.callLogs.count)")
        }
    }

    // MARK: click-to-call list

    private var dialPanel: some View {
        Panel(title: "Click to call (\(callable.count))", icon: "phone.fill") {
            if model.leads.isEmpty {
                EmptyState(icon: "phone.badge.plus", title: "No leads yet",
                           hint: "Add or import leads in Leads (CRM). Leads with a phone number appear here for one-click calling.")
            } else if allWithPhone == 0 {
                EmptyState(icon: "phone.badge.plus", title: "No leads with phone numbers",
                           hint: "None of your \(model.leads.count) lead\(model.leads.count == 1 ? " has" : "s have") a phone number yet. Add one on a lead in Leads (CRM) and it appears here.")
            } else {
                Field(title: "Search", text: $search, prompt: "Name, company, phone, or email…")
                if callable.isEmpty {
                    Text("No leads with a phone match \"\(search)\".")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(callable) { lead in dialRow(lead) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func dialRow(_ lead: Lead) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(lead.displayName)
                    .font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                Text([lead.company, lead.phone].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
            Spacer()
            StatusPill(text: lead.status.label, tint: lead.status.tint)
            GhostButton(label: "Log only", icon: "square.and.pencil") {
                logTarget = CallLogTarget(lead: lead, phone: Dialer.normalize(lead.phone), provider: "manual")
            }
            GoldButton(label: "Call", icon: "phone.fill") { dial(lead) }
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func dial(_ lead: Lead) {
        let plan = Dialer.plan(phone: lead.phone, config: config)
        guard plan.canDial, let url = plan.telURL else { toast = plan.message; return }
        NSWorkspace.shared.open(url)
        toast = plan.message
        // Post-call quick log: the hand-off leaves the app in front, so surface the sheet now.
        // Records provider "tel" — honest even under Twilio/Telnyx config (usesProvider is false
        // until a server voice token exists; see Dialer.plan).
        logTarget = CallLogTarget(lead: lead, phone: Dialer.normalize(lead.phone), provider: "tel")
    }

    // MARK: history

    private var historyPanel: some View {
        Panel(title: "Call history (\(filteredHistory.count))", icon: "clock.arrow.circlepath") {
            if model.callLogs.isEmpty {
                EmptyState(icon: "clock.arrow.circlepath", title: "No calls logged yet",
                           hint: "Place or log your first call above — every logged call also lands on the lead's activity timeline.")
            } else {
                historyFilterBar
                LazyVStack(spacing: 8) {
                    ForEach(filteredHistory.prefix(200)) { log in historyRow(log) }
                }
                if filteredHistory.count > 200 {
                    Text("Showing the latest 200 of \(filteredHistory.count) calls — filter by lead to narrow down.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
        }
    }

    private var historyFilterBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All leads") { historyFilter = nil }
                ForEach(calledLeads) { lead in
                    Button(lead.displayName) { historyFilter = lead.id }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 12, weight: .bold))
                    Text(historyFilter.flatMap { id in model.prospect(id)?.displayName } ?? "All leads")
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(.vertical, 7).padding(.horizontal, 12)
                .background(BLTheme.bg2).clipShape(Capsule())
                .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain).fixedSize()
            if historyFilter != nil {
                GhostButton(label: "Clear filter", icon: "xmark") { historyFilter = nil }
            }
            Spacer()
        }
    }

    @ViewBuilder private func historyRow(_ log: CallLog) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: log.disposition.icon).font(.system(size: 12, weight: .bold))
                .foregroundColor(log.disposition.positive ? BLTheme.green : BLTheme.sub)
                .frame(width: 28, height: 28)
                .background((log.disposition.positive ? BLTheme.green : BLTheme.sub).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(model.prospect(log.prospectID)?.displayName ?? "(removed lead)")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                    StatusPill(text: log.disposition.label,
                               tint: log.disposition.positive ? BLTheme.green : BLTheme.sub)
                }
                Text(historyDetail(log))
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                if !log.notes.isEmpty {
                    Text(log.notes).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if historyFilter == nil {
                IconButton(system: "line.3.horizontal.decrease.circle", tint: BLTheme.sub,
                           accessibilityText: "Show only this lead's calls") { historyFilter = log.prospectID }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func historyDetail(_ log: CallLog) -> String {
        var parts = [Self.timeFmt.string(from: log.at)]
        if !log.phone.isEmpty { parts.append(log.phone) }
        if log.durationSec > 0 { parts.append(Self.duration(log.durationSec)) }
        parts.append(log.provider)
        return parts.joined(separator: " · ")
    }
    private static func duration(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

// MARK: - post-call quick log (outcome + duration + notes → real CallLog + timeline activity)

private struct CallQuickLogSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: CallLogTarget
    // Conservative default: .noAnswer (matches CallLog's default) — never pre-claims a connect.
    @State private var disposition: CallDisposition = .noAnswer
    @State private var minutes = ""
    @State private var seconds = ""
    @State private var notes = ""

    var body: some View {
        content
            .sheetCloseBar()
        #if os(macOS)
            .frame(minWidth: 560, minHeight: 520)
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Log call — \(target.lead.displayName)")
                        .font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("\(target.phone.isEmpty ? "no number" : target.phone) · via \(target.provider == "manual" ? "your own phone (manual log)" : "system dialer (tel:)")")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("OUTCOME").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
                    LazyVGrid(columns: blGridColumns(minItemWidth: 150, spacing: 8, macColumns: 2), spacing: 8) {
                        ForEach(CallDisposition.allCases) { d in dispositionChip(d) }
                    }
                }

                HStack(spacing: 12) {
                    Field(title: "Minutes", text: $minutes, prompt: "0")
                    Field(title: "Seconds", text: $seconds, prompt: "0")
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("NOTES").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
                    TextEditor(text: $notes)
                        .font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 90)
                        .padding(8).background(BLTheme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                }

                HStack(spacing: 10) {
                    GhostButton(label: "Discard", icon: "xmark") { dismiss() }
                    GoldButton(label: "Save call log", icon: "checkmark", action: save)
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder private func dispositionChip(_ d: CallDisposition) -> some View {
        let on = disposition == d
        Button { disposition = d } label: {
            HStack(spacing: 6) {
                Image(systemName: d.icon).font(.system(size: 11, weight: .bold))
                Text(d.label).lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(on ? BLTheme.inkOnGold : BLTheme.text)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(on ? BLTheme.gold.opacity(0.7) : BLTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func save() {
        let dur = max(0, (Int(minutes.trimmingCharacters(in: .whitespaces)) ?? 0) * 60
                       + (Int(seconds.trimmingCharacters(in: .whitespaces)) ?? 0))
        model.logCall(CallLog(prospectID: target.lead.id,
                              phone: target.phone,
                              disposition: disposition,
                              durationSec: dur,
                              notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                              provider: target.provider))
        dismiss()
    }
}
#endif // circuit-convert
