// FileExport.swift — one cross-platform "save this text to a file the user can find" entry point.
//
// macOS: presents an NSSavePanel and writes to the chosen location (unchanged behavior).
// iOS:   writes to a temp file and presents the system share sheet (Save to Files, AirDrop, Mail…),
//        so an export is actually reachable instead of silently landing in the app sandbox.
//
// Returns a short user-facing confirmation string on success, or nil if the user cancelled / it
// failed — call sites use it to set their feedback label truthfully (never claim a save that didn't
// happen).

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
func exportTextFile(suggestedName: String, contents: String, type: UTType = .plainText) -> String? {
    #if os(iOS)
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent(suggestedName)
    guard (try? contents.data(using: .utf8)?.write(to: url)) != nil else { return nil }
    iosShareFile(url)
    return "Ready to save — choose a destination."
    #else
    let panel = NSSavePanel()
    panel.nameFieldStringValue = suggestedName
    panel.allowedContentTypes = [type]
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    guard let data = contents.data(using: .utf8), (try? data.write(to: url)) != nil else { return nil }
    return "Saved \(url.lastPathComponent)."
    #endif
}
#endif // circuit-convert
