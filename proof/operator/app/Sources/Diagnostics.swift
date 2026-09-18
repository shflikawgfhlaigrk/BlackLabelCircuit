// Sovereign — privacy-safe diagnostic report (DOD-11.5).
// A support bundle a buyer can attach to a help request. Composition is a PURE function over an
// explicit facts struct, so what can appear in the file is bounded by construction: the struct
// carries only version identity, environment strings, feature toggles, and integer counts that
// Settings already displays. No conversation content, no document text, no credentials, no
// account address, no file paths ever enter the composer — and the logic tests assert that
// contract against a fully-populated report.
import Foundation

/// Every fact the diagnostic report may contain. Adding a field here is a REVIEWED act:
/// nothing outside this struct can reach the exported file.
struct DiagnosticFacts {
    // Identity (from the bundle — never hardcoded).
    var appVersion: String
    var buildNumber: String
    var bundleID: String
    // Environment.
    var osVersion: String
    var architecture: String
    // Configuration shown in Settings (labels, never secrets).
    var brainProviderLabel: String
    var localModelTag: String        // e.g. "llama3.2" — a public model tag, not a credential
    var wakeWordEnabled: Bool
    var signedIn: Bool
    var accountKind: String          // "guest" or "account" — NEVER the address
    // Local storage counts (the same numbers the Settings storage panel shows).
    var conversations: Int
    var messages: Int
    var documents: Int
    var knowledgeWords: Int
    var notes: Int
    var memories: Int
    var savedPrompts: Int
    var automations: Int
    var reminders: Int
    // Timestamp.
    var generatedAt: Date
}

enum DiagnosticsReport {
    /// Compose the exported text. Pure and deterministic given the facts (timestamp included in
    /// the facts, not read here) so the logic tests can pin its exact privacy surface.
    static func compose(_ f: DiagnosticFacts) -> String {
        let iso = ISO8601DateFormatter().string(from: f.generatedAt)
        var s = ""
        s += "SOVEREIGN DIAGNOSTIC REPORT\n"
        s += "===========================\n"
        s += "Generated: \(iso)\n"
        s += "\n"
        s += "This report is privacy-safe by construction. It contains ONLY the facts below:\n"
        s += "version identity, macOS version and architecture, feature toggles, and item\n"
        s += "counts. It contains NO conversation content, NO document or note text, NO\n"
        s += "credentials or keys, NO account address, and NO file paths.\n"
        s += "\n"
        s += "[App]\n"
        s += "Version:        \(f.appVersion) (build \(f.buildNumber))\n"
        s += "Bundle ID:      \(f.bundleID)\n"
        s += "\n"
        s += "[Environment]\n"
        s += "macOS:          \(f.osVersion)\n"
        s += "Architecture:   \(f.architecture)\n"
        s += "\n"
        s += "[Configuration]\n"
        s += "Brain route:    \(f.brainProviderLabel)\n"
        s += "Local model:    \(f.localModelTag.isEmpty ? "none selected" : f.localModelTag)\n"
        s += "Wake word:      \(f.wakeWordEnabled ? "enabled" : "off")\n"
        s += "Session:        \(f.signedIn ? "signed in (\(f.accountKind))" : "signed out")\n"
        s += "\n"
        s += "[Local storage counts]\n"
        s += "Conversations:  \(f.conversations)\n"
        s += "Messages:       \(f.messages)\n"
        s += "Documents:      \(f.documents)\n"
        s += "Knowledge words:\(String(format: " %d", f.knowledgeWords))\n"
        s += "Notes:          \(f.notes)\n"
        s += "Memories:       \(f.memories)\n"
        s += "Saved prompts:  \(f.savedPrompts)\n"
        s += "Automations:    \(f.automations)\n"
        s += "Reminders:      \(f.reminders)\n"
        return s
    }

    /// Default export filename, timestamped to the minute.
    static func filename(for date: Date = Date()) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmm"
        return "Sovereign-Diagnostics-\(df.string(from: date)).txt"
    }

    /// Machine architecture of the running process (arm64 / x86_64), via uname — no shelling out.
    static func currentArchitecture() -> String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}
