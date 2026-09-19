import Foundation
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif

nonisolated enum AcademicDOCX {
    static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func run(_ text: String, italic: Bool = false) -> String {
        "<w:r>\(italic ? "<w:rPr><w:i/></w:rPr>" : "")<w:t xml:space=\"preserve\">\(xml(text))</w:t></w:r>"
    }

    private static func paragraph(_ content: String, properties: String = "") -> String {
        "<w:p><w:pPr>\(properties)</w:pPr>\(content)</w:p>"
    }

    static func render(_ request: AcademicDocumentRequest, evidence: [AcademicSourceEvidence]) throws -> Data {
        _ = try AcademicDocument.verify(request, evidence: evidence)
        let namespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
        let relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let prefix = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let noIndent = "<w:ind w:firstLine=\"0\"/>"
        var body = [request.author ?? "[Student name]", request.instructor ?? "[Instructor]",
                    request.course ?? "[Course]", request.date ?? "[Day Month Year]"]
            .map { paragraph(run($0), properties: noIndent) }.joined()
        body += paragraph(run(request.title), properties: noIndent + "<w:jc w:val=\"center\"/>")
        for segments in request.paragraphs {
            let text = segments.map { segment in
                var value = segment.quotation == true ? "“\(segment.text)”" : segment.text
                if let sourceID = segment.sourceID, let source = request.sources.first(where: { $0.id == sourceID }) {
                    value += " (\(source.citation))"
                }
                return run(value)
            }.joined()
            body += paragraph(text)
        }
        if !request.sources.isEmpty {
            body += paragraph(run("Works Cited"), properties: noIndent + "<w:pageBreakBefore/><w:jc w:val=\"center\"/>")
            let sorted = request.sources.sorted {
                sortKey($0).compare(sortKey($1), options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedAscending
            }
            for source in sorted {
                let number = request.sources.firstIndex(where: { $0.id == source.id })! + 1
                let bibliography = run((source.author.map { "\($0). " } ?? "") + "“\(source.title).” ")
                    + (source.publication.map { run($0, italic: true) + run(", ") } ?? "")
                    + (source.publicationDate.map { run("\($0), ") } ?? "")
                let hyperlink = "<w:hyperlink r:id=\"source\(number)\">\(run(source.url))</w:hyperlink>"
                let retrieved = evidence.first { $0.sourceID == source.id }!.retrievedAt
                let accessed = ISO8601DateFormatter().date(from: retrieved).map { date in
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                    let months = ["Jan.", "Feb.", "Mar.", "Apr.", "May", "June", "July", "Aug.", "Sept.", "Oct.", "Nov.", "Dec."]
                    return ". Accessed \(calendar.component(.day, from: date)) \(months[calendar.component(.month, from: date) - 1]) \(calendar.component(.year, from: date))."
                } ?? "."
                body += paragraph(bibliography + hyperlink + run(accessed),
                                  properties: "<w:ind w:left=\"720\" w:hanging=\"720\"/>")
            }
        }
        body += "<w:sectPr><w:headerReference w:type=\"default\" r:id=\"header\"/><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\"/></w:sectPr>"
        let document = prefix + "<w:document xmlns:w=\"\(namespace)\" xmlns:r=\"\(relationships)\"><w:body>\(body)</w:body></w:document>"
        let styles = prefix + """
        <w:styles xmlns:w="\(namespace)"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:cs="Times New Roman"/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:before="0" w:after="0" w:line="480" w:lineRule="auto"/><w:ind w:firstLine="720"/><w:widowControl/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style></w:styles>
        """
        let header = prefix + "<w:hdr xmlns:w=\"\(namespace)\">" + paragraph(
            run((request.surname ?? "[Surname]") + " ") + "<w:fldSimple w:instr=\"PAGE\">\(run("1"))</w:fldSimple>",
            properties: noIndent + "<w:jc w:val=\"right\"/>") + "</w:hdr>"
        var documentRelations = "<Relationship Id=\"styles\" Type=\"\(relationships)/styles\" Target=\"styles.xml\"/><Relationship Id=\"header\" Type=\"\(relationships)/header\" Target=\"header1.xml\"/>"
        for (index, source) in request.sources.enumerated() {
            documentRelations += "<Relationship Id=\"source\(index + 1)\" Type=\"\(relationships)/hyperlink\" Target=\"\(xml(source.url))\" TargetMode=\"External\"/>"
        }
        let relPrefix = prefix + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        let contentTypes = prefix + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="json" ContentType="application/json"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/></Types>
        """
        // Evidence remains with the saved document. It is not a semantic truth or authorship score.
        let evidenceEncoder = JSONEncoder()
        evidenceEncoder.outputFormatting = [.sortedKeys]
        let entries: [(String, Data)] = [
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data((relPrefix + "<Relationship Id=\"document\" Type=\"\(relationships)/officeDocument\" Target=\"word/document.xml\"/></Relationships>").utf8)),
            ("word/document.xml", Data(document.utf8)), ("word/styles.xml", Data(styles.utf8)),
            ("word/header1.xml", Data(header.utf8)),
            ("word/_rels/document.xml.rels", Data((relPrefix + documentRelations + "</Relationships>").utf8)),
            ("ace/source-evidence.json", try evidenceEncoder.encode(evidence.map { fetched in
                var record = fetched
                record.text = request.paragraphs.flatMap { $0 }.filter { $0.sourceID == fetched.sourceID }
                    .compactMap(\.supportingPassage).joined(separator: "\n")
                return record
            }))
        ]
        return storedZIP(entries)
    }

    private static func sortKey(_ source: AcademicDocumentSource) -> String {
        if let author = source.authorSurname { return author + " " + source.title }
        return source.title.replacingOccurrences(of: "^(?i)(a|an|the)\\s+", with: "", options: .regularExpression)
    }

    // ZIP's stored method is universally readable and needs no customer-installed runtime.
    private static func storedZIP(_ entries: [(String, Data)]) -> Data {
        var archive = Data(), directory = Data()
        func integer(_ value: UInt32, width: Int = 4) -> Data {
            Data((0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func crc32(_ data: Data) -> UInt32 {
            var crc: UInt32 = 0xFFFFFFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) }
            }
            return ~crc
        }
        for (name, content) in entries {
            let nameData = Data(name.utf8), offset = UInt32(archive.count)
            let checksum = crc32(content), size = UInt32(content.count)
            let common = integer(20, width: 2) + integer(0, width: 2) + integer(0, width: 2)
                + integer(0, width: 2) + integer(33, width: 2) + integer(checksum) + integer(size) + integer(size)
                + integer(UInt32(nameData.count), width: 2) + integer(0, width: 2)
            archive.append(integer(0x04034B50) + common + nameData + content)
            directory.append(integer(0x02014B50) + integer(20, width: 2) + common
                + integer(0, width: 2) + integer(0, width: 2) + integer(0, width: 2)
                + integer(0) + integer(offset) + nameData)
        }
        let offset = UInt32(archive.count)
        archive.append(directory)
        archive.append(integer(0x06054B50) + integer(0, width: 2) + integer(0, width: 2)
            + integer(UInt32(entries.count), width: 2) + integer(UInt32(entries.count), width: 2)
            + integer(UInt32(directory.count)) + integer(offset) + integer(0, width: 2))
        return archive
    }

    static func saveNew(_ data: Data, to output: String) throws {
        let url = URL(fileURLWithPath: output)
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directory >= 0 else { throw AcademicDocumentError.invalid("The output folder is unavailable or is a symbolic link.") }
        defer { close(directory) }
        let temporary = ".ace-document-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw AcademicDocumentError.invalid("The output folder is not writable.") }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw AcademicDocumentError.invalid("The document could not be fully written.") }
                offset += written
            }
        }
        guard fsync(descriptor) == 0, linkat(directory, temporary, directory, url.lastPathComponent, 0) == 0 else {
            throw AcademicDocumentError.invalid("The document was not saved. Choose a new filename; existing files are never replaced.")
        }
        _ = fsync(directory)
    }
}
