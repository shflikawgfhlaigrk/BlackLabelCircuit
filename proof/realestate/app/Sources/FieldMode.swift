// Black Label Real Estate — RE-20 FIELD MODE: stand on a parcel, know it (offline, honest).
//
// The investor is driving a neighborhood and wants to know, standing at the curb, WHOSE parcel this
// is and what the public record says — without a cell signal. Field Mode does two honest things:
//
//   1. DOWNLOAD-FOR-OFFLINE: before heading out (on Wi-Fi), the buyer downloads the current map
//      viewport's parcel POLYGONS from the same free, keyless county ArcGIS parcel layer the rest of
//      the app uses (ParcelRegistry, returnGeometry=true — live-verified 2026-07-12 against Wake Co.).
//      The polygons + owner/situs/PIN are cached on-device. Coverage is exactly what was downloaded —
//      the cached layer records its own bbox so the app can say "you drove outside your download."
//
//   2. STAND-ON-PARCEL: in the field, Core Location fixes the Mac's position and Field Mode runs a
//      PURE point-in-polygon test against the cached layer — ZERO network — to resolve the parcel the
//      buyer is standing on. A miss is reported honestly ("no cached parcel here"), never guessed.
//
// HONESTY, the whole reason this is sellable:
//   • macOS has NO GPS radio — it locates by Wi-Fi/IP trilateration. Field Mode states the real
//     horizontal-accuracy envelope in-UI and NEVER implies GPS precision. A coarse fix that could sit
//     in the neighbor's yard is labeled coarse, not hidden.
//   • Nothing is fabricated: an uncovered county, an empty download, or a point with no cached parcel
//     all gate to an honest empty state; parcels are only ever what the county's own layer returned.
//   • The drive log is the buyer's own field record — parcels they actually stood on, timestamped,
//     stored locally, never uploaded.
//
// The query builder, the ArcGIS parser, the point-in-polygon test, the accuracy classifier, and the
// drive-log logic are all PURE (no I/O, no Core Location, no UserNotifications), so the whole decision
// path is unit-tested against a REAL Wake County parcel polygon. FieldModeScreen.swift owns the
// CLLocationManager fix and the SwiftUI surface. Coordinates are plain [lng,lat] Doubles (EPSG:4326),
// identical to FloodFeature.rings — so this file needs only Foundation, no CoreLocation link.
import Foundation

// MARK: - One parcel polygon cached for offline field use (rings are [ring][point][lng,lat], EPSG:4326).
struct FieldParcel: Codable, Equatable, Identifiable {
    var parcelID: String = ""
    var owner: String = ""
    var situs: String = ""
    var rings: [[[Double]]] = []   // geometry.rings — same shape/order as FloodFeature.rings

    /// A ring needs ≥ 3 points to be a polygon; anything less is dropped, never treated as a shape.
    var renderableRings: [[[Double]]] { rings.filter { $0.count >= 3 } }
    var isRenderable: Bool { !renderableRings.isEmpty }
    /// Stable identity: the county PIN when present, else the centroid (so an unkeyed parcel still de-dups).
    var id: String {
        if !parcelID.isEmpty { return parcelID }
        let c = centroid
        return "\(c.0),\(c.1)"
    }
    /// Average of the outer ring's vertices — the point we log when the buyer stands on this parcel.
    var centroid: (Double, Double) {
        guard let outer = renderableRings.first, !outer.isEmpty else { return (0, 0) }
        var sx = 0.0, sy = 0.0
        for p in outer where p.count >= 2 { sx += p[0]; sy += p[1] }
        let n = Double(outer.count)
        return (sx / n, sy / n)
    }
    /// Human label for the field callout.
    var label: String {
        if !situs.isEmpty { return situs }
        if !owner.isEmpty { return owner }
        return parcelID.isEmpty ? "Parcel" : "Parcel \(parcelID)"
    }
}

// MARK: - A county's offline parcel layer — the geometry the buyer downloaded for field use.
// Local custody: never uploaded. Records its own extent so the app can be honest about coverage.
struct OfflineParcelLayer: Codable, Equatable {
    var county: String = ""
    var source: String = ""              // the ArcGIS endpoint it came from (provenance, cited in-UI)
    var fetchedAt: Date = Date()
    var bbox: [Double] = []              // [minLng,minLat,maxLng,maxLat] the download actually covered
    var parcels: [FieldParcel] = []

