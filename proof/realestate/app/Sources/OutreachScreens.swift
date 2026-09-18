#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — OUTREACH + SCORING UI: Work Queue (lead motivation scoring),
// Direct Mail (multi-touch sequences), Dialer & SMS (BYO-provider gate + 10DLC). All on the
// buyer's own data; honest gates throughout — no fabricated contacts, sends, or scores.
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

// Score-tier → premium pill tint.
extension ScoreTier {
    var tint: Color {
        switch self { case .hot: return BL.danger; case .warm: return BLTheme.gold
        case .cool: return .blue; case .cold: return BLTheme.sub }
    }
}

// MARK: - Outreach send-preview view-model (pure, UI-free) — the honesty rules the Direct-Mail
// drop queue and the Dialer/SMS channel gate render BEFORE anything is sent, extracted so they're
// asserted not eyeballed (mirrors RoutePresenter / DealPresenter — beef550, 2b3b0ec):
//   1. The "mail to drop now" summary is the MODEL's own packet — ready vs needs-review is derived
//      from real per-piece blockers, never a view guess; a piece missing an address or still
//      carrying a merge placeholder is flagged for review, never silently promoted to ready.
//   2. A merged-piece preview NEVER fabricates a missing field — an absent value stays a bracket
//      placeholder the buyer must fill.
//   3. A call/text send-preview routes through the SAME ComplianceEngine gate as a real send: an
//      SMS with no prior-express-WRITTEN consent, a suppressed number, or an out-of-window contact
//      is BLOCKED in the preview, never shown as ready. The per-recipient legal notes shown on a
//      provider-ready channel are the engine's OWN window/consent rules, not a view guess.
enum OutreachPreviewPresenter {
    /// The Direct-Mail "mail to drop now" summary state — model-derived counts, honest empty line.
    enum MailDropState: Hashable {
        case empty(String)                          // nothing due — an honest, model-derived sentence
        case due(ready: Int, review: Int, total: Int)
    }
    static func mailDropState(_ packet: MailDropExportPacket) -> MailDropState {
        guard !packet.rows.isEmpty else {
            return .empty("Nothing due. Enroll leads in a sequence and dated, merged pieces appear here when their drop date arrives.")
        }
        return .due(ready: packet.readyCount, review: packet.reviewCount, total: packet.rows.count)
    }

    /// A merged-piece preview is honest when a missing field survives as a bracket placeholder
    /// (true ⇒ the body still flags an unresolved field for the buyer, rather than a fabricated value).
    static func previewFlagsMissingField(_ body: String) -> Bool {
        body.contains("[") && body.contains("]")
    }

    /// The per-recipient legal rails ComplianceEngine enforces at send, surfaced up front so a
    /// provider-ready channel is never read as "send anything now". Derived from the engine's OWN
    /// window constants — not a hand-typed guess that could drift from the gate.
    static func channelGateNotes(_ kind: PhoneChannelKind) -> [String] {
        let openHr = ComplianceEngine.earliestHour            // 8
        let closeHr = ComplianceEngine.latestHour - 12        // 21 → 9 (pm)
        var notes = [
            "Each contact must land \(openHr)am–\(closeHr)pm in the recipient's local time — checked per lead at send.",
            "Numbers on your Do-Not-Contact / opt-out list are always skipped.",
        ]
        if kind.needs10DLC {
            notes.insert("Texts require prior express WRITTEN consent on file (TCPA) — no signed opt-in, no send.", at: 0)
        }
        return notes
    }

    /// The Dialer & SMS screen's subtitle, held here so it is ASSERTED not eyeballed (same reason
    /// RoutePresenter/DispositionsPresenter exist). It states what the screen DOES — connect a
    /// provider, track 10DLC — and names the limitation from the engine's own constant. It must
    /// never re-acquire a capability claim ("power dialer", "2-way SMS", "ringless voicemail")
    /// while PhoneOutreach.transportShipped is false.
    static let dialerSubtitle =
        "Record your own telephony provider and track your 10DLC registration. \(PhoneOutreach.transportNotEnabledReason)"

