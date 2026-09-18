// Black Label Marketing — per-post insights pulled from each network's OWN API with the
// buyer's OWN stored token (Edits/Buffer gap: post-performance metrics).
//
// HONESTY CONTRACT (§5.1): a metric is shown ONLY when the provider returned it. A field the
// provider didn't return stays nil and renders as "—", NEVER as a zero presented as a metric.
// Platforms without a stored token or without a captured provider receipt surface an honest
// "connect / no receipt" state. Nothing here fabricates a count.
//
// Design mirrors SocialPublishClient.swift:
//   • PURE request builders + parsers (Foundation only) in PostInsightsAPI so the wire shapes
//     are unit-testable without a socket.
//   • An executing PostInsightsClient runs them through ConsentedEgress and returns the
//     provider's numbers or a real error.
//   • A small persisted cache (PostInsightsStore) throttles per-post refetches and remembers
//     the last real pull + which posts were already logged to engagement history.
//
// Endpoints (buyer's own token, no paid service):
//   X          GET /2/tweets?ids=…&tweet.fields=public_metrics,organic_metrics (fallback: public)
//   Facebook   GET /{post-id}?fields=likes.summary(true),comments.summary(true),shares (Page token)
//   Instagram  GET /{media-id}?fields=like_count,comments_count (+ tolerant /insights views,shares)
//   LinkedIn   GET /v2/socialActions/{urn}
//   YouTube    GET /youtube/v3/videos?part=statistics
//   TikTok / Threads: NOT readable by this build (scope/app-review gated) — honest banner, no data.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - The fetched metrics (nil = the provider did not report it; never a fake 0)

struct PostMetrics: Codable, Equatable {
    var impressions: Int? = nil
    var likes: Int? = nil
    var comments: Int? = nil
    var shares: Int? = nil
    var views: Int? = nil
    var fetchedAt: Date = Date()

    var hasAnyValue: Bool {
        impressions != nil || likes != nil || comments != nil || shares != nil || views != nil
    }
    /// likes+comments+shares over the KNOWN fields only; nil when none of the three was reported
    /// (so we never log a fabricated 0 into engagement history).
    var knownEngagement: Int? {
        let known = [likes, comments, shares].compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// Sum a list of pulls field-by-field. A field stays nil unless at least one pull reported it,
    /// so a per-platform total never turns "unreported" into a zero. nil when nothing was reported.
    static func combined(_ list: [PostMetrics]) -> PostMetrics? {
        guard list.contains(where: { $0.hasAnyValue }) else { return nil }
        func sum(_ kp: KeyPath<PostMetrics, Int?>) -> Int? {
            let vals = list.compactMap { $0[keyPath: kp] }
            return vals.isEmpty ? nil : vals.reduce(0, +)
        }
        var out = PostMetrics(fetchedAt: list.map(\.fetchedAt).max() ?? Date())
        out.impressions = sum(\.impressions)
        out.likes = sum(\.likes)
        out.comments = sum(\.comments)
        out.shares = sum(\.shares)
        out.views = sum(\.views)
        return out
    }
}

// MARK: - Provider receipt (the id the publish path captured in publishDetail)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Which provider object a published ScheduledPost points at. The publish path stores either a
/// permalink or "Post id {id}" in publishDetail — this parses BOTH shapes back into the id the
/// metrics endpoints need. Pure + testable; honest nil when no receipt was captured.
struct PostInsightsReceipt: Equatable {
    var platform: SocialPlatform
    var postID: String

    static func extract(from post: ScheduledPost) -> PostInsightsReceipt? {
        guard post.publishState == "published" else { return nil }
        // platformRaw is authoritative (the Publisher writes it); the channel string carries the
        // same rawValue for queue rows, and SocialPublisher covers legacy lowercase channels.
        let platform = post.platformRaw.flatMap(SocialPlatform.init(rawValue:))
            ?? SocialPlatform(rawValue: post.channel)
            ?? SocialPublisher.platform(for: post.channel)
        guard let platform else { return nil }
        guard let detail = post.publishDetail,
              let id = postID(fromDetail: detail, platform: platform) else { return nil }
        return PostInsightsReceipt(platform: platform, postID: id)
    }

