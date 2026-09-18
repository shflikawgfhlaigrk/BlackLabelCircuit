// Black Label Marketing — REAL per-network posting clients.
//
// This is the layer the Founder directive asked for: given the buyer's OWN stored OAuth token
// (minted on-device by SocialOAuthSession, kept in Keychain by SocialCredentialStore), actually
// CALL each network's publish endpoint over HTTPS and return a real post id or a real error.
// Nothing here fabricates a success: every path ends in either an id the provider returned or an
// honest, provider-sourced error / precondition message surfaced to the UI.
//
// Design:
//   • The request BUILDERS are pure (Foundation only, no AppKit/Security/SwiftUI) so they compile
//     into the headless test module and are locked by unit tests on URL/method/header/body shape.
//   • The executing SERVICE (SocialPublishService) runs those requests through ConsentedEgress,
//     resolving the identity each API needs (Meta page id + page token, Threads user id, LinkedIn
//     person urn) from the same token — the buyer never pastes an internal id.
//   • Media-required networks with no media return .needsMedia (honest), never a fake post.
//   • Networks whose desktop path is app-review / relay gated (TikTok) return an honest precondition.
//
// Endpoints verified against live provider docs (Meta Graph v21, Threads v1.0, X API v2 + upload
// v1.1, LinkedIn UGC Posts, YouTube Data API v3, TikTok Content Posting API v2) — 2025/2026.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - What the buyer wants to publish

/// A single post the buyer is publishing to one network from their own connected account.
struct SocialPost {
    var text: String = ""
    /// A local file (rendered reel .mp4 / image) for APIs that accept raw bytes:
    /// X (v1.1 upload), TikTok (FILE_UPLOAD), YouTube (resumable), LinkedIn/FB (video upload).
    var mediaFileURL: URL? = nil
    /// A public HTTPS URL for APIs that FETCH the media themselves (Instagram, Threads).
    var mediaPublicURL: String? = nil
    /// True when the media is a video (vs a still image). Drives IG REELS vs IMAGE, YT always video.
    var mediaIsVideo: Bool = false
    /// Optional title (YouTube video title; ignored elsewhere).
    var title: String = ""