    /// How a call/text send-preview discloses the verdict for ONE recipient: the transport truth
    /// FIRST (`PhoneOutreach.transportShipped` — this build has no dialer/SMS transport, so a
    /// compliance-clean recipient is still never previewed as "ready"), then the engine's own
    /// gate (provider readiness + ComplianceEngine window/consent/suppression). Never a fabricated
    /// "ready": every reason is the engine's, and the no-transport reason is the engine's constant.
    enum SendPreview: Hashable {
        case ready
        case blocked([String])
    }
    static func channelSendPreview(_ kind: PhoneChannelKind, provider: PhoneProvider, phone: String,
                                   suppression: Suppression, consent: ContactConsent = .none,
                                   now: Date = Date()) -> SendPreview {
        let r = PhoneOutreach.canSend(kind, to: phone, provider: provider,
                                      suppression: suppression, consent: consent, now: now)
        if !r.ok { return .blocked(r.reasons) }
        // Compliance-clean, provider-ready — and STILL not sendable while no transport ships.
        if !PhoneOutreach.transportShipped { return .blocked([PhoneOutreach.transportNotEnabledReason]) }
        return .ready
    }
}

// A compact score badge reused in the work queue + pipeline.
struct ScoreBadge: View {
    let score: LeadScore
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "flame.fill").font(.blSystem(size: 9, weight: .bold))
            Text("\(score.total)").font(BLFont.mono(11, .bold))
            Text(score.tier.label).font(.blSystem(size: 9.5, weight: .bold, design: .rounded))
        }
        .foregroundColor(score.tier.tint)
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(score.tier.tint.opacity(0.14)).clipShape(Capsule())
        .overlay(Capsule().stroke(score.tier.tint.opacity(0.4), lineWidth: 1))
    }
}

