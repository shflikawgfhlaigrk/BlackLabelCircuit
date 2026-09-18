#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — CRM PIPELINE (Kanban board) + LEAD DETAIL (skip-trace, tasks,
// promote-to-deal). Drag a lead card between stages; everything persists. Real data only.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct PipelineScreen: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var jump = SearchJump.shared
    @State private var detail: Lead?
    @State private var showDead = false
    private var lanes: [LeadStatus] { PipelineBoard.lanes(showDead: showDead) }
    var body: some View {
        // Bucket leads by status in ONE pass (was one full O(leads) filter per Kanban lane, re-run
        // every render — a cliff on a dense pipeline). Active count comes from the same buckets.
        let byStage = Dictionary(grouping: model.leads, by: { $0.status })
        let activeCount = PipelineBoard.activeCount(model.leads)
        return VStack(alignment: .leading, spacing: 0) {
            // On a phone the title subtitle and the switch fought over the same row and collided;
            // the compact form puts the control on its own line under the header.
            AdaptiveStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Pipeline", subtitle: "Drag leads across stages — \(activeCount) active")
                    Spacer(minLength: 8)
                    if !BLScale.isCompact {
                        Toggle(isOn: $showDead) { Text("Show dead").font(BLFont.body(12, .semibold)) }.toggleStyle(.switch).tint(BLTheme.gold)
                    }
                }
                if BLScale.isCompact {
                    Toggle(isOn: $showDead) { Text("Show dead").font(BLFont.body(12, .semibold)) }
                        .toggleStyle(.switch).tint(BLTheme.gold).fixedSize()
                }
            }.blScreenPadding(28)
            if model.leads.isEmpty {
                Spacer(); EmptyState(icon: "rectangle.split.3x1", title: "No leads to work", hint: "Build a list from the property database and save leads, then drag them across the pipeline here."); Spacer()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(lanes) { stage in KanbanColumn(stage: stage, leads: byStage[stage] ?? [], detail: { detail = $0 }) }
                    }.padding(.horizontal, BLScale.gutter(28)).padding(.bottom, 28)
                }
            }
        }
        .sheet(item: $detail) { l in LeadDetail(lead: l).environmentObject(model).sheetCloseBar() }
        // Global-search deep link: a lead hit opens that lead's detail, not just the board.
        .onAppear(perform: consumeSearchJump)
        .onChangeCompat(of: jump.lead) { _ in consumeSearchJump() }
    }
    private func consumeSearchJump() {
        guard let id = jump.lead else { return }
        jump.lead = nil
        if let l = model.leads.first(where: { $0.id == id }) { detail = l }
    }
}

struct KanbanColumn: View {
    @EnvironmentObject var model: AppModel
    let stage: LeadStatus
    let leads: [Lead]
    let detail: (Lead) -> Void
    @State private var targeted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(stage.tint).frame(width: 8, height: 8).shadow(color: stage.tint.opacity(0.7), radius: 3)
                Text(stage.label).font(.blSystem(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("\(leads.count)").font(BLFont.mono(10, .bold)).foregroundColor(BLTheme.sub).padding(.vertical, 1).padding(.horizontal, 6).background(BLTheme.bg2).clipShape(Capsule())
                Spacer()
            }
            // Each lane scrolls vertically on its own: a stage holding more cards than the window
            // is tall must keep every card reachable (open, drag) — a plain VStack clipped them.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(leads) { l in
                        KanbanCard(lead: l) { detail(l) }
                            .onDrag { NSItemProvider(object: l.id.uuidString as NSString) }
                    }
                    if leads.isEmpty {
                        Text("Drop here").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub.opacity(0.6))
                            .frame(maxWidth: .infinity, minHeight: 60).background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4])).foregroundColor(BLTheme.stroke))
                    }
                }
            }
        }
        .padding(12).frame(width: BLScale.columnWidth(240), alignment: .top)
        .background(targeted ? stage.tint.opacity(0.08) : BL.bg1).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(targeted ? stage.tint.opacity(0.6) : BLTheme.stroke, lineWidth: 1))
        .onDrop(of: [UTType.text], isTargeted: $targeted) { providers in
            providers.first?.loadObject(ofClass: NSString.self) { item, _ in
                guard let s = item as? String, let id = UUID(uuidString: s),
                      let lead = model.leads.first(where: { $0.id == id }) else { return }
                DispatchQueue.main.async { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.setLeadStatus(lead, stage) } }
            }
            return true
        }
    }
}

