#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

@MainActor
final class FloatingInboxPanel: NSPanel {
    let slot: Int
    private let defaults: UserDefaults
    private var collapsedOrigin: NSPoint
    private var dragOrigin: NSPoint?
    private var expanded = false
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(email: FloatingEmail, slot: Int, controller: FloatingInboxController, defaults: UserDefaults) {
        self.slot = slot
        self.defaults = defaults
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        if let saved = defaults.array(forKey: "ace.floatingInbox.position.\(slot)") as? [Double],
           saved.count == 2, saved.allSatisfy(\.isFinite) {
            collapsedOrigin = NSPoint(x: saved[0], y: saved[1])
        } else {
            collapsedOrigin = NSPoint(x: visible.maxX - 102, y: visible.maxY - 108 - CGFloat(slot) * 90)
        }
        super.init(contentRect: NSRect(origin: collapsedOrigin, size: NSSize(width: 88, height: 88)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Ace email bubble"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = .none
        animationBehavior = .none
        contentView = AceHostingView(rootView: FloatingEmailBubbleView(
            email: email, controller: controller,
            expand: { [weak self] value in self?.setExpanded(value) },
            drag: { [weak self] translation, finished in self?.drag(translation, finished: finished) }
        ))
        clampToScreen()
    }

    private func setExpanded(_ value: Bool) {
        guard !StealthVisibilityGate.shared.isActive, !StealthEntryLatch.shared.isRaised else { return }
        expanded = value
        let size = value ? NSSize(width: 380, height: 360) : NSSize(width: 88, height: 88)
        let origin = NSPoint(x: collapsedOrigin.x + 88 - size.width, y: collapsedOrigin.y + 88 - size.height)
        setFrame(NSRect(origin: origin, size: size), display: true,
                 animate: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        clampToScreen()
    }

    private func drag(_ translation: CGSize, finished: Bool) {
        if dragOrigin == nil { dragOrigin = frame.origin }
        guard let origin = dragOrigin else { return }
        setFrameOrigin(NSPoint(x: origin.x + translation.width, y: origin.y - translation.height))
        clampToScreen()
        if finished {
            dragOrigin = nil
        }
    }

    func clampToScreen() {
        let pinned = FloatingInboxLayout.edgePinnedFrame(frame, visibleFrames: NSScreen.screens.map(\.visibleFrame))
        setFrameOrigin(pinned.origin)
        collapsedOrigin = NSPoint(x: frame.maxX - 88, y: frame.maxY - 88)
        let saved = [Double(collapsedOrigin.x), Double(collapsedOrigin.y)]
        let key = "ace.floatingInbox.position.\(slot)"
        if defaults.array(forKey: key) as? [Double] != saved { defaults.set(saved, forKey: key) }
    }
}

/// A slightly asymmetric droplet reads as liquid, with a flatter contact edge
/// and a curved meniscus instead of a uniformly round notification badge.
struct EmailDropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        path.move(to: point(0.48, 0.025))
        path.addCurve(to: point(0.97, 0.49), control1: point(0.76, 0.00), control2: point(0.96, 0.19))
        path.addCurve(to: point(0.53, 0.975), control1: point(1.00, 0.79), control2: point(0.82, 0.98))
        path.addCurve(to: point(0.025, 0.53), control1: point(0.22, 1.00), control2: point(0.015, 0.85))
        path.addCurve(to: point(0.48, 0.025), control1: point(0.00, 0.23), control2: point(0.18, 0.06))
        path.closeSubpath()
        return path
    }
}

struct EmailWaterDroplet: View {
    let initials: String
    let hovered: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                EmailDropletShape().fill(Color(red: 0.12, green: 0.22, blue: 0.29))
            } else {
                EmailDropletShape().fill(.ultraThinMaterial)
                EmailDropletShape().fill(LinearGradient(colors: [
                    .white.opacity(0.34), .cyan.opacity(0.10), .clear, .blue.opacity(0.22)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                Ellipse().fill(.cyan.opacity(0.20)).frame(width: 38, height: 15).blur(radius: 9).offset(x: 13, y: 20)
            }
            EmailDropletShape().stroke(LinearGradient(colors: [
                .white.opacity(0.95), .white.opacity(0.08), .cyan.opacity(0.55), .white.opacity(0.72)
            ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
            EmailDropletShape().stroke(.white.opacity(0.16), lineWidth: 1).padding(3)
            Ellipse().fill(LinearGradient(colors: [.white.opacity(0.78), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .frame(width: 35, height: 12).rotationEffect(.degrees(-28)).offset(x: -9, y: -23).blur(radius: 0.6)
            Capsule().fill(.white.opacity(0.65)).frame(width: 21, height: 2).rotationEffect(.degrees(-24)).offset(x: 11, y: 28).blur(radius: 1)
            Text(initials).font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(.white).shadow(color: .black.opacity(0.75), radius: 3, y: 1)
            Circle().fill(Color(red: 0.65, green: 0.94, blue: 1)).frame(width: 9, height: 9)
                .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
                .offset(x: 25, y: -26)
        }
        .frame(width: 72, height: 72)
        .scaleEffect(hovered ? 1.035 : 1)
        .shadow(color: .black.opacity(0.28), radius: 6, y: 5)
        .shadow(color: .cyan.opacity(hovered ? 0.22 : 0.07), radius: 6)
    }
}

struct FloatingEmailBubbleView: View {
    let email: FloatingEmail
    @ObservedObject var controller: FloatingInboxController
    let expand: (Bool) -> Void
    let drag: (CGSize, Bool) -> Void
    @State private var expanded = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Group {
            if expanded { card.padding(10) }
            else {
                AceTrackedButton { toggle() } label: { EmailWaterDroplet(initials: email.initials, hovered: hovered) }
                    .buttonStyle(.plain)
                    .onHover { hovered = $0 }
                    .pointerCursor()
                    .help("\(email.sender) — \(email.subject)")
                    .accessibilityLabel("Unread email from \(email.sender): \(email.subject)")
                    .accessibilityIdentifier("ace.inbox.bubble.\(email.uid)")
                    .simultaneousGesture(dragGesture)
                    .contextMenu {
                        AceTrackedButton("Email settings…") { controller.showSettings() }
                        AceTrackedButton("Turn off email droplets") { controller.setEnabled(false) }
                        Divider()
                        AceTrackedButton("Dismiss bubble") { controller.dismiss(email) }
                    }
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: hovered)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: "drop.fill").foregroundStyle(.cyan)
                Text("ACE · INBOX").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(2)
                Spacer()
                action("Email settings", icon: "gearshape") { controller.showSettings() }
                action("Collapse", icon: "arrow.down.right.and.arrow.up.left") { toggle() }
                action("Dismiss", icon: "xmark") { controller.dismiss(email) }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(dragGesture)
            Text(email.sender).font(.system(size: 12, weight: .semibold)).lineLimit(2).textSelection(.enabled)
            Text(email.subject).font(.system(size: 18, weight: .semibold, design: .rounded)).lineLimit(2).textSelection(.enabled)
            ScrollView {
                Text(email.preview).font(.system(size: 13)).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }.frame(maxHeight: .infinity)
            if !email.date.isEmpty {
                Text(email.date).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 7) {
                AceTrackedButton(email.isAppleMail ? "Open in Mail" : "Open in Gmail") { controller.open(email) }
                if !email.isAppleMail {
                    AceTrackedButton("Mark read") { controller.markRead(email) }.disabled(controller.isRefreshing)
                }
                AceTrackedButton(email.isAppleMail ? "Open Mail to reply" : "Open Gmail to reply") { controller.open(email, reply: true) }
            }
            .buttonStyle(.bordered).controlSize(.small).font(.system(size: 10)).pointerCursor()
            AceTrackedButton("Turn off email droplets") { controller.setEnabled(false) }
                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(.secondary).pointerCursor()
                .accessibilityIdentifier("ace.inbox.turn-off")
            if let message = controller.actionMessage, controller.actionEmailID == email.id {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                    .accessibilityIdentifier("ace.inbox.action-status")
            }
        }
        .padding(18)
        .foregroundStyle(.primary)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: 27, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: 27, style: .continuous).fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 27, style: .continuous).fill(LinearGradient(
                    colors: [.white.opacity(0.14), .cyan.opacity(0.05), .clear], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(LinearGradient(
            colors: [.white.opacity(0.72), .white.opacity(0.08), .cyan.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
        .accessibilityIdentifier("ace.inbox.preview")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5).onChanged { drag($0.translation, false) }.onEnded { drag($0.translation, true) }
    }

    private func toggle() {
        expanded.toggle()
        expand(expanded)
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        AceTrackedButton(action: perform) { Image(systemName: icon).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22) }
            .buttonStyle(.plain).help(title).accessibilityLabel(title).pointerCursor()
    }
}

struct FloatingInboxSettingsView: View {
    @ObservedObject var controller = FloatingInboxController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            AceTrackedToggle("Show email droplets", isOn: Binding(get: { controller.enabled }, set: { controller.setEnabled($0) }))
                .toggleStyle(.switch).controlSize(.small).pointerCursor()
                .accessibilityIdentifier("ace.inbox.enabled")
            Text(controller.status).font(.system(size: 10)).foregroundStyle(.secondary)
                .accessibilityIdentifier("ace.inbox.status")
            Picker("Email source", selection: Binding(get: { controller.source }, set: { controller.setSource($0) })) {
                ForEach(FloatingInboxSource.allCases) { source in Text(source.label).tag(source) }
            }
            .accessibilityIdentifier("ace.inbox.source")
            Text("Automatic uses your connected Gmail, or Apple Mail when Gmail is not connected. Turning droplets off keeps your accounts connected.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if controller.enabled {
                Text("Email droplets stay at the right edge of your screen. Drag up or down; click to preview. Updates every minute.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                AceTrackedButton("Refresh inbox") { controller.refresh() }
                    .buttonStyle(.bordered).controlSize(.small).disabled(controller.isRefreshing).pointerCursor()
                    .accessibilityIdentifier("ace.inbox.refresh")
            }
        }
    }
}
#endif // circuit-convert
