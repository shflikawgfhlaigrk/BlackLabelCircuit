// Black Label Marketing — Brand kit import control (MK-16).
//
// Buyer-initiated starter-kit import: point it at YOUR OWN domain and it reads the site's public
// metadata (name, tagline, theme-color, logo) into your locked brand kit — the same kit the reel,
// site, and email generators all read. Honest: if nothing is found it leaves your kit unchanged and
// says so; it never invents a color or a name (§5.1).
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct BrandKitImportControl: View {
    @EnvironmentObject var prefs: Prefs
    @State private var domain = ""
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Brand kit")
                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text("Build a starter brand kit from your own domain — your name, tagline, and colors, pulled from your site's public metadata. It feeds your reels, sites, and email the same way.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Field(title: "", text: $domain, prompt: "yourbrand.com")
                GoldButton(label: busy ? "Reading…" : "Import kit", icon: "square.grid.2x2") { importKit() }
                    .opacity(busy ? 0.6 : 1).disabled(busy)
            }
            if !note.isEmpty {
                Text(note).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(note.hasPrefix("✓") ? BLTheme.green : BLTheme.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func importKit() {
        let d = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.isEmpty else { return }
        busy = true; note = ""
        let base = BrandKit(prefs: prefs)
        DispatchQueue.global(qos: .userInitiated).async {
            let kit = BrandKitImporter.liveStarterKit(forDomain: d, base: base)
            DispatchQueue.main.async {
                busy = false
                if kit == base {
                    // Honest empty path: nothing found → leave the buyer's kit exactly as it was.
                    note = "No brand details found at that domain — your kit is unchanged."
                } else {
                    kit.applyImported(to: prefs)
                    note = "✓ Brand kit imported from \(d)."
                }
            }
        }
    }
}
#endif // circuit-convert
