// LinkReference: understand a streaming link WITHOUT ripping its audio.
//
// SoundCloud / YouTube / Spotify all expose a public, no-auth oEmbed endpoint that returns
// a track's title, artist and description. We resolve that metadata and SYNTHESIZE a matching
// mix/master target from it (genre + style inference). This is the honest, legal way to
// "match a reference by link": it understands what the track IS and targets that style.
// (An exact spectral fingerprint still needs the actual audio file — that path stays available.)

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct LinkReference: Equatable {
    var title: String
    var artist: String
    var source: String          // "SoundCloud" | "YouTube" | "Spotify"
    var inferredStyle: MixStyle  // the synthesized target
    var summary: String          // "Title — Artist"
}

enum LinkResolver {
    enum LinkError: LocalizedError {
        case unsupported, network, noData
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Unsupported link — paste a SoundCloud, YouTube or Spotify track URL."
            case .network:     return "Couldn't reach the link. Check the URL and your connection."
            case .noData:      return "The link didn't return readable track info."
            }
        }
    }

    /// Build the platform's public oEmbed URL for a given track link.
    static func oEmbed(for link: String) -> (url: URL, source: String)? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), let host = u.host?.lowercased() else { return nil }
        let base: String, source: String
        if host.contains("soundcloud") { base = "https://soundcloud.com/oembed"; source = "SoundCloud" }
        else if host.contains("youtu")  { base = "https://www.youtube.com/oembed"; source = "YouTube" }
        else if host.contains("spotify"){ base = "https://open.spotify.com/oembed"; source = "Spotify" }
        else { return nil }
        var comps = URLComponents(string: base)!
        comps.queryItems = [URLQueryItem(name: "format", value: "json"),
                            URLQueryItem(name: "url", value: trimmed)]
        guard let url = comps.url else { return nil }
        return (url, source)
    }

    /// Resolve a link into a synthesized reference target. Network + JSON, no auth.
    static func resolve(_ link: String) async throws -> LinkReference {
        guard let (url, source) = oEmbed(for: link) else { throw LinkError.unsupported }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(from: url) }
        catch { throw LinkError.network }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw LinkError.network }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LinkError.noData }

        let title = (json["title"] as? String) ?? "Unknown track"
        let author = (json["author_name"] as? String) ?? ""
        let desc = (json["description"] as? String) ?? ""
        let style = classify(text: [title, author, desc].joined(separator: " "))
        let summary = author.isEmpty ? title : "\(title) — \(author)"
        return LinkReference(title: title, artist: author, source: source, inferredStyle: style, summary: summary)
    }

    /// Manual text reference: artist, song, label, genre, or target description typed by the user.
    static func manual(_ text: String) -> LinkReference {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let style = classify(text: trimmed)
        return LinkReference(title: trimmed, artist: "", source: "Manual", inferredStyle: style, summary: trimmed)
    }

    /// Infer a mix style from the track's text metadata (artist/label/genre keywords).
    static func classify(text: String) -> MixStyle {
        let s = text.lowercased()
        func any(_ ks: [String]) -> Bool { ks.contains { s.contains($0) } }
        if any(["westend", "tech house", "jumpin", "get this party started", "detonate"]) {
            return MixStyles.westendTechHouse
        }
        // Melodic techno / Afterlife world (the HNTR / Anyma reference the user gave).
        if any(["anyma", "hntr", "afterlife", "melodic techno", "tale of us", "massano", "argy", "colyn", "cassian", "mathame"]) {
            return MixStyles.melodicTechno
        }
        if any(["big room", "festival", "mainstage", "martin garrix", "tomorrowland", "hardwell", "edm"]) {
            return MixStyles.festival
        }
        if any(["future bass", "flume", "illenium", "odesza", "san holo", "chillstep"]) {
            return MixStyles.futureBass
        }
        if any(["deep house", "organic house", "afro house", "melodic house", "lane 8", "yotto"]) {
            return MixStyles.deep
        }
        if any(["peak time", "drumcode", "charlotte de witte", "amelie lens", "hard techno", "industrial techno"]) {
            return MixStyles.peakTime
        }
        if any(["techno"]) { return MixStyles.peakTime }
        // Generic "house"/trance/progressive and the unmatched fallback stay on melodicTechno —
        // identical to build 2 (782efdf). Westend Tech House is only reached by an EXPLICIT
        // westend/tech-house reference (branch above) or by selecting it in the style picker.
        if any(["house", "trance", "progressive"]) { return MixStyles.melodicTechno }
        return MixStyles.melodicTechno   // sensible default for the app's core audience
    }
}