    var renderableCount: Int { parcels.filter { $0.isRenderable }.count }
    var isEmpty: Bool { renderableCount == 0 }
    /// True when [lng,lat] falls inside the downloaded extent (so a miss inside can be trusted, and a
    /// miss OUTSIDE is honestly attributed to "you drove off your download", not "no such parcel").
    func covers(lng: Double, lat: Double) -> Bool {
        guard bbox.count == 4 else { return false }
        return lng >= bbox[0] && lng <= bbox[2] && lat >= bbox[1] && lat <= bbox[3]
    }
    /// Provenance line shown under the field callout.
    var sourceLine: String {
        let n = renderableCount
        return "Source: \(source.isEmpty ? "county parcel layer" : source) · \(n) parcel\(n == 1 ? "" : "s") cached offline"
    }
}

// MARK: - The horizontal-accuracy band of a Wi-Fi/IP location fix (macOS has no GPS radio).
enum FieldFixAccuracy: String, Equatable {
    case good        // ≤ 25 m — likely the right parcel on a normal lot
    case coarse      // ≤ 100 m — could be a neighboring parcel; treat as a hint
    case poor        // > 100 m — block-level; do not trust to a single parcel
    case unavailable // no fix / negative accuracy

    var label: String {
        switch self {
        case .good: return "Good (Wi-Fi, ~25 m)"
        case .coarse: return "Coarse (Wi-Fi, ~100 m — could be a neighboring parcel)"
        case .poor: return "Poor (block-level — don't trust to one parcel)"
        case .unavailable: return "No location fix"
        }
    }
}

enum FieldModeEngine {
    // MARK: Download-for-offline query (reuses the app's free, keyless county parcel layers)

    /// Build the ArcGIS envelope query that downloads parcel POLYGONS for a viewport, for offline use.
    /// returnGeometry=true (we need the rings for the point-in-parcel test) + owner/situs/PIN so a field
    /// hit shows the public record. Capped so a dense download stays bounded and honest about its size.
    static func layerQueryURL(source: CountyParcelSource,
                              minLng: Double, minLat: Double, maxLng: Double, maxLat: Double,
                              maxRecords: Int = 500) -> URL {
        var c = URLComponents(string: source.url)!
        var out = [source.parcelField, source.ownerField]
        if let af = source.addrField { out.append(af) }
        if let v = source.valueField { out.append(v) }
        c.queryItems = [
            .init(name: "where", value: "1=1"),
            .init(name: "geometry", value: "\(minLng),\(minLat),\(maxLng),\(maxLat)"),
            .init(name: "geometryType", value: "esriGeometryEnvelope"),
            .init(name: "inSR", value: "4326"),
            .init(name: "spatialRel", value: "esriSpatialRelIntersects"),
            .init(name: "outFields", value: out.joined(separator: ",")),
            .init(name: "returnGeometry", value: "true"),
            .init(name: "outSR", value: "4326"),
            .init(name: "resultRecordCount", value: String(maxRecords)),
            .init(name: "f", value: "json"),
        ]
        return c.url!
    }

    /// Parse an ArcGIS FeatureSet into cacheable parcels. Tolerant + HONEST: a non-JSON body, an ArcGIS
    /// error object, or an empty feature list yields NO parcels — never a fabricated polygon. Rings with
    /// fewer than 3 points are dropped. Field names come from the county's own `CountyParcelSource`.
    static func parseParcels(_ data: Data, source: CountyParcelSource) -> [FieldParcel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        if root["error"] != nil { return [] }                       // ArcGIS surfaced a query problem
        guard let features = root["features"] as? [[String: Any]] else { return [] }
        var out: [FieldParcel] = []
        for f in features {
            var p = FieldParcel()
            if let attrs = f["attributes"] as? [String: Any] {
                p.parcelID = string(attrs[source.parcelField])
                p.owner = string(attrs[source.ownerField])
                p.situs = source.addrField.map { string(attrs[$0]) } ?? ""
            }
            if let geom = f["geometry"] as? [String: Any], let rings = geom["rings"] as? [[[Double]]] {
                p.rings = rings
            }
            if p.isRenderable { out.append(p) }                     // only real polygons are cached
        }
        return out
    }

