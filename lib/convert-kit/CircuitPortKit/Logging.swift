// CircuitPortKit — the Windows parts Circuit ships with a converted codebase.
// Logging: `Logger`, `os_log`, `OSLog`, `OSLogType` and `OSAllocatedUnfairLock` for
// platforms without Apple's `os` module. Same call shapes; messages go to stderr.
// Compiled only where `os` is missing (or when simulating that on a Mac).
#if !canImport(os) || CIRCUIT_WINDOWS_SIM
import Foundation

public struct OSLogPrivacy: Sendable {
    public enum Mask: Sendable { case hash, none }
    public static let auto = OSLogPrivacy()
    public static let `public` = OSLogPrivacy()
    public static let `private` = OSLogPrivacy()
    public static let sensitive = OSLogPrivacy()
    public static func `private`(mask: Mask) -> OSLogPrivacy { OSLogPrivacy() }
    public static func sensitive(mask: Mask) -> OSLogPrivacy { OSLogPrivacy() }
}

public struct OSLogStringAlignment: Sendable {
    public static let none = OSLogStringAlignment()
    public static func left(columns: @autoclosure @escaping @Sendable () -> Int) -> OSLogStringAlignment { OSLogStringAlignment() }
    public static func right(columns: @autoclosure @escaping @Sendable () -> Int) -> OSLogStringAlignment { OSLogStringAlignment() }
}

public struct OSLogIntegerFormatting: Sendable {
    public static let decimal = OSLogIntegerFormatting()
    public static let hex = OSLogIntegerFormatting()
    public static let octal = OSLogIntegerFormatting()
    public static func decimal(explicitPositiveSign: Bool = false, minDigits: Int = 1) -> OSLogIntegerFormatting { OSLogIntegerFormatting() }
}

public struct OSLogFloatFormatting: Sendable {
    let precision: Int?
    public static let fixed = OSLogFloatFormatting(precision: nil)
    public static func fixed(precision: Int) -> OSLogFloatFormatting { OSLogFloatFormatting(precision: precision) }
    public static let exponential = OSLogFloatFormatting(precision: nil)
    public static let hybrid = OSLogFloatFormatting(precision: nil)
}

public struct OSLogInterpolation: StringInterpolationProtocol {
    var text = ""
    public init(literalCapacity: Int, interpolationCount: Int) { text.reserveCapacity(literalCapacity) }
    public mutating func appendLiteral(_ literal: String) { text += literal }

    public mutating func appendInterpolation(_ value: @autoclosure () -> String, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += value() }
    public mutating func appendInterpolation<T: BinaryInteger>(_ value: @autoclosure () -> T, format: OSLogIntegerFormatting = .decimal, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(value()) }
    public mutating func appendInterpolation(_ value: @autoclosure () -> Double, format: OSLogFloatFormatting = .fixed, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
        let v = value()
        if let p = format.precision { text += String(format: "%.\(p)f", v) } else { text += String(v) }
    }
    public mutating func appendInterpolation(_ value: @autoclosure () -> Float, format: OSLogFloatFormatting = .fixed, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
        let v = Double(value())
        if let p = format.precision { text += String(format: "%.\(p)f", v) } else { text += String(v) }
    }
    public mutating func appendInterpolation(_ value: @autoclosure () -> Bool, privacy: OSLogPrivacy = .auto) { text += String(value()) }
    public mutating func appendInterpolation(_ value: @autoclosure () -> any Error, privacy: OSLogPrivacy = .auto) { text += String(describing: value()) }
    public mutating func appendInterpolation<T>(_ value: @autoclosure () -> T, align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) { text += String(describing: value()) }
}

public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    let text: String
    public init(stringInterpolation: OSLogInterpolation) { text = stringInterpolation.text }
    public init(stringLiteral value: String) { text = value }
}

public struct OSLogType: Equatable, Sendable, RawRepresentable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let `default` = OSLogType(rawValue: 0)
    public static let info = OSLogType(rawValue: 1)
    public static let debug = OSLogType(rawValue: 2)
    public static let error = OSLogType(rawValue: 16)
    public static let fault = OSLogType(rawValue: 17)
    var label: String {
        switch rawValue { case 1: return "info"; case 2: return "debug"; case 16: return "error"; case 17: return "fault"; default: return "log" }
    }
}

