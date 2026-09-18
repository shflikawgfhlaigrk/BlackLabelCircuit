#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Audience (segmentation) + Email Builder screens.
// Both operate on the buyer's OWN contacts (CRM leads + saved clients), on-device.
// No fabrication: segment counts are live evaluations over real data; email sends
// hand a personalized message to the buyer's own mail client (logged "Composed").
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// Empty-state hints. b25: the Lead Database is back on every platform (in-app subscription on
// iOS makes it a legal 3.1.3(b) surface), so the copy can point at it everywhere again.
private let noContactsSendHint = "No contacts yet. Add businesses in Find Clients or import them from the Lead Database, then send to them here."
private let noContactsComposeHint = "No contacts yet — add businesses in Find Clients or import leads in the Lead Database, then compose here."

// MARK: - Audience: build, save, and preview rule-based segments

struct AudienceScreen: View {
    @EnvironmentObject var model: AppModel

    @State private var draft = Segment(name: "", match: .all, rules: [SegRule()])
    @State private var editingID: Segment.ID?
    @State private var toast = ""

    private var contacts: [Contact] { model.allContacts }
    private var liveMatches: [Contact] { SegEngine.evaluate(draft, over: contacts) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Audience",
                             subtitle: "Build saved segments from your own contacts — leads and saved clients — to target campaigns.")

                // Pool summary (real counts, never fabricated)
                LazyVGrid(columns: blGridColumns(), spacing: 16) {
                    HeroStat(label: "Contacts", value: "\(contacts.count)", icon: "person.3.fill")
                    HeroStat(label: "Emailable", value: "\(contacts.filter { !$0.email.trimmingCharacters(in: .whitespaces).isEmpty }.count)", icon: "envelope.fill")
                    HeroStat(label: "This segment", value: "\(liveMatches.count)", icon: "line.3.horizontal.decrease.circle.fill")
                }

