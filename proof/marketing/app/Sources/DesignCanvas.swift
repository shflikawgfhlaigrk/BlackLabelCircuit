// Black Label Marketing — Design Canvas model + store.
//
// The freeform drag-and-drop design editor's document model: a DesignDocument is a named,
// fixed-pixel-size canvas holding layered elements (text, shapes, the buyer's own images, the
// brand-kit logo). Everything is Codable with decodeIfPresent evolution (a document saved by an
// older build always loads), persisted as ONE blob in the app-support SQLite workspace exactly
// like Prefs (WorkspaceDatabase blob + legacy-JSON fallback, demo-isolated).
//
// Bindings: §5.1 zero fabrication — the store starts EMPTY, elements only ever contain what the
// buyer typed/imported (their own images, their own brand kit). No stock assets, no seeded docs.
import Foundation
#if canImport(CoreGraphics) && !CIRCUIT_WINDOWS_SIM
import CoreGraphics
#endif
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

// MARK: - Canvas format (the fixed pixel size a document renders at)

/// A named canvas size in EXACT pixels. Presets cover the major social placements; `custom`
/// builds any WxH the buyer types. Value type + Codable so it lives inside the document.
struct DesignFormat: Codable, Equatable, Hashable, Identifiable {
    var name: String
    var width: Int
    var height: Int

    var id: String { "\(name)-\(width)x\(height)" }
    var pixelSize: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
    var label: String { "\(name) · \(width)×\(height)" }
    var aspect: CGFloat { height == 0 ? 1 : CGFloat(width) / CGFloat(height) }
    /// Filename-safe suffix for multi-format export ("ig-post-1080x1080").
    var fileSuffix: String {
        let slug = name.lowercased()
            .map { ch -> Character in (ch.isLetter || ch.isNumber) ? ch : "-" }
        let collapsed = String(slug).split(separator: "-").joined(separator: "-")
        return "\(collapsed)-\(width)x\(height)"
    }

    static let igPost       = DesignFormat(name: "IG Post", width: 1080, height: 1080)
    static let igStory      = DesignFormat(name: "IG Story", width: 1080, height: 1920)
    static let xPost        = DesignFormat(name: "X Post", width: 1600, height: 900)
    static let linkedInPost = DesignFormat(name: "LinkedIn", width: 1200, height: 627)
    static let fbCover      = DesignFormat(name: "FB Cover", width: 1640, height: 859)
    static let youtubeThumb = DesignFormat(name: "YouTube Thumb", width: 1280, height: 720)

    /// The preset placements "Resize for all formats" re-renders into.
    static let presets: [DesignFormat] = [igPost, igStory, xPost, linkedInPost, fbCover, youtubeThumb]

    /// Any WxH the buyer types, clamped to sane render bounds.
    static func custom(width: Int, height: Int) -> DesignFormat {
        DesignFormat(name: "Custom",
                     width: min(max(width, 64), 8192),
                     height: min(max(height, 64), 8192))
    }

    // Evolution-safe decoding (a future field never breaks an old document).
    private enum CodingKeys: String, CodingKey { case name, width, height }
    init(name: String, width: Int, height: Int) { self.name = name; self.width = width; self.height = height }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Custom"
        width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 1080
        height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1080
    }
}

// MARK: - Element attribute enums

enum DesignShapeKind: String, Codable, CaseIterable, Identifiable {
    case rectangle = "Rectangle", rounded = "Rounded", ellipse = "Ellipse", line = "Line"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .rectangle: return "square"
        case .rounded:   return "square.fill.on.square"
        case .ellipse:   return "circle"
        case .line:      return "minus"
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum DesignTextAlignment: String, Codable, CaseIterable, Identifiable {
    case leading = "Left", center = "Center", trailing = "Right"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .leading: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .trailing: return "text.alignright"
        }
    }
    var textAlignment: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum DesignFontWeight: String, Codable, CaseIterable, Identifiable {
    case regular = "Regular", medium = "Medium", semibold = "Semibold", bold = "Bold", heavy = "Heavy"
    var id: String { rawValue }
    var fontWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        }
    }
    /// CoreText weight trait (-1…1) so the pixel-exact exporter matches the on-screen weight.
    var ctWeight: CGFloat {
        switch self {
        case .regular: return 0.0
        case .medium: return 0.23
        case .semibold: return 0.30
        case .bold: return 0.40
        case .heavy: return 0.56
        }
    }
}
#endif // circuit-convert

