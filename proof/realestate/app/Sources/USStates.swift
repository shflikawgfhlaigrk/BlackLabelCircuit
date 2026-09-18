// Black Label Real Estate — US location input normalization.
//
// WHY THIS EXISTS (buyer-friendliness, not fabrication):
// The public-records index stores states as 2-letter USPS codes ("GA") and counties as bare
// names ("Bibb" — no "County" suffix). A non-technical buyer naturally types the *real* things:
// "Georgia" for the state, "Bibb County" for the county. Sent verbatim those queries match ZERO
// rows, and the app honestly (but misleadingly) reports "no matching records" — the area was fine,
// only the spelling was in a format the index doesn't store. This helper canonicalizes what the
// buyer typed to what the index stores, so a reasonable spelling finds the real parcels.
//
// It NEVER invents data: it only rewrites the buyer's own location string into the index's format
// (name → USPS code, strip a trailing "County"/"Parish"/"Borough"). Anything it can't confidently
// resolve is passed through untouched, so a genuinely unknown place still returns an honest zero.
import Foundation

enum USStates {
    /// Full state / territory name (lowercased) → USPS 2-letter code. Includes DC + territories and
    /// a few common written variants, so "georgia", "washington dc", "puerto rico" all resolve.
    static let nameToCode: [String: String] = [
        "alabama": "AL", "alaska": "AK", "arizona": "AZ", "arkansas": "AR", "california": "CA",
        "colorado": "CO", "connecticut": "CT", "delaware": "DE", "florida": "FL", "georgia": "GA",
        "hawaii": "HI", "idaho": "ID", "illinois": "IL", "indiana": "IN", "iowa": "IA",
        "kansas": "KS", "kentucky": "KY", "louisiana": "LA", "maine": "ME", "maryland": "MD",
        "massachusetts": "MA", "michigan": "MI", "minnesota": "MN", "mississippi": "MS",
        "missouri": "MO", "montana": "MT", "nebraska": "NE", "nevada": "NV", "new hampshire": "NH",
        "new jersey": "NJ", "new mexico": "NM", "new york": "NY", "north carolina": "NC",
        "north dakota": "ND", "ohio": "OH", "oklahoma": "OK", "oregon": "OR", "pennsylvania": "PA",
        "rhode island": "RI", "south carolina": "SC", "south dakota": "SD", "tennessee": "TN",
        "texas": "TX", "utah": "UT", "vermont": "VT", "virginia": "VA", "washington": "WA",
        "west virginia": "WV", "wisconsin": "WI", "wyoming": "WY",
        // District + territories + common variants.
        "district of columbia": "DC", "washington dc": "DC", "washington d.c.": "DC", "d.c.": "DC",
        "dc": "DC", "puerto rico": "PR", "guam": "GU", "u.s. virgin islands": "VI",
        "us virgin islands": "VI", "virgin islands": "VI", "american samoa": "AS",
        "northern mariana islands": "MP",
    ]

    /// Every valid 2-letter code (derived from the map — single source of truth).
    static let validCodes: Set<String> = Set(nameToCode.values)

    /// USPS code → canonical display name (first/primary name that maps to the code).
    static let codeToName: [String: String] = {
        // Prefer the canonical single-word/primary spellings; skip the "d.c."/"dc" style aliases.
        let preferred: [String: String] = [
            "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California",
            "CO": "Colorado", "CT": "Connecticut", "DE": "Delaware", "FL": "Florida", "GA": "Georgia",
            "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa",
            "KS": "Kansas", "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland",
            "MA": "Massachusetts", "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi",
            "MO": "Missouri", "MT": "Montana", "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire",
            "NJ": "New Jersey", "NM": "New Mexico", "NY": "New York", "NC": "North Carolina",
            "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma", "OR": "Oregon", "PA": "Pennsylvania",
            "RI": "Rhode Island", "SC": "South Carolina", "SD": "South Dakota", "TN": "Tennessee",
            "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia", "WA": "Washington",
            "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming", "DC": "District of Columbia",
            "PR": "Puerto Rico", "GU": "Guam", "VI": "U.S. Virgin Islands", "AS": "American Samoa",
            "MP": "Northern Mariana Islands",
        ]
        return preferred
    }()

    /// Sorted (name, code) pairs for a picker/menu — the 50 states + DC first, territories after.
    static let pickerEntries: [(name: String, code: String)] = {
        let primary = ["AL","AK","AZ","AR","CA","CO","CT","DE","DC","FL","GA","HI","ID","IL","IN",
                       "IA","KS","KY","LA","ME","MD","MA","MI","MN","MS","MO","MT","NE","NV","NH",
                       "NJ","NM","NY","NC","ND","OH","OK","OR","PA","RI","SC","SD","TN","TX","UT",
                       "VT","VA","WA","WV","WI","WY","PR","GU","VI","AS","MP"]
        return primary.compactMap { code in codeToName[code].map { ($0, code) } }
    }()

    /// Resolve a raw state string to the index's USPS 2-letter code, or nil when it isn't a state
    /// we recognize. Handles: an already-valid code ("ga"/"GA"), a full name ("Georgia"), and
    /// common variants ("Washington D.C."). Never guesses — an unknown value returns nil.
    static func code(from raw: String?) -> String? {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let upper = trimmed.uppercased()
        if upper.count == 2, validCodes.contains(upper) { return upper }
        // Collapse internal whitespace so "new  york" == "new york".
        let key = trimmed.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        if let code = nameToCode[key] { return code }
        // Tolerate a trailing period on abbreviations ("Ga." → GA is not standard, but "Fla." isn't
        // either); only the exact 2-letter USPS code and full names resolve. Anything else: nil.
        return nil
    }

    /// The value to actually SEND as the `state` query param for a raw buyer input:
    /// the resolved USPS code when we recognize it, else the raw text uppercased (so a genuinely
    /// unknown state still produces an honest zero rather than being silently dropped).
    static func queryState(from raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return code(from: trimmed) ?? trimmed.uppercased()
    }

    /// True when the buyer typed something in the state box that we could NOT resolve to a real
    /// state — used to show a gentle "use a 2-letter code or full state name" hint.
    static func isUnresolvedState(_ raw: String?) -> Bool {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && code(from: trimmed) == nil
    }

    /// The county names in the index are bare ("Bibb", "Fulton") — a trailing "County"/"Parish"/
    /// "Borough"/"Municipio"/"Census Area" makes an exact-ish match miss. Strip a trailing suffix
    /// and collapse whitespace; leave the core name (and any internal punctuation like "St. Louis")
    /// untouched. Server matching is case-insensitive, so casing is preserved as typed.
    static func normalizedCounty(_ raw: String?) -> String {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        // Strip ONE trailing administrative suffix (case-insensitive, whole word).
        let suffixes = [" county", " parish", " borough", " municipio", " census area", " city and borough"]
        let lower = s.lowercased()
        for suf in suffixes where lower.hasSuffix(suf) {
            s = String(s.dropLast(suf.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            break
        }
        // Collapse any doubled interior whitespace.
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s
    }
}
