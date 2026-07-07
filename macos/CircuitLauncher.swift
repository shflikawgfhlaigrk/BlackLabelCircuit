import AppKit
import Foundation

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

    private let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Circuit", isDirectory: true)
    }()

    private var recentsFile: URL {
        supportDirectory.appendingPathComponent("recent-repos.txt")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if requiresAppleSiliconGate() {
            showAlert(
                title: "Circuit requires Apple Silicon",
                message: "This build bundles an arm64 Node runtime. Use Circuit on an Apple Silicon Mac."
            )
            NSApp.terminate(nil)
            return
        }

        guard let resources = Bundle.main.resourceURL else {
            showAlert(title: "Circuit cannot start", message: "The app bundle resources are missing.")
            NSApp.terminate(nil)
            return
        }

        let nodeURL = resources.appendingPathComponent("node/node")
        let serverURL = resources.appendingPathComponent("app/server.js")
        guard FileManager.default.isExecutableFile(atPath: nodeURL.path) else {
            showAlert(title: "Circuit cannot start", message: "The bundled Node runtime is missing.")
            NSApp.terminate(nil)
            return
        }
        guard FileManager.default.fileExists(atPath: serverURL.path) else {
            showAlert(title: "Circuit cannot start", message: "The bundled Circuit server is missing.")
            NSApp.terminate(nil)
            return
        }

        guard let repoURL = chooseRepository() else {
            NSApp.terminate(nil)
            return
        }

        remember(repoURL)
        startServer(nodeURL: nodeURL, serverURL: serverURL, repoURL: repoURL)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isQuitting = true
        terminateServer()
        return .terminateNow
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

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.recordOutput(data)
            }

            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, !self.isQuitting else { return }
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
        logHandle?.write(data)
        guard !openedBrowser, let text = String(data: data, encoding: .utf8) else { return }
        outputBuffer += text
        if let range = outputBuffer.range(of: #"http://localhost:[0-9]+"#, options: .regularExpression) {
            openedBrowser = true
            let urlText = String(outputBuffer[range])
            DispatchQueue.main.async {
                if let url = URL(string: urlText) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func terminateServer() {
        guard let server else { return }
        if server.isRunning {
            server.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if server.isRunning {
                    Process.launchedProcess(launchPath: "/bin/kill", arguments: ["-KILL", "\(server.processIdentifier)"]).waitUntilExit()
                }
            }
        }
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
