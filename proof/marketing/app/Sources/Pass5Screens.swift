#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — PASS 5 screens (tier 3/4/5).
// Multichannel Campaigns · ABM Playbooks · Lookalikes · Referrals · Strategy Roadmap ·
// AEO Citation Checker · Security Log · AI Creative Ideation (flagship).
// All on the buyer's OWN data; honest empty states; nothing fabricated or auto-sent.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

private func money(_ d: Double) -> String { "$" + String(format: d.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.2f", d) }
private func pct(_ d: Double) -> String { String(format: "%.1f%%", d * 100) }
private let df: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; return f }()

// A reusable numeric stepper-field matching the brand (logged-data entry).
private struct LogField: View {
    let title: String; @Binding var value: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            HStack(spacing: 6) {
                TextField("0", value: $value, format: .number).textFieldStyle(.plain)
                    .font(BLFonts.mono(14, weight: .bold)).foregroundColor(BLTheme.text).frame(width: 64)
                    .padding(.vertical, 7).padding(.horizontal, 9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                Stepper("", value: $value, in: 0...1_000_000).labelsHidden()
            }
        }
    }
}
private struct MoneyField: View {
    let title: String; @Binding var value: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
            TextField("0", value: $value, format: .number).textFieldStyle(.plain)
                .font(BLFonts.mono(14, weight: .bold)).foregroundColor(BLTheme.text).frame(width: 90)
                .padding(.vertical, 7).padding(.horizontal, 9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
        }
    }
}

// ============================================================================
// MARK: - Multichannel Campaigns
// ============================================================================

struct MCampaignScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: MCampaign?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ScreenHeader(title: "Campaigns",
                                 subtitle: "One campaign across email, social, ads, and landing pages — rolled up from the metrics you log.")
                    Spacer()
                    GoldButton(label: "New campaign", icon: "plus") { editing = MCampaign() }
                }
                if model.mcampaigns.isEmpty {
                    Panel(title: "Your campaigns", icon: "rectangle.3.group.fill") {
                        EmptyState(icon: "rectangle.3.group",
                                   title: "No multichannel campaigns yet",
                                   hint: "Create a campaign, add the channels you're running, and log what each one actually produced. Everything rolls up here — no estimated reach, only your numbers.")
                    }
                } else {
                    ForEach(model.mcampaigns) { c in card(c) }
                }
            }.padding(26)
        }
        .sheet(item: $editing) { c in MCampaignEditor(campaign: c).environmentObject(model).sheetCloseBar() }
    }

    @ViewBuilder private func card(_ c: MCampaign) -> some View {
        let status = MCampaignEngine.status(c)
        let tint: Color = status == "Live" ? BLTheme.green : (status == "Scheduled" ? BLTheme.gold : BLTheme.sub)
        Panel(title: c.name.isEmpty ? "(untitled campaign)" : c.name, icon: "rectangle.3.group.fill") {
            HStack(spacing: 8) {
                StatusPill(text: status, tint: tint)
                Text("\(df.string(from: c.start)) → \(df.string(from: c.end))").font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.sub)
                Spacer()
                GhostButton(label: "Edit", icon: "pencil") { editing = c }
                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteMCampaign(c) }
            }
            // progress bar
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(BLTheme.bg2).frame(height: 6)
                    Capsule().fill(BLTheme.goldGrad).frame(width: g.size.width * MCampaignEngine.progress(c), height: 6)
                }
            }.frame(height: 6)
            // rollup
            if MCampaignEngine.hasAnyData(c) {
                Text(DemoMode.active ? "LOGGED SAMPLE RESULTS · FICTIONAL DEMO CAMPAIGN" : "LOGGED RESULTS · FROM YOUR CHANNEL REPORTS")
                    .font(BLFonts.mono(9, weight: .bold))
                    .foregroundColor(DemoMode.active ? BLTheme.gold : BLTheme.sub)
                    .tracking(0.7)
                    .accessibilityIdentifier("demo.proof.campaign.logged-results")
                LazyVGrid(columns: blGridColumns(minItemWidth: 120, spacing: 12, macColumns: 4), spacing: 12) {
                    mini("Reach", "\(MCampaignEngine.reach(c))")
                    mini("Clicks", "\(MCampaignEngine.clicks(c))")
                    mini("Conv", "\(MCampaignEngine.conversions(c))")
                    mini("Spend", money(MCampaignEngine.spend(c)))
                    mini("CTR", MCampaignEngine.ctr(c).map(pct) ?? "—")
                    mini("CPA", MCampaignEngine.cpa(c).map(money) ?? "—")
                    mini("Planned units", "\(c.entries.reduce(0) { $0 + max(0, $1.planned) })")
                    mini("Objective", c.objective)
                }
            } else {
                Text("No results logged yet. Edit the campaign and enter what each channel produced.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            // channel chips
            if !c.entries.isEmpty {
                HStack(spacing: 6) {
                    ForEach(c.entries) { e in
                        HStack(spacing: 4) {
                            Image(systemName: e.kind.icon).font(.system(size: 9, weight: .bold))
                            Text(e.kind.rawValue).font(BLFonts.mono(9.5, weight: .semibold))
                        }.foregroundColor(BLTheme.gold).padding(.vertical, 3).padding(.horizontal, 8)
                            .background(BLTheme.gold.opacity(0.1)).clipShape(Capsule())
                    }
                }
            }
        }
    }
    @ViewBuilder private func mini(_ l: String, _ v: String) -> some View {
        VStack(spacing: 3) {
            Text(v).font(BLFonts.mono(16, weight: .heavy)).foregroundColor(BLTheme.gold).lineLimit(1).minimumScaleFactor(0.6)
            Text(l.uppercased()).font(.system(size: 8.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
        }.frame(maxWidth: .infinity).padding(.vertical, 9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MCampaignEditor: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var model: AppModel
    @State var campaign: MCampaign
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Campaign").font(BLFonts.display(20, weight: .semibold)).foregroundStyle(BLTheme.goldText); Spacer()
                IconButton(system: "xmark") { dismiss() } }.padding(18)
            Divider().overlay(BLTheme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Field(title: "Campaign name", text: $campaign.name, prompt: "Spring launch")
                    Field(title: "Objective", text: $campaign.objective, prompt: "Awareness / Leads / Sales")
                    HStack(spacing: 14) {
                        DatePicker("Start", selection: $campaign.start, displayedComponents: .date).datePickerStyle(.field)
                        DatePicker("End", selection: $campaign.end, displayedComponents: .date).datePickerStyle(.field)
                    }.font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)

                    HStack { Text("CHANNELS").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(1)
                        Spacer()
                        Menu {
                            ForEach(MChannelKind.allCases) { k in
                                Button(k.rawValue) { campaign.entries.append(MChannelEntry(kind: k)) }
                            }
                        } label: { Label("Add channel", systemImage: "plus.circle.fill") }
                    }
                    if campaign.entries.isEmpty {
                        Text("Add the channels this campaign runs on, then log their real results.")
                            .font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                    ForEach($campaign.entries) { $e in channelRow($e) }
                    GoldButton(label: "Save campaign", fill: true, icon: "checkmark") {
                        model.upsertMCampaign(campaign); dismiss()
                    }.padding(.top, 6)
                }.padding(18)
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
    }
    @ViewBuilder private func channelRow(_ e: Binding<MChannelEntry>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: e.wrappedValue.kind.icon).foregroundColor(BLTheme.gold)
                Text(e.wrappedValue.kind.rawValue).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                IconButton(system: "trash", tint: BLTheme.danger) { campaign.entries.removeAll { $0.id == e.wrappedValue.id } }
            }
            TextField("Asset / note (which post, page, or ad set)", text: e.assetRef).textFieldStyle(.roundedBorder).font(.system(size: 11))
            // Operator-logged metrics ONLY.
            LazyVGrid(columns: blGridColumns(), spacing: 10) {
                LogField(title: "Planned units", value: e.planned)
                LogField(title: "Reach", value: e.loggedReach)
                LogField(title: "Clicks", value: e.loggedClicks)
                LogField(title: "Conv", value: e.loggedConversions)
            }
            MoneyField(title: "Spend ($)", value: e.spend)
        }.padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
    }
}

