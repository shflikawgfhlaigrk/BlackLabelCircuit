#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// One persistent operating loop across the app's existing strategy, creation,
/// publishing, and measurement tools. Counts come only from the buyer's workspace.
struct MarketingOSScreen: View {
    @EnvironmentObject private var model: AppModel
    let go: (Section) -> Void

    @AppStorage("marketingOS.campaignName") private var campaignName = ""
    @AppStorage("marketingOS.objective") private var objective = ""
    @AppStorage("marketingOS.stage") private var stageRaw = MarketingOSStage.idea.rawValue

    private var stage: MarketingOSStage {
        MarketingOSStage(rawValue: stageRaw) ?? .idea
    }

    private var queuedPosts: Int {
        model.posts.filter { ($0.publishState ?? "scheduled") == "scheduled" }.count
    }

    private var publishedPosts: Int {
        model.posts.filter { $0.publishState == "published" }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ScreenHeader(
                    title: "Marketing OS",
                    subtitle: "One continuous workflow from idea to learning — with the work and context kept together."
                )

                campaignCommandCenter
                workflow
                liveWorkspace
                operatingSystem
                deliveryBoundary
            }
            .padding(24)
        }
    }

    private var campaignCommandCenter: some View {
        Panel(title: "Campaign command center", icon: "scope") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        StatusPill(text: "CURRENT · \(stage.title.uppercased())", tint: BLTheme.gold)
                        Text(stage.promise)
                            .font(BLFonts.display(24, weight: .medium))
                            .foregroundColor(BLTheme.text)
                    }
                    Spacer()
                    GoldButton(label: "Continue", icon: "arrow.right") { go(stage.destination) }
                }

                HStack(spacing: 12) {
                    TextField("Campaign name", text: $campaignName)
                        .textFieldStyle(.roundedBorder)
                    TextField("Objective — what should this campaign change?", text: $objective)
                        .textFieldStyle(.roundedBorder)
                }

                Text("Campaign and stage persist locally. Provider publishing still depends on each connected network's official API, permissions, and review state.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub)
            }
        }
    }

    private var workflow: some View {
        Panel(title: "Idea → outcome", icon: "point.3.connected.trianglepath.dotted") {
            LazyVGrid(columns: blGridColumns(minItemWidth: 190, macColumns: 5), spacing: 12) {
                ForEach(MarketingOSStage.allCases) { item in
                    Button {
                        stageRaw = item.rawValue
                        go(item.destination)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Image(systemName: item.icon)
                                    .foregroundColor(item == stage ? BLTheme.inkOnGold : BLTheme.gold)
                                    .frame(width: 28, height: 28)
                                    .background(item == stage ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Spacer()
                                Text(String(format: "%02d", item.ordinal))
                                    .font(BLFonts.mono(10, weight: .bold))
                                    .foregroundColor(BLTheme.sub)
                            }
                            Text(item.title)
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundColor(BLTheme.text)
                            Text(item.detail)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundColor(BLTheme.sub)
                                .lineLimit(3)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
                        .background(item == stage ? BLTheme.gold.opacity(0.09) : BLTheme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(item == stage ? BLTheme.gold.opacity(0.7) : BLTheme.stroke))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var liveWorkspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LIVE WORKSPACE")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.sub)
                .tracking(1)
            LazyVGrid(columns: blGridColumns(minItemWidth: 150, macColumns: 5), spacing: 14) {
                HeroStat(label: "Reel projects", value: "\(model.reels.count)", icon: "film.stack.fill")
                HeroStat(label: "Caption drafts", value: "\(model.captions.count)", icon: "text.quote")
                HeroStat(label: "Queued posts", value: "\(queuedPosts)", icon: "calendar.badge.clock")
                HeroStat(label: "Published receipts", value: "\(publishedPosts)", icon: "checkmark.seal.fill")
                HeroStat(label: "Campaigns", value: "\(model.campaigns.count)", icon: "rectangle.3.group.fill")
            }
        }
    }

    private var operatingSystem: some View {
        Panel(title: "Three connected engines", icon: "gearshape.2.fill") {
            LazyVGrid(columns: blGridColumns(minItemWidth: 230, macColumns: 3), spacing: 14) {
                engine("Strategy", "Brand, audience, offers, briefs, and reusable campaign memory.", "brain.head.profile", .ideation)
                engine("Creation", "Record, edit, caption, brand, and adapt without abandoning the campaign.", "wand.and.stars", .reels)
                engine("Distribution", "Approve, schedule, publish through official providers, and keep real receipts.", "paperplane.circle.fill", .publisher)
            }
        }
    }

    private func engine(_ title: String, _ detail: String, _ icon: String, _ destination: Section) -> some View {
        Button { go(destination) } label: {
            VStack(alignment: .leading, spacing: 9) {
                Image(systemName: icon).font(.system(size: 18, weight: .bold)).foregroundColor(BLTheme.gold)
                Text(title).font(BLFonts.display(20, weight: .medium)).foregroundColor(BLTheme.text)
                Text(detail).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                Text("Open →").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.gold)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 145, alignment: .leading)
            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(BLTheme.stroke))
        }.buttonStyle(.plain)
    }

    private var deliveryBoundary: some View {
        Panel(title: "How this works", icon: "checkmark.shield.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text("One campaign, start to finish: idea, script, record, edit, captions, brand, adapt, approve, schedule, learn. Each step opens the tool that does the work, and your progress is saved between launches.")
                Text("A post only counts as published when the provider returns a receipt confirming it. Anything that isn't connected stays clearly marked as a step you finish yourself — nothing is quietly assumed.")
            }
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .foregroundColor(BLTheme.sub)
        }
    }
}

