// CircuitPortKit — SwiftUI's Image(systemName:) on SwiftCrossUI: the SF Symbol's counterpart from
// Microsoft's Fluent UI System Icons (MIT), drawn as a vector shape. Like an SF Symbol it takes the
// view's foreground color and scales with the font, or with the frame once resizable.
//
// A converted app's `Image` refers to CircuitImage (a module-level alias Circuit generates wherever
// SwiftCrossUI stands in for SwiftUI). A symbol name the table does not know draws nothing and is
// logged once; lib/convert-kit/tools/sf-symbols-to-fluent.json is where it gets added.
#if canImport(SwiftCrossUI) && (!canImport(SwiftUI) || CIRCUIT_WINDOWS_SIM)
import Foundation
@_spi(Backends) import SwiftCrossUI

/// A Fluent icon path as a SwiftCrossUI shape (20×20 design grid, fitted into the bounds).
public struct CircuitSymbolShape: SwiftCrossUI.Shape {
    let pathData: String
    let evenOdd: Bool

    public func path(in bounds: SwiftCrossUI.Path.Rect) -> SwiftCrossUI.Path {
        let scale = min(bounds.width, bounds.height) / 20
        let origin = SIMD2(bounds.x + (bounds.width - 20 * scale) / 2, bounds.y + (bounds.height - 20 * scale) / 2)
        return CircuitSVGPath.build(pathData, scale: scale, origin: origin).fillRule(evenOdd ? .evenOdd : .winding)
    }
}

/// SVG path data (M L H V C S Q T Z, absolute and relative) → SwiftCrossUI path.
enum CircuitSVGPath {
    static func build(_ d: String, scale: Double, origin: SIMD2<Double>) -> SwiftCrossUI.Path {
        var path = SwiftCrossUI.Path()
        var tokens = Tokens(d)
        var current = SIMD2<Double>(0, 0), start = current
        var lastControl: SIMD2<Double>? = nil, lastQuad: SIMD2<Double>? = nil
        var command: Character = "M"
        func point(_ p: SIMD2<Double>) -> SIMD2<Double> { origin + p * scale }
        while let next = tokens.next(currentCommand: command) {
            command = next
            let relative = command.isLowercase
            let base = relative ? current : SIMD2(0, 0)
            switch command {
            case "M", "m":
                guard let p = tokens.pair() else { return path }
                current = base + p; start = current
                path = path.move(to: point(current))
                command = relative ? "l" : "L" // further pairs are implicit line-tos
                lastControl = nil; lastQuad = nil
            case "L", "l":
                guard let p = tokens.pair() else { return path }
                current = base + p
                path = path.addLine(to: point(current)); lastControl = nil; lastQuad = nil
            case "H", "h":
                guard let x = tokens.number() else { return path }
                current = SIMD2(relative ? current.x + x : x, current.y)
                path = path.addLine(to: point(current)); lastControl = nil; lastQuad = nil
            case "V", "v":
                guard let y = tokens.number() else { return path }
                current = SIMD2(current.x, relative ? current.y + y : y)
                path = path.addLine(to: point(current)); lastControl = nil; lastQuad = nil
            case "C", "c":
                guard let c1 = tokens.pair(), let c2 = tokens.pair(), let e = tokens.pair() else { return path }
                path = path.addCubicCurve(control1: point(base + c1), control2: point(base + c2), to: point(base + e))
                lastControl = base + c2; current = base + e; lastQuad = nil
            case "S", "s":
                guard let c2 = tokens.pair(), let e = tokens.pair() else { return path }
                let c1 = lastControl.map { 2 * current - $0 } ?? current
                path = path.addCubicCurve(control1: point(c1), control2: point(base + c2), to: point(base + e))
                lastControl = base + c2; current = base + e; lastQuad = nil
            case "Q", "q":
                guard let c = tokens.pair(), let e = tokens.pair() else { return path }
                path = path.addQuadCurve(control: point(base + c), to: point(base + e))
                lastQuad = base + c; current = base + e; lastControl = nil
            case "T", "t":
                guard let e = tokens.pair() else { return path }
                let c = lastQuad.map { 2 * current - $0 } ?? current
                path = path.addQuadCurve(control: point(c), to: point(base + e))
                lastQuad = c; current = base + e; lastControl = nil
            case "Z", "z":
                path = path.addLine(to: point(start))
                current = start; lastControl = nil; lastQuad = nil
            default:
                return path
            }
        }
        return path
    }