// ============================================================================
// MARK: - ABM Playbooks
// ============================================================================

struct ABMScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: ABMAccount?
    private func tierColor(_ t: ABMTier) -> Color {
        switch t { case .strategic: return BLTheme.gold; case .target: return BLTheme.green; case .nurture: return Color.blue; case .unscored: return BLTheme.sub }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ScreenHeader(title: "ABM Playbooks",
                                 subtitle: "Target accounts → a per-account multichannel plan. Priority is computed from the firmographics you enter — blank accounts score nothing.")
                    Spacer()
                    GoldButton(label: "New account", icon: "plus") { var a = ABMAccount(); a.plays = ABMEngine.starterPlays(); editing = a }
                }
                if model.abmAccounts.isEmpty {
                    Panel(title: "Target accounts", icon: "scope") {
                        EmptyState(icon: "building.2.crop.circle",
                                   title: "No target accounts yet",
                                   hint: "Add the businesses you want to win, enter what you know about them, and build a week-by-week play across channels. Priority is transparent math on your inputs.")
                    }
                } else {
                    ForEach(model.abmAccounts.sorted { ABMEngine.priority($0) > ABMEngine.priority($1) }) { a in card(a) }
                }
            }.padding(26)
        }
        .sheet(item: $editing) { a in ABMEditor(account: a).environmentObject(model).sheetCloseBar() }
    }
    @ViewBuilder private func card(_ a: ABMAccount) -> some View {
        let tier = ABMEngine.tier(a); let p = ABMEngine.priority(a)
        Panel(title: a.company.isEmpty ? "(unnamed account)" : a.company, icon: "scope") {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tierColor(tier).opacity(0.16)).frame(width: 46, height: 46)
                    Text("\(p)").font(BLFonts.mono(17, weight: .heavy)).foregroundColor(tierColor(tier))
                }
                VStack(alignment: .leading, spacing: 2) {
                    StatusPill(text: tier.rawValue, tint: tierColor(tier))
                    if !a.website.isEmpty { Text(a.website).font(BLFonts.mono(10)).foregroundColor(BLTheme.sub).lineLimit(1) }
                }
                Spacer()
                GhostButton(label: "Edit", icon: "pencil") { editing = a }
                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteABM(a) }
            }
            let reasons = ABMEngine.reasons(a)
            if !reasons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(reasons, id: \.0) { r in
                        Text("\(r.0) +\(r.1)").font(BLFonts.mono(9, weight: .semibold)).foregroundColor(BLTheme.gold)
                            .padding(.vertical, 2).padding(.horizontal, 7).background(BLTheme.gold.opacity(0.1)).clipShape(Capsule())
                    }
                }
            }
            if !a.plays.isEmpty {
                let done = a.plays.filter { $0.done }.count
                Text("PLAY · \(done)/\(a.plays.count) done").font(BLFonts.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                ForEach(a.plays.sorted { $0.week < $1.week }) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.done ? "checkmark.circle.fill" : "circle").foregroundColor(s.done ? BLTheme.green : BLTheme.sub)
                        Text("W\(s.week)").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.gold).frame(width: 26, alignment: .leading)
                        Image(systemName: s.channel.icon).font(.system(size: 10)).foregroundColor(BLTheme.sub)
                        Text(s.action).font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.text).strikethrough(s.done)
                        Spacer()
                    }.padding(.vertical, 2)
                }
            }
        }
    }
}

