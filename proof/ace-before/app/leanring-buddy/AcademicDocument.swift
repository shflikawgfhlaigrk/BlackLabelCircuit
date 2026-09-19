import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif

nonisolated struct AcademicDocumentRequest: Codable, Sendable {
    var outputPath: String
    var title: String
    var author: String?
    var surname: String?
    var instructor: String?
    var course: String?
    var date: String?
    var paragraphs: [[AcademicDocumentSegment]]
    var sources: [AcademicDocumentSource]
}

nonisolated struct AcademicDocumentSegment: Codable, Sendable {
    var text: String
    var sourceID: String?
    var supportingPassage: String?
    var quotation: Bool?
}

nonisolated struct AcademicDocumentSource: Codable, Sendable {
    var id: String
    var url: String
    var title: String
    var author: String?
    var authorSurname: String?
    var publication: String?
    var publicationDate: String?

    var citation: String { authorSurname ?? "“\(title)”" }
    var bibliography: String {
        [author.map { "\($0)." }, "“\(title).”", publication.map { "\($0)," },
         publicationDate.map { "\($0)," }, url + "."].compactMap { $0 }.joined(separator: " ")
    }
}

nonisolated struct AcademicSourceEvidence: Codable, Sendable {
    var sourceID: String
    var requestedURL: String
    var retrievedURL: String
    var retrievedAt: String
    var sha256: String
    var byteCount: Int
    var text: String
}

nonisolated enum AcademicDocumentError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

nonisolated enum AcademicDocument {
    static func validate(_ request: AcademicDocumentRequest) throws {
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw AcademicDocumentError.invalid(message) }
        }
        try require(request.outputPath.hasPrefix("/") && request.outputPath.hasSuffix(".docx"),
                    "Choose an absolute .docx output path.")
        try require(!request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "The document needs a title.")
        try require(!request.paragraphs.isEmpty && request.paragraphs.count <= 500 && request.sources.count <= 30,
                    "Use 1–500 paragraphs and at most 30 sources.")
        let encoded = try JSONEncoder().encode(request)
        try require(encoded.count <= 1_000_000, "The document request is too large.")
        // XML 1.0 controls and paragraph breaks must never silently change the saved essay.
        let strings = [request.title, request.author, request.surname, request.instructor, request.course, request.date]
            .compactMap { $0 } + request.paragraphs.flatMap { $0.map(\.text) }
            + request.sources.flatMap { [$0.id, $0.url, $0.title, $0.author, $0.authorSurname, $0.publication, $0.publicationDate].compactMap { $0 } }
        try require(strings.allSatisfy { value in
            !value.isEmpty && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF }
        }, "Document fields must be nonempty text without control characters. Use separate paragraphs for line breaks.")
        let ids = Set(request.sources.map(\.id))
        try require(ids.count == request.sources.count, "Each source needs a unique ID.")
        var cited = Set<String>()
        for paragraph in request.paragraphs {
            try require(!paragraph.isEmpty, "Empty paragraphs are not supported.")
            for segment in paragraph {
                if let id = segment.sourceID {
                    try require(ids.contains(id), "A citation refers to an unknown source: \(id).")
                    try require(segment.supportingPassage.map { normalize($0).count >= 12 } == true,
                                "Each citation needs a supporting passage from the source.")
                    cited.insert(id)
                } else {
                    try require(segment.quotation != true && segment.supportingPassage == nil,
                                "A quotation or supporting passage needs a source ID.")
                }
            }
        }
        try require(cited == ids, "Works Cited must contain exactly the sources cited in the essay.")
        for source in request.sources {
            try require(sourceURL(source.url) != nil, "Source URLs must use HTTPS and contain no credentials.")
            try require((source.author == nil) == (source.authorSurname == nil),
                        "Supply both the source author and citation surname, or omit both.")
        }
    }

    static func sourceURL(_ text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    static func normalize(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func verify(_ request: AcademicDocumentRequest, evidence: [AcademicSourceEvidence]) throws -> Int {
        try validate(request)
        guard evidence.count == request.sources.count,
              Set(evidence.map(\.sourceID)).count == evidence.count else {
            throw AcademicDocumentError.invalid("Source retrieval is incomplete or duplicated.")
        }
        var quotations = 0
        for source in request.sources {
            guard let fetched = evidence.first(where: { $0.sourceID == source.id }),
                  fetched.requestedURL == source.url, fetched.byteCount > 0,
                  sourceURL(fetched.retrievedURL) != nil else {
                throw AcademicDocumentError.invalid("The source retrieval does not match the citation.")
            }
            let content = normalize(fetched.text)
            for segment in request.paragraphs.flatMap({ $0 }) where segment.sourceID == source.id {
                guard let passage = segment.supportingPassage, content.contains(normalize(passage)) else {
                    throw AcademicDocumentError.invalid("The supporting passage was not found in source \(source.id).")
                }
                if segment.quotation == true {
                    guard content.contains(normalize(segment.text)) else {
                        throw AcademicDocumentError.invalid("The quotation was not found in source \(source.id).")
                    }
                    quotations += 1
                }
            }
        }
        return quotations
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
