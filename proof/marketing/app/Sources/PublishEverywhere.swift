#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — one simple composer and automatic queue for every supported network.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

enum ScheduledMediaStore {
    static func persist(_ source: URL) throws -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true)
            .appendingPathComponent("ScheduledMedia", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("social-\(UUID().uuidString).\(ext)")
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}

@MainActor
enum ScheduledSocialPublisher {
    private static var running = false
    /// True when the last runDue call did no work because ANOTHER Marketing process (open app or
    /// LaunchAgent) held the cross-process publish lock. The headless runner reports this honestly.
    private(set) static var lastRunSkippedByLock = false

    static func runDue(model: AppModel) async -> Int {
        guard !running else { return 0 }
        running = true
        defer { running = false }
        // Cross-process single flight: the in-app 60-second loop and the LaunchAgent both land
        // here, and the flock guarantees two processes never upload the same due post concurrently.
        guard let lockFD = PublishSingleFlight.acquire() else {
            lastRunSkippedByLock = true
            return 0
        }
        lastRunSkippedByLock = false
        defer { PublishSingleFlight.release(lockFD) }

        // Self-heal connection-shaped failures: a post that failed ONLY because its network
        // wasn't connected (detail written below with the "Connect " prefix) returns to the
        // queue the moment a token is readable — the buyer never has to find the row and tap
        // Retry after connecting (or after a pre-unlock Keychain read). This runs BEFORE the
        // ledger reconcile so a post the other process already published is corrected to
        // "published" by its receipt instead of re-posting.
        for waiting in model.posts.filter({ $0.autoPublish == true && $0.publishState == "failed"
                && ($0.publishDetail?.hasPrefix("Connect ") ?? false) }) {
            guard let platform = waiting.platformRaw.flatMap(SocialPlatform.init(rawValue:)),
                  let token = SocialCredentialStore.token(for: platform), !token.isEmpty else { continue }
            model.updatePost(waiting.id) {
                $0.publishState = "scheduled"; $0.publishDetail = "Connection restored — retrying…"
            }
        }

        // Consult the cross-process ledger FIRST: the workspace blob is whole-store
        // last-writer-wins, so a row this process still sees as queued may already have been
        // published by the other process — reconcile it with the real receipt instead of re-posting.
        var ledger = PublishLedger.load()
        for row in model.posts where row.autoPublish == true
            && (row.publishState == nil || row.publishState == "scheduled" || row.publishState == "publishing") {
            guard let receipt = ledger[row.id.uuidString] else { continue }
            model.updatePost(row.id) {
                $0.publishState = "published"; $0.publishedAt = receipt.at; $0.publishDetail = receipt.detail
            }
        }

        // A terminated app can leave a row at "publishing". On the next run there is no live
        // uploader, so return it to the queue instead of leaving it stuck forever.
        for interrupted in model.posts.filter({ $0.autoPublish == true && $0.publishState == "publishing" }) {
            model.updatePost(interrupted.id) {
                $0.publishState = "scheduled"; $0.publishDetail = "Retrying interrupted upload…"
            }
        }
        let due = model.posts.filter {
            $0.autoPublish == true && ($0.publishState == nil || $0.publishState == "scheduled") && $0.scheduledAt <= Date()
        }
        var completed = 0
        for queued in due {
            guard let platform = queued.platformRaw.flatMap(SocialPlatform.init(rawValue:)) else {
                model.updatePost(queued.id) { $0.publishState = "failed"; $0.publishDetail = "Unknown social network." }
                continue
            }
            guard let token = SocialCredentialStore.token(for: platform), !token.isEmpty else {
                // "Connect " prefix is load-bearing: the self-heal pass above matches it.
                model.updatePost(queued.id) {
                    $0.publishState = "failed"
                    $0.publishDetail = "Connect \(platform.rawValue) in Connectors — this post sends automatically once connected."
                }
                continue
            }
            let mediaURL = queued.mediaPath.flatMap(URL.init(fileURLWithPath:))
            model.updatePost(queued.id) { $0.publishState = "publishing"; $0.publishDetail = "Uploading…" }
            let post = SocialPost(text: queued.body,
                                  mediaFileURL: mediaURL,
                                  mediaPublicURL: queued.mediaPublicURL,
                                  mediaIsVideo: queued.mediaIsVideo ?? false,
                                  title: queued.title)
            let result = await SocialPublishService().publish(post, to: platform,
                                                               account: SocialAccount(accessToken: token))
            switch result {
            case .success(let receipt):
                let publishedAt = Date()
                let detail = receipt.permalink ?? "Post id \(receipt.id)"
                PublishLedger.record(queued.id, detail: detail, at: publishedAt, in: &ledger)
                model.updatePost(queued.id) {
                    $0.publishState = "published"; $0.publishedAt = publishedAt
                    $0.publishDetail = detail
                }
                completed += 1
            case .failure(let error):
                model.updatePost(queued.id) {
                    $0.publishState = "failed"
                    $0.publishDetail = error.errorDescription ?? "Publish failed."
                }
            }
        }
        return completed
    }
}

