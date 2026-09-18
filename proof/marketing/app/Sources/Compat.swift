// Compat.swift — cross-platform shims so the shared SwiftUI code compiles on BOTH macOS and iOS.
//
// Strategy: on iOS (UIKit), provide thin stand-ins for the few AppKit types/classes the app uses,
// so existing call sites compile UNCHANGED. macOS keeps using the real AppKit types.
//
// iOS-deferred behaviors are marked TODO(iOS) and behave sensibly (no crashes) for v1.
// Adapted from the BlackLabelRealEstate reference port, extended for the AppKit APIs THIS app
// uses: WKWebView NSViewRepresentable, NSImage init/load forms + cgImage accessor,
// NSGraphicsContext text drawing (ReelEngine), NSColor srgb init + .gray, NSFont.Weight.

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
    @ViewBuilder
    func onChangeCompat<Value: Equatable>(of value: Value, perform action: @escaping (Value) -> Void) -> some View {
        if #available(iOS 17.0, macOS 14.0, *) {
            self.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}
#endif // circuit-convert

/// Platform nouns for user-facing copy. Shared screens must never tell an iPhone user about
/// "this Mac", macOS version requirements, or System Settings — copy states facts about the
/// device it actually renders on (§5.1).
enum PlatformWords {
    #if os(iOS)
    /// "iPhone" or "iPad", live from the running device.
    static var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    static let osName = "iOS"
    static let settingsApp = "Settings"
    #else
    static let device = "Mac"
    static let osName = "macOS"
    static let settingsApp = "System Settings"
    #endif
}

#if canImport(UIKit)
import UIKit
import CoreGraphics

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

// MARK: file save — maps NSSavePanel usage. EXPORT on iOS: the caller writes the file to `url`
// synchronously right after `runModal() == .OK` (every call site does), so we point `url` at a temp
// file and schedule a UIActivityViewController (share sheet) on the NEXT main-queue tick — by then
// the synchronous write has already produced the file. This turns the macOS "Save panel → write"
// idiom into the iOS-native "write → Share sheet" with zero call-site changes. The user can then
// AirDrop / save to Files / mail the export. (Phase-2 iOS export, real — not a dead button.)
final class NSSavePanel {
    enum ModalResponse: Equatable { case OK, cancel }
    var nameFieldStringValue: String = ""
    var allowedContentTypes: [UTType] = []
    var canCreateDirectories: Bool = false
    var url: URL?
    var title: String = ""
    @MainActor @discardableResult
    func runModal() -> ModalResponse {
        let name = nameFieldStringValue.isEmpty ? "export" : nameFieldStringValue
        // A unique temp subdir so the share sheet shows the intended filename (not a collision suffix).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blm-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(name)
        url = fileURL
        // Present the share sheet after the caller's synchronous write completes.
        DispatchQueue.main.async {
            if FileManager.default.fileExists(atPath: fileURL.path) { iosShareFile(fileURL) }
        }
        return .OK
    }
}

