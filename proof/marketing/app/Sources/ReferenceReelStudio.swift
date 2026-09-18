#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — reference-style remake controls for Reel Studio.
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import SwiftUI
import AppKit
import WebKit
import UniformTypeIdentifiers

@MainActor
final class ReferenceWebsiteSnapshotter: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<CGImage, Error>?

    func snapshot(url: URL, size: CGSize = CGSize(width: 1440, height: 900)) async throws -> CGImage {
        guard continuation == nil else { throw ReferenceReelError.writer("a website capture is already running") }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
            view.navigationDelegate = self
            self.webView = view
            view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            let configuration = WKSnapshotConfiguration()
            configuration.rect = webView.bounds
            configuration.snapshotWidth = 1440
            webView.takeSnapshot(with: configuration) { [weak self] image, error in
                guard let self else { return }
                if let error { self.finish(.failure(error)); return }
                guard let image, let cgImage = InstalledMarketingAppMarks.cgImage(from: image) else {
                    self.finish(.failure(ReferenceReelError.writer("website snapshot was empty"))); return
                }
                self.finish(.success(cgImage))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        let callback = continuation
        continuation = nil
        webView?.navigationDelegate = nil
        webView = nil
        callback?.resume(with: result)
    }
}

@MainActor
final class ReferenceReelBuilderModel: ObservableObject {
    @Published var referenceLink = ""
    @Published var websiteLink = ""
    @Published var referenceURL: URL?
    @Published var introURL: URL?
    @Published var assets: [ReferenceReelAsset] = []
    @Published var status = "Add the reference reel, then add the work that should replace its clips."
    @Published var errorMessage = ""
    @Published var busy = false
    @Published var renderProgress = 0.0
    @Published var endCard = "BUILT UNDER PRESSURE."
    @Published var secondsPerVisual = 1.5
    @Published var extendToShowEverything = true
    @Published var loopSoundtrack = true
    @Published var viralMode = true
    @Published var viralBrand = ""
    @Published var viralBuildSummary = "Websites, apps, new clients, and the team built in July"
    @Published var viralAudience = "Founders and local-business owners"
    @Published var viralGoal = "Show the July build and earn follows and inbound clients"
    @Published var viralHook = "WE BUILT ALL OF THIS IN JULY."
    @Published var viralProof = "WEBSITES. APPS. CLIENTS. TEAM."
    @Published var viralCTA = "FOLLOW THE BUILD."
    @Published var viralRationale = "Human-led opening, immediate payoff, fast proof cuts, and a direct close."
    @Published var viralPlanSource = "Research-backed template"

    private let snapshotter = ReferenceWebsiteSnapshotter()

    var canRender: Bool { referenceURL != nil && !assets.isEmpty && !busy }

