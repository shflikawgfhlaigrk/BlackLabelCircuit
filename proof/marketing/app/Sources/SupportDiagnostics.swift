// Black Label Marketing — Support & diagnostics (DOD-7.6 / DOD-11.5).
//
// ONE place computes the privacy-safe facts the Settings ▸ Support & diagnostics panel SHOWS
// and the diagnostic-bundle export WRITES — both render the same [DiagnosticFact] array, so the
// exported file can never drift from the surface the user just read.
//
// Foundation-only on purpose: the fast test lane (Tests/run.sh) compiles this file with bare
// `swift` — no SwiftUI, no AppKit — and nothing here may ever need an entitlement, a network
// call, or a secret.
//
// PRIVACY RULE (the point of DOD-11.5): a fact is admissible only when it contains no account
// identifier, no token or credential, no lead or message content, and no absolute path that
// embeds the user's account name — paths under the user's home directory are rendered with a
// "~" prefix instead (`redactingHomeDirectory`). The export states this contract in the file
// itself so support staff and the user can both hold it to account.

import Foundation

/// One privacy-safe support fact — a label/value pair shown in Settings and written verbatim
/// into the exported diagnostic bundle.
struct DiagnosticFact: Identifiable, Equatable {
    let label: String
    let value: String
    var id: String { label }
}

enum SupportDiagnostics {
    // MARK: - The contract the export makes, in the export's own words.
    static let privacyStatement = """
        This diagnostic bundle contains ONLY the facts listed above: the app's version and \
        install facts, system version, and which bundled components are present. It contains \
        no account emails, no tokens, credentials, or Keychain items, no leads or contacts, \
        no message or campaign content, and no paths that reveal the account name (your home \
        folder appears as "~").
        """

    /// App version as a buyer-facing string, e.g. "1.1 (build 72)". Reads the bundle's own
    /// Info.plist — never a hardcoded literal, so it can never go stale (the About panel's old
    /// hardcoded "1.0" is exactly the failure this exists to prevent).
    static func appVersionString(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (v?, b?): return "\(v) (build \(b))"
        case let (v?, nil): return v
        case let (nil, b?): return "build \(b)"
        default: return "unknown (unbundled build)"
        }
    }

    /// Replace the user's home-directory prefix with "~" so no exported path embeds the macOS
    /// account name. Paths outside the home directory pass through unchanged.
    static func redactingHomeDirectory(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// The support facts, in display order. Every value is computed from the running process
    /// and bundle — nothing is remembered, nothing is fabricated, and absence is stated
    /// ("not in this build") rather than omitted.
    static func facts(bundle: Bundle = .main, now: Date = Date()) -> [DiagnosticFact] {
        var facts: [DiagnosticFact] = []

        facts.append(DiagnosticFact(label: "App", value: AppBrand.displayName))
        facts.append(DiagnosticFact(label: "Version", value: appVersionString(bundle: bundle)))
        facts.append(DiagnosticFact(
            label: "Bundle identifier",
            value: bundle.bundleIdentifier ?? "none (unbundled build)"))

        #if DIRECT_DISTRIBUTION
        facts.append(DiagnosticFact(label: "Distribution", value: "Direct (Developer ID)"))
        #else
        facts.append(DiagnosticFact(label: "Distribution", value: "App Store"))
        #endif

        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #if os(iOS)
        facts.append(DiagnosticFact(label: "System", value: "iOS \(os)"))
        #else
        facts.append(DiagnosticFact(label: "System", value: "macOS \(os)"))
        #endif

        #if arch(arm64)
        facts.append(DiagnosticFact(label: "Architecture", value: "arm64 (Apple silicon)"))
        #elseif arch(x86_64)
        facts.append(DiagnosticFact(label: "Architecture", value: "x86_64 (Intel)"))
        #else
        facts.append(DiagnosticFact(label: "Architecture", value: "other"))
        #endif

        facts.append(DiagnosticFact(
            label: "Install location",
            value: redactingHomeDirectory(bundle.bundlePath)))

        // Bundled components — presence is checked, never assumed (HONESTY RULE from
        // BundledGuides: an absent component is stated as absent).
        let mcpPresent = bundle.url(forResource: "server", withExtension: "mjs",
                                    subdirectory: "mcp") != nil
        facts.append(DiagnosticFact(
            label: "Bundled MCP server",
            value: mcpPresent ? "present (Resources/mcp/server.mjs)" : "not in this build"))

        let guideCount = (bundle.urls(forResourcesWithExtension: "md",
                                      subdirectory: "guides") ?? []).count
        facts.append(DiagnosticFact(
            label: "Bundled guides",
            value: guideCount > 0 ? "\(guideCount) documents" : "not in this build"))

        facts.append(DiagnosticFact(
            label: "Locale / time zone",
            value: "\(Locale.current.identifier) / \(TimeZone.current.identifier)"))

        // Free space on the user-data volume — the single most common support fact for
        // render/export failures. Reported honestly as unknown when the query fails.
        if let capacity = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            facts.append(DiagnosticFact(
                label: "Free disk space",
                value: formatter.string(fromByteCount: capacity)))
        } else {
            facts.append(DiagnosticFact(label: "Free disk space", value: "could not be determined"))
        }

        return facts
    }

    /// Render the facts as the exported diagnostic bundle — a plain-text file a buyer can read
    /// in full before sending, with the privacy contract stated inside the file itself.
    static func bundleText(_ facts: [DiagnosticFact], generatedAt: Date = Date()) -> String {
        let stamp = ISO8601DateFormatter().string(from: generatedAt)
        var lines: [String] = []
        lines.append("\(AppBrand.displayName) — diagnostic bundle")
        lines.append("Generated: \(stamp)")
        lines.append("Source: Settings ▸ Support & diagnostics ▸ Export diagnostic bundle")
        lines.append(String(repeating: "-", count: 56))
        let width = facts.map { $0.label.count }.max() ?? 0
        for fact in facts {
            let pad = String(repeating: " ", count: max(0, width - fact.label.count))
            lines.append("\(fact.label)\(pad)  \(fact.value)")
        }
        lines.append(String(repeating: "-", count: 56))
        lines.append(privacyStatement)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Default export filename, timestamped so repeated exports never overwrite each other.
    static func defaultFilename(now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return "black-label-marketing-diagnostics-\(f.string(from: now)).txt"
    }
}
