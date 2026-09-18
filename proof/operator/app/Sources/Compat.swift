// Compat.swift — cross-platform shims so the shared SwiftUI code compiles on BOTH macOS and iOS.
//
// Strategy: on iOS (UIKit), provide thin stand-ins for the few AppKit types/classes Sovereign uses,
// so existing call sites compile UNCHANGED. macOS keeps using the real AppKit types.
//
// iOS-deferred behaviors are marked TODO(iOS) and behave sensibly (no crashes) for this phase.
// What this app actually touches from AppKit (grepped from Sources/):
//   NSColor, NSImage, NSView, NSPasteboard, NSWorkspace.open / .accessibilityDisplayShouldReduceMotion,
//   NSSavePanel, NSOpenPanel (incl .prompt/.message), NSApplication.keyWindow/.windows, Image(nsImage:),
//   NSColorSpace + UIColor component accessors, NSSound.beep.
// (NSStatusBar/NSPanel/NSMenu/Carbon hotkey live in MenuBar.swift, which is entirely #if os(macOS).)

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif

// MARK: - Cross-platform Foundation shims (compiled on BOTH platforms)

extension URL {
    /// `.withSecurityScope` bookmark option is macOS-only. On iOS, document-picker URLs produce
    /// usable security-scoped bookmarks WITHOUT that option (a plain `bookmarkData()` is correct).
    /// This keeps Files.swift's call sites unchanged across platforms.
    static var blSecurityScopeBookmarkOptions: BookmarkCreationOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }
    static var blSecurityScopeResolutionOptions: BookmarkResolutionOptions {
        #if os(macOS)
        return [.withSecurityScope]
        #else
        return []
        #endif
    }
}

// MARK: - Cross-platform SwiftUI shims (compiled on BOTH platforms)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension View {
    /// `.datePickerStyle(.field).controlSize(.small)` is macOS-only. On iOS the closest compact,
    /// inline field is `.compact`. Used by ActivityScreen's custom date range pickers.
    @ViewBuilder func compactFieldDatePicker() -> some View {
        #if os(macOS)
        self.datePickerStyle(.field).controlSize(.small)
        #else
        self.datePickerStyle(.compact)
        #endif
    }
}
#endif // circuit-convert

#if canImport(UIKit)
import UIKit

// MARK: cosmetic type bridges (API-compatible enough for this app's usage)
typealias NSColor = UIColor
typealias NSFont = UIFont
typealias NSImage = UIImage
typealias NSView = UIView

// MARK: clipboard — maps NSPasteboard.general.clearContents()/setString(_,forType:.string)
final class NSPasteboard {
    enum PasteboardType { case string }
    static let general = NSPasteboard()
    func clearContents() { UIPasteboard.general.string = "" }
    func setString(_ s: String, forType _: PasteboardType) { UIPasteboard.general.string = s }
}

// MARK: open a URL + reduce-motion — maps NSWorkspace.shared.open(url) and the accessibility flag
// the QuickAsk theme resolver reads (that path is macOS-only, but keep the property here so any
// future iOS use compiles).
final class NSWorkspace {
    static let shared = NSWorkspace()
    @discardableResult
    @MainActor func open(_ url: URL) -> Bool { UIApplication.shared.open(url); return true }
    var accessibilityDisplayShouldReduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }
}

// MARK: file save — maps NSSavePanel usage. iOS: write into Documents (visible in Files if
// UIFileSharingEnabled) and offer a share sheet. Caller writes to `url` after runModal()==.OK.
final class NSSavePanel {
    enum ModalResponse: Equatable { case OK, cancel }
    var nameFieldStringValue: String = ""
    var allowedContentTypes: [UTType] = []
    var title: String = ""
    var message: String = ""
    var prompt: String = ""
    var url: URL?
    @MainActor @discardableResult
    func runModal() -> ModalResponse {
        let name = nameFieldStringValue.isEmpty ? "export" : nameFieldStringValue
        let dir = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent(name)
        return .OK   // TODO(iOS): present a UIDocumentPicker (export) + share sheet instead of silent write
    }
}

// MARK: file open — maps NSOpenPanel. iOS: not wired (returns cancel). TODO(iOS): document picker.
final class NSOpenPanel {
    var allowsMultipleSelection = false
    var allowedContentTypes: [UTType] = []
    var canChooseDirectories = false
    var canChooseFiles = true
    var title: String = ""
    var message: String = ""
    var prompt: String = ""
    var urls: [URL] = []
    var url: URL?
    @MainActor @discardableResult
    func runModal() -> NSSavePanel.ModalResponse { .cancel } // TODO(iOS): present UIDocumentPickerViewController
}

// MARK: app/window — maps NSApplication.shared.keyWindow / .windows (used as presentation anchors)
final class NSApplication {
    static let shared = NSApplication()
    @MainActor var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
    @MainActor var windows: [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
    }
}

// `NSApp` global — AppKit exposes this as a shorthand for NSApplication.shared. Social.swift's
// ASWebAuthentication presentation anchor reads `NSApp.keyWindow ?? NSApp.windows.first`.
@MainActor let NSApp = NSApplication.shared

