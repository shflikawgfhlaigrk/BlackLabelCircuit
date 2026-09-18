// Black Label Real Estate — ROUTE optimizer (free TSP/VRP).
// Faithful Swift port of the proven Utah engine (utah/product/route.py): haversine distance,
// nearest-neighbour seed + 2-opt polish, with a Canvasser config (one driver, value-first by
// ARV/priority — 2-opt skipped so the value order is preserved) and a Fleet config (multiple
// vehicles from a depot, stops balanced across them). Free by construction: geocoding via OSM
// Nominatim (no key, 1 req/sec, cached forever), solver on plain math (no ortools, no paid API).
// Honest by construction: a geocode miss flags the stop unroutable; a coordinate is never invented.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Geometry
enum RouteMath {
    static let earthRadiusMi = 3958.7613
    static func haversineMiles(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
        let lat1 = a.0 * .pi/180, lon1 = a.1 * .pi/180
        let lat2 = b.0 * .pi/180, lon2 = b.1 * .pi/180
        let dlat = lat2 - lat1, dlon = lon2 - lon1
        let h = pow(sin(dlat/2), 2) + cos(lat1)*cos(lat2)*pow(sin(dlon/2), 2)
        return 2 * earthRadiusMi * asin(min(1.0, sqrt(h)))
    }
    static func matrix(_ pts: [(Double, Double)]) -> [[Double]] {
        let n = pts.count
        var m = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n { for j in (i+1)..<n {
            let d = haversineMiles(pts[i], pts[j]); m[i][j] = d; m[j][i] = d
        }}
        return m
    }
    static func pathMiles(_ m: [[Double]], _ order: [Int], roundTrip: Bool) -> Double {
        guard order.count >= 2 else { return 0 }
        var total = 0.0
        for k in 0..<(order.count - 1) { total += m[order[k]][order[k+1]] }
        if roundTrip { total += m[order[order.count-1]][order[0]] }
        return total
    }
}

// MARK: - Stop / result models
struct RouteStop: Identifiable, Hashable {
    let id = UUID()
    var label: String
    var address: String
    var lat: Double?
    var lng: Double?
    var priority: Double = 0   // higher = more valuable (Canvasser orders by this; ARV maps here)
    var routable: Bool { lat != nil && lng != nil }
}

struct VehicleRoute: Identifiable, Hashable {
    let id = UUID()
    var stops: [Int]           // indices into the routable stop list
    var miles: Double
    var minutes: Double
    var mapsURL: String
}

struct RouteResult {
    var routes: [VehicleRoute]
    var resolved: [RouteStop]      // the routable stops, in the order VehicleRoute.stops indexes into
    var unroutable: [RouteStop]
    var totalMiles: Double
    var totalMinutes: Double
    var stopCount: Int { routes.reduce(0) { $0 + $1.stops.count } }
    /// Stop labels for one vehicle's route, in optimized visit order.
    func labels(_ route: VehicleRoute) -> [String] {
        route.stops.compactMap { $0 >= 0 && $0 < resolved.count ? resolved[$0].label : nil }
    }
}

// MARK: - Configs (the two ship-able personalities)
struct RouteConfig {
    var name: String
    var vehicles: Int = 1
    var usePriority: Bool = false   // value-first ordering (Canvasser)
    var roundTrip: Bool = true      // return to depot/start
    var avgSpeedMph: Double = 30.0

    static let canvasser = RouteConfig(name: "Canvasser", vehicles: 1, usePriority: true, roundTrip: false)
    static func fleet(_ vehicles: Int) -> RouteConfig {
        RouteConfig(name: "Fleet", vehicles: max(2, vehicles), usePriority: false, roundTrip: true)
    }
}

// MARK: - Solver
enum RouteSolver {
    static let priorityWeight = 1.0