struct ABMEditor: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var model: AppModel
    @State var account: ABMAccount
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Account plan").font(BLFonts.display(20, weight: .semibold)).foregroundStyle(BLTheme.goldText); Spacer()
                IconButton(system: "xmark") { dismiss() } }.padding(18)
            Divider().overlay(BLTheme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Field(title: "Company", text: $account.company, prompt: "Greenfield Property Group")
                    Field(title: "Website", text: $account.website, prompt: "greenfieldpg.com")
                    HStack(spacing: 14) {
                        LogField(title: "Employees", value: $account.employees)
                        MoneyField(title: "Revenue ($M)", value: $account.revenueM)
                        LogField(title: "Linked contacts", value: $account.contactsLinked)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("INDUSTRY FIT").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                        Picker("", selection: $account.industryFit) {
                            Text("None").tag(0); Text("Low").tag(1); Text("Medium").tag(2); Text("High").tag(3)
                        }.pickerStyle(.segmented).labelsHidden()
                    }
                    Toggle(isOn: $account.hasChampion) { Text("Has an internal champion").font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text) }
                    let p = ABMEngine.priority(account)
                    HStack { Text("Live priority").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub); Spacer()
                        Text("\(p) · \(ABMEngine.tier(account).rawValue)").font(BLFonts.mono(13, weight: .heavy)).foregroundColor(BLTheme.gold) }
                        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))

                    HStack { Text("MULTICHANNEL PLAY").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(1)
                        Spacer(); Button { account.plays.append(ABMPlayStep(week: (account.plays.map { $0.week }.max() ?? 0) + 1)) } label: { Label("Add step", systemImage: "plus.circle.fill") } }
                    ForEach($account.plays) { $s in
                        HStack(spacing: 8) {
                            Toggle("", isOn: $s.done).labelsHidden()
                            Stepper("W\(s.week)", value: $s.week, in: 1...52).font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.gold).fixedSize()
                            Picker("", selection: $s.channel) { ForEach(MChannelKind.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 110)
                            TextField("action", text: $s.action).textFieldStyle(.roundedBorder).font(.system(size: 11))
                            IconButton(system: "trash", tint: BLTheme.danger) { account.plays.removeAll { $0.id == s.id } }
                        }
                    }
                    TextField("Notes", text: $account.notes).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    GoldButton(label: "Save account", fill: true, icon: "checkmark") { model.upsertABM(account); dismiss() }.padding(.top, 6)
                }.padding(18)
            }
        }
        #if os(macOS)
        .frame(width: 600, height: 680)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
    }
}

// ============================================================================
// MARK: - Lookalikes
// ============================================================================

struct LookalikeScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var seedSegment: UUID?     // a saved segment used as the seed
    @State private var topN = 25

    private var seed: [Contact] {
        guard let id = seedSegment, let seg = model.segments.first(where: { $0.id == id }) else { return [] }
        return SegEngine.evaluate(seg, over: model.allContacts)
    }
    private var ranked: [(contact: Contact, score: Double)] {
        Array(LookalikeEngine.rank(seed: seed, candidates: model.allContacts).prefix(topN))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Lookalikes",
                             subtitle: "Find contacts most similar to a seed audience — modeled from your own contacts' industry, city, and contactability. No third-party audience.")
                if model.segments.isEmpty {
                    Panel(title: "Seed", icon: "person.3.sequence.fill") {
                        EmptyState(icon: "person.crop.circle.badge.plus",
                                   title: "Build a seed segment first",
                                   hint: "Lookalikes need a starting group. Create a segment of your best customers in Audience, then come back to find more like them.")
                    }
                } else {
                    Panel(title: "Seed audience", icon: "target") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Seed segment", selection: $seedSegment) {
                                Text("Choose a segment…").tag(UUID?.none)
                                ForEach(model.segments) { Text($0.name.isEmpty ? "(unnamed)" : $0.name).tag(Optional($0.id)) }
                            }
                            HStack {
                                Text("Seed size: \(seed.count)").font(BLFonts.mono(11, weight: .semibold)).foregroundColor(BLTheme.sub)
                                Spacer()
                                Stepper("Show top \(topN)", value: $topN, in: 5...200, step: 5).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.text)
                            }
                            if seedSegment != nil && seed.isEmpty {
                                Text("That segment matches no contacts right now — pick another or add contacts.")
                                    .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.danger)
                            }
                        }
                    }
                    if seedSegment == nil {
                        Panel(title: "Lookalikes", icon: "person.3.fill") {
                            EmptyState(icon: "person.3", title: "Pick a seed to begin", hint: "Choose a seed segment above. We never invent a lookalike audience — matches come only from contacts you already have.")
                        }
                    } else if ranked.isEmpty {
                        Panel(title: "Lookalikes", icon: "person.3.fill") {
                            EmptyState(icon: "person.crop.circle.badge.questionmark", title: "No lookalikes",
                                       hint: "Your seed needs industry or city signal to model against. Make sure those fields are filled on your seed contacts.")
                        }
                    } else {
                        Panel(title: "Closest matches (\(ranked.count))", icon: "person.3.fill") {
                            ForEach(ranked, id: \.contact.id) { item in
                                HStack(spacing: 10) {
                                    ZStack { Circle().fill(BLTheme.gold.opacity(0.14)).frame(width: 40, height: 40)
                                        Text(pct(item.score)).font(BLFonts.mono(11, weight: .heavy)).foregroundColor(BLTheme.gold) }
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.contact.name.isEmpty ? "(no name)" : item.contact.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                        Text([item.contact.industry, item.contact.city].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                                    }
                                    Spacer()
                                    if !item.contact.email.isEmpty { Image(systemName: "envelope.fill").foregroundColor(BLTheme.sub).font(.system(size: 10)) }
                                    if !item.contact.phone.isEmpty { Image(systemName: "phone.fill").foregroundColor(BLTheme.sub).font(.system(size: 10)) }
                                }.padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                            }
                        }
                    }
                }
            }.padding(26)
        }
    }
}

