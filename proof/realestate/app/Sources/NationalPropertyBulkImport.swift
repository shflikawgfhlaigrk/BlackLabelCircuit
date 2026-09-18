// Black Label Real Estate — chunked national property bulk import.
// Designed for licensed/provider/open-government CSVs. No web scraping, no synthetic parcel data.
import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif

enum NationalPropertyBulkImportStatus: String, Codable, Hashable {
    case running, completed, failed
}

struct NationalPropertyBulkImportOptions: Hashable {
    var importId: String? = nil
    var batchSize: Int = 1_000
    var hasHeader: Bool = true
    var resume: Bool = true
    var strictRows: Bool = false
    var requireSourceRecordID: Bool = true
}

struct NationalPropertyBulkImportCheckpoint: Identifiable, Codable, Hashable {
    var importId: String
    var sourceId: String
    var sourceLabel: String
    var sourceKind: NationalPropertySourceKind
    var state: String
    var county: String
    var fileName: String
    var status: NationalPropertyBulkImportStatus = .running
    var totalRows: Int? = nil
    var attemptedRows: Int = 0
    var committedRows: Int = 0
    var skippedRows: Int = 0
    var duplicateRows: Int = 0
    var failedRows: Int = 0
    var lastCommittedRow: Int = 0
    var lastCommittedChunk: Int = 0
    var batchSize: Int = 1_000
    var startedAt: Date = Date()
    var updatedAt: Date = Date()
    var completedAt: Date? = nil
    var lastError: String = ""
    var fileFingerprint: String? = nil

    var id: String { importId }
    var receipt: String {
        "\(sourceLabel): \(committedRows) committed · \(skippedRows) skipped · \(duplicateRows) duplicates"
    }
}

enum NationalPropertyBulkImportError: LocalizedError, Equatable {
    case missingProvenance
    case missingHeader
    case missingRequiredColumns([String])
    case invalidRow(Int, String)
    case unterminatedCSVRecord
    case sourceChangedOnResume

