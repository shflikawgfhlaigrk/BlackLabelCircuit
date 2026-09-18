#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Tier-2/3 screens: Lead Scoring, Workflows, Attribution, Landing A/B.
// All operate on the buyer's OWN data via the pure engines in GrowthEngine.swift.
// Honest empty states everywhere; nothing fabricated, nothing auto-sent silently.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// ============================================================================
// MARK: - Lead Scoring
// ============================================================================

struct LeadScoringScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var filter: String = "All"
    @State private var query = ""
    @State private var visibleLimit = scorePageSize

    private static let scorePageSize = 100

    private var scored: [(contact: Contact, score: Int)] {
        model.scoredContacts(prefs.leadScoreWeights)
            .sorted { $0.score > $1.score }
    }
    private var filtered: [(contact: Contact, score: Int)] {
        scored.filter { item in
            let g = LeadScoreEngine.grade(item.score).rawValue
            let passGrade = filter == "All" || g == filter
            let q = query.trimmingCharacters(in: .whitespaces).lowercased()
            let passQ = q.isEmpty || item.contact.name.lowercased().contains(q) ||
                item.contact.email.lowercased().contains(q) || item.contact.company.lowercased().contains(q)
            return passGrade && passQ
        }
    }
    private func gradeColor(_ g: LeadGrade) -> Color {
        switch g { case .hot: return BLTheme.danger; case .warm: return BLTheme.gold; case .cool: return BLTheme.green; case .cold: return BLTheme.sub }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Lead Scoring",
                             subtitle: "Deterministic scores from your own contact data — every point is explained, nothing is guessed.")

                if model.allContacts.isEmpty {
                    Panel(title: "Scores", icon: "flame.fill") {
                        EmptyState(icon: "person.crop.circle.badge.questionmark",
                                   title: "No contacts to score yet",
                                   hint: "Save clients in Find Clients or add CRM leads. Scores are built only from real fields you have — email, phone, recency, and logged touches.")
                    }
                } else {
                    // Grade distribution from REAL scores.
                    Panel(title: "Distribution", icon: "chart.bar.fill") {
                        let buckets = Dictionary(grouping: scored, by: { LeadScoreEngine.grade($0.score).rawValue })
                        HStack(spacing: 12) {
                            ForEach(["Hot", "Warm", "Cool", "Cold"], id: \.self) { g in
                                let n = buckets[g]?.count ?? 0
                                VStack(spacing: 4) {
                                    Text("\(n)").font(BLFonts.mono(26, weight: .heavy)).foregroundColor(gradeColor(LeadGrade(rawValue: g) ?? .cold))
                                    Text(g.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                                }.frame(maxWidth: .infinity)
                                    .padding(.vertical, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        Text("Tune the point weights in Settings → Lead scoring. Scores recompute instantly from your data.")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }

                    Panel(title: "Scored contacts (\(filtered.count))", icon: "list.number") {
                        let rows = filtered
                        let visibleRows = Array(rows.prefix(visibleLimit))
                        LazyVStack(spacing: 10) {
                            Field(title: "Search", text: $query, prompt: "name, email, or company")
                            Picker("", selection: $filter) {
                                ForEach(["All", "Hot", "Warm", "Cool", "Cold"], id: \.self) { Text($0).tag($0) }
                            }.pickerStyle(.segmented).labelsHidden()

                            if rows.isEmpty {
                                EmptyState(icon: "magnifyingglass", title: "No matches", hint: "No contacts match this grade or search.")
                            } else {
                                HStack {
                                    Text("Showing \(visibleRows.count.formatted()) of \(rows.count.formatted()) scored contacts")
                                        .font(BLFonts.mono(10.5, weight: .semibold))
                                        .foregroundColor(BLTheme.sub)
                                    Spacer()
                                }
                                ForEach(visibleRows, id: \.contact.id) { item in row(item.contact, item.score) }
                                if visibleRows.count < rows.count {
                                    GhostButton(label: "Show next \(Self.scorePageSize)", icon: "chevron.down.circle") {
                                        visibleLimit += Self.scorePageSize
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(26)
        }
        .onChangeCompat(of: filter) { _ in visibleLimit = Self.scorePageSize }
        .onChangeCompat(of: query) { _ in visibleLimit = Self.scorePageSize }
    }

    @ViewBuilder private func row(_ c: Contact, _ score: Int) -> some View {
        let grade = LeadScoreEngine.grade(score)
        let reasons = LeadScoreEngine.reasons(c, touches: model.loggedTouchCount(for: c), w: prefs.leadScoreWeights)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(gradeColor(grade).opacity(0.16)).frame(width: 44, height: 44)
                    Text("\(score)").font(BLFonts.mono(16, weight: .heavy)).foregroundColor(gradeColor(grade))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name.isEmpty ? "(no name)" : c.name).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(c.email.isEmpty ? (c.company.isEmpty ? c.origin : c.company) : c.email)
                        .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
                Spacer()
                StatusPill(text: grade.rawValue, tint: gradeColor(grade))
            }
            if !reasons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(reasons, id: \.0) { r in
                        Text("\(r.0) +\(r.1)").font(BLFonts.mono(9.5, weight: .semibold)).foregroundColor(BLTheme.gold)
                            .padding(.vertical, 2).padding(.horizontal, 7).background(BLTheme.gold.opacity(0.1)).clipShape(Capsule())
                    }
                }
            }
        }
        .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }
}

// ============================================================================
// MARK: - Unified KPI rollup widget (dashboard) — paid + owned + earned
// ============================================================================

struct KPIRollupView: View {
    @EnvironmentObject var model: AppModel
    private func money(_ d: Double) -> String { "$" + String(format: d.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", d) }

    var body: some View {
        let k = model.kpiRollup
        VStack(alignment: .leading, spacing: 14) {
            Text("UNIFIED KPIs").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(1.2)
            if !k.hasAnyData {
                Panel(title: "Paid · Owned · Earned", icon: "square.stack.3d.up.fill") {
                    EmptyState(icon: "chart.line.uptrend.xyaxis",
                               title: "No marketing activity logged yet",
                               hint: "As you log ad spend, campaign-link clicks, and post engagement, this rolls them into one paid/owned/earned view — built only from what you record.")
                }
            } else {
                // Three channel-class cards.
                LazyVGrid(columns: blGridColumns(), spacing: 14) {
                    classCard("PAID", icon: "megaphone.fill",
                              lines: [("Spend", money(k.paidSpend)), ("Clicks", "\(k.paidClicks)"), ("Conv", "\(k.paidConversions)")])
                    classCard("OWNED", icon: "link",
                              lines: [("Clicks", "\(k.ownedClicks)"), ("Conv", "\(k.ownedConversions)"), ("Emails", "\(k.emailCampaigns)")])
                    classCard("EARNED", icon: "heart.fill",
                              lines: [("Engagement", "\(k.earnedEngagement)"), ("Posts", "\(k.earnedPosts)"), ("Reach (email)", "\(k.emailReachable)")])
                }
                // Blended outcomes (real math, nil -> honest dash).
                LazyVGrid(columns: blGridColumns(), spacing: 14) {
                    HeroStat(label: "Blended Clicks", value: "\(k.totalClicks)", icon: "cursorarrow.click.2")
                    HeroStat(label: "Blended Conv. Rate", value: k.blendedConvRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—", icon: "percent")
                    HeroStat(label: "Cost / Conversion", value: k.costPerConversion.map { money($0) } ?? "—", icon: "dollarsign.circle.fill")
                }
            }
        }
    }

    @ViewBuilder private func classCard(_ title: String, icon: String, lines: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                    .frame(width: 24, height: 24).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 7))
                Text(title).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.8)
            }
            ForEach(lines, id: \.0) { l in
                HStack {
                    Text(l.0).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    Spacer()
                    Text(l.1).font(BLFonts.mono(13, weight: .heavy)).foregroundColor(BLTheme.gold)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassBackground(radius: 16))
    }
}

// ============================================================================
// MARK: - Workflows (trigger → condition → action)
// ============================================================================

struct WorkflowScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var editing: Workflow?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Workflows",
                             subtitle: "Automate the busywork: when something happens, check a condition, take an action. Every rule ships OFF until you arm it.")

                Panel(title: "Your automations (\(model.workflows.count))", icon: "gearshape.2.fill") {
                    HStack {
                        GoldButton(label: "New workflow", icon: "plus") { editing = Workflow() }
                        Spacer()
                    }
                    if model.workflows.isEmpty {
                        EmptyState(icon: "arrow.triangle.branch",
                                   title: "No workflows yet",
                                   hint: "Build a trigger → condition → action rule. Example: when a new lead has a score ≥ 70, compose a personalized email for you to send.")
                    } else {
                        // Score the contact pool ONCE for the whole list, not once per workflow row.
                        let scored = model.scoredContacts(prefs.leadScoreWeights)
                        VStack(spacing: 10) { ForEach(model.workflows) { wf in row(wf, scored: scored) } }
                    }
                }
            }
            .padding(26)
        }
        .sheet(item: $editing) { wf in
            WorkflowEditor(workflow: wf) { saved in model.upsertWorkflow(saved); editing = nil } cancel: { editing = nil }
                .environmentObject(model)
                .sheetCloseBar()
        }
    }

    @ViewBuilder private func row(_ wf: Workflow, scored: [(contact: Contact, score: Int)]) -> some View {
        let count = WorkflowEngine.wouldAct(wf, over: scored)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: wf.trigger.icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.inkOnGold)
                    .frame(width: 30, height: 30).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text(wf.name.isEmpty ? "Untitled workflow" : wf.name).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("\(wf.trigger.rawValue) → \(wf.condField.rawValue) → \(wf.action.rawValue)")
                        .font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
                Spacer()
                StatusPill(text: wf.enabled ? "ARMED" : "OFF", tint: wf.enabled ? BLTheme.green : BLTheme.sub)
                IconButton(system: "pencil") { editing = wf }
                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteWorkflow(wf) }
            }
            HStack(spacing: 8) {
                Image(systemName: "person.2.fill").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.gold)
                Text(wf.enabled
                     ? "\(count) contact\(count == 1 ? "" : "s") match right now"
                     : "Arm to preview matching contacts")
                    .font(BLFonts.mono(10.5, weight: .semibold)).foregroundColor(wf.enabled ? BLTheme.gold : BLTheme.sub)
            }
            Text(wf.action.honestNote).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(wf.enabled ? BLTheme.green.opacity(0.4) : BLTheme.stroke, lineWidth: 1))
    }
}

