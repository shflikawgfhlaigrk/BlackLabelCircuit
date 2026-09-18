// Black Label Real Estate — national property models and map viewport policy.
// Runtime property search/map data comes from the Postgres Lead Database API.
import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif

enum NationalPropertySourceKind: String, Codable, CaseIterable, Identifiable {
    case nationalProvider = "national_provider"
    case providerBulk = "provider_bulk"
    case countyArcGIS = "county_arcgis"
    case csvImport = "csv_import"
    case manual = "manual"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .nationalProvider: return "National provider"
        case .providerBulk: return "Provider bulk file"
        case .countyArcGIS: return "County ArcGIS"
        case .csvImport: return "CSV import"
        case .manual: return "Manual"
        }
    }
}

struct NationalPropertySource: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var label: String = ""
    var kind: NationalPropertySourceKind = .csvImport
    var state: String = ""
    var county: String = ""
    var url: String = ""
    var recordCount: Int = 0
    var lastImportedAt: Date? = nil
    var coverageNote: String = ""
    var providerLegalName: String? = nil
    var licenseURL: String? = nil
    var agreementID: String? = nil
    var rightsReviewedAt: Date? = nil
    var rightsExpiresAt: Date? = nil
    var commercialUseAllowed: Bool? = nil
    var displayAllowed: Bool? = nil
    var storageAllowed: Bool? = nil
    var exportAllowed: Bool? = nil
    var resaleAllowed: Bool? = nil
    var derivedAnalyticsAllowed: Bool? = nil
    var ownerDataAllowed: Bool? = nil
    var noScrapedPortalDataCertified: Bool? = nil
    var noZillowSourceCertified: Bool? = nil
    var noFCRAUseCertified: Bool? = nil
    var attributionText: String? = nil

    var displayLabel: String { label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? kind.label : label }
    var hasRightsProof: Bool {
        let license = licenseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let agreement = agreementID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !license.isEmpty || !agreement.isEmpty
    }
    var rightsExpired: Bool {
        guard let rightsExpiresAt else { return false }
        return rightsExpiresAt < Date()
    }
    var rightsApproved: Bool {
        hasRightsProof &&
        rightsExpired == false &&
        commercialUseAllowed == true &&
        displayAllowed == true &&
        storageAllowed == true &&
        noScrapedPortalDataCertified == true &&
        noZillowSourceCertified == true &&
        noFCRAUseCertified == true
    }
    var rightsStatusLabel: String {
        if rightsApproved { return "Rights approved" }
        if rightsExpired { return "Rights expired" }
        if !hasRightsProof { return "Rights missing" }
        return "Rights incomplete"
    }
    var scopeLabel: String {
        let st = state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let c = county.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .nationalProvider { return "United States" }
        if !st.isEmpty && !c.isEmpty { return "\(c), \(st)" }
        if !st.isEmpty { return st }
        return "Unscoped"
    }
}

struct NationalPropertyRecord: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var address: String = ""
    var unit: String = ""
    var city: String = ""
    var state: String = ""
    var zip: String = ""
    var county: String = ""
    var ownerName: String = ""
    var mailingAddress: String = ""
    var apn: String = ""
    var parcelId: String = ""
    var assessedValue: Int? = nil
    var estimateValue: Int? = nil
    var lastSalePrice: Int? = nil
    var lastSaleDate: String = ""
    var beds: Double? = nil
    var baths: Double? = nil
    var sqft: Int? = nil
    var lotSqft: Int? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var sourceId: String = ""
    var sourceLabel: String = ""
    var sourceKind: NationalPropertySourceKind = .manual
    var updatedAt: Date = Date()
    var provenance: String = ""

    var normalizedState: String { state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
    var normalizedCounty: String {
        county.replacingOccurrences(of: " County", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized
    }
    var locationLine: String {
        [city, normalizedState, zip].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
    var primaryValue: Int? { estimateValue ?? assessedValue ?? lastSalePrice }
    var parcelLabel: String {
        if !apn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return apn }
        if !parcelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return parcelId }
        return ""
    }
    var searchCorpus: String {
        [
            id, address, unit, city, state, zip, county, ownerName, mailingAddress, apn, parcelId,
            sourceLabel, sourceKind.label, provenance
        ]
        .joined(separator: " ")
        .lowercased()
    }
}

struct NationalPropertySearch: Hashable {
    var text: String = ""
    var state: String = ""
    var county: String = ""
    var zip: String = ""
    var owner: String = ""
    var apn: String = ""
    var limit: Int = 100

