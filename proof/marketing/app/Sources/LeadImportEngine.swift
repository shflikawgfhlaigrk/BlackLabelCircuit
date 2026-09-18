#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Lead file import engine — CSV/TSV → Lead records for the unified pool.
//
// Foundation-only ON PURPOSE: Tests/LeadImportEngineTests compiles this file standalone
// (with LeadDomain.swift) so the parser, header mapper, and dedupe can be attacked directly.
// The SwiftUI surface lives in LeadImportScreen.swift and owns nothing but presentation.
//
// Honesty rules (same charter as the rest of the pool): nothing is fabricated. An email cell
// that isn't email-shaped is preserved in notes, never stored as a confirmed email. A domain is
// only ever derived mechanically from the buyer's own website/email cell. Rows the buyer's file
// doesn't contain are never invented; rows we skip are counted and reported.

import Foundation

// MARK: - Target fields a column can map onto

enum LeadImportField: String, CaseIterable, Identifiable, Codable {
    case skip, name, firstName, lastName, company, domain, email, phone, address, industry, notes, tags, campaign
    var id: String { rawValue }
    var label: String {
        switch self {
        case .skip: return "— skip —"
        case .name: return "Name"
        case .firstName: return "First name"
        case .lastName: return "Last name"
        case .company: return "Company"
        case .domain: return "Website / Domain"
        case .email: return "Email"
        case .phone: return "Phone"
        case .address: return "Address"
        case .industry: return "Industry"
        case .notes: return "Notes"
        case .tags: return "Tags"
        case .campaign: return "Source / List"
        }
    }
}

// MARK: - Parsed table

struct LeadImportTable: Equatable {
    var headers: [String]        // count == column count; generated "Column N" names when the file has no header row
    var rows: [[String]]         // data rows only; every row padded/truncated to headers.count
    var hadHeaderRow: Bool
    var delimiter: Character
    var isEmpty: Bool { rows.isEmpty }
}

enum LeadImportEngine {

    // MARK: Delimiter detection

    /// Pick the delimiter by counting candidates OUTSIDE quoted regions over the first ~4KB.
    /// Ties break in candidate order (comma first) — a CSV with stray tabs stays a CSV.
    static func detectDelimiter(in text: String) -> Character {
        let sample = String(text.prefix(4096))
        let candidates: [Character] = [",", "\t", ";", "|"]
        var counts: [Character: Int] = [:]
        var inQuotes = false
        for ch in sample {
            if ch == "\"" { inQuotes.toggle(); continue }
            if !inQuotes, candidates.contains(ch) { counts[ch, default: 0] += 1 }
        }
        var best: Character = ","
        var bestCount = 0
        for c in candidates where (counts[c] ?? 0) > bestCount {
            best = c; bestCount = counts[c] ?? 0
        }
        return best
    }

    // MARK: CSV/TSV parsing (RFC-4180 shape)

