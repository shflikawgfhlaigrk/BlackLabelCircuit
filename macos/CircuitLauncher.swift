import AppKit
import Foundation

// Drag-to-grade drop well (CI-19). A folder dropped here — or on the app's Dock
// icon (routed via application(_:openFiles:)) — starts Circuit grading it, so a
// first-time user never has to hunt through a file picker.
final class DropView: NSView {
    var onDrop: ((URL) -> Void)?
    private var highlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folderURL(from: sender) != nil else { return [] }
        highlighted = true
        needsDisplay = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
        needsDisplay = true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        needsDisplay = true
        guard let url = folderURL(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    // Only accept a directory — Circuit grades a repository, not a single file.
    private func folderURL(from sender: NSDraggingInfo) -> URL? {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts) as? [URL] else { return nil }
        return urls.first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.05, alpha: 1).setFill()
        dirtyRect.fill()
        let inset = bounds.insetBy(dx: 22, dy: 22)
        let path = NSBezierPath(roundedRect: inset, xRadius: 16, yRadius: 16)
        path.lineWidth = 2
        path.setLineDash([8, 6], count: 2, phase: 0)
        let stroke = highlighted
            ? NSColor(calibratedRed: 0.49, green: 0.83, blue: 0.99, alpha: 1)
            : NSColor(white: 1, alpha: 0.2)
        stroke.setStroke()
        path.stroke()
    }
}

@main
final class CircuitApp: NSObject, NSApplicationDelegate {
    private static var appDelegate: CircuitApp?

    static func main() {
        let delegate = CircuitApp()
        appDelegate = delegate
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }

    private var server: Process?
    private var openedBrowser = false
    private var logHandle: FileHandle?
    private var outputBuffer = ""
    private var isQuitting = false

    // Onboarding / lifecycle state (CI-19).
    private var didFinishLaunching = false
    private var started = false
    private var pendingRepo: URL?
    private var currentRepo: URL?
    private var nodeURL: URL?
    private var serverURL: URL?
    private var dropWindow: NSWindow?