// ============================================================================
// MARK: - Referral Program
// ============================================================================

struct ReferralScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: ReferralProgram?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    ScreenHeader(title: "Referrals",
                                 subtitle: "Build a referral program and track real advocate performance — every number is a referral or conversion you logged.")
                    Spacer()
                    GoldButton(label: "New program", icon: "plus") { editing = ReferralProgram() }
                }
                if model.referralPrograms.isEmpty {
                    Panel(title: "Programs", icon: "gift.fill") {
                        EmptyState(icon: "gift",
                                   title: "No referral programs yet",
                                   hint: "Define a reward, share the message with your customers, and log who referred whom. Conversion rate and rewards owed are exact math on your logged data.")
                    }
                } else {
                    ForEach(model.referralPrograms) { p in card(p) }
                }
            }.padding(26)
        }
        .sheet(item: $editing) { p in ReferralEditor(program: p).environmentObject(model).sheetCloseBar() }
    }
    @ViewBuilder private func card(_ p: ReferralProgram) -> some View {
        Panel(title: p.name.isEmpty ? "(unnamed program)" : p.name, icon: "gift.fill") {
            HStack {
                StatusPill(text: p.rewardType.rawValue + " · " + money(p.rewardPerConversion), tint: BLTheme.gold)
                Spacer()
                GhostButton(label: "Edit", icon: "pencil") { editing = p }
                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteReferral(p) }
            }
            LazyVGrid(columns: blGridColumns(minItemWidth: 120, spacing: 12, macColumns: 4), spacing: 12) {
                mini("Advocates", "\(p.records.count)")
                mini("Referrals", "\(ReferralEngine.totalReferrals(p.records))")
                mini("Converted", "\(ReferralEngine.totalConverted(p.records))")
                mini("Conv rate", ReferralEngine.conversionRate(p.records).map(pct) ?? "—")
            }
            HStack {
                Text("Rewards owed").font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                Spacer()
                Text(money(ReferralEngine.rewardOwed(p.records, perConversion: p.rewardPerConversion)))
                    .font(BLFonts.mono(14, weight: .heavy)).foregroundColor(BLTheme.green)
            }.padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            if !p.advocateMessage.isEmpty {
                Text("\u{201C}\(p.advocateMessage)\u{201D}").font(.system(size: 11.5, design: .rounded)).italic().foregroundColor(BLTheme.sub)
            }
        }
    }
    @ViewBuilder private func mini(_ l: String, _ v: String) -> some View {
        VStack(spacing: 3) { Text(v).font(BLFonts.mono(16, weight: .heavy)).foregroundColor(BLTheme.gold)
            Text(l.uppercased()).font(.system(size: 8.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5) }
            .frame(maxWidth: .infinity).padding(.vertical, 9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ReferralEditor: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var model: AppModel
    @State var program: ReferralProgram
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Referral program").font(BLFonts.display(20, weight: .semibold)).foregroundStyle(BLTheme.goldText); Spacer()
                IconButton(system: "xmark") { dismiss() } }.padding(18)
            Divider().overlay(BLTheme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Field(title: "Program name", text: $program.name, prompt: "Refer a friend")
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("REWARD TYPE").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                            Picker("", selection: $program.rewardType) { ForEach(ReferralReward.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
                        }
                        MoneyField(title: "Reward / conversion ($)", value: $program.rewardPerConversion)
                    }
                    Field(title: "Advocate message", text: $program.advocateMessage, prompt: "Refer a friend and you both get…")
                    HStack { Text("ADVOCATES").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(1)
                        Spacer(); Button { program.records.append(ReferralRecord()) } label: { Label("Add advocate", systemImage: "plus.circle.fill") } }
                    if program.records.isEmpty { Text("Add advocates and log their real referrals & conversions.").font(.system(size: 11.5, design: .rounded)).foregroundColor(BLTheme.sub) }
                    ForEach($program.records) { $r in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { TextField("Advocate name", text: $r.advocate).textFieldStyle(.roundedBorder).font(.system(size: 11))
                                IconButton(system: "trash", tint: BLTheme.danger) { program.records.removeAll { $0.id == r.id } } }
                            LazyVGrid(columns: blGridColumns(), spacing: 10) {
                                LogField(title: "Referrals", value: $r.referrals)
                                LogField(title: "Qualified", value: $r.qualified)
                                LogField(title: "Converted", value: $r.converted)
                            }
                        }.padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    GoldButton(label: "Save program", fill: true, icon: "checkmark") { model.upsertReferral(program); dismiss() }.padding(.top, 6)
                }.padding(18)
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 660)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
    }
}

// ============================================================================
// MARK: - Strategy Roadmap
// ============================================================================

// MARK: - CMO Advisor (next move from the buyer's own data)