// MARK: ============================== WORK QUEUE (SCORING) ==============================
struct WorkQueueScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var tierFilter: ScoreTier? = nil
    @State private var detail: Lead?
    @State private var exportNote = ""
    private var ranked: [(Lead, LeadScore)] {
        LeadScoring.rank(model.leads).filter { tierFilter == nil || $0.1.tier == tierFilter }
    }
    private var counts: [(ScoreTier, Int)] { LeadScoring.tierCounts(model.leads) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderRow(title: "Work Queue", subtitle: "Your leads ranked by a transparent motivation score — every point explained, computed from your own data") {
                if !model.leads.isEmpty {
                    // Real file export (save panel / share sheet) — this used to silently copy to the
                    // clipboard while the label promised a file, so users hunted for a download.
                    if !exportNote.isEmpty {
                        Text(exportNote).font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.gold)
                    }
                    GhostButton(label: "Export ranked CSV", icon: "square.and.arrow.up", tint: BLTheme.gold) {
                        let csv = ListEngine.csv(ranked.map { $0.0 })
                        exportNote = exportTextFile(suggestedName: "work-queue-ranked.csv", contents: csv,
                                                    type: .commaSeparatedText) ?? ""
                    }
                }
            }.blScreenPadding(28)
            if model.leads.isEmpty {
                Spacer(); EmptyState(icon: "flame", title: "No leads to score yet", hint: "Save leads from a database list or the scouts, then this queue ranks the most motivated sellers first — with the reason behind every score."); Spacer()
            } else {
                // Tier summary chips. `fixedSize` keeps each pill on one line — squeezed into a
                // phone-width row they were wrapping mid-word ("War m", "Coo l") — and on compact
                // the row scrolls sideways instead of compressing.
                tierChips
                    .padding(.horizontal, BLScale.gutter(28)).padding(.bottom, 14)
                ScrollView { LazyVStack(spacing: 10) {
                    ForEach(ranked, id: \.0.id) { lead, sc in queueRow(lead, sc) }
                }.padding(.horizontal, BLScale.gutter(28)).padding(.bottom, 28) }
            }
        }
        .sheet(item: $detail) { l in ScoreDetailSheet(lead: l, score: LeadScoring.score(l)).environmentObject(model).sheetCloseBar() }
    }
    private var chipRow: some View {
        HStack(spacing: 10) {
            ForEach(counts, id: \.0) { tier, n in
                Button { withAnimation { tierFilter = (tierFilter == tier ? nil : tier) } } label: {
                    HStack(spacing: 6) {
                        Circle().fill(tier.tint).frame(width: 7, height: 7)
                        Text(tier.label).font(BLFont.body(12, .bold)).foregroundColor(BLTheme.text)
                        Text("\(n)").font(BLFont.mono(11, .bold)).foregroundColor(tier.tint)
                    }
                    .fixedSize()
                    .padding(.vertical, 7).padding(.horizontal, 13)
                    .background(tierFilter == tier ? tier.tint.opacity(0.16) : BLTheme.bg2).clipShape(Capsule())
                    .overlay(Capsule().stroke(tierFilter == tier ? tier.tint.opacity(0.5) : BLTheme.stroke, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            if !BLScale.isCompact { Spacer() }
        }
    }
    @ViewBuilder private var tierChips: some View {
        if BLScale.isCompact {
            ScrollView(.horizontal, showsIndicators: false) { chipRow }
        } else {
            chipRow
        }
    }
    @ViewBuilder private func queueRow(_ l: Lead, _ sc: LeadScore) -> some View {
        Button { detail = l } label: {
            HStack(spacing: 14) {
                IconBadge(system: l.source.icon, size: 38, active: sc.tier == .hot)
                VStack(alignment: .leading, spacing: 5) {
                    Text(l.name.isEmpty ? "Unnamed lead" : l.name).font(.blSystem(size: 15, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(l.source.label).font(.blSystem(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                        if !l.propertyAddress.isEmpty { Text(l.propertyAddress).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).lineLimit(1) }
                    }
                    Text(sc.nextBestAction).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub.opacity(0.85)).lineLimit(1)
                }
                Spacer()
                ScoreBadge(score: sc)
                Image(systemName: "chevron.right").font(.blSystem(size: 12, weight: .bold)).foregroundColor(BLTheme.sub.opacity(0.4))
            }
            .padding(16).background(BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(sc.tier == .hot ? sc.tier.tint.opacity(0.35) : BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }
}

// Score breakdown — shows EXACTLY why a lead scores what it does (the transparency moat).
struct ScoreDetailSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let lead: Lead; let score: LeadScore
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconBadge(system: lead.source.icon, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(lead.name).font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(lead.source.label).font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.gold)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text("\(score.total)").font(.blSystem(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(BLTheme.goldGrad)
                    Text(score.tier.label.uppercased()).font(BLFont.mono(9, .bold)).foregroundColor(score.tier.tint).tracking(1)
                }
            }
            Text("Motivation = \(score.total)/100. Every point below is computed from this lead's own data — nothing is fabricated; gated signals are labeled.")
                .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                ForEach(score.factors) { f in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: f.hit ? "checkmark.circle.fill" : "circle").font(.blSystem(size: 12, weight: .bold)).foregroundColor(f.hit ? BLTheme.green : BLTheme.sub.opacity(0.5))
                            Text(f.name).font(.blSystem(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Spacer()
                            Text("\(f.points)/\(f.max)").font(BLFont.mono(11, .bold)).foregroundColor(f.hit ? BLTheme.gold : BLTheme.sub)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(BLTheme.bg2).frame(height: 5)
                                Capsule().fill(BLTheme.goldGrad).frame(width: max(0, geo.size.width * CGFloat(f.points) / CGFloat(max(1, f.max))), height: 5)
                            }
                        }.frame(height: 5)
                        Text(f.detail).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                }
            }
            Panel(title: "Next best action", icon: "arrow.right.circle.fill") {
                Text(score.nextBestAction).font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.green)
            }
            HStack { Spacer(); GoldButton(label: "Done", icon: "checkmark") { dismiss() } }
        }.blScreenPadding(26) }.sheetFrame(540, 680)
    }
}

