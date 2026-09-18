#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — CSV IMPORT + DEDUPE engine.
// Imports the buyer's OWN lead list (PropStream / BatchLeads / a county export / a spreadsheet)
// into the CRM. Pure logic so it's fully testable: an RFC-4180 parser (quotes, embedded commas,
// escaped quotes, CRLF), fuzzy header → Lead-field mapping, and dedupe against the existing book
// by a normalized key (name+county, else property address, else phone/email). Nothing is
// fabricated — only the columns the user actually supplied are filled; the rest stay empty.
import Foundation

enum CSVImport {
    /// Spreadsheet/database clipboard exports often arrive as tab-separated rows. The importer
    /// accepts that paste shape by normalizing TSV to CSV before the RFC-4180 parser runs.
    static func normalizePastedTable(_ text: String) -> String {
        guard let firstLine = text.split(whereSeparator: \.isNewline).first else { return text }
        let first = String(firstLine)
        guard first.contains("\t"), !first.contains(",") else { return text }
        return text.replacingOccurrences(of: "\t", with: ",")
    }

    // MARK: - RFC-4180 parser
    /// Parse CSV text into rows of fields. Handles double-quoted fields with embedded commas,
    /// newlines, and "" escapes. Tolerant of both \n and \r\n line endings.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        // Iterate Unicode scalars (not Characters): Swift treats "\r\n" as ONE Character grapheme,
        // which would otherwise hide both line-ending scalars. Scalars keep \r and \n separate.
        let scalars = Array(text.unicodeScalars)
        var i = 0
        let quote: Unicode.Scalar = "\"", comma: Unicode.Scalar = ",", cr: Unicode.Scalar = "\r", lf: Unicode.Scalar = "\n"
        func endField() { row.append(field); field = "" }
        func endRow() { endField(); rows.append(row); row = [] }
        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == quote {
                    if i + 1 < scalars.count && scalars[i + 1] == quote { field.unicodeScalars.append(quote); i += 1 } // escaped quote
                    else { inQuotes = false }
                } else { field.unicodeScalars.append(c) }
            } else {
                switch c {
                case quote: inQuotes = true
                case comma: endField()
                case cr: break // swallow; the following \n ends the row (or a lone \r ends it below)
                case lf: endRow()
                default: field.unicodeScalars.append(c)
                }
                // a lone CR (old Mac line ending) not followed by LF also ends a row
                if c == cr && !(i + 1 < scalars.count && scalars[i + 1] == lf) { endRow() }
            }
            i += 1
        }
        // trailing field/row with no final newline
        if !field.isEmpty || !row.isEmpty { endRow() }
        // drop fully-empty rows (blank lines)
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    // MARK: - Header mapping
    /// A Lead field a CSV column can map to.
    enum Column: String, CaseIterable {
        case name, ownerName, county, propertyAddress, mailingAddress, phone, email, parcel, assessedValue
        var label: String {
            switch self {
            case .name: return "Name"; case .ownerName: return "Owner"; case .county: return "County"
            case .propertyAddress: return "Property address"; case .mailingAddress: return "Mailing address"
            case .phone: return "Phone"; case .email: return "Email"; case .parcel: return "Parcel/APN"
            case .assessedValue: return "Assessed value"
            }
        }
        /// Header substrings that auto-map to this column (lowercased, punctuation-insensitive).
        var aliases: [String] {
            switch self {
            case .name: return ["name", "owner name", "ownername", "full name", "lead", "contact", "decedent", "first"]
            case .ownerName: return ["owner", "ownerofrecord", "recorded owner", "ownerofrecord", "taxpayer"]
            case .county: return ["county"]
            case .propertyAddress: return ["property address", "propertyaddress", "situs", "site address", "address", "street", "property"]
            case .mailingAddress: return ["mailing address", "mailingaddress", "mail address", "owner mailing", "tax mailing", "mailing"]
            case .phone: return ["phone", "phone1", "mobile", "cell", "telephone", "tel"]
            case .email: return ["email", "e-mail", "emailaddress", "email address"]
            case .parcel: return ["parcel", "apn", "parcel id", "parcelid", "parcel number", "pin"]
            case .assessedValue: return ["assessed", "assessed value", "value", "tax value", "market value", "appraised"]
            }
        }
    }

    private static func norm(_ s: String) -> String {
        var out = s.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: "")
        while out.contains("  ") { out = out.replacingOccurrences(of: "  ", with: " ") }
        return out
    }

    /// Best-guess header → Column mapping. Each header gets at most one column; each column at most
    /// one header (first/closest wins). Exact alias match beats a substring match. Aliases are
    /// normalized the same way as headers so "e-mail" ≡ "e mail".
    static func autoMap(headers: [String]) -> [Int: Column] {
        var result: [Int: Column] = [:]
        var used: Set<Column> = []
        // pass 1: exact alias equality (normalized)
        for (idx, h) in headers.enumerated() {
            let n = norm(h)
            if let col = Column.allCases.first(where: { !used.contains($0) && $0.aliases.map(norm).contains(n) }) {
                result[idx] = col; used.insert(col)
            }
        }
        // pass 2: substring containment for still-unmapped headers
        for (idx, h) in headers.enumerated() where result[idx] == nil {
            let n = norm(h)
            if let col = Column.allCases.first(where: { c in
                !used.contains(c) && c.aliases.map(norm).contains(where: { n.contains($0) || $0.contains(n) })
            }) { result[idx] = col; used.insert(col) }
        }
        return result
    }

    // MARK: - Row → Lead
    /// Build leads from data rows + a column mapping. Skips rows that yield no name AND no address
    /// (an empty record). Source is tagged `.manual` (an imported list) unless a county hints otherwise.
    static func leads(rows: [[String]], mapping: [Int: Column], source: LeadSource = .manual) -> [Lead] {
        rows.compactMap { row -> Lead? in
            var l = Lead(); l.source = source; l.sourceDetail = "CSV import"
            for (idx, col) in mapping {
                guard idx < row.count else { continue }
                let v = row[idx].trimmingCharacters(in: .whitespaces)
                guard !v.isEmpty else { continue }
                switch col {
                case .name: l.name = v
                case .ownerName: l.ownerName = v
                case .county: l.county = v.replacingOccurrences(of: " County", with: "", options: .caseInsensitive)
                case .propertyAddress: l.propertyAddress = v
                case .mailingAddress: l.mailingAddress = v
                case .phone: l.phone = v
                case .email: l.email = v
                case .parcel: l.parcel = v
                case .assessedValue: l.assessedValue = Int(v.filter { $0.isNumber }) ?? 0
                }
            }
            // an owner-only name falls back to the owner field; name defaults to owner/address
            if l.name.isEmpty { l.name = l.ownerName.isEmpty ? l.propertyAddress : l.ownerName }
            guard !l.name.isEmpty || !l.propertyAddress.isEmpty else { return nil }
            return l
        }
    }

    // MARK: - Dedupe
    /// A normalized identity key used to detect duplicates within the import AND against existing.
    static func key(_ l: Lead) -> String {
        let nm = l.name.lowercased().trimmingCharacters(in: .whitespaces)
        let cty = l.county.lowercased().trimmingCharacters(in: .whitespaces)
        if !nm.isEmpty { return "n:\(nm)|\(cty)" }
        let addr = l.propertyAddress.lowercased().filter { $0.isLetter || $0.isNumber }
        if !addr.isEmpty { return "a:\(addr)" }
        let ph = l.phone.filter { $0.isNumber }
        if !ph.isEmpty { return "p:\(ph)" }
        return "e:\(l.email.lowercased())"
    }

    struct Result {
        var newLeads: [Lead] = []
        var duplicates = 0           // matched an existing lead (skipped)
        var withinFileDupes = 0      // duplicate rows inside the same CSV (skipped)
        var skippedRows = 0          // rows with no usable data
        var total = 0                // data rows parsed (excludes header)
    }

    /// Full import: parse → map (auto unless overridden) → build leads → dedupe within file and
    /// against `existing`. Returns the net-new leads plus honest counts for the import summary.
    static func run(_ text: String, existing: [Lead], mappingOverride: [Int: Column]? = nil,
                    source: LeadSource = .manual, hasHeader: Bool = true) -> Result {
        let rows = parse(normalizePastedTable(text))
        guard !rows.isEmpty else { return Result() }
        let header = hasHeader ? rows[0] : (0..<(rows.first?.count ?? 0)).map { "col\($0)" }
        let dataRows = hasHeader ? Array(rows.dropFirst()) : rows
        let mapping = mappingOverride ?? autoMap(headers: header)
        let built = leads(rows: dataRows, mapping: mapping, source: source)

        var result = Result()
        result.total = dataRows.count
        result.skippedRows = dataRows.count - built.count
        let existingKeys = Set(existing.map { key($0) })
        var addedKeys = Set<String>()           // keys we've already imported from THIS file
        for l in built {
            let k = key(l)
            if existingKeys.contains(k) { result.duplicates += 1; continue }      // matches the book
            if addedKeys.contains(k) { result.withinFileDupes += 1; continue }     // dupe row in this file
            addedKeys.insert(k); result.newLeads.append(l)
        }
        return result
    }
}
#endif // circuit-convert
