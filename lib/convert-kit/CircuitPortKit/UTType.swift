// CircuitPortKit — `UTType` for platforms without UniformTypeIdentifiers.
// Windows identifies files by extension and MIME type, so this carries exactly that:
// the identifiers, extensions, MIME types and conformance tree of the common types.
#if !canImport(UniformTypeIdentifiers) || CIRCUIT_WINDOWS_SIM
import Foundation

public struct UTType: Hashable, Sendable, CustomStringConvertible {
    public let identifier: String
    public let preferredFilenameExtension: String?
    public let preferredMIMEType: String?
    let parents: [String]

    init(id identifier: String, ext: String? = nil, mime: String? = nil, parents: [String] = []) {
        self.identifier = identifier
        self.preferredFilenameExtension = ext
        self.preferredMIMEType = mime
        self.parents = parents
    }

    public var description: String { identifier }
    public var localizedDescription: String? { preferredFilenameExtension.map { "\($0.uppercased()) file" } }
    public static func == (a: UTType, b: UTType) -> Bool { a.identifier == b.identifier }
    public func hash(into hasher: inout Hasher) { hasher.combine(identifier) }

    public init?(_ identifier: String) {
        guard let t = UTType.table.first(where: { $0.identifier == identifier }) else { return nil }
        self = t
    }

    public init?(filenameExtension: String, conformingTo supertype: UTType = .data) {
        let e = filenameExtension.lowercased()
        guard let t = UTType.table.first(where: { $0.preferredFilenameExtension == e || UTType.aliases[$0.identifier]?.contains(e) == true }) else { return nil }
        self = t
    }

    public init?(mimeType: String, conformingTo supertype: UTType = .data) {
        guard let t = UTType.table.first(where: { $0.preferredMIMEType == mimeType.lowercased() }) else { return nil }
        self = t
    }

    /// A type the table does not know: keeps the identifier, conforms to `.data`.
    public init(exportedAs identifier: String, conformingTo parent: UTType? = nil) {
        self.init(id: identifier, parents: [parent?.identifier ?? "public.data"])
    }
    public init(importedAs identifier: String, conformingTo parent: UTType? = nil) {
        self.init(id: identifier, parents: [parent?.identifier ?? "public.data"])
    }

    public func conforms(to other: UTType) -> Bool {
        if identifier == other.identifier { return true }
        var seen = Set<String>()
        var queue = parents
        while let next = queue.popLast() {
            if next == other.identifier { return true }
            guard seen.insert(next).inserted, let t = UTType.table.first(where: { $0.identifier == next }) else { continue }
            queue.append(contentsOf: t.parents)
        }
        return false
    }
    public func isSubtype(of other: UTType) -> Bool { self != other && conforms(to: other) }
    public func isSupertype(of other: UTType) -> Bool { other.isSubtype(of: self) }

