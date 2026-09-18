// Black Label Real Estate — MULTI-SOURCE LEAD AGGREGATION (free public sources, honest gates).
//
// Five sourcing lanes, all on free/open data — never fabricated:
//   • Probate         — parse public notices (Model.parseProbate) + parcel-resolve to a real
//                        owner/address/assessed-value lead (ParcelLookup, county ArcGIS).
//   • New construction — builders/contractors/roofers from OpenStreetMap in a metro bbox.
//   • Absentee owner   — derived honestly from a parcel-resolved lead whose owner MAILING
//                        address differs from the property SITUS (the classic absentee signal).
//   • Tax-delinquent / Code-violation / Pre-foreclosure — gated lanes: these live behind
//                        per-county portals with NO free statewide API, so the app honestly
//                        asks the buyer to point it at their county's open dataset and shows a
//                        clear empty state. No fake records, ever.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A builder/contractor discovered in a market (OSM open data).
struct BuilderResult: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var kind: String        // builder / contractor / roofer
    var phone: String
    var website: String
    var address: String
    var domain: String {
        var d = website.lowercased().trimmingCharacters(in: .whitespaces)
        for p in ["https://", "http://", "www."] { d = d.replacingOccurrences(of: p, with: "") }
        if let s = d.firstIndex(of: "/") { d = String(d[..<s]) }
        return d
    }
}