    /// Nearest-neighbour seed (priority biases the seed so high-value stops land early) +
    /// 2-opt polish. When `priorities` is set, 2-opt is skipped so value order is preserved.
    static func solveOrder(_ m: [[Double]], start: Int = 0, priorities: [Double]? = nil, roundTrip: Bool) -> [Int] {
        let n = m.count
        if n <= 1 { return Array(0..<n) }
        var unvisited = Set(0..<n); unvisited.remove(start)
        var order = [start]; var cur = start
        while !unvisited.isEmpty {
            let nxt: Int
            if let p = priorities {
                nxt = unvisited.min(by: {
                    let a = m[cur][$0] / (1.0 + priorityWeight * max(0, p[$0]))
                    let b = m[cur][$1] / (1.0 + priorityWeight * max(0, p[$1]))
                    return a != b ? a < b : $0 < $1
                })!
            } else {
                nxt = unvisited.min(by: { m[cur][$0] != m[cur][$1] ? m[cur][$0] < m[cur][$1] : $0 < $1 })!
            }
            order.append(nxt); unvisited.remove(nxt); cur = nxt
        }
        if priorities == nil { order = twoOpt(m, order, roundTrip: roundTrip) }
        return order
    }

    static func twoOpt(_ m: [[Double]], _ order: [Int], roundTrip: Bool) -> [Int] {
        var best = order
        var bestLen = RouteMath.pathMiles(m, best, roundTrip: roundTrip)
        var improved = true
        while improved {
            improved = false
            if best.count < 3 { break }
            for i in 1..<(best.count - 1) {
                for k in (i+1)..<best.count {
                    var cand = best
                    cand.replaceSubrange(i...k, with: best[i...k].reversed())
                    let len = RouteMath.pathMiles(m, cand, roundTrip: roundTrip)
                    if len + 1e-9 < bestLen { best = cand; bestLen = len; improved = true }
                }
            }
        }
        return best
    }
}

// MARK: - Geocoder (free OSM Nominatim, file-cached forever, injectable)
final class OSMGeocoder {
    static let shared = OSMGeocoder()
    private let url = URL(string: "https://nominatim.openstreetmap.org/search")!
    private let minInterval: TimeInterval = 1.05
    private var last: TimeInterval = 0
    private var cache: [String: [Double]?] = [:]
    private let cacheURL: URL
    private let q = DispatchQueue(label: "blre.geocode")

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelRealEstate", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        cacheURL = base.appendingPathComponent("geocode-cache.json")
        if let d = try? Data(contentsOf: cacheURL),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: [Double]] {
            for (k, v) in j { cache[k] = v }
        }
    }
    private func persist() {
        let flat = cache.compactMapValues { $0 }
        if let d = try? JSONSerialization.data(withJSONObject: flat) { try? d.write(to: cacheURL) }
    }
    /// Geocode an address -> (lat, lng) or nil. Never fabricates. Cached forever.
    func geocode(_ address: String) async -> (Double, Double)? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return nil }
        if let hit = cache[a] { return hit.map { ($0[0], $0[1]) } }
        // courtesy rate limit
        let wait = minInterval - (Date().timeIntervalSince1970 - last)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        last = Date().timeIntervalSince1970
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "q", value: a), .init(name: "format", value: "json"), .init(name: "limit", value: "1")]
        var req = URLRequest(url: comps.url!)
        req.setValue("BlackLabelRealEstate/1.0 (macOS route)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = arr.first,
                  let latS = first["lat"] as? String, let lonS = first["lon"] as? String,
                  let lat = Double(latS), let lon = Double(lonS) else {
                q.sync { cache[a] = .some(nil); persist() }   // cache the miss
                return nil
            }
            q.sync { cache[a] = [lat, lon]; persist() }
            return (lat, lon)
        } catch {
            return nil   // transient: do not cache, do not fabricate
        }
    }
}