struct KanbanCard: View {
    let lead: Lead; let tap: () -> Void
    @State private var hover = false
    // RE-22: at-a-glance encumbrance chip on the CARD FACE — reads the lead's CACHED title chain with
    // ZERO network on render (a changed/unresolved parcel correctly reads "—", never a stale/fabricated
    // count). Warning tint only for a real, pulled, non-zero encumbrance count.
    @ViewBuilder private var encumbranceChip: some View {
        let state = (lead.dbState ?? DatabaseLeadImport.stateToken(in: lead.county) ?? "").uppercased()
        let cached = TitleChainEngine.cached(lead.titleChainCache, parcel: lead.parcel, state: state)
        let warn = TitleChainPresenter.cardFaceIsWarning(cached: cached)
        HStack(spacing: 3) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "doc.text.below.ecg")
                .font(.blSystem(size: 8, weight: .bold))
            Text(TitleChainPresenter.cardFaceBadge(cached: cached)).font(BLFont.mono(9, .bold))
        }
        .foregroundColor(warn ? BL.danger : BLTheme.sub)
        .padding(.vertical, 1).padding(.horizontal, 5)
        .background((warn ? BL.danger : BLTheme.sub).opacity(0.12)).clipShape(Capsule())
    }
    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) { Image(systemName: lead.source.icon).font(.blSystem(size: 10, weight: .bold)).foregroundColor(BLTheme.gold)
                    Text(lead.name).font(.blSystem(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1) }
                if !lead.propertyAddress.isEmpty { Text(lead.propertyAddress).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).lineLimit(1) }
                HStack(spacing: 6) {
                    if lead.assessedValue > 0 { Text(REMath.money(Double(lead.assessedValue))).font(BLFont.body(10.5, .bold)).foregroundColor(BLTheme.green) }
                    if !lead.county.isEmpty { Text(lead.county).font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub) }
                    Spacer()
                    encumbranceChip
                    if lead.openTasks > 0 { Image(systemName: "checklist").font(.blSystem(size: 9, weight: .bold)).foregroundColor(BLTheme.gold); Text("\(lead.openTasks)").font(BLFont.mono(9, .bold)).foregroundColor(BLTheme.gold) }
                }
            }
            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? BLTheme.panelHi : BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(hover ? BLTheme.gold.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
            .shadow(color: hover ? .black.opacity(0.3) : .clear, radius: 8, y: 3)
        }.buttonStyle(.plain).onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
    }
}

// MARK: - Per-lead call-check view-model (pure, UI-free) — the compliance status the lead-detail
// contact panel renders before a call, extracted so it's ASSERTED not eyeballed (mirrors
// RoutePresenter / DealPresenter / CompliancePresenter — beef550, 2b3b0ec). It is the SAME
// ComplianceEngine gate a real send uses, so the per-lead badge can never read friendlier than
// the send path:
//   • A number/email on the buyer's Do-Not-Contact list is a HARD block — .suppressed, never .ok,
//     regardless of the calling window.
//   • A clean number outside the recipient's 8am–9pm local window is .hold with the engine's OWN
//     reason — never "OK to call now".
//   • The label text is the engine's own line, so it can't drift from the gate.
enum PipelineCallPresenter {
    enum Kind: Hashable { case suppressed, ok, hold }
    struct CallState: Hashable {
        var kind: Kind
        var label: String
    }
    static func callCheck(phone: String, email: String, suppression: Suppression,
                          now: Date = Date()) -> CallState {
        let suppressed = (!phone.isEmpty && suppression.suppresses(phone: phone))
            || (!email.isEmpty && suppression.suppresses(email: email))
        if suppressed { return CallState(kind: .suppressed, label: "On Do-Not-Contact") }
        let c = ComplianceEngine.check(channel: .call, phone: phone, email: email, suppression: suppression, now: now)
        if c.allowed {
            let t = c.recipientLocalTime.map { " · \($0)" } ?? ""
            return CallState(kind: .ok, label: "OK to call now\(t)")
        }
        return CallState(kind: .hold, label: c.reasons.first ?? c.warnings.first ?? "Verify before calling")
    }
}