    /// Reads commands and numbers from SVG path data ("M10 2C14.4 2 18 5.58…", "1e-05", "-.5.5").
    struct Tokens {
        let bytes: [UInt8]
        var i = 0
        init(_ s: String) { bytes = Array(s.utf8) }

        mutating func skipSeparators() {
            while i < bytes.count, bytes[i] == 32 || bytes[i] == 44 || bytes[i] == 10 || bytes[i] == 13 || bytes[i] == 9 { i += 1 }
        }
        /// The next command letter, or the current one again when numbers follow (implicit repeat).
        mutating func next(currentCommand: Character) -> Character? {
            skipSeparators()
            guard i < bytes.count else { return nil }
            let b = bytes[i]
            if (b >= 65 && b <= 90) || (b >= 97 && b <= 122), b != 101, b != 69 {
                i += 1
                return Character(Unicode.Scalar(b))
            }
            return currentCommand == "Z" || currentCommand == "z" ? nil : currentCommand
        }
        mutating func number() -> Double? {
            skipSeparators()
            let s = i
            if i < bytes.count, bytes[i] == 43 || bytes[i] == 45 { i += 1 }
            var sawDot = false
            while i < bytes.count {
                let b = bytes[i]
                if b >= 48 && b <= 57 { i += 1 }
                else if b == 46, !sawDot { sawDot = true; i += 1 }
                else if b == 101 || b == 69 {
                    i += 1
                    if i < bytes.count, bytes[i] == 43 || bytes[i] == 45 { i += 1 }
                } else { break }
            }
            guard i > s else { return nil }
            return Double(String(decoding: bytes[s..<i], as: UTF8.self))
        }
        mutating func pair() -> SIMD2<Double>? {
            guard let x = number(), let y = number() else { return nil }
            return SIMD2(x, y)
        }
    }
}

/// SwiftUI's `Image` where SwiftCrossUI stands in for it. Covers what converted apps build with:
/// SF Symbols (as Fluent vector icons). Other image sources are added as Convert learns to carry
/// the app's image assets into the package.
public struct CircuitImage: SwiftCrossUI.View {
    enum Source { case symbol(String) }
    let source: Source
    var resizable = false

    @SwiftCrossUI.Environment(\.font) var font
    @SwiftCrossUI.Environment(\.fontResolutionContext) var fontContext

    public init(systemName: String) { source = .symbol(systemName) }

    public func resizable(capInsets: CircuitEdgeInsets = CircuitEdgeInsets(), resizingMode: CircuitImageResizingMode = .stretch) -> CircuitImage {
        var copy = self
        copy.resizable = true
        return copy
    }
    /// Symbols always draw in the foreground color (SF Symbols' template rendering).
    public func renderingMode(_ mode: CircuitImageTemplateRenderingMode?) -> CircuitImage { self }
    /// Fluent icons are single-color: every symbol rendering mode draws in the foreground color.
    public func symbolRenderingMode(_ mode: CircuitSymbolRenderingMode?) -> CircuitImage { self }

    public var body: some SwiftCrossUI.View {
        switch source {
        case .symbol(let name):
            if let data = CircuitSymbolPaths.paths[name] {
                let shape = CircuitSymbolShape(pathData: data, evenOdd: CircuitSymbolPaths.evenOdd.contains(name))
                if resizable {
                    shape
                } else {
                    // An SF Symbol is about 1.2× the point size of the font it sits in.
                    let side = (font.resolve(in: fontContext).pointSize * 1.2).rounded()
                    shape.frame(width: side, height: side)
                }
            } else {
                let _ = CircuitSymbolLog.missing(name)
                SwiftCrossUI.EmptyView()
            }
        }
    }
}

/// SwiftUI's argument types for the Image modifiers above.
public struct CircuitEdgeInsets { public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {} }
public enum CircuitImageResizingMode { case tile, stretch }
public enum CircuitImageTemplateRenderingMode { case template, original }
public enum CircuitSymbolRenderingMode {
    case monochrome, multicolor, hierarchical, palette
}

enum CircuitSymbolLog {
    private static let seen = CircuitSymbolSeen()
    static func missing(_ name: String) {
        guard seen.insert(name) else { return }
        FileHandle.standardError.write(Data("[CircuitPortKit] no Windows icon for SF Symbol \"\(name)\" (add it to sf-symbols-to-fluent.json)\n".utf8))
    }
}

final class CircuitSymbolSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var names = Set<String>()
    func insert(_ name: String) -> Bool { lock.lock(); defer { lock.unlock() }; return names.insert(name).inserted }
}
#endif