    public static let item = UTType(id: "public.item")
    public static let content = UTType(id: "public.content", parents: ["public.item"])
    public static let data = UTType(id: "public.data", parents: ["public.item"])
    public static let directory = UTType(id: "public.directory", parents: ["public.item"])
    public static let folder = UTType(id: "public.folder", parents: ["public.directory"])
    public static let fileURL = UTType(id: "public.file-url", parents: ["public.url"])
    public static let url = UTType(id: "public.url", parents: ["public.data"])
    public static let text = UTType(id: "public.text", parents: ["public.data", "public.content"])
    public static let plainText = UTType(id: "public.plain-text", ext: "txt", mime: "text/plain", parents: ["public.text"])
    public static let utf8PlainText = UTType(id: "public.utf8-plain-text", ext: "txt", mime: "text/plain", parents: ["public.plain-text"])
    public static let rtf = UTType(id: "public.rtf", ext: "rtf", mime: "text/rtf", parents: ["public.text"])
    public static let html = UTType(id: "public.html", ext: "html", mime: "text/html", parents: ["public.text"])
    public static let xml = UTType(id: "public.xml", ext: "xml", mime: "application/xml", parents: ["public.text"])
    public static let yaml = UTType(id: "public.yaml", ext: "yml", mime: "application/x-yaml", parents: ["public.text"])
    public static let json = UTType(id: "public.json", ext: "json", mime: "application/json", parents: ["public.text"])
    public static let commaSeparatedText = UTType(id: "public.comma-separated-values-text", ext: "csv", mime: "text/csv", parents: ["public.text"])
    public static let tabSeparatedText = UTType(id: "public.tab-separated-values-text", ext: "tsv", mime: "text/tab-separated-values", parents: ["public.text"])
    public static let sourceCode = UTType(id: "public.source-code", parents: ["public.plain-text"])
    public static let swiftSource = UTType(id: "public.swift-source", ext: "swift", parents: ["public.source-code"])
    public static let pythonScript = UTType(id: "public.python-script", ext: "py", mime: "text/x-python-script", parents: ["public.source-code"])
    public static let javaScript = UTType(id: "com.netscape.javascript-source", ext: "js", mime: "text/javascript", parents: ["public.source-code"])
    public static let shellScript = UTType(id: "public.shell-script", ext: "sh", parents: ["public.source-code"])
    public static let propertyList = UTType(id: "com.apple.property-list", ext: "plist", parents: ["public.data"])
    public static let pdf = UTType(id: "com.adobe.pdf", ext: "pdf", mime: "application/pdf", parents: ["public.data", "public.content"])
    public static let image = UTType(id: "public.image", parents: ["public.data", "public.content"])
    public static let png = UTType(id: "public.png", ext: "png", mime: "image/png", parents: ["public.image"])
    public static let jpeg = UTType(id: "public.jpeg", ext: "jpeg", mime: "image/jpeg", parents: ["public.image"])
    public static let gif = UTType(id: "com.compuserve.gif", ext: "gif", mime: "image/gif", parents: ["public.image"])
    public static let tiff = UTType(id: "public.tiff", ext: "tiff", mime: "image/tiff", parents: ["public.image"])
    public static let bmp = UTType(id: "com.microsoft.bmp", ext: "bmp", mime: "image/bmp", parents: ["public.image"])
    public static let ico = UTType(id: "com.microsoft.ico", ext: "ico", mime: "image/vnd.microsoft.icon", parents: ["public.image"])
    public static let svg = UTType(id: "public.svg-image", ext: "svg", mime: "image/svg+xml", parents: ["public.image"])
    public static let heic = UTType(id: "public.heic", ext: "heic", mime: "image/heic", parents: ["public.image"])
    public static let webP = UTType(id: "org.webmproject.webp", ext: "webp", mime: "image/webp", parents: ["public.image"])
    public static let audiovisualContent = UTType(id: "public.audiovisual-content", parents: ["public.data", "public.content"])
    public static let movie = UTType(id: "public.movie", parents: ["public.audiovisual-content"])
    public static let video = UTType(id: "public.video", parents: ["public.movie"])
    public static let audio = UTType(id: "public.audio", parents: ["public.audiovisual-content"])
    public static let quickTimeMovie = UTType(id: "com.apple.quicktime-movie", ext: "mov", mime: "video/quicktime", parents: ["public.movie"])
    public static let mpeg4Movie = UTType(id: "public.mpeg-4", ext: "mp4", mime: "video/mp4", parents: ["public.movie"])
    public static let mpeg4Audio = UTType(id: "public.mpeg-4-audio", ext: "m4a", mime: "audio/mp4", parents: ["public.audio"])
    public static let mp3 = UTType(id: "public.mp3", ext: "mp3", mime: "audio/mpeg", parents: ["public.audio"])
    public static let wav = UTType(id: "com.microsoft.waveform-audio", ext: "wav", mime: "audio/wav", parents: ["public.audio"])
    public static let aiff = UTType(id: "public.aiff-audio", ext: "aiff", mime: "audio/aiff", parents: ["public.audio"])
    public static let midi = UTType(id: "public.midi-audio", ext: "mid", mime: "audio/midi", parents: ["public.audio"])
    public static let archive = UTType(id: "public.archive", parents: ["public.data"])
    public static let zip = UTType(id: "public.zip-archive", ext: "zip", mime: "application/zip", parents: ["public.archive"])
    public static let gzip = UTType(id: "org.gnu.gnu-zip-archive", ext: "gz", mime: "application/gzip", parents: ["public.archive"])
    public static let diskImage = UTType(id: "public.disk-image", ext: "dmg", parents: ["public.archive"])
    public static let executable = UTType(id: "public.executable", parents: ["public.data"])
    public static let exe = UTType(id: "com.microsoft.windows-executable", ext: "exe", mime: "application/vnd.microsoft.portable-executable", parents: ["public.executable"])
    public static let application = UTType(id: "com.apple.application", parents: ["public.executable"])
    public static let applicationBundle = UTType(id: "com.apple.application-bundle", ext: "app", parents: ["com.apple.application"])
    public static let database = UTType(id: "public.database", parents: ["public.data"])
    public static let spreadsheet = UTType(id: "public.spreadsheet", parents: ["public.content"])
    public static let presentation = UTType(id: "public.presentation", parents: ["public.content"])
    public static let font = UTType(id: "public.font", parents: ["public.data"])
    public static let log = UTType(id: "com.apple.log", ext: "log", parents: ["public.plain-text"])
    public static let epub = UTType(id: "org.idpf.epub-container", ext: "epub", mime: "application/epub+zip", parents: ["public.data"])

    static let aliases: [String: [String]] = [
        "public.jpeg": ["jpg", "jpe"], "public.tiff": ["tif"], "public.html": ["htm"], "public.yaml": ["yaml"],
        "public.aiff-audio": ["aif"], "public.midi-audio": ["midi"], "public.plain-text": ["text"], "public.mpeg-4": ["m4v"],
    ]

    static let table: [UTType] = [
        .item, .content, .data, .directory, .folder, .fileURL, .url, .text, .plainText, .utf8PlainText, .rtf, .html, .xml, .yaml,
        .json, .commaSeparatedText, .tabSeparatedText, .sourceCode, .swiftSource, .pythonScript, .javaScript, .shellScript,
        .propertyList, .pdf, .image, .png, .jpeg, .gif, .tiff, .bmp, .ico, .svg, .heic, .webP, .audiovisualContent, .movie, .video,
        .audio, .quickTimeMovie, .mpeg4Movie, .mpeg4Audio, .mp3, .wav, .aiff, .midi, .archive, .zip, .gzip, .diskImage, .executable,
        .exe, .application, .applicationBundle, .database, .spreadsheet, .presentation, .font, .log, .epub,
    ]
}

extension URL {
    /// The type of the file at this URL, by extension (what Windows itself goes by).
    public var circuitContentType: UTType? { UTType(filenameExtension: pathExtension) }
}
#endif