struct WorkflowEditor: View {
    @State var workflow: Workflow
    let save: (Workflow) -> Void
    let cancel: () -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Workflow").font(BLFonts.display(22, weight: .semibold)).foregroundColor(BLTheme.text)

                Field(title: "Name", text: $workflow.name, prompt: "Hot lead welcome")

                Panel(title: "When (trigger)", icon: "bolt.fill") {
                    Picker("", selection: $workflow.trigger) {
                        ForEach(WFTrigger.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().tint(BLTheme.gold)
                    if workflow.trigger == .leadScoreAbove {
                        Stepper("Score reaches \(workflow.triggerThreshold)", value: $workflow.triggerThreshold, in: 1...100, step: 5)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                    }
                    if workflow.trigger == .inSegment {
                        Picker("Segment", selection: Binding(get: { workflow.triggerSegmentID ?? model.segments.first?.id }, set: { workflow.triggerSegmentID = $0 })) {
                            ForEach(model.segments) { s in Text(s.name.isEmpty ? "Untitled" : s.name).tag(Optional(s.id)) }
                        }.tint(BLTheme.gold)
                        if model.segments.isEmpty {
                            Text("No segments yet — build one in Audience first.").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }
                }

                Panel(title: "If (condition)", icon: "line.3.horizontal.decrease.circle.fill") {
                    Picker("", selection: $workflow.condField) {
                        ForEach(WFCondField.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().tint(BLTheme.gold)
                    if workflow.condField.needsValue {
                        Field(title: "Value", text: $workflow.condValue,
                              prompt: workflow.condField == .scoreAtLeast ? "70" : "e.g. dental / Austin")
                    }
                }

                Panel(title: "Then (action)", icon: "play.fill") {
                    Picker("", selection: $workflow.action) {
                        ForEach(WFAction.allCases) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().tint(BLTheme.gold)
                    if workflow.action == .addTag {
                        Field(title: "Tag", text: $workflow.actionValue, prompt: "vip")
                    } else if workflow.action == .notify || workflow.action == .flagForReview {
                        Field(title: "Message / note", text: $workflow.actionValue, prompt: "Follow up within 24h")
                    } else if workflow.action == .enrollJourney {
                        Field(title: "Journey name", text: $workflow.actionValue, prompt: "Welcome series")
                    }
                    Label(workflow.action.honestNote, systemImage: "info.circle.fill")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle(isOn: $workflow.enabled) {
                    Text("Arm this workflow").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                }.tint(BLTheme.green)

                HStack {
                    GhostButton(label: "Cancel") { cancel() }
                    Spacer()
                    GoldButton(label: "Save workflow", icon: "checkmark") { save(workflow) }
                }
            }
            .padding(24)
        }
        #if os(macOS)
        .frame(width: 520, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
    }
}

// ============================================================================
// MARK: - Attribution
// ============================================================================

struct AttributionScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var attModel: AttributionModel = .linear
    @State private var journeySteps: [String] = []
    @State private var stepInput = ""
    @State private var journeyLabel = ""

    /// Build conversion PATHS from the buyer's OWN logged data. Single-touch paths come from
    /// converted UTM links + ad campaigns; MULTI-TOUCH ordered paths come from journeys the operator
    /// logged below. Nothing is inferred where we don't have ordering data.
    private var paths: [[Touch]] {
        var out: [[Touch]] = []
        for l in model.links where l.conversions > 0 {
            let ch = l.source.isEmpty ? "(direct)" : l.source.lowercased()
            for _ in 0..<l.conversions { out.append([Touch(channel: ch, campaign: l.campaign, order: 0)]) }
        }
        for a in model.adCampaigns where a.loggedConversions > 0 {
            let ch = a.provider.rawValue.lowercased()
            for _ in 0..<a.loggedConversions { out.append([Touch(channel: ch, campaign: a.name, order: 0)]) }
        }
        for j in model.conversionPaths where !j.steps.isEmpty {
            out.append(j.steps.enumerated().map { Touch(channel: $0.element.lowercased(), campaign: j.label, order: $0.offset) })
        }
        return out
    }
    private var hasMultiTouch: Bool { model.conversionPaths.contains { $0.steps.count > 1 } }
    private var ranked: [(channel: String, credit: Double)] { AttributionEngine.ranked(paths: paths, model: attModel) }
    private var totalConversions: Int { paths.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Attribution",
                             subtitle: "Credit your conversions across channels — built only from the clicks and conversions you logged, plus any source you connect.")

                // Connect your own GA / ad accounts (honest-empty until real data syncs).
                DataSourcesPanel()

                // Log a real multi-touch conversion journey (ordered channels → one conversion).
                Panel(title: "Log a conversion journey", icon: "point.topleft.down.to.point.bottomright.curvepath") {
                    VStack(alignment: .leading, spacing: 10) {
                        if !journeySteps.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(Array(journeySteps.enumerated()), id: \.offset) { i, s in
                                    HStack(spacing: 3) {
                                        Text(s).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                        if i < journeySteps.count - 1 { Image(systemName: "arrow.right").font(.system(size: 8)).foregroundColor(BLTheme.sub) }
                                    }.padding(.horizontal, 7).padding(.vertical, 3).background(BLTheme.bg2).clipShape(Capsule())
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            Field(title: "", text: $stepInput, prompt: "Channel (e.g. instagram, email, google ads)")
                            GhostButton(label: "Add step", icon: "plus") {
                                let s = stepInput.trimmingCharacters(in: .whitespaces)
                                if !s.isEmpty { journeySteps.append(s); stepInput = "" }
                            }
                        }
                        HStack(spacing: 8) {
                            Field(title: "", text: $journeyLabel, prompt: "Label (optional)")
                            GoldButton(label: "Save journey", icon: "tray.and.arrow.down.fill") {
                                guard !journeySteps.isEmpty else { return }
                                model.addConversionPath(ConversionPath(label: journeyLabel, steps: journeySteps))
                                journeySteps = []; journeyLabel = ""
                            }.opacity(journeySteps.isEmpty ? 0.5 : 1).disabled(journeySteps.isEmpty)
                            if !journeySteps.isEmpty {
                                GhostButton(label: "Clear", icon: "xmark") { journeySteps = [] }
                            }
                        }
                        if !model.conversionPaths.isEmpty {
                            Text("\(model.conversionPaths.count) logged journey\(model.conversionPaths.count == 1 ? "" : "s") feeding multi-touch + data-driven attribution.")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }
                }

                if paths.isEmpty {
                    Panel(title: "Channel credit", icon: "arrow.triangle.merge") {
                        EmptyState(icon: "chart.pie",
                                   title: "No conversions logged yet",
                                   hint: "Log real conversions on your campaign links (Campaign Links) and ad campaigns (Ad Campaigns). Attribution distributes that real credit — it never models conversions you didn't record.")
                    }
                } else {
                    Panel(title: "Model", icon: "slider.horizontal.3") {
                        Picker("", selection: $attModel) {
                            ForEach(AttributionModel.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.menu).labelsHidden().tint(BLTheme.gold)
                        Text(attModel.blurb).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }

                    Panel(title: "Channel credit · \(totalConversions) conversions", icon: "chart.bar.xaxis") {
                        let maxC = max(0.0001, ranked.map { $0.credit }.max() ?? 1)
                        VStack(spacing: 12) {
                            ForEach(ranked, id: \.channel) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(item.channel.capitalized).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                        Spacer()
                                        Text(String(format: "%.2f conv · %.0f%%", item.credit, item.credit / Double(totalConversions) * 100))
                                            .font(BLFonts.mono(10.5, weight: .semibold)).foregroundColor(BLTheme.gold)
                                    }
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(BLTheme.bg2).frame(height: 8)
                                            Capsule().fill(BLTheme.goldGrad).frame(width: geo.size.width * CGFloat(item.credit / maxC), height: 8)
                                        }
                                    }.frame(height: 8)
                                }
                            }
                        }
                        Text(hasMultiTouch
                             ? "Includes your logged multi-touch journeys. Data-driven weights each channel by how often it appears across your converting paths — computed only from data you recorded, never invented."
                             : "These are single-touch paths from logged link/ad conversions. Log a multi-touch journey above to unlock true multi-touch + data-driven credit — we never invent a journey.")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(26)
        }
    }
}

// ============================================================================
// MARK: - Landing-page A/B
// ============================================================================

struct LandingABScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: LandingTest?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Landing A/B",
                             subtitle: "Pit two of your generated pages against each other. Winners are called only on real, sufficient logged data.")

                Panel(title: "Tests (\(model.landingTests.count))", icon: "rectangle.split.2x1.fill") {
                    HStack { GoldButton(label: "New A/B test", icon: "plus") { editing = newTest() }; Spacer() }
                    if model.landingTests.isEmpty {
                        EmptyState(icon: "rectangle.split.2x1",
                                   title: "No A/B tests yet",
                                   hint: "Generate a couple of landing pages in Site Studio, then create a test, log the views and conversions you see, and the studio calls the winner when the data is conclusive.")
                    } else {
                        VStack(spacing: 12) { ForEach(model.landingTests) { t in row(t) } }
                    }
                }
            }
            .padding(26)
        }
        .sheet(item: $editing) { t in
            LandingTestEditor(test: t) { saved in model.upsertLandingTest(saved); editing = nil } cancel: { editing = nil }
                .environmentObject(model)
                .sheetCloseBar()
        }
    }

    private func newTest() -> LandingTest {
        var t = LandingTest(name: "")
        t.variants = [LandingVariant(label: "A"), LandingVariant(label: "B")]
        return t
    }

    @ViewBuilder private func row(_ t: LandingTest) -> some View {
        let leader = LandingABEngine.leader(t)
        let conclusive = LandingABEngine.isConclusive(t)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(t.name.isEmpty ? "Untitled test" : t.name).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                if leader == nil {
                    StatusPill(text: "NO DATA", tint: BLTheme.sub)
                } else if conclusive {
                    StatusPill(text: "WINNER: \(leader!.label)", tint: BLTheme.green)
                } else {
                    StatusPill(text: "COLLECTING", tint: BLTheme.gold)
                }
                IconButton(system: "pencil") { editing = t }
                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteLandingTest(t) }
            }
            ForEach(t.variants) { v in
                HStack(spacing: 10) {
                    Text(v.label).font(BLFonts.mono(13, weight: .heavy)).foregroundColor(BLTheme.inkOnGold)
                        .frame(width: 26, height: 26).background(BLTheme.goldGrad).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.siteName.isEmpty ? "(no page linked)" : v.siteName).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                        Text("\(v.views) views · \(v.conversions) conv").font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.sub)
                    }
                    Spacer()
                    Text(v.conversionRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—")
                        .font(BLFonts.mono(14, weight: .heavy)).foregroundColor(leader?.id == v.id && conclusive ? BLTheme.green : BLTheme.gold)
                }
                .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
            }
            if let lift = LandingABEngine.leaderLift(t), leader != nil {
                Text(conclusive
                     ? String(format: "Variant %@ wins by %.0f%% relative lift.", leader!.label, lift * 100)
                     : String(format: "%@ is ahead by %.0f%%, but keep collecting — needs ≥100 views per variant to call it.", leader!.label, lift * 100))
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(conclusive ? BLTheme.green : BLTheme.sub)
            }
        }
        .padding(12).background(BLTheme.panelHi).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
    }
}