    /// Assemble the offline layer from a parsed download, stamping its real extent + provenance.
    static func makeLayer(county: String, source: String, bbox: [Double], parcels: [FieldParcel],
                          fetchedAt: Date = Date()) -> OfflineParcelLayer {
        OfflineParcelLayer(county: county, source: source, fetchedAt: fetchedAt, bbox: bbox, parcels: parcels)
    }

    private static func string(_ any: Any?) -> String {
        if let s = any as? String { return s.trimmingCharacters(in: .whitespaces) }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    // MARK: Point-in-parcel (pure ray casting, offline, zero network)

    /// Standard even-odd ray-casting test for a single ring. Pure. Points are [lng,lat]; the ring is
    /// treated as closed (ArcGIS repeats the first vertex last, which this handles either way).
    static func pointInRing(lng x: Double, lat y: Double, ring: [[Double]]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            guard ring[i].count >= 2, ring[j].count >= 2 else { j = i; continue }
            let xi = ring[i][0], yi = ring[i][1]
            let xj = ring[j][0], yj = ring[j][1]
            if ((yi > y) != (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// A parcel contains the point when an ODD number of its rings contain it — the even-odd rule, so a
    /// point that lands in a donut hole (a ring inside a ring) is correctly OUTSIDE, never a false hit.
    static func pointInParcel(lng: Double, lat: Double, parcel: FieldParcel) -> Bool {
        var hits = 0
        for ring in parcel.renderableRings where pointInRing(lng: lng, lat: lat, ring: ring) { hits += 1 }
        return hits % 2 == 1
    }

    /// The offline hit test: the parcel the buyer is standing on, resolved from the cached layer with
    /// ZERO network. Returns nil on a genuine miss (honest — a point with no cached parcel is not
    /// invented). First containing parcel wins (parcels don't overlap in an assessor layer).
    static func parcelAt(lng: Double, lat: Double, in layer: OfflineParcelLayer) -> FieldParcel? {
        layer.parcels.first { pointInParcel(lng: lng, lat: lat, parcel: $0) }
    }

    // MARK: Wi-Fi/IP accuracy honesty (macOS is NOT GPS)

    /// Classify a Core Location horizontalAccuracy (meters) into an honest band. A negative accuracy
    /// (CLLocation's "invalid" sentinel) or a non-finite value is `.unavailable`, never silently good.
    static func accuracy(horizontalMeters m: Double) -> FieldFixAccuracy {
        guard m.isFinite, m >= 0 else { return .unavailable }
        if m <= 25 { return .good }
        if m <= 100 { return .coarse }
        return .poor
    }

    /// The honest one-liner shown beside a fix. Names the real fix source per platform (Macs have
    /// no GPS chip; iPhones/iPads do) and quantifies the radius.
    static func accuracyNote(horizontalMeters m: Double) -> String {
        let band = accuracy(horizontalMeters: m)
        #if os(iOS)
        if band == .unavailable { return "No location fix yet — waiting for GPS." }
        let r = Int(m.rounded())
        return "GPS location · ±\(r) m · \(band.label). A fix can still sit on a neighboring parcel — confirm by address."
        #else
        if band == .unavailable { return "No location fix yet — this Mac locates by Wi-Fi, not GPS." }
        let r = Int(m.rounded())
        return "Wi-Fi location · ±\(r) m · \(band.label). This Mac has no GPS; a fix can sit on a neighboring parcel."
        #endif
    }

    // MARK: Honest empty / preamble copy
    #if os(iOS)
    static let accuracyPreamble = "Field Mode uses GPS — expect a radius of a few meters outdoors, and confirm the parcel by address, not the dot alone."
    #else
    static let accuracyPreamble = "Field Mode locates this Mac by Wi-Fi/IP, not GPS — expect a radius of tens of meters, and confirm the parcel by address, not the dot alone."
    #endif
    static let noLayerNote = "No parcels downloaded for offline use yet. On Wi-Fi, pan the Property Map to your target area and tap “Download for offline” — Field Mode caches those parcels so it works with no signal. Nothing is invented; coverage is exactly what you download."
    static let uncoveredCountyNote = "This county has no open parcel layer wired yet, so there's nothing to download. Add its ArcGIS layer in Settings → Markets & Counties, or work a covered county — Field Mode never invents parcels."
    static let noParcelHereNote = "No cached parcel at your location. You may be standing outside your downloaded area, on a right-of-way, or on an unparceled tract — Field Mode won't guess a parcel that isn't in the county layer."
    static let offDownloadNote = "You're outside the area you downloaded. Nothing here is missing from the county — you just haven't cached this spot. Return to Wi-Fi and download this viewport to work it offline."
}

// MARK: - The buyer's field drive log (parcels they actually stood on, timestamped, local-only).
struct DrivenParcel: Codable, Equatable, Identifiable {
    var id = UUID()
    var parcelID: String = ""
    var owner: String = ""
    var situs: String = ""
    var lng: Double = 0
    var lat: Double = 0
    var drivenAt = Date()
    var accuracyMeters: Double? = nil      // the Wi-Fi fix radius at logging time (kept honest, not hidden)
    var note: String = ""

    /// The identity used to collapse a stand-still (same parcel logged twice without moving on).
    var dedupeKey: String { parcelID.isEmpty ? "\(lng),\(lat)" : parcelID }
    var accuracyLabel: String {
        guard let a = accuracyMeters else { return "" }
        return "±\(Int(a.rounded())) m · \(FieldModeEngine.accuracy(horizontalMeters: a).label)"
    }
}

enum FieldDriveLog {
    /// Append a stood-on parcel to the log. Consecutive-dedupe: if the SAME parcel is the most-recent
    /// entry (you're still standing on it), we refresh that entry's timestamp instead of stacking a
    /// duplicate — a real re-visit later (after driving elsewhere) is a new entry, as it should be.
    static func append(_ entry: DrivenParcel, to log: [DrivenParcel]) -> [DrivenParcel] {
        var out = log
        if let last = out.last, last.dedupeKey == entry.dedupeKey {
            var refreshed = entry
            refreshed.id = last.id
            out[out.count - 1] = refreshed
        } else {
            out.append(entry)
        }
        return out
    }
    /// Distinct parcels stood on (not raw log length) — the honest "N properties worked today" number.
    static func distinctParcelCount(_ log: [DrivenParcel]) -> Int {
        Set(log.map { $0.dedupeKey }).count
    }
    static let emptyNote = "No parcels logged yet. In the field, tap “I'm standing here” on a cached parcel and it's added to your drive log — timestamped, on-device, never uploaded."
}

// MARK: - On-device persistence (JSON in UserDefaults; local custody, injectable for tests).
struct OfflineParcelLayerStore {
    private let key = "bl.realestate.offline_parcel_layers.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [OfflineParcelLayer] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([OfflineParcelLayer].self, from: data) else { return [] }
        return list
    }
    func save(_ list: [OfflineParcelLayer]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
    }
    /// Insert or replace a county's cached layer (one layer per county — a re-download refreshes it).
    @discardableResult
    func upsert(_ layer: OfflineParcelLayer) -> [OfflineParcelLayer] {
        var list = load()
        let county = layer.county.lowercased()
        if let i = list.firstIndex(where: { $0.county.lowercased() == county }) { list[i] = layer }
        else { list.append(layer) }
        save(list)
        return list
    }
    func layer(forCounty county: String) -> OfflineParcelLayer? {
        let c = county.trimmingCharacters(in: .whitespaces).lowercased()
        return load().first { $0.county.lowercased() == c }
    }
    /// Resolve the parcel at a point across ALL cached counties (offline, zero network).
    func parcelAt(lng: Double, lat: Double) -> (OfflineParcelLayer, FieldParcel)? {
        for layer in load() {
            if let p = FieldModeEngine.parcelAt(lng: lng, lat: lat, in: layer) { return (layer, p) }
        }
        return nil
    }
}

struct FieldDriveLogStore {
    private let key = "bl.realestate.field_drive_log.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> [DrivenParcel] {
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([DrivenParcel].self, from: data) else { return [] }
        return list
    }
    func save(_ list: [DrivenParcel]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        defaults.set(data, forKey: key)
    }
    @discardableResult
    func log(_ entry: DrivenParcel) -> [DrivenParcel] {
        let list = FieldDriveLog.append(entry, to: load())
        save(list)
        return list
    }
    @discardableResult
    func clear() -> [DrivenParcel] { save([]); return [] }
}
