#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
import Foundation
import CircuitPortKit
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif

@MainActor
final class FloatingInboxController: ObservableObject {
    static let shared = FloatingInboxController()
    @Published private(set) var enabled: Bool
    @Published private(set) var source: FloatingInboxSource
    @Published var settingsPresented = false
    @Published private(set) var status = "Floating inbox is off."
    @Published private(set) var isRefreshing = false
    @Published private(set) var unreadCount = 0
    @Published private(set) var actionMessage: String?
    @Published private(set) var actionEmailID: String?
    private var state = FloatingInboxState()
    private let store = GmailAccountStore()
    private var panels: [String: FloatingInboxPanel] = [:]
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var cancellation: FloatingInboxCancellation?
    private var privacyCutoff: UUID?
    private var generation: UInt64 = 0
    private var screenLocked = false
    private var sleeping = false
    private var started = false
    private let defaults: UserDefaults
    static let preferenceKey = "ace.floatingInbox.enabled"
    static let sourcePreferenceKey = "ace.floatingInbox.source"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.preferenceKey)
        source = FloatingInboxSource(rawValue: defaults.string(forKey: Self.sourcePreferenceKey) ?? "") ?? .automatic
    }

    func start() {
        guard !started else { return }
        started = true
        observe(.default, "AcePrivacyWallRaised") { $0.settingsPresented = false; $0.suspend(status: "Paused in Private Mode.") }
        observe(.default, "AcePrivacyWallLowered") { $0.refresh() }
        observe(.default, "AceGmailAccountChanged") { controller in
            controller.suspend(status: "Email account changed.")
            controller.refresh()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification.rawValue) {
            $0.sleeping = true; $0.suspend(status: "Paused while this Mac sleeps.")
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification.rawValue) {
            $0.sleeping = false; $0.refresh()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification.rawValue) {
            $0.screenLocked = true; $0.suspend(status: "Paused while this session is locked.")
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification.rawValue) {
            $0.screenLocked = false; $0.refresh()
        }
        observe(DistributedNotificationCenter.default(), "com.apple.screenIsLocked") {
            $0.screenLocked = true; $0.suspend(status: "Paused while this Mac is locked.")
        }
        observe(DistributedNotificationCenter.default(), "com.apple.screenIsUnlocked") {
            $0.screenLocked = false; $0.refresh()
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification.rawValue) { controller in
            controller.panels.values.forEach { $0.clampToScreen() }
        }
        if enabled { schedule(); refresh() }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: Self.preferenceKey)
        if value { start(); schedule(); refresh() }
        else { timer?.invalidate(); timer = nil; suspend(status: "Floating inbox is off.") }
    }

    func showSettings() {
        guard !StealthVisibilityGate.shared.isActive, !StealthEntryLatch.shared.isRaised,
              AceLicense.shared.admits(.premiumRuntimeStartup) else { return }
        settingsPresented = true
        NotificationCenter.default.post(name: Notification.Name("AceShowEmailSettings"), object: nil)
    }

    func setSource(_ value: FloatingInboxSource) {
        guard source != value else { return }
        suspend(status: "Email source changed.")
        source = value
        defaults.set(value.rawValue, forKey: Self.sourcePreferenceKey)
        refresh()
    }

    private var usesAppleMail: Bool {
        source == .appleMail || (source == .automatic && store.storedAddress() == nil)
    }

    private var admitted: Bool {
        enabled && !screenLocked && !sleeping && !StealthVisibilityGate.shared.isActive && !StealthEntryLatch.shared.isRaised
            && AceLicense.shared.admits(.premiumRuntimeStartup)
    }

    func refresh() {
        guard enabled else { return }
        guard admitted else { suspend(status: "Floating inbox is paused."); return }
        guard !isRefreshing else { return }
        if usesAppleMail { refreshAppleMail(); return }
        guard let address = store.storedAddress() else {
            suspend(status: "Connect a Gmail account in Email settings."); return
        }
        isRefreshing = true
        status = "Checking unread email…"
        let token = beginOperation()
        let currentGeneration = generation
        Task { [weak self] in
            guard let self else { return }
            let credential: GmailAccountCredential
            do {
                guard let connected = try await self.store.loadUsableCredential(), connected.address == address else {
                    throw GmailOAuthError.accountChanged
                }
                try token.check()
                credential = connected
            } catch {
                guard self.generation == currentGeneration else { return }
                self.suspend(status: "Reconnect Gmail in Email settings to refresh your droplets.")
                return
            }
            let result = await Task.detached(priority: .utility) { () -> Result<FloatingInboxSnapshot, Error> in
                defer { token.cancel() }
                return Result {
                    let session = try FloatingInboxGmail.connect(address: address, password: credential.transportSecret, usesOAuth: credential.oauth != nil, cancellation: token)
                    return try FloatingInboxGmail.snapshot(session: session, account: address)
                }
            }.value
            guard self.generation == currentGeneration else { return }
            self.isRefreshing = false
            self.finishOperation()
            guard self.admitted, !self.usesAppleMail, self.store.storedAddress() == address else {
                self.suspend(status: "Floating inbox is paused."); return
            }
            switch result {
            case .success(let snapshot):
                self.state.apply(snapshot)
                self.unreadCount = snapshot.unreadCount
                self.status = snapshot.unreadCount == 0 ? "No unread email." : "\(snapshot.unreadCount) unread · showing up to 5 bubbles"
                self.render()
            case .failure:
                self.state.clear(); self.unreadCount = 0; self.hidePanels()
                self.status = "Email refresh failed. Check your connection or reconnect Gmail."
            }
        }
    }

    func dismiss(_ email: FloatingEmail) {
        state.dismiss(email.id)
        panels.removeValue(forKey: email.id)?.close()
    }

    private func refreshAppleMail() {
        isRefreshing = true
        status = "Checking unread Apple Mail…"
        let token = beginOperation(), currentGeneration = generation
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> Result<FloatingInboxSnapshot, Error> in
                defer { token.cancel() }
                return Result { try FloatingInboxAppleMail.snapshot(cancellation: token) }
            }.value
            guard let self, self.generation == currentGeneration else { return }
            self.isRefreshing = false; self.finishOperation()
            guard self.admitted, self.usesAppleMail else {
                self.suspend(status: "Floating inbox is paused."); return
            }
            switch result {
            case .success(let snapshot):
                self.state.apply(snapshot)
                self.unreadCount = snapshot.unreadCount
                self.status = snapshot.unreadCount == 0 ? "No unread email in Apple Mail." : "Apple Mail · \(snapshot.unreadCount) unread · showing up to 5 droplets"
                self.render()
            case .failure(let error):
                self.state.clear(); self.unreadCount = 0; self.hidePanels()
                self.status = (error as? LocalizedError)?.errorDescription ?? "Apple Mail could not be refreshed. Check Local Mail Access in Setup."
            }
        }
    }

    func open(_ email: FloatingEmail, reply: Bool = false) {
        guard admitted,
              state.messages.contains(where: { $0.id == email.id }) else { return }
        actionEmailID = email.id
        if email.isAppleMail {
            guard usesAppleMail else { return }
            let target = email.appleMailURL ?? URL(fileURLWithPath: "/System/Applications/Mail.app")
            if NSWorkspace.shared.open(target) {
                actionMessage = email.appleMailURL == nil
                    ? "Apple Mail is opening. Search for this subject; this message has no direct link."
                    : reply ? "Opening this message in Apple Mail. Choose Reply there." : "Opening this message in Apple Mail."
            } else { actionMessage = "Apple Mail did not open. Try again from this droplet." }
            return
        }
        guard store.storedAddress() == email.account else { return }
        if NSWorkspace.shared.open(email.gmailURL) {
            actionMessage = reply ? "Opening the message in Gmail. Choose Reply there to draft your response." : "Opening this message in Gmail."
        } else { actionMessage = "Gmail did not open. Try again from this bubble." }
    }

    func markRead(_ email: FloatingEmail) {
        guard admitted, !email.isAppleMail, !isRefreshing, state.messages.contains(where: { $0.id == email.id }) else { return }
        actionEmailID = email.id
        guard store.storedAddress() == email.account else {
            actionMessage = "Reconnect this Gmail account before marking read."; return
        }
        isRefreshing = true
        actionMessage = "Marking read…"
        let token = beginOperation(), currentGeneration = generation
        let address = email.account
        Task { [weak self] in
            guard let self else { return }
            let credential: GmailAccountCredential
            do {
                guard let connected = try await self.store.loadUsableCredential(), connected.address == address else {
                    throw GmailOAuthError.accountChanged
                }
                try token.check()
                credential = connected
            } catch {
                guard self.generation == currentGeneration else { return }
                self.suspend(status: "Reconnect this Gmail account before marking read.")
                return
            }
            let result = await Task.detached(priority: .utility) { () -> Result<Void, Error> in
                defer { token.cancel() }
                return Result {
                    let session = try FloatingInboxGmail.connect(address: address, password: credential.transportSecret, usesOAuth: credential.oauth != nil, cancellation: token)
                    try FloatingInboxGmail.markRead(email, session: session)
                }
            }.value
            guard self.generation == currentGeneration else { return }
            self.isRefreshing = false; self.finishOperation()
            guard self.admitted, self.store.storedAddress() == email.account else {
                self.suspend(status: "Floating inbox is paused."); return
            }
            switch result {
            case .success:
                self.dismiss(email)
                self.actionMessage = "Marked read in Gmail."
                self.refresh()
            case .failure:
                self.actionMessage = "Read status is unconfirmed. Refresh before trying again."
                self.refresh()
            }
        }
    }

    func suspend(status: String) {
        generation &+= 1
        cancellation?.cancel(); finishOperation()
        isRefreshing = false
        state.clear(); unreadCount = 0; actionMessage = nil; actionEmailID = nil
        hidePanels()
        self.status = status
    }

    func stop() {
        timer?.invalidate(); timer = nil
        suspend(status: "Floating inbox stopped.")
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll(); started = false
    }

    private func beginOperation() -> FloatingInboxCancellation {
        cancellation?.cancel()
        finishOperation()
        generation &+= 1
        let token = FloatingInboxCancellation(); cancellation = token
        privacyCutoff = StealthEntryLatch.shared.registerSynchronousEntryCutoff { token.cancel() }
        return token
    }

    private func finishOperation() {
        cancellation = nil
        if let privacyCutoff { StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(privacyCutoff) }
        privacyCutoff = nil
    }

    private func schedule() {
        guard timer == nil else { return }
        let poll = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        poll.tolerance = 10
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
    }

    private func observe(_ center: NotificationCenter, _ name: String, action: @escaping (FloatingInboxController) -> Void) {
        let observer = center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        observers.append((center, observer))
    }

    private func render() {
        guard admitted else { return }
        let liveIDs = Set(state.messages.map(\.id))
        for id in Array(panels.keys) where !liveIDs.contains(id) { panels.removeValue(forKey: id)?.close() }
        for email in state.messages where panels[email.id] == nil {
            let occupied = Set(panels.values.map(\.slot))
            let slot = (0..<FloatingInboxState.maximumBubbles).first { !occupied.contains($0) } ?? 0
            let panel = FloatingInboxPanel(email: email, slot: slot, controller: self, defaults: defaults)
            panels[email.id] = panel
            panel.orderFrontRegardless()
        }
    }

    private func hidePanels() {
        panels.values.forEach { $0.close() }
        panels.removeAll()
    }
}
#endif // circuit-convert
