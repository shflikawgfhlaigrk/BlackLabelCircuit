// Black Label Marketing — branded short links on the buyer's OWN Cloudflare account (own-it, free tier).
//
// Buffer sells link shortening as a service; this app closes that gap WITHOUT any Black Label
// server and without a paid shortener: one click provisions a tiny redirect Worker + KV store on
// the buyer's own Cloudflare account (free tier), then all link CRUD + click counts go through
// that buyer-owned Worker. The canonical Worker source lives in cloudflare/shortlink-worker.js;
// `CloudflareShortlinks.workerScript` below is the byte-identical copy the app uploads over the
// Cloudflare API (PUT /accounts/{id}/workers/scripts/… with metadata bindings), because the app
// bundle does not ship the cloudflare/ dev directory.
//
// SHIP-NO-DATA / OWN-IT: the API token, Account ID, Worker URL, and admin secret ALL ship EMPTY.
// The buyer pastes their own scoped token (the "Edit Cloudflare Workers" template) in
// Distribute → Short Links. Both secrets live ONLY in the data-protection Keychain, never in
// JSON, never in the shipped bundle. Real provision = real links; the screen stays an honest
// "Connect Cloudflare…" empty state until then, and click counts are surfaced as APPROXIMATE
// (KV has no atomic increment) — never presented as exact analytics.
//
// The networking is a thin async shell over PURE, testable functions: slug/URL hygiene, the
// multipart script-upload builder, the Cloudflare envelope parsers, and the Worker response
// parsers — same shape as CloudflareAnalytics/CloudflareEmail.
import Foundation
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - a short link (Codable so the screen can cache the last REAL list, never fabricate one)

struct ShortLink: Codable, Identifiable, Equatable, Hashable {
    var slug: String
    var url: String       // the destination (typically a UTM-tagged URL from the Campaign Links builder)
    var created: String   // ISO-8601, as reported by the buyer's Worker
    var clicks: Int       // KV counter — approximate; surfaced as ≈ in the UI
    var id: String { slug }
}

struct ShortlinksCache: Codable, Equatable {
    var links: [ShortLink]
    var fetchedAt: Date
}

// MARK: - config (all fields ship EMPTY; buyer connects in Distribute → Short Links)

enum CloudflareShortlinksConfig {
    // UserDefaults keys (device-local, non-secret).
    static let accountIDKey    = "cf.shortlinks.accountId"     // 32-hex Account ID
    static let workerURLKey    = "cf.shortlinks.workerUrl"     // https://blm-shortlinks.<buyer>.workers.dev
    static let namespaceIDKey  = "cf.shortlinks.kvNamespaceId" // the LINKS KV namespace id
    static let customDomainKey = "cf.shortlinks.customDomain"  // optional buyer-attached domain, e.g. go.acme.com
    static let lastListKey     = "cf.shortlinks.lastList"      // cached JSON of the last REAL link list

    // What the provisioner names the buyer-side resources (visible in THEIR dashboard).
    static let scriptName = "blm-shortlinks"
    static let namespaceTitle = "blm-shortlinks"

    // Keychain (data-protection): the Cloudflare API token + the Worker admin secret.
    private static var keychainService: String {
        "\(Bundle.main.bundleIdentifier ?? "com.blacklabel.marketing").cfshortlinks"
    }
    private static func keychainBase(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
    }
    private static let apiAccount = "api"      // the CF API token (Workers Scripts + KV edit scopes)
    private static let adminAccount = "admin"  // the Worker's ADMIN_SECRET bearer

