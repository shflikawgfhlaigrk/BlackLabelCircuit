// Sovereign — bundled buyer guides (DOD-3.7: documentation must be reachable INSIDE the product).
// The six markdown guides written for buyers (docs/guides/*.md in the repo) are copied into the
// app bundle at build time (Contents/Resources/Guides by the swiftc lanes; a `guides` folder
// reference in the Xcode lanes) and rendered in-app by the existing in-house MarkdownView —
// no internet, no external reader, nothing fabricated: if a guide file is genuinely absent from
// this build, the Help row says so instead of pretending.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// One buyer guide shipped inside the bundle. `fileName` is the on-disk markdown name
/// (without extension) exactly as authored in docs/guides/.
struct BundledGuide: Identifiable, Equatable {
    let fileName: String   // e.g. "FIRST-RUN"
    let title: String      // human title shown in Help
    let blurb: String      // one-line description
    let icon: String       // SF Symbol
    var id: String { fileName }
}

enum GuideLibrary {
    #if os(iOS)
    /// The six guides are authored for the Mac buyer lane — package sha256 verification, Ollama/
    /// Homebrew installs, `defaults delete`, drag-to-Trash uninstall. On iPhone every one of those
    /// instructions is wrong about how the buyer got, updates, and removes the product (§5.1), so
    /// the iOS catalog ships EMPTY (Help hides the panel) until iOS-specific guides are authored.
    static let catalog: [BundledGuide] = []
    #else
    /// The shipped catalog — must track docs/guides/*.md one-to-one.
    static let catalog: [BundledGuide] = [
        BundledGuide(fileName: "FIRST-RUN", title: "First-Run Guide",
                     blurb: "Install, first launch, onboarding, and your first question.",
                     icon: "sparkles"),
        BundledGuide(fileName: "FEATURES", title: "Feature Guide",
                     blurb: "Every screen and what it really does.",
                     icon: "square.grid.2x2.fill"),
        BundledGuide(fileName: "INTEGRATIONS", title: "Integration Guide",
                     blurb: "Brains and services you own: Ollama, local servers, your own API.",
                     icon: "point.3.filled.connected.trianglepath.dotted"),
        BundledGuide(fileName: "PERMISSIONS", title: "Permission Guide",
                     blurb: "What each macOS permission is for, and how to grant, revoke, recover.",
                     icon: "lock.shield.fill"),
        BundledGuide(fileName: "RECOVERY", title: "Recovery Guide",
                     blurb: "Where your data lives and how to get back to a working state.",
                     icon: "arrow.counterclockwise.circle.fill"),
        BundledGuide(fileName: "UNINSTALL", title: "Uninstall Guide",
                     blurb: "Remove the app and every byte it wrote.",
                     icon: "trash.circle.fill")
    ]
    #endif

    /// Bundle subdirectories the guides may live under: "Guides" (swiftc release lanes) or
    /// "guides" (Xcode folder-reference copy keeps the filesystem name). Root is a last resort.
    private static let subdirectories: [String?] = ["Guides", "guides", nil]

    /// Load a guide's markdown from the app bundle. Returns nil when the file is truly not in
    /// this build — callers must surface that honestly, never render placeholder prose.
    static func text(for guide: BundledGuide, bundle: Bundle = .main) -> String? {
        for sub in subdirectories {
            if let url = bundle.url(forResource: guide.fileName, withExtension: "md", subdirectory: sub),
               let s = try? String(contentsOf: url, encoding: .utf8) {
                return s
            }
        }
        return nil
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Full-text reader for one bundled guide. Presented as a sheet from Help.
struct GuideReaderView: View {
    let guide: BundledGuide
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: guide.icon).font(.system(size: 14, weight: .bold)).foregroundColor(BLTheme.ink)
                    .frame(width: 32, height: 32).background(BLTheme.goldGrad).clipShape(RoundedRectangle(cornerRadius: 9))
                Text(guide.title).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundColor(BLTheme.sub)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close \(guide.title)")
            }
            .padding(16)
            Rectangle().fill(BLTheme.stroke).frame(height: 1)
            if let text = GuideLibrary.text(for: guide) {
                ScrollView {
                    MarkdownView(text: text)
                        .padding(20)
                        .frame(maxWidth: 720, alignment: .leading)
                }
            } else {
                // Honest absence: this build genuinely does not carry the file.
                VStack(spacing: 8) {
                    Image(systemName: "doc.questionmark").font(.system(size: 24)).foregroundColor(BLTheme.sub)
                    Text("This guide is not bundled in this build.")
                        .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("The \(guide.title) ships inside release packages; this copy of the app was built without it.")
                        .font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            }
        }
        .background(BLTheme.bg)
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 620)
        #endif
    }
}
#endif // circuit-convert