    /// Parse a publishDetail string ("Post id 123" or a permalink) into the provider post id.
    static func postID(fromDetail detail: String, platform: SocialPlatform) -> String? {
        let d = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return nil }
        if d.hasPrefix("Post id ") {
            let id = String(d.dropFirst("Post id ".count)).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
        guard let url = URL(string: d), let host = url.host?.lowercased() else { return nil }
        switch platform {
        case .x:
            // https://x.com/i/web/status/{id}
            guard host.hasSuffix("x.com") || host.hasSuffix("twitter.com") else { return nil }
            let last = url.lastPathComponent
            return (!last.isEmpty && last.allSatisfy(\.isNumber)) ? last : nil
        case .youtube:
            // https://youtu.be/{id}
            guard host.hasSuffix("youtu.be") || host.hasSuffix("youtube.com") else { return nil }
            let last = url.lastPathComponent
            return (last.isEmpty || last == "/") ? nil : last
        case .facebook:
            // https://facebook.com/{page-id}_{post-id} (or a bare video id)
            guard host.hasSuffix("facebook.com") else { return nil }
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return path.isEmpty ? nil : path
        default:
            return nil   // other networks store "Post id …", handled above
        }
    }
}
#endif // circuit-convert

// MARK: - Errors (every failure the UI can surface; no silent success)

enum PostInsightsError: LocalizedError, Equatable {
    case notConnected(SocialPlatform)
    case noReceipt(SocialPlatform)
    case unsupported(SocialPlatform, String)
    case http(SocialPlatform, Int, String)
    case network(SocialPlatform, String)
    case badResponse(SocialPlatform)
    /// The buyer has not allowed this network to receive data (or withdrew it, or the disclosure
    /// changed). Its own case so a refusal can never be shown — or retried — as an outage.
    case consentRequired(SocialPlatform, String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let p):
            return "Connect your \(p.rawValue) account to fetch metrics — no credential is stored on this device."
        case .noReceipt(let p):
            return "\(p.rawValue): no provider receipt was captured for this post, so there's nothing to look up."
        case .unsupported(let p, let why):
            return "\(p.rawValue): \(why)"
        case .http(let p, let code, let msg):
            return "\(p.rawValue) API error (\(code)): \(msg)"
        case .network(let p, let msg):
            return "\(p.rawValue): network error — \(msg)"
        case .badResponse(let p):
            return "\(p.rawValue): the API returned a response we couldn't read."
        case .consentRequired(_, let refusal):
            return refusal
        }
    }
}

// MARK: - Pure request builders + parsers (Foundation-only; testable by shape)

enum PostInsightsAPI {

    // MARK: capability (which networks THIS build can read; honest reasons for the rest)

    static func readable(_ p: SocialPlatform) -> Bool {
        switch p {
        case .x, .facebook, .instagram, .linkedin, .youtube: return true
        case .tiktok, .threads, .pinterest:                  return false
        }
    }

    /// Honest reason a network's metrics are NOT readable by this build (nil = readable).
    static func unreadableReason(_ p: SocialPlatform) -> String? {
        switch p {
        case .tiktok:
            return "TikTok's video-query API needs a separate app approval (video.list scope) this build doesn't request."
        case .threads:
            return "Threads insights need the threads_manage_insights scope, which the connect flow doesn't request yet."
        case .pinterest:
            return "Pinterest's pin-analytics endpoint isn't wired into this build yet — pins publish, but metrics reading is still to come."
        default:
            return nil
        }
    }

    // MARK: shared helpers