struct UnifiedPublisherScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Publisher", subtitle: "Create once, select every network, then publish now or schedule it.")
                Panel(title: "New post", icon: "paperplane.fill") {
                    PublishEverywhereComposer()
                }
                automaticQueue
                #if os(macOS)
                BackgroundPublishCard()
                #endif
            }
            .padding(28)
        }
        .onAppear { model.refreshSocialCredentialFlags() }
    }

    private var automaticQueue: some View {
        let queued = model.posts.filter { $0.autoPublish == true }
        return Panel(title: "Automatic queue (\(queued.count))", icon: "clock.badge.checkmark") {
            VStack(spacing: 8) {
                if queued.isEmpty {
                    EmptyState(icon: "calendar.badge.plus", title: "Queue is empty",
                               hint: "Choose networks and a time above. Marketing publishes due posts while the app is open.")
                } else {
                    ForEach(queued) { post in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: platform(for: post)?.icon ?? "paperplane")
                                .foregroundColor(BLTheme.gold).frame(width: 22)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 7) {
                                    Text(post.channel).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    StatusPill(text: (post.publishState ?? "scheduled").capitalized,
                                               tint: stateColor(post.publishState))
                                }
                                Text(post.body.isEmpty ? post.title : post.body)
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                    .lineLimit(2)
                                Text(post.publishDetail ?? post.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if post.publishState == "failed" {
                                Button("Retry") {
                                    model.updatePost(post.id) {
                                        $0.publishState = "scheduled"; $0.publishDetail = nil; $0.scheduledAt = Date()
                                    }
                                    Task { _ = await ScheduledSocialPublisher.runDue(model: model) }
                                }.buttonStyle(.bordered).tint(BLTheme.gold)
                            }
                            ConfirmDeleteButton(title: "Delete this post?",
                                                message: "It will be removed from the queue and won't publish. This cannot be undone.") {
                                model.deletePost(post)
                            }
                        }
                        .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                }
            }
        }
    }

    private func platform(for post: ScheduledPost) -> SocialPlatform? {
        post.platformRaw.flatMap(SocialPlatform.init(rawValue:))
    }
    private func stateColor(_ state: String?) -> Color {
        switch state {
        case "published": return BLTheme.green
        case "failed": return BLTheme.danger
        case "publishing": return BLTheme.gold
        default: return BLTheme.sub
        }
    }
}

struct PublishEverywhereComposer: View {
    @EnvironmentObject var model: AppModel
    let initialMediaURL: URL?
    let suggestedCaption: String
    let compact: Bool

    @State private var title = ""
    @State private var caption = ""
    @State private var publicMediaURL = ""
    @State private var localMediaURL: URL?
    @State private var selected = Set(SocialPlatform.allCases)
    @State private var showMediaPicker = false
    @State private var scheduleDate = Date().addingTimeInterval(3600)
    @State private var publishing = false
    @State private var status: [SocialPlatform: String] = [:]
    @State private var message = ""
    @State private var seeded = false

