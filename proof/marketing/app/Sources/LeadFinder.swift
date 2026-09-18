// Black Label Marketing — the industry/market lead finder (OpenStreetMap Overpass).
//
// Lifted out of LeadEngines.swift so this lane can be COMPILED AND EXECUTED standalone in the
// headless suite (Tests/EgressChokePointTests.swift). The consent gate protecting it used to be
// proven only by a regex over LeadEngines.swift, and a regex cannot distinguish a live condition
// from `if false, …`. Now the refusal is proven by running the code.
//
// Foundation-only. Nothing changed in the move except that the two POSTs go through
// Sources/ConsentedEgress.swift instead of calling URLSession here.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Lead discovery BY INDUSTRY + market (real OpenStreetMap Overpass API — free, keyless, open data, no SDK)
// Honest: returns real businesses tagged in OpenStreetMap for the chosen vertical near the chosen metro.
// This is the primary finder — discovery by field/industry, not by a person's name.
struct DiscoveredLead: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var website: String
    var phone: String
    var address: String
    var type: ProspectType
    /// Domain parsed from the listed website (empty if the business has no site tagged).
    var domain: String { website.isEmpty ? "" : EmailEngine.normalizeDomain(website) }
    /// Role-based business email guess (no person name needed) when a domain exists.
    var suggestedEmail: String { domain.isEmpty ? "" : "info@\(domain)" }
    var hasContact: Bool { !website.isEmpty || !phone.isEmpty }
}