enum BuilderFinder {
    // Construction trades the spec calls "builders" — each a real OSM tag set.
    static func query(metro: REMetro) -> String {
        let d = 0.18
        let bbox = String(format: "(%.4f,%.4f,%.4f,%.4f)", metro.lat - d, metro.lon - d, metro.lat + d, metro.lon + d)
        let tags = [
            "node[\"craft\"=\"builder\"]", "node[\"office\"=\"construction_company\"]",
            "node[\"craft\"=\"roofer\"]", "node[\"craft\"=\"carpenter\"]",
            "node[\"craft\"=\"plumber\"]", "node[\"shop\"=\"trade\"]"
        ]
        let body = tags.map { "  \($0)\(bbox);" }.joined(separator: "\n")
        return "[out:json][timeout:25];\n(\n\(body)\n);\nout body 80;"
    }
    static func search(metro: REMetro) async throws -> [BuilderResult] {
        let ql = query(metro: metro)
        var req = URLRequest(url: URL(string: "https://overpass-api.de/api/interpreter")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("BlackLabelRealEstate/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.httpBody = "data=\(ql.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ql)".data(using: .utf8)
        req.timeoutInterval = 30
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch { throw AreaFinderError.network(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw AreaFinderError.badResponse }
        guard http.statusCode == 200 else { throw AreaFinderError.http(http.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { throw AreaFinderError.badResponse }
        var seen = Set<String>(); var out: [BuilderResult] = []
        for el in elements {
            guard let tags = el["tags"] as? [String: Any],
                  let name = (tags["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let kind = (tags["craft"] as? String) ?? (tags["office"] as? String) ?? (tags["shop"] as? String) ?? "builder"
            let website = ((tags["website"] as? String) ?? (tags["contact:website"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let phone = ((tags["phone"] as? String) ?? (tags["contact:phone"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let street = [tags["addr:housenumber"] as? String, tags["addr:street"] as? String].compactMap { $0 }.joined(separator: " ")
            let addr = [street, (tags["addr:city"] as? String) ?? metro.city].filter { !$0.isEmpty }.joined(separator: ", ")
            let key = name.lowercased()
            if seen.contains(key) { continue }; seen.insert(key)
            out.append(BuilderResult(name: name, kind: kind, phone: phone, website: website, address: addr))
        }
        guard !out.isEmpty else { throw AreaFinderError.noResults }
        out.sort { (($0.phone.isEmpty ?0:1)+($0.website.isEmpty ?0:1)) > (($1.phone.isEmpty ?0:1)+($1.website.isEmpty ?0:1)) }
        return out
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Parcel-resolution path (probate name + county → a real, valued, contactable lead)
enum ParcelEnrich {
    /// Resolve a probate-style lead (name + county) into a fully-enriched lead off the county's
    /// open parcel layer: real situs address, assessed value, owner, mailing (skip-trace),
    /// ownership confidence, debt signals. Returns nil with an honest reason when gated.
    static func enrich(_ lead: Lead, fetch: ParcelLookup.Fetch = ParcelLookup.liveFetch) async -> (Lead, ParcelRecord) {
        let rec = await ParcelLookup.resolve(name: lead.name, county: lead.county, fetch: fetch)
        var l = lead
        // Populate whatever the county published. A pid-only / owner-search county (Cleveland) resolves
        // owner + parcel id + deed with NO situs address — it must still auto-populate lead.parcel (and
        // owner/mailing), so the gate is `rec.available` with at least one resolved field, not "has an
        // address". propertyAddress is written ONLY when a real situs came back (never fabricated).
        if rec.available, rec.address != nil || rec.owner != nil || rec.parcel != nil {
            if let addr = rec.address { l.propertyAddress = addr }
            l.ownerName = rec.owner ?? ""
            l.assessedValue = rec.assessedValue ?? 0
            l.parcel = rec.parcel ?? ""
            l.mailingAddress = rec.ownerMail.full
            l.ownershipConfidence = rec.ownershipConfidence.rawValue
            // Absentee signal: a mailing address that differs from the situs is the classic tell (only
            // computable when a situs address exists — a pid-only county can't produce this comparison).
            if let addr = rec.address, !rec.ownerMail.isEmpty, normalize(rec.ownerMail.street) != normalize(addr) {
                if l.source == .probate { l.sourceDetail = "Probate · absentee owner" }
            }
        }
        return (l, rec)
    }
    private static func normalize(_ s: String) -> String {
        s.uppercased().replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: "")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// Is this an absentee owner? (mailing street present and != situs).
    static func isAbsentee(_ rec: ParcelRecord) -> Bool {
        guard let situs = rec.address, !rec.ownerMail.isEmpty else { return false }
        return normalize(rec.ownerMail.street) != normalize(situs)
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - Gated source lanes (no free statewide API — honest "configure your county" state)
enum GatedSource: String, CaseIterable, Identifiable {
    case taxDelinquent, codeViolation, preForeclosure
    var id: String { rawValue }
    var source: LeadSource {
        switch self { case .taxDelinquent: return .taxDelinquent; case .codeViolation: return .codeViolation; case .preForeclosure: return .preForeclosure }
    }
    var title: String { source.label }
    var icon: String { source.icon }
    /// Honest explanation of why this lane is gated and what unlocks it — never a fake list.
    var explainer: String {
        switch self {
        case .taxDelinquent:
            return "Tax-delinquent rolls are published per county (tax commissioner / sheriff sale lists). There is no free statewide API. Paste your county's delinquent list below to import it — addresses and owners are kept exactly as published, never invented."
        case .codeViolation:
            return "Code-enforcement violations live in each city's open-data portal (often Socrata / ArcGIS). Point this at your jurisdiction's open dataset URL to pull them — nothing is fabricated."
        case .preForeclosure:
            return "Pre-foreclosure (lis pendens / notice of sale) is recorded at the county clerk and published in legal-notice papers. Paste a legal-notice block below and the on-device parser extracts owner names + properties — same engine as probate notices."
        }
    }
    /// Whether the on-device notice parser can extract leads from pasted text for this lane.
    var supportsPaste: Bool { self == .taxDelinquent || self == .preForeclosure }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    /// Import leads from a pasted county list / legal-notice block for a gated lane.
    /// Reuses the on-device probate parser (names + counties) — real extraction, no fabrication.
    func importPasted(_ text: String, source: LeadSource, detail: String) -> Int {
        let found = REMath.parseProbate(text).map { l -> Lead in
            var x = l; x.source = source; x.sourceDetail = detail; return x
        }
        addLeads(found)
        return found.count
    }
    /// Save a scouted teardown/lot-flip candidate as a lead (real assessor fields, no fabrication).
    func saveTeardown(_ c: TeardownCandidate, county: String) {
        addLeads([c.asLead(county: county)])
    }
    /// Save a discovered builder as a new-construction lead.
    func saveBuilder(_ b: BuilderResult, metro: REMetro) {
        let note = [b.address, b.website].filter { !$0.isEmpty }.joined(separator: " · ")
        var l = Lead(name: b.name, county: metro.city, source: .builder, sourceDetail: b.kind.capitalized,
                     phone: b.phone, notes: note)
        l.propertyAddress = b.address
        addLeads([l])
    }
}
#endif // circuit-convert