// MARK: ============================== DIRECT MAIL (SEQUENCES) ==============================
struct DirectMailScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: MailSequence?
    @State private var enrolling: MailSequence?
    @State private var pendingDelete: MailSequence?
    @State private var showDue = true
    private var due: [ScheduledMailPiece] { model.dueMailPieces() }
    private var dropPacket: MailDropExportPacket { model.dueMailDropPacket() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Direct Mail", subtitle: "Multi-touch mail cadences — deals close on touch 5–7, not one postcard. Build sequences, enroll leads, run the dated drop schedule")
                Spacer()
                Menu {
                    Button("Blank sequence") { editing = MailSequence(name: "New sequence") }
                    Divider()
                    ForEach(MailSequenceTemplates.all) { t in Button("Clone: \(t.name)") { var c = t; c.id = UUID(); editing = c } }
                } label: { GoldLabel(label: "New sequence", icon: "plus") }.menuStyle(.borderlessButton).fixedSize()
            }.blScreenPadding(28)
            ScrollView { VStack(alignment: .leading, spacing: 16) {
                // DUE-NOW queue (real, dated, merged)
                Panel(title: "Mail to drop now", icon: "tray.full.fill", glow: !due.isEmpty) {
                    if case .empty(let line) = OutreachPreviewPresenter.mailDropState(dropPacket) {
                        Text(line).font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub)
                    } else {
                        Text("\(due.count) merged piece\(due.count == 1 ? "" : "s") due — export a mail-house CSV, copy the packet, or copy pieces one by one. Rows with missing addresses or placeholders are flagged for review; nothing is marked sent until you tap Mark dropped.").font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.gold)
                        HStack(spacing: 8) {
                            StatusPill(text: "\(dropPacket.readyCount) ready", tint: BLTheme.green)
                            StatusPill(text: "\(dropPacket.reviewCount) review", tint: dropPacket.reviewCount == 0 ? BLTheme.sub : BL.danger)
                            Spacer()
                            GhostButton(label: "Export CSV", icon: "square.and.arrow.up", tint: BLTheme.gold) {
                                _ = exportTextFile(suggestedName: "mail-drop-\(Int(Date().timeIntervalSince1970)).csv",
                                                   contents: dropPacket.csv,
                                                   type: .commaSeparatedText)
                            }
                            GhostButton(label: "Copy packet", icon: "doc.on.doc", tint: BLTheme.sub) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(dropPacket.textPacket, forType: .string)
                            }
                        }
                        ForEach(due) { p in duePieceRow(p) }
                    }
                }
                // Sequences
                if model.mailSequences.isEmpty {
                    EmptyState(icon: "envelope.open", title: "No sequences yet", hint: "Create a multi-touch mail cadence or clone a proven starter (Probate 5-touch, Absentee 3-touch). Then enroll leads.")
                        .padding(.vertical, 30)
                } else {
                    ForEach(model.mailSequences) { seq in sequenceCard(seq) }
                }
            }.padding(.horizontal, BLScale.gutter(28)).padding(.bottom, 28) }
        }
        .sheet(item: $editing) { s in MailSequenceEditor(sequence: s).environmentObject(model).sheetCloseBar() }
        .sheet(item: $enrolling) { s in MailEnrollSheet(sequence: s).environmentObject(model).sheetCloseBar() }
        .confirmationDialog("Delete this sequence?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let s = pendingDelete { model.deleteSequence(s) }; pendingDelete = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes it — there is no undo.") }
    }
    @ViewBuilder private func duePieceRow(_ p: ScheduledMailPiece) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(system: p.kind.icon, size: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(p.leadName).font(.blSystem(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(p.kind.label).font(BLFont.body(10.5, .semibold)).foregroundColor(BLTheme.gold)
                    Text(p.dropDate, style: .date).font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub)
                    // Honest: an unresolved merge/sender token survives as a bracket placeholder — flag it,
                    // never let a fabricated value slip into the piece.
                    if OutreachPreviewPresenter.previewFlagsMissingField(p.merged) {
                        StatusPill(text: "Fill a field", tint: BL.danger)
                    }
                }
                Text(p.merged).font(BLFont.body(11, .regular)).foregroundColor(BLTheme.sub).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            GhostButton(label: "Copy", icon: "doc.on.doc", tint: BLTheme.gold) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(p.merged, forType: .string)
            }
            // Mark dropped — clears the piece from the due queue and lets the lead timeline's
            // "Mail sent" event (gated on piece.done) fire. Without this the queue never cleared.
            GhostButton(label: "Mark dropped", icon: "checkmark.circle", tint: BLTheme.green) {
                if let e = model.enrollments.first(where: { $0.id == p.enrollmentID }) {
                    model.toggleTouch(e, touchID: p.id)
                }
            }
        }.padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
    }
    @ViewBuilder private func sequenceCard(_ seq: MailSequence) -> some View {
        let enrolled = model.enrollments.filter { $0.sequenceID == seq.id }.count
        Panel(title: seq.name.isEmpty ? "Untitled sequence" : seq.name, icon: "envelope.fill") {
            HStack(spacing: 14) {
                Label("\(seq.touchCount) touches", systemImage: "number").font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.sub)
                Label("\(seq.spanDays) days", systemImage: "calendar").font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.sub)
                Label("\(enrolled) enrolled", systemImage: "person.fill").font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.gold)
                Spacer()
            }
            FlowLayout(spacing: 6) {
                ForEach(seq.touches.sorted { $0.dayOffset < $1.dayOffset }) { t in
                    HStack(spacing: 4) {
                        Image(systemName: t.kind.icon).font(.blSystem(size: 9, weight: .bold))
                        Text("Day \(t.dayOffset)").font(BLFont.mono(9.5, .bold))
                    }.foregroundColor(BLTheme.text).padding(.vertical, 4).padding(.horizontal, 9)
                    .background(BLTheme.bg2).clipShape(Capsule()).overlay(Capsule().stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
                }
            }
            HStack(spacing: 10) {
                GhostButton(label: "Enroll leads", icon: "person.badge.plus", tint: BLTheme.gold) { enrolling = seq }
                GhostButton(label: "Edit", icon: "pencil", tint: BLTheme.sub) { editing = seq }
                GhostButton(label: "Delete", icon: "trash", tint: BL.danger) { pendingDelete = seq }
                Spacer()
            }
        }
    }
}