    private static func bearer(_ req: inout URLRequest, _ token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// Coerce a provider count (Int / NSNumber / numeric String — YouTube sends strings) to Int.
    static func asInt(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }

    // MARK: X — GET /2/tweets?ids=…&tweet.fields=public_metrics[,organic_metrics]

    static func xTweetMetrics(tweetID: String, token: String, includeOrganic: Bool) -> URLRequest? {
        let id = tweetID.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, !id.isEmpty else { return nil }
        var c = URLComponents(string: "https://api.x.com/2/tweets")
        let fields = includeOrganic ? "public_metrics,organic_metrics" : "public_metrics"
        c?.queryItems = [URLQueryItem(name: "ids", value: id),
                         URLQueryItem(name: "tweet.fields", value: fields)]
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        bearer(&req, token)
        return req
    }

    /// Organic metrics (author-only) win when present; public_metrics fill the rest.
    /// nil when the response carries no usable metrics (e.g. 200-with-errors, organic denied).
    static func parseXMetrics(_ json: [String: Any], now: Date = Date()) -> PostMetrics? {
        guard let arr = json["data"] as? [[String: Any]], let first = arr.first else { return nil }
        let pub = first["public_metrics"] as? [String: Any]
        let organic = first["organic_metrics"] as? [String: Any]
        var m = PostMetrics(fetchedAt: now)
        m.likes = asInt(organic?["like_count"]) ?? asInt(pub?["like_count"])
        m.comments = asInt(organic?["reply_count"]) ?? asInt(pub?["reply_count"])
        let retweets = asInt(organic?["retweet_count"]) ?? asInt(pub?["retweet_count"])
        let quotes = asInt(pub?["quote_count"])
        if let r = retweets { m.shares = r + (quotes ?? 0) } else { m.shares = quotes }
        m.impressions = asInt(organic?["impression_count"]) ?? asInt(pub?["impression_count"])
        return m.hasAnyValue ? m : nil
    }

    // MARK: Facebook — GET /{post-id}?fields=likes/comments summaries + shares (Page token)

    static func facebookPostMetrics(postID: String, pageToken: String) -> URLRequest? {
        let id = postID.trimmingCharacters(in: .whitespaces)
        guard !pageToken.isEmpty, !id.isEmpty else { return nil }
        var c = URLComponents(string: "https://graph.facebook.com/\(SocialPublishAPI.metaVersion)/\(id)")
        c?.queryItems = [URLQueryItem(name: "fields", value: "likes.summary(true),comments.summary(true),shares"),
                         URLQueryItem(name: "access_token", value: pageToken)]
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        return req
    }

    static func parseFacebookMetrics(_ json: [String: Any], now: Date = Date()) -> PostMetrics? {
        var m = PostMetrics(fetchedAt: now)
        if let likes = json["likes"] as? [String: Any], let summary = likes["summary"] as? [String: Any] {
            m.likes = asInt(summary["total_count"])
        }
        if let comments = json["comments"] as? [String: Any], let summary = comments["summary"] as? [String: Any] {
            m.comments = asInt(summary["total_count"])
        }
        if let shares = json["shares"] as? [String: Any] {
            m.shares = asInt(shares["count"])
        }
        return m.hasAnyValue ? m : nil
    }

    // MARK: Instagram — media fields + tolerant insights (Graph, Instagram Login token)

    static func instagramMediaFields(mediaID: String, token: String) -> URLRequest? {
        let id = mediaID.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, !id.isEmpty else { return nil }
        var c = URLComponents(string: "https://graph.instagram.com/\(SocialPublishAPI.metaVersion)/\(id)")
        c?.queryItems = [URLQueryItem(name: "fields", value: "like_count,comments_count"),
                         URLQueryItem(name: "access_token", value: token)]
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        return req
    }

    /// Optional second pull: /insights views+shares. Failures here are TOLERATED (some media
    /// kinds/accounts don't expose them) — the fields pull alone is a valid result.
    static func instagramMediaInsights(mediaID: String, token: String) -> URLRequest? {
        let id = mediaID.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, !id.isEmpty else { return nil }
        var c = URLComponents(string: "https://graph.instagram.com/\(SocialPublishAPI.metaVersion)/\(id)/insights")
        c?.queryItems = [URLQueryItem(name: "metric", value: "views,shares"),
                         URLQueryItem(name: "access_token", value: token)]
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        return req
    }

    static func parseInstagramFields(_ json: [String: Any], now: Date = Date()) -> PostMetrics? {
        var m = PostMetrics(fetchedAt: now)
        m.likes = asInt(json["like_count"])
        m.comments = asInt(json["comments_count"])
        return m.hasAnyValue ? m : nil
    }

    /// Merge the insights pull ({"data":[{"name":…,"values":[{"value":n}]}…]}) into `base`.
    /// Unrecognized/absent metrics leave the field nil — never a zero.
    static func mergeInstagramInsights(_ json: [String: Any], into base: PostMetrics) -> PostMetrics {
        var m = base
        guard let data = json["data"] as? [[String: Any]] else { return m }
        for entry in data {
            guard let name = entry["name"] as? String else { continue }
            var value: Int? = nil
            if let values = entry["values"] as? [[String: Any]], let first = values.first {
                value = asInt(first["value"])
            }
            if value == nil, let total = entry["total_value"] as? [String: Any] {
                value = asInt(total["value"])
            }
            guard let value else { continue }
            switch name {
            case "views":  m.views = value
            case "shares": m.shares = value
            default: break
            }
        }
        return m
    }

    // MARK: LinkedIn — GET /v2/socialActions/{urn}

    static func linkedinSocialActions(urn: String, token: String) -> URLRequest? {
        let raw = urn.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, !raw.isEmpty else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.linkedin.com/v2/socialActions/\(encoded)") else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        bearer(&req, token)
        req.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
        return req
    }

    static func parseLinkedInMetrics(_ json: [String: Any], now: Date = Date()) -> PostMetrics? {
        var m = PostMetrics(fetchedAt: now)
        if let likes = json["likesSummary"] as? [String: Any] {
            m.likes = asInt(likes["totalLikes"]) ?? asInt(likes["aggregatedTotalLikes"]) ?? asInt(likes["count"])
        }
        if let comments = json["commentsSummary"] as? [String: Any] {
            m.comments = asInt(comments["totalFirstLevelComments"]) ?? asInt(comments["aggregatedTotalComments"]) ?? asInt(comments["count"])
        }
        return m.hasAnyValue ? m : nil
    }

    // MARK: YouTube — GET /youtube/v3/videos?part=statistics

    static func youtubeStatistics(videoID: String, token: String) -> URLRequest? {
        let id = videoID.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, !id.isEmpty else { return nil }
        var c = URLComponents(string: "https://www.googleapis.com/youtube/v3/videos")
        c?.queryItems = [URLQueryItem(name: "part", value: "statistics"),
                         URLQueryItem(name: "id", value: id)]
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url); req.timeoutInterval = 30
        bearer(&req, token)
        return req
    }