enum DesignElementKind: String, Codable {
    case text, shape, image, logo
    var label: String {
        switch self {
        case .text: return "Text"
        case .shape: return "Shape"
        case .image: return "Image"
        case .logo: return "Brand logo"
        }
    }
}

// MARK: - Element

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// One layer on the canvas. A flat struct (not an enum) so every field decodes with
/// decodeIfPresent — an old document with new fields, or a new document missing old ones,
/// always loads with sensible defaults. Frames are in DOCUMENT PIXEL coordinates, top-left origin.
struct DesignElement: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: DesignElementKind = .shape
    var frame = CGRect(x: 0, y: 0, width: 200, height: 200)
    var rotation: Double = 0          // degrees, clockwise (matches SwiftUI rotationEffect)
    var zIndex: Int = 0
    var opacity: Double = 1
    var locked: Bool = false

    // Text attributes
    var text: String = ""
    var fontFamily: String = ""       // "" → the system font (never a fabricated licensed font)
    var fontSize: Double = 64
    var fontWeight: DesignFontWeight = .semibold
    var textColorHex: UInt32 = 0xEDEDED
    var alignment: DesignTextAlignment = .center

    // Shape attributes
    var shape: DesignShapeKind = .rectangle
    var fillHex: UInt32 = 0xD9B65C
    var fillEnabled: Bool = true
    var strokeHex: UInt32 = 0xEDEDED
    var strokeWidth: Double = 0

    // Image / logo attributes — the buyer's OWN pixels, embedded so the document is
    // self-contained; the original file's security-scoped bookmark is kept for provenance.
    var imageData: Data? = nil
    var imageBookmark: Data? = nil
    var cornerRadius: Double = 0
    /// Non-destructive crop / flip / grade applied at render time. The bytes above are never
    /// rewritten by it, so every adjustment is reversible (see DesignPhotoEdit.swift).
    var photo = DesignPhotoEdit()

    private enum CodingKeys: String, CodingKey {
        case id, kind, frame, rotation, zIndex, opacity, locked
        case text, fontFamily, fontSize, fontWeight, textColorHex, alignment
        case shape, fillHex, fillEnabled, strokeHex, strokeWidth
        case imageData, imageBookmark, cornerRadius, photo
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(DesignElementKind.self, forKey: .kind) ?? .shape
        frame = try c.decodeIfPresent(CGRect.self, forKey: .frame) ?? CGRect(x: 0, y: 0, width: 200, height: 200)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? ""
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 64
        fontWeight = try c.decodeIfPresent(DesignFontWeight.self, forKey: .fontWeight) ?? .semibold
        textColorHex = try c.decodeIfPresent(UInt32.self, forKey: .textColorHex) ?? 0xEDEDED
        alignment = try c.decodeIfPresent(DesignTextAlignment.self, forKey: .alignment) ?? .center
        shape = try c.decodeIfPresent(DesignShapeKind.self, forKey: .shape) ?? .rectangle
        fillHex = try c.decodeIfPresent(UInt32.self, forKey: .fillHex) ?? 0xD9B65C
        fillEnabled = try c.decodeIfPresent(Bool.self, forKey: .fillEnabled) ?? true
        strokeHex = try c.decodeIfPresent(UInt32.self, forKey: .strokeHex) ?? 0xEDEDED
        strokeWidth = try c.decodeIfPresent(Double.self, forKey: .strokeWidth) ?? 0
        imageData = try c.decodeIfPresent(Data.self, forKey: .imageData)
        imageBookmark = try c.decodeIfPresent(Data.self, forKey: .imageBookmark)
        cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 0
        photo = try c.decodeIfPresent(DesignPhotoEdit.self, forKey: .photo) ?? DesignPhotoEdit()
    }

    // MARK: factories (each centers a sensibly sized layer on the given canvas)

    static func text(_ string: String, on format: DesignFormat, accentHex: UInt32) -> DesignElement {
        var e = DesignElement()
        e.kind = .text
        e.text = string
        e.fontSize = Double(max(28, min(format.width, format.height) / 9))
        e.textColorHex = 0xEDEDED
        let w = CGFloat(format.width) * 0.8
        let h = CGFloat(e.fontSize) * 2.4
        e.frame = CGRect(x: (CGFloat(format.width) - w) / 2, y: (CGFloat(format.height) - h) / 2, width: w, height: h)
        _ = accentHex   // text starts neutral; the accent is one tap away in the inspector palette
        return e
    }

    static func shape(_ kind: DesignShapeKind, on format: DesignFormat, accentHex: UInt32) -> DesignElement {
        var e = DesignElement()
        e.kind = .shape
        e.shape = kind
        e.fillHex = accentHex
        let side = CGFloat(min(format.width, format.height)) * 0.35
        var size = CGSize(width: side, height: side)
        if kind == .line { size = CGSize(width: CGFloat(format.width) * 0.5, height: max(4, side * 0.04)) }
        if kind == .rounded { e.cornerRadius = Double(side * 0.12) }
        e.frame = CGRect(x: (CGFloat(format.width) - size.width) / 2,
                         y: (CGFloat(format.height) - size.height) / 2,
                         width: size.width, height: size.height)
        return e
    }

    static func image(data: Data, pixelWidth: Int, pixelHeight: Int, on format: DesignFormat,
                      bookmark: Data? = nil, asLogo: Bool = false) -> DesignElement {
        var e = DesignElement()
        e.kind = asLogo ? .logo : .image
        e.imageData = data
        e.imageBookmark = bookmark
        // Fit the image into ~60% of the canvas (30% for a logo) at its true aspect.
        let maxW = CGFloat(format.width) * (asLogo ? 0.3 : 0.6)
        let maxH = CGFloat(format.height) * (asLogo ? 0.3 : 0.6)
        let iw = CGFloat(max(1, pixelWidth)), ih = CGFloat(max(1, pixelHeight))
        let s = min(maxW / iw, maxH / ih)
        let size = CGSize(width: iw * s, height: ih * s)
        e.frame = CGRect(x: (CGFloat(format.width) - size.width) / 2,
                         y: (CGFloat(format.height) - size.height) / 2,
                         width: size.width, height: size.height)
        return e
    }
}
#endif // circuit-convert

