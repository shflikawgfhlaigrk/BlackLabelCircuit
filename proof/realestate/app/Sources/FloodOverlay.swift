// Black Label Real Estate — RE-19 FEMA flood-zone OVERLAY on the Property Map (real, cited, honest).
//
// The RedevelopmentScore heat shading answers "is this a teardown?"; the Teardown Radar's next
// question for an investor is "will it flood?" — an SFHA (Special Flood Hazard Area) parcel needs
// flood insurance and prices differently. This module pulls the LIVE FEMA National Flood Hazard
// Layer (NFHL) for the current map viewport and draws the real flood-zone polygons on top of the
// heat, each labeled with its FEMA zone + a source/date stamp. It NEVER fabricates a polygon: when
// the layer has no coverage (or the public service times out — it is slow and throttled), the map
// shows an honest "no FEMA flood data for this view" note, never an invented zone.
//
// Endpoint (live-verified 2026-07-11): the NFHL MapServer layer 28 "Flood Hazard Zones"
//   https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/28
//   geometryType=esriGeometryPolygon; fields FLD_ZONE, ZONE_SUBTY, SFHA_TF, STATIC_BFE.
//
// The URL builder and the FeatureSet parser are PURE (no I/O), so the whole path is unit-tested with
// a canned ArcGIS response; only the transport is injected/performed by the caller.
import Foundation

// MARK: - Flood risk band derived from the FEMA zone (pure; the view maps this to a color).
enum FloodRisk: String, Equatable {
    case high        // Special Flood Hazard Area — 1% annual chance (A/AE/AH/AO/AR/A99, V/VE)
    case moderate    // 0.2% annual chance (shaded X) / zone B
    case minimal     // area of minimal flood hazard (unshaded X / C)
    case undetermined // zone D — flood hazard undetermined
    case unknown     // no zone label on the feature

    var legendLabel: String {
        switch self {
        case .high: return "High risk (SFHA — flood insurance required)"
        case .moderate: return "Moderate (0.2% annual chance)"
        case .minimal: return "Minimal flood hazard"
        case .undetermined: return "Undetermined (Zone D)"
        case .unknown: return "Flood zone (unlabeled)"
        }
    }
}

// MARK: - One real flood-zone polygon returned by FEMA (rings are [lng,lat] pairs, EPSG:4326).
struct FloodFeature: Equatable {
    var zone: String = ""        // FLD_ZONE, e.g. "AE", "X", "VE"
    var subtype: String = ""     // ZONE_SUBTY, e.g. "0.2 PCT ANNUAL CHANCE FLOOD HAZARD"
    var sfha: Bool = false       // SFHA_TF == "T"
    var rings: [[[Double]]] = [] // geometry.rings — [ring][point][lng,lat]

    var risk: FloodRisk { FloodOverlayEngine.risk(zone: zone, subtype: subtype, sfha: sfha) }
    /// A ring with < 3 points isn't a polygon and is dropped — never rendered as a fake shape.
    var renderableRings: [[[Double]]] { rings.filter { $0.count >= 3 } }
    var isRenderable: Bool { !renderableRings.isEmpty }
    /// Human label for the callout, e.g. "FEMA Zone AE".
    var label: String { zone.isEmpty ? "FEMA flood zone" : "FEMA Zone \(zone)" }
}

// MARK: - The parsed FeatureSet + provenance (never claims data it didn't receive).
struct FloodFeatureSet: Equatable {
    var features: [FloodFeature] = []
    let source = "FEMA National Flood Hazard Layer (NFHL)"
    var isEmpty: Bool { features.allSatisfy { !$0.isRenderable } }
    var sfhaCount: Int { features.filter { $0.risk == .high }.count }
}

enum FloodOverlayEngine {
    static let layerQueryURL = "https://hazards.fema.gov/arcgis/rest/services/public/NFHL/MapServer/28/query"

