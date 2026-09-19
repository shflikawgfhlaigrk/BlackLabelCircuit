//
//  NativeWebNavigationIntentPolicy.swift
//  Ace
//
//  Pure one-turn website admission. It binds literal public URLs/domains and a
//  small reviewed canonical website map, while app names and unknown prose
//  remain model-owned.
//

import Foundation

nonisolated struct NativeWebNavigation: Equatable, Sendable {
    let url: String
    let browserBundleIdentifier: String?
}

nonisolated enum NativeWebNavigationIntentPolicy {
    private static let browserNames: [String: String] = [
        "safari": "com.apple.Safari", "chrome": "com.google.Chrome",
        "google chrome": "com.google.Chrome", "firefox": "org.mozilla.firefox",
        "brave": "com.brave.Browser", "edge": "com.microsoft.edgemac",
        "microsoft edge": "com.microsoft.edgemac", "arc": "company.thebrowser.Browser",
    ]
    private static let hailExpression = try! NSRegularExpression(
        pattern: #"(?i)^\s*(?:(?:hey|hi|okay|ok)[\s,]+)?(?:ace[\s,]+|is\s+(?=(?:go\s+to|open|visit)\b))?"#
    )
    private static let browserSuffixExpression = try! NSRegularExpression(
        pattern: #"(?i)\s+(?:(?:in|on|using|with)\s+)?(?:the\s+)?(google\s+chrome|microsoft\s+edge|safari|chrome|firefox|brave|edge|arc)(?:\s+browser)?(?:\s+please)?[.!?]?\s*$"#
    )
    private static let browserPrefixExpression = try! NSRegularExpression(
        pattern: #"(?i)^\s*(?:please\s+)?open\s+(?:the\s+)?(google\s+chrome|microsoft\s+edge|safari|chrome|firefox|brave|edge|arc)(?:\s+browser)?\s+(?:(?:and\s+)?then\s+|and\s+)?((?:go\s+to|open|visit|navigate\s+to)\s+.+)$"#
    )

    private static func browserIdentifier(_ name: String) -> String? {
        browserNames[name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")]
    }

    static func navigation(from utterance: String) -> NativeWebNavigation? {
        var request = hailExpression.stringByReplacingMatches(
            in: utterance, range: NSRange(utterance.startIndex..., in: utterance),
            withTemplate: ""
        )
        var browser: String?
        // Speech can omit "in": "go to Black Label chrome". Strip the
        // browser only provisionally; the remaining whole command must still
        // resolve to an exact URL or reviewed website name below.
        if let suffix = browserSuffixExpression.firstMatch(
            in: request, range: NSRange(request.startIndex..., in: request)
        ), let browserRange = Range(suffix.range(at: 1), in: request),
           let suffixRange = Range(suffix.range, in: request) {
            browser = browserIdentifier(String(request[browserRange]))
            request.removeSubrange(suffixRange)
        }
        if let prefix = browserPrefixExpression.firstMatch(
            in: request, range: NSRange(request.startIndex..., in: request)
        ), let browserRange = Range(prefix.range(at: 1), in: request),
           let destinationRange = Range(prefix.range(at: 2), in: request) {
            let prefixBrowser = browserIdentifier(String(request[browserRange]))
            guard browser == nil || browser == prefixBrowser else { return nil }
            browser = prefixBrowser
            request = String(request[destinationRange])
            if request.lowercased().hasPrefix("navigate to ") {
                request = "go to " + request.dropFirst(12)
            }
        }
        guard let url = exactURLString(from: request) else { return nil }
        return NativeWebNavigation(url: url, browserBundleIdentifier: browser)
    }

    private static let commandPrefixPattern =
        #"(?i)^\s*(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?(?:open|visit|go\s+to|take\s+me\s+to|pull\s+up|bring\s+up|show\s+me)\s+"#

    private static let canonicalWebsiteURLs: [String: String] = [
        "amazon": "https://www.amazon.com",
        "apple": "https://www.apple.com",
        "black label": "https://blacklabelbots.com",
        "black label bots": "https://blacklabelbots.com",
        "facebook": "https://www.facebook.com",
        "github": "https://github.com",
        "google": "https://www.google.com",
        "google search": "https://www.google.com",
        "instagram": "https://www.instagram.com",
        "linkedin": "https://www.linkedin.com",
        "microsoft": "https://www.microsoft.com",
        "open ai": "https://openai.com",
        "openai": "https://openai.com",
        "reddit": "https://www.reddit.com",
        "tiktok": "https://www.tiktok.com",
        "twitter": "https://x.com",
        "wikipedia": "https://www.wikipedia.org",
        "x": "https://x.com",
        "youtube": "https://www.youtube.com",
    ]

    static func exactURLString(from utterance: String) -> String? {
        let literal = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        if literal.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           literal.range(of: #"(?i)^(?:https?://[^\s]+|(?:[a-z0-9-]+\.)+(?:com|net|org|io|ai|dev|app|tech|edu|gov|co|us|uk|me|xyz)(?:[/?#][^\s]*)?)$"#,
                         options: .regularExpression) != nil {
            return validatedPublicURL(literal)
        }
        guard utterance.range(
            of: #"(?i)^\s*(?:don'?t|do\s+not)\b"#,
            options: .regularExpression
        ) == nil,
        let prefix = utterance.range(
            of: commandPrefixPattern,
            options: .regularExpression
        ) else {
            return nil
        }

        var target = String(utterance[prefix.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        target = target.replacingOccurrences(
            of: #"[.!]+\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }

        // A compound desktop instruction is not one website target. Speech
        // commonly arrives as "open Google Chrome go to blacklabeltec.com";
        // collapsing that phrase into a host opened
        // googlechromegotoblacklabeltec.com in Safari, then forced the owner to
        // repeat the real task. Leave browser-plus-navigation commands to the
        // one Gold execution plan so the requested browser and destination are
        // performed exactly once.
        let startsWithBrowserApplication = target.range(
            of: #"(?i)^(?:the\s+)?(?:google\s+chrome|chrome|safari|firefox|brave|microsoft\s+edge|edge)(?:\s+browser)?\b"#,
            options: .regularExpression
        ) != nil
        let containsSecondNavigation = target.range(
            of: #"(?i)\b(?:(?:and\s+)?then\s+|and\s+)?(?:open|visit|go\s+to|navigate\s+to|take\s+me\s+to|pull\s+up|bring\s+up)\b"#,
            options: .regularExpression
        ) != nil
        let containsDomainDestination = target.range(
            of: #"(?i)(?:https?://|\b[a-z0-9][a-z0-9 -]{0,240}\.(?:com|net|org|info|biz|app|dev|tech|xyz)\b)"#,
            options: .regularExpression
        ) != nil
        guard !(startsWithBrowserApplication
            && (containsSecondNavigation || containsDomainDestination)) else {
            return nil
        }

        if target.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
           let exactURL = validatedPublicURL(target) {
            return exactURL
        }
        if let spokenDomain = normalizedSpokenDomain(target) {
            return "https://\(spokenDomain)"
        }

        let explicitlyNamesWebsite = target.range(
            of: #"(?i)\b(?:web\s*site|site|homepage|web\s*page)\s*$"#,
            options: .regularExpression
        ) != nil
        var normalizedName = target.replacingOccurrences(
            of: #"(?i)^(?:the\s+)+"#,
            with: "",
            options: .regularExpression
        )
        normalizedName = normalizedName.replacingOccurrences(
            of: #"(?i)\s+(?:web\s*site|site|homepage|web\s*page)\s*$"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        normalizedName = normalizedName.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        if let canonical = canonicalWebsiteURLs[normalizedName] {
            return canonical
        }
        if explicitlyNamesWebsite && normalizedName == "ace" {
            return "https://ace-bl.tech"
        }

        return nil
    }

    static func explicitlyNamesWebsite(_ utterance: String) -> Bool {
        guard utterance.range(
            of: commandPrefixPattern,
            options: .regularExpression
        ) != nil else { return false }
        return utterance.range(
            of: #"(?i)\b(?:web\s*site|site|homepage|web\s*page|\.com|\.net|\.org|\.io|\.ai|\.tech)\b"#,
            options: .regularExpression
        ) != nil
    }

    private static func validatedPublicURL(_ candidate: String) -> String? {
        let suppliedScheme = candidate.range(
            of: #"(?i)^https?://"#,
            options: .regularExpression
        ) != nil
        let normalized = suppliedScheme ? candidate : "https://\(candidate)"
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              host.contains("."),
              components.user == nil,
              components.password == nil else {
            return nil
        }
        return normalized
    }

    /// Speech recognition commonly inserts spaces inside branded hosts and
    /// spells the separator ("Black Labeltec.com", "black label tech dot
    /// com"). Accept only a whole host-shaped target, then remove whitespace;
    /// ordinary multiword page prose still cannot become a URL.
    private static func normalizedSpokenDomain(
        _ target: String
    ) -> String? {
        var candidate = target.lowercased().replacingOccurrences(
            of: #"\s+dot\s+"#,
            with: ".",
            options: .regularExpression
        )
        candidate = candidate.replacingOccurrences(
            of: #"(?i)^the\s+"#,
            with: "",
            options: .regularExpression
        )
        guard candidate.range(
            of: #"^[a-z0-9][a-z0-9 -]{0,240}\.(?:[a-z]{2}|com|net|org|info|biz|app|dev|tech|xyz)$"#,
            options: .regularExpression
        ) != nil else {
            return nil
        }
        candidate = candidate.replacingOccurrences(
            of: #"\s+"#,
            with: "",
            options: .regularExpression
        )
        guard let components = URLComponents(
            string: "https://\(candidate)"
        ), let host = components.host,
           host.contains("."),
           components.user == nil,
           components.password == nil else {
            return nil
        }
        return host
    }
}
