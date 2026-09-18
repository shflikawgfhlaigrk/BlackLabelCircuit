// Black Label Real Estate — backend base-URL single source of truth.
//
// Every call to the public Lead Database API (the Cloudflare Worker over the harvested
// public-records index in Cloudflare D1) resolves its base URL HERE — never hard-coded at a
// call site.
//
// DEFAULT = the SHIPPED production Worker, which is DEPLOYED AND LIVE. The backend repo
// (~/BlackLabelRealEstateAPI) publishes worker `blacklabel-realestate-api`, which on the live
// Cloudflare account resolves to the deterministic host below — the SAME convention the shipping
// Leads app uses (blacklabel-leads-api.michael-070.workers.dev). A fresh download reaches the
// real index with no rebuild and no per-user setup; if the Worker is ever unreachable, requests
// fail cleanly and the UI shows an honest error state — the client never fabricates a record.
//
// LOCAL DEV: point at a `wrangler dev` worker without touching shipped defaults via the
// BLRE_API_BASE env var (e.g. `BLRE_API_BASE=http://127.0.0.1:8798 open Build/...app`). This
// mirrors the app's existing BLRE_DATA_DIR convention and keeps localhost out of the binary.
//
// RUNTIME OVERRIDE: a buyer or QA can override the base at runtime via the UserDefaults key
// "blre.apiBaseURL" (Settings → Lead Database → "API base URL") — e.g. to point at a staging
// endpoint without a rebuild:
//   defaults write com.blacklabel.realestate blre.apiBaseURL https://staging.example.workers.dev
//
// Resolution order: UserDefaults override → BLRE_API_BASE env → prod default.
//
// Only PUBLIC query params (state/county/owner/address/zip/parcel) ever leave the device through
// this base. A buyer's own CRM leads / deals / PII are LOCAL-FIRST and are never POSTed.
import Foundation

enum APIConfig {
    /// UserDefaults override key. Empty / invalid → falls through to env, then the prod default.
    static let baseURLDefaultsKey = "blre.apiBaseURL"

    /// Local-dev env override key. Lets `wrangler dev` testing skip UserDefaults entirely.
    static let baseURLEnvKey = "BLRE_API_BASE"

    /// The SHIPPED default: the API's branded custom domain, attached to the same live Worker
    /// (`blacklabel-realestate-api`) as the workers.dev host — both resolve to the same deployment,
    /// so this is a stable, professional endpoint. Fallback if unreachable:
    /// https://blacklabel-realestate-api.michael-070.workers.dev
    static let prodDefault = URL(string: "https://api.blbestate.com")!

    /// The active base URL. Override → env → prod default (first usable http(s) URL wins).
    static var baseURL: URL {
        resolveBaseURL(
            override: UserDefaults.standard.string(forKey: baseURLDefaultsKey),
            env: ProcessInfo.processInfo.environment[baseURLEnvKey]
        )
    }

    /// Pure resolver (inputs injected so it's unit-testable without touching global state).
    /// Returns the first usable http(s) URL from override → env, else the prod default. A blank or
    /// malformed value is ignored, never fatal — so a stray UserDefaults/env string can't strand
    /// the app on a dead base.
    static func resolveBaseURL(override: String?, env: String?) -> URL {
        for candidate in [override, env] {
            if let u = usableURL(candidate) { return u }
        }
        return prodDefault
    }

    /// Persist a runtime override (validated). Pass nil/empty to clear it (back to env/prod default).
    /// Returns nil on success, or an honest reason string when the value isn't a usable URL.
    @discardableResult
    static func setBaseURLOverride(_ value: String?) -> String? {
        let raw = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            UserDefaults.standard.removeObject(forKey: baseURLDefaultsKey); return nil
        }
        guard usableURL(raw) != nil else {
            return "Enter a full URL including http(s):// and a host."
        }
        UserDefaults.standard.set(raw, forKey: baseURLDefaultsKey); return nil
    }

    /// A trimmed http(s) URL with a host, or nil. Shared by the resolver and the setter so the
    /// "what counts as a usable base" rule lives in exactly one place.
    static func usableURL(_ raw: String?) -> URL? {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, let u = URL(string: s),
              let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https",
              u.host != nil else { return nil }
        return u
    }
}