struct MailSequenceEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var sequence: MailSequence
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { IconBadge(system: "envelope.fill", size: 30); Text(sequence.name.isEmpty ? "New sequence" : "Edit sequence").font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text); Spacer() }
            Field(title: "Sequence name", text: $sequence.name, prompt: "Probate 5-touch")
            Text("TOUCHES — tokens {{name}} {{owner}} {{property}} {{county}} {{mailing}} merge each lead's real data; missing fields show a bracket placeholder, never a fake value.")
                .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            ForEach($sequence.touches) { $t in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Picker("", selection: $t.kind) { ForEach(MailPieceKind.allCases) { Label($0.label, systemImage: $0.icon).tag($0) } }.labelsHidden().tint(BLTheme.gold).fixedSize()
                        HStack(spacing: 6) { Text("Day").font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.sub)
                            TextField("0", value: $t.dayOffset, formatter: NumberFormatter()).textFieldStyle(.plain).frame(width: 44).padding(6).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8)).foregroundColor(BLTheme.text) }
                        Spacer()
                        Button { sequence.touches.removeAll { $0.id == t.id } } label: { Image(systemName: "trash").foregroundColor(BL.danger) }.buttonStyle(.plain)
                    }
                    TextEditor(text: $t.template).font(.blSystem(size: 12, design: .rounded)).foregroundColor(BLTheme.text).scrollContentBackground(.hidden).padding(8).frame(height: 70).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                }.padding(12).background(BLTheme.panel).clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
            }
            GhostButton(label: "Add touch", icon: "plus", tint: BLTheme.gold) {
                let nextDay = (sequence.touches.map { $0.dayOffset }.max() ?? -14) + 14
                sequence.touches.append(MailTouch(dayOffset: max(0, nextDay), kind: .postcard, template: "Hi {{name}}, regarding {{property}} — [your offer]. — [your name], [your phone]"))
            }
            HStack { Spacer(); GhostButton(label: "Cancel", tint: BLTheme.sub) { dismiss() }
                GoldButton(label: "Save sequence", icon: "checkmark") { model.upsert(sequence); dismiss() }.disabled(sequence.touches.isEmpty) }
        }.blScreenPadding(26) }.sheetFrame(560, 680)
    }
}