struct CMOAdvisorScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs

    private var input: AdvisorInput {
        let contacts = model.allContacts
        let topChannel: String? = {
            var byChannel: [String: Int] = [:]
            for l in model.links where l.conversions > 0 {
                byChannel[l.source.isEmpty ? "(direct)" : l.source.lowercased(), default: 0] += l.conversions
            }
            return byChannel.max { $0.value < $1.value }?.key
        }()
        return AdvisorInput(
            contacts: contacts.count,
            leadsLast7: contacts.filter { $0.createdDaysAgo <= 7 }.count,
            activeJourneys: model.journeys.filter { $0.enabled }.count,
            loggedClicks: model.totalLoggedClicks,
            loggedConversions: model.totalLoggedConversions,
            spotlightsSent: model.spotlights.count,
            contentItems: model.contentLibrary.count,
            topChannel: topChannel,
            segments: model.segments.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "CMO Advisor",
                             subtitle: "Your fractional strategist — reads your own pipeline, journeys, and attribution and recommends the next move. Every recommendation shows the metric behind it.")
                let recs = AdvisorEngine.analyze(input)
                Panel(title: "Recommended next moves", icon: "brain.head.profile") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(recs) { r in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(r.title).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Spacer()
                                    Text("\(r.confidence)%").font(BLFonts.mono(10.5, weight: .semibold)).foregroundColor(BLTheme.gold)
                                }
                                Text(r.reasoning).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                                Text(r.backing).font(BLFonts.mono(9.5, weight: .semibold)).foregroundColor(BLTheme.sub.opacity(0.8))
                            }
                            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                        }
                    }
                }
            }
            .padding(28)
        }
    }
}

struct RoadmapScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var newTitle = ""
    @State private var newQuarter = 1
    @State private var newImpact = 5
    @State private var newEffort = 3
    @State private var newChannels: Set<String> = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Strategy Roadmap",
                             subtitle: "Plan your quarters. Items are ranked by leverage (impact ÷ effort) — your judgment, organized.")
                Panel(title: "Add an initiative", icon: "plus.rectangle.on.folder.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Field(title: "Title", text: $newTitle, prompt: "Launch referral program")
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("QUARTER").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                                Picker("", selection: $newQuarter) { ForEach(1...4, id: \.self) { Text("Q\($0)").tag($0) } }.pickerStyle(.segmented).labelsHidden().frame(width: 180)
                            }
                            Stepper("Impact \(newImpact)", value: $newImpact, in: 0...10).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.text).fixedSize()
                            Stepper("Effort \(newEffort)", value: $newEffort, in: 1...10).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.text).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("CHANNELS").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(["Email","Instagram","TikTok","X","Facebook","LinkedIn","Threads","Ads","Site"], id: \.self) { lane in
                                        let on = newChannels.contains(lane)
                                        Button { if on { newChannels.remove(lane) } else { newChannels.insert(lane) } } label: {
                                            Text(lane).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                                .foregroundColor(on ? BLTheme.inkOnGold : BLTheme.sub)
                                                .padding(.horizontal, 9).padding(.vertical, 4)
                                                .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                                                .clipShape(Capsule())
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        GoldButton(label: "Add", icon: "plus") {
                            let t = newTitle.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
                            model.upsertRoadItem(RoadItem(title: t, quarter: newQuarter, impact: newImpact, effort: newEffort,
                                                          channels: Array(newChannels).sorted()))
                            newTitle = ""; newChannels = []
                        }
                    }
                }
                if model.roadItems.isEmpty {
                    Panel(title: "Roadmap", icon: "map.fill") {
                        EmptyState(icon: "map", title: "No initiatives yet", hint: "Add the things you plan to do this year. Each quarter is sorted by impact-to-effort so the highest-leverage work rises to the top.")
                    }
                } else {
                    if let top = RoadmapEngine.topPick(model.roadItems) {
                        Panel(title: "Highest leverage now", icon: "bolt.fill") {
                            HStack { Text(top.title).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                Spacer(); Text("Q\(top.quarter) · impact \(top.impact)/effort \(top.effort)").font(BLFonts.mono(11, weight: .semibold)).foregroundColor(BLTheme.gold) }
                        }
                    }
                    let buckets = RoadmapEngine.byQuarter(model.roadItems)
                    ForEach(1...4, id: \.self) { q in
                        if let items = buckets[q], !items.isEmpty {
                            Panel(title: "Q\(q)", icon: "calendar") {
                                ForEach(items) { i in
                                    HStack(spacing: 10) {
                                        Button { var x = i; x.done.toggle(); model.upsertRoadItem(x) } label: {
                                            Image(systemName: i.done ? "checkmark.circle.fill" : "circle").foregroundColor(i.done ? BLTheme.green : BLTheme.sub)
                                        }.buttonStyle(.plain)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(i.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).strikethrough(i.done)
                                            Text("Leverage \(String(format: "%.1f", RoadmapEngine.score(i)))\(i.channels.isEmpty ? "" : " · " + i.channels.joined(separator: ", "))").font(BLFonts.mono(9.5)).foregroundColor(BLTheme.sub)
                                        }
                                        Spacer()
                                        IconButton(system: "trash", tint: BLTheme.danger) { model.deleteRoadItem(i) }
                                    }.padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }
            }.padding(26)
        }
    }
}

// ============================================================================
// MARK: - AEO Citation Checker (tier 4)
// ============================================================================