    static func parseYouTubeMetrics(_ json: [String: Any], now: Date = Date()) -> PostMetrics? {
        guard let items = json["items"] as? [[String: Any]], let first = items.first,
              let stats = first["statistics"] as? [String: Any] else { return nil }
        var m = PostMetrics(fetchedAt: now)
        m.views = asInt(stats["viewCount"])
        m.likes = asInt(stats["likeCount"])
        m.comments = asInt(stats["commentCount"])
        return m.hasAnyValue ? m : nil
    }
}

// MARK: - Executing client (real HTTPS through the egress choke point; injectable for tests)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct PostInsightsClient {
    /// Injectable seam. Production leaves it nil and the choke point uses its own transport;
    /// a suite passes a stub. This file names no URLSession — the socket lives in ConsentedEgress.
    var transport: OutboundTransport? = nil

    func fetch(platform: SocialPlatform, postID: String, token: String) async -> Result<PostMetrics, PostInsightsError> {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .failure(.notConnected(platform)) }
        let id = postID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return .failure(.noReceipt(platform)) }
        switch platform {
        case .x:         return await fetchX(postID: id, token: t)
        case .facebook:  return await fetchFacebook(postID: id, token: t)
        case .instagram: return await fetchInstagram(mediaID: id, token: t)
        case .linkedin:  return await fetchLinkedIn(urn: id, token: t)
        case .youtube:   return await fetchYouTube(videoID: id, token: t)
        case .tiktok, .threads, .pinterest:
            return .failure(.unsupported(platform, PostInsightsAPI.unreadableReason(platform) ?? "metrics aren't readable in this build."))
        }
    }

    // MARK: X (organic_metrics is author-scoped and can be denied → honest public fallback)

    private func fetchX(postID: String, token: String) async -> Result<PostMetrics, PostInsightsError> {
        guard let organicReq = PostInsightsAPI.xTweetMetrics(tweetID: postID, token: token, includeOrganic: true) else {
            return .failure(.badResponse(.x))
        }
        switch await runRaw(organicReq, platform: .x) {
        case .success(let json):
            if let m = PostInsightsAPI.parseXMetrics(json) { return .success(m) }
            // 200-with-errors (organic denied) → fall through to the public-only retry.
        case .failure(let e):
            if case .http = e { /* organic fields rejected → retry public-only */ } else { return .failure(e) }
        }
        guard let publicReq = PostInsightsAPI.xTweetMetrics(tweetID: postID, token: token, includeOrganic: false) else {
            return .failure(.badResponse(.x))
        }
        switch await runRaw(publicReq, platform: .x) {
        case .success(let json):
            guard let m = PostInsightsAPI.parseXMetrics(json) else { return .failure(.badResponse(.x)) }
            return .success(m)
        case .failure(let e):
            return .failure(e)
        }
    }

    // MARK: Facebook (resolve the managed Page token the same way the publish path does)

    private func fetchFacebook(postID: String, token: String) async -> Result<PostMetrics, PostInsightsError> {
        guard let acctReq = SocialPublishAPI.facebookAccounts(token: token) else {
            return .failure(.notConnected(.facebook))
        }
        let pageToken: String
        switch await runRaw(acctReq, platform: .facebook) {
        case .success(let json):
            guard let list = json["data"] as? [[String: Any]], let first = list.first,
                  let pt = first["access_token"] as? String, !pt.isEmpty else {
                return .failure(.unsupported(.facebook, "couldn't find a managed Page for this token — reading post metrics needs pages_read_engagement."))
            }
            pageToken = pt
        case .failure(let e):
            return .failure(e)
        }
        guard let req = PostInsightsAPI.facebookPostMetrics(postID: postID, pageToken: pageToken) else {
            return .failure(.badResponse(.facebook))
        }
        switch await runRaw(req, platform: .facebook) {
        case .success(let json):
            guard let m = PostInsightsAPI.parseFacebookMetrics(json) else { return .failure(.badResponse(.facebook)) }
            return .success(m)
        case .failure(let e):
            return .failure(e)
        }
    }

    // MARK: Instagram (fields pull is authoritative; insights merge is tolerant)

    private func fetchInstagram(mediaID: String, token: String) async -> Result<PostMetrics, PostInsightsError> {
        guard let fieldsReq = PostInsightsAPI.instagramMediaFields(mediaID: mediaID, token: token) else {
            return .failure(.badResponse(.instagram))
        }
        var metrics: PostMetrics
        switch await runRaw(fieldsReq, platform: .instagram) {
        case .success(let json):
            guard let m = PostInsightsAPI.parseInstagramFields(json) else { return .failure(.badResponse(.instagram)) }
            metrics = m
        case .failure(let e):
            return .failure(e)
        }
        // Views/shares live behind /insights; not every media kind exposes them — tolerate failure.
        if let insightsReq = PostInsightsAPI.instagramMediaInsights(mediaID: mediaID, token: token),
           case .success(let json) = await runRaw(insightsReq, platform: .instagram) {
            metrics = PostInsightsAPI.mergeInstagramInsights(json, into: metrics)
        }
        return .success(metrics)
    }

    // MARK: LinkedIn

    private func fetchLinkedIn(urn: String, token: String) async -> Result<PostMetrics, PostInsightsError> {
        guard let req = PostInsightsAPI.linkedinSocialActions(urn: urn, token: token) else {
            return .failure(.badResponse(.linkedin))
        }
        switch await runRaw(req, platform: .linkedin) {
        case .success(let json):
            guard let m = PostInsightsAPI.parseLinkedInMetrics(json) else { return .failure(.badResponse(.linkedin)) }
            return .success(m)
        case .failure(let e):
            return .failure(e)
        }
    }

    // MARK: YouTube

    private func fetchYouTube(videoID: String, token: String) async -> Result<PostMetrics, PostInsightsError> {
        guard let req = PostInsightsAPI.youtubeStatistics(videoID: videoID, token: token) else {
            return .failure(.badResponse(.youtube))
        }
        switch await runRaw(req, platform: .youtube) {
        case .success(let json):
            guard let m = PostInsightsAPI.parseYouTubeMetrics(json) else { return .failure(.badResponse(.youtube)) }
            return .success(m)
        case .failure(let e):
            return .failure(e)
        }
    }

    // MARK: transport (same contract as SocialPublishService.runRaw)

    private func runRaw(_ req: URLRequest, platform: SocialPlatform) async -> Result<[String: Any], PostInsightsError> {
        do {
            // Reading insights still ships the buyer's access token and the post id to the network,
            // so it leaves through the same choke point as publishing. `transport` stays injectable.
            let (data, resp) = try await ConsentedEgress.send(req, to: platform.transmissionProvider,
                                                              via: transport)
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failure(.http(platform, http.statusCode,
                                      SocialPublishService.apiMessage(json, fallback: String(data: data, encoding: .utf8) ?? "")))
            }
            // Meta/Graph can return 200 with an "error" object.
            if let errObj = json["error"] as? [String: Any], let msg = errObj["message"] as? String {
                return .failure(.http(platform, (errObj["code"] as? Int) ?? 0, msg))
            }
            return .success(json)
        } catch let refusal as ConsentedEgressError {
            return .failure(.consentRequired(platform, refusal.errorDescription ?? "Nothing was sent."))
        } catch {
            return .failure(.network(platform, error.localizedDescription))
        }
    }
}
#endif // circuit-convert