    init(initialMediaURL: URL? = nil, suggestedCaption: String = "", compact: Bool = false) {
        self.initialMediaURL = initialMediaURL
        self.suggestedCaption = suggestedCaption
        self.compact = compact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title (used by YouTube)", text: $title)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $caption)
                .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .scrollContentBackground(.hidden).frame(minHeight: compact ? 80 : 120)
                .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if caption.isEmpty { Text("Write one caption for every selected network…").font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub).padding(14).allowsHitTesting(false) }
                }

            HStack(spacing: 8) {
                if !compact {
                    GhostButton(label: localMediaURL == nil ? "Add photo or video" : "Media ✓", icon: "photo.on.rectangle") { showMediaPicker = true }
                }
                if let localMediaURL {
                    Text(localMediaURL.lastPathComponent).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(1)
                    Button { self.localMediaURL = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundColor(BLTheme.sub)
                }
            }
            .fileImporter(isPresented: $showMediaPicker, allowedContentTypes: [.movie, .image], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let source = urls.first {
                    do { localMediaURL = try ScheduledMediaStore.persist(source); message = "Media ready." }
                    catch { message = "Couldn't load media: \(error.localizedDescription)" }
                }
            }

            TextField("Public media URL for Instagram and Threads (optional)", text: $publicMediaURL)
                .textFieldStyle(.roundedBorder)
            Text("Instagram and Threads fetch video from a public HTTPS URL. X, Facebook, YouTube, and approved TikTok apps upload the local file directly; LinkedIn publishes the caption/link share.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("POST TO").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.7)
                Spacer()
                Button(selected.count == SocialPlatform.allCases.count ? "Clear" : "Select all") {
                    selected = selected.count == SocialPlatform.allCases.count ? [] : Set(SocialPlatform.allCases)
                }.buttonStyle(.plain).foregroundColor(BLTheme.gold)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], spacing: 8) {
                ForEach(SocialPlatform.allCases) { platform in platformButton(platform) }
            }

            DatePicker("Schedule for", selection: $scheduleDate)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).tint(BLTheme.gold)
            HStack(spacing: 9) {
                GoldButton(label: publishing ? "Publishing…" : "Publish now to \(selected.count)", fill: true, icon: "paperplane.fill") { publishNow() }
                    .disabled(publishing || selected.isEmpty || !hasContent)
                GoldButton(label: "Add \(selected.count) to queue", icon: "calendar.badge.plus") { schedule() }
                    .disabled(selected.isEmpty || !hasContent)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(message.lowercased().contains("fail") || message.lowercased().contains("couldn't") ? BLTheme.danger : BLTheme.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            guard !seeded else { return }; seeded = true
            localMediaURL = initialMediaURL
            if caption.isEmpty { caption = suggestedCaption }
            model.refreshSocialCredentialFlags()
        }
    }

    private var hasContent: Bool {
        !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || localMediaURL != nil || validPublicURL != nil
    }
    private var validPublicURL: String? {
        let value = publicMediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return value
    }
    private var isVideo: Bool {
        guard let ext = localMediaURL?.pathExtension.lowercased() else { return true }
        return ["mp4", "mov", "m4v", "avi", "webm"].contains(ext)
    }

    private func platformButton(_ platform: SocialPlatform) -> some View {
        let active = selected.contains(platform)
        // Health, not presence: a stored-but-expired credential is NOT "connected". It reports the
        // real reason here instead of showing a route label and failing later at publish time.
        let liveness = SocialCredentialStore.liveness(for: platform)
        let connected = SocialCredentialStore.hasToken(for: platform) && !liveness.isKnownDead
        return Button {
            if active { selected.remove(platform) } else { selected.insert(platform) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(active ? BLTheme.gold : BLTheme.sub)
                Image(systemName: platform.icon).foregroundColor(BLTheme.gold).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(platform.rawValue).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(status[platform] ?? (connected ? routeLabel(platform)
                                                        : (liveness.isKnownDead ? "Credential expired — reconnect" : "Connect account")))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundColor(status[platform]?.hasPrefix("✓") == true ? BLTheme.green : BLTheme.sub).lineLimit(2)
                }
                Spacer()
            }
            .padding(9).background(active ? BLTheme.gold.opacity(0.08) : BLTheme.bg2)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(active ? BLTheme.gold.opacity(0.45) : BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func routeLabel(_ platform: SocialPlatform) -> String {
        switch platform {
        case .instagram, .threads: return validPublicURL == nil && localMediaURL != nil ? "Needs public media URL" : "Ready"
        case .youtube, .tiktok: return localMediaURL == nil ? "Needs a video" : "Ready"
        case .linkedin: return localMediaURL == nil ? "Ready" : "Caption/link share"
        default: return "Ready"
        }
    }

    private func payload() -> SocialPost {
        SocialPost(text: caption.trimmingCharacters(in: .whitespacesAndNewlines),
                   mediaFileURL: localMediaURL,
                   mediaPublicURL: validPublicURL,
                   mediaIsVideo: isVideo,
                   title: title.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func publishNow() {
        publishing = true; message = "Publishing to selected accounts…"; status = [:]
        let post = payload(); let platforms = SocialPlatform.allCases.filter(selected.contains)
        Task {
            var successes = 0
            for platform in platforms {
                guard let token = SocialCredentialStore.token(for: platform), !token.isEmpty else {
                    await MainActor.run { status[platform] = "Connect account" }; continue
                }
                await MainActor.run { status[platform] = "Publishing…" }
                let result = await SocialPublishService().publish(post, to: platform,
                                                                   account: SocialAccount(accessToken: token))
                await MainActor.run {
                    switch result {
                    case .success(let receipt): status[platform] = "✓ \(receipt.id)"; successes += 1
                    case .failure(let error): status[platform] = error.errorDescription ?? "Failed"
                    }
                }
            }
            await MainActor.run {
                publishing = false
                message = "Published \(successes) of \(platforms.count). Each network's result is shown above."
            }
        }
    }

    private func schedule() {
        let platforms = SocialPlatform.allCases.filter(selected.contains)
        let durableMedia: URL?
        do {
            if let localMediaURL, !localMediaURL.path.contains("/Application Support/BlackLabelMarketing/ScheduledMedia/") {
                durableMedia = try ScheduledMediaStore.persist(localMediaURL)
            } else { durableMedia = localMediaURL }
        } catch {
            message = "Couldn't stage media for the queue: \(error.localizedDescription)"; return
        }
        for platform in platforms {
            model.schedule(ScheduledPost(title: title.isEmpty ? "Social post" : title,
                                         body: caption, channel: platform.rawValue, scheduledAt: scheduleDate,
                                         platformRaw: platform.rawValue, mediaPath: durableMedia?.path,
                                         mediaPublicURL: validPublicURL, mediaIsVideo: isVideo,
                                         autoPublish: true, publishState: "scheduled"))
        }
        message = "Queued \(platforms.count) posts for \(scheduleDate.formatted(date: .abbreviated, time: .shortened))."
        if scheduleDate <= Date() { Task { _ = await ScheduledSocialPublisher.runDue(model: model) } }
    }
}

#if os(macOS)
/// "Publish while the app is closed" — installs the buyer's own LaunchAgent that re-runs this
/// binary headlessly (--publish-due) every 5 minutes. Own-infra by design: tokens never leave
/// this Mac, so the honest trade-off (vs Buffer's servers) is that the Mac must be on.
struct BackgroundPublishCard: View {
    @State private var status = LaunchAgentManager.status()
    @State private var working = false
    @State private var lastMessage: String?

    var body: some View {
        Panel(title: "Publish while the app is closed", icon: "moon.zzz.fill") {
            VStack(alignment: .leading, spacing: 10) {
                if status.sandboxBlocked {
                    Text("This App Store build runs in the App Sandbox, which cannot register a background publisher. Use the direct-download build for closed-app publishing.")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                } else {
                    HStack(spacing: 10) {
                        Toggle(isOn: Binding(
                            get: { status.installed },
                            set: { on in
                                guard !working else { return }
                                working = true
                                let result = on ? LaunchAgentManager.install() : LaunchAgentManager.uninstall()
                                lastMessage = result.message
                                status = LaunchAgentManager.status()
                                working = false
                            }
                        )) {
                            Text("Publish due posts every 5 minutes, even with Marketing closed")
                                .font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        }
                        .toggleStyle(.switch).tint(BLTheme.gold).disabled(working)
                        Spacer()
                        if status.installed {
                            StatusPill(text: status.loaded ? "Active" : "Installed",
                                       tint: status.loaded ? BLTheme.green : BLTheme.gold)
                        }
                    }
                    if status.installed && !status.executableMatchesThisBuild {
                        Text("The background publisher points at a different copy of Marketing than the one you're running. Toggle off and on to repoint it to this build.")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger)
                    }
                    if let run = status.lastRun {
                        Text("Last run \(run.lastRunAt.formatted(date: .abbreviated, time: .shortened)): \(run.publishedCount) published, \(run.failedCount) failed of \(run.dueCount) due. \(run.message)")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .lineLimit(3)
                    } else if status.installed {
                        Text("No background run recorded yet — the first one happens within 5 minutes of installing.")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                    if let msg = lastMessage, !msg.isEmpty {
                        Text(msg).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(3)
                    }
                    HStack(spacing: 8) {
                        if status.installed {
                            Button("Run now") {
                                guard !working else { return }
                                working = true
                                let result = LaunchAgentManager.runNow()
                                lastMessage = result.message
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    status = LaunchAgentManager.status(); working = false
                                }
                            }.buttonStyle(.bordered).tint(BLTheme.gold).disabled(working)
                        }
                        Button("Refresh status") { status = LaunchAgentManager.status() }
                            .buttonStyle(.bordered).tint(BLTheme.sub).disabled(working)
                    }
                    Text("Runs on your own Mac only — your accounts and tokens never leave it. Your Mac must be on (or set to wake) at post time.")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                }
            }
        }
    }
}
#endif
#endif // circuit-convert
