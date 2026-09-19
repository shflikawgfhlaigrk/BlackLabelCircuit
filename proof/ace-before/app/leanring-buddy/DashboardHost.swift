import Foundation
#if canImport(Network) && !CIRCUIT_WINDOWS_SIM
import Network
#endif

nonisolated struct DashboardHostConfiguration: Equatable, Sendable {
    let rootURL: URL
    let allowedTools: [String]
    let opensBrowser: Bool
}

nonisolated enum DashboardHostRoute: Equatable, Sendable {
    case staticFile(String)
    case readTool(name: String, arguments: [String])
    case health
    case blocked
}

/// Pure admission and routing policy for the local dashboard server sealed in
/// Ace. Generated projects receive a bounded reader bridge without depending
/// on Python, Node, Homebrew, Xcode, or a machine-global service.
nonisolated enum DashboardHostPolicy {
    static let readOnlyTools: Set<String> = [
        "app-list",
        "calendar-today",
        "clipboard",
        "contact-find",
        "email-read",
        "find-file",
        "music-control",
        "screenshot-take",
        "system-info",
        "weather",
        "web-fetch",
        "web-search",
    ]

    private static let staticExtensions: Set<String> = [
        "css", "gif", "html", "ico", "jpeg", "jpg", "js", "json",
        "png", "svg", "webp", "woff", "woff2",
    ]

    static func parse(
        arguments: [String],
        homeDirectory: URL
    ) -> DashboardHostConfiguration? {
        guard arguments.contains("--dashboard-host") else { return nil }
        var rootPath: String?
        var tools: Set<String> = []
        var opensBrowser = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--dashboard-host":
                index += 1
            case "--root":
                guard index + 1 < arguments.count,
                      rootPath == nil else { return nil }
                rootPath = arguments[index + 1]
                index += 2
            case "--allow-tool":
                guard index + 1 < arguments.count else { return nil }
                let tool = arguments[index + 1]
                guard readOnlyTools.contains(tool) else { return nil }
                tools.insert(tool)
                index += 2
            case "--open":
                guard !opensBrowser else { return nil }
                opensBrowser = true
                index += 1
            default:
                return nil
            }
        }

        guard let rootPath else { return nil }
        let projectsRoot = homeDirectory
            .appendingPathComponent("Ace Projects", isDirectory: true)
            .standardizedFileURL
        let rootURL = URL(
            fileURLWithPath: rootPath,
            isDirectory: true
        ).standardizedFileURL
        guard rootURL.deletingLastPathComponent().path == projectsRoot.path,
              !rootURL.lastPathComponent.isEmpty,
              !rootURL.lastPathComponent.hasPrefix(".") else {
            return nil
        }
        return DashboardHostConfiguration(
            rootURL: rootURL,
            allowedTools: tools.sorted(),
            opensBrowser: opensBrowser
        )
    }

    static func route(
        requestTarget: String,
        sessionToken: String,
        allowedTools: Set<String>,
        workspaceRoot: URL,
        entitlementIsCurrent: Bool
    ) -> DashboardHostRoute {
        guard entitlementIsCurrent,
              requestTarget.count <= 4_096,
              let components = URLComponents(
                string: "http://127.0.0.1\(requestTarget)"
              ),
              let decodedPath = components.percentEncodedPath
                .removingPercentEncoding else {
            return .blocked
        }
        let prefix = "/session/\(sessionToken)/"
        guard decodedPath.hasPrefix(prefix) else { return .blocked }
        let relativePath = String(decodedPath.dropFirst(prefix.count))

        if relativePath == "api/health" {
            return .health
        }
        if relativePath == "api/read" {
            let items = components.queryItems ?? []
            let toolItems = items.filter { $0.name == "tool" }
            guard toolItems.count == 1,
                  let tool = toolItems[0].value,
                  allowedTools.contains(tool),
                  readOnlyTools.contains(tool) else {
                return .blocked
            }
            let unknown = items.contains { $0.name != "tool" && $0.name != "arg" }
            let rawArguments = items.filter { $0.name == "arg" }.compactMap(\.value)
            guard !unknown, rawArguments.count <= 8 else { return .blocked }
            var arguments: [String] = []
            for rawArgument in rawArguments {
                guard let admitted = admittedToolArgument(
                    rawArgument,
                    workspaceRoot: workspaceRoot
                ) else {
                    return .blocked
                }
                arguments.append(admitted)
            }
            return .readTool(name: tool, arguments: arguments)
        }

        let requestedFile = relativePath.isEmpty ? "index.html" : relativePath
        let pathComponents = requestedFile.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !pathComponents.isEmpty,
              pathComponents.allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
                      && !component.hasPrefix(".")
              }),
              !requestedFile.contains("\\"),
              staticExtensions.contains(
                URL(fileURLWithPath: requestedFile).pathExtension.lowercased()
              ) else {
            return .blocked
        }
        return .staticFile(requestedFile)
    }

    /// Admits one `arg` query item for the read bridge, returning the exact
    /// value the tool receives (nil = blocked).
    ///
    /// Most arguments are plain words ("5", "unread", a search term) and pass
    /// through untouched. But the reader contracts the build prompt ADVERTISES
    /// include two shapes that need '/': `web-fetch <url>` and
    /// `screenshot-take [path.png]`. Build 62 rejected every '/' outright,
    /// which made both of those generated dashboard controls dead on arrival.
    /// This admits exactly the advertised shapes — never a blanket '/':
    ///   1. a plain https URL (same rule WorkflowPlan applies to approved
    ///      external sources: https scheme, nonempty host, no credentials);
    ///   2. a path that resolves INSIDE this dashboard's own workspace,
    ///      workspace-relative or already absolute. `..`, hidden and empty
    ///      components are refused on the RAW text, before standardization,
    ///      so "a/../b" cannot launder itself into an inside path; the
    ///      admitted value is canonicalized to the absolute in-workspace path
    ///      because screenshot-take's contract demands an absolute .png
    ///      destination.
    private static func admittedToolArgument(
        _ argument: String,
        workspaceRoot: URL
    ) -> String? {
        guard !argument.isEmpty,
              argument.utf8.count <= 512,
              !argument.contains("\\"),
              !argument.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        guard argument.contains("/") else { return argument }

        if argument.hasPrefix("https://") {
            guard let url = URL(string: argument),
                  url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else {
                return nil
            }
            return argument
        }

        let isAbsolutePath = argument.hasPrefix("/")
        let rawComponents = argument.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        // An absolute path's leading "/" produces one empty first component;
        // every remaining component must be a real, visible name.
        let pathComponents = isAbsolutePath
            ? Array(rawComponents.dropFirst())
            : Array(rawComponents)
        guard !pathComponents.isEmpty,
              pathComponents.allSatisfy({ component in
                  !component.isEmpty && component != "." && component != ".."
                      && !component.hasPrefix(".")
              }) else {
            return nil
        }
        let rootPath = workspaceRoot.standardizedFileURL.path
        let resolvedPath = URL(
            fileURLWithPath: isAbsolutePath
                ? argument
                : rootPath + "/" + argument
        ).standardizedFileURL.path
        guard resolvedPath.hasPrefix(rootPath + "/") else { return nil }
        return resolvedPath
    }

    static func launcherScript(allowedTools: [String]) -> String {
        let validated = Array(Set(allowedTools.filter {
            readOnlyTools.contains($0)
        })).sorted()
        let toolArguments = validated.map {
            "--allow-tool \($0)"
        }.joined(separator: " ")
        return """
            #!/bin/zsh
            set -euo pipefail
            PROJECT_ROOT="${0:A:h}"
            ACE_HOST="/Applications/Ace.app/Contents/MacOS/Ace"
            if [[ ! -x "$ACE_HOST" ]]; then
              print -u2 -- "Ace must be installed in Applications to run this dashboard."
              exit 1
            fi
            exec "$ACE_HOST" --dashboard-host --root "$PROJECT_ROOT" \(toolArguments) --open
            """ + "\n"
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated final class DashboardHostService: @unchecked Sendable {
    private let configuration: DashboardHostConfiguration
    private let entitlementIsCurrent: @Sendable () -> Bool
    private let sessionToken = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(
        label: "com.blacklabel.ace.dashboard-host",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var listener: NWListener?

    init(
        configuration: DashboardHostConfiguration,
        entitlementIsCurrent: @escaping @Sendable () -> Bool
    ) {
        self.configuration = configuration
        self.entitlementIsCurrent = entitlementIsCurrent
    }

    func start() throws {
        guard validateRoot() else {
            throw CocoaError(.fileReadNoPermission)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: .any
        )
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port else {
                    // A ready listener with no port can never be reached or
                    // acknowledged. Returning silently here left the host
                    // hanging forever with no ready line, no browser, and no
                    // error — exit loudly instead so the launch visibly fails.
                    FileHandle.standardError.write(
                        Data("Ace dashboard host has no listening port.\n".utf8)
                    )
                    exit(70)
                }
                let url = "http://127.0.0.1:\(port.rawValue)/session/\(sessionToken)/"
                FileHandle.standardOutput.write(Data("ACE_DASHBOARD_READY \(url)\n".utf8))
                if configuration.opensBrowser {
                    openBrowser(url)
                }
            case let .failed(error):
                FileHandle.standardError.write(
                    Data("Ace dashboard host failed: \(error)\n".utf8)
                )
                exit(70)
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    private func validateRoot() -> Bool {
        let fileManager = FileManager.default
        let root = configuration.rootURL
        guard root.resolvingSymlinksInPath() == root else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulated: Data())
    }

    private func receive(on connection: NWConnection, accumulated: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16_384
        ) { [weak self] data, _, _, error in
            guard let self else { return }
            var request = accumulated
            if let data { request.append(data) }
            if request.count > 64 * 1_024 {
                send(status: 413, body: Data(), contentType: "text/plain", on: connection)
                return
            }
            if request.range(of: Data("\r\n\r\n".utf8)) == nil {
                if error == nil {
                    receive(on: connection, accumulated: request)
                } else {
                    connection.cancel()
                }
                return
            }
            handle(request, on: connection)
        }
    }

    private func handle(_ requestData: Data, on connection: NWConnection) {
        guard let request = String(data: requestData, encoding: .utf8) else {
            send(status: 400, body: Data(), contentType: "text/plain", on: connection)
            return
        }
        let lines = request.components(separatedBy: "\r\n")
        guard let first = lines.first else {
            send(status: 400, body: Data(), contentType: "text/plain", on: connection)
            return
        }
        let fields = first.split(separator: " ")
        guard fields.count == 3,
              fields[0] == "GET",
              fields[2] == "HTTP/1.1" else {
            send(status: 405, body: Data(), contentType: "text/plain", on: connection)
            return
        }
        let target = String(fields[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                send(status: 400, body: Data(), contentType: "text/plain", on: connection)
                return
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, headers[name] == nil else {
                send(status: 400, body: Data(), contentType: "text/plain", on: connection)
                return
            }
            headers[name] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard let listenerPort = listener?.port?.rawValue else {
            send(status: 503, body: Data(), contentType: "text/plain", on: connection)
            return
        }
        let loopbackHosts = [
            "127.0.0.1:\(listenerPort)",
            "localhost:\(listenerPort)",
        ]
        guard let host = headers["host"],
              loopbackHosts.contains(host.lowercased()) else {
            send(status: 403, body: Data(), contentType: "text/plain", on: connection)
            return
        }

        switch DashboardHostPolicy.route(
            requestTarget: target,
            sessionToken: sessionToken,
            allowedTools: Set(configuration.allowedTools),
            workspaceRoot: configuration.rootURL,
            entitlementIsCurrent: entitlementIsCurrent()
        ) {
        case let .staticFile(relativePath):
            serve(relativePath: relativePath, on: connection)
        case let .readTool(name, arguments):
            runTool(name: name, arguments: arguments, on: connection)
        case .health:
            sendJSON(["ok": true, "product": "Ace dashboard host"], on: connection)
        case .blocked:
            send(status: 404, body: Data(), contentType: "text/plain", on: connection)
        }
    }

    private func serve(relativePath: String, on connection: NWConnection) {
        let root = configuration.rootURL
        let fileURL = root.appendingPathComponent(relativePath).standardizedFileURL
        guard fileURL.path.hasPrefix(root.path + "/"),
              fileURL.resolvingSymlinksInPath() == fileURL,
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: fileURL.path
              ),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue <= 8 * 1_024 * 1_024,
              let data = try? Data(contentsOf: fileURL) else {
            send(status: 404, body: Data(), contentType: "text/plain", on: connection)
            return
        }
        send(
            status: 200,
            body: data,
            contentType: Self.mimeType(for: fileURL.pathExtension),
            on: connection
        )
    }

    private func runTool(
        name: String,
        arguments: [String],
        on connection: NWConnection
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            guard entitlementIsCurrent() else {
                sendJSON(
                    ["ok": false, "error": "Ace account access is required"],
                    status: 403,
                    on: connection
                )
                return
            }
            guard let resources = Bundle.main.resourceURL else {
                sendJSON(["ok": false, "error": "Ace resources are unavailable"], status: 500, on: connection)
                return
            }
            let toolsRoot = resources
                .appendingPathComponent("tools", isDirectory: true)
                .standardizedFileURL
            let toolURL = toolsRoot.appendingPathComponent(name).standardizedFileURL
            guard toolURL.path.hasPrefix(toolsRoot.path + "/"),
                  toolURL.resolvingSymlinksInPath() == toolURL,
                  FileManager.default.isExecutableFile(atPath: toolURL.path) else {
                sendJSON(["ok": false, "error": "Reader is unavailable"], status: 503, on: connection)
                return
            }
            // The route policy admits an absolute argument only when it lies
            // lexically inside the workspace, and validateRoot() proved the
            // root itself is symlink-free at start. A build-authored symlinked
            // SUBFOLDER is the remaining way an in-workspace path can point
            // outside it, so re-prove containment here, at execution time,
            // with symlinks resolved.
            let workspaceRootPath = configuration.rootURL.standardizedFileURL.path
            for argument in arguments where argument.hasPrefix("/") {
                let resolvedArgumentPath = URL(fileURLWithPath: argument)
                    .resolvingSymlinksInPath().path
                guard argument.hasPrefix(workspaceRootPath + "/"),
                      resolvedArgumentPath.hasPrefix(workspaceRootPath + "/") else {
                    sendJSON(
                        ["ok": false, "error": "Reader argument leaves this dashboard's workspace"],
                        status: 403,
                        on: connection
                    )
                    return
                }
            }
            // Mirror AppActionBroker's wrapper environment: inherited ACE_*
            // values are stripped and the effect-guard paths are pinned to the
            // real owner-only support directory, so the launching shell can
            // never re-point the guard's boundary, stealth markers, or tool
            // binary overrides — and so the approval token minted below is
            // validated against the same directory it was written into.
            guard let applicationSupportURL = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                sendJSON(["ok": false, "error": "Ace support directory is unavailable"], status: 500, on: connection)
                return
            }
            let supportDirectoryURL = applicationSupportURL
                .appendingPathComponent("BlackLabel", isDirectory: true)
            var environment = ProcessInfo.processInfo.environment
            for key in environment.keys where key.hasPrefix("ACE_") {
                environment.removeValue(forKey: key)
            }
            environment["ACE_EFFECT_GUARD_SUPPORT_DIRECTORY"] = supportDirectoryURL.path
            environment["ACE_STEALTH_MARKER"] = supportDirectoryURL
                .appendingPathComponent("stealth-active", isDirectory: false).path
            environment["ACE_STEALTH_INTENT"] = supportDirectoryURL
                .appendingPathComponent("stealth-intent-v1", isDirectory: false).path
            // screenshot-take guards its capture behind a one-use app-issued
            // approval (tools/effect-guard.sh). For a dashboard that approval
            // already happened: the owner armed a whole-job readback that
            // named "your screen", and trusted app code pinned
            // `--allow-tool screenshot-take` into run.command. Without a
            // token every dashboard screenshot control was dead — the tool
            // exited "no active owner-turn effect authority" on each click. Minting one
            // token per admitted request keeps the one-token-one-invocation
            // property. No other tool receives approval context, so
            // `web-fetch --open` and every other mutation path still fails
            // closed at the guard.
            var screenshotApproval: DashboardScreenshotApproval?
            if name == "screenshot-take" {
                guard let issued = DashboardScreenshotApproval.issue(
                    supportDirectoryURL: supportDirectoryURL
                ) else {
                    sendJSON(["ok": false, "error": "Screen reader approval could not be issued"], status: 503, on: connection)
                    return
                }
                screenshotApproval = issued
                environment["ACE_APP_MUTATION_APPROVED"] = "1"
                environment["ACE_APP_MUTATION_TOKEN_PATH"] = issued.tokenURL.path
            }
            defer { screenshotApproval?.destroy() }
            let process = Process()
            process.executableURL = toolURL
            process.arguments = arguments
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let output = DashboardHostOutputBuffer(limit: 64 * 1_024)
            let outputClosed = DispatchSemaphore(value: 0)
            let outputHandle = pipe.fileHandleForReading
            outputHandle.readabilityHandler = { handle in
                let available = handle.availableData
                if available.isEmpty {
                    handle.readabilityHandler = nil
                    outputClosed.signal()
                } else {
                    // Keep draining after the response limit so a verbose
                    // reader can never fill the pipe and deadlock the host.
                    output.append(available)
                }
            }
            do {
                try process.run()
            } catch {
                outputHandle.readabilityHandler = nil
                sendJSON(["ok": false, "error": "Reader did not start"], status: 503, on: connection)
                return
            }
            let deadline = Date().addingTimeInterval(20)
            var entitlementWasRevoked = false
            while process.isRunning && Date() < deadline {
                if !entitlementIsCurrent() {
                    entitlementWasRevoked = true
                    process.terminate()
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if entitlementWasRevoked {
                let terminationDeadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                _ = outputClosed.wait(timeout: .now() + 1)
                outputHandle.readabilityHandler = nil
                sendJSON(
                    ["ok": false, "error": "Ace account access ended"],
                    status: 403,
                    on: connection
                )
                return
            }
            if process.isRunning {
                process.terminate()
                let terminationDeadline = Date().addingTimeInterval(1)
                while process.isRunning && Date() < terminationDeadline {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning {
                    Darwin.kill(process.processIdentifier, SIGKILL)
                }
                process.waitUntilExit()
                _ = outputClosed.wait(timeout: .now() + 1)
                outputHandle.readabilityHandler = nil
                sendJSON(["ok": false, "error": "Reader timed out"], status: 504, on: connection)
                return
            }
            process.waitUntilExit()
            _ = outputClosed.wait(timeout: .now() + 1)
            outputHandle.readabilityHandler = nil
            let text = String(decoding: output.snapshot(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            sendJSON(
                [
                    "ok": process.terminationStatus == 0,
                    "tool": name,
                    "output": text,
                ],
                status: process.terminationStatus == 0 ? 200 : 502,
                on: connection
            )
        }
    }

    private func openBrowser(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        try? process.run()
    }

    private func sendJSON(
        _ object: [String: Any],
        status: Int = 200,
        on connection: NWConnection
    ) {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        send(
            status: status,
            body: data,
            contentType: "application/json; charset=utf-8",
            on: connection
        )
    }

    private func send(
        status: Int,
        body: Data,
        contentType: String,
        on connection: NWConnection
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 500: reason = "Internal Server Error"
        case 502: reason = "Bad Gateway"
        case 503: reason = "Service Unavailable"
        case 504: reason = "Gateway Timeout"
        default: reason = "Error"
        }
        let header = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: DENY",
            "Referrer-Policy: no-referrer",
            "Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'",
            "Connection: close",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(
            content: response,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    private static func mimeType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "text/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}
#endif // circuit-convert

/// One-use effect-guard approval minted for a dashboard screenshot read.
///
/// WHY this exists instead of reusing `OwnerTurnEffectAuthority`:
/// the standalone test battery compiles DashboardHost.swift with only its own
/// dependencies, and the broker drags the whole app-action surface with it.
/// The CONTRACT both implementations satisfy is defined by
/// `tools/effect-guard.sh` (`ace_effect_guard_require_approval`): a nonempty
/// regular file named `token-<hex/dash identifier>` inside the owner-only
/// 0700 `action-approvals` directory, consumed exactly once by the wrapper.
nonisolated private struct DashboardScreenshotApproval {
    let tokenURL: URL
    let consumedURL: URL

    static func issue(
        supportDirectoryURL: URL
    ) -> DashboardScreenshotApproval? {
        let fileManager = FileManager.default
        let approvalDirectoryURL = supportDirectoryURL
            .appendingPathComponent("action-approvals", isDirectory: true)
        for directoryURL in [supportDirectoryURL, approvalDirectoryURL] {
            do {
                try fileManager.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let values = try directoryURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true,
                      values.isSymbolicLink != true else { return nil }
                // Repair a previously loose mode: the effect guard refuses
                // every tool unless the support directory is exactly 0700.
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directoryURL.path
                )
            } catch {
                return nil
            }
        }
        let identifier = UUID().uuidString
        let tokenURL = approvalDirectoryURL
            .appendingPathComponent("token-\(identifier)", isDirectory: false)
        // O_EXCL + O_NOFOLLOW: the token must be a NEW regular file this
        // process created — a planted symlink or reused name fails closed.
        let descriptor = tokenURL.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        let bytes = Array("\(identifier)\n".utf8)
        var offset = 0
        let wroteAll = bytes.withUnsafeBytes { buffer -> Bool in
            guard let baseAddress = buffer.baseAddress else { return false }
            while offset < buffer.count {
                let written = Darwin.write(
                    descriptor,
                    baseAddress + offset,
                    buffer.count - offset
                )
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
        guard wroteAll else {
            Darwin.unlink(tokenURL.path)
            return nil
        }
        return DashboardScreenshotApproval(
            tokenURL: tokenURL,
            consumedURL: URL(fileURLWithPath: tokenURL.path + ".consumed")
        )
    }

    /// The wrapper consumes the token file itself; this clears whatever is
    /// left (an unconsumed token after a failed run, and the `.consumed`
    /// marker directory after a successful one) so approvals never pile up.
    func destroy() {
        try? FileManager.default.removeItem(at: tokenURL)
        try? FileManager.default.removeItem(at: consumedURL)
    }
}

nonisolated private final class DashboardHostOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ newData: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else { return }
        data.append(newData.prefix(limit - data.count))
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
enum DashboardHostCLI {
    private static var service: DashboardHostService?

    static func startIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        guard arguments.contains("--dashboard-host") else { return false }
        guard let configuration = DashboardHostPolicy.parse(
            arguments: arguments,
            homeDirectory: homeDirectory
        ) else {
            FileHandle.standardError.write(Data("Invalid Ace dashboard host request.\n".utf8))
            exit(64)
        }
        guard AceEntitlementRuntimeAdmissionGate.shared.admits(
            .dashboardTool
        ) else {
            FileHandle.standardError.write(
                Data("Ace account access is required.\n".utf8)
            )
            exit(77)
        }
        let service = DashboardHostService(
            configuration: configuration,
            entitlementIsCurrent: {
                AceEntitlementRuntimeAdmissionGate.shared.admits(
                    .dashboardTool
                )
            }
        )
        do {
            try service.start()
            self.service = service
            return true
        } catch {
            FileHandle.standardError.write(Data("Ace dashboard host could not start.\n".utf8))
            exit(70)
        }
    }
}
#endif // circuit-convert
