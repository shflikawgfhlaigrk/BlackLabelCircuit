import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated enum FloatingInboxLayout {
    /// Saved positions and drags may select a display and height, never the desktop center.
    static func edgePinnedFrame(_ proposed: CGRect, visibleFrames: [CGRect]) -> CGRect {
        guard let fallback = visibleFrames.first else { return proposed }
        var bounds = fallback
        var largestOverlap: CGFloat = 0
        for candidate in visibleFrames {
            let overlap = proposed.intersection(candidate)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > largestOverlap { largestOverlap = area; bounds = candidate }
        }
        let inset: CGFloat = 14
        let x = max(bounds.minX + inset, bounds.maxX - proposed.width - inset)
        let y = min(max(proposed.minY, bounds.minY + inset),
                    max(bounds.minY + inset, bounds.maxY - proposed.height - inset))
        return CGRect(origin: CGPoint(x: x, y: y), size: proposed.size)
    }
}
#endif // circuit-convert

nonisolated enum FloatingInboxSource: String, CaseIterable, Identifiable {
    case automatic, appleMail, gmail
    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .appleMail: return "Apple Mail accounts"
        case .gmail: return "Connected Gmail"
        }
    }
}

nonisolated struct FloatingEmail: Identifiable, Equatable, Sendable {
    let account: String
    let uidValidity: UInt64
    let uid: UInt64
    let gmailID: UInt64
    let sender: String
    let subject: String
    let preview: String
    let date: String
    var appleMailIdentity: String? = nil
    var appleMailMessageID: String? = nil

    var isAppleMail: Bool { appleMailIdentity != nil }
    var id: String { appleMailIdentity.map { "apple-mail/" + $0 } ?? "\(account.lowercased())/\(uidValidity)/\(uid)/\(gmailID)" }
    var appleMailURL: URL? {
        guard let raw = appleMailMessageID else { return nil }
        let identifier = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        guard identifier.contains("@"), identifier.utf8.count <= 998,
              !identifier.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value < 32 || $0.value == 127 }),
              let encoded = ("<" + identifier + ">").addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return URL(string: "message://" + encoded)
    }
    var initials: String {
        let name = sender.components(separatedBy: "<").first ?? sender
        let letters = name.split(whereSeparator: { $0.isWhitespace || $0 == "@" })
            .prefix(2).compactMap(\.first)
        return letters.isEmpty ? "@" : String(letters).uppercased()
    }
    var gmailURL: URL {
        var url = URLComponents(string: "https://mail.google.com/mail/u/")!
        url.queryItems = [URLQueryItem(name: "authuser", value: account)]
        url.fragment = "all/" + String(gmailID, radix: 16)
        return url.url!
    }
}

nonisolated struct FloatingInboxSnapshot: Sendable {
    let messages: [FloatingEmail]
    let unreadCount: Int
}

/// Mail stays in memory. Only opaque dismissal identities and window positions
/// live for the current session; relaunch fetches the buyer's mailbox afresh.
nonisolated struct FloatingInboxState {
    private(set) var messages: [FloatingEmail] = []
    private(set) var unreadCount = 0
    private var dismissed: Set<String> = []
    private var account: String?
    private var uidValidity: UInt64?
    static let maximumBubbles = 5

    mutating func apply(_ snapshot: FloatingInboxSnapshot) {
        if let first = snapshot.messages.first,
           account != first.account || uidValidity != first.uidValidity {
            dismissed.removeAll()
            account = first.account
            uidValidity = first.uidValidity
        }
        unreadCount = max(0, snapshot.unreadCount)
        let currentIDs = Set(snapshot.messages.map(\.id))
        dismissed.formIntersection(currentIDs)
        var unique: Set<String> = []
        messages = Array(snapshot.messages.filter {
            !dismissed.contains($0.id) && unique.insert($0.id).inserted
        }.prefix(Self.maximumBubbles))
    }

    mutating func dismiss(_ id: String) {
        dismissed.insert(id)
        messages.removeAll { $0.id == id }
    }

    mutating func clear() { self = Self() }
}