    var isEmpty: Bool {
        [text, state, county, zip, owner, apn].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

enum PropertyMapSummaryLevel: String, Hashable {
    case state
    case county
}

struct PropertyMapSummary: Hashable, Identifiable {
    var id: String
    var title: String
    var state: String
    var county: String
    var count: Int
    var lat: Double
    var lng: Double
    var level: PropertyMapSummaryLevel
}

private struct PropertyMapCoordinateBounds {
    let state: String
    let south: Double
    let north: Double
    let west: Double
    let east: Double
}

enum PropertyMapViewportPolicy {
    static func shouldSummarizeRecords(bounds: PropertyMapBounds,
                                       query: String,
                                       county: String,
                                       city: String,
                                       zip: String) -> Bool {
        false
    }

    static func coordinateMatchesState(_ state: String?, lat: Double, lng: Double) -> Bool {
        let normalized = (state ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let bounds = stateCoordinateBounds.first(where: { $0.state == normalized }) else { return true }
        return lat >= bounds.south && lat <= bounds.north && lng >= bounds.west && lng <= bounds.east
    }

    private static let stateCoordinateBounds: [PropertyMapCoordinateBounds] = [
        .init(state: "AL", south: 30.0, north: 35.5, west: -88.6, east: -84.7),
        .init(state: "AK", south: 51.0, north: 72.0, west: -180.0, east: -129.0),
        .init(state: "AZ", south: 31.2, north: 37.1, west: -114.9, east: -109.0),
        .init(state: "AR", south: 33.0, north: 36.6, west: -94.7, east: -89.6),
        .init(state: "CA", south: 32.4, north: 42.1, west: -124.5, east: -114.0),
        .init(state: "CO", south: 36.9, north: 41.1, west: -109.2, east: -102.0),
        .init(state: "CT", south: 40.9, north: 42.1, west: -73.8, east: -71.7),
        .init(state: "DE", south: 38.4, north: 39.9, west: -75.9, east: -75.0),
        .init(state: "DC", south: 38.7, north: 39.1, west: -77.2, east: -76.8),
        .init(state: "FL", south: 24.4, north: 31.1, west: -87.8, east: -80.0),
        .init(state: "GA", south: 30.2, north: 35.1, west: -85.7, east: -80.6),
        .init(state: "HI", south: 18.8, north: 22.3, west: -160.5, east: -154.7),
        .init(state: "ID", south: 41.9, north: 49.1, west: -117.4, east: -111.0),
        .init(state: "IL", south: 36.8, north: 42.6, west: -91.6, east: -87.0),
        .init(state: "IN", south: 37.7, north: 41.8, west: -88.2, east: -84.7),
        .init(state: "IA", south: 40.3, north: 43.6, west: -96.7, east: -90.1),
        .init(state: "KS", south: 36.9, north: 40.1, west: -102.1, east: -94.5),
        .init(state: "KY", south: 36.4, north: 39.3, west: -89.7, east: -81.9),
        .init(state: "LA", south: 28.8, north: 33.1, west: -94.1, east: -88.7),
        .init(state: "ME", south: 42.9, north: 47.5, west: -71.2, east: -66.8),
        .init(state: "MD", south: 37.8, north: 39.8, west: -79.6, east: -75.0),
        .init(state: "MA", south: 41.1, north: 42.9, west: -73.6, east: -69.9),
        .init(state: "MI", south: 41.6, north: 48.4, west: -90.5, east: -82.1),
        .init(state: "MN", south: 43.4, north: 49.4, west: -97.4, east: -89.4),
        .init(state: "MS", south: 30.1, north: 35.1, west: -91.7, east: -88.0),
        .init(state: "MO", south: 35.9, north: 40.7, west: -95.8, east: -89.0),
        .init(state: "MT", south: 44.2, north: 49.1, west: -116.2, east: -104.0),
        .init(state: "NE", south: 39.9, north: 43.1, west: -104.1, east: -95.2),
        .init(state: "NV", south: 35.0, north: 42.1, west: -120.1, east: -114.0),
        .init(state: "NH", south: 42.6, north: 45.4, west: -72.6, east: -70.6),
        .init(state: "NJ", south: 38.8, north: 41.4, west: -75.7, east: -73.8),
        .init(state: "NM", south: 31.2, north: 37.1, west: -109.2, east: -103.0),
        .init(state: "NY", south: 40.4, north: 45.1, west: -79.9, east: -71.7),
        .init(state: "NC", south: 33.7, north: 36.7, west: -84.4, east: -75.3),
        .init(state: "ND", south: 45.8, north: 49.1, west: -104.2, east: -96.4),
        .init(state: "OH", south: 38.3, north: 42.4, west: -84.9, east: -80.5),
        .init(state: "OK", south: 33.5, north: 37.1, west: -103.1, east: -94.3),
        .init(state: "OR", south: 41.9, north: 46.4, west: -124.7, east: -116.3),
        .init(state: "PA", south: 39.6, north: 42.6, west: -80.6, east: -74.6),
        .init(state: "PR", south: 17.8, north: 18.6, west: -67.4, east: -65.2),
        .init(state: "RI", south: 41.1, north: 42.1, west: -71.9, east: -71.1),
        .init(state: "SC", south: 32.0, north: 35.3, west: -83.5, east: -78.4),
        .init(state: "SD", south: 42.4, north: 45.9, west: -104.2, east: -96.4),
        .init(state: "TN", south: 34.9, north: 36.8, west: -90.4, east: -81.6),
        .init(state: "TX", south: 25.7, north: 36.6, west: -106.7, east: -93.5),
        .init(state: "UT", south: 36.9, north: 42.1, west: -114.2, east: -109.0),
        .init(state: "VT", south: 42.7, north: 45.1, west: -73.5, east: -71.4),
        .init(state: "VA", south: 36.5, north: 39.6, west: -83.8, east: -75.2),
        .init(state: "WA", south: 45.4, north: 49.1, west: -124.9, east: -116.8),
        .init(state: "WV", south: 37.1, north: 40.8, west: -82.7, east: -77.6),
        .init(state: "WI", south: 42.4, north: 47.2, west: -92.9, east: -86.8),
        .init(state: "WY", south: 40.9, north: 45.1, west: -111.2, east: -104.0)
    ]
}

/// Coverage math for provider-backed records. This is NOT the app's source of truth: the Property
/// Index headline + Coverage screen read live truth from `RealEstateAPI` (/v1/stats, /v1/coverage).
/// The thresholds below describe when a provider-backed corpus could honestly claim national
/// completeness (the US has ~145M parcels); they never drive a local user-facing cache claim.
struct NationalPropertyCoverage: Hashable {
    var recordCount: Int = 0
    var sourceCount: Int = 0
    var stateCodes: [String] = []
    var countyKeys: [String] = []
    var nationalProviderSources: Int = 0
    var rightsApprovedSources: Int = 0
    var rightsBlockedSources: Int = 0

    // Offline self-audit bar only (consumed by NationalPropertyAuditReport). Not a UI gate.
    static let minimumSellableNationwideRecords = 100_000_000
    static let requiredStateCodes: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN",
        "IA", "KS", "KY", "LA", "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV",
        "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN",
        "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY", "DC"
    ]

    var stateCount: Int { stateCodes.count }
    var countyCount: Int { countyKeys.count }
    var coversEveryState: Bool { Set(stateCodes).isSuperset(of: Self.requiredStateCodes) }
    var countyCoverageNearComplete: Bool { countyCount >= 3_000 }
    var denseNationwideRecords: Bool { recordCount >= Self.minimumSellableNationwideRecords }
    var nationallyIndexed: Bool { recordCount > 0 && coversEveryState }
    // Offline self-audit verdict only (consumed by NationalPropertyAuditReport) — never a UI pill.
    var nationwideReady: Bool {
        denseNationwideRecords && coversEveryState && rightsApprovedSources > 0 && (nationalProviderSources > 0 || countyCoverageNearComplete)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct NationalPropertyImportResult {
    var source: NationalPropertySource
    var records: [NationalPropertyRecord]
    var totalRows: Int
    var skippedRows: Int
    var duplicateRows: Int
    var mappedColumns: [Int: NationalPropertyCSVImporter.Column]

    var importedRows: Int { records.count }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum NationalPropertyCSVImporter {
    enum Column: String, CaseIterable, Codable {
        case id, address, unit, city, state, zip, county, ownerName, mailingAddress, apn, parcelId
        case assessedValue, estimateValue, lastSalePrice, lastSaleDate, beds, baths, sqft, lotSqft, latitude, longitude

        var aliases: [String] {
            switch self {
            case .id: return ["id", "property id", "propertyid", "record id", "listing id"]
            case .address: return ["address", "property address", "situs", "situs address", "site address", "street", "street address"]
            case .unit: return ["unit", "apt", "suite"]
            case .city: return ["city", "situs city", "property city"]
            case .state: return ["state", "st", "situs state", "property state"]
            case .zip: return ["zip", "zipcode", "postal", "postal code", "situs zip"]
            case .county: return ["county", "county name"]
            case .ownerName: return ["owner", "owner name", "ownername", "taxpayer", "vested owner"]
            case .mailingAddress: return ["mailing address", "mail address", "owner mailing", "tax mailing", "mailing"]
            case .apn: return ["apn", "parcel", "parcel number", "parcel no", "parcel apn"]
            case .parcelId: return ["parcel id", "parcelid", "pin", "folio", "account number"]
            case .assessedValue: return ["assessed", "assessed value", "tax value", "appraised value"]
            case .estimateValue: return ["estimate", "estimated value", "avm", "market value"]
            case .lastSalePrice: return ["last sale price", "sale price", "sold price", "last sold price"]
            case .lastSaleDate: return ["last sale date", "sale date", "sold date", "last sold date"]
            case .beds: return ["beds", "bedrooms", "bed"]
            case .baths: return ["baths", "bathrooms", "bath"]
            case .sqft: return ["sqft", "square feet", "building sqft", "living area", "living sqft"]
            case .lotSqft: return ["lot sqft", "lot size", "land sqft", "lot square feet"]
            case .latitude: return ["lat", "latitude", "y"]
            case .longitude: return ["lon", "lng", "longitude", "x"]
            }
        }
    }

    static func autoMap(headers: [String]) -> [Int: Column] {
        var result: [Int: Column] = [:]
        var used: Set<Column> = []
        for (idx, header) in headers.enumerated() {
            let h = norm(header)
            if let match = Column.allCases.first(where: { !used.contains($0) && $0.aliases.map(norm).contains(h) }) {
                result[idx] = match; used.insert(match)
            }
        }
        for (idx, header) in headers.enumerated() where result[idx] == nil {
            let h = norm(header)
            if let match = Column.allCases.first(where: { c in
                !used.contains(c) && c.aliases.map(norm).contains(where: { h.contains($0) || $0.contains(h) })
            }) {
                result[idx] = match; used.insert(match)
            }
        }
        return result
    }

    static func importCSV(_ text: String, source: NationalPropertySource, hasHeader: Bool = true) -> NationalPropertyImportResult {
        let rows = CSVImport.parse(text)
        guard !rows.isEmpty else {
            return NationalPropertyImportResult(source: source, records: [], totalRows: 0, skippedRows: 0, duplicateRows: 0, mappedColumns: [:])
        }
        let headers = hasHeader ? rows[0] : (0..<(rows.first?.count ?? 0)).map { "Column \($0 + 1)" }
        let dataRows = hasHeader ? Array(rows.dropFirst()) : rows
        let mapping = hasHeader ? autoMap(headers: headers) : autoMap(headers: headers)
        var imported: [NationalPropertyRecord] = []
        var skipped = 0
        var duplicates = 0
        var seen = Set<String>()
        var src = source

        for row in dataRows {
            var record = NationalPropertyRecord()
            func value(_ col: Column) -> String {
                guard let idx = mapping.first(where: { $0.value == col })?.key, idx < row.count else { return "" }
                return row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            record.id = value(.id)
            record.address = value(.address)
            record.unit = value(.unit)
            record.city = value(.city)
            record.state = value(.state).uppercased()
            record.zip = value(.zip)
            record.county = value(.county).replacingOccurrences(of: " County", with: "", options: .caseInsensitive)
            record.ownerName = value(.ownerName)
            record.mailingAddress = value(.mailingAddress)
            record.apn = value(.apn)
            record.parcelId = value(.parcelId)
            record.assessedValue = intValue(value(.assessedValue))
            record.estimateValue = intValue(value(.estimateValue))
            record.lastSalePrice = intValue(value(.lastSalePrice))
            record.lastSaleDate = value(.lastSaleDate)
            record.beds = doubleValue(value(.beds))
            record.baths = doubleValue(value(.baths))
            record.sqft = intValue(value(.sqft))
            record.lotSqft = intValue(value(.lotSqft))
            record.latitude = doubleValue(value(.latitude))
            record.longitude = doubleValue(value(.longitude))
            record.sourceId = src.id
            record.sourceLabel = src.displayLabel
            record.sourceKind = src.kind
            record.updatedAt = Date()
            record.provenance = src.coverageNote.isEmpty ? src.kind.label : src.coverageNote

            if record.address.isEmpty && record.parcelLabel.isEmpty && record.ownerName.isEmpty {
                skipped += 1
                continue
            }
            if record.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                record.id = stableID([
                    src.id, record.apn, record.parcelId, record.address, record.city, record.state, record.zip
                ].joined(separator: "|"))
            }
            if seen.contains(record.id) {
                duplicates += 1
                continue
            }
            seen.insert(record.id)
            imported.append(record)
        }

        src.recordCount = imported.count
        src.lastImportedAt = Date()
        if src.coverageNote.isEmpty {
            src.coverageNote = "CSV property import"
        }
        return NationalPropertyImportResult(source: src, records: imported, totalRows: dataRows.count,
                                            skippedRows: skipped, duplicateRows: duplicates, mappedColumns: mapping)
    }

    private static func norm(_ s: String) -> String {
        var out = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: "")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
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
}
#endif // circuit-convert
