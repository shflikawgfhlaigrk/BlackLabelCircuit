import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct WebsiteLiveSnapshot: Codable, Hashable {
    struct Section: Codable, Hashable {
        var status: String?
        var leads: Int?
        var with_phone: Int?
        var with_email: Int?
        var sent: Int?
        var posts: Int?
        var headline: String?
        var note: String?
        var email: String?
        var instagram: String?
        var tiktok: String?
        var x: String?
        var facebook: String?
        var linkedin: String?
        var threads: String?
    }

    var generated_at: String?
    var outbound: Section?
    var marketing: Section?
    var pipeline: Section?
    var selfcoding: Section?
}

struct WebsiteLiveSyncResult: Hashable {
    var sourceURL: String
    var generatedAt: String
    var sites: Int
    var reels: Int
    var captions: Int
    var posts: Int
    var renderedReelPath: String
    var renderedReelBytes: Int
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum WebsiteLiveSync {
    static let defaultURL = URL(string: "https://blacklabelbots.com/data/live.json")!
    private static let sourceTag = "[BlackLabelWebsiteLive]"

    static func fetch(url: URL = defaultURL) async throws -> WebsiteLiveSnapshot {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Black Label's own published snapshot — the declared `firstPartyUpdateFeed` lane.
        let (data, response) = try await ConsentedEgress.sendUngated(request, lane: .firstPartyUpdateFeed)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(WebsiteLiveSnapshot.self, from: data)
    }

    @discardableResult
    static func sync(model: AppModel, snapshot: WebsiteLiveSnapshot, sourceURL: URL = defaultURL, renderReel: Bool = true) throws -> WebsiteLiveSyncResult {
        var snapshot = snapshot
        if var marketing = snapshot.marketing {
            marketing.headline = normalizedMarketingHeadline(marketing.headline ?? "")
            marketing.note = normalizedMarketingNote(marketing.note ?? "")
            snapshot.marketing = marketing
        }
        let generated = snapshot.generated_at ?? ISO8601DateFormatter().string(from: Date())
        let outbound = snapshot.outbound
        let marketing = snapshot.marketing
        let headline = outbound?.headline?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? outbound!.headline!
            : "Black Label Bots live website snapshot"
        let marketingHeadline = marketing?.headline?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? marketing!.headline!
            : "Marketing engine status"

        let site = makeSite(snapshot: snapshot, generated: generated)
        upsertSite(site, in: model)

        let captions = makeCaptions(outboundHeadline: headline, marketingHeadline: marketingHeadline, generated: generated)
        upsertCaptions(captions, in: model)

        let posts = makePosts(outboundHeadline: headline, marketingHeadline: marketingHeadline, generated: generated)
        upsertPosts(posts, in: model)

        let reel = makeReel(snapshot: snapshot, generated: generated)
        upsertReel(reel, in: model)

        var renderedPath = ""
        var renderedBytes = 0
        if renderReel {
            let out = try render(reel)
            renderedPath = out.path
            let attributes = try? FileManager.default.attributesOfItem(atPath: out.path)
            renderedBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        }

        return WebsiteLiveSyncResult(sourceURL: sourceURL.absoluteString,
                                     generatedAt: generated,
                                     sites: model.sites.filter { $0.name.contains(sourceTag) }.count,
                                     reels: model.reels.filter { $0.name.contains(sourceTag) }.count,
                                     captions: model.captions.filter { $0.topic.contains(sourceTag) }.count,
                                     posts: model.posts.filter { $0.title.contains(sourceTag) }.count,
                                     renderedReelPath: renderedPath,
                                     renderedReelBytes: renderedBytes)
    }

    private static func makeSite(snapshot: WebsiteLiveSnapshot, generated: String) -> SiteProject {
        let outbound = snapshot.outbound
        let marketing = snapshot.marketing
        var content = SiteContent()
        content.about = [
            outbound?.note,
            marketing?.note,
            "Snapshot generated at \(generated)."
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        content.services = [
            SiteService(title: "Outbound lead engine", detail: outbound?.headline ?? ""),
            SiteService(title: "Marketing engine", detail: marketing?.headline ?? "")
        ].filter { !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        content.stats = [
            outbound?.leads.map { SiteStat(value: String($0), label: "leads sourced") },
            outbound?.with_phone.map { SiteStat(value: String($0), label: "with phone") },
            outbound?.with_email.map { SiteStat(value: String($0), label: "with email") },
            outbound?.sent.map { SiteStat(value: String($0), label: "contacted") },
            marketing?.posts.map { SiteStat(value: String($0), label: "operator posts logged") }
        ].compactMap { $0 }
        content.ctaLabel = "Review live pipeline"
        let html = Studio.landingPage(name: "Black Label Bots Live Snapshot",
                                      type: "Operator website data",
                                      city: "",
                                      phone: "",
                                      template: .bold,
                                      palette: .gold,
                                      formEndpoint: "",
                                      contactEmail: "",
                                      headline: outbound?.headline ?? "Black Label Bots live data",
                                      subheadOverride: marketing?.headline ?? "",
                                      funnel: false,
                                      content: content)
        return SiteProject(id: deterministicUUID("site-\(generated)"),
                           name: "\(sourceTag) Website data snapshot",
                           businessType: "Operator website data",
                           city: "",
                           phone: "",
                           html: html,
                           content: content,
                           created: Date())
    }

    private static func makeCaptions(outboundHeadline: String, marketingHeadline: String, generated: String) -> [Caption] {
        [
            Caption(id: deterministicUUID("caption-outbound-\(generated)"),
                    topic: "\(sourceTag) Outbound",
                    text: "\(outboundHeadline)\n\nSource: blacklabelbots.com/data/live.json\nGenerated: \(generated)",
                    created: Date()),
            Caption(id: deterministicUUID("caption-marketing-\(generated)"),
                    topic: "\(sourceTag) Marketing",
                    text: "\(marketingHeadline)\n\nDirect posting remains connector-gated until credentials and send logs exist.",
                    created: Date())
        ]
    }

    private static func makePosts(outboundHeadline: String, marketingHeadline: String, generated: String) -> [ScheduledPost] {
        [
            ScheduledPost(id: deterministicUUID("post-linkedin-\(generated)"),
                          title: "\(sourceTag) LinkedIn website proof",
                          body: "\(outboundHeadline)\n\nMarketing status: \(marketingHeadline)\n\nSource: blacklabelbots.com/data/live.json",
                          channel: "LinkedIn",
                          scheduledAt: Date(),
                          created: Date()),
            ScheduledPost(id: deterministicUUID("post-x-\(generated)"),
                          title: "\(sourceTag) X website proof",
                          body: "\(outboundHeadline) | \(marketingHeadline)",
                          channel: "X",
                          scheduledAt: Date().addingTimeInterval(3600),
                          created: Date())
        ]
    }

    private static func makeReel(snapshot: WebsiteLiveSnapshot, generated: String) -> ReelProject {
        let outbound = snapshot.outbound
        let marketing = snapshot.marketing
        let scenes = [
            ReelScene(eyebrow: "LIVE WEBSITE DATA",
                      headline: "Black Label Bots",
                      subtitle: generated,
                      seconds: 1.8,
                      transition: .zoomIn,
                      kind: .opener),
            ReelScene(eyebrow: "OUTBOUND",
                      headline: outbound?.headline ?? "Lead engine snapshot",
                      subtitle: outbound?.note ?? "",
                      seconds: 2.6,
                      transition: .slideUp),
            ReelScene(eyebrow: "MARKETING",
                      headline: marketing?.headline ?? "Marketing status",
                      subtitle: marketing?.note ?? "",
                      seconds: 2.8,
                      transition: .slideLeft),
            ReelScene(eyebrow: "SOURCE",
                      headline: "Synced from website JSON",
                      subtitle: "Review, edit, export, or post from connected accounts.",
                      seconds: 2.2,
                      transition: .fade,
                      kind: .cta)
        ]
        return ReelProject(id: deterministicUUID("reel-\(generated)"),
                           name: "\(sourceTag) Website proof reel",
                           format: .vertical,
                           scenes: scenes,
                           paletteAccentHex: 0xD9B65C,
                           styleID: .spotlight,
                           fps: 30,
                           voice: ReelVoice(enabled: false),
                           music: ReelMusic(enabled: true, source: .builtIn, mood: .cinematic, gain: 0.18),
                           created: Date())
    }

    private static func normalizedMarketingHeadline(_ raw: String) -> String {
        if raw.localizedCaseInsensitiveContains("marketing engine not publicly live") {
            return "Marketing is live with promo reels, landing pages, email, CRM tools, and the included U.S. lead database."
        }
        return raw
    }

    private static func normalizedMarketingNote(_ raw: String) -> String {
        if raw.localizedCaseInsensitiveContains("public marketing product is coming soon") {
            return "Direct posting remains connector-gated until credentials and send logs exist."
        }
        return raw
    }

    private static func upsertSite(_ site: SiteProject, in model: AppModel) {
        if let existing = model.sites.first(where: { $0.name.contains(sourceTag) }) {
            var replacement = site
            replacement.id = existing.id
            model.upsert(replacement)
        } else {
            model.upsert(site)
        }
    }

    private static func upsertCaptions(_ captions: [Caption], in model: AppModel) {
        model.captions.removeAll { $0.topic.contains(sourceTag) }
        for caption in captions.reversed() { model.addCaption(caption) }
    }

    private static func upsertPosts(_ posts: [ScheduledPost], in model: AppModel) {
        model.posts.removeAll { $0.title.contains(sourceTag) }
        for post in posts { model.schedule(post) }
    }

    private static func upsertReel(_ reel: ReelProject, in model: AppModel) {
        if let existing = model.reels.first(where: { $0.name.contains(sourceTag) }) {
            var replacement = reel
            replacement.id = existing.id
            model.upsertReel(replacement)
        } else {
            model.upsertReel(reel)
        }
    }

    private static func render(_ reel: ReelProject) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true)
            .appendingPathComponent("RenderedReels", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let bundle = safeFileComponent(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing")
        let runID = "\(Int(Date().timeIntervalSince1970))-\(ProcessInfo.processInfo.processIdentifier)"
        let out = base.appendingPathComponent("website-proof-reel-\(bundle)-\(reel.id.uuidString)-\(runID).mp4")
        try ReelRenderer.render(project: reel, to: out)
        return out
    }

    private static func safeFileComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return value.isEmpty ? "app" : value
    }

    private static func deterministicUUID(_ seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
#endif // circuit-convert
