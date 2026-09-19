import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

nonisolated final class AcademicSourceFetcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // A source fetch never attaches browser cookies or sends credentials on redirects.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { AcademicDocument.sourceURL($0.absoluteString) } == nil ? nil : request)
    }

    func fetch(_ source: AcademicDocumentSource) async throws -> AcademicSourceEvidence {
        guard let url = AcademicDocument.sourceURL(source.url) else {
            throw AcademicDocumentError.invalid("The source URL is invalid.")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let finalURL = http.url, AcademicDocument.sourceURL(finalURL.absoluteString) != nil,
              ["text/html", "text/plain", "application/xhtml+xml"].contains(http.mimeType?.lowercased() ?? ""),
              http.expectedContentLength <= 2_000_000 else {
            throw AcademicDocumentError.invalid("Source \(source.id) did not return a bounded HTML or text page. PDF and login-only sources need a supported text source.")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_000_000 else { throw AcademicDocumentError.invalid("The source exceeds the retrieval limit.") }
            data.append(byte)
        }
        guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else {
            throw AcademicDocumentError.invalid("The source needs readable UTF-8 text.")
        }
        return AcademicSourceEvidence(sourceID: source.id, requestedURL: source.url,
            retrievedURL: finalURL.absoluteString, retrievedAt: ISO8601DateFormatter().string(from: Date()),
            sha256: AcademicDocument.sha256(data), byteCount: data.count,
            text: http.mimeType == "text/plain" ? raw : Self.visibleText(raw))
    }

    static func visibleText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style|noscript)\\b[^>]*>.*?</\\1\\s*>",
                                             with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?s)<!--.*?-->|<[^>]*>", with: " ", options: .regularExpression)
        // Decode entities after stripping tags so quoted markup stays source text.
        let pattern = try! NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let digitsRange = Range(match.range(at: 1), in: text), let range = Range(match.range, in: text) else { continue }
            let digits = String(text[digitsRange])
            let value = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            if let value, let scalar = UnicodeScalar(value) { text.replaceSubrange(range, with: String(scalar)) }
        }
        for (entity, value) in [("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"),
                                 ("&lsquo;", "‘"), ("&rsquo;", "’"), ("&ldquo;", "“"),
                                 ("&rdquo;", "”"), ("&ndash;", "–"), ("&mdash;", "—"),
                                 ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return AcademicDocument.normalize(text)
    }
}