    /// Single-pass state machine: quoted fields, "" escapes, delimiters and newlines inside
    /// quotes, CRLF/LF/CR endings, leading BOM. Never throws; hostile input yields rows of
    /// plain cells, not a crash.
    static func parseRecords(_ text: String, delimiter: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var inQuotes = false
        var sawAnything = false

        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil
        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        func endField() { record.append(field); field = "" }
        func endRecord() {
            endField()
            // A record that is entirely empty cells from a blank line is dropped here;
            // rows of real empty cells (",,,") survive because they have >1 cell.
            if !(record.count == 1 && record[0].isEmpty) { records.append(record) }
            record = []
        }

        while let scalar = next() {
            sawAnything = true
            let ch = Character(scalar)
            if ch == "\u{FEFF}" && records.isEmpty && record.isEmpty && field.isEmpty { continue }
            if inQuotes {
                if ch == "\"" {
                    if let peek = next() {
                        if Character(peek) == "\"" { field.append("\"") }   // "" escape
                        else { inQuotes = false; pending = peek }
                    } else { inQuotes = false }
                } else {
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case "\"" where field.isEmpty:
                inQuotes = true
            case delimiter:
                endField()
            case "\r":
                if let peek = next(), Character(peek) != "\n" { pending = peek }
                endRecord()
            case "\n":
                endRecord()
            default:
                field.append(ch)
            }
        }
        if sawAnything && (!field.isEmpty || !record.isEmpty) { endRecord() }
        return records
    }

    /// Parse + normalize into a rectangular table with a header decision.
    static func parseTable(_ text: String, delimiter: Character? = nil) -> LeadImportTable {
        let delim = delimiter ?? detectDelimiter(in: text)
        var records = parseRecords(text, delimiter: delim)
        guard !records.isEmpty else {
            return LeadImportTable(headers: [], rows: [], hadHeaderRow: false, delimiter: delim)
        }
        let width = records.map(\.count).max() ?? 0
        records = records.map { row in
            row.count == width ? row : row + Array(repeating: "", count: width - row.count)
        }
        // Header iff the first row names at least one field we recognize. A first row that is
        // itself data (an email-shaped cell, say) never matches a synonym, so it is kept.
        let firstRowMap = autoMap(records[0])
        let hasHeader = firstRowMap.contains { $0 != .skip }
        if hasHeader {
            let headers = records[0].enumerated().map { i, h -> String in
                let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? "Column \(i + 1)" : t
            }
            return LeadImportTable(headers: headers, rows: Array(records.dropFirst()), hadHeaderRow: true, delimiter: delim)
        }
        let headers = (0..<width).map { "Column \($0 + 1)" }
        return LeadImportTable(headers: headers, rows: records, hadHeaderRow: false, delimiter: delim)
    }

    // MARK: Header → field auto-mapping

    private static let synonyms: [LeadImportField: Set<String>] = [
        .name: ["name", "full name", "contact", "contact name", "lead", "lead name", "person",
                "owner", "owner name", "customer", "customer name", "client", "client name"],
        .firstName: ["first name", "first", "fname", "given name", "forename"],
        .lastName: ["last name", "last", "lname", "surname", "family name"],
        .company: ["company", "company name", "business", "business name", "organization",
                   "organisation", "org", "account", "account name", "employer", "firm", "brand"],
        .domain: ["domain", "website", "web site", "url", "site", "homepage", "company website",
                  "company domain", "web"],
        .email: ["email", "e mail", "email address", "e mail address", "mail", "work email",
                 "contact email", "email 1", "primary email"],
        .phone: ["phone", "phone number", "mobile", "mobile number", "cell", "cell phone",
                 "telephone", "tel", "contact number", "work phone", "phone 1", "number"],
        .address: ["address", "street", "street address", "full address", "location", "city",
                   "mailing address", "address 1"],
        .industry: ["industry", "vertical", "sector", "category", "niche", "trade", "type"],
        .notes: ["notes", "note", "description", "comments", "comment", "about", "details"],
        .tags: ["tags", "tag", "labels", "label", "keywords", "groups", "segment"],
        .campaign: ["source", "lead source", "campaign", "list", "list name", "origin"],
    ]

    static func normalizeHeader(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        var lastWasSpace = true
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" "); lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Map each header to its best field guess. Unrecognized headers map to .skip — the buyer
    /// can override every column by hand in the UI, so a wrong guess is never load-bearing.
    static func autoMap(_ headers: [String]) -> [LeadImportField] {
        headers.map { raw in
            let norm = normalizeHeader(raw)
            guard !norm.isEmpty else { return .skip }
            for (field, names) in synonyms where names.contains(norm) { return field }
            return .skip
        }
    }

    // MARK: Cell hygiene

    static func isEmailShaped(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 5, !t.contains(" ") else { return false }
        // split(separator:) drops empty subsequences, which would wave "a@@x.com" through —
        // count the @ signs explicitly instead.
        guard t.filter({ $0 == "@" }).count == 1 else { return false }
        let parts = t.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].contains(".") else { return false }
        return !parts[0].isEmpty && !parts[1].hasPrefix(".") && !parts[1].hasSuffix(".")
    }