// MARK: sound — maps NSSound.beep() (used as a fallback when notifications aren't authorized).
// iOS has no system "beep"; a light haptic is the closest honest stand-in (no audio file fabricated).
enum NSSound {
    @MainActor static func beep() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

// Present a share sheet for a file (use after exporting on iOS).
@MainActor
func iosShareFile(_ url: URL) {
    let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    present(av)
}

// MARK: - iOS file I/O bridge (real UIDocumentPicker import + share-sheet export)
//
// Phase-2: the synchronous NSOpenPanel/NSSavePanel shims above used to return .cancel / write
// silently — i.e. dead import buttons and invisible exports on iPhone. These helpers wire the
// REAL UIKit pickers. Call sites use `#if os(macOS)` (unchanged AppKit panel) / `#else` (these),
// so macOS stays byte-identical and iOS gets a genuinely working flow.

// Find the top-most view controller to present from (sheets/alerts can already be up).
@MainActor
private func topPresenter() -> UIViewController? {
    var vc = NSApplication.shared.keyWindow?.rootViewController
        ?? NSApplication.shared.windows.first?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
}

@MainActor
private func present(_ vc: UIViewController) {
    guard let host = topPresenter() else { return }
    // iPad: a popover needs a source; anchor to the host view's center so it never crashes.
    if let pop = vc.popoverPresentationController {
        pop.sourceView = host.view
        pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
        pop.permittedArrowDirections = []
    }
    host.present(vc, animated: true)
}

// Retains the picker delegate for the lifetime of the presentation (UIKit holds only weakly).
@MainActor private var _blPickerDelegates: [ObjectIdentifier: AnyObject] = [:]

@MainActor
final class _BLDocPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let onPick: ([URL]) -> Void
    init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // Copy security-scoped picks into the app's tmp so the URLs stay readable after the
        // scope closes (matches the macOS panel, where the returned URL is directly readable).
        var readable: [URL] = []
        for src in urls {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: dst)
            if (try? FileManager.default.copyItem(at: src, to: dst)) != nil { readable.append(dst) }
            else { readable.append(src) }   // directory picks: hand back the original (caller re-scopes)
        }
        _blPickerDelegates[ObjectIdentifier(controller)] = nil
        onPick(readable)
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        _blPickerDelegates[ObjectIdentifier(controller)] = nil
        onPick([])
    }
}

/// Present a real document picker. `completion` runs on the main actor with the chosen URL(s)
/// (empty if cancelled). Mirrors NSOpenPanel's intent so call sites stay tiny.
@MainActor
func iosImportFiles(contentTypes: [UTType],
                    allowsMultiple: Bool = false,
                    pickDirectories: Bool = false,
                    completion: @escaping ([URL]) -> Void) {
    let types: [UTType] = pickDirectories ? [.folder]
        : (contentTypes.isEmpty ? [.item] : contentTypes)
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: !pickDirectories)
    picker.allowsMultipleSelection = allowsMultiple
    let delegate = _BLDocPickerDelegate(onPick: completion)
    picker.delegate = delegate
    _blPickerDelegates[ObjectIdentifier(picker)] = delegate
    present(picker)
}

/// Write text to a temp file and present the iOS share sheet (Save to Files, Mail, etc.).
@MainActor
func iosExportText(_ text: String, suggestedName: String) {
    let name = suggestedName.isEmpty ? "export.txt" : suggestedName.replacingOccurrences(of: "/", with: "-")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try? text.data(using: .utf8)?.write(to: url)
    iosShareFile(url)
}

// Image(nsImage:) → uiImage on iOS
extension Image { init(nsImage: UIImage) { self.init(uiImage: nsImage) } }

// .toggleStyle(.checkbox) is macOS-only → fall back to a switch on iOS (kept for safety; this app
// uses .switch/default styles today, but call sites copied from siblings may reference it).
extension ToggleStyle where Self == SwitchToggleStyle {
    static var checkbox: SwitchToggleStyle { SwitchToggleStyle() }
}

// NSColor(=UIColor) color-space + component accessors used by Holographic.swift's hex round-trip.
enum NSColorSpace { case sRGB, deviceRGB, genericRGB }
extension UIColor {
    func usingColorSpace(_ : NSColorSpace) -> UIColor? { self }
    var redComponent: CGFloat { var v: CGFloat = 0; getRed(&v, green: nil, blue: nil, alpha: nil); return v }
    var greenComponent: CGFloat { var v: CGFloat = 0; getRed(nil, green: &v, blue: nil, alpha: nil); return v }
    var blueComponent: CGFloat { var v: CGFloat = 0; getRed(nil, green: nil, blue: &v, alpha: nil); return v }
    var alphaComponent: CGFloat { var v: CGFloat = 0; getRed(nil, green: nil, blue: nil, alpha: &v); return v }
}

// NSFontManager.shared.availableFontFamilies → UIFont.familyNames (not used today; parity w/ siblings)
final class NSFontManager {
    static let shared = NSFontManager()
    var availableFontFamilies: [String] { UIFont.familyNames }
}
#endif