    var hasLocalMedia: Bool { mediaFileURL != nil }
    var hasPublicMedia: Bool { !(mediaPublicURL ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    var hasAnyMedia: Bool { hasLocalMedia || hasPublicMedia }
}

/// The account context for one network: the buyer's own token, plus any id/secondary token the
/// specific API requires (resolved on-device from the token, never hand-entered).
struct SocialAccount {
    var accessToken: String
    /// IG business-user id / FB page id / Threads user id / LinkedIn person sub — API dependent.
    var accountID: String? = nil
    /// FB page access token (differs from the user token; resolved via /me/accounts).
    var pageAccessToken: String? = nil
}

/// A successful publish: the id the provider returned (+ a permalink when derivable).
struct SocialPostResult: Equatable {
    var platform: SocialPlatform
    var id: String
    var permalink: String? = nil
}

/// Every failure the UI can surface. Each case maps to an honest, human message — no silent success.
enum SocialPostError: LocalizedError, Equatable {
    case notConnected(SocialPlatform)
    /// The buyer has not granted (or has withdrawn) consent to transmit content + credentials to
    /// this platform. Carries the refusal text verbatim from Sources/ProviderConsent.swift.
    case consentRequired(SocialPlatform, String)
    case needsAccountID(SocialPlatform, String)
    case needsMedia(SocialPlatform, String)
    case needsPublicURL(SocialPlatform, String)
    case relayOnly(SocialPlatform, String)
    case appReviewRequired(SocialPlatform, String)
    case processingTimeout(SocialPlatform)
    case http(SocialPlatform, Int, String)
    case network(SocialPlatform, String)
    case badResponse(SocialPlatform)

    var errorDescription: String? {
        switch self {
        case .notConnected(let p):
            return "Connect your \(p.rawValue) account first — no credential is stored on this device."
        case .consentRequired(_, let refusal):
            return refusal
        case .needsAccountID(let p, let what):
            return "\(p.rawValue): couldn't resolve your \(what). \(SocialPostError.accountHint(p))"
        case .needsMedia(let p, let what):
            return "\(p.rawValue) requires \(what). Attach a rendered reel or image and try again."
        case .needsPublicURL(let p, let what):
            return "\(p.rawValue) fetches media by URL, so it needs a public HTTPS \(what). Publish the reel to a public URL first (or use the Reel Relay)."
        case .relayOnly(let p, let why):
            return "\(p.rawValue): \(why)"
        case .appReviewRequired(let p, let why):
            return "\(p.rawValue): \(why)"
        case .processingTimeout(let p):
            return "\(p.rawValue) is still processing the media. It was accepted — check the app in a minute; it usually finishes on its own."
        case .http(let p, let code, let msg):
            return "\(p.rawValue) API error (\(code)): \(msg)"
        case .network(let p, let msg):
            return "\(p.rawValue): network error — \(msg)"
        case .badResponse(let p):
            return "\(p.rawValue): the API returned a response we couldn't read."
        }
    }

    private static func accountHint(_ p: SocialPlatform) -> String {
        switch p {
        case .instagram: return "Instagram publishing needs an Instagram Business/Creator account linked to a Facebook Page."
        case .facebook:  return "Facebook publishing needs a Page you manage (grant the pages_manage_posts scope)."
        case .threads:   return "Reconnect Threads so we can read your Threads user id."
        case .linkedin:  return "Reconnect LinkedIn with the openid+profile scopes so we can read your member id."
        case .pinterest: return "Pinterest pins save to a board. Create at least one board in your own Pinterest account, then try again."
        default:         return "Reconnect the account and try again."
        }
    }
}

// MARK: - Pure request builders (Foundation-only; unit-tested by shape)
//
// One namespace per network. Every builder returns a fully-formed URLRequest? (nil only on
// honest bad input, e.g. an empty token) so the executing service never has to hand-assemble a
// request and the tests can assert the exact wire format without a network.
enum SocialPublishAPI {

    static let metaVersion = "v21.0"
    static let threadsVersion = "v1.0"

    private static func bearer(_ req: inout URLRequest, _ token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    private static func jsonBody(_ req: inout URLRequest, _ obj: [String: Any]) {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: obj)
    }
    /// x-www-form-urlencoded body (spaces as %20, provider-safe) for Meta/Threads/TikTok-ish forms.
    static func formEncoded(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return items.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(ek)=\(ev)"
        }.joined(separator: "&")
    }

    // MARK: X (Twitter) — API v2 tweet + v1.1 chunked media upload

    /// POST https://api.x.com/2/tweets  { "text": ... [, "media": {"media_ids": [...]}] }
    static func xTweet(text: String, token: String, mediaIDs: [String] = []) -> URLRequest? {
        guard !token.isEmpty else { return nil }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !mediaIDs.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://api.x.com/2/tweets")!)
        req.httpMethod = "POST"; bearer(&req, token)
        var payload: [String: Any] = [:]
        if !body.isEmpty { payload["text"] = body }
        if !mediaIDs.isEmpty { payload["media"] = ["media_ids": mediaIDs] }
        jsonBody(&req, payload)
        return req
    }

    /// v1.1 media upload INIT (command=INIT). total_bytes + media_type + media_category.
    static func xMediaInit(totalBytes: Int, mimeType: String, category: String, token: String) -> URLRequest? {
        guard !token.isEmpty, totalBytes > 0 else { return nil }
        var req = URLRequest(url: URL(string: "https://upload.twitter.com/1.1/media/upload.json")!)
        req.httpMethod = "POST"; bearer(&req, token)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncoded([("command", "INIT"), ("total_bytes", String(totalBytes)),
                                    ("media_type", mimeType), ("media_category", category)]).data(using: .utf8)
        return req
    }

    /// v1.1 media upload APPEND (multipart: command, media_id, segment_index, media bytes).
    static func xMediaAppend(mediaID: String, segmentIndex: Int, chunk: Data, token: String) -> URLRequest? {
        guard !token.isEmpty, !mediaID.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://upload.twitter.com/1.1/media/upload.json")!)
        req.httpMethod = "POST"; bearer(&req, token)
        let boundary = "blm.\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var b = Data()
        func field(_ name: String, _ value: String) {
            b.append("--\(boundary)\r\n".data(using: .utf8)!)
            b.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            b.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("command", "APPEND"); field("media_id", mediaID); field("segment_index", String(segmentIndex))
        b.append("--\(boundary)\r\n".data(using: .utf8)!)
        b.append("Content-Disposition: form-data; name=\"media\"\r\n".data(using: .utf8)!)
        b.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        b.append(chunk); b.append("\r\n".data(using: .utf8)!)
        b.append("--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = b
        return req
    }

    /// v1.1 media upload FINALIZE (command=FINALIZE, media_id).
    static func xMediaFinalize(mediaID: String, token: String) -> URLRequest? {
        guard !token.isEmpty, !mediaID.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://upload.twitter.com/1.1/media/upload.json")!)
        req.httpMethod = "POST"; bearer(&req, token)
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncoded([("command", "FINALIZE"), ("media_id", mediaID)]).data(using: .utf8)
        return req
    }

    // MARK: LinkedIn — UGC Posts API (author = urn:li:person:{sub})

    /// GET https://api.linkedin.com/v2/userinfo → the OIDC `sub` we turn into urn:li:person:{sub}.
    static func linkedinUserinfo(token: String) -> URLRequest? {
        guard !token.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://api.linkedin.com/v2/userinfo")!)
        bearer(&req, token)
        return req
    }

    static func linkedinPersonURN(sub: String) -> String { "urn:li:person:\(sub)" }

    /// POST https://api.linkedin.com/v2/ugcPosts — a text share authored by the member.
    static func linkedinTextPost(authorURN: String, text: String, token: String) -> URLRequest? {
        guard !token.isEmpty, !authorURN.isEmpty else { return nil }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://api.linkedin.com/v2/ugcPosts")!)
        req.httpMethod = "POST"; bearer(&req, token)
        req.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
        let payload: [String: Any] = [
            "author": authorURN,
            "lifecycleState": "PUBLISHED",
            "specificContent": [
                "com.linkedin.ugc.ShareContent": [
                    "shareCommentary": ["text": body],
                    "shareMediaCategory": "NONE"
                ]
            ],
            "visibility": ["com.linkedin.ugc.MemberNetworkVisibility": "PUBLIC"]
        ]
        jsonBody(&req, payload)
        return req
    }

    // MARK: Facebook — Page feed (message post to a Page the buyer manages)

    /// GET /me/accounts → the Pages (id + page access_token) the user manages.
    static func facebookAccounts(token: String) -> URLRequest? {
        guard !token.isEmpty else { return nil }
        var c = URLComponents(string: "https://graph.facebook.com/\(metaVersion)/me/accounts")
        c?.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = c?.url else { return nil }
        return URLRequest(url: url)
    }

    /// POST /{page-id}/feed  message=…  (uses the PAGE access token, not the user token).
    static func facebookPageFeed(pageID: String, message: String, pageToken: String, linkURL: String? = nil) -> URLRequest? {
        guard !pageToken.isEmpty, !pageID.isEmpty else { return nil }
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return nil }
        guard let url = URL(string: "https://graph.facebook.com/\(metaVersion)/\(pageID)/feed") else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var items = [("message", msg), ("access_token", pageToken)]
        if let l = linkURL, !l.isEmpty { items.append(("link", l)) }
        req.httpBody = formEncoded(items).data(using: .utf8)
        return req
    }

    /// POST /{page-id}/videos with the local MP4 bytes. Returns the real Facebook video id.
    static func facebookPageVideo(pageID: String, description: String, pageToken: String, data: Data) -> URLRequest? {
        guard !pageToken.isEmpty, !pageID.isEmpty, !data.isEmpty else { return nil }
        guard let url = URL(string: "https://graph.facebook.com/\(metaVersion)/\(pageID)/videos") else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 180
        let boundary = "blm.\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        field("description", description); field("access_token", pageToken)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"source\"; filename=\"video.mp4\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: video/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(data); body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        return req
    }

    // MARK: Threads — text/media create-container → publish (author = threads user id)

    /// GET /me?fields=id → the Threads user id.
    static func threadsMe(token: String) -> URLRequest? {
        guard !token.isEmpty else { return nil }
        var c = URLComponents(string: "https://graph.threads.net/\(threadsVersion)/me")
        c?.queryItems = [URLQueryItem(name: "fields", value: "id"),
                         URLQueryItem(name: "access_token", value: token)]
        guard let url = c?.url else { return nil }
        return URLRequest(url: url)
    }

    /// POST /{user-id}/threads  media_type=TEXT (or IMAGE/VIDEO + url) → returns a creation id.
    static func threadsCreate(userID: String, text: String, token: String,
                              mediaType: String = "TEXT", mediaURL: String? = nil) -> URLRequest? {
        guard !token.isEmpty, !userID.isEmpty else { return nil }
        var items = [("media_type", mediaType), ("access_token", token)]
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { items.append(("text", body)) }
        if mediaType == "IMAGE", let u = mediaURL { items.append(("image_url", u)) }
        if mediaType == "VIDEO", let u = mediaURL { items.append(("video_url", u)) }
        guard mediaType != "TEXT" || !body.isEmpty else { return nil }
        guard let url = URL(string: "https://graph.threads.net/\(threadsVersion)/\(userID)/threads") else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncoded(items).data(using: .utf8)
        return req
    }

    /// POST /{user-id}/threads_publish  creation_id=… → the published media id.
    static func threadsPublish(userID: String, creationID: String, token: String) -> URLRequest? {
        guard !token.isEmpty, !userID.isEmpty, !creationID.isEmpty else { return nil }
        guard let url = URL(string: "https://graph.threads.net/\(threadsVersion)/\(userID)/threads_publish") else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncoded([("creation_id", creationID), ("access_token", token)]).data(using: .utf8)
        return req
    }

    // MARK: Instagram — image container (video reels reuse SocialOAuth.instagramCreateReelRequest)

    /// Instagram Login tokens expose their publishing user id through /me.
    static func instagramMe(token: String) -> URLRequest? {
        guard !token.isEmpty else { return nil }
        var c = URLComponents(string: "https://graph.instagram.com/me")
        c?.queryItems = [URLQueryItem(name: "fields", value: "user_id,username"),
                         URLQueryItem(name: "access_token", value: token)]
        guard let url = c?.url else { return nil }
        return URLRequest(url: url)
    }

    /// POST /{ig-user-id}/media  image_url=… → a container id (then publish with media_publish).
    static func instagramCreateImage(igUserID: String, imageURL: String, caption: String, token: String) -> URLRequest? {
        guard !token.isEmpty, !igUserID.isEmpty, imageURL.lowercased().hasPrefix("https://") else { return nil }
        var c = URLComponents(string: "https://graph.instagram.com/\(metaVersion)/\(igUserID)/media")
        c?.queryItems = [URLQueryItem(name: "image_url", value: imageURL),
                         URLQueryItem(name: "caption", value: caption),
                         URLQueryItem(name: "access_token", value: token)]
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"; return req
    }

    /// GET /{creation-id}?fields=status_code → poll IG container processing (FINISHED/IN_PROGRESS/ERROR).
    static func instagramContainerStatus(creationID: String, token: String) -> URLRequest? {
        guard !token.isEmpty, !creationID.isEmpty else { return nil }
        var c = URLComponents(string: "https://graph.instagram.com/\(metaVersion)/\(creationID)")
        c?.queryItems = [URLQueryItem(name: "fields", value: "status_code"),
                         URLQueryItem(name: "access_token", value: token)]
        guard let url = c?.url else { return nil }
        return URLRequest(url: url)
    }

    // MARK: YouTube — Data API v3 videos.insert (resumable upload)

    /// POST …/upload/youtube/v3/videos?uploadType=resumable  — starts the session; the response
    /// `Location` header is the upload URL we PUT the bytes to. Body = snippet + status JSON.
    static func youtubeResumableInit(title: String, description: String, token: String,
                                     privacy: String = "public", contentType: String = "video/*",
                                     contentLength: Int) -> URLRequest? {
        guard !token.isEmpty, contentLength > 0 else { return nil }
        var c = URLComponents(string: "https://www.googleapis.com/upload/youtube/v3/videos")
        c?.queryItems = [URLQueryItem(name: "uploadType", value: "resumable"),
                         URLQueryItem(name: "part", value: "snippet,status")]
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "POST"; bearer(&req, token)
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue(contentType, forHTTPHeaderField: "X-Upload-Content-Type")
        req.setValue(String(contentLength), forHTTPHeaderField: "X-Upload-Content-Length")
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload: [String: Any] = [
            "snippet": ["title": t.isEmpty ? "Untitled" : t, "description": description],
            "status": ["privacyStatus": privacy, "selfDeclaredMadeForKids": false]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return req
    }

    /// PUT the video bytes to the resumable session URL returned by youtubeResumableInit.
    static func youtubeUpload(sessionURL: String, data: Data, contentType: String = "video/*") -> URLRequest? {
        guard let url = URL(string: sessionURL), !data.isEmpty else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(String(data.count), forHTTPHeaderField: "Content-Length")
        req.httpBody = data
        return req
    }

    // MARK: TikTok — Content Posting API v2 (direct post: init → upload → status)

    /// POST /v2/post/publish/video/init/ — reserves a publish_id + upload_url for FILE_UPLOAD.
    static func tiktokInit(title: String, videoSize: Int, token: String,
                           privacy: String = "SELF_ONLY") -> URLRequest? {
        guard !token.isEmpty, videoSize > 0 else { return nil }
        var req = URLRequest(url: URL(string: "https://open.tiktokapis.com/v2/post/publish/video/init/")!)
        req.httpMethod = "POST"; bearer(&req, token)
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "post_info": ["title": title, "privacy_level": privacy,
                          "disable_duet": false, "disable_comment": false, "disable_stitch": false],
            "source_info": ["source": "FILE_UPLOAD", "video_size": videoSize,
                            "chunk_size": videoSize, "total_chunk_count": 1]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return req
    }

    /// PUT the video bytes to the TikTok upload_url returned by tiktokInit (single chunk).
    static func tiktokUpload(uploadURL: String, data: Data, mimeType: String = "video/mp4") -> URLRequest? {
        guard let url = URL(string: uploadURL), !data.isEmpty else { return nil }
        var req = URLRequest(url: url); req.httpMethod = "PUT"
        let n = data.count
        req.setValue("bytes 0-\(n - 1)/\(n)", forHTTPHeaderField: "Content-Range")
        req.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        return req
    }

    /// POST /v2/post/publish/status/fetch/ — poll the publish_id until PUBLISH_COMPLETE / fail.
    static func tiktokStatus(publishID: String, token: String) -> URLRequest? {
        guard !token.isEmpty, !publishID.isEmpty else { return nil }
        var req = URLRequest(url: URL(string: "https://open.tiktokapis.com/v2/post/publish/status/fetch/")!)
        req.httpMethod = "POST"; bearer(&req, token)
        req.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["publish_id": publishID])
        return req
    }

    // MARK: Pinterest — API v5 (boards list → create pin)

    /// GET https://api.pinterest.com/v5/boards — the buyer's own boards. One page is enough to
    /// pick a default destination board; the chosen id is then persisted for later publishes.
    static func pinterestBoards(token: String, pageSize: Int = 25) -> URLRequest? {
        guard !token.isEmpty, pageSize > 0 else { return nil }
        var c = URLComponents(string: "https://api.pinterest.com/v5/boards")
        c?.queryItems = [URLQueryItem(name: "page_size", value: String(pageSize))]
        guard let url = c?.url else { return nil }
        var req = URLRequest(url: url); bearer(&req, token)
        return req
    }

    /// POST https://api.pinterest.com/v5/pins — JSON {board_id, title, description, media_source}.
    /// Pins REQUIRE an image: exactly one of `imageURL` (public HTTPS, Pinterest fetches it) or
    /// `imageData` (raw bytes → image_base64) must be provided, else nil (honest bad input).
    /// Title/description clamp to Pinterest's documented caps (100 / 800 chars).
    static func pinterestCreatePin(boardID: String, title: String, description: String, token: String,
                                   imageURL: String? = nil, imageData: Data? = nil,
                                   imageContentType: String = "image/jpeg") -> URLRequest? {
        guard !token.isEmpty, !boardID.isEmpty else { return nil }
        let mediaSource: [String: Any]
        if let u = imageURL?.trimmingCharacters(in: .whitespaces), !u.isEmpty {
            guard u.lowercased().hasPrefix("https://") else { return nil }
            mediaSource = ["source_type": "image_url", "url": u]
        } else if let d = imageData, !d.isEmpty {
            mediaSource = ["source_type": "image_base64", "content_type": imageContentType,
                           "data": d.base64EncodedString()]
        } else {
            return nil
        }
        var req = URLRequest(url: URL(string: "https://api.pinterest.com/v5/pins")!)
        req.httpMethod = "POST"; bearer(&req, token)
        var payload: [String: Any] = ["board_id": boardID, "media_source": mediaSource]
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { payload["title"] = String(t.prefix(100)) }
        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { payload["description"] = String(desc.prefix(800)) }
        jsonBody(&req, payload)
        return req
    }
}

// MARK: - Pinterest default board (persisted choice; a board id is not a secret)

/// Remembers which of the buyer's own boards pins publish to. Resolved once from GET /v5/boards
/// (first board) and persisted in UserDefaults — board ids are public identifiers, not credentials,
/// so they don't belong in Keychain. `clear()` lets a reconnect under a different account
/// re-resolve the board on the next publish.
enum PinterestBoardStore {
    static let boardIDKey = "social.pinterest.boardID"
    static let boardNameKey = "social.pinterest.boardName"

    static var boardID: String? {
        let v = (UserDefaults.standard.string(forKey: boardIDKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
    static var boardName: String? {
        let v = (UserDefaults.standard.string(forKey: boardNameKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }
    static func save(id: String, name: String?) {
        UserDefaults.standard.set(id, forKey: boardIDKey)
        if let name, !name.isEmpty { UserDefaults.standard.set(name, forKey: boardNameKey) }
        else { UserDefaults.standard.removeObject(forKey: boardNameKey) }
    }
    static func clear() {
        UserDefaults.standard.removeObject(forKey: boardIDKey)
        UserDefaults.standard.removeObject(forKey: boardNameKey)
    }
}

// MARK: - Which networks can publish which shape (honest capability table, testable)

enum SocialPublishCapability {
    /// Can this network publish a TEXT-only post through its API with just the buyer's token?
    static func supportsTextPost(_ p: SocialPlatform) -> Bool {
        switch p {
        case .x, .linkedin, .facebook, .threads:       return true
        case .instagram, .youtube, .tiktok, .pinterest: return false   // media-required
        }
    }
    /// Does this network's DESKTOP publish require a public media URL (it fetches, won't take bytes)?
    static func fetchesMediaByURL(_ p: SocialPlatform) -> Bool {
        switch p { case .instagram, .threads: return true; default: return false }
    }
    /// Is this network's macOS direct-publish path gated behind app-review / relay (not one-tap)?
    static func desktopRelayGated(_ p: SocialPlatform) -> Bool {
        p == .tiktok
    }
    /// Can this network publish a rendered reel straight from a LOCAL .mp4 on desktop — i.e. its API
    /// accepts the raw video bytes with just the buyer's own token? X (v1.1 chunked upload → tweet)
    /// YouTube (resumable upload), Facebook Page Video, and TikTok Content Posting do. Instagram and
    /// Threads fetch media by public URL; LinkedIn currently receives the caption/link share.
    static func supportsLocalVideoPublish(_ p: SocialPlatform) -> Bool {
        switch p {
        case .x, .youtube, .facebook, .tiktok: return true
        default:           return false
        }
    }
    /// A short, honest note shown next to the Publish action for a connected network.
    static func note(_ p: SocialPlatform) -> String {
        switch p {
        case .x:         return "Posts directly to X as a tweet."
        case .linkedin:  return "Posts to your LinkedIn feed as a member share."
        case .facebook:  return "Posts to a Facebook Page you manage."
        case .threads:   return "Posts to Threads."
        case .instagram: return "Instagram needs an image or a public reel URL (Business/Creator account)."
        case .youtube:   return "YouTube publishes a video/Short — attach a rendered reel."
        case .tiktok:    return "Posts through TikTok Content Posting when your TikTok app is approved."
        case .pinterest: return "Creates a Pin on one of your boards — attach an image."
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Executing service (async; real HTTPS through the egress choke point)
//
// One entry point: publish(post:to:account:). It resolves the identity each API needs, runs the
// real call(s), and returns the provider's id or a real error. `transport` is injectable so a
// test can drive it with a stub; production leaves it nil and the choke point uses its own. This
// file names no URLSession — the socket lives in Sources/ConsentedEgress.swift.
struct SocialPublishService {
    var transport: OutboundTransport? = nil
    /// How long to poll async media processing (IG container / TikTok) before returning
    /// .processingTimeout (accepted-but-not-confirmed, which is honest, not a failure claim).
    var pollAttempts = 12
    var pollDelayNanos: UInt64 = 3_000_000_000   // 3s

    func publish(_ post: SocialPost, to platform: SocialPlatform, account: SocialAccount) async -> Result<SocialPostResult, SocialPostError> {
        // Transmission consent first: the caption, any attached image/video, and the access token
        // are all about to leave this Mac for a third-party API. No recorded, current grant for
        // THIS platform → the request is never built. (Sources/ProviderConsent.swift.)
        if let refusal = TransmissionConsentStore.refusal(for: platform.transmissionProvider) {
            return .failure(.consentRequired(platform, refusal))
        }
        let token = account.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            ConnectorVerificationStore.clear(ConnectorVerificationStore.social(platform.rawValue))
            return .failure(.notConnected(platform))
        }
        let result: Result<SocialPostResult, SocialPostError>
        switch platform {
        case .x:         result = await publishX(post, token: token)
        case .linkedin:  result = await publishLinkedIn(post, token: token)
        case .facebook:  result = await publishFacebook(post, account: account)
        case .threads:   result = await publishThreads(post, account: account)
        case .instagram: result = await publishInstagram(post, account: account)
        case .youtube:   result = await publishYouTube(post, token: token)
        case .tiktok:    result = await publishTikTok(post, token: token)
        case .pinterest: result = await publishPinterest(post, account: account)
        }
        switch result {
        case .success:
            ConnectorVerificationStore.record(ConnectorVerificationStore.social(platform.rawValue), ok: true, detail: "Provider accepted the publish")
        case .failure(let error):
            // Local composition requirements do not invalidate a credential. Persist a negative
            // connector receipt only when a provider/network round-trip actually failed.
            switch error {
            case .http, .network, .badResponse, .needsAccountID, .appReviewRequired:
                ConnectorVerificationStore.record(ConnectorVerificationStore.social(platform.rawValue), ok: false, detail: error.localizedDescription)
            case .processingTimeout:
                ConnectorVerificationStore.record(ConnectorVerificationStore.social(platform.rawValue), ok: true, detail: "Provider accepted the media and is processing it")
            case .notConnected:
                ConnectorVerificationStore.clear(ConnectorVerificationStore.social(platform.rawValue))
            case .needsMedia, .needsPublicURL, .relayOnly, .consentRequired:
                // Local/consent refusals never happened on the wire, so they must not stain (or
                // clear) the connector's verification receipt.
                break
            }
        }
        return result
    }

    // MARK: X
    private func publishX(_ post: SocialPost, token: String) async -> Result<SocialPostResult, SocialPostError> {
        var mediaIDs: [String] = []
        if let file = post.mediaFileURL, let data = try? Data(contentsOf: file) {
            switch await uploadXMedia(data: data, isVideo: post.mediaIsVideo, token: token) {
            case .success(let id): mediaIDs = [id]
            case .failure(let e): return .failure(e)
            }
        }
        guard let req = SocialPublishAPI.xTweet(text: post.text, token: token, mediaIDs: mediaIDs) else {
            return .failure(.needsMedia(.x, "text or media"))
        }
        return await run(req, platform: .x) { json in
            guard let data = json["data"] as? [String: Any], let id = data["id"] as? String else { return nil }
            return SocialPostResult(platform: .x, id: id, permalink: "https://x.com/i/web/status/\(id)")
        }
    }

    private func uploadXMedia(data: Data, isVideo: Bool, token: String) async -> Result<String, SocialPostError> {
        let mime = isVideo ? "video/mp4" : "image/jpeg"
        let category = isVideo ? "tweet_video" : "tweet_image"
        guard let initReq = SocialPublishAPI.xMediaInit(totalBytes: data.count, mimeType: mime, category: category, token: token) else {
            return .failure(.badResponse(.x))
        }
        var mediaID = ""
        switch await run(initReq, platform: .x, decode: { ($0["media_id_string"] as? String).map { SocialPostResult(platform: .x, id: $0) } }) {
        case .success(let r): mediaID = r.id
        case .failure(let e): return .failure(e)
        }
        // APPEND in 4MB segments.
        let chunkSize = 4 * 1024 * 1024
        var index = 0, offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data.subdata(in: offset..<end)
            guard let appendReq = SocialPublishAPI.xMediaAppend(mediaID: mediaID, segmentIndex: index, chunk: chunk, token: token) else {
                return .failure(.badResponse(.x))
            }
            if case .failure(let e) = await runRaw(appendReq, platform: .x) { return .failure(e) }
            offset = end; index += 1
        }
        guard let finalizeReq = SocialPublishAPI.xMediaFinalize(mediaID: mediaID, token: token) else {
            return .failure(.badResponse(.x))
        }
        if case .failure(let e) = await runRaw(finalizeReq, platform: .x) { return .failure(e) }
        return .success(mediaID)
    }

    // MARK: LinkedIn
    private func publishLinkedIn(_ post: SocialPost, token: String) async -> Result<SocialPostResult, SocialPostError> {
        guard SocialPublishAPI.linkedinUserinfo(token: token) != nil else { return .failure(.notConnected(.linkedin)) }
        // Resolve the member id (OIDC sub).
        guard let meReq = SocialPublishAPI.linkedinUserinfo(token: token) else { return .failure(.notConnected(.linkedin)) }
        let sub: String
        switch await run(meReq, platform: .linkedin, decode: { ($0["sub"] as? String).map { SocialPostResult(platform: .linkedin, id: $0) } }) {
        case .success(let r): sub = r.id
        case .failure: return .failure(.needsAccountID(.linkedin, "member id"))
        }
        let urn = SocialPublishAPI.linkedinPersonURN(sub: sub)
        guard post.text.trimmingCharacters(in: .whitespaces).isEmpty == false else {
            return .failure(.needsMedia(.linkedin, "post text"))
        }
        guard let req = SocialPublishAPI.linkedinTextPost(authorURN: urn, text: post.text, token: token) else {
            return .failure(.badResponse(.linkedin))
        }
        return await run(req, platform: .linkedin) { json in
            guard let id = json["id"] as? String else { return nil }
            return SocialPostResult(platform: .linkedin, id: id)
        }
    }

    // MARK: Facebook
    private func publishFacebook(_ post: SocialPost, account: SocialAccount) async -> Result<SocialPostResult, SocialPostError> {
        let token = account.accessToken
        // Resolve a managed Page (id + page token) unless already provided.
        var pageID = account.accountID ?? ""
        var pageToken = account.pageAccessToken ?? ""
        if pageID.isEmpty || pageToken.isEmpty {
            guard let acctReq = SocialPublishAPI.facebookAccounts(token: token) else { return .failure(.notConnected(.facebook)) }
            switch await runRaw(acctReq, platform: .facebook) {
            case .success(let json):
                guard let list = json["data"] as? [[String: Any]], let first = list.first,
                      let id = first["id"] as? String, let pt = first["access_token"] as? String else {
                    return .failure(.needsAccountID(.facebook, "Page"))
                }
                pageID = id; pageToken = pt
            case .failure(let e): return .failure(e)
            }
        }
        let req: URLRequest?
        if post.mediaIsVideo, let file = post.mediaFileURL, let data = try? Data(contentsOf: file), !data.isEmpty {
            req = SocialPublishAPI.facebookPageVideo(pageID: pageID, description: post.text, pageToken: pageToken, data: data)
        } else {
            req = SocialPublishAPI.facebookPageFeed(pageID: pageID, message: post.text, pageToken: pageToken,
                                                    linkURL: post.mediaPublicURL)
        }
        guard let req else {
            return .failure(.needsMedia(.facebook, "post text"))
        }
        return await run(req, platform: .facebook) { json in
            guard let id = json["id"] as? String else { return nil }
            return SocialPostResult(platform: .facebook, id: id,
                                    permalink: "https://facebook.com/\(id)")
        }
    }

    // MARK: Threads
    private func publishThreads(_ post: SocialPost, account: SocialAccount) async -> Result<SocialPostResult, SocialPostError> {
        let token = account.accessToken
        var userID = account.accountID ?? ""
        if userID.isEmpty {
            guard let meReq = SocialPublishAPI.threadsMe(token: token) else { return .failure(.notConnected(.threads)) }
            switch await runRaw(meReq, platform: .threads) {
            case .success(let json):
                guard let id = json["id"] as? String else { return .failure(.needsAccountID(.threads, "user id")) }
                userID = id
            case .failure(let e): return .failure(e)
            }
        }
        // Text vs media container.
        let mediaType: String
        var mediaURL: String? = nil
        if post.hasPublicMedia {
            mediaType = post.mediaIsVideo ? "VIDEO" : "IMAGE"; mediaURL = post.mediaPublicURL
        } else if post.hasLocalMedia {
            return .failure(.needsPublicURL(.threads, "media URL"))
        } else if post.text.trimmingCharacters(in: .whitespaces).isEmpty {
            return .failure(.needsMedia(.threads, "post text or media"))
        } else {
            mediaType = "TEXT"
        }
        guard let createReq = SocialPublishAPI.threadsCreate(userID: userID, text: post.text, token: token,
                                                             mediaType: mediaType, mediaURL: mediaURL) else {
            return .failure(.badResponse(.threads))
        }
        let creationID: String
        switch await runRaw(createReq, platform: .threads) {
        case .success(let json):
            guard let id = json["id"] as? String else { return .failure(.badResponse(.threads)) }
            creationID = id
        case .failure(let e): return .failure(e)
        }
        guard let pubReq = SocialPublishAPI.threadsPublish(userID: userID, creationID: creationID, token: token) else {
            return .failure(.badResponse(.threads))
        }
        return await run(pubReq, platform: .threads) { json in
            guard let id = json["id"] as? String else { return nil }
            return SocialPostResult(platform: .threads, id: id)
        }
    }

    // MARK: Instagram (image or public reel URL → container → poll → publish)
    private func publishInstagram(_ post: SocialPost, account: SocialAccount) async -> Result<SocialPostResult, SocialPostError> {
        let token = account.accessToken
        var igUserID = account.accountID ?? ""
        if igUserID.isEmpty {
            guard let meReq = SocialPublishAPI.instagramMe(token: token) else { return .failure(.notConnected(.instagram)) }
            switch await runRaw(meReq, platform: .instagram) {
            case .success(let json):
                igUserID = (json["user_id"] as? String) ?? (json["id"] as? String) ?? ""
                if igUserID.isEmpty { return .failure(.needsAccountID(.instagram, "Instagram Business account id")) }
            case .failure(let error): return .failure(error)
            }
        }
        guard post.hasPublicMedia else {
            if post.hasLocalMedia { return .failure(.needsPublicURL(.instagram, "reel/image URL")) }
            return .failure(.needsMedia(.instagram, "an image or a public reel URL"))
        }
        let mediaURL = post.mediaPublicURL!
        // Build the right container (REELS reuses the verified SocialOAuth builder).
        let containerReq: URLRequest?
        if post.mediaIsVideo {
            containerReq = SocialOAuth.instagramCreateReelRequest(igUserID: igUserID, videoURL: mediaURL,
                                                                  caption: post.text, accessToken: token)
        } else {
            containerReq = SocialPublishAPI.instagramCreateImage(igUserID: igUserID, imageURL: mediaURL,
                                                                 caption: post.text, token: token)
        }
        guard let createReq = containerReq else { return .failure(.needsPublicURL(.instagram, "HTTPS media URL")) }
        let creationID: String
        switch await runRaw(createReq, platform: .instagram) {
        case .success(let json):
            guard let id = json["id"] as? String else { return .failure(.badResponse(.instagram)) }
            creationID = id
        case .failure(let e): return .failure(e)
        }
        // Poll the container until FINISHED (video processing is async).
        if post.mediaIsVideo {
            var done = false
            for _ in 0..<pollAttempts {
                guard let statusReq = SocialPublishAPI.instagramContainerStatus(creationID: creationID, token: token) else { break }
                if case .success(let json) = await runRaw(statusReq, platform: .instagram),
                   let code = json["status_code"] as? String {
                    if code == "FINISHED" { done = true; break }
                    if code == "ERROR" || code == "EXPIRED" { return .failure(.http(.instagram, 0, "media processing \(code.lowercased())")) }
                }
                try? await Task.sleep(nanoseconds: pollDelayNanos)
            }
            if !done { return .failure(.processingTimeout(.instagram)) }
        }
        guard let pubReq = SocialOAuth.instagramPublishRequest(igUserID: igUserID, creationID: creationID, accessToken: token) else {
            return .failure(.badResponse(.instagram))
        }
        return await run(pubReq, platform: .instagram) { json in
            guard let id = json["id"] as? String else { return nil }
            return SocialPostResult(platform: .instagram, id: id)
        }
    }

    // MARK: YouTube (resumable upload)
    private func publishYouTube(_ post: SocialPost, token: String) async -> Result<SocialPostResult, SocialPostError> {
        guard let file = post.mediaFileURL, let data = try? Data(contentsOf: file), !data.isEmpty else {
            return .failure(.needsMedia(.youtube, "a video file"))
        }
        guard var initReq = SocialPublishAPI.youtubeResumableInit(title: post.title.isEmpty ? post.text : post.title,
                                                                  description: post.text, token: token,
                                                                  contentLength: data.count) else {
            return .failure(.notConnected(.youtube))
        }
        initReq.timeoutInterval = 30
        // The session URL comes back in the Location header (not the body).
        let sessionURL: String
        do {
            let (_, resp) = try await ConsentedEgress.send(initReq, to: SocialPlatform.youtube.transmissionProvider,
                                                           via: transport)
            guard let http = resp as? HTTPURLResponse else { return .failure(.badResponse(.youtube)) }
            guard (200...299).contains(http.statusCode), let loc = http.value(forHTTPHeaderField: "Location") else {
                return .failure(.http(.youtube, http.statusCode, "couldn't open an upload session"))
            }
            sessionURL = loc
        } catch let refusal as ConsentedEgressError {
            return .failure(.consentRequired(.youtube, refusal.errorDescription ?? "Nothing was sent."))
        } catch { return .failure(.network(.youtube, error.localizedDescription)) }
        guard let upReq = SocialPublishAPI.youtubeUpload(sessionURL: sessionURL, data: data) else {
            return .failure(.badResponse(.youtube))
        }
        // The upload target is the per-upload URL YouTube just issued in the Location header, not a
        // host this app chose — so the registry check does not apply to it. Consent for .youtube is
        // still required and is still checked inside the choke point.
        return await run(upReq, platform: .youtube, destination: .providerIssuedUploadURL) { json in
            guard let id = json["id"] as? String else { return nil }
            return SocialPostResult(platform: .youtube, id: id, permalink: "https://youtu.be/\(id)")
        }
    }

    // MARK: TikTok (init → upload → status)
    private func publishTikTok(_ post: SocialPost, token: String) async -> Result<SocialPostResult, SocialPostError> {
        guard let file = post.mediaFileURL, let data = try? Data(contentsOf: file), !data.isEmpty else {
            return .failure(.needsMedia(.tiktok, "a video file"))
        }
        guard let initReq = SocialPublishAPI.tiktokInit(title: post.text, videoSize: data.count, token: token) else {
            return .failure(.notConnected(.tiktok))
        }
        var uploadURL = "", publishID = ""
        switch await runRaw(initReq, platform: .tiktok) {
        case .success(let json):
            let d = json["data"] as? [String: Any]
            uploadURL = (d?["upload_url"] as? String) ?? ""
            publishID = (d?["publish_id"] as? String) ?? ""
            if uploadURL.isEmpty || publishID.isEmpty {
                let err = (json["error"] as? [String: Any])?["message"] as? String
                return .failure(.appReviewRequired(.tiktok, err ?? "your TikTok app must be approved for the Content Posting API before it can publish."))
            }
        case .failure(let e): return .failure(e)
        }
        guard let upReq = SocialPublishAPI.tiktokUpload(uploadURL: uploadURL, data: data) else { return .failure(.badResponse(.tiktok)) }
        // Same shape as the YouTube resumable upload: TikTok hands back a per-upload URL, so the
        // host cannot be in the registry. Consent for .tiktok is still enforced inside the choke point.
        if case .failure(let e) = await runRaw(upReq, platform: .tiktok, destination: .providerIssuedUploadURL) { return .failure(e) }
        // Poll publish status.
        for _ in 0..<pollAttempts {
            guard let stReq = SocialPublishAPI.tiktokStatus(publishID: publishID, token: token) else { break }
            if case .success(let json) = await runRaw(stReq, platform: .tiktok),
               let d = json["data"] as? [String: Any], let status = d["status"] as? String {
                if status == "PUBLISH_COMPLETE" { return .success(SocialPostResult(platform: .tiktok, id: publishID)) }
                if status.contains("FAIL") { return .failure(.http(.tiktok, 0, "publish failed: \(status)")) }
            }
            try? await Task.sleep(nanoseconds: pollDelayNanos)
        }
        return .failure(.processingTimeout(.tiktok))
    }

    // MARK: Pinterest (resolve board → create pin; pins REQUIRE an image)
    private func publishPinterest(_ post: SocialPost, account: SocialAccount) async -> Result<SocialPostResult, SocialPostError> {
        let token = account.accessToken
        // Pins are image posts. A local video (rendered reel) is honestly rejected up front —
        // this path publishes image pins only. A PUBLIC URL is passed through as image_url and
        // Pinterest itself validates the content (its error surfaces unchanged if it isn't an image).
        var imageURL: String? = nil
        var imageData: Data? = nil
        var contentType = "image/jpeg"
        if post.hasPublicMedia {
            imageURL = post.mediaPublicURL
        } else if let file = post.mediaFileURL {
            if post.mediaIsVideo {
                return .failure(.needsMedia(.pinterest, "a still image — this path publishes image pins, not video"))
            }
            guard let data = try? Data(contentsOf: file), !data.isEmpty else {
                return .failure(.needsMedia(.pinterest, "a readable image file"))
            }
            imageData = data
            contentType = Self.pinterestImageContentType(for: file)
        } else {
            return .failure(.needsMedia(.pinterest, "an image"))
        }
        // Destination board: previously chosen > first of the buyer's own boards (then persisted).
        var boardID = account.accountID ?? PinterestBoardStore.boardID ?? ""
        if boardID.isEmpty {
            guard let boardsReq = SocialPublishAPI.pinterestBoards(token: token) else {
                return .failure(.notConnected(.pinterest))
            }
            switch await runRaw(boardsReq, platform: .pinterest) {
            case .success(let json):
                let items = json["items"] as? [[String: Any]] ?? []
                guard let first = items.first, let id = first["id"] as? String, !id.isEmpty else {
                    // Honest: the account has no boards; a pin has nowhere to go.
                    return .failure(.needsAccountID(.pinterest, "board"))
                }
                boardID = id
                PinterestBoardStore.save(id: id, name: first["name"] as? String)
            case .failure(let e): return .failure(e)
            }
        }
        let title = post.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(post.text.split(separator: "\n").first ?? "")
            : post.title
        guard let req = SocialPublishAPI.pinterestCreatePin(boardID: boardID, title: title,
                                                            description: post.text, token: token,
                                                            imageURL: imageURL, imageData: imageData,
                                                            imageContentType: contentType) else {
            return .failure(.needsMedia(.pinterest, "an HTTPS image URL or an image file"))
        }
        return await run(req, platform: .pinterest) { json in
            guard let id = json["id"] as? String, !id.isEmpty else { return nil }
            return SocialPostResult(platform: .pinterest, id: id,
                                    permalink: "https://www.pinterest.com/pin/\(id)/")
        }
    }

    /// Content type for a local image handed to Pinterest's image_base64 source.
    private static func pinterestImageContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png":  return "image/png"
        default:     return "image/jpeg"
        }
    }

    // MARK: - Transport helpers

    /// Run a request, decode the JSON body, and map it to a result via `decode` (nil → badResponse).
    private func run(_ req: URLRequest, platform: SocialPlatform,
                     destination: EgressDestination = .registeredHost,
                     decode: @escaping ([String: Any]) -> SocialPostResult?) async -> Result<SocialPostResult, SocialPostError> {
        switch await runRaw(req, platform: platform, destination: destination) {
        case .success(let json):
            if let r = decode(json) { return .success(r) }
            return .failure(.badResponse(platform))
        case .failure(let e): return .failure(e)
        }
    }

    /// Run a request and return the parsed JSON dict, or a real error (network / non-2xx / API error).
    private func runRaw(_ req: URLRequest, platform: SocialPlatform,
                        destination: EgressDestination = .registeredHost) async -> Result<[String: Any], SocialPostError> {
        do {
            var bounded = req
            // API calls return quickly; media upload builders opt into a larger timeout explicitly.
            if bounded.timeoutInterval >= 60 { bounded.timeoutInterval = bounded.httpBody?.count ?? 0 > 1_000_000 ? 180 : 30 }
            // Every social request leaves through the choke point, which makes the consent decision
            // itself. `transport` stays injectable so the stub-transport suites are unaffected.
            let (data, resp) = try await ConsentedEgress.send(bounded, to: platform.transmissionProvider,
                                                              destination: destination,
                                                              via: transport)
            let http = resp as? HTTPURLResponse
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let http = http, !(200...299).contains(http.statusCode) {
                return .failure(.http(platform, http.statusCode, Self.apiMessage(json, fallback: String(data: data, encoding: .utf8) ?? "")))
            }
            // Meta/Graph can return 200 with an "error" object.
            if let errObj = json["error"] as? [String: Any], let msg = errObj["message"] as? String {
                return .failure(.http(platform, (errObj["code"] as? Int) ?? 0, msg))
            }
            return .success(json)
        } catch let refusal as ConsentedEgressError {
            // A refusal is never an outage. Its own case, so the surface cannot retry into a send.
            return .failure(.consentRequired(platform, refusal.errorDescription ?? "Nothing was sent."))
        } catch {
            return .failure(.network(platform, error.localizedDescription))
        }
    }

    /// Pull the most specific human message out of a provider error body.
    static func apiMessage(_ json: [String: Any], fallback: String) -> String {
        if let e = json["error"] as? [String: Any] {
            if let m = e["message"] as? String { return m }
            if let m = e["error_user_msg"] as? String { return m }
        }
        if let m = json["message"] as? String { return m }
        if let m = json["error_description"] as? String { return m }
        if let e = json["error"] as? String { return e }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "request failed" : String(trimmed.prefix(300))
    }
}
#endif // circuit-convert

// MARK: - Rendered reel → publish payload (media-populated, not text-only)
//
// The Reel Studio renders an .mp4 to a temp file; before we hand it to a network's video path we
// (a) copy it into a stable RenderedReels/ dir under Application Support so the upload (and any
// retry) always has a readable path, and (b) wrap it in a media-populated SocialPost so the
// per-network video publish (X v1.1 upload / YouTube resumable) actually uploads the bytes.

extension SocialPost {
    /// Build a publish payload for a rendered reel: the local .mp4 the buyer just rendered, carried
    /// as VIDEO media (mediaFileURL + mediaIsVideo) so the video path uploads real bytes rather than
    /// a text-only post. `caption` becomes the post text; `title` seeds YouTube's video title.
    static func reel(fileURL: URL, caption: String, title: String = "") -> SocialPost {
        SocialPost(text: caption, mediaFileURL: fileURL, mediaIsVideo: true, title: title)
    }
}

/// Durable store for reels the buyer publishes. Foundation-only (unit-tested) so the RenderedReels/
/// path and the temp→durable copy are proven, not asserted. Same RenderedReels/ dir the website-sync
/// proof reel uses (~/Library/Application Support/BlackLabelMarketing/RenderedReels).
enum RenderedReelStore {
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true)
            .appendingPathComponent("RenderedReels", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Copy a freshly rendered temp .mp4 into RenderedReels/ under a stable, filesystem-safe name and
    /// return the durable URL. Overwrites a same-named prior copy (idempotent re-publish of one reel).
    static func persist(_ tempURL: URL, name: String) throws -> URL {
        let dir = directory()
        let slug = safeComponent(name)
        let stamp = tempURL.deletingPathExtension().lastPathComponent
        let dst = dir.appendingPathComponent("publish-\(slug)-\(stamp).mp4")
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: tempURL, to: dst)
        return dst
    }

    static func safeComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let value = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: ".-_ "))
        return value.isEmpty ? "reel" : String(value.prefix(60))
    }
}

// MARK: - Bluesky (AT Protocol), Mastodon, Discord webhook
//
// These three earn a place the other missing platforms cannot: each is BYO-credential with NO
// gatekeeper — no app registration, no review queue, no paid tier. The buyer issues the credential
// themselves and can revoke it themselves, which is the same posture every connector here already
// has. Reddit and Snapchat need app registration + review (a founder gate), and Quora, Hacker News,
// Alignable, BiggerPockets, Houzz and Substack publish no write API at all, so none of them are
// listed as connectors — an integration that cannot exist is not shown as "coming soon".

extension SocialPublishAPI {

    // MARK: Bluesky — AT Protocol XRPC
    //
    // Auth is a session created from the buyer's handle + an APP PASSWORD they generate in Bluesky's
    // own settings (never their account password). The session JWT is short-lived, so the caller
    // creates one per publish rather than storing it.

    /// POST /xrpc/com.atproto.server.createSession  { identifier, password } -> { accessJwt, did }
    static func blueskyCreateSession(handle: String, appPassword: String,
                                     host: String = "https://bsky.social") -> URLRequest? {
        let id = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let pw = appPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !pw.isEmpty, let url = URL(string: host + "/xrpc/com.atproto.server.createSession") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["identifier": id, "password": pw])
        return req
    }

    /// POST /xrpc/com.atproto.repo.createRecord — an app.bsky.feed.post record in the buyer's repo.
    /// `createdAt` is ISO-8601 with fractional seconds, which the lexicon requires.
    static func blueskyPost(text: String, accessJwt: String, did: String,
                            host: String = "https://bsky.social") -> URLRequest? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !accessJwt.isEmpty, !did.isEmpty,
              let url = URL(string: host + "/xrpc/com.atproto.repo.createRecord") else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessJwt)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let record: [String: Any] = ["$type": "app.bsky.feed.post",
                                     "text": String(body.prefix(300)),   // lexicon max is 300 graphemes
                                     "createdAt": fmt.string(from: Date())]
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "repo": did, "collection": "app.bsky.feed.post", "record": record])
        return req
    }

    // MARK: Mastodon
    //
    // The buyer's own instance host plus a token they issue in Preferences -> Development. There is
    // no central Mastodon host, so the instance is ALWAYS supplied by the buyer and never defaulted.

    /// POST https://<instance>/api/v1/statuses  { status, visibility }
    static func mastodonPost(text: String, token: String, instanceHost: String,
                             visibility: String = "public") -> URLRequest? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = instanceHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix("/") { host.removeLast() }
        if !host.hasPrefix("http") { host = "https://" + host }
        guard !body.isEmpty, !token.isEmpty, !host.isEmpty,
              let url = URL(string: host + "/api/v1/statuses") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        bearerToken(&req, token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["status": body, "visibility": visibility])
        return req
    }

    // MARK: Discord — incoming webhook
    //
    // No OAuth at all: the buyer creates a webhook in their own server's channel settings and pastes
    // the URL. The URL IS the credential, so it is stored like one and never logged.

    /// POST <webhookURL>  { content }
    static func discordWebhookPost(text: String, webhookURL: String) -> URLRequest? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = webhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, let url = URL(string: raw),
              let host = url.host, host.hasSuffix("discord.com") || host.hasSuffix("discordapp.com")
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["content": String(body.prefix(2000))])
        return req
    }

    /// Local mirror of the private `bearer` helper so this extension stays self-contained.
    private static func bearerToken(_ req: inout URLRequest, _ token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}