    var errorDescription: String? {
        switch self {
        case .missingProvenance:
            return "Bulk import requires source id, source label, and source URL/file or coverage note."
        case .missingHeader:
            return "Bulk import requires a CSV header row."
        case .missingRequiredColumns(let columns):
            return "Bulk import missing required column(s): \(columns.joined(separator: ", "))"
        case .invalidRow(let row, let reason):
            return "Invalid property row \(row): \(reason)"
        case .unterminatedCSVRecord:
            return "CSV ended inside a quoted row."
        case .sourceChangedOnResume:
            return "Bulk import resume blocked because the source file changed. Re-import the full file or use a new import ID."
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
final class NationalPropertyBulkImporter {
    let db: RealEstateLocalDatabase

    init(db: RealEstateLocalDatabase = RealEstateLocalDatabase()) {
        self.db = db
    }

    func importCSVText(_ text: String, source rawSource: NationalPropertySource,
                       options: NationalPropertyBulkImportOptions = NationalPropertyBulkImportOptions()) throws -> NationalPropertyBulkImportCheckpoint {
        let rows = CSVImport.parse(text)
        return try importRows(rows, source: rawSource, options: options, fileName: rawSource.url,
                              fileFingerprint: Self.fingerprint(text))
    }

    func importCSVFile(_ url: URL, source rawSource: NationalPropertySource,
                       options: NationalPropertyBulkImportOptions = NationalPropertyBulkImportOptions()) throws -> NationalPropertyBulkImportCheckpoint {
        var rows: [[String]] = []
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var pending = ""
        var rowText = ""
        while true {
            let data = handle.readData(ofLength: 1_048_576)
            if data.isEmpty { break }
            hasher.update(data: data)
            pending += String(decoding: data, as: UTF8.self)
            while let range = pending.range(of: "\n") {
                let line = String(pending[..<range.upperBound])
                pending.removeSubrange(..<range.upperBound)
                rowText += line
                if Self.csvRecordComplete(rowText) {
                    if let row = CSVImport.parse(rowText).first { rows.append(row) }
                    rowText = ""
                }
            }
        }
        if !pending.isEmpty { rowText += pending }
        if !rowText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard Self.csvRecordComplete(rowText) else { throw NationalPropertyBulkImportError.unterminatedCSVRecord }
            if let row = CSVImport.parse(rowText).first { rows.append(row) }
        }
        var source = rawSource
        if source.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            source.url = url.lastPathComponent
        }
        return try importRows(rows, source: source, options: options, fileName: url.lastPathComponent,
                              fileFingerprint: Self.hex(hasher.finalize()))
    }

    private func importRows(_ rows: [[String]], source rawSource: NationalPropertySource,
                            options rawOptions: NationalPropertyBulkImportOptions,
                            fileName: String,
                            fileFingerprint: String) throws -> NationalPropertyBulkImportCheckpoint {
        var source = rawSource
        if source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { source.id = UUID().uuidString }
        try validateProvenance(source)
        guard rawOptions.hasHeader else { throw NationalPropertyBulkImportError.missingHeader }
        guard let headers = rows.first else { throw NationalPropertyBulkImportError.missingHeader }
        let mapping = NationalPropertyCSVImporter.autoMap(headers: headers)
        try validateRequiredColumns(mapping, options: rawOptions)

        let dataRows = Array(rows.dropFirst())
        var options = rawOptions
        options.batchSize = max(1, options.batchSize)
        let importId = options.importId ?? source.id
        var checkpoint = (options.resume ? try db.bulkImportCheckpoint(importId: importId) : nil)
            ?? NationalPropertyBulkImportCheckpoint(importId: importId,
                                                    sourceId: source.id,
                                                    sourceLabel: source.displayLabel,
                                                    sourceKind: source.kind,
                                                    state: source.state.uppercased(),
                                                    county: source.county,
                                                    fileName: fileName,
                                                    totalRows: dataRows.count,
                                                    batchSize: options.batchSize)
        if options.resume,
           checkpoint.lastCommittedRow > 0,
           let existingFingerprint = checkpoint.fileFingerprint,
           !existingFingerprint.isEmpty,
           existingFingerprint != fileFingerprint {
            throw NationalPropertyBulkImportError.sourceChangedOnResume
        }
        checkpoint.status = .running
        checkpoint.totalRows = dataRows.count
        checkpoint.batchSize = options.batchSize
        checkpoint.fileFingerprint = fileFingerprint
        checkpoint.updatedAt = Date()

        var chunkRecords: [NationalPropertyRecord] = []
        var chunkEndRow = checkpoint.lastCommittedRow
        var chunkSkipped = 0
        var chunkDuplicates = 0
        var seenInImport = Set<String>()

        func commitChunk() throws {
            guard chunkEndRow > checkpoint.lastCommittedRow else { return }
            checkpoint.lastCommittedRow = chunkEndRow
            checkpoint.attemptedRows = max(checkpoint.attemptedRows, chunkEndRow)
            checkpoint.committedRows += chunkRecords.count
            checkpoint.skippedRows += chunkSkipped
            checkpoint.duplicateRows += chunkDuplicates
            checkpoint.lastCommittedChunk += 1
            checkpoint.updatedAt = Date()
            source.recordCount = checkpoint.committedRows
            source.lastImportedAt = checkpoint.updatedAt
            try db.commitBulkImportChunk(source: source, records: chunkRecords, checkpoint: checkpoint)
            chunkRecords = []
            chunkSkipped = 0
            chunkDuplicates = 0
        }

        do {
            for (offset, row) in dataRows.enumerated() {
                let rowNumber = offset + 1
                if options.resume && rowNumber <= checkpoint.lastCommittedRow { continue }
                chunkEndRow = rowNumber
                switch buildRecord(row: row, rowNumber: rowNumber, mapping: mapping, source: source, options: options) {
                case .success(let record):
                    if seenInImport.contains(record.id) {
                        chunkDuplicates += 1
                    } else {
                        seenInImport.insert(record.id)
                        chunkRecords.append(record)
                    }
                case .failure(let error):
                    if options.strictRows { throw error }
                    chunkSkipped += 1
                }
                let chunkConsumed = chunkRecords.count + chunkSkipped + chunkDuplicates
                if chunkConsumed >= options.batchSize { try commitChunk() }
            }
            try commitChunk()
            checkpoint.status = .completed
            checkpoint.completedAt = Date()
            checkpoint.updatedAt = checkpoint.completedAt ?? Date()
            source.recordCount = checkpoint.committedRows
            source.lastImportedAt = checkpoint.updatedAt
            try db.commitBulkImportChunk(source: source, records: [], checkpoint: checkpoint)
            return checkpoint
        } catch {
            checkpoint.status = .failed
            checkpoint.failedRows += 1
            checkpoint.updatedAt = Date()
            checkpoint.lastError = error.localizedDescription
            try? db.writeBulkImportCheckpoint(checkpoint)
            throw error
        }
    }

    private func validateProvenance(_ source: NationalPropertySource) throws {
        let hasID = !source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasLabel = !source.displayLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasOrigin = !source.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !source.coverageNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !(hasID && hasLabel && hasOrigin) { throw NationalPropertyBulkImportError.missingProvenance }
    }

    private func validateRequiredColumns(_ mapping: [Int: NationalPropertyCSVImporter.Column],
                                         options: NationalPropertyBulkImportOptions) throws {
        let mapped = Set(mapping.values)
        var missing: [String] = []
        if !mapped.contains(.state) { missing.append("state") }
        if options.requireSourceRecordID && !mapped.contains(.id) && !mapped.contains(.apn) && !mapped.contains(.parcelId) {
            missing.append("id/apn/parcel")
        }
        if !missing.isEmpty { throw NationalPropertyBulkImportError.missingRequiredColumns(missing) }
    }

    private enum RowBuildResult {
        case success(NationalPropertyRecord)
        case failure(NationalPropertyBulkImportError)
    }

    private func buildRecord(row: [String], rowNumber: Int, mapping: [Int: NationalPropertyCSVImporter.Column],
                             source: NationalPropertySource, options: NationalPropertyBulkImportOptions) -> RowBuildResult {
        func value(_ col: NationalPropertyCSVImporter.Column) -> String {
            guard let idx = mapping.first(where: { $0.value == col })?.key, idx < row.count else { return "" }
            return row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var record = NationalPropertyRecord()
        let sourceRecordID = firstNonEmpty([value(.id), value(.apn), value(.parcelId)])
        if options.requireSourceRecordID && sourceRecordID.isEmpty {
            return .failure(.invalidRow(rowNumber, "missing source property id, APN, or parcel id"))
        }
        record.id = Self.stableID([source.id, sourceRecordID, value(.address), value(.city), value(.state), value(.zip)].joined(separator: "|"))
        record.address = value(.address)
        record.unit = value(.unit)
        record.city = value(.city)
        record.state = firstNonEmpty([value(.state), source.state]).uppercased()
        record.zip = value(.zip)
        record.county = firstNonEmpty([value(.county), source.county])
            .replacingOccurrences(of: " County", with: "", options: .caseInsensitive)
        record.ownerName = value(.ownerName)
        record.mailingAddress = value(.mailingAddress)
        record.apn = value(.apn)
        record.parcelId = value(.parcelId)
        record.assessedValue = Self.intValue(value(.assessedValue))
        record.estimateValue = Self.intValue(value(.estimateValue))
        record.lastSalePrice = Self.intValue(value(.lastSalePrice))
        record.lastSaleDate = value(.lastSaleDate)
        record.beds = Self.doubleValue(value(.beds))
        record.baths = Self.doubleValue(value(.baths))
        record.sqft = Self.intValue(value(.sqft))
        record.lotSqft = Self.intValue(value(.lotSqft))
        record.latitude = Self.doubleValue(value(.latitude))
        record.longitude = Self.doubleValue(value(.longitude))
        record.sourceId = source.id
        record.sourceLabel = source.displayLabel
        record.sourceKind = source.kind
        record.updatedAt = Date()
        record.provenance = [source.coverageNote, source.url, "row \(rowNumber)"]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " · ")

        if record.normalizedState.isEmpty { return .failure(.invalidRow(rowNumber, "missing state")) }
        if record.address.isEmpty && record.parcelLabel.isEmpty && record.ownerName.isEmpty {
            return .failure(.invalidRow(rowNumber, "missing address, owner, and parcel identifiers"))
        }
        return .success(record)
    }

    private func firstNonEmpty(_ values: [String]) -> String {
        values.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    private static func csvRecordComplete(_ text: String) -> Bool {
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let quote: Unicode.Scalar = "\""
        while i < scalars.count {
            if scalars[i] == quote {
                if inQuotes && i + 1 < scalars.count && scalars[i + 1] == quote {
                    i += 1
                } else {
                    inQuotes.toggle()
                }
            }
            i += 1
        }
        return !inQuotes
    }

    private static func intValue(_ raw: String) -> Int? {
        let cleaned = raw.filter { $0.isNumber || $0 == "-" }
        return cleaned.isEmpty ? nil : Int(cleaned)
    }

    private static func doubleValue(_ raw: String) -> Double? {
        let cleaned = raw.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : Double(cleaned)
    }

    private static func stableID(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return "property-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func stableSourceID(kind: NationalPropertySourceKind, url: URL) -> String {
        let path = url.standardizedFileURL.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let basis = [kind.rawValue, path.isEmpty ? fallback : path.lowercased()].joined(separator: "|")
        let digest = SHA256.hash(data: Data(basis.utf8))
        return "source-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func fingerprint(_ text: String) -> String {
        hex(SHA256.hash(data: Data(text.utf8)))
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
#endif // circuit-convert


extension RealEstateLocalDatabase {
    func bulkImportCheckpoint(importId: String) throws -> NationalPropertyBulkImportCheckpoint? {
        throw RealEstateLocalDatabaseError.localIndexDisabled
    }

    func writeBulkImportCheckpoint(_ checkpoint: NationalPropertyBulkImportCheckpoint) throws {
        throw RealEstateLocalDatabaseError.localIndexDisabled
    }

    func commitBulkImportChunk(source: NationalPropertySource, records: [NationalPropertyRecord],
                               checkpoint: NationalPropertyBulkImportCheckpoint) throws {
        throw RealEstateLocalDatabaseError.localIndexDisabled
    }
}
