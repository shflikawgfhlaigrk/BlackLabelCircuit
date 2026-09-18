// Black Label Marketing — the guides that ship INSIDE the product.
//
// The six buyer guides (plus the three provider setup walkthroughs they index) are bundled at
// Contents/Resources/guides/ by project.yml, so "see the setup guide" is a real document on the
// buyer's Mac — never a pointer to a repository that only exists on the build machine.
//
// READ IN-APP, NOT HANDED OFF (2026-08-10): opening a guide used to call NSWorkspace.shared.open
// on the .md file, which launches whatever the Mac has registered for Markdown — VS Code on a
// developer's machine, TextEdit or Xcode elsewhere. Ejecting the buyer into a code editor to read
// this product's own documentation is not a viewer decision, it is a bug. Guides now render in the
// app (Sources/GuideReaderScreen.swift + GuideMarkdown.swift); this type only locates and reads
// the shipped bytes, so the text the buyer sees is byte-for-byte the file that shipped.
//
// HONESTY RULE: `url(_:)` / `text(_:)` return nil when a guide is genuinely absent (e.g. an
// unbundled developer build), and every caller must surface that as "not included in this build"
// rather than silently doing nothing.

import Foundation

enum BundledGuides {
    /// One shipped guide. `file` is the exact basename inside Resources/guides/.
    struct Guide: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        let file: String
    }

    /// The buyer-facing library, in reading order. Titles say what the buyer gets, not what the
    /// document is called internally.
    static let library: [Guide] = [
        Guide(id: "first-run", title: "First run",
              detail: "What happens on first launch, the demo workspace, and how to go live.",
              file: "FIRST-RUN.md"),
        Guide(id: "features", title: "Features",
              detail: "Every advertised capability and where to find it in the app.",
              file: "FEATURES.md"),
        Guide(id: "permissions", title: "Permissions",
              detail: "Each macOS permission this app can ask for, why, and what still works without it.",
              file: "PERMISSIONS.md"),
        Guide(id: "integrations", title: "Integrations & setup",
              detail: "Connecting mailboxes, social accounts, analytics, CRM, and messaging — all on your own accounts.",
              file: "INTEGRATIONS.md"),
        Guide(id: "recovery", title: "Recovery",
              detail: "What to do when a connection dies, a token expires, or something fails mid-job.",
              file: "RECOVERY.md"),
        Guide(id: "uninstall", title: "Uninstall",
              detail: "How to remove the app completely, and exactly what data removal leaves behind.",
              file: "UNINSTALL.md"),
    ]

    /// The bundled URL for a guide file, or nil when this build genuinely does not carry it.
    static func url(_ file: String) -> URL? {
        let base = (file as NSString).deletingPathExtension
        let ext = (file as NSString).pathExtension
        return Bundle.main.url(forResource: base, withExtension: ext, subdirectory: "guides")
    }

    /// The shipped text of a guide, or nil when it is not in this build (or is unreadable). The
    /// reader must say so out loud — never render an empty page.
    static func text(_ file: String) -> String? {
        guard let url = url(file) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// A readable entry for ANY shipped guide file. The six library guides return their own row;
    /// the setup walkthroughs (CLOUDFLARE-ANALYTICS-SETUP.md, SOCIAL-SETUP.md, EMAIL-API-SETUP.md)
    /// are opened straight from the connector that needs them, so they get a synthesized entry
    /// rather than being unopenable for not appearing in the library.
    static func entry(for file: String) -> Guide {
        library.first(where: { $0.file == file })
            ?? Guide(id: file, title: title(for: file), detail: "", file: file)
    }

    /// A human title for any guide file, including the setup walkthroughs that are referenced by
    /// the six library guides but are not themselves library rows (SOCIAL-SETUP.md → "Social
    /// setup"). Falls back to the filename so an unknown document is still named, never "Untitled".
    static func title(for file: String) -> String {
        if let known = library.first(where: { $0.file == file }) { return known.title }
        let base = (file as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ")
        guard let first = base.first else { return file }
        return String(first).uppercased() + base.dropFirst().lowercased()
    }
}