// MARK: - Persisted cache (per-post last pull + min refetch interval + logged-to-history marks)

enum PostInsightsStore {
    /// Manual per-post refetch floor — protects the buyer's own rate limits, not a fake delay.
    static let minRefreshInterval: TimeInterval = 60

    struct Entry: Codable, Equatable {
        var platform: String
        var providerPostID: String
        var metrics: PostMetrics
    }
    struct State: Codable, Equatable {
        var entries: [String: Entry] = [:]      // key = ScheduledPost.id.uuidString
        var loggedPostIDs: [String] = []        // posts already pushed into engagement history
    }

    static func fileURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("PostInsights.json")
    }

    static func load() -> State {
        guard let data = try? Data(contentsOf: fileURL()),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return State() }
        return state
    }

    static func save(_ state: State) {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: fileURL(), options: .atomic)
        }
    }

    /// Pure throttle rule: fetch when never fetched, or when the min interval has elapsed.
    static func shouldFetch(last: Date?, now: Date = Date(), minInterval: TimeInterval = minRefreshInterval) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= minInterval
    }

    static func remember(postID: UUID, platform: SocialPlatform, providerPostID: String, metrics: PostMetrics) {
        var state = load()
        state.entries[postID.uuidString] = Entry(platform: platform.rawValue,
                                                 providerPostID: providerPostID, metrics: metrics)
        save(state)
    }

    static func cachedMetrics(postID: UUID) -> PostMetrics? {
        load().entries[postID.uuidString]?.metrics
    }

    static func markLogged(_ postID: UUID) {
        var state = load()
        if !state.loggedPostIDs.contains(postID.uuidString) {
            state.loggedPostIDs.append(postID.uuidString)
            save(state)
        }
    }

    static func isLogged(_ postID: UUID) -> Bool {
        load().loggedPostIDs.contains(postID.uuidString)
    }
}

// MARK: - Engagement-history bridge (feeds BestTimeEngine from REAL pulled numbers)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum PostInsightsEngagement {
    /// Build a PostEngagement row from a real pull. nil when NONE of likes/comments/shares was
    /// reported (we never log a fabricated 0). weekday/hour come from the real publish time.
    static func entry(for post: ScheduledPost, metrics: PostMetrics,
                      calendar: Calendar = .current) -> PostEngagement? {
        guard let total = metrics.knownEngagement else { return nil }
        let when = post.publishedAt ?? post.scheduledAt
        return PostEngagement(weekday: calendar.component(.weekday, from: when),
                              hour: calendar.component(.hour, from: when),
                              engagement: total,
                              channel: post.channel)
    }
}
#endif // circuit-convert
