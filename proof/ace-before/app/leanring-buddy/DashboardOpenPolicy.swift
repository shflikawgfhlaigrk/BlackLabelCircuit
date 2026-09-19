import Foundation

/// Deterministic grammar and path resolution for "open my dashboard" —
/// launching a dashboard the owner already built under `~/Ace Projects`.
///
/// This is a fixed product route, not a model-planned effect: the owner names a
/// dashboard they own, and app code resolves it inside one sanitized directory.
/// Nothing here can reach a path outside `~/Ace Projects`, and nothing here
/// runs the project — it only resolves WHICH project, so the caller can hand a
/// validated root to the already-sealed dashboard host.
nonisolated enum DashboardOpenPolicy {

    /// Anchored open-grammar. A mutation verb anywhere disqualifies the whole
    /// utterance so this can never become a build/delete path, and questions
    /// ("how do i open my dashboard") stay with the brain.
    private static let requestPattern =
        #"(?i)^\s*(?:(?:hey\s+)?ace[\s,]+)?(?:please\s+)?(?:(?:can|could|would)\s+you(?:\s+please)?\s+)?"#
        + #"(?:open|show|bring\s+up|pull\s+up|launch|display)\s+"#
        + #"(?:(?:me|us)\s+)?(?:my\s+|the\s+|our\s+)?"#
        + #"(?:(.+?)\s+)?dashboard\s*[?.!]?\s*$"#

    private static let mutationPattern =
        #"(?i)\b(build|create|make|generate|write|delete|remove|rebuild|change|edit|update|rename|deploy|publish)\b"#

    private static let questionPattern =
        #"(?i)^\s*(?:how|why|what|when|where|who|do|does|did|is|are|should|can\s+i)\b"#

    /// Returns the spoken dashboard name when this is an open request.
    /// An empty string means "the dashboard" with no qualifier — the caller
    /// resolves that against what actually exists.
    static func requestedDashboardName(_ text: String) -> String? {
        guard text.range(
            of: mutationPattern,
            options: .regularExpression
        ) == nil,
              text.range(
                of: questionPattern,
                options: .regularExpression
              ) == nil else {
            return nil
        }
        guard let match = text.range(
            of: requestPattern,
            options: .regularExpression
        ), match.lowerBound == text.startIndex else {
            return nil
        }
        // Recover the optional qualifier group with NSRegularExpression so the
        // spoken name ("command deck") can be matched against real folders.
        guard let expression = try? NSRegularExpression(
            pattern: requestPattern
        ) else {
            return ""
        }
        let nsText = text as NSString
        guard let result = expression.firstMatch(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        ) else {
            return ""
        }
        let qualifierRange = result.range(at: 1)
        guard qualifierRange.location != NSNotFound else { return "" }
        return nsText.substring(with: qualifierRange)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Normalizes a spoken name or a folder name to a comparable form:
    /// lowercase, alphanumerics only. "Ace Command Deck" and "command deck"
    /// both reduce to matchable text without inviting fuzzy path tricks.
    static func normalized(_ value: String) -> String {
        value.lowercased().unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
    }

    /// Chooses one project folder for a spoken name.
    ///
    /// Fail-closed by design: an ambiguous request resolves to nothing rather
    /// than guessing, because opening the WRONG dashboard on a projector in
    /// front of an audience is worse than saying "which one".
    enum Resolution: Equatable, Sendable {
        case resolved(String)
        case none
        case ambiguous([String])
    }

    static func resolve(
        spokenName: String,
        availableProjects: [String]
    ) -> Resolution {
        // Only folders that actually carry a dashboard entry point are
        // candidates; the caller filters for index.html + run.command.
        guard !availableProjects.isEmpty else { return .none }

        let target = normalized(spokenName)
        if target.isEmpty {
            // No qualifier: unambiguous only when exactly one exists.
            return availableProjects.count == 1
                ? .resolved(availableProjects[0])
                : .ambiguous(availableProjects.sorted())
        }

        let exact = availableProjects.filter {
            normalized($0) == target
        }
        if exact.count == 1 { return .resolved(exact[0]) }
        if exact.count > 1 { return .ambiguous(exact.sorted()) }

        let contained = availableProjects.filter {
            normalized($0).contains(target)
        }
        if contained.count == 1 { return .resolved(contained[0]) }
        if contained.count > 1 { return .ambiguous(contained.sorted()) }
        return .none
    }

    /// The one directory a dashboard may ever live in. A resolved project is
    /// exactly one path component under it — never a traversal, never a
    /// symlink target, never a hidden folder.
    static func projectRootURL(
        for projectName: String,
        homeDirectory: URL
    ) -> URL? {
        guard !projectName.isEmpty,
              !projectName.hasPrefix("."),
              !projectName.contains("/"),
              !projectName.contains("\\") else {
            return nil
        }
        let projectsRoot = homeDirectory
            .appendingPathComponent("Ace Projects", isDirectory: true)
            .standardizedFileURL
        let candidate = projectsRoot
            .appendingPathComponent(projectName, isDirectory: true)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent().path
                == projectsRoot.path else {
            return nil
        }
        return candidate
    }

    static func spokenAmbiguity(_ options: [String]) -> String {
        let named = options.prefix(4).joined(separator: ", ")
        return "i have more than one dashboard: \(named). which one?"
    }

    static let spokenNoneFound =
        "i don't have a dashboard built yet. ask me to build one first."
}
