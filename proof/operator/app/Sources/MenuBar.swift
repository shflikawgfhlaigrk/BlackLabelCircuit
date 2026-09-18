#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — menu-bar presence + a global quick-ask hotkey (summon from anywhere).
//
// Two tier-3 "companion" features:
//   1. A menu-bar status item — Sovereign lives in the menu bar; click it to show the window,
//      jump to a screen, or open quick-ask.
//   2. A global hotkey (⌥Space by default) that summons a floating quick-ask panel from ANY app.
//      Type a question, press Return, and it routes into The Brain — no window switching.
//
// Both are real, reachable, and honest: the panel just hands the prompt to the main window's
// brain; it never answers on its own or fabricates anything. Carbon's RegisterEventHotKey is
// the only dependency-free way to get a true system-wide hotkey on macOS.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// Notification posted when the global hotkey (or menu) requests quick-ask.
/// Defined OUTSIDE the macOS guard because ChatScreen (compiled on iOS too) listens for
/// .sovQuickAskSubmit. On iOS nothing posts it (no menu bar / hotkey), so the listener is simply idle.
extension Notification.Name {
    static let sovQuickAsk = Notification.Name("sov.quickAsk")            // show the floating panel
    static let sovQuickAskSubmit = Notification.Name("sov.quickAskSubmit") // object: String prompt
}

// The companion surface below (menu-bar status item, Carbon global hotkey, floating NSPanel)
// is macOS-only. iOS has no menu bar / system-wide hotkey / NSPanel; AppDelegate (its only caller)
// is itself #if os(macOS), so this whole block compiles out cleanly on iOS.
#if os(macOS)
import AppKit
import Carbon.HIToolbox

@MainActor
final class MenuBarCompanion: NSObject {
    private var statusItem: NSStatusItem?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var quickAsk: QuickAskPanel?

    /// The bring-window-forward action, injected by the AppDelegate.
    var showMainWindow: (() -> Void)?

    func install() {
        installStatusItem()
        syncHotkeyRegistration()
        // Live-sync with the Settings toggle: registration follows the defaults key without a relaunch.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.syncHotkeyRegistration() }
        }
    }

    /// Defaults key for the global ⌥Space hotkey (default ON). Buyers can turn it off in Settings —
    /// Option-Space is a real keystroke on some layouts (non-breaking space) and other launchers use it.
    static let hotkeyDefaultsKey = "com.blacklabel.sovereign.quickask.hotkey.enabled"
    private var hotkeyEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.hotkeyDefaultsKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.hotkeyDefaultsKey)
    }

    /// Register or unregister to match the setting; safe to call repeatedly.
    private func syncHotkeyRegistration() {
        if hotkeyEnabled {
            if hotKeyRef == nil { installGlobalHotKey() }
        } else if let h = hotKeyRef {
            UnregisterEventHotKey(h)
            hotKeyRef = nil
        }
    }

    // MARK: Menu-bar status item
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Sovereign")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Quick Ask  (⌥Space)", action: #selector(triggerQuickAsk), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        for (title, route) in [("Open Sovereign", AppRoute.dashboard), ("The Brain", .brain), ("Agent", .agent), ("Settings", .settings)] {
            let mi = NSMenuItem(title: title, action: #selector(openRoute(_:)), keyEquivalent: "")
            mi.representedObject = route; mi.target = self; menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sovereign", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openRoute(_ sender: NSMenuItem) {
        showMainWindow?()
        if let r = sender.representedObject as? AppRoute {
            NotificationCenter.default.post(name: .sovRoute, object: r)
        }
    }

    // MARK: Global hotkey (⌥Space) — works system-wide
    private func installGlobalHotKey() {
        if eventHandler == nil {   // handler survives toggle cycles; install it exactly once
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
                guard let userData = userData else { return noErr }
                let me = Unmanaged<MenuBarCompanion>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in me.triggerQuickAsk() }
                _ = event
                return noErr
            }, 1, &spec, selfPtr, &eventHandler)
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x534F5651), id: 1)  // 'SOVQ'
        // ⌥Space: keycode 49 (space) + optionKey modifier.
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hotKeyID,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    @objc func triggerQuickAsk() {
        if quickAsk == nil { quickAsk = QuickAskPanel(showMainWindow: { [weak self] in self?.showMainWindow?() }) }
        quickAsk?.present()
    }

    deinit {
        if let h = hotKeyRef { UnregisterEventHotKey(h) }
        if let e = eventHandler { RemoveEventHandler(e) }
    }
}

