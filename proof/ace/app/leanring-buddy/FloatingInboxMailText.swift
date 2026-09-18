import Foundation

/// Bounded text-only MIME previews. No HTML renderer, remote images, links,
/// attachments, or executable mail content enter the bubble surface.
nonisolated enum FloatingInboxMailText {
    static func headers(_ data: Data) -> [String: String] {
        let raw = String(decoding: data.prefix(65536), as: UTF8.self)
        let unfolded = raw.replacingOccurrences(of: #"\r?\n[ \t]+"#, with: " ", options: .regularExpression)
        var fields: [String: String] = [:]
        for line in unfolded.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            if fields[key] == nil {
                fields[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return fields
    }

    static func header(_ value: String) -> String {
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return clean(value) }
        // RFC 2047 ignores whitespace between adjacent encoded words.
        var result = value.replacingOccurrences(of: #"\?=[ \t]+(?==\?)"#, with: "?=", options: .regularExpression)
        let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            let original = result as NSString
            let charset = original.substring(with: match.range(at: 1))
            let encoding = original.substring(with: match.range(at: 2)).lowercased()
            let payload = original.substring(with: match.range(at: 3))
            let data = encoding == "b" ? Data(base64Encoded: payload) : quotedPrintable(payload.replacingOccurrences(of: "_", with: " "))
            if let data, let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: decode(data, charset: charset))
            }
        }
        return clean(result)
    }

    static func preview(headers fields: [String: String], body: Data, depth: Int = 0) -> String {
        guard depth < 4, !body.isEmpty else { return "Open in Gmail to read this message." }
        let contentType = fields["content-type"] ?? "text/plain; charset=utf-8"
        if fields["content-disposition"]?.lowercased().contains("attachment") == true {
            return "Attachment — open in Gmail."
        }
        if contentType.lowercased().hasPrefix("multipart/") {
            guard let boundary = parameter("boundary", in: contentType), boundary.count <= 200 else {
                return "Open in Gmail to read this message."
            }
            let parts = String(decoding: body, as: UTF8.self).components(separatedBy: "--" + boundary).dropFirst().prefix(20)
            var candidates: [([String: String], Data)] = []
            for part in parts {
                let normalized = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = normalized.range(of: "\r\n\r\n") ?? normalized.range(of: "\n\n") else { continue }
                let partFields = headers(Data(normalized[..<separator.lowerBound].utf8))
                guard partFields["content-disposition"]?.lowercased().contains("attachment") != true else { continue }
                candidates.append((partFields, Data(normalized[separator.upperBound...].utf8)))
            }
            let candidate = candidates.first { ($0.0["content-type"] ?? "text/plain").lowercased().hasPrefix("text/plain") }
                ?? candidates.first { ($0.0["content-type"] ?? "").lowercased().hasPrefix("multipart/") }
                ?? candidates.first { ($0.0["content-type"] ?? "").lowercased().hasPrefix("text/html") }
            guard let candidate else { return "Open in Gmail to read this message." }
            return preview(headers: candidate.0, body: candidate.1, depth: depth + 1)
        }
        guard contentType.lowercased().hasPrefix("text/plain") || contentType.lowercased().hasPrefix("text/html") else {
            return "Open in Gmail to read this message."
        }
        let transfer = fields["content-transfer-encoding"]?.lowercased() ?? ""
        let decoded: Data
        switch transfer {
        case "base64":
            let compact = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
            // A fetched excerpt can end mid-quartet; decode only complete units.
            guard let data = Data(base64Encoded: String(compact.prefix(compact.count / 4 * 4))) else {
                return "Open in Gmail to read this message."
            }
            decoded = data
        case "quoted-printable": decoded = quotedPrintable(String(decoding: body, as: UTF8.self))
        default: decoded = body
        }
        var text = decode(decoded, charset: parameter("charset", in: contentType) ?? "utf-8")
        if contentType.lowercased().hasPrefix("text/html") {
            text = text.replacingOccurrences(of: #"(?is)<(script|style|head)\b[^>]*>.*?</\1\s*>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"(?s)<[^>]*>"#, with: " ", options: .regularExpression)
            for (entity, replacement) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
                text = text.replacingOccurrences(of: entity, with: replacement)
            }
        }
        let result = clean(text, limit: 600)
        return result.isEmpty ? "Open in Gmail to read this message." : result
    }

    static func clean(_ value: String, limit: Int = 300) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespacesAndNewlines.contains($0)
        }.filter { ![0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069].contains($0.value) }
        let string = String(String.UnicodeScalarView(scalars))
        return String(string.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(limit))
    }

    private static func parameter(_ name: String, in value: String) -> String? {
        guard let values = GmailIMAPSyntax.captures("(?:^|;)\\s*" + name + #"\s*=\s*(?:"([^"]+)"|([^;\s]+))"#, in: value) else { return nil }
        return values.first { !$0.isEmpty }
    }

    private static func decode(_ data: Data, charset: String) -> String {
        let encoding: String.Encoding
        switch charset.lowercased() {
        case "iso-8859-1", "latin1": encoding = .isoLatin1
        case "windows-1252": encoding = .windowsCP1252
        case "us-ascii": encoding = .ascii
        default: encoding = .utf8
        }
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    private static func quotedPrintable(_ value: String) -> Data {
        let bytes = Array(value.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "").utf8)
        var output = Data(), index = 0
        while index < bytes.count {
            if bytes[index] == 61, index + 2 < bytes.count,
               let byte = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                output.append(byte); index += 3
            } else { output.append(bytes[index]); index += 1 }
        }
        return output
    }
}
