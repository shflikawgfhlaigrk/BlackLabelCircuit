#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — POWER TOOLS: List Builder, Skip Trace, Compliance, Deal Accounting.
// Each surfaces a real engine (ListEngine / SkipTrace / ComplianceEngine / DealAccounting) on
// the buyer's own data. No fabricated rows, no fake "sent/compliant" — honest gates throughout.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: ================= CRM SMART LISTS (secondary List Builder tab) =================
// Filters over the buyer's OWN saved CRM leads (not the national index) — kept as the
// "My CRM lists" tab inside ListBuilderScreen. The primary list-building experience is
// the guided database-backed builder in ListBuilderScreen.swift.
struct CRMSmartListsView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = LeadFilter()
    @State private var listName = ""
    @State private var savedNote = ""
    @State private var stackMin = 2
    @State private var showStack = false
    @State private var pendingDelete: SmartList?

    private var results: [Lead] { ListEngine.apply(filter, to: model.leads) }
    private var stacked: [(Lead, Int)] { ListEngine.stack(model.smartLists, over: model.leads, minListCount: stackMin) }

    var body: some View {
        // One combined pass over the leads for ALL template count badges (was O(templates × leads)
        // re-run per render, and this screen re-renders on every keystroke in the text filter).
        let templates = ListTemplates.all
        let templateCounts = ListEngine.counts(templates.map { $0.filter }, over: model.leads)
        return ScrollView { VStack(alignment: .leading, spacing: 18) {
            Text("These lists filter the leads you've already saved to your CRM. To build a list from the live property-record database, use the Build from database tab.")
                .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            // Distressed list templates (one-tap apply)
            Panel(title: "Motivated-seller list types", icon: "rectangle.stack.fill", glow: true) {
                Text("Apply a distressed-seller list to your captured leads. Each keys only on signals the app can verify — gated lists say what real data they'd need; nothing is fabricated.")
                    .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 8) {
                    ForEach(Array(templates.enumerated()), id: \.element.id) { idx, t in
                        Button { withAnimation { filter = t.filter } } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "line.3.horizontal.decrease.circle").font(.blSystem(size: 10, weight: .bold))
                                Text(t.name).font(BLFont.body(11.5, .semibold))
                                Text("\(templateCounts[idx])").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.ink)
                                    .padding(.vertical, 1).padding(.horizontal, 5).background(BLTheme.goldGrad).clipShape(Capsule())
                            }
                            .foregroundColor(BLTheme.text).padding(.vertical, 6).padding(.horizontal, 10)
                            .background(BLTheme.bg2).clipShape(Capsule()).overlay(Capsule().stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
                        }.buttonStyle(.plain).help(t.blurb + (t.needs.isEmpty ? "" : "\n\n⚠︎ " + t.needs))
                    }
                }
            }

            // Live filters
            Panel(title: "Filters", icon: "slider.horizontal.3") {
                HStack {
                    Text("\(filter.activeCount) filter\(filter.activeCount == 1 ? "" : "s") active").font(BLFont.body(12, .bold)).foregroundColor(BLTheme.gold)
                    Spacer()
                    if !filter.isEmpty { GhostButton(label: "Clear", icon: "xmark", tint: BLTheme.sub) { withAnimation { filter = LeadFilter() } } }
                }
                // source chips
                chipRow("SOURCE", LeadSource.allCases.map { ($0.label, filter.sources.contains($0)) }) { i in
                    let s = LeadSource.allCases[i]; if filter.sources.contains(s) { filter.sources.remove(s) } else { filter.sources.insert(s) }
                }
                // stage chips
                chipRow("STAGE", LeadStatus.allCases.map { ($0.label, filter.statuses.contains($0)) }) { i in
                    let s = LeadStatus.allCases[i]; if filter.statuses.contains(s) { filter.statuses.remove(s) } else { filter.statuses.insert(s) }
                }
                // value band
                HStack(spacing: 12) {
                    optIntField("Min value $", get: filter.minValue) { filter.minValue = $0 }
                    optIntField("Max value $", get: filter.maxValue) { filter.maxValue = $0 }
                }
                // toggles
                FlowLayout(spacing: 8) {
                    toggleChip("Absentee owner", filter.absenteeOnly) { filter.absenteeOnly.toggle() }
                    toggleChip("Parcel-resolved", filter.resolvedOnly) { filter.resolvedOnly.toggle() }
                    triChip("Phone", filter.hasPhone) { filter.hasPhone = $0 }
                    triChip("Email", filter.hasEmail) { filter.hasEmail = $0 }
                    triChip("Mailing addr", filter.hasMailingAddress) { filter.hasMailingAddress = $0 }
                    triChip("Open tasks", filter.hasOpenTasks) { filter.hasOpenTasks = $0 }
                }
                Field(title: "Text contains (name / address / notes)", text: $filter.text, prompt: "search…")
            }

            // Results + save / export
            Panel(title: "Matches", icon: "person.3.fill", glow: !results.isEmpty) {
                HStack {
                    Text("\(results.count) lead\(results.count == 1 ? "" : "s") match").font(BLFont.body(13, .bold)).foregroundColor(BLTheme.text)
                    Spacer()
                    if !results.isEmpty { GhostButton(label: "Export CSV", icon: "square.and.arrow.up", tint: BLTheme.gold) { exportCSV(results) } }
                }
                HStack(spacing: 8) {
                    TextField("Name this list (e.g. \"ATL probate absentee\")", text: $listName).textFieldStyle(.plain).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    GoldButton(label: "Save smart list", icon: "tray.and.arrow.down") { saveList() }.disabled(filter.isEmpty)
                }
                if !savedNote.isEmpty { Label(savedNote, systemImage: "checkmark.circle.fill").font(BLFont.body(12, .bold)).foregroundColor(BLTheme.green) }
                if results.isEmpty {
                    Text(model.leads.isEmpty ? "No saved CRM leads yet — build a list from the database tab and save the results, or add leads from the Property Index / Lot-Flip Scout." : "No leads match these filters. Loosen them or clear.")
                        .font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub)
                } else {
                    ForEach(results.prefix(20)) { l in LeadRow(lead: l) }
                    if results.count > 20 { Text("+ \(results.count - 20) more — export the CSV for the full list.").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub) }
                }
            }

            // Saved smart lists + LIST AUTOMATION + STACKING
            Panel(title: "Saved smart lists", icon: "square.stack.3d.up.fill") {
                if model.smartLists.isEmpty {
                    Text("Save a filter above as a smart list. Lists auto-maintain: re-sync to ADD newly-qualifying leads and REMOVE leads that no longer match (cured foreclosures, sold homes). Stack lists to surface owners on multiple distressed lists.")
                        .font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                } else {
                    // LIST AUTOMATION — pending add/remove changes since last sync.
                    let changes = model.syncResults()
                    if !changes.isEmpty {
                        let added = changes.reduce(0) { $0 + $1.added.count }, removed = changes.reduce(0) { $0 + $1.removed.count }
                        HStack(spacing: 10) {
                            Image(systemName: "arrow.triangle.2.circlepath").font(.blSystem(size: 12, weight: .bold)).foregroundColor(BLTheme.gold)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("List automation: \(added) to add, \(removed) to remove").font(BLFont.body(12.5, .bold)).foregroundColor(BLTheme.text)
                                Text("Removed = leads that no longer qualify (cured / sold / disqualified). They stay in your CRM — they just leave the list.").font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub)
                            }
                            Spacer()
                            GoldButton(label: "Sync now", icon: "arrow.triangle.2.circlepath") { withAnimation { _ = model.syncLists() } }
                        }.padding(11).background(BLTheme.gold.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
                    }
                    ForEach(model.smartLists) { s in
                        let sync = ListEngine.sync(s, against: model.leads)
                        HStack(spacing: 10) {
                            IconBadge(system: s.autoMaintain ? "arrow.triangle.2.circlepath.circle.fill" : "line.3.horizontal.decrease.circle.fill", size: 30, active: sync.hasChanges)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.name.isEmpty ? "Untitled list" : s.name).font(BLFont.body(13.5, .bold)).foregroundColor(BLTheme.text)
                                HStack(spacing: 6) {
                                    Text("\(s.filter.activeCount) filters · \(ListEngine.apply(s.filter, to: model.leads).count) leads").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
                                    if sync.added.count > 0 { Text("+\(sync.added.count)").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.green) }
                                    if sync.removed.count > 0 { Text("−\(sync.removed.count)").font(BLFont.mono(9.5, .bold)).foregroundColor(BL.danger) }
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(get: { s.autoMaintain }, set: { v in var x = s; x.autoMaintain = v; model.upsert(x) })).labelsHidden().toggleStyle(.switch).tint(BLTheme.gold).help("Auto-maintain (bidirectional add/remove)")
                            GhostButton(label: "Load", icon: "arrow.down.circle", tint: BLTheme.gold) { withAnimation { filter = s.filter } }
                            GhostButton(label: "Delete", icon: "trash", tint: BL.danger) { pendingDelete = s }
                        }.padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(sync.hasChanges ? BLTheme.gold.opacity(0.3) : BLTheme.stroke, lineWidth: 1))
                    }
                    Divider().overlay(BLTheme.stroke)
                    HStack(spacing: 10) {
                        Text("STACK: owners on").font(BLFont.mono(10, .bold)).foregroundColor(BLTheme.sub)
                        Stepper(value: $stackMin, in: 2...max(2, model.smartLists.count)) { Text("\(stackMin)+").font(BLFont.mono(13, .bold)).foregroundColor(BLTheme.gold) }.labelsHidden().fixedSize()
                        Text("lists").font(BLFont.mono(10, .bold)).foregroundColor(BLTheme.sub)
                        GhostButton(label: showStack ? "Hide" : "Show stacked (\(stacked.count))", icon: "square.3.layers.3d", tint: BLTheme.gold) { withAnimation { showStack.toggle() } }.disabled(model.smartLists.count < 2)
                        Spacer()
                        if showStack, !stacked.isEmpty { GhostButton(label: "Export", icon: "square.and.arrow.up", tint: BLTheme.gold) { exportCSV(stacked.map { $0.0 }) } }
                    }
                    if showStack {
                        if stacked.isEmpty { Text("No owners appear on \(stackMin)+ lists yet.").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub) }
                        else { ForEach(stacked.prefix(20), id: \.0.id) { l, n in
                            HStack {
                                Text("\(n)×").font(BLFont.mono(11, .bold)).foregroundColor(BLTheme.ink).padding(.vertical, 2).padding(.horizontal, 7).background(BLTheme.goldGrad).clipShape(Capsule())
                                LeadRow(lead: l)
                            }
                        } }
                    }
                }
            }
        }.blScreenPadding(28) }
        .confirmationDialog("Delete this smart list?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let s = pendingDelete { model.deleteList(s) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes it — there is no undo.") }
    }

    // MARK: helpers
    @ViewBuilder private func chipRow(_ title: String, _ items: [(String, Bool)], _ tap: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            FlowLayout(spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    Button { tap(i) } label: {
                        Text(item.0).font(BLFont.body(11.5, .semibold)).foregroundColor(item.1 ? BLTheme.ink : BLTheme.sub)
                            .padding(.vertical, 5).padding(.horizontal, 11)
                            .background(item.1 ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(Capsule())
                            .overlay(Capsule().stroke(item.1 ? Color.clear : BLTheme.stroke, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
    @ViewBuilder private func toggleChip(_ label: String, _ on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 5) { Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.blSystem(size: 10, weight: .bold)); Text(label).font(BLFont.body(11.5, .semibold)) }
                .foregroundColor(on ? BLTheme.ink : BLTheme.sub).padding(.vertical, 6).padding(.horizontal, 11)
                .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(Capsule()).overlay(Capsule().stroke(on ? Color.clear : BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }
    // tri-state chip: nil (any) → true (has) → false (lacks) → nil
    @ViewBuilder private func triChip(_ label: String, _ value: Bool?, _ set: @escaping (Bool?) -> Void) -> some View {
        let state = value == nil ? "any" : (value! ? "has" : "no")
        let tint: Color = value == nil ? BLTheme.sub : (value! ? BLTheme.green : BL.danger)
        Button { set(value == nil ? true : (value! ? false : nil)) } label: {
            HStack(spacing: 5) { Text(label).font(BLFont.body(11.5, .semibold)); Text(state).font(BLFont.mono(9, .bold)).foregroundColor(tint) }
                .foregroundColor(value == nil ? BLTheme.sub : BLTheme.text).padding(.vertical, 6).padding(.horizontal, 11)
                .background(BLTheme.bg2).clipShape(Capsule()).overlay(Capsule().stroke(value == nil ? BLTheme.stroke : tint.opacity(0.5), lineWidth: 1))
        }.buttonStyle(.plain)
    }
    @ViewBuilder private func optIntField(_ title: String, get: Int?, set: @escaping (Int?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            TextField("any", text: Binding(get: { get.map(String.init) ?? "" }, set: { set(Int($0.filter(\.isNumber))) }))
                .textFieldStyle(.plain).font(.blSystem(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(.vertical, 11).padding(.horizontal, 13).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func saveList() {
        let name = listName.trimmingCharacters(in: .whitespaces)
        // Capture initial membership so list automation has a diff anchor from the start.
        let list = ListEngine.applied(SmartList(name: name.isEmpty ? "List \(model.smartLists.count + 1)" : name, filter: filter), against: model.leads)
        model.upsert(list)
        savedNote = "Saved \"\(name.isEmpty ? "List" : name)\" (\(results.count) leads · auto-maintained)."; listName = ""
    }
    private func exportCSV(_ leads: [Lead]) {
        _ = exportTextFile(suggestedName: "leads-\(Int(Date().timeIntervalSince1970)).csv",
                           contents: ListEngine.csv(leads), type: .commaSeparatedText)
    }
}

// MARK: ============================== COMPLIANCE ==============================
// MARK: - Compliance-tester view-model (pure, UI-free) — the honesty rules the calling-window
// checker renders, extracted so they're ASSERTED not eyeballed (mirrors RoutePresenter /
// DealPresenter / OutreachPreviewPresenter — beef550, 2b3b0ec, 458716e). The verdict is the SAME
// ComplianceEngine gate a real send routes through, so the tester can never show a friendlier
// answer than the send path:
//   • A cold TEXT with no prior-express-WRITTEN consent is BLOCKED (TCPA) — never "OK to contact".
//   • Consent NEVER beats suppression: a number on the buyer's Do-Not-Contact list is a hard block
//     even with written consent on file.
//   • Quiet-hours are honored in the RECIPIENT's local time — an out-of-window call/text is blocked.
enum CompliancePresenter {
    struct Verdict: Hashable {
        var allowed: Bool
        var headline: String            // the shipped OK/Do-NOT headline — derived from `allowed`, never hand-set
        var reasons: [String]           // the engine's OWN why-blocked lines (empty when allowed)
        var warnings: [String]          // allowed-but-unverifiable notes (e.g. unknown time zone)
        var localTime: String?          // recipient's inferred local time, when known
    }
    static func verdict(channel: ContactChannel, phone: String, email: String,
                        suppression: Suppression, consent: ContactConsent = .none,
                        now: Date = Date()) -> Verdict {
        let c = ComplianceEngine.check(channel: channel, phone: phone, email: email,
                                       suppression: suppression, consent: consent, now: now)
        return Verdict(allowed: c.allowed,
                       headline: c.allowed ? "OK to contact now" : "Do NOT contact now",
                       reasons: c.reasons, warnings: c.warnings, localTime: c.recipientLocalTime)
    }
}

struct ComplianceScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var addPhone = ""
    @State private var addEmail = ""
    @State private var testPhone = ""
    @State private var testChannel: ContactChannel = .call
    @State private var verdict: CompliancePresenter.Verdict?

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Compliance", subtitle: "TCPA calling windows + your Do-Not-Contact list — the legal safety layer before any call or text")

            Panel(title: "Calling-window checker", icon: "clock.badge.checkmark.fill", glow: true) {
                Text("Federal TCPA bars calls/texts before 8am or after 9pm in the RECIPIENT's local time. Enter a number — the window is checked against the time zone inferred from its area code.")
                    .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Field(title: "Recipient phone", text: $testPhone, prompt: "Recipient phone number")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CHANNEL").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                        Picker("", selection: $testChannel) { ForEach(ContactChannel.allCases) { Text($0.label).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                    }
                }
                GoldButton(label: "Check now", icon: "checkmark.shield") {
                    verdict = CompliancePresenter.verdict(channel: testChannel, phone: testPhone, email: "", suppression: model.suppression)
                }.disabled(testPhone.trimmingCharacters(in: .whitespaces).isEmpty)
                if let v = verdict {
                    HStack(spacing: 8) {
                        Image(systemName: v.allowed ? "checkmark.seal.fill" : "exclamationmark.octagon.fill").foregroundColor(v.allowed ? BLTheme.green : BL.danger)
                        Text(v.headline).font(BLFont.body(14, .bold)).foregroundColor(v.allowed ? BLTheme.green : BL.danger)
                        if let t = v.localTime { Text("· recipient local \(t)").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub) }
                    }
                    ForEach(v.reasons, id: \.self) { Label($0, systemImage: "xmark.circle").font(BLFont.body(11.5, .medium)).foregroundColor(BL.danger) }
                    ForEach(v.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(BLFont.body(11.5, .medium)).foregroundColor(.orange) }
                    if !v.allowed, let m = ComplianceEngine.minutesUntilOpen(phone: testPhone), m > 0 {
                        Text("Next legal window opens in ~\(m/60)h \(m%60)m.").font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.gold)
                    }
                }
                Text("Honest scope: this checks the statutory time window + YOUR suppression list. It does not scrub the federal National DNC Registry (that needs a paid SAN subscription) — so verify DNC separately for cold outreach.")
                    .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }

            Panel(title: "Do-Not-Contact list", icon: "hand.raised.fill") {
                Text("Anyone who says STOP / asks not to be contacted goes here — a hard block before any call, text, or blast. Add from a lead's detail, or directly:")
                    .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("Phone to suppress", text: $addPhone).textFieldStyle(.plain).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    GhostButton(label: "Block phone", icon: "phone.down.fill", tint: BL.danger) { model.suppress(phone: addPhone); addPhone = "" }
                }
                HStack(spacing: 8) {
                    TextField("Email to suppress", text: $addEmail).textFieldStyle(.plain).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    GhostButton(label: "Block email", icon: "envelope.badge.shield.half.filled", tint: BL.danger) { model.suppress(email: addEmail); addEmail = "" }
                }
                let phones = model.suppression.phones.sorted(), emails = model.suppression.emails.sorted()
                if phones.isEmpty && emails.isEmpty {
                    Text("Empty — no suppressed contacts yet.").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
                } else {
                    if !phones.isEmpty { suppressRow("PHONES (\(phones.count))", phones) { model.unsuppress(phone: $0) } }
                    if !emails.isEmpty { suppressRow("EMAILS (\(emails.count))", emails) { model.unsuppress(email: $0) } }
                }
            }
        }.blScreenPadding(28) }
    }
    @ViewBuilder private func suppressRow(_ title: String, _ items: [String], _ remove: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
            FlowLayout(spacing: 7) {
                ForEach(items, id: \.self) { item in
                    HStack(spacing: 5) {
                        Text(item).font(BLFont.mono(11, .semibold)).foregroundColor(BLTheme.text)
                        Button { remove(item) } label: { Image(systemName: "xmark").font(.blSystem(size: 8, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                    }.padding(.vertical, 5).padding(.horizontal, 10).background(BL.danger.opacity(0.12)).clipShape(Capsule()).overlay(Capsule().stroke(BL.danger.opacity(0.3), lineWidth: 1))
                }
            }
        }
    }
}

// MARK: ============================== DEAL ACCOUNTING ==============================
struct AccountingScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var addChannel: MarketingChannel = .directMail
    @State private var addCampaign = ""
    @State private var addAmount = ""
    let cols = [GridItem(.adaptive(minimum: BLScale.cardMin(240, spacing: 16)), spacing: 16)]

    private var stats: [ChannelStats] { DealAccounting.channelStats(spend: model.spend, leads: model.leads, deals: model.deals) }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            SectionHeader(title: "Deal Accounting", subtitle: "Track marketing spend by channel and see your real cost-per-lead, cost-per-deal, and ROI")

            LazyVGrid(columns: cols, spacing: 16) {
                MetricCard(label: "Total spend", value: REMath.money(DealAccounting.totalSpend(model.spend)), icon: "creditcard.fill", accent: .orange)
                MetricCard(label: "Blended cost / lead", value: REMath.money(DealAccounting.blendedCPL(spend: model.spend, leads: model.leads)), icon: "person.crop.circle.badge.plus", accent: BLTheme.gold)
                MetricCard(label: "Leads", value: "\(model.leads.count)", icon: "person.3.fill", accent: BLTheme.gold)
                MetricCard(label: "Won deals", value: "\(model.wonCount)", icon: "checkmark.seal.fill", accent: BLTheme.green, hero: true)
            }

            Panel(title: "Log marketing spend", icon: "plus.circle.fill", glow: true) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("CHANNEL").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                        Picker("", selection: $addChannel) { ForEach(MarketingChannel.allCases) { Label($0.label, systemImage: $0.icon).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Field(title: "Campaign", text: $addCampaign, prompt: "Probate postcards — May")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("AMOUNT $").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                        TextField("1000", text: $addAmount).textFieldStyle(.plain).font(.blSystem(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                            .padding(.vertical, 11).padding(.horizontal, 13).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                    }.frame(width: 130)
                }
                GoldButton(label: "Add spend", icon: "plus") {
                    let amt = Double(addAmount.filter { "0123456789.".contains($0) }) ?? 0
                    guard amt > 0 else { return }
                    model.upsert(MarketingSpend(channel: addChannel, campaign: addCampaign, amount: amt))
                    addCampaign = ""; addAmount = ""
                }
            }

            Panel(title: "Channel performance", icon: "chart.bar.xaxis", glow: !stats.isEmpty) {
                if stats.isEmpty {
                    EmptyState(icon: "chart.bar.doc.horizontal", title: "No spend logged yet", hint: "Log a marketing campaign above. Cost-per-lead, cost-per-deal and ROI appear here, attributed by lead source.").padding(.vertical, 8)
                } else {
                    // header
                    HStack { Text("CHANNEL").frame(maxWidth: .infinity, alignment: .leading); Text("SPEND").frame(width: 80, alignment: .trailing); Text("CPL").frame(width: 70, alignment: .trailing); Text("CPD").frame(width: 80, alignment: .trailing); Text("ROI").frame(width: 80, alignment: .trailing) }
                        .font(BLFont.mono(8.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                    ForEach(stats, id: \.channel) { s in
                        HStack {
                            HStack(spacing: 8) { Image(systemName: s.channel.icon).font(.blSystem(size: 11, weight: .bold)).foregroundColor(BLTheme.gold); Text(s.channel.label).font(BLFont.body(12.5, .semibold)).foregroundColor(BLTheme.text) }.frame(maxWidth: .infinity, alignment: .leading)
                            Text(REMath.money(s.spend)).font(BLFont.body(12, .bold)).foregroundColor(BLTheme.text).frame(width: 80, alignment: .trailing)
                            Text(s.leads > 0 ? REMath.money(s.costPerLead) : "—").font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub).frame(width: 70, alignment: .trailing)
                            Text(s.deals > 0 ? REMath.money(s.costPerDeal) : "—").font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub).frame(width: 80, alignment: .trailing)
                            Text(s.spend > 0 && s.deals > 0 ? REMath.pct(s.roi) : "—").font(BLFont.body(12, .bold)).foregroundColor(s.roi >= 0 ? BLTheme.green : BL.danger).frame(width: 80, alignment: .trailing)
                        }
                        .padding(.vertical, 8).padding(.horizontal, 10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    Text("CPL = spend ÷ leads from that source. CPD/ROI use WON deals only (realized, never projected). Leads attribute to a channel by source; refine by logging spend per real campaign.")
                        .font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !model.spend.isEmpty {
                Panel(title: "Spend log", icon: "list.bullet.rectangle") {
                    ForEach(model.spend) { s in
                        HStack(spacing: 10) {
                            IconBadge(system: s.channel.icon, size: 30, active: false)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.campaign.isEmpty ? s.channel.label : s.campaign).font(BLFont.body(13, .bold)).foregroundColor(BLTheme.text)
                                Text("\(s.channel.label) · \(s.date.formatted(date: .abbreviated, time: .omitted))").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
                            }
                            Spacer()
                            Text(REMath.money(s.amount)).font(BLFont.body(13, .heavy)).foregroundColor(.orange)
                            Button { model.deleteSpend(s) } label: { Image(systemName: "trash").font(.blSystem(size: 11)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                        }.padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                    }
                }
            }
        }.blScreenPadding(28) }
    }
}
#endif // circuit-convert