                if contacts.isEmpty {
                    Panel(title: "No contacts yet", icon: "person.crop.circle.badge.questionmark") {
                        EmptyState(icon: "person.3.sequence",
                                   title: "Your audience is empty",
                                   hint: "Add leads in Leads (CRM) or save businesses in Find Clients. Segments build from those real contacts — nothing is generated for you.")
                    }
                } else {
                    builder
                    if !model.segments.isEmpty { savedSegments }
                }
            }
            .padding(28)
        }
    }

    // ---- Segment builder ----
    private var builder: some View {
        Panel(title: editingID == nil ? "New segment" : "Edit segment", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                Field(title: "Segment name", text: $draft.name, prompt: "Warm leads in Austin")

                VStack(alignment: .leading, spacing: 6) {
                    Text("LOGIC").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                    Picker("", selection: $draft.match) {
                        ForEach(SegMatch.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented).tint(BLTheme.gold)
                }

                VStack(spacing: 10) {
                    ForEach($draft.rules) { $rule in ruleEditor($rule) }
                }
                GhostButton(label: "Add rule", icon: "plus") { draft.rules.append(SegRule()) }

                // Live match readout — real evaluation as you type.
                HStack(spacing: 8) {
                    Image(systemName: "person.fill.checkmark").foregroundColor(BLTheme.green).font(.system(size: 13, weight: .bold))
                    Text("\(liveMatches.count) of \(contacts.count) contacts match")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Spacer()
                }
                .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))

                HStack(spacing: 10) {
                    GoldButton(label: editingID == nil ? "Save segment" : "Update segment", fill: true, icon: "tray.and.arrow.down.fill") { saveSegment() }
                    if editingID != nil {
                        GhostButton(label: "New", icon: "plus.circle") { resetDraft() }
                    }
                }
                if !toast.isEmpty {
                    Label(toast, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                }

                // Live preview of matched contacts (first 8)
                if !liveMatches.isEmpty {
                    Divider().background(BLTheme.stroke)
                    Text("PREVIEW (\(min(8, liveMatches.count)) of \(liveMatches.count))").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.7)
                    VStack(spacing: 6) {
                        ForEach(liveMatches.prefix(8)) { c in contactRow(c) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func ruleEditor(_ rule: Binding<SegRule>) -> some View {
        let validOps = SegOp.valid(for: rule.wrappedValue.field)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: rule.field) {
                    ForEach(SegField.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold).frame(maxWidth: 150)
                    .onChangeCompat(of: rule.wrappedValue.field) { newField in
                        // Keep the operator valid for the new field.
                        let ops = SegOp.valid(for: newField)
                        if !ops.contains(rule.wrappedValue.op) { rule.wrappedValue.op = ops.first ?? .contains }
                    }
                Picker("", selection: rule.op) {
                    ForEach(validOps) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold).frame(maxWidth: 140)
                Spacer()
                Button { draft.rules.removeAll { $0.id == rule.wrappedValue.id } } label: {
                    Image(systemName: "trash").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.danger)
                }.buttonStyle(.plain).disabled(draft.rules.count <= 1).opacity(draft.rules.count <= 1 ? 0.3 : 1)
            }
            if rule.wrappedValue.op.needsValue {
                TextField(rule.wrappedValue.field == .recencyDays ? "e.g. 30" : "value", text: rule.value)
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                    .padding(8).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
            }
        }
        .padding(11).background(BLTheme.panel.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func contactRow(_ c: Contact) -> some View {
        HStack(spacing: 10) {
            Image(systemName: c.origin == "Saved client" ? "building.2.fill" : "person.fill")
                .font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                .frame(width: 26, height: 26).background(BLTheme.goldGrad).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(c.name.isEmpty ? (c.email.isEmpty ? "(no name)" : c.email) : c.name)
                    .font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text([c.email, c.city, c.industry, c.source].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
            Spacer()
            StatusPill(text: c.origin, tint: BLTheme.sub)
        }
        .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
    }

    // ---- Saved segments ----
    private var savedSegments: some View {
        Panel(title: "Saved segments (\(model.segments.count))", icon: "folder.fill") {
            VStack(spacing: 8) {
                ForEach(model.segments) { s in
                    let n = SegEngine.count(s, over: contacts)
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name.isEmpty ? "Untitled segment" : s.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Text("\(s.rules.count) rule\(s.rules.count == 1 ? "" : "s") · \(s.match == .all ? "AND" : "OR") · \(n) match\(n == 1 ? "" : "es")")
                                .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                        Spacer()
                        IconButton(system: "square.and.pencil") { loadSegment(s) }
                        IconButton(system: "trash", tint: BLTheme.danger) { model.deleteSegment(s) }
                    }
                    .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                }
            }
        }
    }

    private func saveSegment() {
        var s = draft
        if s.name.trimmingCharacters(in: .whitespaces).isEmpty { s.name = "Segment \(model.segments.count + 1)" }
        if let id = editingID { s.id = id }
        model.upsertSegment(s)
        toast = editingID == nil ? "Segment saved." : "Segment updated."
        editingID = s.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if toast.hasPrefix("Segment") { toast = "" } }
    }
    private func loadSegment(_ s: Segment) {
        draft = s; editingID = s.id; toast = ""
    }
    private func resetDraft() {
        draft = Segment(name: "", match: .all, rules: [SegRule()]); editingID = nil; toast = ""
    }
}

// MARK: - Email Builder: block composer + tokens + A/B + segment send

struct EmailBuilderScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs

    @State private var campaign = EmailCampaign(name: "", subject: "", blocks: [
        EmailBlock(kind: .heading, text: "A quick idea for {{company}}"),
        EmailBlock(kind: .paragraph, text: "Hi {{first_name}}, we help local businesses get found online."),
    ])
    @State private var editingID: EmailCampaign.ID?
    @State private var selectedSegmentID: UUID?
    @State private var confirmsAllContacts = false
    @State private var showVariantB = false
    @State private var toast = ""
    @State private var sentCount = 0

    private var contacts: [Contact] { model.allContacts }
    private var targetContacts: [Contact] {
        if let sid = selectedSegmentID, let seg = model.segments.first(where: { $0.id == sid }) {
            return SegEngine.evaluate(seg, over: contacts)
        }
        return confirmsAllContacts ? contacts : []
    }
    private var emailable: [Contact] { targetContacts.filter { !$0.email.trimmingCharacters(in: .whitespaces).isEmpty } }
    private var sampleContact: Contact {
        emailable.first ?? targetContacts.first ?? Contact(id: UUID(), name: "Jordan Lee", email: "jordan@example.com", company: "Summit Plumbing", industry: "Plumbing", city: "Austin")
    }
    private var accentHex: String { prefs.sitePalette.hexes.0 }

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Email Builder",
                                 subtitle: "Compose a block-based email with personalization tokens, target a segment, and send via your own mail app.")

                    subjectPanel
                    blocksPanel(forB: false)
                    abPanel
                    if showVariantB { blocksPanel(forB: true) }
                    audiencePanel
                    sendPanel
                    if !model.campaigns.isEmpty { savedCampaigns }
                }
                .padding(24)
            }
            .splitPaneWidth(min: 440, ideal: 520)

            // Live HTML preview (personalized for a real sample contact)
            ZStack {
                BLTheme.bg2.ignoresSafeArea()
                VStack(spacing: 10) {
                    HStack {
                        Text(DemoMode.active ? "SAMPLE OUTPUT · GENERATED EMAIL" : "LIVE PREVIEW")
                            .font(BLFonts.mono(10, weight: .bold))
                            .foregroundColor(DemoMode.active ? BLTheme.gold : BLTheme.sub).tracking(1)
                            .accessibilityIdentifier("demo.proof.email.output")
                        Spacer()
                        Text("for \(sampleContact.name.isEmpty ? sampleContact.email : sampleContact.name)")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                    }
                    Text(Personalize.render(campaign.subject.isEmpty ? "(no subject)" : campaign.subject, for: sampleContact))
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HTMLPreview(html: EmailBuilder.html(campaign.blocks, for: sampleContact, accentHex: accentHex))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
                }
                .padding(20)
            }
            .splitPaneWidth(min: 360)
        }
        .onAppear {
            if selectedSegmentID == nil { selectedSegmentID = model.segments.first?.id }
            loadDemoCampaignIfNeeded()
        }
    }

    private var subjectPanel: some View {
        Panel(title: "Subject", icon: "textformat") {
            VStack(alignment: .leading, spacing: 10) {
                Field(title: "Campaign name", text: $campaign.name, prompt: "Spring outreach")
                Field(title: "Subject line", text: $campaign.subject, prompt: "A quick idea for {{company}}")
                tokenRow { token in campaign.subject += "{{\(token)}}" }
            }
        }
    }

    private func blocksPanel(forB: Bool) -> some View {
        Panel(title: forB ? "Variant B blocks" : "Content blocks", icon: "square.stack.3d.up.fill") {
            VStack(spacing: 10) {
                let blocks = forB ? $campaign.blocksB : $campaign.blocks
                if blocks.wrappedValue.isEmpty {
                    EmptyState(icon: "square.stack.3d.up", title: "No blocks yet", hint: "Add a heading, text, button, or divider below to compose this email.")
                } else {
                    ForEach(blocks) { $block in blockEditor($block, forB: forB) }
                }
                HStack(spacing: 8) {
                    ForEach(EmailBlockKind.allCases) { kind in
                        Button {
                            if forB { campaign.blocksB.append(EmailBlock(kind: kind, text: defaultText(kind))) }
                            else { campaign.blocks.append(EmailBlock(kind: kind, text: defaultText(kind))) }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: kind.icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                                Text(kind.label).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    @ViewBuilder private func blockEditor(_ block: Binding<EmailBlock>, forB: Bool) -> some View {
        let kind = block.wrappedValue.kind
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(kind.label, systemImage: kind.icon).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                Spacer()
                Button { move(block.wrappedValue, up: true, forB: forB) } label: { Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                Button { move(block.wrappedValue, up: false, forB: forB) } label: { Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                Button { remove(block.wrappedValue, forB: forB) } label: { Image(systemName: "trash").font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.danger) }.buttonStyle(.plain)
            }
            if kind == .heading || kind == .paragraph || kind == .button {
                if kind == .paragraph {
                    TextEditor(text: block.text)
                        .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        .scrollContentBackground(.hidden).frame(minHeight: 64)
                        .padding(7).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                } else {
                    TextField(kind == .button ? "Button label" : "Text", text: block.text)
                        .textFieldStyle(.plain).font(.system(size: 13.5, weight: kind == .heading ? .bold : .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        .padding(8).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                }
                if kind == .button {
                    TextField("https://your-link.com", text: block.url)
                        .textFieldStyle(.plain).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundColor(BLTheme.sub)
                        .padding(8).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                }
                if kind != .button { tokenRow { token in block.wrappedValue.text += "{{\(token)}}" } }
            } else {
                Text(kind == .divider ? "A horizontal divider line." : "Vertical spacing.")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
        }
        .padding(11).background(BLTheme.panel.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func tokenRow(_ insert: @escaping (String) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Text("INSERT:").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub)
                ForEach(Personalize.tokens, id: \.self) { tok in
                    Button { insert(tok) } label: {
                        Text("{{\(tok)}}").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.gold)
                            .padding(.vertical, 3).padding(.horizontal, 8)
                            .background(BLTheme.gold.opacity(0.12)).clipShape(Capsule())
                            .overlay(Capsule().stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var abPanel: some View {
        Panel(title: "A/B test", icon: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $campaign.abEnabled) {
                    Text("Split-test two versions across the audience")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                }.tint(BLTheme.gold)
                if campaign.abEnabled {
                    Field(title: "Variant B subject", text: $campaign.subjectB, prompt: "Alternate subject line")
                    tokenRow { token in campaign.subjectB += "{{\(token)}}" }
                    HStack {
                        Text("Half your audience gets Variant A, half gets B. Stable split by contact order.")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        Spacer()
                        GhostButton(label: showVariantB ? "Hide B blocks" : "Edit B blocks", icon: "square.stack.3d.up") {
                            if campaign.blocksB.isEmpty { campaign.blocksB = campaign.blocks }   // seed B from A
                            withAnimation { showVariantB.toggle() }
                        }
                    }
                }
            }
        }
    }

    private var audiencePanel: some View {
        Panel(title: "Audience", icon: "person.3.fill") {
            VStack(alignment: .leading, spacing: 10) {
                if model.segments.isEmpty {
                    Text(targetContacts.isEmpty
                         ? noContactsSendHint
                         : "All-contact scope explicitly confirmed for \(emailable.count) emailable contacts.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                } else {
                    Picker("Segment", selection: $selectedSegmentID) {
                        Text("All contacts (confirmation required)").tag(UUID?.none)
                        ForEach(model.segments) { s in Text(s.name.isEmpty ? "Untitled segment" : s.name).tag(UUID?.some(s.id)) }
                    }.tint(BLTheme.gold)
                        .onChangeCompat(of: selectedSegmentID) { _ in confirmsAllContacts = false }
                }
                if selectedSegmentID == nil, !contacts.isEmpty {
                    Toggle(isOn: $confirmsAllContacts) {
                        Text("I explicitly intend to use all \(contacts.count) contacts")
                            .font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    }
                    .toggleStyle(.switch).tint(BLTheme.gold)
                    Text("Off by default. Selecting this confirms the campaign scope; it does not send anything automatically.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                HStack(spacing: 14) {
                    Label("\(targetContacts.count) in audience", systemImage: "person.3").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Label("\(emailable.count) emailable", systemImage: "envelope.fill").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                }
            }
        }
    }

    private var sendPanel: some View {
        Panel(title: "Save & send", icon: "paperplane.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    FoilBadge(text: "LIVE", icon: "checkmark.seal.fill")
                    Text("Send opens each personalized email in your mail app, one at a time — review and send. We log each as \"Composed,\" never a fabricated \"Delivered.\"")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    GoldButton(label: "Save campaign", icon: "tray.and.arrow.down.fill") { saveCampaign() }
                    GoldButton(label: "Compose first email", icon: "envelope.fill") { composeFirst() }
                        .opacity(emailable.isEmpty ? 0.5 : 1).disabled(emailable.isEmpty)
                    GhostButton(label: "Export HTML", icon: "chevron.left.forwardslash.chevron.right") { exportHTML() }
                }
                if emailable.isEmpty {
                    Label(targetContacts.isEmpty
                          ? noContactsComposeHint
                          : "No contacts in this audience have an email address — add emails in Leads/Find Clients.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !toast.isEmpty {
                    Label(toast, systemImage: "checkmark.circle.fill").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                }
            }
        }
    }

    private var savedCampaigns: some View {
        Panel(title: "Saved campaigns (\(model.campaigns.count))", icon: "folder.fill") {
            VStack(spacing: 8) {
                ForEach(model.campaigns) { c in
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.fill").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                            .frame(width: 28, height: 28).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name.isEmpty ? "Untitled campaign" : c.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Text("\(c.blocks.count) block\(c.blocks.count == 1 ? "" : "s")\(c.abEnabled ? " · A/B" : "") · \(c.subject)").font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                        }
                        Spacer()
                        IconButton(system: "square.and.pencil") { loadCampaign(c) }
                        IconButton(system: "trash", tint: BLTheme.danger) { model.deleteCampaign(c) }
                    }
                    .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                }
            }
        }
    }

    // ---- helpers ----
    private func defaultText(_ kind: EmailBlockKind) -> String {
        switch kind {
        case .heading: return "Headline"
        case .paragraph: return "Write your message here. Use {{first_name}} to personalize."
        case .button: return "Learn more"
        case .divider, .spacer: return ""
        }
    }
    private func move(_ b: EmailBlock, up: Bool, forB: Bool) {
        if forB { campaign.blocksB = reorder(campaign.blocksB, b, up: up) }
        else { campaign.blocks = reorder(campaign.blocks, b, up: up) }
    }
    private func reorder(_ arr: [EmailBlock], _ b: EmailBlock, up: Bool) -> [EmailBlock] {
        var a = arr
        guard let i = a.firstIndex(of: b) else { return a }
        let j = up ? i - 1 : i + 1
        guard j >= 0, j < a.count else { return a }
        a.swapAt(i, j); return a
    }
    private func remove(_ b: EmailBlock, forB: Bool) {
        if forB { campaign.blocksB.removeAll { $0.id == b.id } } else { campaign.blocks.removeAll { $0.id == b.id } }
    }
    private func saveCampaign() {
        var c = campaign
        if c.name.trimmingCharacters(in: .whitespaces).isEmpty { c.name = "Campaign \(model.campaigns.count + 1)" }
        c.segmentID = selectedSegmentID
        if let id = editingID { c.id = id }
        model.upsertCampaign(c); editingID = c.id
        flash("Campaign saved.")
    }
    private func loadCampaign(_ c: EmailCampaign) {
        campaign = c; editingID = c.id; selectedSegmentID = c.segmentID; confirmsAllContacts = false; showVariantB = false; toast = ""
    }
    /// Demo mode opens on an actual HTML email generated by the shipped block renderer. The sample
    /// stays in the isolated demo database and remains visibly labeled; real workspaces keep their
    /// own draft/empty state.
    private func loadDemoCampaignIfNeeded() {
        guard DemoMode.active, editingID == nil, let sample = model.campaigns.first else { return }
        loadCampaign(sample)
        toast = "SAMPLE OUTPUT · Generated email loaded in the live preview."
    }
    /// Compose the FIRST emailable contact's personalized message into the buyer's
    /// mail app and log it. Honest, real, one-at-a-time (no fake bulk "send").
    private func composeFirst() {
        guard selectedSegmentID != nil || confirmsAllContacts else {
            flash("Choose a saved segment or explicitly confirm all contacts before composing.")
            return
        }
        guard let first = emailable.first else { return }
        let idx = 0
        let useB = campaign.abEnabled && EmailBuilder.abVariant(index: idx) == 1
        let subjectTpl = useB ? (campaign.subjectB.isEmpty ? campaign.subject : campaign.subjectB) : campaign.subject
        let blocks = useB ? (campaign.blocksB.isEmpty ? campaign.blocks : campaign.blocksB) : campaign.blocks
        let subject = Personalize.render(subjectTpl, for: first)
        let body = EmailBuilder.plainText(blocks, for: first)
        if let url = Studio.mailtoURL(to: first.email, subject: subject, body: body) {
            let who = first.name.isEmpty ? first.email : first.name
            let opened = DemoMode.openExternal(url, simulatedNote: "Demo: this would open a personalized email for \(who).")
            model.logSpotlight(SpotlightRecord(client: who, subject: subject, to: first.email, status: "Composed"))
            saveCampaign()
            flash(opened
                  ? "Opened a personalized email for \(who) in your mail app. \(emailable.count - 1) more in this audience."
                  : "Demo — composed a personalized email for \(who) (nothing is actually sent). \(emailable.count - 1) more in this audience.")
        }
    }
    private func exportHTML() {
        let html = EmailBuilder.html(campaign.blocks, for: sampleContact, accentHex: accentHex)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (campaign.name.isEmpty ? "email" : campaign.name.replacingOccurrences(of: " ", with: "-").lowercased()) + ".html"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try html.write(to: url, atomically: true, encoding: .utf8)
                flash("Exported \(url.lastPathComponent).")
            } catch {
                flash("Couldn't save the file — \(error.localizedDescription) Try a different folder.")
            }
        }
    }
    private func flash(_ m: String) {
        toast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if toast == m { toast = "" } }
    }
}
#endif // circuit-convert