struct AEOScreen: View {
    @EnvironmentObject var prefs: Prefs
    @State private var pasted = ""
    @State private var brand = ""
    @State private var factsRaw = ""
    @State private var checked = false
    private var facts: [String] {
        var f = factsRaw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let b = brand.trimmingCharacters(in: .whitespaces)
        if !b.isEmpty { f.insert(b, at: 0) }
        return f
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "AI Citation Checker",
                             subtitle: "Paste an answer from ChatGPT / Gemini / Bing about your category and see, literally, whether your brand and key facts appear. No guessing whether an AI \u{201C}would\u{201D} cite you.")
                Panel(title: "What to check", icon: "doc.text.magnifyingglass") {
                    VStack(alignment: .leading, spacing: 10) {
                        Field(title: "Your brand", text: $brand, prompt: prefs.displayBrand)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("KEY FACTS (one per line)").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                            TextEditor(text: $factsRaw).font(.system(size: 12, design: .monospaced)).frame(height: 80)
                                .padding(6).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).foregroundColor(BLTheme.text)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("PASTE THE AI ANSWER / PAGE TEXT").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.6)
                            TextEditor(text: $pasted).font(.system(size: 12, design: .rounded)).frame(height: 150)
                                .padding(6).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).foregroundColor(BLTheme.text)
                        }
                        GoldButton(label: "Check citations", icon: "checkmark.seal") { checked = true }
                    }
                }
                if checked {
                    if pasted.trimmingCharacters(in: .whitespaces).isEmpty || facts.isEmpty {
                        Panel(title: "Results", icon: "list.bullet.clipboard") {
                            EmptyState(icon: "text.badge.xmark", title: "Nothing to check", hint: "Add your brand or some facts and paste the answer text, then check again.")
                        }
                    } else {
                        let bd = AEOEngine.breakdown(text: pasted, facts: facts)
                        let hits = bd.filter { $0.found }.count
                        Panel(title: "Results — \(hits)/\(facts.count) cited", icon: "list.bullet.clipboard.fill") {
                            ForEach(Array(bd.enumerated()), id: \.offset) { _, item in
                                HStack(spacing: 8) {
                                    Image(systemName: item.found ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundColor(item.found ? BLTheme.green : BLTheme.danger)
                                    Text(item.fact).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                                    Spacer()
                                    Text(item.found ? "Cited" : "Not found").font(BLFonts.mono(10, weight: .bold)).foregroundColor(item.found ? BLTheme.green : BLTheme.sub)
                                }.padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                            Text("Tip: if your brand isn't appearing, strengthen schema markup and the on-page facts the SEO Toolkit checks.")
                                .font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }
                }
            }.padding(26)
        }
    }
}

// ============================================================================
// MARK: - Security Log (tier 4)
// ============================================================================

struct SecurityLogScreen: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Security Log",
                             subtitle: "A tamper-evident, hash-chained record of sensitive actions in this app — sign-in, exports, and data deletion. Stored only on your \(PlatformWords.device).")
                let intact = SecurityLog.verify(model.auditLog)
                Panel(title: "Integrity", icon: intact ? "lock.shield.fill" : "exclamationmark.shield.fill") {
                    HStack(spacing: 10) {
                        Image(systemName: intact ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 22)).foregroundColor(intact ? BLTheme.green : BLTheme.danger)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(intact ? "Chain verified" : "Chain integrity FAILED").font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(intact ? BLTheme.green : BLTheme.danger)
                            Text("\(model.auditLog.count) event\(model.auditLog.count == 1 ? "" : "s") · SHA-256 linked").font(BLFonts.mono(10.5)).foregroundColor(BLTheme.sub)
                        }
                        Spacer()
                    }
                }
                if model.auditLog.isEmpty {
                    Panel(title: "Events", icon: "list.bullet.rectangle") {
                        EmptyState(icon: "shield.lefthalf.filled", title: "No events yet", hint: "Security-relevant actions are recorded here as you use the app. Each event is hash-chained to the previous one, so tampering is detectable.")
                    }
                } else {
                    Panel(title: "Events (newest first)", icon: "list.bullet.rectangle.fill") {
                        ForEach(model.auditLog.reversed()) { e in
                            HStack(spacing: 10) {
                                Image(systemName: icon(e.action)).foregroundColor(BLTheme.gold).frame(width: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(label(e.action)).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    if !e.detail.isEmpty { Text(e.detail).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1) }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(e.date, style: .date).font(BLFonts.mono(9.5)).foregroundColor(BLTheme.sub)
                                    Text(String(e.hash.prefix(10))).font(BLFonts.mono(9)).foregroundColor(BLTheme.sub.opacity(0.7))
                                }
                            }.padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                        }
                    }
                }
            }.padding(26)
        }
    }
    private func icon(_ a: String) -> String {
        switch a { case "sign_in": return "person.crop.circle.badge.checkmark"; case "sign_out": return "rectangle.portrait.and.arrow.right"
        case "export": return "square.and.arrow.up"; case "delete_account", "delete_all": return "trash.fill"; default: return "circle.fill" }
    }
    private func label(_ a: String) -> String {
        switch a { case "sign_in": return "Signed in"; case "sign_out": return "Signed out"; case "export": return "Exported data"
        case "delete_account", "delete_all": return "Deleted all data"; default: return a.replacingOccurrences(of: "_", with: " ").capitalized }
    }
}

// ============================================================================
// MARK: - AI Creative Ideation (tier-5 flagship)
// ============================================================================

private enum IdeationMode: String, Hashable {
    case concepts, captions
}

