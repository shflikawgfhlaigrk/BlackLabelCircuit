import Foundation
#if canImport(Network) && !CIRCUIT_WINDOWS_SIM
import Network
#endif

nonisolated private final class BrowserBackendReply: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false
    private(set) var result: Data?
    let signal = DispatchSemaphore(value: 0)

    func append(_ bytes: Data?, ended: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return false }
        if let bytes { data.append(bytes) }
        if data.count > 262_144 { finished = true; signal.signal(); return false }
        if data.last == 10 {
            result = data; finished = true; signal.signal(); return false
        }
        if ended { finished = true; signal.signal(); return false }
        return true
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated enum BrowserBackendHeadlessCommand {
    static let launchFlag = "--ace-browser-backend"
    static let dataLaunchFlag = "--ace-data-backend"

    static func runForever() -> Never {
        let environment = ProcessInfo.processInfo.environment
        let dataMode = CommandLine.arguments.dropFirst().first == dataLaunchFlag
        let input: Data
        if dataMode {
            let arguments = Array(CommandLine.arguments.dropFirst(2))
            guard let tool = arguments.first, arguments.count <= 6,
                  let encoded = try? JSONSerialization.data(withJSONObject: [
                    "operation": "data-adapter", "tool": tool,
                    "arguments": Array(arguments.dropFirst())
                  ]), encoded.count <= 64_000 else { fail("The data adapter request is invalid.") }
            input = encoded
        } else {
            guard let bytes = try? FileHandle.standardInput.read(upToCount: 65_537),
                  bytes.count <= 64_000 else { fail("The browser request is invalid.") }
            input = bytes
        }
        guard let portText = environment["ACE_BACKGROUND_BROWSER_PORT"],
              let rawPort = UInt16(portText), rawPort > 0,
              let port = NWEndpoint.Port(rawValue: rawPort),
              let authorization = environment["ACE_BACKGROUND_BROWSER_AUTH"],
              authorization.count == 72,
              let request = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
              var payload = try? JSONSerialization.data(withJSONObject: ["authorization": authorization, "request": request])
        else { fail("The task's isolated browser session is unavailable or the request is invalid.") }
        payload.append(10)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let reply = BrowserBackendReply()
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, error in
                if reply.append(data, ended: done || error != nil) { receive() }
            }
        }
        connection.start(queue: DispatchQueue(label: "Ace.browser-client"))
        connection.send(content: payload, completion: .contentProcessed { error in
            if error != nil { _ = reply.append(nil, ended: true) }
            else { receive() }
        })
        let completed = reply.signal.wait(timeout: .now() + (dataMode ? 135 : 35)) == .success
        connection.cancel()
        guard completed, let data = reply.result,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { fail("The isolated browser did not return a complete result.") }
        if dataMode {
            let output = object["output"] as? String ?? object["message"] as? String ?? "The data adapter returned no result."
            FileHandle.standardOutput.write(Data((output + (output.hasSuffix("\n") ? "" : "\n")).utf8))
            exit(object["status"] as? String == "verified" ? 0 : 3)
        }
        FileHandle.standardOutput.write(data)
        exit(object["status"] as? String == "failed" ? 3 : 0)
    }

    private static func fail(_ message: String) -> Never {
        let data = try! JSONSerialization.data(withJSONObject: ["status": "failed", "message": message])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        exit(3)
    }
}
#endif // circuit-convert