// MARK: - Lead detail: skip-trace, contact, parcel resolution, tasks, promote-to-deal
struct LeadDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var lead: Lead
    /// The lead as opened — dirty compares against the model's live copy (pickers/tasks upsert
    /// as they go), so only genuinely unsaved field/notes edits arm the close confirmation.
    private let original: Lead
    init(lead: Lead) { self.original = lead; self._lead = State(initialValue: lead) }
    private var isDirty: Bool { lead != (model.leads.first(where: { $0.id == lead.id }) ?? original) }
    @State private var resolving = false
    @State private var resolveNote = ""
    @State private var newTask = ""
    @State private var logNote = ""
    @State private var pendingKind: ActivityKind? = nil
    @State private var tracing = false
    @State private var traceNote = ""
    @State private var showSkipConfig = false
    @State private var confirmDelete = false
    @State private var showTitleChain = false   // RE-22 title/lien chain sheet
    @State private var chooser: ChooserContext? = nil   // round 21: the buyer's pick over an ambiguous match
    // RE-17: pre-charge yield, computed only from this Mac's own prior trace outcomes.
    @State private var traceYield = SkipTraceYieldStore.load()

    // RE-22: at-a-glance encumbrance badge on the lead card — reads the lead's CACHED title chain with
    // ZERO network. Honest three-state (a real count only when a chain was pulled and encumbered
    // something; otherwise "none recorded" or "not pulled" — never a fabricated lien, §5.1).
    @ViewBuilder private var encumbranceBadge: some View {
        let state = (lead.dbState ?? DatabaseLeadImport.stateToken(in: lead.county) ?? "").uppercased()
        let cached = TitleChainEngine.cached(lead.titleChainCache, parcel: lead.parcel, state: state)
        let warn = TitleChainPresenter.encumbranceIsWarning(cached: cached)
        Text(TitleChainPresenter.encumbranceBadge(cached: cached))
            .font(BLFont.mono(10, .medium))
            .foregroundColor(warn ? BL.danger : BLTheme.sub)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((warn ? BL.danger : BLTheme.sub).opacity(0.12))
            .clipShape(Capsule())
    }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconBadge(system: lead.source.icon, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lead.name).font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("\(lead.source.label)\(lead.sourceDetail.isEmpty ? "" : " · \(lead.sourceDetail)")").font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.gold)
                }
                Spacer()
                Picker("", selection: Binding(get: { lead.status }, set: { s in model.setLeadStatus(lead, s); lead.status = s })) {
                    ForEach(LeadStatus.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.menu).tint(lead.status.tint).fixedSize()
            }

            // Assignment (team / lead routing). Single-user installs see an "Add a teammate" hint.
            Panel(title: "Assignment", icon: "person.fill.badge.plus") {
                if model.team.isEmpty {
                    Label("No teammates yet — add them in Settings → Team to assign leads and auto-route new ones.", systemImage: "info.circle")
                        .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 10) {
                        Text("OWNER").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.sub).tracking(1)
                        Picker("", selection: Binding(
                            get: { lead.assignedTo },
                            set: { id in model.assign(lead, to: id); lead.assignedTo = id })) {
                            Text("Unassigned").tag(Optional<UUID>.none)
                            ForEach(model.team.filter { $0.active }) { m in Text("\(m.name) · \(m.role)").tag(Optional(m.id)) }
                        }.labelsHidden().tint(BLTheme.gold).frame(maxWidth: 280)
                        Spacer()
                        if let id = lead.assignedTo, let m = model.member(id) {
                            HStack(spacing: 6) {
                                Text(m.initials).font(BLFont.mono(10, .bold)).foregroundColor(BLTheme.ink).frame(width: 24, height: 24).background(BLTheme.goldGrad).clipShape(Circle())
                            }
                        }
                    }
                }
            }

            // Database provenance — the audit trail from CRM lead back to the public record.
            if lead.isDatabaseLead {
                Panel(title: "Public-record provenance", icon: "building.columns.fill") {
                    HStack(spacing: 14) {
                        if let origin = lead.dbOrigin.flatMap(DatabaseLeadOrigin.init(rawValue:)) {
                            miniStat("Saved from", origin.label)
                        }
                        if let cat = lead.dbCategory, !cat.isEmpty {
                            miniStat("Category", DatabaseListCriteria.humanCategory(cat))
                        }
                        if let at = lead.dbSavedAt {
                            miniStat("Saved", at.formatted(date: .abbreviated, time: .shortened))
                        }
                        if let st = lead.dbState { miniStat("State", st) }
                    }
                    if let crit = lead.dbCriteria, !crit.isEmpty {
                        Text("List criteria: \(crit)").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                    if let raw = lead.dbSourceURL, let url = URL(string: raw) {
                        GhostButton(label: "Open county source record", icon: "link", tint: BLTheme.gold) { NSWorkspace.shared.open(url) }
                    }
                }
            }

            // Contact / skip-trace block
            Panel(title: "Contact & skip-trace", icon: "person.crop.circle.badge.questionmark") {
                if lead.isDatabaseLead && lead.phone.isEmpty && lead.email.isEmpty {
                    Label("Not skip-traced yet — public records carry no phone/email, and none is ever invented. Add verified contact info here when you trace the owner.",
                          systemImage: "person.crop.circle.badge.questionmark")
                        .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 12) { Field(title: "Phone", text: $lead.phone, prompt: "Verified phone"); Field(title: "Email", text: $lead.email, prompt: "Verified email") }
                // Compliance status: live calling-window verdict + one-click STOP / opt-out.
                if !lead.phone.isEmpty || !lead.email.isEmpty {
                    let cs = PipelineCallPresenter.callCheck(phone: lead.phone, email: lead.email, suppression: model.suppression)
                    let tint: Color = cs.kind == .suppressed ? BL.danger : (cs.kind == .ok ? BLTheme.green : .orange)
                    let icon = cs.kind == .suppressed ? "hand.raised.fill" : (cs.kind == .ok ? "checkmark.shield.fill" : "clock.badge.exclamationmark.fill")
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .foregroundColor(tint).font(.blSystem(size: 12, weight: .bold))
                        Text(cs.label)
                            .font(BLFont.body(11, .semibold)).foregroundColor(tint).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if cs.kind == .suppressed {
                            GhostButton(label: "Unblock", icon: "arrow.uturn.left", tint: BLTheme.gold) { model.unsuppress(phone: lead.phone, email: lead.email) }
                        } else {
                            GhostButton(label: "STOP / opt-out", icon: "hand.raised", tint: BL.danger) { model.suppress(phone: lead.phone, email: lead.email) }
                        }
                    }
                }
                Field(title: "Owner (recorded)", text: $lead.ownerName, prompt: "from parcel record")
                Field(title: "Property (situs)", text: $lead.propertyAddress, prompt: "Situs from parcel record")
                Field(title: "Owner mailing (direct-mail target)", text: $lead.mailingAddress, prompt: "where tax bills go")

                // BRING-YOUR-OWN skip-trace: phone/email via the buyer's OWN provider key, run
                // on-device, appended to THIS lead locally. No key connected → honest CTA; PII
                // never leaves for our index (see SkipTraceProvider).
                let hasAddr = !lead.mailingAddress.trimmingCharacters(in: .whitespaces).isEmpty || !lead.propertyAddress.trimmingCharacters(in: .whitespaces).isEmpty
                let connectedProviders = SkipTraceKeychain.connectedVendors()
                let hasProvider = !connectedProviders.isEmpty
                // RE-17 — TRANSPARENT YIELD BEFORE CHARGING. A trace bills the buyer's provider key, so
                // show what THEIR OWN past traces on this Mac actually yielded first: right-party
                // hit-rate + how many returned phones their DNC list will scrub. No history → honest
                // "no trace history yet on this Mac" (never a fabricated percentage).
                if hasProvider {
                    preChargeYield(hasAddr: hasAddr)
                }
                HStack(spacing: 10) {
                    if hasProvider {
                        GhostButton(label: tracing ? "Tracing…" : (connectedProviders.count > 1 ? "Trace phone/email (waterfall)" : "Trace phone/email (your provider)"), icon: tracing ? "hourglass" : "person.crop.circle.badge.checkmark", tint: BLTheme.gold) { traceOwner() }
                            .disabled(tracing || !hasAddr)
                    } else {
                        GhostButton(label: "Connect a skip-trace provider", icon: "key.fill", tint: BLTheme.gold) { showSkipConfig = true }
                    }
                    if !traceNote.isEmpty { Text(traceNote).font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.green).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                    Spacer()
                }
                if hasProvider && !hasAddr {
                    Text("Add a property or mailing address first — the trace needs an address to look up.").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
                Text("Runs on your machine as a WATERFALL under your own provider keys (\(connectedProviders.isEmpty ? "BatchData → RocketSkip" : connectedProviders.map(\.label).joined(separator: " → "))) — it tries each in order, stops at the first confirmed contact, and caches it locally so a re-trace is free. Phone/email is stored on this lead locally; it never goes to our servers. No key = nothing invented.")
                    .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

                if !lead.parcel.isEmpty || lead.assessedValue > 0 {
                    HStack(spacing: 12) {
                        if !lead.parcel.isEmpty { miniStat("Parcel", lead.parcel) }
                        if lead.assessedValue > 0 { miniStat("Assessed", REMath.money(Double(lead.assessedValue))) }
                        if !lead.ownershipConfidence.isEmpty { miniStat("Ownership", lead.ownershipConfidence.capitalized) }
                    }
                }
                if ParcelRegistry.covers(lead.county) {
                    HStack(spacing: 10) {
                        GhostButton(label: resolving ? "Resolving…" : "Resolve parcel (\(lead.county.capitalized))", icon: resolving ? "hourglass" : "scope", tint: BLTheme.gold) { resolve() }.disabled(resolving)
                        if !resolveNote.isEmpty { Text(resolveNote).font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.green) }
                        Spacer()
                    }
                    Text("Free county GIS — fills situs, value, owner + mailing. Gated honestly if the owner isn't found; never fabricated.").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                } else if !lead.county.isEmpty {
                    Label("No open parcel source for \(lead.county.capitalized) County yet — add it in the engine to enable resolution. Nothing is invented.", systemImage: "info.circle").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
            }

            // Tasks / follow-up
            Panel(title: "Follow-up tasks", icon: "checklist") {
                HStack(spacing: 8) {
                    TextField("Add a task (call, mail, drive-by)…", text: $newTask).textFieldStyle(.plain).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                        .onSubmit(addTask)
                    GhostButton(label: "Add", icon: "plus", tint: BLTheme.gold, action: addTask)
                }
                if lead.tasks.isEmpty { Text("No tasks yet. Add your first follow-up.").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub) }
                ForEach(lead.tasks) { t in
                    HStack(spacing: 10) {
                        Button { toggle(t) } label: { Image(systemName: t.done ? "checkmark.circle.fill" : "circle").foregroundColor(t.done ? BLTheme.green : BLTheme.sub) }.buttonStyle(.plain)
                        Text(t.text).font(BLFont.body(12.5, .medium)).foregroundColor(t.done ? BLTheme.sub : BLTheme.text).strikethrough(t.done)
                        Spacer()
                        Button { lead.tasks.removeAll { $0.id == t.id }; model.upsert(lead) } label: { Image(systemName: "xmark").font(.blSystem(size: 9, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                    }.padding(.vertical, 3)
                }
            }

            // Quick-log row: record a real contact attempt as a timeline event (no fabrication —
            // the user is recording an action they actually took).
            Panel(title: "Log activity", icon: "plus.circle") {
                HStack(spacing: 8) {
                    quickLog("Call", "phone.fill", .call)
                    quickLog("Text", "message.fill", .text)
                    quickLog("Email", "envelope.fill", .email)
                    quickLog("Note", "text.bubble.fill", .note)
                    Spacer()
                }
                if pendingKind != nil {
                    HStack(spacing: 8) {
                        TextField(pendingKind == .note ? "Write the note…" : "Add a detail (optional)…", text: $logNote).textFieldStyle(.plain).font(BLFont.body(12.5, .medium)).foregroundColor(BLTheme.text)
                            .padding(.vertical, 8).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9)).overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                            .onSubmit { commitLog() }
                        GhostButton(label: "Save", icon: "checkmark", tint: BLTheme.gold) { commitLog() }
                    }
                }
            }

            // Unified activity timeline (status changes, calls/texts/mail, tasks, parcel/skip-trace).
            Panel(title: "Activity timeline", icon: "clock.arrow.circlepath") {
                let events = model.timeline(for: lead)
                if events.isEmpty {
                    Text("No activity yet. Logging a call, moving a stage, or adding a task all show up here.").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
                } else {
                    ForEach(Array(events.prefix(40))) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: e.kind.icon).font(.blSystem(size: 11, weight: .bold)).foregroundColor(e.kind.tint).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(e.detail).font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.text).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 5) {
                                    Text(relTime(e.at)).font(BLFont.mono(9.5, .medium)).foregroundColor(BLTheme.sub)
                                    if !e.actor.isEmpty { Text("· \(e.actor)").font(BLFont.mono(9.5, .medium)).foregroundColor(BLTheme.gold) }
                                }
                            }
                            Spacer()
                        }.padding(.vertical, 3)
                    }
                    if events.count > 40 { Text("+\(events.count - 40) earlier events").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub) }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("NOTES").font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $lead.notes).font(.blSystem(size: 13, design: .rounded)).foregroundColor(BLTheme.text).scrollContentBackground(.hidden).padding(8).frame(height: 60).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 10) {
                if lead.routableAddress != nil || lead.assessedValue > 0 {
                    GhostButton(label: "Promote to deal", icon: "house.fill", tint: BLTheme.gold) { model.upsert(model.dealFromLead(lead)); dismiss() }
                }
                GhostButton(label: "Title & lien chain", icon: "doc.text.below.ecg", tint: BLTheme.gold) { showTitleChain = true }
                encumbranceBadge
                GhostButton(label: "Delete", icon: "trash", tint: BL.danger) { confirmDelete = true }
                Spacer()
                GoldButton(label: "Save", icon: "checkmark") { model.upsert(lead); dismiss() }
            }
            .confirmationDialog("Delete this lead?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { model.deleteLead(lead); dismiss() }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This permanently removes the lead and its whole activity timeline — there is no undo.") }
        }.blScreenPadding(26) }
        .sheetFrame(540, 700)
        .sheetEditsPending(isDirty)
        .sheet(isPresented: $showSkipConfig) { SkipTraceConfigSheet().sheetCloseBar() }
        .sheet(isPresented: $showTitleChain) { TitleChainSheet(lead: lead).environmentObject(model).sheetCloseBar() }
        .sheet(item: $chooser) { ctx in
            ParcelChooserSheet(record: ctx.record) { pick($0, of: ParcelChooserPresenter.rows(ctx.record).count) }.sheetCloseBar()
        }
    }
    /// Pre-charge yield panel (RE-17). A single-lead trace is a batch of 1; numbers come only from
    /// `traceYield` (this Mac's real prior outcomes). Honest empty state when there's no history.
    @ViewBuilder private func preChargeYield(hasAddr: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.doc.horizontal").font(.blSystem(size: 11, weight: .bold)).foregroundColor(BLTheme.gold)
                Text("BEFORE YOU CHARGE — YOUR YIELD ON THIS \(kThisDeviceWord.uppercased())").font(BLFont.mono(9, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
            }
            // Which lines render is decided by a PURE, unit-tested resolver (LeadDetailYield.preCharge):
            // an empty local history yields the honest no-history note and NO percentage line; a real
            // history yields the two projection lines derived only from the buyer's own outcomes.
            switch LeadDetailYield.preCharge(history: traceYield) {
            case .projected(let hitRate, let dnc):
                Text(hitRate).font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.text).fixedSize(horizontal: false, vertical: true)
                Text(dnc).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            case .noHistory(let note):
                Text(note).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
    }
    @ViewBuilder private func miniStat(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(l.uppercased()).font(BLFont.mono(8.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.5); Text(v).font(BLFont.body(12.5, .bold)).foregroundColor(BLTheme.text).lineLimit(1) }
            .frame(maxWidth: .infinity, alignment: .leading).padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
    }
    private func addTask() { let t = newTask.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }; lead.tasks.append(LeadTask(text: t)); newTask = ""; model.upsert(lead) }
    private func toggle(_ t: LeadTask) {
        if let i = lead.tasks.firstIndex(where: { $0.id == t.id }) {
            let isDone = !lead.tasks[i].done
            lead.tasks[i].done = isDone
            lead.tasks[i].completedAt = isDone ? Date() : nil
            model.upsert(lead)
        }
    }

    // Quick-log: one tap records a contact attempt. A Call/Text/Email logs immediately; Note opens
    // the detail field. The user is recording a real action — never a fabricated outcome.
    @ViewBuilder private func quickLog(_ label: String, _ icon: String, _ kind: ActivityKind) -> some View {
        GhostButton(label: label, icon: icon, tint: kind == .note ? BLTheme.sub : .blue) {
            if kind == .note { pendingKind = .note }                                    // reveal the detail field
            else { lead.log(kind, "\(label) logged"); model.upsert(lead); pendingKind = kind }   // log now; allow an optional detail
        }
    }
    private func commitLog() {
        let detail = logNote.trimmingCharacters(in: .whitespaces)
        let kind = pendingKind ?? .note
        if kind == .note {
            guard !detail.isEmpty else { return }
            lead.log(.note, detail)
        } else if !detail.isEmpty, let i = lead.activity.lastIndex(where: { $0.kind == kind }) {
            lead.activity[i].detail += " — \(detail)"   // attach the detail to the just-logged event
        }
        model.upsert(lead); logNote = ""; pendingKind = nil
    }
    private func relTime(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }
    private func resolve() {
        resolving = true; resolveNote = ""
        Task {
            let (updated, rec) = await ParcelEnrich.enrich(lead)
            await MainActor.run {
                resolving = false
                if rec.available, rec.address != nil {
                    var u = updated; u.log(.parcel, "Resolved parcel — \(rec.address ?? "situs")\(rec.assessedValue.map { " · \(REMath.money(Double($0)))" } ?? "")")
                    lead = u; model.upsert(u); resolveNote = "Resolved."
                }
                // ROUND 21: an ambiguous match carries the county's REAL candidate rows (round 20).
                // Offer them instead of the bare refusal — the resolver still refuses to pick, but the
                // buyer can. Checked BEFORE the generic else, which would otherwise swallow a record
                // that has something to show behind a note that says nothing can be shown.
                else if ParcelChooserPresenter.offers(rec) {
                    chooser = ChooserContext(record: rec)
                    resolveNote = ""
                }
                else { resolveNote = rec.note.isEmpty ? "Owner not found — nothing invented." : rec.note }
            }
        }
    }

    /// The buyer picked a parcel out of the county's ambiguous match. Writes the CHOSEN row's own
    /// recorded values (never a synthesized one) and logs it as the buyer's act.
    private func pick(_ c: ParcelCandidate, of count: Int) {
        var u = ParcelChooserPresenter.apply(c, to: lead)
        u.log(.parcel, ParcelChooserPresenter.pickLog(c, of: count))
        lead = u; model.upsert(u)
        resolveNote = "Parcel selected."
    }

    /// Skip-trace THIS lead via the buyer's own provider keys, on-device, as a WATERFALL (RE-15):
    /// the ordered chain of connected providers is tried until the first confirmed contact, then it
    /// STOPS (no second provider is billed). A cached result for the unchanged lead re-serves with
    /// ZERO network. Fills blank phone/email locally; honest note on empty/failed. Never fabricates.
    private func traceOwner() {
        let chain = SkipTraceKeychain.connectedVendors()
        guard !chain.isEmpty else { showSkipConfig = true; return }
        tracing = true; traceNote = ""
        let snapshot = lead
        let name = SkipTraceWaterfall.traceName(snapshot)
        let addr = SkipTraceWaterfall.traceAddress(snapshot)
        Task {
            // Cache-hit → zero network (instant + free re-trace of an unchanged lead).
            let result: SkipWaterfallResult
            if let hit = SkipTraceWaterfall.cached(snapshot.skipTraceCache, name: name, address: addr) {
                result = hit
            } else {
                result = await SkipTraceWaterfall.run(lead: snapshot, chain: chain,
                                                      keyFor: { SkipTraceKeychain.keyFor($0) })
            }
            await MainActor.run {
                tracing = false
                // RE-17: fold this REAL outcome into the local yield history so the next pre-charge
                // panel reflects the buyer's own results across the WHOLE chain. DNC-removed = returned
                // phones on their suppression list. A cached re-serve isn't a new data point.
                if !result.fromCache {
                    let dncRemoved = result.contact.phones.filter { model.suppression.suppresses(phone: $0) }.count
                    traceYield = SkipTraceYieldStore.record(SkipTraceWaterfall.outcome(result, dncRemoved: dncRemoved))
                }
                if result.isHit {
                    let u = SkipTraceWaterfall.attach(result, to: lead)
                    lead = u; model.upsert(u)
                    let via = result.winner?.label ?? "your provider"
                    traceNote = "Attached via \(via)\(result.fromCache ? " (from cache — no re-charge)" : "") — stored locally."
                } else {
                    // Cache the exhausted miss too, so a re-run is free instead of re-billing every provider.
                    var u = lead; u.skipTraceCache = SkipTraceWaterfall.cacheEntry(lead: snapshot, result: result)
                    lead = u; model.upsert(u)
                    traceNote = result.fromCache ? "No contact on file (cached — no re-charge)."
                        : "No phone/email returned across your providers — nothing invented."
                }
            }
        }
    }
}