// MARK: - Background

struct DesignBackground: Codable, Equatable {
    var colorHex: UInt32 = 0x0B0B0D
    var transparent: Bool = false

    private enum CodingKeys: String, CodingKey { case colorHex, transparent }
    init() {}
    init(colorHex: UInt32, transparent: Bool = false) { self.colorHex = colorHex; self.transparent = transparent }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colorHex = try c.decodeIfPresent(UInt32.self, forKey: .colorHex) ?? 0x0B0B0D
        transparent = try c.decodeIfPresent(Bool.self, forKey: .transparent) ?? false
    }
}

// MARK: - Document

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct DesignDocument: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String = "Untitled design"
    var format: DesignFormat = .igPost
    var elements: [DesignElement] = []
    var background = DesignBackground()
    var created = Date()
    var updated = Date()

    var pixelSize: CGSize { format.pixelSize }
    /// Paint order: back → front.
    var sortedElements: [DesignElement] { elements.sorted { $0.zIndex < $1.zIndex } }
    var maxZ: Int { elements.map { $0.zIndex }.max() ?? 0 }
    var minZ: Int { elements.map { $0.zIndex }.min() ?? 0 }

    private enum CodingKeys: String, CodingKey { case id, name, format, elements, background, created, updated }
    init() {}
    init(name: String, format: DesignFormat) { self.name = name; self.format = format }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled design"
        format = try c.decodeIfPresent(DesignFormat.self, forKey: .format) ?? .igPost
        elements = try c.decodeIfPresent([DesignElement].self, forKey: .elements) ?? []
        background = try c.decodeIfPresent(DesignBackground.self, forKey: .background) ?? DesignBackground()
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        updated = try c.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
    }

    // MARK: element helpers (all pure mutations; the screen owns undo snapshots)

    func element(_ id: UUID?) -> DesignElement? { elements.first { $0.id == id } }

    mutating func upsert(_ element: DesignElement) {
        if let i = elements.firstIndex(where: { $0.id == element.id }) { elements[i] = element }
        else { elements.append(element) }
        updated = Date()
    }

    mutating func add(_ element: DesignElement) {
        var e = element
        e.zIndex = maxZ + 1
        elements.append(e)
        updated = Date()
    }

    mutating func remove(_ id: UUID) {
        elements.removeAll { $0.id == id }
        updated = Date()
    }

    /// Duplicate a layer slightly offset, on top. Returns the copy's id for selection.
    @discardableResult
    mutating func duplicate(_ id: UUID) -> UUID? {
        guard var copy = element(id) else { return nil }
        copy.id = UUID()
        copy.zIndex = maxZ + 1
        copy.frame.origin.x += 24
        copy.frame.origin.y += 24
        elements.append(copy)
        updated = Date()
        return copy.id
    }

    mutating func bringToFront(_ id: UUID) {
        guard let i = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[i].zIndex = maxZ + 1
        normalizeZ()
    }
    mutating func sendToBack(_ id: UUID) {
        guard let i = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[i].zIndex = minZ - 1
        normalizeZ()
    }
    mutating func bringForward(_ id: UUID) { swapZ(id, direction: 1) }
    mutating func sendBackward(_ id: UUID) { swapZ(id, direction: -1) }

    private mutating func swapZ(_ id: UUID, direction: Int) {
        normalizeZ()
        let ordered = sortedElements
        guard let pos = ordered.firstIndex(where: { $0.id == id }) else { return }
        let target = pos + direction
        guard target >= 0, target < ordered.count else { return }
        let otherID = ordered[target].id
        guard let a = elements.firstIndex(where: { $0.id == id }),
              let b = elements.firstIndex(where: { $0.id == otherID }) else { return }
        let z = elements[a].zIndex
        elements[a].zIndex = elements[b].zIndex
        elements[b].zIndex = z
        updated = Date()
    }

    /// Re-pack z indices to 0…n-1 preserving order (keeps swaps well-defined forever).
    mutating func normalizeZ() {
        let ordered = sortedElements
        for (i, e) in ordered.enumerated() {
            if let idx = elements.firstIndex(where: { $0.id == e.id }) { elements[idx].zIndex = i }
        }
    }
}
#endif // circuit-convert