    private let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Circuit", isDirectory: true)
    }()

    private var recentsFile: URL {
        supportDirectory.appendingPathComponent("recent-repos.txt")
    }

    // A folder dropped on the Dock icon (or "Open With → Circuit") arrives here —
    // possibly BEFORE applicationDidFinishLaunching. Stash it if we're not ready,
    // otherwise start grading immediately, skipping the picker.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let dir = filenames.first { isDirectory($0) } ?? filenames.first
        guard let dir else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        if didFinishLaunching { beginGrading(url) } else { pendingRepo = url }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        installMainMenu()

        guard preflight() else { return }

        // Silent auto-update check (launch + daily throttle) — only surfaces UI when a
        // strictly-newer build is actually published. See macos/CircuitUpdater.swift.
        UpdaterUI.checkInBackgroundIfDue()

        // A folder was already dropped on the Dock icon at launch — grade it now.
        if let repo = pendingRepo {
            beginGrading(repo)
            return
        }
        // Otherwise present the drag-to-grade welcome window (drop a folder, or
        // fall back to the native picker button).
        showDropWindow()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isQuitting = true
        terminateServer()
        return .terminateNow
    }

    // The drop window is closable, so a Dock-icon click with no windows left must
    // bring it back — otherwise the app is running with no surface and no way in.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !started && !flag {
            if let dropWindow { dropWindow.makeKeyAndOrderFront(nil) } else { showDropWindow() }
        }
        return true
    }

    // The launcher builds its menu bar in code (there is no nib). The app menu carries
    // "Check for Updates…" — the on-demand trigger for the updater — the toggle for the
    // silent auto-check (air-gapped installs need real zero-egress), the license-key
    // entry (the only activation path — GUI launches never inherit shell env vars),
    // plus the standard Quit so Cmd-Q works.
    private func installMainMenu() {
        let appMenu = NSMenu()
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        appMenu.addItem(check)
        let auto = NSMenuItem(title: "Automatically Check for Updates", action: #selector(toggleAutoUpdateCheck(_:)), keyEquivalent: "")
        auto.target = self
        auto.state = Updater.autoCheckEnabled ? .on : .off
        appMenu.addItem(auto)
        appMenu.addItem(.separator())
        let license = NSMenuItem(title: "Enter License Key…", action: #selector(enterLicenseKey), keyEquivalent: "")
        license.target = self
        appMenu.addItem(license)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Circuit",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))

        let fileMenu = NSMenu(title: "File")
        let open = NSMenuItem(title: "Open Repository…", action: #selector(openRepository), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)

        // Standard first-responder Edit menu — without it Cmd-C/V/A are dead
        // everywhere, including paste into NSOpenPanel's Go-to-Folder sheet.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let mainMenu = NSMenu()
        for submenu in [appMenu, fileMenu, editMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        NSApp.mainMenu = mainMenu
    }

    // Menu target-actions always arrive on the main thread; declaring the isolation
    // lets this nonisolated delegate class call into the @MainActor UpdaterUI.
    @MainActor @objc private func checkForUpdates() {
        UpdaterUI.checkInteractively()
    }

    @MainActor @objc private func toggleAutoUpdateCheck(_ sender: NSMenuItem) {
        Updater.autoCheckEnabled.toggle()
        sender.state = Updater.autoCheckEnabled ? .on : .off
    }

    // Repo choice, any time: before grading it starts the first scan; after, it swaps
    // the running server onto the newly chosen repository (no quit-and-relaunch).
    @objc private func openRepository() {
        guard let repo = chooseRepository() else { return }
        if started { restartServer(grading: repo) } else { beginGrading(repo) }
    }

    // MARK: License activation
    // lib/license.js reads CIRCUIT_LICENSE from the server process environment.
    // The key is persisted here and injected in startServer; validation stays
    // server-side (fail-closed), so this UI claims storage, never validity.
    private static let licenseDefaultsKey = "circuit.licenseKey"

    private func storedLicenseKey() -> String? {
        let raw = (UserDefaults.standard.string(forKey: Self.licenseDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    @objc private func enterLicenseKey() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Enter your Circuit license key"
        alert.informativeText = "The key from your purchase. Circuit stores it on this Mac and passes it to the grading engine at startup. Leave the field empty to remove a saved key."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = storedLicenseKey() ?? ""
        field.placeholderString = "CIRC-XXXX-XXXX-XXXX"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.licenseDefaultsKey)
        } else {
            UserDefaults.standard.set(key, forKey: Self.licenseDefaultsKey)
        }
        // The env only reaches the node process at spawn — restart so the saved
        // key takes effect now instead of on the next launch.
        if started, let repo = currentRepo { restartServer(grading: repo) }
    }

    // Validate the runtime once, up front, so both the drop path and the picker
    // path share the same guarantees. Terminates (with an alert) on failure.
    private func preflight() -> Bool {
        if requiresAppleSiliconGate() {
            showAlert(
                title: "Circuit requires Apple Silicon",
                message: "This build bundles an arm64 Node runtime. Use Circuit on an Apple Silicon Mac."
            )
            NSApp.terminate(nil)
            return false
        }
        guard let resources = Bundle.main.resourceURL else {
            showAlert(title: "Circuit cannot start", message: "The app bundle resources are missing.")
            NSApp.terminate(nil)
            return false
        }
        let node = resources.appendingPathComponent("node/node")
        let srv = resources.appendingPathComponent("app/server.js")
        guard FileManager.default.isExecutableFile(atPath: node.path) else {
            showAlert(title: "Circuit cannot start", message: "The bundled Node runtime is missing.")
            NSApp.terminate(nil)
            return false
        }
        guard FileManager.default.fileExists(atPath: srv.path) else {
            showAlert(title: "Circuit cannot start", message: "The bundled Circuit server is missing.")
            NSApp.terminate(nil)
            return false
        }
        nodeURL = node
        serverURL = srv
        return true
    }

    // Start grading a chosen repository. Idempotent — the first folder wins for
    // this launch (a second drop is ignored rather than spawning a rival server);
    // switching later goes through restartServer via File → Open Repository….
    private func beginGrading(_ repoURL: URL) {
        guard !started, let nodeURL, let serverURL else { return }
        started = true
        currentRepo = repoURL
        dropWindow?.orderOut(nil)
        remember(repoURL)
        startServer(nodeURL: nodeURL, serverURL: serverURL, repoURL: repoURL)
    }

    // Replace the running server with one grading `repoURL` (repo switch, or a
    // just-saved license key that must reach the child env). The old process is
    // detached from `server` first so its termination reads as an intentional
    // swap, not a crash.
    private func restartServer(grading repoURL: URL) {
        guard started, let nodeURL, let serverURL else { return }
        if let old = server {
            server = nil
            terminate(old)
        }
        logHandle?.closeFile()
        logHandle = nil
        openedBrowser = false
        outputBuffer = ""
        currentRepo = repoURL
        remember(repoURL)
        startServer(nodeURL: nodeURL, serverURL: serverURL, repoURL: repoURL)
    }

    // The drag-to-grade welcome window: a dashed drop well that accepts a folder,
    // plus a native picker button for users who'd rather browse.
    private func showDropWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Circuit"
        window.center()
        window.isReleasedWhenClosed = false

        let drop = DropView(frame: NSRect(x: 0, y: 0, width: 540, height: 380))
        drop.autoresizingMask = [.width, .height]
        drop.onDrop = { [weak self] url in self?.beginGrading(url) }

        let title = label("Drop a folder to grade it", size: 22, weight: .bold, color: NSColor(white: 1, alpha: 0.92))
        title.frame = NSRect(x: 40, y: 250, width: 460, height: 34)
        let sub = label("Drag any code repository here — Circuit grades every file and wires it in 3D.", size: 13, weight: .regular, color: NSColor(white: 1, alpha: 0.55))
        sub.frame = NSRect(x: 40, y: 210, width: 460, height: 40)
        sub.usesSingleLineMode = false
        sub.cell?.wraps = true

        let button = NSButton(title: "Choose a folder…", target: self, action: #selector(pickFolder))
        button.bezelStyle = .rounded
        button.frame = NSRect(x: 210, y: 120, width: 160, height: 32)

        drop.addSubview(title)
        drop.addSubview(sub)
        drop.addSubview(button)
        window.contentView = drop
        window.makeKeyAndOrderFront(nil)
        dropWindow = window
    }

    @objc private func pickFolder() {
        if let repo = chooseRepository() { beginGrading(repo) }
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.alignment = .center
        return field
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private func chooseRepository() -> URL? {
        let recents = recentRepositories()
        if recents.isEmpty {
            return openPanel(title: "Grade your first repository", message: "Choose the codebase Circuit should grade.")
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Grade which repository?"
        alert.informativeText = "Choose a recent repo or pick another folder."
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 520, height: 26), pullsDown: false)
        for url in recents {
            popup.addItem(withTitle: abbreviated(url.path))
            popup.lastItem?.representedObject = url
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Grade Selected")
        alert.addButton(withTitle: "Choose Other")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return popup.selectedItem?.representedObject as? URL
        case .alertSecondButtonReturn:
            return openPanel(title: "Choose a repository", message: "Pick the codebase Circuit should grade.", defaultURL: recents.first)
        default:
            return nil
        }
    }

    private func openPanel(title: String, message: String, defaultURL: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Grade Repository"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultURL
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func startServer(nodeURL: URL, serverURL: URL, repoURL: URL) {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let logURL = supportDirectory.appendingPathComponent("last-run.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
            logHandle = try FileHandle(forWritingTo: logURL)

            let process = Process()
            process.executableURL = nodeURL
            process.arguments = [serverURL.path, repoURL.path]
            process.currentDirectoryURL = serverURL.deletingLastPathComponent()
            // GUI-launched apps never inherit shell env vars — inject the saved
            // license key so a purchased CIRCUIT_LICENSE reaches lib/license.js.
            var env = ProcessInfo.processInfo.environment
            if let key = storedLicenseKey() { env["CIRCUIT_LICENSE"] = key }
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.recordOutput(data)
            }

            // Only the CURRENT server's exit is fatal — a process detached by
            // restartServer terminates by design and must not raise this alert.
            process.terminationHandler = { [weak self] proc in
                DispatchQueue.main.async {
                    guard let self, !self.isQuitting, self.server === proc else { return }
                    self.showAlert(title: "Circuit stopped", message: "The local grading server exited. See last-run.log in Application Support/Circuit.")
                    NSApp.terminate(nil)
                }
            }

            server = process
            try process.run()
        } catch {
            showAlert(title: "Circuit cannot start", message: error.localizedDescription)
            NSApp.terminate(nil)
        }
    }

    private func recordOutput(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        outputBuffer += text
        // Wait for a whole line; the capability and port may span stdout chunks.
        while let newline = outputBuffer.firstIndex(of: "\n") {
            let line = String(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            let redacted = line.replacingOccurrences(of: #"#handoff=[A-Za-z0-9_-]+"#, with: "#handoff=[redacted]", options: .regularExpression)
            if let bytes = (redacted + "\n").data(using: .utf8) { logHandle?.write(bytes) }
            guard !openedBrowser,
                  let range = line.range(of: #"http://localhost:[0-9]+/#handoff=[A-Za-z0-9_-]{43}$"#, options: .regularExpression) else { continue }
            openedBrowser = true
            let urlText = String(line[range])
            DispatchQueue.main.async {
                if let url = URL(string: urlText) { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                Process.launchedProcess(launchPath: "/bin/kill", arguments: ["-KILL", "\(process.processIdentifier)"]).waitUntilExit()
            }
        }
    }

    private func terminateServer() {
        guard let server else { return }
        terminate(server)
        logHandle?.closeFile()
    }

    private func recentRepositories() -> [URL] {
        guard let text = try? String(contentsOf: recentsFile, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        return text
            .split(separator: "\n")
            .compactMap { line -> URL? in
                let path = String(line)
                guard !seen.contains(path) else { return nil }
                seen.insert(path)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            .prefix(8)
            .map { $0 }
    }

    private func remember(_ repoURL: URL) {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let chosen = repoURL.standardizedFileURL.path
            let kept = recentRepositories()
                .map { $0.standardizedFileURL.path }
                .filter { $0 != chosen }
            let next = ([chosen] + kept).prefix(8).joined(separator: "\n") + "\n"
            try next.write(to: recentsFile, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Circuit could not write recents: \(error.localizedDescription)")
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func requiresAppleSiliconGate() -> Bool {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }
}