// MARK: - Pipeline view-models (PURE — unit-tested in EngineTests → testPipelineBoardAndYield)

enum PipelineBoard {
    /// Active (non-dead) lead count shown in the header — pulled out of the view body so the number
    /// the user reads is unit-tested, not eyeballed. Equals the total minus the Dead lane.
    static func activeCount(_ leads: [Lead]) -> Int {
        leads.reduce(0) { $0 + ($1.status == .dead ? 0 : 1) }
    }
    /// The Kanban lanes rendered — every stage when "Show dead" is on, else the working board (Dead hidden).
    static func lanes(showDead: Bool) -> [LeadStatus] {
        showDead ? LeadStatus.allCases : LeadStatus.board
    }
}

enum LeadDetailYield {
    /// The pre-charge yield panel state for a SINGLE-lead trace (a batch of 1). Derived ONLY from the
    /// buyer's local skip-trace history: no history → the honest note with NO percentage line (never a
    /// fabricated rate); real history → the two transparent projection lines.
    enum PreCharge: Equatable {
        case noHistory(note: String)
        case projected(hitRate: String, dnc: String)
    }
    static func preCharge(history: SkipTraceHistory) -> PreCharge {
        guard let proj = SkipTraceYield.projection(history: history, batchSize: 1) else {
            return .noHistory(note: SkipTraceYield.noHistoryNote)
        }
        return .projected(hitRate: proj.hitRateLine, dnc: proj.dncLine)
    }
}