    /// "https://www.acme.com/pricing" → "acme.com". Mechanical strip only; no guessing.
    static func normalizeDomain(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return "" }
        for scheme in ["https://", "http://"] where s.hasPrefix(scheme) { s = String(s.dropFirst(scheme.count)) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        if let slash = s.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) { s = String(s[..<slash]) }
        return s
    }

    // MARK: Rows → Leads

    struct BuildResult {
        var leads: [Lead] = []
        var skippedEmptyRows = 0
        var duplicatesInFile = 0
    }

    /// Build Lead records from the table under a mapping. Repeat-mapped columns join
    /// (name parts with spaces, address parts with ", ", notes with newlines, tags merge).
    /// In-file duplicates (same dedupe key) collapse to the FIRST occurrence.
    static func buildLeads(from table: LeadImportTable, mapping: [LeadImportField],
                           fileName: String, extraTag: String) -> BuildResult {
        var result = BuildResult()
        var seenKeys = Set<String>()
        let tag = extraTag.trimmingCharacters(in: .whitespacesAndNewlines)

        for row in table.rows {
            var parts: [LeadImportField: [String]] = [:]
            for (i, field) in mapping.enumerated() where field != .skip && i < row.count {
                let cell = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !cell.isEmpty { parts[field, default: []].append(cell) }
            }
            if parts.isEmpty { result.skippedEmptyRows += 1; continue }

            var lead = Lead()
            lead.source = .imported

            var name = (parts[.name] ?? []).joined(separator: " ")
            let first = (parts[.firstName] ?? []).joined(separator: " ")
            let last = (parts[.lastName] ?? []).joined(separator: " ")
            if name.isEmpty { name = [first, last].filter { !$0.isEmpty }.joined(separator: " ") }
            lead.name = name
            lead.company = (parts[.company] ?? []).joined(separator: " · ")
            lead.phone = (parts[.phone] ?? []).joined(separator: " · ")
            lead.address = (parts[.address] ?? []).joined(separator: ", ")
            lead.industry = (parts[.industry] ?? []).joined(separator: " · ")

            var notes = (parts[.notes] ?? []).joined(separator: "\n")

            // Email: only an email-shaped cell is stored as an email. Anything else the file
            // put in that column is preserved in notes — never promoted, never dropped silently.
            if let rawEmail = parts[.email]?.first {
                if isEmailShaped(rawEmail) {
                    lead.email = rawEmail.lowercased()
                } else {
                    notes = notes.isEmpty ? "email column: \(rawEmail)" : notes + "\nemail column: \(rawEmail)"
                }
            }

            var domain = normalizeDomain((parts[.domain] ?? []).first ?? "")
            if domain.isEmpty, !lead.email.isEmpty, let at = lead.email.firstIndex(of: "@") {
                domain = String(lead.email[lead.email.index(after: at)...])   // mechanical, from their own cell
            }
            lead.domain = domain
            lead.notes = notes

            var tags: [String] = []
            for cell in parts[.tags] ?? [] {
                tags.append(contentsOf: cell.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "|" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }
            if !tag.isEmpty { tags.append(tag) }
            var seenTags = Set<String>()
            lead.tags = tags.filter { seenTags.insert($0.lowercased()).inserted }

            lead.sourceCampaign = (parts[.campaign] ?? []).first ?? fileName

            if let key = dedupeKey(lead) {
                if !seenKeys.insert(key).inserted { result.duplicatesInFile += 1; continue }
            }
            result.leads.append(lead)
        }
        return result
    }

    // MARK: Dedupe

    /// Identity for duplicate detection: confirmed email first; else name+company.
    /// A row with none of the three has no key and is never treated as a duplicate.
    static func dedupeKey(_ l: Lead) -> String? {
        let email = l.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !email.isEmpty { return "e|\(email)" }
        let name = l.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let company = l.company.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.isEmpty && company.isEmpty { return nil }
        return "nc|\(name)|\(company)"
    }

    /// Split candidates into (fresh, duplicateCount) against the existing pool.
    static func partitionAgainstExisting(_ candidates: [Lead], existing: [Lead]) -> (fresh: [Lead], duplicates: Int) {
        var existingKeys = Set<String>()
        for l in existing { if let k = dedupeKey(l) { existingKeys.insert(k) } }
        var fresh: [Lead] = []
        var dupes = 0
        for c in candidates {
            if let k = dedupeKey(c), existingKeys.contains(k) { dupes += 1 } else { fresh.append(c) }
        }
        return (fresh, dupes)
    }
}
#endif // circuit-convert