// MARK: - The floating quick-ask panel (spotlight-style)

/// A small borderless panel that floats above everything. The buyer types a question and it's
/// routed into The Brain in the main window. Honest: it does not answer here — it hands the
/// prompt to the real brain so the answer appears in the conversation, never invented inline.
@MainActor
final class QuickAskPanel {
    private var panel: NSPanel?
    private let showMainWindow: () -> Void

    init(showMainWindow: @escaping () -> Void) { self.showMainWindow = showMainWindow }

    /// Resolve the buyer's persisted HoloTheme for the floating panel (hosted outside RootView).
    static func currentTheme() -> HoloTheme {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return AppSettings().holoTheme(motionAllowed: !reduce)
    }

    func present() {
        // Ordering the panel out never unmounts its SwiftUI view, so a reused view keeps the last
        // query in the field and a spent onAppear focus kick. Rebuild the hosting view for every
        // fresh summon (panel hidden) so the field is EMPTY and focused; re-summoning while it is
        // already on screen only re-fronts it, preserving in-progress typing.
        if panel == nil || !(panel?.isVisible ?? false) { build() }
        guard let panel = panel else { return }
        // Center near the top of the active screen, like Spotlight.
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let w: CGFloat = 620, h: CGFloat = 76
            panel.setFrame(NSRect(x: f.midX - w/2, y: f.midY + f.height*0.18, width: w, height: h), display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() { panel?.orderOut(nil) }

    /// Creates the panel on first use, and (re)mounts a FRESH QuickAskView into it on every call —
    /// fresh @State (empty query) + a fresh onAppear (the focus kick), and the buyer's CURRENT
    /// persisted theme rather than the one captured at first summon.
    private func build() {
        let p: NSPanel
        if let existing = panel {
            p = existing
            p.contentView?.subviews.forEach { $0.removeFromSuperview() }
        } else {
            p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 76),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .floating
            p.hidesOnDeactivate = true
            p.isMovableByWindowBackground = true
            p.backgroundColor = .clear
            p.hasShadow = true
            panel = p
        }
        // The panel is hosted outside RootView's environment, so inject a live theme so the holo
        // treatment (iridescent rim, sheen) matches the app. Reads the buyer's persisted theme.
        let liveTheme = QuickAskPanel.currentTheme()
        let host = NSHostingView(rootView: QuickAskView(
            onSubmit: { [weak self] text in
                self?.dismiss()
                self?.showMainWindow()
                // Route into The Brain and pre-fill the composer; the real brain answers there.
                NotificationCenter.default.post(name: .sovRoute, object: AppRoute.brain)
                NotificationCenter.default.post(name: .sovQuickAskSubmit, object: text)
            },
            onCancel: { [weak self] in self?.dismiss() }
        ).holoTheme(liveTheme))
        host.frame = p.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        p.contentView?.addSubview(host)
    }
}

private struct QuickAskView: View {
    @Environment(\.holoTheme) private var theme
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles").font(.system(size: 18, weight: .bold)).foregroundColor(theme.accent)
            TextField("Ask Sovereign…", text: $text)
                .textFieldStyle(.plain).font(.system(size: 18, design: .rounded)).foregroundColor(BLTheme.text)
                .focused($focused)
                .onSubmit { let t = text.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { onSubmit(t) } }
            Text("⏎").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(BLTheme.sub)
                .padding(.vertical, 3).padding(.horizontal, 7).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.horizontal, 22).frame(height: 76)
        .background(BLTheme.glassStrong).background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(HoloSheen(cornerRadius: 18))                                   // iridescent sweep
        .overlay(IridescentBorder(cornerRadius: 18, lineWidth: 1.1))           // animated rim
        .shadow(color: theme.accent.opacity(0.22 * theme.glow), radius: 26)
        .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        .onExitCommand { onCancel() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true } }
    }
}

#endif  // os(macOS)
#endif // circuit-convert