/// Carries an ambiguous ParcelRecord into the chooser sheet. `ParcelRecord` is a value type with no
/// identity of its own, and `.sheet(item:)` needs one.
struct ChooserContext: Identifiable {
    let id = UUID()
    let record: ParcelRecord
}

// MARK: - Parcel chooser (round 21) — the buyer's pick over an AMBIGUOUS owner match.
//
// Rounds 18–20 built the honest half of this. Round 18 established that the resolver must never PICK
// among several DISTINCT parcels matching one owner name (it was rendering an arbitrary one of many —
// live: Durham 33 candidates, Buncombe 35, Cleveland 7 whose first is a DIFFERENT MAN). Round 20
// stopped throwing away the rows it had already fetched: an ambiguous answer now carries the REAL
// candidates. But NOTHING RENDERED THEM — the knowledge reached the UI layer and stopped there, so a
// buyer still saw a bare refusal and could not act on parcels the county had already published.
//
// This presenter is the missing step, and it is deliberately the ONLY thing that changes: the
// resolver still never picks. Choosing is the BUYER'S act. It stays terminal — no index widen is
// re-opened (round 18's rule), nothing is re-queried, and every value written to the lead is the
// county's own recorded value carried verbatim off the row the buyer chose (§5.1).
enum ParcelChooserPresenter {
    /// Does this record offer a chooser? ONLY an ambiguous refusal that actually carries candidates.
    /// Two things this must never do:
    ///   • offer over a RESOLVED record — the county PROVED that parcel; letting a buyer "pick"
    ///     something else would launder a proven answer back into a guess. (A resolved record carries
    ///     no candidates by construction, so this is belt and braces — but the belt is the point: the
    ///     round-18 defect was precisely a surface treating an unproven answer as a proven one.)
    ///   • render an EMPTY chooser — a bad-name / no-source refusal has nothing to choose between, and
    ///     an empty picker reads as "this county has no such parcels" (a claim we have NOT established)
    ///     rather than "we could not ask".
    static func offers(_ rec: ParcelRecord) -> Bool {
        rec.source == ParcelLookup.ambiguousSource && !rec.candidates.isEmpty
    }

