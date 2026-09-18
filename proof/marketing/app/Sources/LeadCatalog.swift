// Black Label Marketing — Lead catalog wire model (Foundation-only, b50).
//
// The API row/response shapes + the taxonomy-label formatter, split out of LeadDatabase.swift so
// they compile and unit-test WITHOUT SwiftUI (LeadDatabase.swift also holds the SwiftUI screen with
// app-wide deps — AppModel/BLTheme — and can't be exercised standalone). No SwiftUI import here on
// purpose: this file is pure data + decode, proven by Tests/LeadCatalogModelTests.swift.
//
// BINDINGS: zero fabrication — decoding NEVER invents a field or a facet row. A garbage/incomplete
// payload DROPS (nil response, or the bad facet row omitted), it is never backfilled with a phantom
// value. Every field is optional because the masked preview tier blurs contacts and some rows lack
// a field; a missing field stays nil rather than being guessed.
import Foundation

/// Title-cases a raw snake_case taxonomy token (industry / subcategory) for display. Pure and
/// total: empty in → empty out; already-spaced or already-cased input is preserved; no crash on
/// unicode, digits, or a value that is all separators.
func taxonomyLabel(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

/// One business returned by the catalog API. Mirrors the API row shape exactly; every field is
/// optional because the masked preview tier blurs contacts and some rows lack a field. The mapping
/// into the app's unified `Lead` (`toLead()`) lives in LeadDatabase.swift, where `Lead` + SwiftUI
/// are in scope — this stays a pure wire type so it can be decoded and tested with zero UI deps.
struct LeadRecord: Codable, Identifiable, Hashable {
    let id: Int
    var name: String?
    var category: String?
    var subtype: String?
    var industry: String?
    var subcategory: String?
    var contact_name: String?
    var email: String?
    var email_status: String?
    var phone: String?
    var website: String?
    var city: String?
    var state: String?
    var region: String?
    var deliv_tier: String?
}

struct LeadResponse: Codable {
    var tier: String
    var total: Int
    var page: Int
    var per_page: Int
    var masked: Bool
    var results: [LeadRecord]

    /// Decode a leads API body. Returns nil (drops the whole response) on ANY malformed/missing
    /// field — a required key absent, a row missing its `id`, or non-JSON garbage. Never a partial
    /// or fabricated response. Mirrors the `try?` decode the live LeadDBStore uses.
    static func decode(_ data: Data) -> LeadResponse? {
        try? JSONDecoder().decode(LeadResponse.self, from: data)
    }
}

/// Decodes an array element, yielding nil instead of throwing when that element is malformed — so a
/// single bad row DROPS rather than discarding the entire list (and is never fabricated into a
/// placeholder). This is the honest-decode primitive behind the facet lists below.
private struct DropInvalid<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) {
        value = try? T(from: decoder)
    }
}

/// The `/v1/facets` response: industry / subcategory / state rollups with live counts. Decoding is
/// lenient per row — a malformed facet row is DROPPED, never zero-filled — and a missing list decodes
/// to `[]`. So one bad row can't blank the whole facet panel, and no phantom facet is ever invented.
struct LeadFacets: Decodable {
    struct Industry: Decodable, Equatable { var industry: String; var label: String; var n: Int }
    struct Subcategory: Decodable, Equatable { var industry: String; var subcategory: String; var label: String; var n: Int }
    struct StateFacet: Decodable, Equatable { var state: String?; var n: Int }

    var taxonomy: Int
    var total: Int
    var industries: [Industry]
    var subcategories: [Subcategory]
    var states: [StateFacet]

    enum CodingKeys: String, CodingKey { case taxonomy, total, industries, subcategories, states }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taxonomy = (try? c.decode(Int.self, forKey: .taxonomy)) ?? 0
        total = (try? c.decode(Int.self, forKey: .total)) ?? 0
        industries = ((try? c.decode([DropInvalid<Industry>].self, forKey: .industries)) ?? []).compactMap(\.value)
        subcategories = ((try? c.decode([DropInvalid<Subcategory>].self, forKey: .subcategories)) ?? []).compactMap(\.value)
        states = ((try? c.decode([DropInvalid<StateFacet>].self, forKey: .states)) ?? []).compactMap(\.value)
    }

    /// Decode a facets body, or nil on non-JSON garbage. A JSON object with missing/garbage lists
    /// still decodes (empty lists) rather than fabricating rollups.
    static func decode(_ data: Data) -> LeadFacets? {
        try? JSONDecoder().decode(LeadFacets.self, from: data)
    }

    /// Subcategory picker options as `(value, count)` — valid rows only, garbage rows already dropped
    /// by the lenient decode. Never a fabricated (value, 0) placeholder.
    var subcategoryOptions: [(String, Int)] { subcategories.map { ($0.subcategory, $0.n) } }
}
