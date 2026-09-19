import Foundation
#if canImport(Network) && !CIRCUIT_WINDOWS_SIM
import Network
#endif

nonisolated protocol GmailIMAPWire: AnyObject {
    func write(_ data: Data) throws
    func readLine() throws -> String
    func readBytes(_ count: Int) throws -> Data
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated final class GmailNetworkWire: GmailIMAPWire {
    private let connection: NWConnection
    private var buffered = Data()
    private let maximumBytes = 2_000_000
    private var received = 0

    private final class Reply: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: (Data, Bool)?
        func finish(data: Data = Data(), failed: Bool = false) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = (data, failed)
            lock.unlock()
            semaphore.signal()
        }
        func wait(seconds: Double) throws -> Data {
            guard semaphore.wait(timeout: .now() + seconds) == .success
            else { throw GmailBackendError.transport }
            lock.lock(); defer { lock.unlock() }
            guard let result, !result.1 else { throw GmailBackendError.transport }
            return result.0
        }
    }

    init() throws {
        connection = NWConnection(host: "imap.gmail.com", port: 993, using: .tls)
        let ready = Reply()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.finish()
            case .failed, .cancelled: ready.finish(failed: true)
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "com.blacklabel.ace.gmail-imap"))
        do { _ = try ready.wait(seconds: 20) } catch {
            connection.cancel(); throw GmailBackendError.transport
        }
        connection.stateUpdateHandler = nil
    }

    deinit { connection.cancel() }

    func cancel() { connection.cancel() }

    func write(_ data: Data) throws {
        let reply = Reply()
        connection.send(content: data, completion: .contentProcessed { error in
            reply.finish(failed: error != nil)
        })
        do { _ = try reply.wait(seconds: 30) }
        catch { connection.cancel(); throw GmailBackendError.transport }
    }

    private func receive() throws {
        let reply = Reply()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
            reply.finish(data: data ?? Data(), failed: error != nil || (data ?? Data()).isEmpty)
        }
        let data: Data
        do { data = try reply.wait(seconds: 30) }
        catch { connection.cancel(); throw GmailBackendError.transport }
        received += data.count
        guard received <= maximumBytes else { throw GmailBackendError.malformedResponse }
        buffered.append(data)
    }

    func readLine() throws -> String {
        let newline = Data([13, 10])
        while true {
            if let end = buffered.range(of: newline) {
                let data = buffered[..<end.lowerBound]
                let line = String(decoding: data, as: UTF8.self)
                buffered.removeSubrange(..<end.upperBound)
                return line
            }
            guard buffered.count <= 1_000_000 else { throw GmailBackendError.malformedResponse }
            try receive()
        }
    }

    func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= 262144 else { throw GmailBackendError.malformedResponse }
        while buffered.count < count { try receive() }
        let result = Data(buffered.prefix(count)); buffered.removeFirst(count)
        return result
    }
}
#endif // circuit-convert

nonisolated final class GmailIMAPSession: GmailIMAPCommands {
    private let wire: any GmailIMAPWire
    private let beforeCommand: () throws -> Void
    private var serial = 0

    init(wire: any GmailIMAPWire, address: String, password: String, usesOAuth: Bool = false,
         beforeCommand: @escaping () throws -> Void = {}) throws {
        self.wire = wire
        self.beforeCommand = beforeCommand
        let greeting = try wire.readLine()
        guard greeting.uppercased().hasPrefix("* OK "),
              !address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !password.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw GmailBackendError.transport }
        if usesOAuth {
            let authentication = Data("user=\(address)\u{01}auth=Bearer \(password)\u{01}\u{01}".utf8).base64EncodedString()
            _ = try command("AUTHENTICATE XOAUTH2 " + authentication)
        } else {
            _ = try command("LOGIN " + GmailIMAPSyntax.quoted(address) + " " + GmailIMAPSyntax.quoted(password))
        }
    }

    func command(_ command: String) throws -> GmailIMAPResponse {
        guard !command.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              command.utf8.count <= 8192
        else { throw GmailBackendError.invalidRequest }
        serial += 1
        let tag = "ACE\(serial)"
        try beforeCommand()
        try wire.write(Data((tag + " " + command + "\r\n").utf8))
        var response = GmailIMAPResponse()
        var bytes = 0
        while response.lines.count < 10000 {
            let line = try wire.readLine()
            bytes += line.utf8.count
            guard bytes <= 2_000_000 else { throw GmailBackendError.malformedResponse }
            if line.hasPrefix(tag + " ") {
                guard line.uppercased().hasPrefix(tag + " OK ") || line.uppercased() == tag + " OK"
                else { throw GmailBackendError.refused }
                return response
            }
            guard !line.uppercased().hasPrefix("* BYE"), !line.hasPrefix("+")
            else { throw GmailBackendError.transport }
            response.lines.append(line)
            if let countText = GmailIMAPSyntax.captures(#"\{([0-9]+)\}$"#, in: line)?.first,
               let count = Int(countText) {
                guard count <= 262144 else { throw GmailBackendError.malformedResponse }
                let data = try wire.readBytes(count)
                guard data.count == count else { throw GmailBackendError.malformedResponse }
                bytes += count
                guard bytes <= 2_000_000 else { throw GmailBackendError.malformedResponse }
                response.literals.append(data)
            }
        }
        throw GmailBackendError.malformedResponse
    }
}
