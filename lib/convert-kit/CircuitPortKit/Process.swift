// CircuitPortKit process lifecycle. Converted call sites use CircuitProcess so
// Foundation.Process does not become an invisible Windows-only compile failure.
import Foundation
#if os(Windows)
import WinSDK
#endif

public enum CircuitProcessError: Error, CustomStringConvertible {
    case executableMissing
    case launchFailed(UInt32)
    public var description: String {
        switch self {
        case .executableMissing: return "CircuitProcess requires executableURL"
        case .launchFailed(let code): return "CreateProcessW failed with Windows error \(code)"
        }
    }
}

public final class CircuitProcess: @unchecked Sendable {
    public var executableURL: URL?
    public var arguments: [String]?
    public var environment: [String: String]?
    public var currentDirectoryURL: URL?

    private let lock = NSLock()
    private var status: Int32 = 0
    #if os(Windows)
    private var processHandle: HANDLE?
    private var processID: DWORD = 0
    #else
    private var process: Process?
    #endif

    public init() {}

    public var terminationStatus: Int32 { lock.withLock { status } }
    public var processIdentifier: Int32 {
        #if os(Windows)
        return lock.withLock { Int32(bitPattern: processID) }
        #else
        return lock.withLock { process?.processIdentifier ?? 0 }
        #endif
    }
    public var isRunning: Bool {
        #if os(Windows)
        return lock.withLock {
            guard let handle = processHandle else { return false }
            return WaitForSingleObject(handle, 0) == DWORD(WAIT_TIMEOUT)
        }
        #else
        return lock.withLock { process?.isRunning ?? false }
        #endif
    }

    public func run() throws {
        guard let executableURL else { throw CircuitProcessError.executableMissing }
        #if os(Windows)
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var info = PROCESS_INFORMATION()
        var command = Array(Self.windowsCommandLine(executableURL.path, arguments ?? []).utf16) + [0]
        var environmentBlock = Self.windowsEnvironmentBlock(environment ?? ProcessInfo.processInfo.environment)
        let directory = currentDirectoryURL?.path
        let launched = environmentBlock.withUnsafeMutableBufferPointer { environmentBuffer in
            command.withUnsafeMutableBufferPointer { commandBuffer in
                let environmentPointer = UnsafeMutableRawPointer(environmentBuffer.baseAddress)
                if let directory {
                    return directory.withCString(encodedAs: UTF16.self) { directoryPointer in
                        CreateProcessW(nil, commandBuffer.baseAddress, nil, nil, false, DWORD(CREATE_UNICODE_ENVIRONMENT), environmentPointer, directoryPointer, &startup, &info)
                    }
                }
                return CreateProcessW(nil, commandBuffer.baseAddress, nil, nil, false, DWORD(CREATE_UNICODE_ENVIRONMENT), environmentPointer, nil, &startup, &info)
            }
        }
        guard launched else { throw CircuitProcessError.launchFailed(GetLastError()) }
        CloseHandle(info.hThread)
        lock.withLock { processHandle = info.hProcess; processID = info.dwProcessId; status = 0 }
        #else
        let child = Process()
        child.executableURL = executableURL
        child.arguments = arguments
        child.environment = environment
        child.currentDirectoryURL = currentDirectoryURL
        try child.run()
        lock.withLock { process = child }
        #endif
    }

    public func waitUntilExit() {
        #if os(Windows)
        let handle = lock.withLock { processHandle }
        guard let handle else { return }
        _ = WaitForSingleObject(handle, DWORD(INFINITE))
        var code: DWORD = 0
        _ = GetExitCodeProcess(handle, &code)
        CloseHandle(handle)
        lock.withLock { status = Int32(bitPattern: code); processHandle = nil }
        #else
        let child = lock.withLock { process }
        child?.waitUntilExit()
        lock.withLock { status = child?.terminationStatus ?? status }
        #endif
    }

    public func terminate() {
        #if os(Windows)
        if let handle = lock.withLock({ processHandle }) { _ = TerminateProcess(handle, 15) }
        #else
        lock.withLock { process }?.terminate()
        #endif
    }

    static func windowsCommandLine(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments).map(windowsQuote).joined(separator: " ")
    }

    static func windowsEnvironmentBlock(_ values: [String: String]) -> [UInt16] {
        var block: [UInt16] = []
        for (key, value) in values.sorted(by: { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }) {
            block.append(contentsOf: "\(key)=\(value)".utf16)
            block.append(0)
        }
        block.append(0)
        return block
    }

    static func windowsQuote(_ value: String) -> String {
        guard value.isEmpty || value.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) else { return value }
        var out = "\"", slashes = 0
        for character in value {
            if character == "\\" { slashes += 1; continue }
            if character == "\"" { out += String(repeating: "\\", count: slashes * 2 + 1); out.append(character); slashes = 0; continue }
            out += String(repeating: "\\", count: slashes); slashes = 0; out.append(character)
        }
        out += String(repeating: "\\", count: slashes * 2) + "\""
        return out
    }
}