    func generateViralPlan() {
        busy = true
        errorMessage = ""
        status = "Building a short-form hook, proof sequence, and close on this Mac…"
        let brand = viralBrand.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = viralBuildSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let audience = viralAudience.trimmingCharacters(in: .whitespacesAndNewlines)
        let goal = viralGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let plan = await ViralReelPlanner.generate(brand: brand, buildSummary: summary, audience: audience, goal: goal)
            viralHook = plan.hook
            viralProof = plan.proofLine
            viralCTA = plan.callToAction
            viralRationale = plan.rationale
            viralPlanSource = plan.source
            secondsPerVisual = plan.secondsPerVisual
            extendToShowEverything = true
            loopSoundtrack = true
            busy = false
            status = "Viral plan ready · first-frame hook + fast proof + direct close"
        }
    }

    func loadReferenceLink() {
        guard !referenceLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = ReferenceReelError.invalidURL.localizedDescription; return
        }
        busy = true; errorMessage = ""; status = "Recovering the reference movie and soundtrack…"
        Task {
            do {
                let url = try await ReferenceMediaLoader.loadRemote(referenceLink)
                referenceURL = url
                let seconds = ReferenceReelRenderer.mediaDuration(url)
                status = String(format: "Reference ready · %.1fs · soundtrack will be preserved", seconds)
            } catch { errorMessage = error.localizedDescription; status = "Reference not loaded" }
            busy = false
        }
    }

    func loadLocalReference(_ url: URL) {
        busy = true; errorMessage = ""
        Task {
            do {
                let staged = try ReferenceMediaLoader.stageLocalMovie(url)
                referenceURL = staged
                let seconds = ReferenceReelRenderer.mediaDuration(staged)
                status = String(format: "Reference ready · %.1fs · soundtrack will be preserved", seconds)
            } catch { errorMessage = error.localizedDescription }
            busy = false
        }
    }

    func loadIntro(_ url: URL) {
        busy = true; errorMessage = ""; status = "Adding the spoken intro…"
        Task {
            do {
                introURL = try ReferenceMediaLoader.stageLocalMovie(url)
                status = String(format: "Intro ready · %.1fs · its voice audio will play before the soundtrack",
                                ReferenceReelRenderer.mediaDuration(introURL!))
            } catch { errorMessage = error.localizedDescription; status = "Intro not loaded" }
            busy = false
        }
    }

    func captureWebsite() {
        let raw = websiteLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = normalizedWebURL(raw) else { errorMessage = ReferenceReelError.invalidURL.localizedDescription; return }
        busy = true; errorMessage = ""; status = "Rendering \(url.host ?? raw) in a private browser capture…"
        Task {
            do {
                let image = try await snapshotter.snapshot(url: url)
                let name = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Website"
                assets.append(ReferenceReelAsset(name: name, kind: .website, image: image))
                websiteLink = ""
                status = "Website captured · \(assets.count) visual\(assets.count == 1 ? "" : "s") ready"
            } catch { errorMessage = error.localizedDescription; status = "Website capture failed" }
            busy = false
        }
    }

    func addImage(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(contentsOf: url), let cgImage = InstalledMarketingAppMarks.cgImage(from: image) else {
            errorMessage = "That image could not be read."; return
        }
        assets.append(ReferenceReelAsset(name: url.deletingPathExtension().lastPathComponent,
                                         kind: .image, image: cgImage))
        status = "Image added · \(assets.count) visual\(assets.count == 1 ? "" : "s") ready"
    }

    func addInstalledAppMarks() {
        let existing = Set(assets.map(\.name))
        let found = InstalledMarketingAppMarks.load().filter { !existing.contains($0.name) }
        assets.append(contentsOf: found)
        status = found.isEmpty ? "No additional installed Black Label app marks were found." :
            "Added \(found.count) installed app marks · \(assets.count) visuals ready"
    }

    func addTextCard(title: String, subtitle: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { errorMessage = "Enter the large text for this card."; return }
        assets.append(ReferenceReelAsset(titleCard: cleanTitle,
                                         subtitle: subtitle.trimmingCharacters(in: .whitespacesAndNewlines)))
        status = "Text card added · \(assets.count) timeline items ready"
        errorMessage = ""
    }

    func moveAsset(_ id: UUID, by offset: Int) {
        guard let source = assets.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(assets.count - 1, max(0, source + offset))
        guard source != destination else { return }
        let item = assets.remove(at: source)
        assets.insert(item, at: destination)
    }

    func updateAsset(_ id: UUID, _ keyPath: WritableKeyPath<ReferenceReelAsset, String>, value: String) {
        guard let index = assets.firstIndex(where: { $0.id == id }) else { return }
        assets[index][keyPath: keyPath] = value
    }

    func removeAsset(_ id: UUID) { assets.removeAll { $0.id == id } }

    func render(onFinished: @escaping (URL) -> Void) {
        guard let referenceURL, canRender else { return }
        busy = true; errorMessage = ""; renderProgress = 0; status = "Rendering the reference-style reel on this Mac…"
        let isViral = viralMode
        var renderAssets = assets
        if isViral {
            let hook = viralHook.trimmingCharacters(in: .whitespacesAndNewlines)
            if !hook.isEmpty {
                renderAssets.insert(ReferenceReelAsset(titleCard: hook,
                                                       subtitle: viralProof.trimmingCharacters(in: .whitespacesAndNewlines)),
                                    at: 0)
            }
        }
        let title = isViral
            ? (viralCTA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "FOLLOW THE BUILD." : viralCTA)
            : (endCard.isEmpty ? "BUILT UNDER PRESSURE." : endCard)
        let options = ReferenceReelRenderOptions(introURL: introURL,
                                                 secondsPerVisual: secondsPerVisual,
                                                 endCardSeconds: isViral ? 1.5 : 4,
                                                 extendToShowEverything: extendToShowEverything,
                                                 loopSoundtrack: loopSoundtrack,
                                                 fitToViralPacing: isViral)
        Task.detached(priority: .userInitiated) {
            do {
                let output = try Self.outputURL()
                try ReferenceReelRenderer.render(referenceURL: referenceURL, assets: renderAssets, outputURL: output,
                                                  title: title, options: options) { value in
                    DispatchQueue.main.async { self.renderProgress = value }
                }
                await MainActor.run {
                    self.busy = false; self.renderProgress = 1
                    self.status = isViral
                        ? "Finished · viral hook + fast proof + exact soundtrack + direct close"
                        : "Finished · intro + exact soundtrack + \(renderAssets.count) timeline items"
                    onFinished(output)
                }
            } catch {
                await MainActor.run {
                    self.busy = false; self.errorMessage = error.localizedDescription
                    self.status = "Render failed"
                }
            }
        }
    }

    private func normalizedWebURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: "https://\(raw)")
    }

    private nonisolated static func outputURL() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("BlackLabelMarketing/RenderedReels", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return base.appendingPathComponent("reference-reel-\(stamp).mp4")
    }
}

