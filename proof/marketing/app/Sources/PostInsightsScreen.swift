#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Post Insights screen (Distribute): per-post metrics pulled from each
// network's own API with the buyer's OWN token. HONEST EVERYWHERE: a metric renders only when
// the provider returned it ("—" otherwise, never a fabricated zero); missing tokens and missing
// provider receipts are said out loud; the banner names the networks this build cannot read.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct PostInsightsScreen: View {
    @EnvironmentObject var model: AppModel

    @State private var metricsByPost: [UUID: PostMetrics] = [:]
    @State private var errorsByPost: [UUID: String] = [:]
    @State private var fetching: Set<UUID> = []
    @State private var logged: Set<UUID> = []
    @State private var loaded = false

    private var published: [ScheduledPost] {
        model.posts.filter { $0.publishState == "published" }
            .sorted { ($0.publishedAt ?? $0.scheduledAt) > ($1.publishedAt ?? $1.scheduledAt) }
    }

    /// Networks this build cannot read, with the honest reason each is dark.
    private var unreadable: [(platform: SocialPlatform, reason: String)] {
        SocialPlatform.allCases.compactMap { p in
            PostInsightsAPI.unreadableReason(p).map { (p, $0) }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Post Insights",
                             subtitle: "Per-post metrics pulled from each network's own API with your tokens — real numbers or an honest blank, never an invented count.")
                if DemoMode.active {
                    Panel(title: "SAMPLE METRICS", icon: "sparkles") {
                        Text("These figures belong to the labeled fictional demo posts below. They show how completed provider results render; they are not your results and no post was sent.")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundColor(BLTheme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                coverageBanner
                totalsPanel
                postsPanel
            }
            .padding(28)
        }
        .onAppear {
            model.refreshSocialCredentialFlags()
            guard !loaded else { return }
            loaded = true
            let state = PostInsightsStore.load()
            for post in published {
                if let sample = DemoData.postMetrics(for: post) {
                    metricsByPost[post.id] = sample
                } else if !DemoMode.active, let entry = state.entries[post.id.uuidString] {
                    metricsByPost[post.id] = entry.metrics
                }
            }
            if !DemoMode.active { logged = Set(state.loggedPostIDs.compactMap(UUID.init(uuidString:))) }
        }
    }

    // MARK: honest coverage banner

    private var coverageBanner: some View {
        Panel(title: "What this build can read", icon: "checkmark.shield") {
            VStack(alignment: .leading, spacing: 8) {
                Text(DemoMode.active
                     ? "Live workspaces pull from X, Facebook Pages, Instagram, LinkedIn, and YouTube. This demo uses only the explicitly labeled sample results above."
                     : "Metrics come straight from X, Facebook Pages, Instagram, LinkedIn, and YouTube using the tokens you connected — nothing is estimated.")
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(unreadable, id: \.platform) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.platform.icon).foregroundColor(BLTheme.sub).frame(width: 18)
                        Text("\(item.platform.rawValue): \(item.reason)")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: per-platform totals (only over posts whose metrics were actually pulled)

    private var totalsPanel: some View {
        let byPlatform: [(platform: SocialPlatform, totals: PostMetrics, count: Int)] =
            SocialPlatform.allCases.compactMap { platform in
                let pulls = published.filter {
                    PostInsightsReceipt.extract(from: $0)?.platform == platform
                }.compactMap { metricsByPost[$0.id] }
                guard let totals = PostMetrics.combined(pulls) else { return nil }
                return (platform, totals, pulls.count)
            }
        return Panel(title: "Per-platform totals", icon: "sum") {
            if byPlatform.isEmpty {
                EmptyState(icon: "chart.bar.xaxis", title: "No metrics fetched yet",
                           hint: "Refresh a published post below to pull its real numbers — totals appear once at least one pull succeeds.")
                    .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: blGridColumns(minItemWidth: 200, macColumns: 3), spacing: 12) {
                    ForEach(byPlatform, id: \.platform) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: row.platform.icon).foregroundColor(BLTheme.gold).frame(width: 18)
                                Text(row.platform.rawValue).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                Spacer()
                                Text("\(row.count) post\(row.count == 1 ? "" : "s")")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                            }
                            metricRow(row.totals)
                        }
                        .padding(12).background(BLTheme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                }
            }
        }
    }

    // MARK: published posts

    private var postsPanel: some View {
        Panel(title: "Published posts (\(published.count))", icon: "chart.bar.doc.horizontal") {
            VStack(spacing: 8) {
                if published.isEmpty {
                    EmptyState(icon: "paperplane", title: "Nothing published yet",
                               hint: "Publish through the Publisher and every post with a provider receipt shows up here with its real metrics.")
                        .frame(maxWidth: .infinity)
                } else {
                    if !DemoMode.active {
                        HStack {
                            Spacer()
                            GhostButton(label: "Refresh all", icon: "arrow.clockwise") {
                                for post in published { refresh(post) }
                            }
                        }
                    }
                    ForEach(published) { post in
                        postRow(post)
                    }
                }
            }
        }
    }

    private func postRow(_ post: ScheduledPost) -> some View {
        let receipt = PostInsightsReceipt.extract(from: post)
        let platform = receipt?.platform
            ?? post.platformRaw.flatMap(SocialPlatform.init(rawValue:))
            ?? SocialPlatform(rawValue: post.channel)
            ?? SocialPublisher.platform(for: post.channel)
        let hasToken = platform.map { SocialCredentialStore.hasToken(for: $0) } ?? false
        // Presence alone never enables the fetch button: a credential known to be past its expiry
        // cannot read metrics, so the button is withheld and statusLine explains why.
        let credentialUsable = hasToken && platform.map { !SocialCredentialStore.liveness(for: $0).isKnownDead } ?? false
        let metrics = metricsByPost[post.id]
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: platform?.icon ?? "paperplane")
                .foregroundColor(BLTheme.gold).frame(width: 22)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(post.channel).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    StatusPill(text: "Published", tint: BLTheme.green)
                    if let at = post.publishedAt {
                        Text(at.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
                Text(post.body.isEmpty ? post.title : post.body)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .lineLimit(2)
                statusLine(post: post, receipt: receipt, platform: platform, hasToken: hasToken)
                if let metrics {
                    metricRow(metrics)
                    Text("Fetched \(metrics.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if fetching.contains(post.id) {
                    ProgressView().controlSize(.small)
                } else if !DemoMode.active,
                          receipt != nil,
                          credentialUsable,
                          platform.map(PostInsightsAPI.readable) == true {
                    IconButton(system: "arrow.clockwise", accessibilityText: "Fetch metrics") { refresh(post) }
                }
                if DemoMode.active, metrics != nil {
                    Text("Sample only")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundColor(BLTheme.gold)
                } else if let metrics, metrics.knownEngagement != nil {
                    if logged.contains(post.id) {
                        Text("Logged ✓").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                    } else {
                        GhostButton(label: "Log to history", icon: "chart.line.uptrend.xyaxis", tint: BLTheme.gold) {
                            logToHistory(post, metrics: metrics)
                        }
                    }
                }
            }
        }
        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    /// One honest line describing why metrics can/can't be fetched for this row.
    @ViewBuilder
    private func statusLine(post: ScheduledPost, receipt: PostInsightsReceipt?,
                            platform: SocialPlatform?, hasToken: Bool) -> some View {
        if let error = errorsByPost[post.id] {
            Text(error).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true)
        } else if DemoMode.active, DemoData.postMetrics(for: post) != nil {
            Text("Sample provider result · synthetic receipt · no network request")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("demo.proof.post-insights")
        } else if let platform, !PostInsightsAPI.readable(platform) {
            Text(PostInsightsAPI.unreadableReason(platform) ?? "\(platform.rawValue) metrics aren't readable in this build.")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        } else if receipt == nil {
            Text("No provider receipt was captured for this post, so there's nothing to look up. Posts published from this build store one automatically.")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        } else if !hasToken {
            Text("Connect \(platform?.rawValue ?? post.channel) in Connectors to fetch this post's metrics.")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        } else if let platform, SocialCredentialStore.liveness(for: platform).isKnownDead {
            // A stored credential is present but its recorded expiry has passed — say so instead of
            // offering a refresh that will come back as a provider auth error.
            Text("The stored \(platform.rawValue) credential has expired. Reconnect \(platform.rawValue) in Connectors to fetch this post's metrics.")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        } else if let receipt {
            Text("Receipt: \(receipt.postID)")
                .font(BLFonts.mono(9.5, weight: .semibold)).foregroundColor(BLTheme.sub)
                .lineLimit(1)
        }
    }

    /// The five metric chips. "—" = the provider did not report that field (never a zero).
    private func metricRow(_ m: PostMetrics) -> some View {
        HStack(spacing: 14) {
            metricChip("Impressions", m.impressions)
            metricChip("Likes", m.likes)
            metricChip("Comments", m.comments)
            metricChip("Shares", m.shares)
            metricChip("Views", m.views)
        }
    }

    private func metricChip(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.sub).tracking(0.5)
            Text(value.map(String.init) ?? "—")
                .font(BLFonts.mono(14, weight: .heavy))
                .foregroundColor(value == nil ? BLTheme.sub : BLTheme.gold)
        }
    }

    // MARK: actions

    private func refresh(_ post: ScheduledPost) {
        guard let receipt = PostInsightsReceipt.extract(from: post) else {
            errorsByPost[post.id] = "No provider receipt on this post — nothing to look up."
            return
        }
        guard PostInsightsAPI.readable(receipt.platform) else {
            errorsByPost[post.id] = PostInsightsAPI.unreadableReason(receipt.platform)
            return
        }
        guard let token = SocialCredentialStore.token(for: receipt.platform), !token.isEmpty else {
            errorsByPost[post.id] = "Connect \(receipt.platform.rawValue) in Connectors first."
            return
        }
        if let last = metricsByPost[post.id]?.fetchedAt,
           !PostInsightsStore.shouldFetch(last: last) {
            errorsByPost[post.id] = "Fetched \(Int(Date().timeIntervalSince(last)))s ago — cached values shown; try again in a minute."
            return
        }
        guard !fetching.contains(post.id) else { return }
        fetching.insert(post.id)
        errorsByPost[post.id] = nil
        Task {
            let result = await PostInsightsClient().fetch(platform: receipt.platform,
                                                          postID: receipt.postID, token: token)
            await MainActor.run {
                fetching.remove(post.id)
                switch result {
                case .success(let metrics):
                    metricsByPost[post.id] = metrics
                    PostInsightsStore.remember(postID: post.id, platform: receipt.platform,
                                               providerPostID: receipt.postID, metrics: metrics)
                case .failure(let error):
                    errorsByPost[post.id] = error.errorDescription ?? "Fetch failed."
                }
            }
        }
    }

    /// Push a real pull into the operator engagement log so BestTimeEngine learns from API data.
    private func logToHistory(_ post: ScheduledPost, metrics: PostMetrics) {
        guard !logged.contains(post.id),
              let entry = PostInsightsEngagement.entry(for: post, metrics: metrics) else { return }
        model.logEngagement(entry)
        PostInsightsStore.markLogged(post.id)
        logged.insert(post.id)
    }
}
#endif // circuit-convert