private enum MarketingOSStage: String, CaseIterable, Identifiable {
    case idea, script, record, edit, captions, brand, adapt, approve, schedule, learn
    var id: String { rawValue }
    var ordinal: Int { Self.allCases.firstIndex(of: self)! + 1 }

    var title: String {
        switch self {
        case .idea: return "Idea"
        case .script: return "Script"
        case .record: return "Record"
        case .edit: return "Edit"
        case .captions: return "Captions"
        case .brand: return "Brand"
        case .adapt: return "Adapt"
        case .approve: return "Approve"
        case .schedule: return "Schedule"
        case .learn: return "Learn"
        }
    }

    var icon: String {
        switch self {
        case .idea: return "lightbulb.max.fill"
        case .script: return "doc.text.fill"
        case .record: return "record.circle"
        case .edit: return "slider.horizontal.3"
        case .captions: return "captions.bubble.fill"
        case .brand: return "paintpalette.fill"
        case .adapt: return "arrow.triangle.branch"
        case .approve: return "checkmark.circle.fill"
        case .schedule: return "calendar.badge.clock"
        case .learn: return "chart.line.uptrend.xyaxis"
        }
    }

    var detail: String {
        switch self {
        case .idea: return "Choose an audience, promise, hook, and evidence."
        case .script: return "Turn the brief into a platform-ready narrative."
        case .record: return "Capture camera, microphone, screen, or imported media."
        case .edit: return "Shape the timeline and preserve the campaign context."
        case .captions: return "Create readable, editable, accessible captions."
        case .brand: return "Apply approved voice, visuals, claims, and disclosures."
        case .adapt: return "Create native variants for every destination."
        case .approve: return "Review copy, creative, ownership, and risk."
        case .schedule: return "Queue through connected official provider APIs."
        case .learn: return "Use real outcomes to improve the next brief."
        }
    }

    var promise: String { detail }

    var destination: Section {
        switch self {
        case .idea, .script, .captions: return .ideation
        case .record, .edit: return .reels
        case .brand: return .content
        case .adapt: return .publisher
        case .approve: return .pipeline
        case .schedule: return .calendar
        case .learn: return .dashboard
        }
    }
}
#endif // circuit-convert