    /// The rows to render — empty unless a chooser is genuinely offered, so a surface that forgets to
    /// call `offers` still cannot draw a picker over a proven or empty answer.
    static func rows(_ rec: ParcelRecord) -> [ParcelCandidate] { offers(rec) ? rec.candidates : [] }

    // Display helpers. A nil field is a field the COUNTY DOES NOT PUBLISH (Cleveland is pid-only and
    // publishes no situs), so it renders as an explicit "not published" — never as a blank that reads
    // like an absent value, and never as a synthesized filler. A chooser must not invent the very
    // field it exists to display.
    static let unpublished = "not published by this county"
    static func ownerLabel(_ c: ParcelCandidate) -> String { nonEmpty(c.owner) ?? unpublished }
    static func addressLabel(_ c: ParcelCandidate) -> String { nonEmpty(c.address) ?? unpublished }
    static func parcelLabel(_ c: ParcelCandidate) -> String { nonEmpty(c.parcel) ?? unpublished }
    static func valueLabel(_ c: ParcelCandidate) -> String {
        guard let v = c.assessedValue, v > 0 else { return unpublished }
        return REMath.money(Double(v))
    }
    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    /// Apply the buyer's pick. Writes ONLY what the county actually published on the chosen row: a nil
    /// or blank field leaves the lead's own value untouched rather than overwriting it with a filler.
    ///
    /// `ownershipConfidence` is deliberately NOT set. The county published these parcels; it did NOT
    /// tell us which one belongs to the searched person — that is the buyer's assertion, and stamping
    /// a confidence on it would be the app claiming a match the county never made (§5.1). The pick is
    /// recorded in the activity log as the buyer's act instead.
    static func apply(_ c: ParcelCandidate, to lead: Lead) -> Lead {
        var l = lead
        if let p = nonEmpty(c.parcel) { l.parcel = p }
        if let o = nonEmpty(c.owner) { l.ownerName = o }
        if let a = nonEmpty(c.address) { l.propertyAddress = a }
        if let v = c.assessedValue, v > 0 { l.assessedValue = v }
        return l
    }