struct ReferenceReelBuilderPanel: View {
    @StateObject private var builder = ReferenceReelBuilderModel()
    @State private var moviePicker = false
    @State private var introPicker = false
    @State private var imagePicker = false
    @State private var cardTitle = ""
    @State private var cardSubtitle = ""
    let cameraTake: URL?
    let onFinished: (URL) -> Void

    init(cameraTake: URL? = nil, onFinished: @escaping (URL) -> Void) {
        self.cameraTake = cameraTake
        self.onFinished = onFinished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Turn any reference reel into a finished Black Label video. Add your intro, soundtrack reference, sites, people, app marks, labels, and title cards; then arrange everything in one timeline.")
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 7) {
                stepLabel("0  VIRAL PLAN")
                Toggle("Optimize for hook, retention, and a direct close", isOn: $builder.viralMode)
                    .toggleStyle(.switch).tint(BLTheme.gold)
                if builder.viralMode {
                    TextField("What is shown in the reel?", text: $builder.viralBuildSummary).textFieldStyle(.roundedBorder)
                    HStack(spacing: 8) {
                        TextField("Audience", text: $builder.viralAudience).textFieldStyle(.roundedBorder)
                        TextField("Goal", text: $builder.viralGoal).textFieldStyle(.roundedBorder)
                    }
                    HStack(spacing: 8) {
                        GhostButton(label: builder.busy ? "Planning…" : "Generate AI viral plan", icon: "sparkles") {
                            builder.generateViralPlan()
                        }.disabled(builder.busy)
                        StatusPill(text: builder.viralPlanSource,
                                   tint: builder.viralPlanSource == "On-device AI" ? BLTheme.green : BLTheme.sub)
                    }
                    HStack(spacing: 8) {
                        TextField("First-frame hook", text: $builder.viralHook).textFieldStyle(.roundedBorder)
                        TextField("Proof line", text: $builder.viralProof).textFieldStyle(.roundedBorder)
                        TextField("CTA", text: $builder.viralCTA).textFieldStyle(.roundedBorder)
                    }
                    Text(builder.viralRationale)
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                stepLabel("1  REFERENCE + SOUNDTRACK")
                TextField("Instagram reel, Instagram CDN poster, or direct .mp4 URL", text: $builder.referenceLink)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    GoldButton(label: builder.referenceURL == nil ? "Load reference link" : "Reference loaded ✓",
                               icon: "link") { builder.loadReferenceLink() }
                    GhostButton(label: "Choose movie", icon: "film") { moviePicker = true }
                }
                .fileImporter(isPresented: $moviePicker, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
                    if case .success(let url) = result { builder.loadLocalReference(url) }
                }
            }