struct MailEnrollSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let sequence: MailSequence
    @State private var selected: Set<UUID> = []
    @State private var onlyMailable = true
    private var candidates: [Lead] {
        model.leads.filter { l in
            (!onlyMailable || !l.mailingAddress.isEmpty || !l.propertyAddress.isEmpty)
            && !model.enrollments.contains { $0.leadID == l.id && $0.sequenceID == sequence.id }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { IconBadge(system: "person.badge.plus", size: 30); Text("Enroll in \(sequence.name)").font(.blSystem(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text); Spacer() }
            Toggle(isOn: $onlyMailable) { Text("Only leads with a mailable address").font(BLFont.body(12, .semibold)) }.toggleStyle(.switch).tint(BLTheme.gold)
            if candidates.isEmpty {
                Text("No eligible leads to enroll (all already enrolled, or none have a mailable address).").font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub)
            } else {
                ScrollView { VStack(spacing: 6) {
                    ForEach(candidates) { l in
                        Button { if selected.contains(l.id) { selected.remove(l.id) } else { selected.insert(l.id) } } label: {
                            HStack {
                                Image(systemName: selected.contains(l.id) ? "checkmark.square.fill" : "square").foregroundColor(selected.contains(l.id) ? BLTheme.gold : BLTheme.sub)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(l.name).font(BLFont.body(12.5, .semibold)).foregroundColor(BLTheme.text)
                                    Text(l.mailingAddress.isEmpty ? l.propertyAddress : l.mailingAddress).font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub).lineLimit(1)
                                }
                                Spacer()
                            }.padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }}.frame(maxHeight: 320)
            }
            HStack { Text("\(selected.count) selected").font(BLFont.body(11.5, .bold)).foregroundColor(BLTheme.gold); Spacer()
                GhostButton(label: "Cancel", tint: BLTheme.sub) { dismiss() }
                GoldButton(label: "Enroll", icon: "checkmark") {
                    for id in selected { if let l = model.lead(id) { model.enroll(l, in: sequence) } }
                    dismiss()
                }.disabled(selected.isEmpty)
            }
        }.blScreenPadding(26).sheetFrame(520)
    }
}

