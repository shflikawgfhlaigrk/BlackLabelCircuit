// Black Label Real Estate — live Census tract market intelligence.
//
// Address → Census Geocoder geography → 2024 + 2019 ACS 5-year tract estimates. This is intentionally
// NOT called a comp, AVM, or property value: it is neighborhood context from a cited survey. The
// buyer's Census API key stays in Keychain; an unmatched address or unavailable estimate remains
// empty. No address, geography, value, rent, income, or vacancy figure is invented.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct CensusTractGeography: Equatable {
    var matchedAddress: String
    var stateCode: String
    var stateName: String
    var countyCode: String
    var countyName: String
    var tractCode: String
    var tractName: String
    var latitude: Double?
    var longitude: Double?
}

struct CensusMarketSnapshot: Equatable {
    static let vintage = "2024 ACS 5-year"
    var year: Int
    var geography: CensusTractGeography
    var areaName: String
    var medianHomeValue: Int?
    var medianHomeValueMOE: Int?
    var medianGrossRent: Int?
    var medianGrossRentMOE: Int?
    var medianHouseholdIncome: Int?
    var medianHouseholdIncomeMOE: Int?
    var housingUnits: Int?
    var occupiedUnits: Int?
    var vacantUnits: Int?
    var fetchedAt: Date

    var vacancyRate: Double? {
        guard let vacantUnits, let housingUnits, housingUnits > 0 else { return nil }
        return Double(vacantUnits) / Double(housingUnits)
    }

    var vintage: String { "\(year) ACS 5-year" }
}

struct CensusMarketComparison: Equatable {
    var current: CensusMarketSnapshot
    var baseline: CensusMarketSnapshot?
    var baselineError: String?

    static func percentChange(current: Int?, baseline: Int?) -> Double? {
        guard let current, let baseline, baseline > 0 else { return nil }
        return (Double(current) - Double(baseline)) / Double(baseline)
    }

    static func differenceExceedsCombinedMOE(current: Int?, currentMOE: Int?,
                                             baseline: Int?, baselineMOE: Int?) -> Bool? {
        guard let current, let currentMOE, let baseline, let baselineMOE,
              currentMOE >= 0, baselineMOE >= 0 else { return nil }
        let combinedMOE = hypot(Double(currentMOE), Double(baselineMOE))
        return abs(Double(current - baseline)) > combinedMOE
    }

    var homeValueChange: Double? { Self.percentChange(current: current.medianHomeValue, baseline: baseline?.medianHomeValue) }
    var rentChange: Double? { Self.percentChange(current: current.medianGrossRent, baseline: baseline?.medianGrossRent) }
    var incomeChange: Double? { Self.percentChange(current: current.medianHouseholdIncome, baseline: baseline?.medianHouseholdIncome) }
    var vacancyPointChange: Double? {
        guard let current = current.vacancyRate, let baseline = baseline?.vacancyRate else { return nil }
        return current - baseline
    }
    var homeValueDifferenceExceedsMOE: Bool? {
        Self.differenceExceedsCombinedMOE(current: current.medianHomeValue,
                                          currentMOE: current.medianHomeValueMOE,
                                          baseline: baseline?.medianHomeValue,
                                          baselineMOE: baseline?.medianHomeValueMOE)
    }
    var rentDifferenceExceedsMOE: Bool? {
        Self.differenceExceedsCombinedMOE(current: current.medianGrossRent,
                                          currentMOE: current.medianGrossRentMOE,
                                          baseline: baseline?.medianGrossRent,
                                          baselineMOE: baseline?.medianGrossRentMOE)
    }
    var incomeDifferenceExceedsMOE: Bool? {
        Self.differenceExceedsCombinedMOE(current: current.medianHouseholdIncome,
                                          currentMOE: current.medianHouseholdIncomeMOE,
                                          baseline: baseline?.medianHouseholdIncome,
                                          baselineMOE: baseline?.medianHouseholdIncomeMOE)
    }
}

enum CensusMarketError: LocalizedError, Equatable {
    case emptyAddress
    case missingAPIKey
    case badRequest
    case transport(String)
    case http(Int, String)
    case noAddressMatch
    case missingGeography
    case unreadableResponse
    case noEstimate

