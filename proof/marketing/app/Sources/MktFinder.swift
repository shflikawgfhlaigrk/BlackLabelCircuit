// Black Label Marketing — the shipped client finder (OpenStreetMap Overpass).
//
// Lifted out of Model.swift verbatim so this lane can be COMPILED AND EXECUTED on its own in the
// headless suite. That matters: the consent gate protecting it was previously proven only by
// grepping Model.swift, and a grep cannot tell a live `if` from a dead one. Tests/
// EgressChokePointTests.swift now runs `MktFinder.search` for real against a recording transport
// and asserts that a refused operator receives nothing — which was impossible while this code sat
// inside a 2,200-line SwiftUI file that no headless suite could build.
//
// Foundation-only, exactly as it was; no behaviour changed in the move except that the two POSTs
// now go through Sources/ConsentedEgress.swift instead of calling URLSession directly.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Find clients to pitch BY INDUSTRY + market (real OpenStreetMap Overpass API — free, keyless, open data)
// Honest: returns real local businesses (by vertical + metro) you could pitch marketing services to. Real listings only.
struct MktMetro: Identifiable, Hashable {
    let id = UUID(); let city: String; let state: String; let lat: Double; let lon: Double
    var label: String { "\(city), \(state)" }
}
enum MktMarkets {
    static let all: [MktMetro] = [
        .init(city: "Atlanta", state: "GA", lat: 33.7490, lon: -84.3880), .init(city: "New York", state: "NY", lat: 40.7128, lon: -74.0060),
        .init(city: "Los Angeles", state: "CA", lat: 34.0522, lon: -118.2437), .init(city: "Chicago", state: "IL", lat: 41.8781, lon: -87.6298),
        .init(city: "Houston", state: "TX", lat: 29.7604, lon: -95.3698), .init(city: "Miami", state: "FL", lat: 25.7617, lon: -80.1918),
        .init(city: "Dallas", state: "TX", lat: 32.7767, lon: -96.7970), .init(city: "Phoenix", state: "AZ", lat: 33.4484, lon: -112.0740),
        .init(city: "Nashville", state: "TN", lat: 36.1627, lon: -86.7816), .init(city: "Austin", state: "TX", lat: 30.2672, lon: -97.7431),
        .init(city: "Denver", state: "CO", lat: 39.7392, lon: -104.9903), .init(city: "Tampa", state: "FL", lat: 27.9506, lon: -82.4572),
        .init(city: "Charlotte", state: "NC", lat: 35.2271, lon: -80.8431), .init(city: "Seattle", state: "WA", lat: 47.6062, lon: -122.3321),
        .init(city: "Las Vegas", state: "NV", lat: 36.1699, lon: -115.1398), .init(city: "Orlando", state: "FL", lat: 28.5383, lon: -81.3792)
    ]
}
enum MktVertical: String, CaseIterable, Identifiable {
    case restaurant = "Restaurants", fitness = "Gyms / Fitness", dental = "Dental", realEstate = "Real estate"
    case salon = "Salons / Spas", retail = "Retail / Boutiques", legal = "Law firms", auto = "Auto services"
    var id: String { rawValue }
    var filters: [String] {
        switch self {
        case .restaurant: return ["node[\"amenity\"=\"restaurant\"]", "node[\"amenity\"=\"cafe\"]"]
        case .fitness:    return ["node[\"leisure\"=\"fitness_centre\"]", "node[\"leisure\"=\"sports_centre\"]"]
        case .dental:     return ["node[\"amenity\"=\"dentist\"]", "node[\"healthcare\"=\"dentist\"]"]
        case .realEstate: return ["node[\"office\"=\"estate_agent\"]"]
        case .salon:      return ["node[\"shop\"=\"hairdresser\"]", "node[\"shop\"=\"beauty\"]", "node[\"leisure\"=\"spa\"]"]
        case .retail:     return ["node[\"shop\"=\"clothes\"]", "node[\"shop\"=\"boutique\"]"]
        case .legal:      return ["node[\"office\"=\"lawyer\"]"]
        case .auto:       return ["node[\"shop\"=\"car_repair\"]", "node[\"shop\"=\"car\"]"]
        }
    }
}
struct BizResult: Identifiable, Hashable {
    let id = UUID(); var name: String; var phone: String; var website: String; var email: String = ""; var address: String; var industry: String
    var domain: String {
        var d = website.lowercased().trimmingCharacters(in: .whitespaces)
        for p in ["https://", "http://", "www."] { d = d.replacingOccurrences(of: p, with: "") }
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        return d
    }
}
enum MktFinderError: LocalizedError {
    case badResponse, http(Int), noResults, network(String)
    /// No Overpass operator has a current grant, so the typed search was never transmitted.
    /// Its own case (never folded into `.network`) so the surface cannot mistake a refusal
    /// for an outage and retry into a send.
    case consentRequired(String)
    var errorDescription: String? {
        switch self {
        case .badResponse: return "The source returned data we couldn't read. Please try again."
        case .http(let c): return "The source is busy (HTTP \(c)). Wait a moment and try again."
        case .noResults:   return "No listed businesses matched in this metro. If you searched a name, that business may not be on the open map here — try the name without a keyword, a broader keyword, or a nearby city."
        case .network(let m): return m
        case .consentRequired(let refusal): return refusal
        }
    }
}
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum MktFinder {
    /// Public global Overpass instances listed by OpenStreetMap. A transient 429/5xx on one host
    /// falls through to the next host; semantic 200 responses are never merged or fabricated.
    ///
    /// EACH host is paired with its OWN TransmissionProvider. These are two independent volunteer
    /// operators, and the fallback means the second one receives the identical query — so the
    /// buyer's grant is taken per operator and the fallback SKIPS any operator that was not
    /// granted. See Sources/ProviderConsent.swift.
    static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!
    ]

    /// The consent identity of each entry in `endpoints`, in the same order.
    static let endpointProviders: [TransmissionProvider] = [.overpassMain, .overpassPrivateCoffee]

    /// Build a punctuation-tolerant, injection-safe Overpass `name` regex from a typed
    /// business name. Only letters/digits survive (so NO regex metacharacter can ever
    /// reach the query and break it — the old code injected the raw keyword, which made
    /// "papa johns (downtown)", "a+ auto", etc. an HTTP 400 syntax error). The survivors
    /// are joined with an optional non-alphanumeric run so the apostrophe/space in the
    /// real listing "Papa John's" is absorbed and the search actually finds it.
    static func nameRegex(for keyword: String) -> String? {
        let chars = keyword.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !chars.isEmpty else { return nil }
        return chars.map(String.init).joined(separator: "[^a-z0-9]*")
    }

    /// Post-filter: does `name` contain the typed keyword once both are reduced to their
    /// alphanumeric characters? This is the same tolerance applied locally, so a real
    /// listing like "Papa John's" matches a "papa johns" query (apostrophe absorbed)
    /// while an unrelated name is still rejected (zero fabrication).
    static func nameMatches(_ name: String, keyword: String) -> Bool {
        func norm(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }
        let k = norm(keyword)
        guard !k.isEmpty else { return true }
        return norm(name).contains(k)
    }

    static func search(vertical: MktVertical, metro: MktMetro, keyword: String) async throws -> [BizResult] {
        let d = 0.12
        let bbox = String(format: "(%.4f,%.4f,%.4f,%.4f)", metro.lat - d, metro.lon - d, metro.lat + d, metro.lon + d)
        let kw = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        // When the user types a NAME, they want that specific business — not the whole
        // vertical. Searching name-only is also what makes the result correct: the prior
        // code unioned the name clause with the vertical flood under a single `out body 80`
        // cap, so the hundreds of restaurant/cafe nodes crowded the named match out of the
        // cap and the search returned nothing. Name present -> name-only query (vertical is
        // just the industry label). No keyword -> browse the whole vertical as before.
        let clauses: [String]
        if let rx = nameRegex(for: kw) {
            clauses = ["node[\"name\"~\"\(rx)\",i]\(bbox)"]
        } else {
            clauses = vertical.filters.map { "\($0)\(bbox)" }
        }
        let ql = "[out:json][timeout:20];\n(\n" + clauses.map { "  \($0);" }.joined(separator: "\n") + "\n);\nout body 80;"
        let data = try await fetchWithFallback(query: ql)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { throw MktFinderError.badResponse }
        var seen = Set<String>(); var out: [BizResult] = []
        for el in elements {
            guard let tags = el["tags"] as? [String: Any],
                  let name = (tags["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { continue }
            let website = ((tags["website"] as? String) ?? (tags["contact:website"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let phone = ((tags["phone"] as? String) ?? (tags["contact:phone"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let email = ((tags["email"] as? String) ?? (tags["contact:email"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let street = [tags["addr:housenumber"] as? String, tags["addr:street"] as? String].compactMap { $0 }.joined(separator: " ")
            let address = [street, (tags["addr:city"] as? String) ?? metro.city].filter { !$0.isEmpty }.joined(separator: ", ")
            let key = name.lowercased()
            if seen.contains(key) { continue }; seen.insert(key)
            out.append(BizResult(name: name, phone: phone, website: website, email: email, address: address, industry: vertical.rawValue))
        }
        // When a keyword is given, the user is searching for a specific business by NAME.
        // The Overpass union also returns the whole vertical, so narrow to real name matches —
        // never present generic listings as if they matched the typed name (zero fabrication).
        // Uses the same punctuation-tolerant comparison as the query so "papa johns" keeps
        // the real "Papa John's" listing instead of silently dropping it.
        if nameRegex(for: kw) != nil { out = out.filter { nameMatches($0.name, keyword: kw) } }
        guard !out.isEmpty else { throw MktFinderError.noResults }
        out.sort { (($0.website.isEmpty ?0:2)+($0.phone.isEmpty ?0:1)) > (($1.website.isEmpty ?0:2)+($1.phone.isEmpty ?0:1)) }
        return out
    }

    private static func fetchWithFallback(query: String) async throws -> Data {
        var lastError: Error = MktFinderError.badResponse
        // CONSENT BEFORE THE SOCKET — and the consent decision is NOT made here. Every POST goes
        // through ConsentedEgress.send, which consults TransmissionConsentStore itself before it
        // will move a byte. There is deliberately no `if` on this side to delete, invert or
        // short-circuit: a refused operator surfaces as ConsentedEgressError.consentRefused, is
        // skipped, and is never failed over into. If every operator is refused, nothing was
        // transmitted at all and the buyer is shown the first refusal verbatim.
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
                guard let http = response as? HTTPURLResponse else {
                    lastError = MktFinderError.badResponse
                    continue
                }
                if http.statusCode == 200 { return data }
                lastError = MktFinderError.http(http.statusCode)
                // Auth/syntax/client errors are deterministic; only capacity/server failures fail over.
                if !(http.statusCode == 429 || (500...599).contains(http.statusCode)) { throw lastError }
            } catch let error as ConsentedEgressError {
                // A refusal is NOT an outage: record it and skip this operator entirely.
                if case .consentRefused(_, let refusal) = error {
                    refusals.append(refusal)
                    continue
                }
                throw MktFinderError.network(error.localizedDescription)
            } catch let error as MktFinderError {
                lastError = error
                if case .http(let status) = error,
                   !(status == 429 || (500...599).contains(status)) { throw error }
            } catch {
                lastError = MktFinderError.network(error.localizedDescription)
            }
        }
        // Every operator was refused ⇒ zero bytes left this device.
        if refusals.count == endpoints.count, let first = refusals.first {
            throw MktFinderError.consentRequired(first)
        }
        throw lastError
    }
}
#endif // circuit-convert
