#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
import Foundation
#if canImport(Network) && !CIRCUIT_WINDOWS_SIM
import Network
#endif
#if canImport(WebKit) && !CIRCUIT_WINDOWS_SIM
import WebKit
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One worker's private web surface. It has no NSWindow and never uses the
/// system pointer, clipboard, browser profile, or active application.
@MainActor
final class BackgroundBrowserService: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let authorization = UUID().uuidString + UUID().uuidString
    private let isAllowed: () -> Bool
    private let dataAdapter: (([String: Any]) async -> [String: Any])?
    private var adapterTask: Task<[String: Any], Never>?
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var buffers: [ObjectIdentifier: Data] = [:]
    private var startContinuation: CheckedContinuation<[String: String], Error>?
    private var webView: WKWebView?
    private var snapshotID: String?
    private var busy = false
    private var stopped = false
    private let world = WKContentWorld.world(name: "AceBackgroundBrowser")

    init(
        isAllowed: @escaping () -> Bool,
        dataAdapter: (([String: Any]) async -> [String: Any])? = nil
    ) {
        self.isAllowed = isAllowed
        self.dataAdapter = dataAdapter
    }

    func start() async throws -> [String: String] {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, let pending = self.startContinuation else { return }
                    switch state {
                    case .ready:
                        guard let port = listener.port, self.isAllowed(), !self.stopped else {
                            self.stop(); return
                        }
                        self.startContinuation = nil
                        pending.resume(returning: [
                            "ACE_BACKGROUND_BROWSER_PORT": String(port.rawValue),
                            "ACE_BACKGROUND_BROWSER_AUTH": self.authorization,
                        ])
                    case .failed(let error):
                        self.startContinuation = nil
                        pending.resume(throwing: error)
                        self.stop()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if self?.startContinuation != nil { self?.stop() }
            }
        }
    }

    func stop() {
        stopped = true
        adapterTask?.cancel(); adapterTask = nil
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll(); buffers.removeAll()
        webView?.stopLoading()
        webView?.navigationDelegate = nil; webView?.uiDelegate = nil
        webView = nil; snapshotID = nil
        startContinuation?.resume(throwing: CancellationError())
        startContinuation = nil
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, isAllowed(), connections.count < 4 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection; buffers[id] = Data()
        connection.start(queue: .main)
        receive(connection)
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(140))
            guard let self, let connection, self.connections[id] != nil else { return }
            self.close(connection)
        }
    }

    private func close(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        buffers.removeValue(forKey: id); connections.removeValue(forKey: id)
        connection.cancel()
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_537) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let id = ObjectIdentifier(connection)
                guard self.connections[id] != nil, !self.stopped, self.isAllowed() else {
                    self.close(connection); return
                }
                if let data { self.buffers[id, default: Data()].append(data) }
                let buffer = self.buffers[id] ?? Data()
                guard buffer.count <= 65_536 else { self.close(connection); return }
                if let end = buffer.firstIndex(of: 10) {
                    guard end == buffer.index(before: buffer.endIndex),
                          let envelope = try? JSONSerialization.jsonObject(with: buffer[..<end]) as? [String: Any],
                          let token = envelope["authorization"] as? String,
                          token == self.authorization,
                          let request = envelope["request"] as? [String: Any] else {
                        self.reply(["status": "failed", "message": "Invalid browser request."], to: connection)
                        return
                    }
                    self.buffers.removeValue(forKey: id)
                    let result = await self.execute(request)
                    guard self.isAllowed(), !self.stopped else { self.close(connection); return }
                    self.reply(result, to: connection)
                } else if done || error != nil { self.close(connection) }
                else { self.receive(connection) }
            }
        }
    }

    private func reply(_ object: [String: Any], to connection: NWConnection) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count < 262_144 else { close(connection); return }
        data.append(10)
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.close(connection) }
        })
    }

    private func view() -> WKWebView {
        if let webView { return webView }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        self.webView = view
        return view
    }

    private func script(_ source: String, in view: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(source, in: nil, in: world) { result in
                switch result {
                case .success(let value): continuation.resume(returning: value as? String ?? "")
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func settle(_ view: WKWebView) async throws {
        let deadline = Date().addingTimeInterval(20)
        try await Task.sleep(for: .milliseconds(100))
        while view.isLoading {
            guard isAllowed(), !stopped, Date() < deadline else {
                view.stopLoading(); throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        guard isAllowed(), !stopped else { throw CancellationError() }
    }

    private func snapshot(_ view: WKWebView) async throws -> [String: Any] {
        let id = UUID().uuidString
        let text = try await script(#"""
        (() => {
          const targets = new Map(); let index = 0;
          const elements = Array.from(document.querySelectorAll('a,button,input,textarea,select,[contenteditable="true"],[role="button"]'))
            .filter(e => { const r=e.getBoundingClientRect(); return r.width>0 && r.height>0; }).slice(0,200)
            .map(e => { const token='e'+(++index); targets.set(token,e);
              return {token,tag:e.tagName.toLowerCase(),type:e.type||'',label:(e.getAttribute('aria-label')||e.innerText||e.getAttribute('placeholder')||'').slice(0,250),href:e.href||null}; });
          globalThis.aceTargets=targets;
          return JSON.stringify({url:location.href,title:document.title,text:(document.body?.innerText||'').slice(0,50000),elements});
        })()
        """#, in: view)
        guard var result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw CancellationError()
        }
        snapshotID = id
        result["snapshotID"] = id; result["status"] = "observed"
        result["retrievedAt"] = ISO8601DateFormatter().string(from: Date())
        result["session"] = "isolated temporary browser; personal browser cookies are unavailable"
        return result
    }

    private static func literal(_ value: String) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    private func execute(_ request: [String: Any]) async -> [String: Any] {
        guard !stopped, isAllowed(), !busy else { return ["status": "failed", "message": "Browser session is unavailable or busy."] }
        busy = true; defer { busy = false }
        do {
            if request["operation"] as? String == "data-adapter" {
                guard let dataAdapter else {
                    return ["status": "failed", "message": "The data adapter is unavailable."]
                }
                let task = Task { @MainActor in await dataAdapter(request) }
                adapterTask = task
                defer { adapterTask = nil }
                return await task.value
            }
            let view = view()
            switch request["operation"] as? String {
            case "navigate":
                guard let raw = request["url"] as? String, let url = URL(string: raw),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                      url.host != nil, url.user == nil, url.password == nil else { throw CancellationError() }
                snapshotID = nil
                view.load(URLRequest(url: url))
                try await settle(view)
            case "snapshot": break
            case "click", "type", "scroll":
                guard let id = request["snapshotID"] as? String, id == snapshotID else {
                    return ["status": "failed", "message": "The browser target changed; take a new snapshot."]
                }
                let operation = request["operation"] as? String
                if operation == "scroll" {
                    let delta = max(-900, min(900, request["deltaY"] as? Int ?? 0))
                    _ = try await script("window.scrollBy(0, \(delta)); 'scrolled'", in: view)
                } else {
                    guard let target = request["target"] as? String else { throw CancellationError() }
                    let lookup = "const e=globalThis.aceTargets?.get(\(Self.literal(target))); if(!e || !e.isConnected || e.disabled) throw Error('stale target');"
                    let action: String
                    if operation == "click" { action = "e.click(); return 'delivered';" }
                    else {
                        guard let text = request["text"] as? String, text.count <= 32_000 else { throw CancellationError() }
                        action = """
                        if(e.tagName==='INPUT' || e.tagName==='TEXTAREA') {
                          const proto=e.tagName==='INPUT'?HTMLInputElement.prototype:HTMLTextAreaElement.prototype;
                          Object.getOwnPropertyDescriptor(proto,'value').set.call(e,\(Self.literal(text)));
                        } else if(e.isContentEditable) { e.textContent=\(Self.literal(text)); }
                        else { throw Error('target is not editable'); }
                        e.dispatchEvent(new Event('input',{bubbles:true})); e.dispatchEvent(new Event('change',{bubbles:true})); return 'delivered';
                        """
                    }
                    _ = try await script("(() => { \(lookup) \(action) })()", in: view)
                }
                try await settle(view)
            default: return ["status": "failed", "message": "Unsupported browser operation."]
            }
            return try await snapshot(view)
        } catch {
            return ["status": "failed", "message": "The isolated browser operation did not produce a verified result. No system pointer action was used."]
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { snapshotID = nil }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(!stopped && isAllowed() && ["http", "https", "about"].contains(scheme) ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(!stopped && isAllowed() && navigationResponse.canShowMIMEType ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
}
#endif // circuit-convert