public final class OSLog: @unchecked Sendable {
    public let subsystem: String
    public let category: String
    public init(subsystem: String, category: String) { self.subsystem = subsystem; self.category = category }
    public static let `default` = OSLog(subsystem: "", category: "")
    public static let disabled = OSLog(subsystem: "", category: "disabled")
    public func isEnabled(type: OSLogType) -> Bool { self !== OSLog.disabled }
}

enum CircuitLogSink {
    static let lock = NSLock()
    static func write(_ level: String, _ subsystem: String, _ category: String, _ message: String) {
        let scope = subsystem.isEmpty && category.isEmpty ? "" : "[\(subsystem):\(category)] "
        let line = "\(level) \(scope)\(message)\n"
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data(line.utf8))
    }
}

public struct Logger: Sendable {
    let subsystem: String
    let category: String
    public init(subsystem: String, category: String) { self.subsystem = subsystem; self.category = category }
    public init() { subsystem = ""; category = "" }
    public init(_ log: OSLog) { subsystem = log.subsystem; category = log.category }

    public func log(_ message: OSLogMessage) { CircuitLogSink.write("log", subsystem, category, message.text) }
    public func log(level: OSLogType, _ message: OSLogMessage) { CircuitLogSink.write(level.label, subsystem, category, message.text) }
    public func trace(_ message: OSLogMessage) { CircuitLogSink.write("trace", subsystem, category, message.text) }
    public func debug(_ message: OSLogMessage) { CircuitLogSink.write("debug", subsystem, category, message.text) }
    public func info(_ message: OSLogMessage) { CircuitLogSink.write("info", subsystem, category, message.text) }
    public func notice(_ message: OSLogMessage) { CircuitLogSink.write("notice", subsystem, category, message.text) }
    public func warning(_ message: OSLogMessage) { CircuitLogSink.write("warning", subsystem, category, message.text) }
    public func error(_ message: OSLogMessage) { CircuitLogSink.write("error", subsystem, category, message.text) }
    public func critical(_ message: OSLogMessage) { CircuitLogSink.write("critical", subsystem, category, message.text) }
    public func fault(_ message: OSLogMessage) { CircuitLogSink.write("fault", subsystem, category, message.text) }
}

private func circuitFormat(_ format: StaticString, _ args: [CVarArg]) -> String {
    // os_log uses %{public}@-style specifiers; String(format:) only knows %@.
    let raw = format.withUTF8Buffer { String(decoding: $0, as: UTF8.self) }
    var cleaned = ""
    var i = raw.startIndex
    while i < raw.endIndex {
        if raw[i] == "%", let open = raw.index(i, offsetBy: 1, limitedBy: raw.endIndex), open < raw.endIndex, raw[open] == "{",
           let close = raw[open...].firstIndex(of: "}") {
            cleaned.append("%")
            i = raw.index(after: close)
        } else {
            cleaned.append(raw[i])
            i = raw.index(after: i)
        }
    }
    return withVaList(args) { NSString(format: cleaned, arguments: $0) as String }
}

public func os_log(_ message: StaticString, log: OSLog = .default, type: OSLogType = .default, _ args: CVarArg...) {
    guard log !== OSLog.disabled else { return }
    CircuitLogSink.write(type.label, log.subsystem, log.category, circuitFormat(message, args))
}

public func os_log(_ type: OSLogType, log: OSLog = .default, _ message: StaticString, _ args: CVarArg...) {
    guard log !== OSLog.disabled else { return }
    CircuitLogSink.write(type.label, log.subsystem, log.category, circuitFormat(message, args))
}

/// `OSAllocatedUnfairLock` over NSLock: the same API, portable.
public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let guardLock = NSLock()
    private var state: State
    public init(initialState: State) { state = initialState }
    public init(uncheckedState: State) { state = uncheckedState }
    @discardableResult
    public func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
        guardLock.lock(); defer { guardLock.unlock() }
        return try body(&state)
    }
    @discardableResult
    public func withLockUnchecked<R>(_ body: (inout State) throws -> R) rethrows -> R {
        guardLock.lock(); defer { guardLock.unlock() }
        return try body(&state)
    }
}

extension OSAllocatedUnfairLock where State == Void {
    public convenience init() { self.init(initialState: ()) }
    public func lock() { guardLock.lock() }
    public func unlock() { guardLock.unlock() }
    @discardableResult
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        guardLock.lock(); defer { guardLock.unlock() }
        return try body()
    }
}
#endif
