//
//  PublicWebsiteSearchResolver.swift
//  Ace
//
//  Extracts one direct public destination from the first ordinary web result.
//  Network transport stays outside this pure boundary so malformed search
//  markup cannot become an app-launch URL without explicit validation.
//

import Foundation

enum PublicWebsiteSearchResolver {
    private static let maximumPageBytes = 4_194_304

    static func firstPublicResultURL(in html: String) -> URL? {
        guard !html.isEmpty,
              html.utf8.count <= maximumPageBytes,
              let expression = try? NSRegularExpression(
                pattern:
                    #"data-type\s*=\s*[\"']web[\"'][\s\S]*?<a\b[^>]*\bhref\s*=\s*[\"']([^\"']+)[\"']"#,
                options: [.caseInsensitive]
              ),
              let match = expression.firstMatch(
                in: html,
                range: NSRange(html.startIndex..., in: html)
              ),
              let range = Range(match.range(at: 1), in: html) else {
            return nil
        }

        let rawURL = String(html[range])
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty,
              host.contains(".") || host.contains(":"),
              components.user == nil,
              components.password == nil,
              let result = components.url else {
            return nil
        }
        return result
    }
}