struct LandingTestEditor: View {
    @State var test: LandingTest
    @State private var validationMessage = ""
    let save: (LandingTest) -> Void
    let cancel: () -> Void
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("A/B Test").font(BLFonts.display(22, weight: .semibold)).foregroundColor(BLTheme.text)
                Field(title: "Test name", text: $test.name, prompt: "Hero headline test")
                Field(title: "Conversion goal", text: $test.goal, prompt: "Form submit")

                ForEach($test.variants) { $v in
                    Panel(title: "Variant \(v.label)", icon: "doc.richtext") {
                        Picker("Page", selection: Binding(get: { v.siteID }, set: { id in
                            v.siteID = id
                            v.siteName = model.sites.first { $0.id == id }?.name ?? ""
                        })) {
                            Text("(none)").tag(Optional<UUID>.none)
                            ForEach(model.sites) { s in Text(s.name.isEmpty ? "Untitled page" : s.name).tag(Optional(s.id)) }
                        }.tint(BLTheme.gold)
                        if model.sites.isEmpty {
                            Text("No generated pages yet — make some in Site Studio.").font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                        HStack(spacing: 14) {
                            stepperBlock(label: "Views", value: $v.views, step: 10, tint: BLTheme.gold)
                            stepperBlock(label: "Conversions", value: $v.conversions, step: 1, tint: BLTheme.green)
                        }
                        Text("Enter the real numbers from your own analytics. Conversions can't exceed views.")
                            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }

                HStack {
                    GhostButton(label: "Cancel") { cancel() }
                    Spacer()
                    GoldButton(label: "Save test", icon: "checkmark") {
                        guard variantsHaveDistinctPages else {
                            validationMessage = "Link every variant to a different generated page before saving."
                            return
                        }
                        validationMessage = ""
                        // Guard honesty: conversions never exceed views (no impossible rates).
                        for i in test.variants.indices { test.variants[i].conversions = min(test.variants[i].conversions, test.variants[i].views) }
                        save(test)
                    }
                    .disabled(!variantsHaveDistinctPages)
                }
                if !validationMessage.isEmpty || !variantsHaveDistinctPages {
                    Text(validationMessage.isEmpty ? "Link every variant to a different generated page before saving." : validationMessage)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
        #if os(macOS)
        .frame(width: 520, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
    }

    private var variantsHaveDistinctPages: Bool {
        let ids = test.variants.compactMap(\.siteID)
        return ids.count == test.variants.count && Set(ids).count == ids.count
    }

    @ViewBuilder private func stepperBlock(label: String, value: Binding<Int>, step: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            HStack(spacing: 8) {
                Button { value.wrappedValue = max(0, value.wrappedValue - step) } label: { Image(systemName: "minus.circle.fill").foregroundColor(BLTheme.sub) }.buttonStyle(.plain)
                Text("\(value.wrappedValue)").font(BLFonts.mono(16, weight: .heavy)).foregroundColor(tint).frame(minWidth: 44)
                Button { value.wrappedValue += step } label: { Image(systemName: "plus.circle.fill").foregroundColor(tint) }.buttonStyle(.plain)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif // circuit-convert