// MARK: - Planner (geocode → solve → split across vehicles → Google Maps links)
enum RoutePlanner {
    /// Build a route. `depot` is the start (geocoded). Stops with no coordinate are returned unroutable.
    /// Geocoding is injectable for offline determinism (tests pass a closure).
    static func plan(stops input: [RouteStop], depot: String, config: RouteConfig,
                     geocode: (String) async -> (Double, Double)?) async -> RouteResult {
        // 1) geocode depot + each stop (skip those that already have coords)
        let depotCoord = await geocode(depot) ?? (input.first(where: { $0.routable }).map { ($0.lat!, $0.lng!) })
        var resolved: [RouteStop] = []
        var unroutable: [RouteStop] = []
        for var s in input {
            if !s.routable, let c = await geocode(s.address.isEmpty ? s.label : s.address) {
                s.lat = c.0; s.lng = c.1
            }
            if s.routable { resolved.append(s) } else { unroutable.append(s) }
        }
        guard let depotC = depotCoord, !resolved.isEmpty else {
            return RouteResult(routes: [], resolved: [], unroutable: unroutable + resolved, totalMiles: 0, totalMinutes: 0)
        }
        // 2) build a matrix with the depot at index 0
        let pts: [(Double, Double)] = [depotC] + resolved.map { ($0.lat!, $0.lng!) }
        let m = RouteMath.matrix(pts)
        var routes: [VehicleRoute] = []

        if config.vehicles <= 1 {
            let prios = config.usePriority ? [0.0] + resolved.map { $0.priority } : nil
            var order = RouteSolver.solveOrder(m, start: 0, priorities: prios, roundTrip: config.roundTrip)
            order.removeFirst()  // drop the depot from the visit list
            routes = [vehicleRoute(order.map { $0 - 1 }, resolved: resolved, depot: depotC, config: config)]
        } else {
            // Fleet: balance stops across vehicles by angular sweep around the depot, then
            // optimize each vehicle's sub-route independently (round trip from depot).
            let clusters = sweepClusters(resolved, depot: depotC, vehicles: config.vehicles)
            for cluster in clusters where !cluster.isEmpty {
                let subStops = cluster.map { resolved[$0] }
                let subPts: [(Double, Double)] = [depotC] + subStops.map { ($0.lat!, $0.lng!) }
                let sm = RouteMath.matrix(subPts)
                var order = RouteSolver.solveOrder(sm, start: 0, priorities: nil, roundTrip: true)
                order.removeFirst()
                let globalOrder = order.map { cluster[$0 - 1] }
                routes.append(vehicleRoute(globalOrder, resolved: resolved, depot: depotC, config: config))
            }
        }
        let totalMiles = routes.reduce(0) { $0 + $1.miles }
        return RouteResult(routes: routes, resolved: resolved, unroutable: unroutable,
                           totalMiles: totalMiles, totalMinutes: totalMiles / config.avgSpeedMph * 60)
    }

    /// Greedy angular sweep: order stops by bearing from the depot, then split that ordering
    /// into balanced contiguous wedges — one per vehicle. The remainder is spread one stop per
    /// vehicle (divmod), so loads differ by at most one stop and no requested vehicle is left
    /// empty. Faithful to the proven utah/product/route.py `_cluster`. Deterministic, no libs.
    static func sweepClusters(_ stops: [RouteStop], depot: (Double, Double), vehicles: Int) -> [[Int]] {
        let n = stops.count
        if vehicles <= 1 || n <= 1 { return [Array(stops.indices)] }
        if n <= vehicles { return stops.indices.map { [$0] } }   // one stop each — never an empty wedge
        let byAngle = stops.indices.sorted {
            atan2(stops[$0].lat! - depot.0, stops[$0].lng! - depot.1) <
            atan2(stops[$1].lat! - depot.0, stops[$1].lng! - depot.1)
        }
        let base = n / vehicles, extra = n % vehicles   // remainder spread one-per-vehicle
        var clusters: [[Int]] = []; var pos = 0
        for g in 0..<vehicles {
            let size = base + (g < extra ? 1 : 0)
            clusters.append(Array(byAngle[pos..<pos + size])); pos += size
        }
        return clusters.filter { !$0.isEmpty }
    }

    private static func vehicleRoute(_ globalOrder: [Int], resolved: [RouteStop],
                                     depot: (Double, Double), config: RouteConfig) -> VehicleRoute {
        let coords = [depot] + globalOrder.map { (resolved[$0].lat!, resolved[$0].lng!) }
        let miles = RouteMath.pathMiles(RouteMath.matrix(coords), Array(0..<coords.count), roundTrip: config.roundTrip)
        return VehicleRoute(stops: globalOrder, miles: miles, minutes: miles / config.avgSpeedMph * 60,
                            mapsURL: mapsURL(depot: depot, stops: globalOrder.map { (resolved[$0].lat!, resolved[$0].lng!) }, roundTrip: config.roundTrip))
    }

    static func mapsURL(depot: (Double, Double), stops: [(Double, Double)], roundTrip: Bool) -> String {
        var pts = [depot] + stops
        if roundTrip { pts.append(depot) }
        let path = pts.map { String(format: "%.5f,%.5f", $0.0, $0.1) }.joined(separator: "/")
        return "https://www.google.com/maps/dir/" + path
    }
}
