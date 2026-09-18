import Foundation

nonisolated struct EmailReadWindow: Equatable, Sendable {
    static let phrasePattern = #"(?i)\b(?:(?:in\s+)?the\s+last\s+week|(?:past|last)\s+(?:seven|7)\s+days|past\s+week|last\s+week)\b"#
    let since: String
    let before: String

    var arguments: [String] { ["since=\(since)", "before=\(before)"] }
    var label: String { "from \(since) to \(before) (end date excluded)" }
    var imapCriteria: String {
        func imapDate(_ iso: String) -> String {
            let parts = iso.split(separator: "-").map(String.init)
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            return "\(parts[2])-\(months[Int(parts[1])! - 1])-\(parts[0])"
        }
        return "SINCE \(imapDate(since)) BEFORE \(imapDate(before))"
    }

    init?(arguments: [String]) {
        let starts = arguments.filter { $0.hasPrefix("since=") }
        let ends = arguments.filter { $0.hasPrefix("before=") }
        guard starts.count == 1, ends.count == 1 else { return nil }
        let since = String(starts[0].dropFirst(6))
        let before = String(ends[0].dropFirst(7))
        let formatter = Self.formatter(calendar: Calendar(identifier: .gregorian))
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let start = formatter.date(from: since), let end = formatter.date(from: before),
              formatter.string(from: start) == since, formatter.string(from: end) == before,
              end > start, end.timeIntervalSince(start) <= 31 * 86_400 else { return nil }
        self.since = since
        self.before = before
    }

    private init(since: Date, before: Date, calendar: Calendar) {
        let formatter = Self.formatter(calendar: calendar)
        self.since = formatter.string(from: since)
        self.before = formatter.string(from: before)
    }

    static func requested(in text: String, now: Date, calendar: Calendar) -> Self? {
        guard let range = text.range(of: phrasePattern, options: .regularExpression) else { return nil }
        let phrase = text[range].lowercased()
        var calendar = calendar
        calendar.firstWeekday = 2
        if phrase == "last week", let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now),
           let start = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start) {
            return Self(since: start, before: thisWeek.start, calendar: calendar)
        }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today),
              let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        return Self(since: start, before: end, calendar: calendar)
    }

    private static func formatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}