    static var accountID: String {
        get { (UserDefaults.standard.string(forKey: accountIDKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: accountIDKey) }
            else { UserDefaults.standard.set(v, forKey: accountIDKey) }
        }
    }
    static var workerURL: String {
        get { (UserDefaults.standard.string(forKey: workerURLKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: workerURLKey) }
            else { UserDefaults.standard.set(v, forKey: workerURLKey) }
        }
    }
    static var namespaceID: String {
        get { (UserDefaults.standard.string(forKey: namespaceIDKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces)
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: namespaceIDKey) }
            else { UserDefaults.standard.set(v, forKey: namespaceIDKey) }
        }
    }
    static var customDomain: String {
        get { (UserDefaults.standard.string(forKey: customDomainKey) ?? "").trimmingCharacters(in: .whitespaces) }
        set {
            let v = newValue.trimmingCharacters(in: .whitespaces).lowercased()
            if v.isEmpty { UserDefaults.standard.removeObject(forKey: customDomainKey) }
            else { UserDefaults.standard.set(v, forKey: customDomainKey) }
        }
    }

    // MARK: the Cloudflare API token (used only to provision/redeploy the Worker)
    static func setAPIToken(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespaces)
        let base = keychainBase(account: apiAccount)
        if t.isEmpty { MarketingKeychain.delete(base); return }
        MarketingKeychain.set(base, data: Data(t.utf8), accessible: kSecAttrAccessibleWhenUnlocked)
    }
    static var apiToken: String? {
        let base = keychainBase(account: apiAccount)
        guard let data = MarketingKeychain.copy(base, accessible: kSecAttrAccessibleWhenUnlocked,
                                                allowAuthenticationUI: false),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
    static var hasAPIToken: Bool { apiToken != nil }

    // MARK: the Worker admin secret (bearer for /api/* on the buyer's Worker)
    static func setAdminSecret(_ secret: String) {
        let t = secret.trimmingCharacters(in: .whitespaces)
        let base = keychainBase(account: adminAccount)
        if t.isEmpty { MarketingKeychain.delete(base); return }
        MarketingKeychain.set(base, data: Data(t.utf8), accessible: kSecAttrAccessibleWhenUnlocked)
    }
    static var adminSecret: String? {
        let base = keychainBase(account: adminAccount)
        guard let data = MarketingKeychain.copy(base, accessible: kSecAttrAccessibleWhenUnlocked,
                                                allowAuthenticationUI: false),
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }
    static var hasAdminSecret: Bool { adminSecret != nil }
    static var hasSavedAdminItem: Bool { MarketingKeychain.exists(keychainBase(account: adminAccount)) }
    static var adminNeedsReconnect: Bool { !hasAdminSecret && hasSavedAdminItem }
    static func migrateSavedSecrets() -> Bool {
        let a = MarketingKeychain.migrate(keychainBase(account: adminAccount), accessible: kSecAttrAccessibleWhenUnlocked)
        let b = MarketingKeychain.migrate(keychainBase(account: apiAccount), accessible: kSecAttrAccessibleWhenUnlocked)
        return a || b
    }

    /// True only when the buyer's Worker is reachable in principle: a stored Worker URL AND the
    /// admin secret. Pure over its inputs so the UI chip and the CRUD paths agree.
    static func isProvisioned(workerURL: String, hasAdminSecret: Bool) -> Bool {
        guard let url = URL(string: workerURL), url.scheme?.lowercased() == "https", url.host != nil else { return false }
        return hasAdminSecret
    }
    static var isProvisioned: Bool { isProvisioned(workerURL: workerURL, hasAdminSecret: hasAdminSecret) }

    // MARK: cache of the last REAL link list (non-secret; instant list on relaunch, honest age)
    static func saveList(_ links: [ShortLink], fetchedAt: Date = Date()) {
        if let d = try? JSONEncoder().encode(ShortlinksCache(links: links, fetchedAt: fetchedAt)) {
            UserDefaults.standard.set(d, forKey: lastListKey)
        }
    }
    static var lastList: ShortlinksCache? {
        guard let d = UserDefaults.standard.data(forKey: lastListKey) else { return nil }
        return try? JSONDecoder().decode(ShortlinksCache.self, from: d)
    }

    /// Disconnect locally. Deliberately does NOT touch the buyer's Cloudflare account — the Worker,
    /// KV data, and links they own stay exactly where they are.
    static func clearLocal() {
        UserDefaults.standard.removeObject(forKey: workerURLKey)
        UserDefaults.standard.removeObject(forKey: namespaceIDKey)
        UserDefaults.standard.removeObject(forKey: customDomainKey)
        UserDefaults.standard.removeObject(forKey: lastListKey)
        setAPIToken("")
        setAdminSecret("")
    }
}