// MARK: ============================== DIALER & SMS (BYO PROVIDER) ==============================
struct DialerScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var showConfig = false
    private var provider: PhoneProvider { model.phoneProvider }
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 18) {
            // The subtitle states what this screen DOES (connect a provider, track 10DLC), not what
            // the product will eventually do. There is no call/SMS transport in this build
            // (PhoneOutreach.transportShipped == false, verified 2026-08-03), and RE-18/⛔H4 require
            // a disabled texting path to LOOK disabled — so no "power dialer / 2-way SMS" claim here
            // until the provider client lands alongside the flag flip.
            SectionHeader(title: "Dialer & SMS", subtitle: OutreachPreviewPresenter.dialerSubtitle)

            // "Connected" was a claim this build cannot back: saving these fields performs no
            // handshake, no auth check, and no request of any kind — `provider.connected` only means
            // a name, a from-number and a Keychain key are on file. With no transport shipping
            // (PhoneOutreach.transportShipped == false) nothing ever contacts the carrier, so the
            // pill says SAVED, in the gold "tracked but incomplete" tint, never green.
            Panel(title: "Your telephony provider", icon: "antenna.radiowaves.left.and.right", glow: !provider.connected) {
                Text(PhoneOutreach.providerStorageOnlyNote)
                    .font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                if provider.connected {
                    HStack(spacing: 10) {
                        StatusPill(text: "Saved — not verified", tint: BLTheme.gold)
                        Text(provider.name).font(BLFont.body(13, .bold)).foregroundColor(BLTheme.text)
                        Text("from \(provider.fromNumber)").font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
                        Spacer()
                        GhostButton(label: "Edit details", icon: "gearshape", tint: BLTheme.gold) { showConfig = true }
                    }
                } else {
                    Text("Nothing saved yet. The product never fabricates a call or text — record your own carrier (Twilio, Telnyx, etc.) here. The API key is stored in this \(kThisDeviceWord)'s Keychain and never bundled, logged, or sent anywhere.")
                        .font(BLFont.body(12, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    HStack { GoldButton(label: "Save provider details", icon: "square.and.pencil") { showConfig = true }; Spacer() }
                }
            }

            // Channel state — the engine's own verdict, transport truth included. A green "Ready"
            // pill is reachable ONLY from .sendable, i.e. only once a real transport ships; typing
            // provider fields and ticking the two 10DLC toggles gets "Provider configured — sending
            // not enabled", never a claim the app can't back.
            Panel(title: "Channels", icon: "phone.bubble.fill") {
                ForEach(PhoneChannelKind.allCases) { kind in
                    let state = PhoneOutreach.sendState(kind, provider: provider)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            IconBadge(system: kind.icon, size: 30, active: state == .sendable)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(kind.label).font(.blSystem(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                if kind.needs10DLC { Text("Requires 10DLC A2P registration").font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub) }
                            }
                            Spacer()
                            StatusPill(text: state.pillText, tint: pillTint(state))
                        }
                        switch state {
                        case .gated(let blockers):
                            ForEach(blockers, id: \.self) { b in
                                HStack(spacing: 6) { Image(systemName: "exclamationmark.circle.fill").font(.blSystem(size: 10)).foregroundColor(BL.danger.opacity(0.8)); Text(b).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub) }
                            }
                        case .configuredNoTransport:
                            HStack(spacing: 6) { Image(systemName: "nosign").font(.blSystem(size: 10)).foregroundColor(BLTheme.gold.opacity(0.9)); Text(PhoneOutreach.transportNotEnabledReason).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub) }
                            // The rails below are what will apply the day a send exists — shown as
                            // future conditions, not as an all-clear for something that can run now.
                            ForEach(OutreachPreviewPresenter.channelGateNotes(kind), id: \.self) { note in
                                HStack(spacing: 6) { Image(systemName: "shield.lefthalf.filled").font(.blSystem(size: 10)).foregroundColor(BLTheme.sub); Text("When sending lands: \(note)").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub) }
                            }
                        case .sendable:
                            // Provider-ready ≠ send-anything: surface the per-recipient TCPA rails the
                            // ComplianceEngine still enforces per lead at send (never a fabricated all-clear).
                            ForEach(OutreachPreviewPresenter.channelGateNotes(kind), id: \.self) { note in
                                HStack(spacing: 6) { Image(systemName: "checkmark.shield.fill").font(.blSystem(size: 10)).foregroundColor(BLTheme.green.opacity(0.8)); Text(note).font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub) }
                            }
                        }
                    }.padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                }
            }

            // 10DLC registration tracker
            Panel(title: "10DLC registration (A2P SMS)", icon: "checkmark.seal.fill") {
                Text("US carriers require brand + campaign registration before business SMS. Track yours here and complete it with your provider — we never auto-approve it.")
                    .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    regStep("Brand", provider.tenDLC.brandRegistered)
                    Image(systemName: "arrow.right").foregroundColor(BLTheme.sub)
                    regStep("Campaign", provider.tenDLC.campaignRegistered)
                    Spacer()
                    GhostButton(label: "Update", icon: "pencil", tint: BLTheme.gold) { showConfig = true }
                }
            }
        }.blScreenPadding(28) }
        .sheet(isPresented: $showConfig) { ProviderConfigSheet().environmentObject(model).sheetCloseBar() }
    }
    /// Green is reserved for a state the app can actually perform; configured-but-no-transport is
    /// gold (a tracked, incomplete step), missing prerequisites are red.
    private func pillTint(_ state: PhoneOutreach.ChannelSendState) -> Color {
        switch state {
        case .gated: return BL.danger
        case .configuredNoTransport: return BLTheme.gold
        case .sendable: return BLTheme.green
        }
    }
    @ViewBuilder private func regStep(_ label: String, _ done: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundColor(done ? BLTheme.green : BLTheme.sub)
            Text(label).font(BLFont.body(12, .bold)).foregroundColor(done ? BLTheme.text : BLTheme.sub)
        }.padding(.vertical, 6).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(Capsule())
    }
}