struct CreativeIdeationScreen: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var model: AppModel
    @State private var ideationMode: IdeationMode = .concepts
    @State private var brand = ""
    @State private var does = ""
    @State private var audience = ""
    @State private var goal = ""
    @State private var concepts: [CreativeConcept] = []
    @State private var working = false
    @State private var usedAI = false
    @State private var briefError = ""
    private let ideationTabs = [
        HubTab(id: IdeationMode.concepts, title: "Concepts", icon: "sparkles"),
        HubTab(id: IdeationMode.captions, title: "Captions", icon: "text.quote")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "AI Creative Ideation",
                             subtitle: "On-device Apple Intelligence proposes campaign concepts from your brand. No cloud, no subscription — and it never invents facts or results.")

                HubTabs(tabs: ideationTabs, selection: $ideationMode)

                if ideationMode == .captions {
                    AICaptionStudioPanel()
                } else {
                    // Honest availability banner.
                    availabilityBanner

                    Panel(title: "Your brief", icon: "lightbulb.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            Field(title: "Brand", text: $brand, prompt: prefs.displayBrand)
                            Field(title: "What you do", text: $does, prompt: prefs.defaultVertical.isEmpty ? "e.g. residential plumbing" : prefs.defaultVertical)
                            Field(title: "Target audience", text: $audience, prompt: "e.g. homeowners in Austin")
                            Field(title: "Primary goal", text: $goal, prompt: "e.g. more booked jobs")
                            HStack {
                                GoldButton(label: working ? "Thinking…" : "Generate concepts", icon: "sparkles") { generate() }
                                    .disabled(working)
                                if !concepts.isEmpty { GhostButton(label: "Clear", icon: "xmark") { clearConcepts() } }
                            }
                            if !briefError.isEmpty {
                                Text(briefError).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if !concepts.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: usedAI ? "cpu.fill" : "doc.text.fill").font(.system(size: 10)).foregroundColor(BLTheme.gold)
                            Text(usedAI ? "Generated on-device by Apple Intelligence" : "Template starters (on-device AI unavailable)")
                                .font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.sub)
                        }
                        ForEach(concepts) { c in conceptCard(c) }
                    }
                }
            }.padding(26)
                .onAppear(perform: hydrateSavedIdeation)
        }
    }

    @ViewBuilder private var availabilityBanner: some View {
        let avail = CreativeIdeation.availability()
        if case .unavailable(let reason) = avail {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundColor(BLTheme.gold)
                Text(reason).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                Spacer()
            }.padding(12).background(BLTheme.gold.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
        }
    }

    private func generate() {
        let b = (brand.isEmpty ? prefs.displayBrand : brand).trimmingCharacters(in: .whitespacesAndNewlines)
        let d = does.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = audience.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        var missing: [String] = []
        if b.isEmpty { missing.append("brand") }
        if d.isEmpty { missing.append("what you do") }
        if a.isEmpty { missing.append("target audience") }
        if g.isEmpty { missing.append("primary goal") }
        guard missing.isEmpty else {
            briefError = "Complete the brief before generating: \(missing.joined(separator: ", "))."
            return
        }
        briefError = ""
        working = true
        Task {
            if let ai = await CreativeIdeation.generate(brand: b, does: d, audience: a, goal: g) {
                await MainActor.run { persistGeneratedConcepts(ai, usedAI: true, brand: b, does: d, audience: a, goal: g) }
            } else {
                await MainActor.run {
                    let templated = CreativeIdeation.templates(brand: b, does: d, audience: a, goal: g)
                    persistGeneratedConcepts(templated, usedAI: false, brand: b, does: d, audience: a, goal: g)
                }
            }
        }
    }

    private func persistGeneratedConcepts(_ generated: [CreativeConcept], usedAI aiBacked: Bool, brand b: String, does d: String, audience a: String, goal g: String) {
        concepts = generated
        usedAI = aiBacked
        working = false
        model.saveCreativeIdeation(brand: b, does: d, audience: a, goal: g, concepts: generated, usedAI: aiBacked)
    }

    private func hydrateSavedIdeation() {
        guard concepts.isEmpty, let latest = model.creativeIdeations.first else { return }
        brand = latest.brand
        does = latest.does
        audience = latest.audience
        goal = latest.goal
        concepts = latest.concepts
        usedAI = latest.usedAI
    }

    private func clearConcepts() {
        concepts = []
        usedAI = false
        model.clearCreativeIdeations()
    }

    @ViewBuilder private func conceptCard(_ c: CreativeConcept) -> some View {
        Panel(title: c.angle, icon: "wand.and.stars") {
            if !c.hook.isEmpty {
                Text("\u{201C}\(c.hook)\u{201D}").font(BLFonts.display(18, weight: .medium)).foregroundStyle(BLTheme.goldText)
            }
            if !c.channels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(c.channels, id: \.self) { ch in
                        Text(ch).font(BLFonts.mono(9.5, weight: .semibold)).foregroundColor(BLTheme.gold)
                            .padding(.vertical, 2).padding(.horizontal, 8).background(BLTheme.gold.opacity(0.1)).clipShape(Capsule())
                    }
                }
            }
            if !c.copyStarter.isEmpty {
                Text(c.copyStarter).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                StatusPill(text: c.source, tint: c.source == "On-device AI" ? BLTheme.green : BLTheme.sub)
                Spacer()
                GhostButton(label: "Copy", icon: "doc.on.doc") {
                    let txt = "\(c.angle)\n\(c.hook)\nChannels: \(c.channels.joined(separator: ", "))\n\n\(c.copyStarter)"
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(txt, forType: .string)
                }
                GhostButton(label: "Make campaign", icon: "arrow.right.circle") {
                    var mc = MCampaign(); mc.name = c.angle; mc.objective = goal.isEmpty ? "Awareness" : goal
                    mc.entries = c.channels.compactMap { ch in
                        MChannelEntry(kind: kind(for: ch), assetRef: c.hook)
                    }
                    model.upsertMCampaign(mc)
                }
            }
        }
    }
    private func kind(for s: String) -> MChannelKind {
        let l = s.lowercased()
        if l.contains("email") { return .email }
        if l.contains("ad") { return .ads }
        if l.contains("land") { return .landing }
        return .social
    }
}