enum LeadFinderError: LocalizedError {
    case badResponse, http(Int), noResults, network(String)
    /// No Overpass operator has a current grant — the typed search was never transmitted.
    case consentRequired(String)
    var errorDescription: String? {
        switch self {
        case .badResponse: return "The lead source returned data we couldn't read. Please try again."
        case .http(let c): return "The lead source is busy (HTTP \(c)). Wait a moment and try again."
        case .noResults:   return "No listed businesses found for that industry in this metro. Try a nearby city or a broader keyword."
        case .network(let m): return m
        case .consentRequired(let refusal): return refusal
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum LeadFinder {
    static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!
    ]

    /// The consent identity of each entry in `endpoints`, in the same order. Two independent
    /// volunteer operators ⇒ two grants; see Sources/ProviderConsent.swift.
    ///
    /// NOTE FOR WHOEVER WIRES THIS UP: nothing in the app currently calls `LeadFinder.search`
    /// (MktFinder in Model.swift is the shipped finder). It is gated anyway — an ungated lane
    /// sitting one call site away from being live is how this defect got here in the first place.
    static let endpointProviders: [TransmissionProvider] = [.overpassMain, .overpassPrivateCoffee]
    /// Real OpenStreetMap tag filters per vertical — how these businesses are actually tagged in OSM.
    static func filters(_ t: ProspectType) -> [String] {
        switch t {
        case .realEstate: return ["node[\"office\"=\"estate_agent\"]", "node[\"shop\"=\"estate_agent\"]"]
        case .agency:     return ["node[\"office\"=\"advertising_agency\"]", "node[\"office\"=\"company\"]"]
        case .ecommerce:  return ["node[\"shop\"=\"computer\"]", "node[\"shop\"=\"electronics\"]"]
        case .restaurant: return ["node[\"amenity\"=\"restaurant\"]", "node[\"amenity\"=\"cafe\"]"]
        case .fitness:    return ["node[\"leisure\"=\"fitness_centre\"]", "node[\"leisure\"=\"sports_centre\"]"]
        case .dental:     return ["node[\"amenity\"=\"dentist\"]", "node[\"healthcare\"=\"dentist\"]"]
        case .legal:      return ["node[\"office\"=\"lawyer\"]"]
        case .contractor: return ["node[\"craft\"]", "node[\"shop\"=\"trade\"]"]
        case .saas:       return ["node[\"office\"=\"it\"]", "node[\"office\"=\"company\"]"]
        case .other:      return []   // keyword-driven
        }
    }

    /// Build the Overpass QL for a vertical (+ optional keyword) within a metro bbox.
    static func query(type: ProspectType, metro: Metro, keyword: String) -> String {
        let d = 0.12
        let bbox = String(format: "(%.4f,%.4f,%.4f,%.4f)", metro.lat - d, metro.lon - d, metro.lat + d, metro.lon + d)
        // Only letters and digits of the typed keyword survive, joined by an optional
        // non-alphanumeric run. Two reasons, and both matter:
        //   1. TRUTH — the consent disclosure for .overpassMain/.overpassPrivateCoffee promises
        //      that only "the letters and digits of that name" leave. Interpolating the raw
        //      string (what this line used to do) made that disclosure false.
        //   2. CORRECTNESS — a raw keyword puts regex metacharacters and quotes straight into
        //      the Overpass QL. "a+ auto" or a stray `"` is an HTTP 400, and worse, a crafted
        //      keyword could close the clause and append its own.
        // Same helper the shipped finder uses, so both lanes send the identical shape.
        let rx = MktFinder.nameRegex(for: keyword.trimmingCharacters(in: .whitespaces))
        let kw = rx ?? ""
        var clauses: [String]
        if type == .other && !kw.isEmpty {
            clauses = ["node[\"name\"~\"\(kw)\",i]\(bbox)", "node[\"shop\"~\"\(kw)\",i]\(bbox)",
                       "node[\"office\"~\"\(kw)\",i]\(bbox)", "node[\"amenity\"~\"\(kw)\",i]\(bbox)"]
        } else {
            clauses = filters(type).map { "\($0)\(bbox)" }
            if !kw.isEmpty { clauses.append("node[\"name\"~\"\(kw)\",i]\(bbox)") }
            if clauses.isEmpty { clauses = ["node[\"name\"~\"business\",i]\(bbox)"] }
        }
        let body = clauses.map { "  \($0);" }.joined(separator: "\n")
        return "[out:json][timeout:25];\n(\n\(body)\n);\nout body 80;"
    }

    /// Live search against the public Overpass API. Returns real businesses with contact info first.
    static func search(type: ProspectType, metro: Metro, keyword: String) async throws -> [DiscoveredLead] {
        let ql = query(type: type, metro: metro, keyword: keyword)
        let data = try await fetchWithFallback(query: ql)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { throw LeadFinderError.badResponse }

        var seen = Set<String>(); var out: [DiscoveredLead] = []
        for el in elements {
            guard let tags = el["tags"] as? [String: Any],
                  let name = (tags["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let website = ((tags["website"] as? String) ?? (tags["contact:website"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let phone = ((tags["phone"] as? String) ?? (tags["contact:phone"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let street = [tags["addr:housenumber"] as? String, tags["addr:street"] as? String].compactMap { $0 }.joined(separator: " ")
            let city = (tags["addr:city"] as? String) ?? metro.city
            let address = [street, city].filter { !$0.isEmpty }.joined(separator: ", ")
            let key = name.lowercased() + "|" + website.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(DiscoveredLead(name: name, website: website, phone: phone, address: address, type: type))
        }
        guard !out.isEmpty else { throw LeadFinderError.noResults }
        // Most-actionable first: businesses with website + phone rank highest.
        out.sort { (($0.website.isEmpty ? 0 : 2) + ($0.phone.isEmpty ? 0 : 1)) > (($1.website.isEmpty ? 0 : 2) + ($1.phone.isEmpty ? 0 : 1)) }
        return out
    }

    private static func fetchWithFallback(query: String) async throws -> Data {
        var lastError: Error = LeadFinderError.badResponse
        // CONSENT BEFORE THE SOCKET — identical rule to MktFinder.fetchWithFallback, and identical
        // mechanics: the decision is NOT made on this side. Every POST goes through
        // ConsentedEgress.send, which consults TransmissionConsentStore itself. There is no
        // caller-side `if` here whose deletion or short-circuiting could let a refused operator
        // receive the buyer's typed search.
        var refusals: [String] = []
        for (endpoint, provider) in zip(endpoints, endpointProviders) {
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("BlackLabelMarketing/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            req.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)".data(using: .utf8)
            req.timeoutInterval = 25
            do {
                let (data, response) = try await ConsentedEgress.send(req, to: provider)
                guard let http = response as? HTTPURLResponse else { lastError = LeadFinderError.badResponse; continue }
                if http.statusCode == 200 { return data }
                lastError = LeadFinderError.http(http.statusCode)
                if !(http.statusCode == 429 || (500...599).contains(http.statusCode)) { throw lastError }
            } catch let error as ConsentedEgressError {
                if case .consentRefused(_, let refusal) = error {
                    refusals.append(refusal)
                    continue
                }
                throw LeadFinderError.network(error.localizedDescription)
            } catch let error as LeadFinderError {
                lastError = error
                if case .http(let status) = error,
                   !(status == 429 || (500...599).contains(status)) { throw error }
            } catch {
                lastError = LeadFinderError.network(error.localizedDescription)
            }
        }
        // Every operator was refused ⇒ zero bytes left this device.
        if refusals.count == endpoints.count, let first = refusals.first {
            throw LeadFinderError.consentRequired(first)
        }
        throw lastError
    }
}
#endif // circuit-convert
