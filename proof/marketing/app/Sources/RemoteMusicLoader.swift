// Black Label Marketing — download a buyer-supplied audio file into a local render-safe cache.
// The original URL is never sent anywhere except the host the buyer pasted.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RemoteMusicError: LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case badStatus(Int)
    case notAudio
    case tooLarge
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Paste a direct link to an audio file."
        case .insecureURL: return "Use an HTTPS music link."
        case .badStatus(let code): return "The music link returned HTTP \(code)."
        case .notAudio: return "That link did not return an audio file. Use a direct MP3, WAV, M4A, AAC, or FLAC link."
        case .tooLarge: return "That audio file is over the 100 MB limit."
        case .emptyFile: return "The music link returned an empty file."
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum RemoteMusicLoader {
    static let maximumBytes: Int64 = 100 * 1024 * 1024
    private static let audioExtensions = Set(["mp3", "wav", "m4a", "aac", "flac", "aiff", "aif", "caf", "mp4"])

    static func validatedURL(_ raw: String) throws -> URL {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), url.host != nil else { throw RemoteMusicError.invalidURL }
        guard url.scheme?.lowercased() == "https" else { throw RemoteMusicError.insecureURL }
        return url
    }

    /// Downloads a URL the buyer pasted, through the egress choke point's declared
    /// `userDirectedFetch` lane.
    static func load(_ raw: String) async throws -> URL {
        let source = try validatedURL(raw)
        var request = URLRequest(url: source)
        request.timeoutInterval = 60
        request.setValue("audio/*,application/octet-stream;q=0.8", forHTTPHeaderField: "Accept")
        let (temporary, response) = try await ConsentedEgress.downloadUngated(request, lane: .userDirectedFetch)
        guard let http = response as? HTTPURLResponse else { throw RemoteMusicError.invalidURL }
        guard (200...299).contains(http.statusCode) else { throw RemoteMusicError.badStatus(http.statusCode) }

        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int64.init), length > maximumBytes {
            throw RemoteMusicError.tooLarge
        }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0 else { throw RemoteMusicError.emptyFile }
        guard size <= maximumBytes else { throw RemoteMusicError.tooLarge }

        let mime = (http.mimeType ?? "").lowercased()
        let responseExtension = response.suggestedFilename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() } ?? ""
        let sourceExtension = source.pathExtension.lowercased()
        let fileExtension = audioExtensions.contains(responseExtension) ? responseExtension : sourceExtension
        guard mime.hasPrefix("audio/") || audioExtensions.contains(fileExtension) else { throw RemoteMusicError.notAudio }

        let ext = audioExtensions.contains(fileExtension) ? fileExtension : "m4a"
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("blm-music-link-\(UUID().uuidString)")
            .appendingPathExtension(ext)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }
}
#endif // circuit-convert
