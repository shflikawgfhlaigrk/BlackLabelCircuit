// Compat.swift — cross-platform shims so the shared SwiftUI code compiles on BOTH macOS and iOS.
//
// Strategy: on iOS (UIKit), provide thin stand-ins for the few AppKit types/classes the app uses,
// so existing call sites compile UNCHANGED. macOS keeps using the real AppKit types.
//
// iOS-deferred behaviors are marked TODO(iOS) and behave sensibly (no crashes) for v1.

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
extension View {
    /// SwiftUI's one-argument `onChange(of:perform:)` is deprecated on iOS 17/macOS 14, while the
    /// replacement is unavailable on older OS targets. Keep call sites warning-free without raising
    /// the app's minimum OS.
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
        if #available(macOS 14.0, iOS 17.0, *) {
            self.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            self.onChange(of: value, perform: action)
        }
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

// MARK: open a URL — maps NSWorkspace.shared.open(url)
final class NSWorkspace {
    static let shared = NSWorkspace()
    @discardableResult
    func open(_ url: URL) -> Bool { UIApplication.shared.open(url); return true }
}

// MARK: file save — maps NSSavePanel usage. iOS v1: write into Documents (visible in Files if
// UIFileSharingEnabled) and offer a share sheet. Caller writes to `url` after runModal()==.OK.
final class NSSavePanel {
    enum ModalResponse: Equatable { case OK, cancel }
    var nameFieldStringValue: String = ""
    var allowedContentTypes: [UTType] = []
    var url: URL?
    var title: String = ""
    @MainActor @discardableResult
    func runModal() -> ModalResponse {
        let name = nameFieldStringValue.isEmpty ? "export" : nameFieldStringValue
        let dir = (try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent(name)
        return .OK
    }
}

// MARK: file open — maps NSOpenPanel. iOS v1: not wired (returns cancel). TODO(iOS): document picker.
final class NSOpenPanel {
    var allowsMultipleSelection = false
    var allowedContentTypes: [UTType] = []
    var canChooseDirectories = false
    var canChooseFiles = true
    var urls: [URL] = []
    var url: URL?
    @MainActor @discardableResult
    func runModal() -> NSSavePanel.ModalResponse { .cancel } // TODO(iOS): present UIDocumentPickerViewController
}

// MARK: app/window — maps NSApplication.shared.keyWindow / .windows (used for presentation anchors)
final class NSApplication {
    static let shared = NSApplication()
    var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
    var windows: [UIWindow] {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
    }
}

// Resign whatever text field currently owns the keyboard — the shared keyboard "Done" bar
// (SheetCloseBar) routes here so no per-view FocusState plumbing is needed.
@MainActor
func blDismissKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

// Present a share sheet for a file (use after exporting on iOS).
@MainActor
func iosShareFile(_ url: URL) {
    let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    // On iPad the share sheet is a popover and needs a source rect anchor.
    if let pop = av.popoverPresentationController, let root = NSApplication.shared.keyWindow?.rootViewController?.view {
        pop.sourceView = root
        pop.sourceRect = CGRect(x: root.bounds.midX, y: root.bounds.midY, width: 0, height: 0)
        pop.permittedArrowDirections = []
    }
    topPresented()?.present(av, animated: true)
}

// The topmost presented view controller — so a picker/share sheet presents above any open SwiftUI
// sheet instead of failing silently because the root is already presenting.
@MainActor
private func topPresented() -> UIViewController? {
    var vc = NSApplication.shared.keyWindow?.rootViewController
    while let p = vc?.presentedViewController { vc = p }
    return vc
}

// MARK: real iOS file import — presents a UIDocumentPickerViewController and returns the picked
// file's text via the completion handler. Replaces the dead NSOpenPanel path on iOS. Reads the
// file with security-scoped access (required for files outside the app sandbox).
@MainActor
func iosImportFile(types: [UTType], completion: @escaping (_ url: URL, _ text: String) -> Void) {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.plainText] : types, asCopy: true)
    picker.allowsMultipleSelection = false
    let delegate = DocumentPickerDelegate { url in
        var text = ""
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let t = try? String(contentsOf: url, encoding: .utf8) { text = t }
        else if let d = try? Data(contentsOf: url) { text = String(decoding: d, as: UTF8.self) }
        completion(url, text)
    }
    // Retain the delegate for the lifetime of the picker presentation.
    objc_setAssociatedObject(picker, &DocumentPickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
    picker.delegate = delegate
    topPresented()?.present(picker, animated: true)
}

final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    static var key: UInt8 = 0
    let onPick: (URL) -> Void
    init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let u = urls.first { onPick(u) }
    }
}

// Image(nsImage:) → uiImage on iOS
extension Image { init(nsImage: UIImage) { self.init(uiImage: nsImage) } }

// .toggleStyle(.checkbox) is macOS-only → fall back to a switch on iOS
extension ToggleStyle where Self == SwitchToggleStyle {
    static var checkbox: SwitchToggleStyle { SwitchToggleStyle() }
}

// NSColor(=UIColor) color-space + component accessors used by the FX layer
enum NSColorSpace { case sRGB, deviceRGB, genericRGB }
extension UIColor {
    func usingColorSpace(_ : NSColorSpace) -> UIColor? { self }
    var redComponent: CGFloat { var v: CGFloat = 0; getRed(&v, green: nil, blue: nil, alpha: nil); return v }
    var greenComponent: CGFloat { var v: CGFloat = 0; getRed(nil, green: &v, blue: nil, alpha: nil); return v }
    var blueComponent: CGFloat { var v: CGFloat = 0; getRed(nil, green: nil, blue: &v, alpha: nil); return v }
    var alphaComponent: CGFloat { var v: CGFloat = 0; getRed(nil, green: nil, blue: nil, alpha: &v); return v }
}

// NSFontManager.shared.availableFontFamilies → UIFont.familyNames
final class NSFontManager {
    static let shared = NSFontManager()
    var availableFontFamilies: [String] { UIFont.familyNames }
}
#endif
