// Weather — real current conditions via Open-Meteo (free, no API key) with optional
// CoreLocation forward-geocoding of a typed city. Folded in from the lean Sovereign
// build. Kept self-contained: the engine here is the single source of truth for the
// Open-Meteo URL, the WMO weather-code map, and the response decoding; the richer
// WeatherService (Model.swift) and the WeatherScreen (Screens.swift) both call into it.
//
// AppKit is only needed by the host app, never the headless test target — guard it so
// the logic (URL/decoding/describe) compiles everywhere.
#if canImport(AppKit)
import AppKit
#endif
import Foundation
#if canImport(CoreLocation) && !CIRCUIT_WINDOWS_SIM
import CoreLocation
#endif

// Renamed from the lean app's `AppInfo` to avoid colliding with the full app's own
// branding (settings.assistantName / "Sovereign").
enum WeatherInfo {
    static let source = "Open-Meteo"
    static let attribution = "Live data from open-meteo.com"
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Renamed from the lean app's `SovEngine` — the full app already owns its capability
// surface (Connectors). This is strictly the weather engine.
enum WeatherEngine {
    /// WMO weather-interpretation codes → human conditions text.
    static let wmo: [Int: String] = [
        0: "Clear sky", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
        45: "Fog", 48: "Rime fog", 51: "Light drizzle", 53: "Drizzle", 55: "Dense drizzle",
        56: "Freezing drizzle", 57: "Dense freezing drizzle",
        61: "Light rain", 63: "Rain", 65: "Heavy rain",
        66: "Freezing rain", 67: "Heavy freezing rain",
        71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
        80: "Light showers", 81: "Showers", 82: "Violent showers",
        85: "Snow showers", 86: "Heavy snow showers",
        95: "Thunderstorm", 96: "Thunderstorm w/ hail", 99: "Severe thunderstorm w/ hail",
    ]

    /// Open-Meteo current-conditions response.
    struct OMResp: Decodable {
        let current: Current?
        struct Current: Decodable {
            let temperature_2m: Double?
            let relative_humidity_2m: Double?
            let precipitation: Double?
            let weather_code: Int?
            let wind_speed_10m: Double?
        }
    }

    /// Human-readable one-line summary (used for accessibility / brain-style descriptions).
    static func describe(_ r: OMResp, label: String) -> String {
        guard let c = r.current else { return "\(label): no current conditions returned." }
        var parts = ["\(label): \((wmo[c.weather_code ?? -1] ?? "Unknown conditions").lowercased())"]
        if let t = c.temperature_2m { parts.append("\(Int(t.rounded()))°F") }
        if let h = c.relative_humidity_2m { parts.append("\(Int(h.rounded()))% humidity") }
        if let w = c.wind_speed_10m { parts.append("wind \(Int(w.rounded())) mph") }
        if let p = c.precipitation, p > 0 { parts.append("\(p) in precipitation") }
        return parts.joined(separator: ", ") + "."
    }

    static func conditions(for code: Int?) -> String {
        wmo[code ?? -1] ?? "Unknown conditions"
    }

    /// PRIVACY — the coarse-location clamp. Apple's App Privacy definitions draw the Precise/Coarse
    /// line numerically: Precise Location is "a latitude and longitude with three or more decimal
    /// places." `CLGeocoder.geocodeAddressString` will happily resolve a full street address to
    /// rooftop precision, and this app then puts that coordinate in a query string bound for a third
    /// party (api.open-meteo.com), which sees it alongside the request IP.
    ///
    /// A weather lookup does not need that. Rounding to 2 decimal places (~1.1 km of latitude) keeps
    /// the transmitted coordinate strictly BELOW Apple's Precise threshold and inside the Coarse
    /// band, matches the preset city table (already stored at 2 dp), and changes nothing the buyer
    /// can perceive — current conditions are identical at 1 km resolution.
    ///
    /// This is what makes the manifest's CoarseLocation declaration structurally true instead of
    /// merely usually-true: the app CANNOT transmit a precise-resolution coordinate, so there is no
    /// PreciseLocation to declare. `weatherURL` is the single source of truth for the Open-Meteo URL
    /// and every path (typed place, quick-pick preset) routes through it, so the clamp is total.
    static func coarsen(_ degrees: Double) -> Double {
        (degrees * 100).rounded() / 100
    }

    /// Keyless Open-Meteo current-conditions endpoint (Fahrenheit + mph + inches).
    /// The coordinate is coarsened to 2 decimal places before it leaves the device (see `coarsen`).
    static func weatherURL(lat: Double, lon: Double) -> URL {
        let lat = coarsen(lat), lon = coarsen(lon)
        return URL(string: "https://api.open-meteo.com/v1/forecast"
            + "?latitude=\(lat)&longitude=\(lon)"
            + "&current=temperature_2m,relative_humidity_2m,precipitation,weather_code,wind_speed_10m"
            + "&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch")!
    }

    /// Forward-geocode a typed place ("City, ST" or any address) to coordinates.
    /// Uses CLGeocoder, which resolves over Apple's network service — it needs the
    /// network.client entitlement (already declared) but NOT location-services
    /// authorization, so no new entitlement / usage string and the App Store sandbox
    /// build is unaffected.
    ///
    /// PRIVACY — needing no location-services authorization is NOT the same as collecting no
    /// location. Apple's data-type definitions key on what the value DESCRIBES and at what
    /// RESOLUTION, not on which API produced it; there is no "typed by the user rather than sensed"
    /// carve-out. The resulting coordinate is transmitted to a third party (api.open-meteo.com), and
    /// in this app's actual UX ("Search any city", prompt "City, ST") the place typed is usually the
    /// buyer's own. So it is declared: NSPrivacyCollectedDataTypeCoarseLocation in
    /// PrivacyInfo.xcprivacy, with `weatherURL` clamping the coordinate to the Coarse band before it
    /// leaves the device. The full-precision value returned here never goes off-device by any other
    /// path — the only consumer is WeatherService.fetch(place:), which hands it straight to
    /// `weatherURL`; the resolved `name` is display-only.
    static func geocode(_ place: String) async throws -> (lat: Double, lon: Double, name: String) {
        let marks = try await CLGeocoder().geocodeAddressString(place)
        guard let loc = marks.first?.location else { throw WeatherError.noMatch }
        let resolved = [marks.first?.locality, marks.first?.administrativeArea]
            .compactMap { $0 }.joined(separator: ", ")
        return (loc.coordinate.latitude, loc.coordinate.longitude,
                resolved.isEmpty ? place : resolved)
    }
}
#endif // circuit-convert