    /// Build the ArcGIS envelope query for a viewport bbox (WGS84). Requests only the flood-zone
    /// fields + geometry, capped to `maxRecords` so a dense metro view stays responsive.
    static func queryURL(minLng: Double, minLat: Double, maxLng: Double, maxLat: Double,
                         maxRecords: Int = 60) -> URL {
        var c = URLComponents(string: layerQueryURL)!
        let env = "\(minLng),\(minLat),\(maxLng),\(maxLat)"
        c.queryItems = [
            .init(name: "where", value: "1=1"),
            .init(name: "geometry", value: env),
            .init(name: "geometryType", value: "esriGeometryEnvelope"),
            .init(name: "inSR", value: "4326"),
            .init(name: "spatialRel", value: "esriSpatialRelIntersects"),
            .init(name: "outFields", value: "FLD_ZONE,ZONE_SUBTY,SFHA_TF"),
            .init(name: "returnGeometry", value: "true"),
            .init(name: "outSR", value: "4326"),
            .init(name: "resultRecordCount", value: String(maxRecords)),
            .init(name: "f", value: "json"),
        ]
        return c.url!
    }

    /// Property-sized FEMA query used by the verification dossier. A tiny envelope is intentional:
    /// it catches a zone polygon intersecting the geocoded point while still using the same proven
    /// parser as the map overlay. No returned feature is treated as "safe"; it stays unavailable.
    static func pointQueryURL(lat: Double, lng: Double, padding: Double = 0.00005,
                              maxRecords: Int = 10) -> URL {
        let p = max(0.000001, min(abs(padding), 0.01))
        return queryURL(minLng: lng - p, minLat: lat - p,
                        maxLng: lng + p, maxLat: lat + p, maxRecords: maxRecords)
    }

    /// Classify a FEMA zone into a risk band. Pure; the source of truth is FLD_ZONE + SFHA_TF.
    static func risk(zone rawZone: String, subtype rawSub: String, sfha: Bool) -> FloodRisk {
        let z = rawZone.trimmingCharacters(in: .whitespaces).uppercased()
        let sub = rawSub.uppercased()
        if z.isEmpty { return .unknown }
        // A* and V* zones (and anything FEMA flags SFHA) are the 1%-annual Special Flood Hazard Area.
        if sfha || z.hasPrefix("A") || z.hasPrefix("V") { return .high }
        if z == "D" { return .undetermined }
        // 0.2%-annual shaded X (or legacy B) is the moderate band.
        if z == "B" || sub.contains("0.2 PCT") || sub.contains("0.2%") { return .moderate }
        if z == "X" || z == "C" || sub.contains("MINIMAL") { return .minimal }
        return .unknown
    }

    /// Parse an ArcGIS FeatureSet JSON into flood features. Tolerant + HONEST: a non-JSON body, an
    /// error object, or an empty feature list yields an empty set — never a fabricated polygon. Rings
    /// with fewer than 3 points are dropped.
    static func parse(_ data: Data) -> FloodFeatureSet {
        var set = FloodFeatureSet()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return set }
        // ArcGIS surfaces query problems under "error" — we render nothing rather than guess.
        if root["error"] != nil { return set }
        guard let features = root["features"] as? [[String: Any]] else { return set }
        for f in features {
            var feat = FloodFeature()
            if let attrs = f["attributes"] as? [String: Any] {
                feat.zone = (attrs["FLD_ZONE"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                feat.subtype = (attrs["ZONE_SUBTY"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
                feat.sfha = (attrs["SFHA_TF"] as? String)?.uppercased() == "T"
            }
            if let geom = f["geometry"] as? [String: Any], let rings = geom["rings"] as? [[[Double]]] {
                feat.rings = rings
            }
            if feat.isRenderable { set.features.append(feat) }
        }
        return set
    }

    /// Provenance line shown under the map when the overlay is on and returned data.
    static func sourceLine(featureCount: Int, dateLabel: String) -> String {
        "Source: FEMA National Flood Hazard Layer · \(featureCount) zone\(featureCount == 1 ? "" : "s") in view · fetched \(dateLabel)"
    }
    /// Honest empty state — the layer has no coverage for this view (or the public service timed out).
    static let emptyNote = "No FEMA flood zones returned for this view — the NFHL may not cover it, or the public service timed out. Nothing was invented; pan/zoom and toggle again to retry."
    /// The risk bands present in a set (for the legend), most-severe first.
    static func legendBands(_ set: FloodFeatureSet) -> [FloodRisk] {
        let order: [FloodRisk] = [.high, .moderate, .minimal, .undetermined, .unknown]
        let present = Set(set.features.map { $0.risk })
        return order.filter { present.contains($0) }
    }
}
