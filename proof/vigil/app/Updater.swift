// Vigil — in-app update check (DOD-9.5, mechanism half).
//
// Fleet pattern: the storefront publishes a per-product version manifest at
// https://blacklabelbots.com/api/version/<product>; the app compares the offered
// build against its own CFBundleVersion and tells the buyer the truth:
//
//   · a NEWER offered build  -> "update available" + route to the gated download
//     page (downloads require the buyer's account/access code, so the app never
//     fetches the artifact itself — it opens the same /dl surface the buyer
//     bought through);
//   · an OLDER/EQUAL offer   -> "up to date". A stale manifest can NEVER make the
//     app offer a downgrade (the round-4 manifest offered build 12 to a build-15
//     install — a rollback-shaped answer this decision rule refuses);
//   · no manifest / network down -> said plainly. An unreachable manifest is
//     NEVER reported as "up to date" (§5.1 — absence of evidence stays absence).
//
// Publishing the manifest itself is owner-gated deploy work (BLOCKERS DOD-9.5,
// bucket E); this file is the in-app mechanism that consumes it.
//
// Pure logic (parse + decide) is Foundation-only and unit-locked in
// tests/HomeCoreTests.swift; only the fetch shell touches the network.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The storefront's version-manifest shape (see /api/version/homefront live).
/// Unknown extra keys are ignored; the two load-bearing fields are required.
struct UpdateManifest: Codable, Equatable {
    let product: String
    let latestBuild: Int
    let latestVersion: String?
    let minSupportedBuild: Int?
    let sha256: String?
    let notarized: Bool?

    enum CodingKeys: String, CodingKey {
        case product
        case latestBuild = "latest_build"
        case latestVersion = "latest_version"
        case minSupportedBuild = "min_supported_build"
        case sha256, notarized
    }
}

/// What the buyer is told after a successful manifest read. Pure.
enum UpdateDecision: Equatable {
    /// Offered build is newer than the running one.
    case updateAvailable(current: Int, offered: Int, version: String?)
    /// Offered build is the running one — genuinely current.
    case upToDate(current: Int)
    /// Offered build is OLDER than the running one (stale manifest). Reported
    /// distinctly so a stale manifest reads as what it is, never as an update
    /// and never as a clean "up to date".
    case manifestBehind(current: Int, offered: Int)
}

/// Outcome of one check, including the honest failure states.
enum UpdateCheckResult: Equatable {
    case decision(UpdateDecision)
    case noManifest            // endpoint answered: no manifest published for this product
    case unreachable(String)   // network/transport failure — NOT "up to date"
}

enum UpdaterModel {
    /// The gated download surface the buyer bought through (suite installer).
    static let downloadPageURL = URL(string: "https://blacklabelbots.com/dl")!
    /// Manifest endpoints, most specific first. The storefront key for this
    /// product is historically "homefront"; "vigil" is the display-name key the
    /// owner deploy may publish under — the app accepts whichever exists.
    static let manifestURLs: [URL] = [
        URL(string: "https://blacklabelbots.com/api/version/vigil")!,
        URL(string: "https://blacklabelbots.com/api/version/homefront")!,
    ]

    /// Strict parse: malformed JSON or a missing/non-numeric latest_build is nil,
    /// never a guessed manifest.
    static func parse(_ data: Data) -> UpdateManifest? {
        try? JSONDecoder().decode(UpdateManifest.self, from: data)
    }

    /// The one decision rule. Downgrades are refused by construction.
    static func decide(currentBuild: Int, manifest: UpdateManifest) -> UpdateDecision {
        if manifest.latestBuild > currentBuild {
            return .updateAvailable(current: currentBuild,
                                    offered: manifest.latestBuild,
                                    version: manifest.latestVersion)
        }
        if manifest.latestBuild < currentBuild {
            return .manifestBehind(current: currentBuild, offered: manifest.latestBuild)
        }
        return .upToDate(current: currentBuild)
    }

    /// One-line buyer-facing status per result. Pure, unit-locked.
    static func statusLine(_ result: UpdateCheckResult) -> String {
        switch result {
        case .decision(.updateAvailable(let current, let offered, let version)):
            let v = version.map { "Vigil \($0) " } ?? ""
            return "Update available: \(v)build \(offered) (you have build \(current)). Downloads go through your account on the download page."
        case .decision(.upToDate(let current)):
            return "You're up to date (build \(current))."
        case .decision(.manifestBehind(let current, let offered)):
            return "You're ahead of the published release (you have build \(current); the server lists build \(offered)). Nothing to install."
        case .noManifest:
            return "The update service has no release listed for Vigil yet — this build predates the first published manifest. Check again after the next release."
        case .unreachable(let why):
            return "Couldn't reach the update service (\(why)). This says nothing about whether an update exists — try again when you're online."
        }
    }

    /// The running app's build number, from the same Info.plist the artifact ships.
    static func currentBuild(bundle: Bundle = .main) -> Int? {
        (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap(Int.init)
    }

    /// Live check. Tries each manifest endpoint in order; the first parseable
    /// manifest wins. An HTTP 200 that does not parse (e.g. the literal
    /// "no manifest for vigil" body) counts as "no manifest" for that endpoint.
    static func check(currentBuild: Int, session: URLSession = .shared) async -> UpdateCheckResult {
        var sawNoManifest = false
        var lastTransportError: String?
        for url in manifestURLs {
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, resp) = try await session.data(for: req)
                guard let http = resp as? HTTPURLResponse else { continue }
                if http.statusCode == 200, let manifest = parse(data) {
                    return .decision(decide(currentBuild: currentBuild, manifest: manifest))
                }
                sawNoManifest = true   // answered, but no usable manifest here
            } catch {
                lastTransportError = error.localizedDescription
            }
        }
        if sawNoManifest { return .noManifest }
        return .unreachable(lastTransportError ?? "no response")
    }
}