// MARK: - Store (SQLite workspace blob, same discipline as Prefs)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
final class DesignDocumentStore: ObservableObject {
    static let blobName = "designDocuments"

    @Published var documents: [DesignDocument] = [] { didSet { scheduleSave() } }

    private var database: WorkspaceDatabase
    private var legacyURL: URL
    private var loading = false
    private var pendingSave: DispatchWorkItem?

    /// Legacy JSON file used only as a write-fallback / migration source (mirrors Prefs).
    private static func legacyStoreURL(demo: Bool) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelMarketing", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(demo ? "designs-demo.json" : "designs.json")
    }

    init() {
        database = WorkspaceDatabase(demo: DemoMode.active)
        legacyURL = Self.legacyStoreURL(demo: DemoMode.active)
        load()
    }

    private func load() {
        loading = true
        defer { loading = false }
        if let data = try? database.readBlob(named: Self.blobName),
           let docs = try? JSONDecoder().decode([DesignDocument].self, from: data) {
            documents = docs
            return
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let docs = try? JSONDecoder().decode([DesignDocument].self, from: data) else { return }
        documents = docs
        try? database.writeBlob(data, named: Self.blobName)
    }

    /// Documents can carry multi-MB image layers, so unlike Prefs the save is DEBOUNCED —
    /// continuous inspector edits (sliders, typing) coalesce into one blob write ~0.4s after the
    /// last change. `flush()` (called when the editor closes) writes immediately.
    private func scheduleSave() {
        guard !loading else { return }
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
    }

    private func saveNow() {
        guard let data = try? JSONEncoder().encode(documents) else { return }
        do {
            try database.writeBlob(data, named: Self.blobName)
        } catch {
            try? data.write(to: legacyURL, options: .atomic)
        }
    }

    // MARK: CRUD

    func document(_ id: UUID?) -> DesignDocument? { documents.first { $0.id == id } }

    @discardableResult
    func create(format: DesignFormat, name: String = "") -> DesignDocument {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let doc = DesignDocument(name: trimmed.isEmpty ? "Design \(documents.count + 1)" : trimmed,
                                 format: format)
        documents.insert(doc, at: 0)
        return doc
    }

    /// Replace the stored copy of a document (stamps `updated`).
    func update(_ doc: DesignDocument) {
        guard let i = documents.firstIndex(where: { $0.id == doc.id }) else { return }
        var d = doc
        d.updated = Date()
        documents[i] = d
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = documents.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        documents[i].name = trimmed
        documents[i].updated = Date()
    }

    @discardableResult
    func duplicate(_ id: UUID) -> DesignDocument? {
        guard let src = document(id) else { return nil }
        var copy = src
        copy.id = UUID()
        copy.name = src.name + " copy"
        copy.created = Date()
        copy.updated = Date()
        // Fresh element ids so the copy is fully independent of the original.
        copy.elements = src.elements.map { e in var n = e; n.id = UUID(); return n }
        documents.insert(copy, at: 0)
        return copy
    }

    func delete(_ id: UUID) { documents.removeAll { $0.id == id } }
}
#endif // circuit-convert