// MARK: - the provisioning + link CRUD client (pure builders/parsers + async transport)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum CloudflareShortlinks {
    static let apiBase = "https://api.cloudflare.com/client/v4"
    static let moduleFileName = "shortlink.js"
    static let compatibilityDate = "2025-01-15"

    struct StepResult: Equatable { var ok: Bool; var detail: String }
    struct ProvisionResult: Equatable {
        var ok: Bool
        var workerURL: String
        var namespaceID: String
        var detail: String
    }

    // MARK: pure — slug + destination hygiene (mirrors the Worker's own validation)

    static func normalizedSlug(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Same contract as the Worker's SLUG_RE: 1–64 chars of a-z 0-9 - _, starting alphanumeric,
    /// and never the reserved "api" path.
    static func isValidSlug(_ s: String) -> Bool {
        let slug = normalizedSlug(s)
        guard !slug.isEmpty, slug.count <= 64, slug != "api" else { return false }
        let head = slug.unicodeScalars.first!
        guard CharacterSet.lowercaseLetters.contains(head) || CharacterSet.decimalDigits.contains(head) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_")
        return slug.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Normalize a destination like Studio.buildUTM normalizes its base: prepend https:// when the
    /// scheme is missing, then require a real host. Honest nil when it can't be a link.
    static func normalizeDestination(_ raw: String) -> String? {
        let b = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return nil }
        let normalized = (b.hasPrefix("http://") || b.hasPrefix("https://")) ? b : "https://" + b
        guard let comp = URLComponents(string: normalized), let host = comp.host, !host.isEmpty,
              host.contains(".") else { return nil }
        return comp.url?.absoluteString
    }

    /// Random slug from an unambiguous alphabet (no 0/o/1/l lookalikes).
    static func randomSlug(length: Int = 6) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return String((0..<max(1, length)).compactMap { _ in alphabet.randomElement() })
    }

    /// 32 random bytes, hex — the Worker's ADMIN_SECRET. Generated on-device, stored in Keychain.
    static func randomAdminSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // SecRandom failing is effectively unheard of; fall back to SystemRandomNumberGenerator.
            var rng = SystemRandomNumberGenerator()
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The base short links are DISPLAYED/copied from: the buyer's custom domain when they attached
    /// one, else the workers.dev URL. Pure so the screen and copy actions agree.
    static func displayBase(workerURL: String, customDomain: String) -> String {
        let domain = customDomain.trimmingCharacters(in: .whitespaces).lowercased()
        if !domain.isEmpty {
            let base = (domain.hasPrefix("http://") || domain.hasPrefix("https://")) ? domain : "https://" + domain
            if let comp = URLComponents(string: base), let host = comp.host, host.contains(".") {
                return "https://" + host
            }
        }
        return workerURL.hasSuffix("/") ? String(workerURL.dropLast()) : workerURL
    }

    static func shortURL(base: String, slug: String) -> String {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        return b + "/" + normalizedSlug(slug)
    }

    // MARK: pure — Cloudflare API request builders

    static func apiRequest(token: String, path: String, method: String, jsonBody: [String: Any]? = nil) -> URLRequest? {
        guard let url = URL(string: apiBase + path) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        if let jsonBody {
            guard let body = try? JSONSerialization.data(withJSONObject: jsonBody) else { return nil }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    /// The script-upload metadata: an ES-module Worker with the KV binding and the admin secret.
    /// sortedKeys so the bytes are deterministic (testable without a socket).
    static func uploadMetadata(namespaceID: String, adminSecret: String) -> Data? {
        let metadata: [String: Any] = [
            "main_module": moduleFileName,
            "compatibility_date": compatibilityDate,
            "bindings": [
                ["type": "kv_namespace", "name": "LINKS", "namespace_id": namespaceID],
                ["type": "secret_text", "name": "ADMIN_SECRET", "text": adminSecret]
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
    }

    /// multipart/form-data body for PUT /workers/scripts/{name}: a `metadata` JSON part + the
    /// module script part. Pure over its inputs.
    static func multipartScriptBody(boundary: String, metadata: Data, script: String) -> Data {
        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"metadata\"\r\n")
        append("Content-Type: application/json\r\n\r\n")
        body.append(metadata)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(moduleFileName)\"; filename=\"\(moduleFileName)\"\r\n")
        append("Content-Type: application/javascript+module\r\n\r\n")
        append(script)
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func scriptUploadRequest(token: String, accountID: String, namespaceID: String,
                                    adminSecret: String, boundary: String = "blm-\(UUID().uuidString)") -> URLRequest? {
        guard let metadata = uploadMetadata(namespaceID: namespaceID, adminSecret: adminSecret),
              let url = URL(string: "\(apiBase)/accounts/\(accountID)/workers/scripts/\(CloudflareShortlinksConfig.scriptName)")
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipartScriptBody(boundary: boundary, metadata: metadata, script: workerScript)
        req.timeoutInterval = 60
        return req
    }

    // MARK: pure — Cloudflare envelope parsing ({"success":bool,"result":…,"errors":[…]})

    static func apiEnvelope(_ data: Data) -> (ok: Bool, result: Any?, error: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, nil, "Cloudflare returned an unreadable response.")
        }
        let ok = (obj["success"] as? Bool) == true
        let msg = (obj["errors"] as? [[String: Any]])?
            .compactMap { e -> String? in
                guard let m = e["message"] as? String, !m.isEmpty else { return nil }
                if let code = e["code"] as? Int { return "\(m) (code \(code))" }
                return m
            }
            .joined(separator: "; ") ?? ""
        return (ok, obj["result"], ok ? "" : (msg.isEmpty ? "Cloudflare rejected the request." : msg))
    }

    static func namespaceID(fromCreate data: Data) -> String? {
        let env = apiEnvelope(data)
        guard env.ok, let result = env.result as? [String: Any],
              let id = result["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    static func namespaceID(fromList data: Data, title: String) -> String? {
        let env = apiEnvelope(data)
        guard env.ok, let list = env.result as? [[String: Any]] else { return nil }
        return list.first { ($0["title"] as? String) == title }?["id"] as? String
    }

    static func subdomain(from data: Data) -> String? {
        let env = apiEnvelope(data)
        guard env.ok, let result = env.result as? [String: Any],
              let sub = result["subdomain"] as? String, !sub.isEmpty else { return nil }
        return sub
    }

    // MARK: pure — the buyer's Worker responses

    private struct WorkerLinksEnvelope: Decodable {
        var ok: Bool?
        var links: [ShortLink]?
        var link: ShortLink?
        var error: String?
    }
    private struct WorkerHealthEnvelope: Decodable {
        var ok: Bool?
        var service: String?
        var version: Int?
    }

    static func parseLinks(_ data: Data) -> (links: [ShortLink]?, error: String) {
        guard let env = try? JSONDecoder().decode(WorkerLinksEnvelope.self, from: data) else {
            return (nil, "The Worker returned an unreadable response.")
        }
        if env.ok == true, let links = env.links { return (links, "") }
        return (nil, env.error ?? "The Worker returned no link list.")
    }

    static func parseCreatedLink(_ data: Data) -> (link: ShortLink?, error: String) {
        guard let env = try? JSONDecoder().decode(WorkerLinksEnvelope.self, from: data) else {
            return (nil, "The Worker returned an unreadable response.")
        }
        if env.ok == true, let link = env.link { return (link, "") }
        return (nil, env.error ?? "The Worker didn't confirm the link.")
    }

    static func parseHealth(statusCode: Int, data: Data) -> StepResult {
        guard statusCode == 200,
              let env = try? JSONDecoder().decode(WorkerHealthEnvelope.self, from: data),
              env.ok == true, env.service == "shortlinks" else {
            if statusCode == 401 {
                return StepResult(ok: false, detail: "The Worker rejected the admin secret — re-provision to rotate it.")
            }
            return StepResult(ok: false, detail: "The short-link Worker isn't answering yet (HTTP \(statusCode)).")
        }
        return StepResult(ok: true, detail: "Worker live (v\(env.version ?? 0)).")
    }

    static func workerRequest(base: String, path: String, method: String, secret: String,
                              jsonBody: [String: Any]? = nil) -> URLRequest? {
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: b + path), url.scheme?.lowercased() == "https" else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        if let jsonBody {
            guard let body = try? JSONSerialization.data(withJSONObject: jsonBody) else { return nil }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    // MARK: async — one-click provision (namespace → script upload → workers.dev → health probe)

    static func createOrFindNamespace(token: String, accountID: String) async -> (id: String?, detail: String) {
        let title = CloudflareShortlinksConfig.namespaceTitle
        if let req = apiRequest(token: token, path: "/accounts/\(accountID)/storage/kv/namespaces",
                                method: "POST", jsonBody: ["title": title]),
           let (data, _) = try? await ConsentedEgress.sendUngated(req, lane: .ownAccountAPI) {
            if let id = namespaceID(fromCreate: data) { return (id, "Created KV namespace \(title).") }
            // Likely "namespace already exists" from an earlier provision — find it by title.
            if let listReq = apiRequest(token: token,
                                        path: "/accounts/\(accountID)/storage/kv/namespaces?per_page=100&order=title",
                                        method: "GET"),
               let (listData, _) = try? await ConsentedEgress.sendUngated(listReq, lane: .ownAccountAPI),
               let id = namespaceID(fromList: listData, title: title) {
                return (id, "Reusing your existing KV namespace \(title).")
            }
            return (nil, apiEnvelope(data).error.isEmpty
                ? "Couldn't create or find the KV namespace — check the token has Workers KV Storage: Edit."
                : apiEnvelope(data).error)
        }
        return (nil, "Network error reaching the Cloudflare API.")
    }

    static func uploadWorker(token: String, accountID: String, namespaceID: String, adminSecret: String) async -> StepResult {
        guard let req = scriptUploadRequest(token: token, accountID: accountID,
                                            namespaceID: namespaceID, adminSecret: adminSecret) else {
            return StepResult(ok: false, detail: "Couldn't build the Worker upload request.")
        }
        guard let (data, _) = try? await ConsentedEgress.sendUngated(req, lane: .ownAccountAPI) else {
            return StepResult(ok: false, detail: "Network error uploading the Worker.")
        }
        let env = apiEnvelope(data)
        return env.ok
            ? StepResult(ok: true, detail: "Worker script deployed.")
            : StepResult(ok: false, detail: env.error.isEmpty
                ? "Cloudflare rejected the Worker upload — check the token has Workers Scripts: Edit."
                : env.error)
    }

    static func enableWorkersDev(token: String, accountID: String) async -> (url: String?, detail: String) {
        guard let subReq = apiRequest(token: token, path: "/accounts/\(accountID)/workers/subdomain", method: "GET"),
              let (subData, _) = try? await ConsentedEgress.sendUngated(subReq, lane: .ownAccountAPI),
              let sub = subdomain(from: subData) else {
            return (nil, "Your account has no workers.dev subdomain yet — open the Cloudflare dashboard → Workers & Pages once to claim one, then provision again.")
        }
        // Enable the workers.dev route for this script (idempotent; ignore-if-already-on is decided
        // by the health probe, which is the real proof).
        if let enableReq = apiRequest(token: token,
                                      path: "/accounts/\(accountID)/workers/scripts/\(CloudflareShortlinksConfig.scriptName)/subdomain",
                                      method: "POST", jsonBody: ["enabled": true]) {
            _ = try? await ConsentedEgress.sendUngated(enableReq, lane: .ownAccountAPI)
        }
        return ("https://\(CloudflareShortlinksConfig.scriptName).\(sub).workers.dev", "workers.dev route enabled.")
    }

    static func verifyHealth(workerURL: String, secret: String) async -> StepResult {
        guard let req = workerRequest(base: workerURL, path: "/api/health", method: "GET", secret: secret) else {
            return StepResult(ok: false, detail: "The stored Worker URL is invalid.")
        }
        guard let (data, resp) = try? await ConsentedEgress.sendUngated(req, lane: .ownAccountAPI) else {
            return StepResult(ok: false, detail: "Network error reaching the short-link Worker.")
        }
        return parseHealth(statusCode: (resp as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }

    /// The one-click provision. On success, persists the whole config (Worker URL, namespace id,
    /// account id, both secrets) so the screen flips to live and CRUD works immediately.
    static func provision(token: String, accountID: String) async -> ProvisionResult {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return ProvisionResult(ok: false, workerURL: "", namespaceID: "", detail: "Add your Cloudflare API token first.") }
        guard !account.isEmpty else { return ProvisionResult(ok: false, workerURL: "", namespaceID: "", detail: "Add your Cloudflare Account ID first.") }

        let ns = await createOrFindNamespace(token: t, accountID: account)
        guard let namespaceID = ns.id else { return ProvisionResult(ok: false, workerURL: "", namespaceID: "", detail: ns.detail) }

        // Keep an existing admin secret across re-provisions so already-copied links keep working
        // from the same config; generate one only on first run.
        let secret = CloudflareShortlinksConfig.adminSecret ?? randomAdminSecret()

        let upload = await uploadWorker(token: t, accountID: account, namespaceID: namespaceID, adminSecret: secret)
        guard upload.ok else { return ProvisionResult(ok: false, workerURL: "", namespaceID: namespaceID, detail: upload.detail) }

        let route = await enableWorkersDev(token: t, accountID: account)
        guard let workerURL = route.url else { return ProvisionResult(ok: false, workerURL: "", namespaceID: namespaceID, detail: route.detail) }

        // A fresh workers.dev route can take a few seconds to serve — probe with patience, and only
        // a REAL healthy answer flips the config to provisioned.
        var health = StepResult(ok: false, detail: "The Worker never answered the health probe.")
        for attempt in 0..<4 {
            health = await verifyHealth(workerURL: workerURL, secret: secret)
            if health.ok { break }
            if attempt < 3 { try? await Task.sleep(nanoseconds: 2_000_000_000) }
        }
        guard health.ok else {
            return ProvisionResult(ok: false, workerURL: workerURL, namespaceID: namespaceID,
                                   detail: "Deployed, but the Worker didn't answer at \(workerURL) yet: \(health.detail) Try Re-check in a minute.")
        }

        CloudflareShortlinksConfig.accountID = account
        CloudflareShortlinksConfig.workerURL = workerURL
        CloudflareShortlinksConfig.namespaceID = namespaceID
        CloudflareShortlinksConfig.setAPIToken(t)
        CloudflareShortlinksConfig.setAdminSecret(secret)
        return ProvisionResult(ok: true, workerURL: workerURL, namespaceID: namespaceID,
                               detail: "Live on your Cloudflare account. \(health.detail)")
    }

    // MARK: async — link CRUD through the buyer's OWN Worker

    static func listLinks() async -> (links: [ShortLink]?, detail: String) {
        guard CloudflareShortlinksConfig.isProvisioned, let secret = CloudflareShortlinksConfig.adminSecret else {
            return (nil, "Connect Cloudflare first.")
        }
        guard let req = workerRequest(base: CloudflareShortlinksConfig.workerURL, path: "/api/links",
                                      method: "GET", secret: secret) else {
            return (nil, "The stored Worker URL is invalid.")
        }
        guard let (data, _) = try? await ConsentedEgress.sendUngated(req, lane: .ownAccountAPI) else {
            return (nil, "Network error reaching your short-link Worker.")
        }
        let parsed = parseLinks(data)
        if let links = parsed.links {
            CloudflareShortlinksConfig.saveList(links)
            return (links, "Pulled \(links.count) link\(links.count == 1 ? "" : "s") from your Worker.")
        }
        return (nil, parsed.error)
    }

    static func createLink(slug: String, destination: String) async -> (link: ShortLink?, detail: String) {
        guard CloudflareShortlinksConfig.isProvisioned, let secret = CloudflareShortlinksConfig.adminSecret else {
            return (nil, "Connect Cloudflare first.")
        }
        let s = normalizedSlug(slug)
        guard isValidSlug(s) else {
            return (nil, "Slug must be 1–64 chars of a-z, 0-9, - or _ (and not \"api\").")
        }
        guard let dest = normalizeDestination(destination) else {
            return (nil, "That destination isn't a valid URL — paste a full link (e.g. from the UTM builder).")
        }
        guard let req = workerRequest(base: CloudflareShortlinksConfig.workerURL, path: "/api/links",
                                      method: "POST", secret: secret, jsonBody: ["slug": s, "url": dest]) else {
            return (nil, "The stored Worker URL is invalid.")
        }
        guard let (data, _) = try? await ConsentedEgress.sendUngated(req, lane: .ownAccountAPI) else {
            return (nil, "Network error reaching your short-link Worker.")
        }
        let parsed = parseCreatedLink(data)
        return (parsed.link, parsed.link != nil ? "Short link created." : parsed.error)
    }

    static func deleteLink(slug: String) async -> StepResult {
        guard CloudflareShortlinksConfig.isProvisioned, let secret = CloudflareShortlinksConfig.adminSecret else {
            return StepResult(ok: false, detail: "Connect Cloudflare first.")
        }
        let s = normalizedSlug(slug)
        guard let encoded = s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let req = workerRequest(base: CloudflareShortlinksConfig.workerURL, path: "/api/links/\(encoded)",
                                      method: "DELETE", secret: secret) else {
            return StepResult(ok: false, detail: "The stored Worker URL is invalid.")
        }
        guard let (data, resp) = try? await ConsentedEgress.sendUngated(req, lane: .ownAccountAPI) else {
            return StepResult(ok: false, detail: "Network error reaching your short-link Worker.")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { return StepResult(ok: true, detail: "Deleted /\(s).") }
        let err = (try? JSONDecoder().decode(WorkerErrorEnvelope.self, from: data))?.error
        return StepResult(ok: false, detail: err ?? "The Worker returned HTTP \(code).")
    }
    private struct WorkerErrorEnvelope: Decodable { var error: String? }

    // MARK: the Worker source the app uploads (byte-identical to cloudflare/shortlink-worker.js)

    static let workerScript = #"""
// Black Label Marketing — buyer-owned branded short links (Cloudflare Workers + KV, free tier).
//
// This Worker runs on the BUYER'S OWN Cloudflare account — the app deploys it one-click from
// Distribute → Short Links (Sources/Shortlinks.swift uploads this exact script over the Cloudflare
// API), or you can deploy it manually with wrangler. Bindings it expects:
//   LINKS         KV namespace  (link:<slug> → destination URL; clicks:<slug> → counter)
//   ADMIN_SECRET  bearer secret for the /api/* management routes (the app generates + stores it)
//
// Routes:
//   GET  /<slug>              → 301 redirect to the stored destination (public)
//   GET  /api/health          → { ok, service, version }                    (bearer)
//   GET  /api/links           → { ok, links: [{slug,url,created,clicks}] }  (bearer)
//   POST /api/links           → create { slug, url }                        (bearer)
//   DELETE /api/links/<slug>  → delete the link + its counter               (bearer)
//
// HONEST LIMITS: click counters use KV read-modify-write — KV has no atomic increment, so
// concurrent clicks can under-count. Redirects are 301 and may be cached by browsers/CDNs.
// The app surfaces both caveats; never present these counts as exact analytics.

export const VERSION = 1;
const SLUG_RE = /^[a-z0-9][a-z0-9_-]{0,63}$/;

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json", "cache-control": "no-store" },
  });

async function timingSafeEqualStr(a, b) {
  const enc = new TextEncoder();
  const [da, db] = await Promise.all([
    crypto.subtle.digest("SHA-256", enc.encode(a)),
    crypto.subtle.digest("SHA-256", enc.encode(b)),
  ]);
  const va = new Uint8Array(da), vb = new Uint8Array(db);
  let diff = 0;
  for (let i = 0; i < va.length; i++) diff |= va[i] ^ vb[i];
  return diff === 0;
}

function normalizeSlug(value) {
  return String(value ?? "").trim().toLowerCase();
}

// Only absolute http(s) destinations — a short link must never 301 into javascript:/data:.
function validDestination(raw) {
  let url;
  try { url = new URL(String(raw ?? "").trim()); } catch { return null; }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  return url.toString();
}

async function authorized(request, env) {
  const auth = request.headers.get("authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  return Boolean(env.ADMIN_SECRET) && (await timingSafeEqualStr(token, env.ADMIN_SECRET));
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // ---- management API (bearer = the buyer's own admin secret) ----
    if (path === "/api/health" || path === "/api/links" || path.startsWith("/api/links/")) {
      if (!(await authorized(request, env))) return json({ ok: false, error: "unauthorized" }, 401);
      if (!env.LINKS) return json({ ok: false, error: "LINKS KV binding is not configured" }, 503);

      if (path === "/api/health" && request.method === "GET") {
        return json({ ok: true, service: "shortlinks", version: VERSION });
      }

      if (path === "/api/links" && request.method === "GET") {
        const links = [];
        let cursor;
        do {
          const page = await env.LINKS.list({ prefix: "link:", cursor });
          for (const key of page.keys) {
            links.push({
              slug: key.name.slice("link:".length),
              url: (key.metadata && key.metadata.url) || "",
              created: (key.metadata && key.metadata.created) || "",
              clicks: 0,
            });
          }
          cursor = page.list_complete ? undefined : page.cursor;
        } while (cursor);
        for (const link of links) {
          if (!link.url) link.url = (await env.LINKS.get("link:" + link.slug)) || "";
          const clicks = await env.LINKS.get("clicks:" + link.slug);
          link.clicks = clicks ? Number(clicks) || 0 : 0;
        }
        links.sort((a, b) => (b.created || "").localeCompare(a.created || ""));
        return json({ ok: true, version: VERSION, links });
      }

      if (path === "/api/links" && request.method === "POST") {
        let body;
        try { body = await request.json(); }
        catch { return json({ ok: false, error: "invalid JSON" }, 400); }
        const slug = normalizeSlug(body && body.slug);
        const destination = validDestination(body && body.url);
        if (!SLUG_RE.test(slug) || slug === "api") {
          return json({ ok: false, error: "slug must be 1-64 chars of a-z, 0-9, - or _ (and not 'api')" }, 400);
        }
        if (!destination) return json({ ok: false, error: "url must be a valid http(s) URL" }, 400);
        if (await env.LINKS.get("link:" + slug)) {
          return json({ ok: false, error: "that slug already exists — delete it first or pick another" }, 409);
        }
        const created = new Date().toISOString();
        await env.LINKS.put("link:" + slug, destination, { metadata: { url: destination, created } });
        return json({ ok: true, link: { slug, url: destination, created, clicks: 0 } }, 201);
      }

      const match = path.match(/^\/api\/links\/([^/]+)$/);
      if (match && request.method === "DELETE") {
        const slug = normalizeSlug(decodeURIComponent(match[1]));
        if (!SLUG_RE.test(slug)) return json({ ok: false, error: "invalid slug" }, 400);
        await env.LINKS.delete("link:" + slug);
        await env.LINKS.delete("clicks:" + slug);
        return json({ ok: true, deleted: slug });
      }

      return json({ ok: false, error: "not found" }, 404);
    }

    // ---- public redirect: GET /<slug> → 301 ----
    if (request.method !== "GET" && request.method !== "HEAD") {
      return new Response("method not allowed", { status: 405 });
    }
    const slug = normalizeSlug(path.replace(/^\/+/, ""));
    if (!slug || !SLUG_RE.test(slug) || !env.LINKS) {
      return new Response("not found", { status: 404 });
    }
    const destination = await env.LINKS.get("link:" + slug);
    if (!destination) return new Response("not found", { status: 404 });

    // Approximate counter (see HONEST LIMITS above); never blocks the redirect.
    if (request.method === "GET") {
      ctx.waitUntil((async () => {
        const current = Number((await env.LINKS.get("clicks:" + slug)) || "0") || 0;
        await env.LINKS.put("clicks:" + slug, String(current + 1));
      })());
    }
    return Response.redirect(destination, 301);
  },
};
"""#
}
#endif // circuit-convert

// MARK: - headless CLI provision path (wired by main.swift as --configure-cloudflare-shortlinks)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum CloudflareShortlinksCLI {
    /// `--configure-cloudflare-shortlinks <accountID>` with the Cloudflare API token on stdin
    /// (never argv/env). Provisions the Worker + KV on the buyer's account through the installed
    /// app's own Keychain identity, prints ONE machine-parseable line, returns the exit code.
    static func run(accountID: String) -> Int32 {
        let tokenData = FileHandle.standardInput.readDataToEndOfFile()
        let token = (String(data: tokenData, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let account = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !account.isEmpty else {
            print("cloudflare_shortlinks_config|state=Error|reason=missing_account_or_token")
            return 2
        }
        let sem = DispatchSemaphore(value: 0)
        var result: CloudflareShortlinks.ProvisionResult?
        Task {
            result = await CloudflareShortlinks.provision(token: token, accountID: account)
            sem.signal()
        }
        if sem.wait(timeout: .now() + 120) == .timedOut {
            print("cloudflare_shortlinks_config|state=Error|reason=provision_timeout")
            return 2
        }
        if let result, result.ok {
            print("cloudflare_shortlinks_config|state=Connected|worker=\(result.workerURL)|namespace=\(result.namespaceID)")
            return 0
        }
        let detail = (result?.detail ?? "provision_failed")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "/")
        print("cloudflare_shortlinks_config|state=Error|reason=\(detail)")
        return 2
    }
}
#endif // circuit-convert
