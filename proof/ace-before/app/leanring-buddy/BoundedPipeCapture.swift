#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// Drains helper output as it arrives. Finishing captures the readable tail
/// without waiting for EOF from a child that inherited the write descriptor.
/// All mutable state belongs to the utility queue; retained bytes are bounded.
nonisolated final class BoundedPipeCapture: @unchecked Sendable {
    struct Snapshot: Sendable {
        let data: Data
        let truncated: Bool
        let readFailed: Bool
    }

    private let queue = DispatchQueue(label: "com.blacklabel.assistant.pipe-capture", qos: .utility)
    private let descriptor: Int32
    private let limit: Int
    private let source: DispatchSourceRead
    private var data = Data()
    private var truncated = false
    private var readFailed = false
    private var finished = false

    init(handle: FileHandle, limit: Int) throws {
        let descriptor = fcntl(handle.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(descriptor)
            throw error
        }
        self.descriptor = descriptor
        self.limit = max(0, limit)
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.drainAvailableBytes() }
        source.setCancelHandler { Darwin.close(descriptor) }
        source.resume()
    }

    deinit { source.cancel() }

    func finish() -> Snapshot {
        queue.sync {
            if !finished {
                drainAvailableBytes()
                finished = true
                source.cancel()
            }
            return Snapshot(data: data, truncated: truncated, readFailed: readFailed)
        }
    }

    func discard() {
        queue.sync {
            finished = true
            data.removeAll(keepingCapacity: false)
            source.cancel()
        }
    }

    private func drainAvailableBytes() {
        guard !finished else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        // Yield even if a child writes continuously, so finish/discard cannot
        // wait behind an unbounded drain loop. Reads themselves never block.
        for _ in 0..<64 {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 {
                finished = true
                source.cancel()
                return
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    readFailed = true
                    finished = true
                    source.cancel()
                }
                return
            }
            let remaining = max(0, limit - data.count)
            data.append(contentsOf: buffer.prefix(min(count, remaining)))
            if count > remaining { truncated = true }
        }
    }
}