            Divider().background(BLTheme.stroke)
            VStack(alignment: .leading, spacing: 6) {
                stepLabel("2  SPOKEN INTRO")
                Text("The intro keeps its voice audio. The reference soundtrack starts immediately after it.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                HStack(spacing: 8) {
                    GhostButton(label: builder.introURL == nil ? "Choose intro video" : "Intro loaded ✓", icon: "person.crop.rectangle") {
                        introPicker = true
                    }
                    GhostButton(label: "Use latest camera take", icon: "video.badge.checkmark") {
                        if let cameraTake { builder.loadIntro(cameraTake) }
                    }
                    .disabled(cameraTake == nil)
                    if builder.introURL != nil {
                        Button("Remove") { builder.introURL = nil }.buttonStyle(.plain)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
                .fileImporter(isPresented: $introPicker, allowedContentTypes: [.movie, .mpeg4Movie, .quickTimeMovie]) { result in
                    if case .success(let url) = result { builder.loadIntro(url) }
                }
            }

            Divider().background(BLTheme.stroke)
            VStack(alignment: .leading, spacing: 6) {
                stepLabel("3  ADD WORK + PEOPLE")
                TextField("Website URL", text: $builder.websiteLink).textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    GhostButton(label: "Capture website", icon: "globe") { builder.captureWebsite() }
                    GhostButton(label: "Add photo / logo", icon: "photo") { imagePicker = true }
                    GhostButton(label: "Installed app marks", icon: "square.grid.3x3.fill") { builder.addInstalledAppMarks() }
                }
                .fileImporter(isPresented: $imagePicker, allowedContentTypes: [.image]) { result in
                    if case .success(let url) = result { builder.addImage(url) }
                }

                HStack(spacing: 8) {
                    TextField("Large text — e.g. 3 MORE or TEACHER", text: $cardTitle).textFieldStyle(.roundedBorder)
                    TextField("Small text — e.g. JUSTIN DUKES", text: $cardSubtitle).textFieldStyle(.roundedBorder)
                    GhostButton(label: "Add text card", icon: "textformat") {
                        builder.addTextCard(title: cardTitle, subtitle: cardSubtitle)
                        if builder.errorMessage.isEmpty { cardTitle = ""; cardSubtitle = "" }
                    }
                }
            }

            if !builder.assets.isEmpty {
                Divider().background(BLTheme.stroke)
                VStack(alignment: .leading, spacing: 8) {
                    stepLabel("4  ARRANGE + LABEL THE TIMELINE")
                    Text("Use the arrows for the exact order. Edit each name, optional subtitle, and any temporary restriction label.")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    ForEach(Array(builder.assets.enumerated()), id: \.element.id) { index, asset in
                        timelineRow(index: index, asset: asset)
                    }
                }
            }

            Divider().background(BLTheme.stroke)
            VStack(alignment: .leading, spacing: 6) {
                stepLabel("5  TIMING + END CARD")
                if !builder.viralMode {
                    TextField("BUILT UNDER PRESSURE.", text: $builder.endCard).textFieldStyle(.roundedBorder)
                } else {
                    Text("The exact reference soundtrack is trimmed to the faster cut; the spoken intro keeps its own audio.")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                Toggle("Give every timeline item enough screen time", isOn: $builder.extendToShowEverything)
                    .toggleStyle(.switch).tint(BLTheme.gold)
                if builder.extendToShowEverything {
                    HStack {
                        Text(builder.viralMode ? "Fast-cut pace" : "Seconds per item")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        Slider(value: $builder.secondsPerVisual,
                               in: builder.viralMode ? 0.65...1.25 : 0.75...4,
                               step: builder.viralMode ? 0.05 : 0.25).tint(BLTheme.gold)
                        Text(String(format: "%.2fs", builder.secondsPerVisual)).font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.text)
                            .frame(width: 48, alignment: .trailing)
                    }
                    Toggle("Repeat the exact reference soundtrack when needed", isOn: $builder.loopSoundtrack)
                        .toggleStyle(.switch).tint(BLTheme.gold)
                }
            }

            if builder.busy {
                ProgressView(value: builder.renderProgress).tint(BLTheme.gold)
            }
            GoldButton(label: builder.busy ? "Working…" : (builder.viralMode ? "Render viral cut" : "Render reference-style reel"), fill: true,
                       icon: "wand.and.stars.inverse") { builder.render(onFinished: onFinished) }
                .opacity(builder.canRender ? 1 : 0.5).disabled(!builder.canRender)
            Text(builder.status).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            if !builder.errorMessage.isEmpty {
                Label(builder.errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func stepLabel(_ text: String) -> some View {
        Text(text).font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
    }

    @ViewBuilder
    private func timelineRow(index: Int, asset: ReferenceReelAsset) -> some View {
        HStack(spacing: 10) {
            Text("\(index + 1)").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.gold)
                .frame(width: 20)
            Group {
                if let image = asset.image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill()
                } else {
                    ZStack {
                        Color.black
                        Text(asset.name.uppercased()).font(.system(size: 9, weight: .bold, design: .serif))
                            .foregroundColor(.white).lineLimit(2).multilineTextAlignment(.center).padding(4)
                    }
                }
            }
            .frame(width: 72, height: 48).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(BLTheme.stroke, lineWidth: 1))

            VStack(spacing: 5) {
                TextField(asset.kind == .textCard ? "Large text" : "Name", text: binding(asset.id, \.name))
                    .textFieldStyle(.roundedBorder)
                TextField("Subtitle (optional)", text: binding(asset.id, \.subtitle)).textFieldStyle(.roundedBorder)
                if asset.kind != .textCard {
                    TextField("Restriction label (optional)", text: binding(asset.id, \.restriction)).textFieldStyle(.roundedBorder)
                }
            }
            VStack(spacing: 5) {
                Button { builder.moveAsset(asset.id, by: -1) } label: { Image(systemName: "arrow.up") }
                    .buttonStyle(.plain).disabled(index == 0)
                Button { builder.moveAsset(asset.id, by: 1) } label: { Image(systemName: "arrow.down") }
                    .buttonStyle(.plain).disabled(index == builder.assets.count - 1)
                Button { builder.removeAsset(asset.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundColor(BLTheme.danger)
            }
            .foregroundColor(BLTheme.sub)
        }
        .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func binding(_ id: UUID, _ keyPath: WritableKeyPath<ReferenceReelAsset, String>) -> Binding<String> {
        Binding(
            get: { builder.assets.first(where: { $0.id == id })?[keyPath: keyPath] ?? "" },
            set: { builder.updateAsset(id, keyPath, value: $0) }
        )
    }
}
#endif
#endif // circuit-convert