    var errorDescription: String? {
        switch self {
        case .emptyAddress: return "Enter a complete U.S. property address."
        case .missingAPIKey: return "Add your Census Data API key to query current ACS estimates."
        case .badRequest: return "The Census request could not be built."
        case .transport(let detail): return "Could not reach the Census API (\(detail))."
        case .http(let code, let detail):
            return detail.isEmpty ? "The Census API returned HTTP \(code)." : detail
        case .noAddressMatch: return "The Census geocoder did not match that address. Check the street, city, state, and ZIP."
        case .missingGeography: return "The matched address did not include a Census tract."
        case .unreadableResponse: return "The Census API returned an unreadable response."
        case .noEstimate: return "No ACS tract estimate was returned for this address."
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum CensusMarketConfig {
    static let apiKeyAccount = "blre.censusAPIKey"
    static let lastAddressKey = "blre.censusMarket.lastAddress"
    static var apiKey: String? {
        guard let value = Keychain.get(account: apiKeyAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
    static var hasAPIKey: Bool { apiKey != nil }
    static func setAPIKey(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { Keychain.delete(account: apiKeyAccount) }
        else { Keychain.set(value, account: apiKeyAccount) }
    }
    static var lastAddress: String? {
        let value = UserDefaults.standard.string(forKey: lastAddressKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
    static func setLastAddress(_ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { UserDefaults.standard.set(value, forKey: lastAddressKey) }
    }
}
#endif // circuit-convert

enum CensusMarketIntelligence {
    static let acsYear = 2024
    static let baselineYear = 2019
    static let currentGeographyVintage = "Current_Current"
    static let baselineGeographyVintage = "ACS2019_Current"
    static let acsVariables = ["NAME", "B25077_001E", "B25077_001M",
                               "B25064_001E", "B25064_001M", "B19013_001E", "B19013_001M",
                               "B25002_001E", "B25002_002E", "B25002_003E"]

    static func geocodeURL(address rawAddress: String,
                           vintage: String = currentGeographyVintage) -> URL? {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        let vintage = vintage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, !vintage.isEmpty else { return nil }
        var components = URLComponents(string: "https://geocoding.geo.census.gov/geocoder/geographies/onelineaddress")!
        components.queryItems = [
            .init(name: "address", value: address),
            .init(name: "benchmark", value: "Public_AR_Current"),
            .init(name: "vintage", value: vintage),
            .init(name: "format", value: "json")
        ]
        return components.url
    }

    static func uniqueAddresses(_ candidates: [String], limit: Int = 10) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            let address = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty else { continue }
            let key = address.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { continue }
            result.append(address)
            if result.count == limit { break }
        }
        return result
    }

    static func parseGeography(_ data: Data) throws -> CensusTractGeography {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let matches = result["addressMatches"] as? [[String: Any]] else {
            throw CensusMarketError.unreadableResponse
        }
        guard let match = matches.first else { throw CensusMarketError.noAddressMatch }
        guard let geographies = match["geographies"] as? [String: Any],
              let tracts = geographies["Census Tracts"] as? [[String: Any]], let tract = tracts.first,
              let counties = geographies["Counties"] as? [[String: Any]], let county = counties.first,
              let states = geographies["States"] as? [[String: Any]], let state = states.first,
              let stateCode = state["STATE"] as? String,
              let countyCode = tract["COUNTY"] as? String,
              let tractCode = tract["TRACT"] as? String else {
            throw CensusMarketError.missingGeography
        }
        let coordinates = match["coordinates"] as? [String: Any]
        func number(_ value: Any?) -> Double? {
            if let value = value as? Double { return value }
            if let value = value as? Int { return Double(value) }
            if let value = value as? String { return Double(value) }
            return nil
        }
        return CensusTractGeography(
            matchedAddress: (match["matchedAddress"] as? String) ?? "",
            stateCode: stateCode,
            stateName: (state["NAME"] as? String) ?? (state["BASENAME"] as? String) ?? "",
            countyCode: countyCode,
            countyName: (county["NAME"] as? String) ?? (county["BASENAME"] as? String) ?? "",
            tractCode: tractCode,
            tractName: (tract["NAME"] as? String) ?? (tract["BASENAME"] as? String) ?? "",
            latitude: number(coordinates?["y"]),
            longitude: number(coordinates?["x"])
        )
    }

    static func acsURL(geography: CensusTractGeography, apiKey rawKey: String,
                       year: Int = acsYear) -> URL? {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, (2009...acsYear).contains(year) else { return nil }
        var components = URLComponents(string: "https://api.census.gov/data/\(year)/acs/acs5")!
        components.queryItems = [
            .init(name: "get", value: acsVariables.joined(separator: ",")),
            .init(name: "for", value: "tract:\(geography.tractCode)"),
            .init(name: "in", value: "state:\(geography.stateCode) county:\(geography.countyCode)"),
            .init(name: "key", value: key)
        ]
        return components.url
    }

    static func parseSnapshot(_ data: Data, geography: CensusTractGeography,
                              year: Int = acsYear, now: Date = Date()) throws -> CensusMarketSnapshot {
        guard let table = try? JSONSerialization.jsonObject(with: data) as? [[Any]], table.count >= 2,
              let headers = table.first as? [String], let row = table.dropFirst().first else {
            if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = root["error"] as? String, !error.isEmpty {
                throw CensusMarketError.http(400, error)
            }
            throw CensusMarketError.noEstimate
        }
        var values: [String: String] = [:]
        for (index, header) in headers.enumerated() where index < row.count {
            if let value = row[index] as? String { values[header] = value }
            else if let value = row[index] as? NSNumber { values[header] = value.stringValue }
        }
        func estimate(_ key: String) -> Int? {
            guard let raw = values[key], let value = Int(raw), value >= 0 else { return nil }
            return value
        }
        return CensusMarketSnapshot(
            year: year,
            geography: geography,
            areaName: values["NAME"] ?? "",
            medianHomeValue: estimate("B25077_001E"),
            medianHomeValueMOE: estimate("B25077_001M"),
            medianGrossRent: estimate("B25064_001E"),
            medianGrossRentMOE: estimate("B25064_001M"),
            medianHouseholdIncome: estimate("B19013_001E"),
            medianHouseholdIncomeMOE: estimate("B19013_001M"),
            housingUnits: estimate("B25002_001E"),
            occupiedUnits: estimate("B25002_002E"),
            vacantUnits: estimate("B25002_003E"),
            fetchedAt: now
        )
    }

    static func load(address rawAddress: String, apiKey rawKey: String,
                     session: URLSession = .shared) async throws -> CensusMarketSnapshot {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw CensusMarketError.emptyAddress }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CensusMarketError.missingAPIKey }
        guard let geocodeURL = geocodeURL(address: address) else { throw CensusMarketError.badRequest }
        let geocodeData = try await fetch(geocodeURL, session: session)
        let geography = try parseGeography(geocodeData)
        guard let marketURL = acsURL(geography: geography, apiKey: key) else { throw CensusMarketError.badRequest }
        let marketData = try await fetch(marketURL, session: session)
        return try parseSnapshot(marketData, geography: geography)
    }

    static func loadComparison(address rawAddress: String, apiKey rawKey: String,
                               session: URLSession = .shared) async throws -> CensusMarketComparison {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { throw CensusMarketError.emptyAddress }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw CensusMarketError.missingAPIKey }
        guard let currentGeocodeURL = geocodeURL(address: address, vintage: currentGeographyVintage) else {
            throw CensusMarketError.badRequest
        }
        let geography = try parseGeography(try await fetch(currentGeocodeURL, session: session))

        guard let currentURL = acsURL(geography: geography, apiKey: key, year: acsYear) else {
            throw CensusMarketError.badRequest
        }
        let current = try parseSnapshot(try await fetch(currentURL, session: session),
                                        geography: geography, year: acsYear)

        do {
            // ACS 2019 uses its own tract geography. Re-geocode the same address against that vintage
            // instead of assuming a current tract code existed with the same boundary in 2019.
            guard let historicalGeocodeURL = geocodeURL(address: address, vintage: baselineGeographyVintage) else {
                throw CensusMarketError.badRequest
            }
            let historicalGeography = try parseGeography(try await fetch(historicalGeocodeURL, session: session))
            guard let baselineURL = acsURL(geography: historicalGeography, apiKey: key, year: baselineYear) else {
                throw CensusMarketError.badRequest
            }
            let baseline = try parseSnapshot(try await fetch(baselineURL, session: session),
                                             geography: historicalGeography, year: baselineYear)
            return CensusMarketComparison(current: current, baseline: baseline, baselineError: nil)
        } catch {
            // Current evidence remains useful; the UI explicitly labels the missing historical read.
            return CensusMarketComparison(current: current, baseline: nil, baselineError: error.localizedDescription)
        }
    }

    private static func fetch(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw CensusMarketError.transport(error.localizedDescription) }
        guard let http = response as? HTTPURLResponse else { throw CensusMarketError.unreadableResponse }
        guard (200...299).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CensusMarketError.http(http.statusCode, String(detail.prefix(180)))
        }
        return data
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
struct MarketIntelligencePanel: View {
    @EnvironmentObject var model: AppModel
    @State private var address = ""
    @State private var keyDraft = ""
    @State private var hasKey = false
    @State private var loading = false
    @State private var note = ""
    @State private var comparison: CensusMarketComparison?

    private var savedAddresses: [String] {
        CensusMarketIntelligence.uniqueAddresses(
            [CensusMarketConfig.lastAddress].compactMap { $0 } +
            model.deals.map(\.address) + model.leads.map(\.propertyAddress)
        )
    }

    var body: some View {
        Panel(title: "Neighborhood Market Intelligence", icon: "map.fill", glow: comparison != nil) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose one of your saved properties or enter an address. The app geocodes it once, then compares published 2024 and 2019 tract estimates. This is neighborhood evidence, not a comp or AVM.")
                    .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                Text("1  Choose a property   ·   2  save a free Census key once   ·   3  run the live comparison")
                    .font(BLFont.body(10, .bold)).foregroundColor(BLTheme.gold)
                if !savedAddresses.isEmpty {
                    HStack(spacing: 9) {
                        Text("Your properties").font(BLFont.body(10.5, .semibold)).foregroundColor(BLTheme.sub)
                        Menu {
                            ForEach(savedAddresses, id: \.self) { saved in
                                Button(saved) { address = saved }
                            }
                        } label: {
                            Label(address.isEmpty ? "Choose saved address" : "Choose another", systemImage: "building.2.fill")
                                .font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.gold)
                        }
                    }
                }
                HStack(spacing: 9) {
                    Field(title: "Property address", text: $address, prompt: "Street, city, state, ZIP")
                    GoldButton(label: loading ? "Reading two periods…" : "Run live comparison", icon: "bolt.fill") { run() }
                        .disabled(loading || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  (!hasKey && keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
                HStack(spacing: 9) {
                    SecureField(hasKey ? "Census API key stored — paste to replace" : "Census Data API key", text: $keyDraft)
                        .textFieldStyle(.plain).font(BLFont.body(12, .medium)).foregroundColor(BLTheme.text)
                        .padding(.vertical, 10).padding(.horizontal, 12).background(BLTheme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    GhostButton(label: "Save key", icon: "key.fill") { saveKey() }
                    Link(destination: URL(string: "https://api.census.gov/data/key_signup.html")!) {
                        Label("Get free key", systemImage: "arrow.up.right")
                            .font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.gold)
                    }
                }
                if !note.isEmpty {
                    Text(note).font(BLFont.body(10.5, .semibold))
                        .foregroundColor(note.hasPrefix("✓") ? BLTheme.green : BL.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let comparison { result(comparison) }
            }
        }
        .onAppear {
            hasKey = CensusMarketConfig.hasAPIKey
            if address.isEmpty { address = CensusMarketConfig.lastAddress ?? savedAddresses.first ?? "" }
        }
    }

    @ViewBuilder private func result(_ comparison: CensusMarketComparison) -> some View {
        let result = comparison.current
        Divider().background(BLTheme.stroke)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.geography.matchedAddress).font(BLFont.body(12.5, .bold)).foregroundColor(BLTheme.text)
                Text("\(result.geography.countyName) · \(result.geography.tractName)")
                    .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            StatusPill(text: "LIVE CENSUS", tint: BLTheme.green)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: BLScale.cardMin(180, spacing: 12)), spacing: 12)], spacing: 12) {
            MetricCard(label: "Tract median home value", value: money(result.medianHomeValue), icon: "house.fill", accent: BLTheme.gold)
            MetricCard(label: "Median gross rent", value: money(result.medianGrossRent), icon: "key.fill", accent: .blue)
            MetricCard(label: "Median household income", value: money(result.medianHouseholdIncome), icon: "dollarsign.circle.fill", accent: BLTheme.green)
            MetricCard(label: "Housing vacancy", value: result.vacancyRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—", icon: "house.slash.fill", accent: .orange)
        }
        if let baseline = comparison.baseline {
            VStack(alignment: .leading, spacing: 6) {
                Text("CHANGE FROM 2019 BASELINE").font(BLFont.body(9, .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                trendRow("Median home value", current: money(result.medianHomeValue), baseline: money(baseline.medianHomeValue),
                         change: comparisonLabel(comparison.homeValueChange, comparison.homeValueDifferenceExceedsMOE))
                trendRow("Median gross rent", current: money(result.medianGrossRent), baseline: money(baseline.medianGrossRent),
                         change: comparisonLabel(comparison.rentChange, comparison.rentDifferenceExceedsMOE))
                trendRow("Median household income", current: money(result.medianHouseholdIncome), baseline: money(baseline.medianHouseholdIncome),
                         change: comparisonLabel(comparison.incomeChange, comparison.incomeDifferenceExceedsMOE))
                trendRow("Housing vacancy", current: vacancy(result.vacancyRate), baseline: vacancy(baseline.vacancyRate),
                         change: comparison.vacancyPointChange.map { String(format: "%+.1f pts", $0 * 100) } ?? "No baseline")
            }
            .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            Text("Comparison: 2020–2024 ACS versus 2015–2019 ACS, with the address mapped to each period's tract geography. Dollar changes are nominal. ‘Exceeds MOE’ means the difference is larger than the two published 90% margins combined; geography, methodology, and inflation can still affect interpretation. Vacancy is directional because this panel does not calculate a ratio margin of error.")
                .font(BLFont.body(9.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        } else if let baselineError = comparison.baselineError {
            Text("Current estimates loaded. The 2019 benchmark is unavailable: \(baselineError)")
                .font(BLFont.body(10, .semibold)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
        }
        Text("Source: U.S. Census Bureau · \(result.vintage) · tract estimates · fetched \(result.fetchedAt.formatted(date: .abbreviated, time: .shortened)). Survey estimates are market context only; use recorded sales for ARV.")
            .font(BLFont.body(9.5, .medium)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func trendRow(_ label: String, current: String, baseline: String, change: String) -> some View {
        // The desktop row reserves a fixed 132pt change column for cross-row alignment; on a phone
        // that column starves the metric label into a 3-line sliver, so compact stacks the label
        // over its values instead.
        Group {
            if BLScale.isCompact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    HStack(spacing: 8) {
                        Text("2019  \(baseline)").foregroundColor(BLTheme.sub)
                        Text("2024  \(current)").foregroundColor(BLTheme.text)
                        Spacer(minLength: 8)
                        Text(change).foregroundColor(BLTheme.gold).multilineTextAlignment(.trailing)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Text(label).frame(maxWidth: .infinity, alignment: .leading)
                    Text("2019  \(baseline)").foregroundColor(BLTheme.sub)
                    Text("2024  \(current)").foregroundColor(BLTheme.text)
                    Text(change).foregroundColor(BLTheme.gold).frame(width: 132, alignment: .trailing)
                }
            }
        }
        .font(BLFont.body(9.5, .semibold))
    }

    private func money(_ value: Int?) -> String {
        guard let value else { return "—" }
        return value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    private func vacancy(_ value: Double?) -> String {
        value.map { String(format: "%.1f%%", $0 * 100) } ?? "—"
    }

    private func percent(_ value: Double?) -> String {
        value.map { String(format: "%+.1f%%", $0 * 100) } ?? "No baseline"
    }

    private func comparisonLabel(_ value: Double?, _ exceedsMOE: Bool?) -> String {
        let change = percent(value)
        guard let exceedsMOE else { return "\(change) · MOE unavailable" }
        return "\(change) · \(exceedsMOE ? "exceeds MOE" : "within MOE")"
    }

    private func saveKey() {
        if !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            CensusMarketConfig.setAPIKey(keyDraft); keyDraft = ""
        }
        hasKey = CensusMarketConfig.hasAPIKey
        note = hasKey ? "Key saved. Run a live address read to verify it." : CensusMarketError.missingAPIKey.localizedDescription
    }

    private func run() {
        if !keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saveKey() }
        guard let key = CensusMarketConfig.apiKey else { note = CensusMarketError.missingAPIKey.localizedDescription; return }
        loading = true; note = ""; comparison = nil
        Task {
            do {
                let result = try await CensusMarketIntelligence.loadComparison(address: address, apiKey: key)
                await MainActor.run {
                    CensusMarketConfig.setLastAddress(address)
                    comparison = result; loading = false
                    note = result.baseline == nil
                        ? "✓ Live 2024 tract estimates loaded; the historical benchmark is labeled below."
                        : "✓ Live 2024 and 2019 tract estimates loaded and compared."
                }
            } catch {
                await MainActor.run { loading = false; note = error.localizedDescription }
            }
        }
    }
}
#endif // circuit-convert
