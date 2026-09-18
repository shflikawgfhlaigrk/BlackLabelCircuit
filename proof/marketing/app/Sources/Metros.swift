// Black Label Marketing — the built-in US metro catalog (real public lat/lon facts).
//
// Lifted verbatim out of LeadEngines.swift for the same reason as EmailEngine.swift: the finder
// lane in Sources/LeadFinder.swift takes a Metro, and it must be buildable without the SwiftUI
// half of the app so its consent refusal can be proven at runtime.
//
// These coordinates are the metro the buyer PICKS from this list. They are never the device's
// location — the Overpass consent disclosure in Sources/ProviderConsent.swift says exactly that.
import Foundation

// MARK: - US metros (real public facts: lat/lon)
struct Metro: Identifiable, Hashable {
    let id = UUID()
    let city: String
    let state: String
    let lat: Double
    let lon: Double
    var label: String { "\(city), \(state)" }
}

enum Markets {
    static let all: [Metro] = [
        Metro(city: "New York", state: "NY", lat: 40.7128, lon: -74.0060),
        Metro(city: "Los Angeles", state: "CA", lat: 34.0522, lon: -118.2437),
        Metro(city: "Chicago", state: "IL", lat: 41.8781, lon: -87.6298),
        Metro(city: "Houston", state: "TX", lat: 29.7604, lon: -95.3698),
        Metro(city: "Phoenix", state: "AZ", lat: 33.4484, lon: -112.0740),
        Metro(city: "Philadelphia", state: "PA", lat: 39.9526, lon: -75.1652),
        Metro(city: "San Antonio", state: "TX", lat: 29.4241, lon: -98.4936),
        Metro(city: "San Diego", state: "CA", lat: 32.7157, lon: -117.1611),
        Metro(city: "Dallas", state: "TX", lat: 32.7767, lon: -96.7970),
        Metro(city: "San Jose", state: "CA", lat: 37.3382, lon: -121.8863),
        Metro(city: "Austin", state: "TX", lat: 30.2672, lon: -97.7431),
        Metro(city: "Jacksonville", state: "FL", lat: 30.3322, lon: -81.6557),
        Metro(city: "Fort Worth", state: "TX", lat: 32.7555, lon: -97.3308),
        Metro(city: "Columbus", state: "OH", lat: 39.9612, lon: -82.9988),
        Metro(city: "Charlotte", state: "NC", lat: 35.2271, lon: -80.8431),
        Metro(city: "San Francisco", state: "CA", lat: 37.7749, lon: -122.4194),
        Metro(city: "Indianapolis", state: "IN", lat: 39.7684, lon: -86.1581),
        Metro(city: "Seattle", state: "WA", lat: 47.6062, lon: -122.3321),
        Metro(city: "Denver", state: "CO", lat: 39.7392, lon: -104.9903),
        Metro(city: "Washington", state: "DC", lat: 38.9072, lon: -77.0369),
        Metro(city: "Boston", state: "MA", lat: 42.3601, lon: -71.0589),
        Metro(city: "El Paso", state: "TX", lat: 31.7619, lon: -106.4850),
        Metro(city: "Nashville", state: "TN", lat: 36.1627, lon: -86.7816),
        Metro(city: "Detroit", state: "MI", lat: 42.3314, lon: -83.0458),
        Metro(city: "Oklahoma City", state: "OK", lat: 35.4676, lon: -97.5164),
        Metro(city: "Portland", state: "OR", lat: 45.5152, lon: -122.6784),
        Metro(city: "Las Vegas", state: "NV", lat: 36.1699, lon: -115.1398),
        Metro(city: "Memphis", state: "TN", lat: 35.1495, lon: -90.0490),
        Metro(city: "Louisville", state: "KY", lat: 38.2527, lon: -85.7585),
        Metro(city: "Baltimore", state: "MD", lat: 39.2904, lon: -76.6122),
        Metro(city: "Milwaukee", state: "WI", lat: 43.0389, lon: -87.9065),
        Metro(city: "Albuquerque", state: "NM", lat: 35.0844, lon: -106.6504),
        Metro(city: "Tucson", state: "AZ", lat: 32.2226, lon: -110.9747),
        Metro(city: "Fresno", state: "CA", lat: 36.7378, lon: -119.7871),
        Metro(city: "Sacramento", state: "CA", lat: 38.5816, lon: -121.4944),
        Metro(city: "Kansas City", state: "MO", lat: 39.0997, lon: -94.5786),
        Metro(city: "Mesa", state: "AZ", lat: 33.4152, lon: -111.8315),
        Metro(city: "Atlanta", state: "GA", lat: 33.7490, lon: -84.3880),
        Metro(city: "Miami", state: "FL", lat: 25.7617, lon: -80.1918),
        Metro(city: "Raleigh", state: "NC", lat: 35.7796, lon: -78.6382),
        Metro(city: "Minneapolis", state: "MN", lat: 44.9778, lon: -93.2650),
        Metro(city: "Tampa", state: "FL", lat: 27.9506, lon: -82.4572),
    ]
}