// ============================================================================
// MARK: - AI Caption Studio (Buffer gap: real on-device AI captions, template fallback)
// ============================================================================

struct AICaptionStudioPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var brief = ""
    @State private var tone: CaptionTone = .punchy
    @State private var platform: CaptionPlatform = .instagram
    @State private var variants: [CaptionVariant] = []
    @State private var working = false
    @State private var usedAI = false
    @State private var inputError = ""
    @State private var copiedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            availabilityBanner

            Panel(title: "AI captions", icon: "text.quote") {
                VStack(alignment: .leading, spacing: 12) {
                    Field(title: "What's the post about?", text: $brief, prompt: "Spring promo, new menu, grand opening...")
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("TONE").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                            Picker("", selection: $tone) { ForEach(CaptionTone.allCases) { Text($0.rawValue).tag($0) } }
                                .labelsHidden().tint(BLTheme.gold)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PLATFORM").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                            Picker("", selection: $platform) {
                                ForEach(CaptionPlatform.allCases) { p in
                                    Text("\(p.rawValue) · \(p.charLimit) chars").tag(p)
                                }
                            }.labelsHidden().tint(BLTheme.gold)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing: 10) {
                        GoldButton(label: working ? "Writing…" : "Generate with AI", icon: "sparkles") { generate() }
                            .disabled(working)
                        if working { ProgressView().controlSize(.small).tint(BLTheme.gold) }
                        if !variants.isEmpty && !working {
                            GhostButton(label: "Regenerate", icon: "arrow.clockwise") { generate() }
                            GhostButton(label: "Clear", icon: "xmark") { variants = []; usedAI = false }
                        }
                    }
                    if !inputError.isEmpty {
                        Text(inputError).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !variants.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: usedAI ? "cpu.fill" : "doc.text.fill").font(.system(size: 10)).foregroundColor(BLTheme.gold)
                    Text(usedAI ? "Generated on-device by Apple Intelligence" : "Template captions (on-device AI unavailable)")
                        .font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.sub)
                }
                ForEach(variants) { v in variantCard(v) }
            }

            if !model.captions.isEmpty {
                Panel(title: "Saved captions (\(model.captions.count))", icon: "books.vertical.fill") {
                    VStack(spacing: 8) {
                        ForEach(model.captions) { caption in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(caption.topic).font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
                                    Text(caption.text).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                                }
                                Spacer()
                                IconButton(system: "doc.on.doc") { copyText(caption.text) }
                                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteCaption(caption) }
                            }
                            .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                        }
                    }
                }
            }
        }
        .onAppear { tone = prefs.captionTone }
    }

    // Honest availability banner — same pattern as the Concepts tab.
    @ViewBuilder private var availabilityBanner: some View {
        let avail = AICaptionEngine.availability()
        if case .unavailable(let reason) = avail {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundColor(BLTheme.gold)
                Text(reason).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                Spacer()
            }.padding(12).background(BLTheme.gold.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.gold.opacity(0.25), lineWidth: 1))
        }
    }

    private func generate() {
        let b = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else {
            inputError = "Add a real topic or offer before generating captions."
            return
        }
        inputError = ""
        working = true
        let kit = BrandKit(prefs: prefs)
        let t = tone, p = platform
        Task {
            let out = await AICaptionEngine.generateCaptions(brief: b, tone: t, platform: p, brandKit: kit)
            await MainActor.run {
                variants = out
                usedAI = out.contains { $0.source == AICaptionEngine.aiSource }
                working = false
            }
        }
    }

    @ViewBuilder private func variantCard(_ v: CaptionVariant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !v.hook.isEmpty {
                Text(v.hook).font(BLFonts.display(16, weight: .medium)).foregroundStyle(BLTheme.goldText)
            }
            if !v.bodyText.isEmpty {
                Text(v.bodyText).font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.text).fixedSize(horizontal: false, vertical: true)
            }
            if !v.cta.isEmpty {
                Text(v.cta).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            }
            if !v.hashtags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(v.hashtags, id: \.self) { tag in
                        Text(tag).font(BLFonts.mono(9.5, weight: .semibold)).foregroundColor(BLTheme.gold)
                            .padding(.vertical, 2).padding(.horizontal, 8).background(BLTheme.gold.opacity(0.1)).clipShape(Capsule())
                    }
                }
            }
            HStack(spacing: 8) {
                StatusPill(text: v.source, tint: v.source == AICaptionEngine.aiSource ? BLTheme.green : BLTheme.sub)
                Text("\(v.characterCount) / \(v.platform.charLimit)")
                    .font(BLFonts.mono(9.5, weight: .semibold))
                    .foregroundColor(v.characterCount > v.platform.charLimit ? BLTheme.danger : BLTheme.sub)
                Spacer()
                GhostButton(label: copiedID == v.id ? "Copied" : "Copy", icon: copiedID == v.id ? "checkmark" : "doc.on.doc") { copyVariant(v) }
                IconButton(system: "plus.circle.fill", tint: BLTheme.green, accessibilityText: "Save caption") {
                    let topic = brief.trimmingCharacters(in: .whitespaces)
                    model.addCaption(Caption(topic: topic.isEmpty ? "general" : topic, text: v.fullText))
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { copyVariant(v) }
    }

    private func copyVariant(_ v: CaptionVariant) {
        copyText(v.fullText)
        withAnimation(.easeOut(duration: 0.15)) { copiedID = v.id }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { if copiedID == v.id { copiedID = nil } }
        }
    }

    private func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
#endif // circuit-convert