struct ProviderConfigSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var p = PhoneProvider()
    @State private var apiKey = ""
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) { IconBadge(system: "antenna.radiowaves.left.and.right", size: 30); Text("Telephony provider").font(.blSystem(size: 19, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text); Spacer() }
            // Saving is a local record, not a connection — say so before the buyer types a key, not
            // only after. Nothing on this sheet reaches the carrier.
            Text(PhoneOutreach.providerStorageOnlyNote)
                .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            Field(title: "Provider name", text: $p.name, prompt: "Twilio")
            Field(title: "From number (your provisioned number)", text: $p.fromNumber, prompt: "Your provisioned sender number")
            VStack(alignment: .leading, spacing: 5) {
                Text("API KEY").font(.blSystem(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                SecureField(p.apiKeyPresent ? "•••••••• (stored in Keychain)" : "Paste your provider API key", text: $apiKey)
                    .textFieldStyle(.plain).font(.blSystem(size: 14, design: .rounded)).foregroundColor(BLTheme.text)
                    .padding(.vertical, 11).padding(.horizontal, 13).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                Text("Stored only in this \(kThisDeviceWord)'s Keychain. Never bundled, logged, or sent anywhere but your provider's API.").font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub)
            }
            Divider().background(BLTheme.stroke)
            Text("10DLC REGISTRATION").font(BLFont.mono(9.5, .bold)).foregroundColor(BLTheme.gold).tracking(1)
            Field(title: "Brand name", text: $p.tenDLC.brandName, prompt: "Your LLC / DBA")
            Field(title: "Business EIN", text: $p.tenDLC.ein, prompt: "12-3456789")
            Field(title: "Use case", text: $p.tenDLC.useCase, prompt: "Real-estate lead follow-up")
            Toggle(isOn: $p.tenDLC.brandRegistered) { Text("Brand registered with carrier").font(BLFont.body(12.5, .semibold)) }.toggleStyle(.switch).tint(BLTheme.gold)
            Toggle(isOn: $p.tenDLC.campaignRegistered) { Text("Campaign registered & approved").font(BLFont.body(12.5, .semibold)) }.toggleStyle(.switch).tint(BLTheme.gold)
            HStack { Spacer(); GhostButton(label: "Cancel", tint: BLTheme.sub) { dismiss() }
                GoldButton(label: "Save", icon: "checkmark") {
                    if !apiKey.trimmingCharacters(in: .whitespaces).isEmpty {
                        ProviderKeychain.set(apiKey.trimmingCharacters(in: .whitespaces)); p.apiKeyPresent = true
                    } else { p.apiKeyPresent = ProviderKeychain.hasKey() }
                    model.phoneProvider = p; dismiss()
                }
            }
        }.blScreenPadding(26) }.sheetFrame(520, 660)
        .onAppear { p = model.phoneProvider }
    }
}

// Real Keychain store for the provider key (the secret never lives in the model or the bundle).
// Routes through RealEstateKeychain (Keychain.swift) so the key lands in the DATA-PROTECTION
// keychain — access keyed to the stable app identifier, not the per-rebuild adhoc signature — which
// is what stops the recurring macOS keychain password prompt on re-signed local builds
// (Founder 2026-07-03). Unsigned/entitlement-less builds fall back to the legacy path unchanged.
enum ProviderKeychain {
    private static let account = "com.blacklabel.realestate.telephony"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }
    static func set(_ key: String) {
        RealEstateKeychain.set(base, data: Data(key.utf8))
    }
    static func hasKey() -> Bool {
        RealEstateKeychain.copy(base) != nil
    }
    /// DESTRUCTIVE — removes the connected telephony/outreach provider credential. Backs account
    /// deletion, which must leave no connected-provider key behind.
    static func clear() {
        RealEstateKeychain.delete(base)
    }
}
#endif // circuit-convert