    /// The activity-log line for a pick. Names it as the BUYER's selection out of N county rows, so the
    /// timeline never reads like the app resolved something it refused to resolve.
    static func pickLog(_ c: ParcelCandidate, of count: Int) -> String {
        "Selected parcel \(parcelLabel(c)) — \(ownerLabel(c)) — chosen by you from \(count) county matches (the county did not disambiguate)"
    }

    static func headline(_ rec: ParcelRecord) -> String {
        "\(rows(rec).count) parcels match that owner name"
    }
}

// The chooser sheet. Renders `ParcelRecord.candidates` — the REAL rows the county already returned —
// so an ambiguous match becomes a pick instead of a dead end.
struct ParcelChooserSheet: View {
    @Environment(\.dismiss) var dismiss
    let record: ParcelRecord
    let onPick: (ParcelCandidate) -> Void

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconBadge(system: "square.stack.3d.up", size: 30)
                Text("Which parcel is yours?").font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
            }
            Text(ParcelChooserPresenter.headline(record))
                .font(BLFont.body(13, .bold)).foregroundColor(BLTheme.gold)
            Text("\(record.county.capitalized) County published every parcel below and did not say which one belongs to your lead — so this app will not guess one for you. Pick the parcel you recognise and its recorded details are copied to the lead exactly as the county published them. Nothing here is estimated or invented.")
                .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            ForEach(Array(ParcelChooserPresenter.rows(record).enumerated()), id: \.offset) { _, c in
                candidateRow(c)
            }

            Text("Can't tell them apart? Nothing is written until you pick. Close this and the lead is left exactly as it was.")
                .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }.blScreenPadding(26) }.sheetFrame(560, 560)
    }

    @ViewBuilder private func candidateRow(_ c: ParcelCandidate) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(ParcelChooserPresenter.ownerLabel(c))
                .font(BLFont.body(13.5, .bold)).foregroundColor(BLTheme.text).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                field("Parcel", ParcelChooserPresenter.parcelLabel(c))
                field("Assessed", ParcelChooserPresenter.valueLabel(c))
            }
            field("Address", ParcelChooserPresenter.addressLabel(c))
            HStack {
                Spacer()
                GoldButton(label: "This one", icon: "checkmark") { onPick(c); dismiss() }
            }
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func field(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l.uppercased()).font(BLFont.mono(8.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
            Text(v).font(BLFont.body(12, .semibold))
                .foregroundColor(v == ParcelChooserPresenter.unpublished ? BLTheme.sub.opacity(0.75) : BLTheme.text)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// Config sheet for the buyer's skip-trace provider key (secret stored only in the Keychain).
struct SkipTraceConfigSheet: View {
    @Environment(\.dismiss) var dismiss
    @State private var vendor: SkipTraceVendor = .batchData
    @State private var apiKey = ""
    @State private var hasKey = SkipTraceKeychain.hasKey(vendor: .batchData)
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { IconBadge(system: "person.crop.circle.badge.checkmark", size: 30); Text("Skip-trace providers").font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text); Spacer() }
            Text("Connect YOUR OWN skip-trace providers. Traces run on this \(kThisDeviceWord) under your keys and bill to your account; the phone/email is attached to the lead locally and never sent to Black Label. We never fabricate contact info. Connect two or more and they run as a WATERFALL — each is tried in order until one returns a contact, then it stops.")
                .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            Picker("Provider", selection: $vendor) { ForEach(SkipTraceVendor.allCases) { Text($0.label + (SkipTraceKeychain.hasKey(vendor: $0) ? " ✓" : "")).tag($0) } }
                .pickerStyle(.menu).tint(BLTheme.gold)
                .onChangeCompat(of: vendor) { _ in hasKey = SkipTraceKeychain.hasKey(vendor: vendor); apiKey = "" }
            VStack(alignment: .leading, spacing: 5) {
                Text("API KEY").font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                SecureField(hasKey ? "•••••••• (stored in Keychain)" : "Paste your provider API key", text: $apiKey)
                    .textFieldStyle(.plain).font(.blSystem(size: 14, design: .rounded)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 11).padding(.horizontal, 13).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                Text(vendor.signupHint).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                Text("Stored only in this \(kThisDeviceWord)'s Keychain — never bundled, logged, or sent anywhere but your provider's API.").font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub)
            }
            HStack {
                if hasKey { GhostButton(label: "Remove \(vendor.label) key", icon: "trash", tint: BL.danger) { SkipTraceKeychain.clear(vendor: vendor); hasKey = false; apiKey = "" } }
                Spacer()
                GhostButton(label: "Done", tint: BLTheme.sub) { dismiss() }
                GoldButton(label: hasKey ? "Update" : "Save", icon: "checkmark") {
                    let t = apiKey.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty { SkipTraceKeychain.set(t, vendor: vendor); hasKey = true }
                    // Stay open so the buyer can add the next provider's key for the waterfall.
                    apiKey = ""
                }
            }
        }.blScreenPadding(26) }.sheetFrame(520, 520)
    }
}
#endif // circuit-convert