// MARK: error alert — maps NSAlert (messageText/informativeText + runModal), used by export error
// paths. iOS has no synchronous modal, so this presents a native UIAlertController above whatever
// is frontmost and returns immediately (every call site ignores the response — informational only).
final class NSAlert {
    var messageText: String = ""
    var informativeText: String = ""
    @MainActor @discardableResult
    func runModal() -> NSSavePanel.ModalResponse {
        let alert = UIAlertController(title: messageText, message: informativeText, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        iosTopViewController()?.present(alert, animated: true)
        return .OK
    }
}

// MARK: file open — maps NSOpenPanel. IMPORT on iOS is inherently async (UIDocumentPickerViewController
// has no synchronous "runModal" equivalent), so the synchronous NSOpenPanel.runModal() contract can't
// be honored on a phone. The single iOS import call site (Settings ▸ logo) uses a SwiftUI `.fileImporter`
// behind `#if os(iOS)` instead (see SettingsScreen). This shim therefore returns `.cancel` and is NOT
// wired to any live iOS button — no dead buttons ship. `iosImportFile` below is the async path used.
final class NSOpenPanel {
    var allowsMultipleSelection = false
    var allowedContentTypes: [UTType] = []
    var canChooseDirectories = false
    var canChooseFiles = true
    var urls: [URL] = []
    var url: URL?
    @MainActor @discardableResult
    func runModal() -> NSSavePanel.ModalResponse { .cancel }
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

// Walk to the top-most presented view controller so we present ABOVE any open SwiftUI sheet
// (exports are frequently triggered from inside a presented editor sheet).
@MainActor
private func iosTopViewController() -> UIViewController? {
    var top = NSApplication.shared.keyWindow?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
}

// Present a share sheet for a file (iOS export). Anchors the popover (iPad) to the presenter.
@MainActor
func iosShareFile(_ url: URL) {
    guard let host = iosTopViewController() else { return }
    let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
    if let pop = av.popoverPresentationController {       // iPad: anchor to avoid a crash
        pop.sourceView = host.view
        pop.sourceRect = CGRect(x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
        pop.permittedArrowDirections = []
    }
    host.present(av, animated: true)
}

// Image(nsImage:) → uiImage on iOS
extension Image { init(nsImage: UIImage) { self.init(uiImage: nsImage) } }

// .toggleStyle(.checkbox) is macOS-only → fall back to a switch on iOS
extension ToggleStyle where Self == SwitchToggleStyle {
    static var checkbox: SwitchToggleStyle { SwitchToggleStyle() }
}

// .datePickerStyle(.field) is macOS-only → fall back to the compact field-like style on iOS.
extension DatePickerStyle where Self == CompactDatePickerStyle {
    static var field: CompactDatePickerStyle { CompactDatePickerStyle() }
}

// MARK: NSColor(=UIColor) — color-space + component accessors used by the FX/theme layer,
// plus the AppKit-only inits/statics this app calls.
enum NSColorSpace { case sRGB, deviceRGB, genericRGB }
extension UIColor {
    func usingColorSpace(_ : NSColorSpace) -> UIColor? { self }
    var redComponent: CGFloat { var v: CGFloat = 0; getRed(&v, green: nil, blue: nil, alpha: nil); return v }
    var greenComponent: CGFloat { var v: CGFloat = 0; getRed(nil, green: &v, blue: nil, alpha: nil); return v }
    var blueComponent: CGFloat { var v: CGFloat = 0; getRed(nil, green: nil, blue: &v, alpha: nil); return v }
    var alphaComponent: CGFloat { var v: CGFloat = 0; getRed(nil, green: nil, blue: nil, alpha: &v); return v }

    // NSColor(srgbRed:green:blue:alpha:) → UIColor(red:green:blue:alpha:) (sRGB on iOS by default).
    convenience init(srgbRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) {
        self.init(red: r, green: g, blue: b, alpha: a)
    }
    // (NSColor.gray maps directly to UIColor.gray — no shim needed.)
}

// MARK: NSFontManager.shared.availableFontFamilies → UIFont.familyNames
final class NSFontManager {
    static let shared = NSFontManager()
    var availableFontFamilies: [String] { UIFont.familyNames }
}

// MARK: .onExitCommand (Esc handler) is macOS-only → inert no-op on iOS so call sites compile.
// On iOS, sheets dismiss via the interactive drag / explicit close buttons. TODO(iOS): ensure
// every sheet has an on-screen close affordance (Phase-2 UI pass).
extension View {
    func onExitCommand(perform action: @escaping () -> Void) -> some View { self }
}

// MARK: HSplitView is macOS-only. On a wide canvas (Mac / iPad regular) it lays the two editor panes
// side-by-side; on an iPhone (compact width) that would crush both panes into unreadable slivers, so
// we STACK them vertically (editor on top, preview below) inside a ScrollView — the Phase-2 phone fix
// for the side-by-side editor/preview overflow. iPad regular keeps the side-by-side layout.
struct HSplitView<Content: View>: View {
    @ViewBuilder var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    var body: some View {
        if hSize == .compact {
            // Phone: stack the panes vertically. Each pane keeps its own ScrollView, so we do NOT
            // add an outer ScrollView (that would nest two vertical scrollers). The editor pane
            // (first) takes the available space; the preview pane (second) sizes naturally below.
            VStack(spacing: 0) { content }
        } else {
            HStack(spacing: 0) { content }                  // iPad regular: side-by-side
        }
    }
    #else
    var body: some View { HStack(spacing: 0) { content } }
    #endif
}

// MARK: NSImage(=UIImage) load/init forms the app uses on macOS.
// UIImage already has (contentsOfFile:), (named:), (data:) — add the AppKit-only ones.
extension UIImage {
    // NSImage(cgImage:size:) → UIImage(cgImage:) (size is metadata-only here; the SwiftUI views
    // .resizable()/.scaledToFit() and drive frame, so dropping the explicit size is fine for v1).
    convenience init(cgImage: CGImage, size _: CGSize) {
        self.init(cgImage: cgImage)
    }
    // NSImage.cgImage(forProposedRect:context:hints:) → UIImage.cgImage (the underlying CGImage).
    func cgImage(forProposedRect _: UnsafeMutablePointer<CGRect>?, context _: Any?, hints _: [AnyHashable: Any]?) -> CGImage? {
        self.cgImage
    }
}

// MARK: NSGraphicsContext — used by ReelEngine to draw NSAttributedString text into a CGContext.
// On iOS, UIKit text drawing reads UIGraphicsGetCurrentContext(), set via push/pop. We provide a
// minimal shim so `NSGraphicsContext.current = NSGraphicsContext(cgContext:flipped:)` (and the
// later restore) maps onto UIGraphicsPushContext/PopContext.
final class NSGraphicsContext {
    let cgContext: CGContext
    init(cgContext: CGContext, flipped _: Bool) { self.cgContext = cgContext }
    private init?(existing: CGContext?) {
        guard let c = existing else { return nil }
        self.cgContext = c
    }
    // Tracks the contexts WE pushed so a restore (assigning the previously-captured value, which
    // may be nil if nothing was current before) maps to UIGraphicsPopContext rather than another
    // push. This makes the AppKit "save current, set new, restore" idiom work via push/pop.
    private static var pushed: [CGContext] = []
    static var current: NSGraphicsContext? {
        get { NSGraphicsContext(existing: UIGraphicsGetCurrentContext()) }
        set {
            if let ctx = newValue?.cgContext, ctx !== UIGraphicsGetCurrentContext() {
                // Assigning a NEW context that isn't already live → push it.
                UIGraphicsPushContext(ctx)
                pushed.append(ctx)
            } else if !pushed.isEmpty {
                // Assigning the prior value (nil or the already-live context) → restore: pop ours.
                UIGraphicsPopContext()
                pushed.removeLast()
            }
        }
    }
}
#endif
