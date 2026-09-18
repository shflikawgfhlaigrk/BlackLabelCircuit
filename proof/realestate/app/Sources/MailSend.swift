// Black Label Real Estate — BUYER-KEY direct-mail SEND (real Lob / PostGrid letter dispatch).
//
// The parity gap this closes: competitors mail seller letters / postcards in-app. We already
// GENERATE a real Letter of Intent (Offer.loiText), but there was no in-app "Send" — the buyer had
// to copy/paste into another tool. This wires a REAL send through the buyer's OWN mail-vendor key
// (Lob or PostGrid — both documented REST shapes implemented). No new Black Label paid service
// (CHARTER §5.5): the letter is dispatched under the buyer's account, billed to the buyer, addressed
// from the buyer's return address.
//
// Honesty rules baked in:
//   • Review-first: the caller shows a confirm sheet (to/from/preview + a cost note) before this
//     runs. Nothing is sent silently.
//   • NEVER a fake "sent": a MailSendResult is only constructed from a REAL provider letter id in
//     the response. A network/HTTP/parse failure throws — the UI surfaces the provider's own error,
//     it never displays a fabricated "delivered/sent".
//   • Buyer key at rest lives in the Keychain (MailVendorKeychain), never the model or the bundle.
//
// The request-builder and response-parser are PURE, so the whole path is unit-tested with canned
// fixtures; only the transport is injected.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Vendor
enum MailVendor: String, Codable, CaseIterable, Identifiable {
    case lob, postgrid
    var id: String { rawValue }
    var label: String { switch self { case .lob: return "Lob"; case .postgrid: return "PostGrid" } }
    var host: String { switch self { case .lob: return "api.lob.com"; case .postgrid: return "api.postgrid.com" } }
    var endpoint: URL {
        switch self {
        case .lob: return URL(string: "https://api.lob.com/v1/letters")!
        case .postgrid: return URL(string: "https://api.postgrid.com/print-mail/v1/letters")!
        }
    }
    var signupHint: String {
        switch self {
        case .lob: return "Create a Live API key in your Lob dashboard (Settings → API Keys) and paste it here."
        case .postgrid: return "Create a Live API key in your PostGrid dashboard (Settings → API) and paste it here."
        }
    }
}

// MARK: - Keychain store for the buyer's mail-vendor key (secret at rest).
enum MailVendorKeychain {
    private static let account = "com.blacklabel.realestate.mailvendor"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }
    static func set(_ key: String) {
        let t = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { RealEstateKeychain.delete(base) } else { RealEstateKeychain.set(base, data: Data(t.utf8)) }
    }
    static func get() -> String? {
        guard let d = RealEstateKeychain.copy(base), let s = String(data: d, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    static func hasKey() -> Bool { get() != nil }
    static func clear() { RealEstateKeychain.delete(base) }
}

// MARK: - Address (both to + from must be a real, mailable US address).
struct MailAddress: Hashable {
    var name = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var state = ""
    var zip = ""

    var missingFields: [String] {
        var m: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { m.append("name") }
        if line1.trimmingCharacters(in: .whitespaces).isEmpty { m.append("street") }
        if city.trimmingCharacters(in: .whitespaces).isEmpty { m.append("city") }
        if state.trimmingCharacters(in: .whitespaces).isEmpty { m.append("state") }
        if zip.trimmingCharacters(in: .whitespaces).isEmpty { m.append("ZIP") }
        return m
    }
    var isComplete: Bool { missingFields.isEmpty }

    /// Build from a one-line address string + a name (best-effort; caller can still edit fields).
    static func from(name: String, oneLine: String) -> MailAddress {
        let p = AddressParts.parse(oneLine)
        return MailAddress(name: name, line1: p.street, line2: "", city: p.city, state: p.state, zip: p.zip)
    }
}

struct MailPiece: Hashable {
    var to: MailAddress
    var from: MailAddress
    var html: String            // the letter body rendered as HTML (Offer.loiText wrapped)
    var color = false
    var description = "Seller letter"
}

// MARK: - Result — ONLY ever built from a real provider letter id (no fabricated "sent").
struct MailSendResult: Hashable {
    var id: String              // provider letter id (ltr_… / letter_…)
    var status: String
    var expectedDelivery: String
    var url: String
    var vendorLabel: String
}

enum MailSendError: LocalizedError, Equatable {
    case notConfigured
    case incompleteAddress(String)
    case emptyBody
    case transport(String)
    case http(Int, String)
    case decode(String)
    case noLetterID
    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No mail provider connected. Add your Lob or PostGrid API key in Settings to send letters."
        case .incompleteAddress(let which): return "The \(which) address is incomplete — fill every field before sending."
        case .emptyBody: return "The letter has no body to print."
        case .transport(let m): return "Couldn't reach your mail provider (\(m)). Nothing was sent."
        case .http(let code, let body):
            if code == 401 || code == 403 { return "Your provider rejected the API key (HTTP \(code)). Check the key in Settings." }
            let detail = MailSend.serverMessage(body).map { ": \($0)" } ?? ""
            return "Your provider rejected the letter (HTTP \(code))\(detail). Nothing was sent."
        case .decode(let m): return "Your provider's response wasn't understood (\(m)). Treat the letter as NOT sent and check your provider dashboard."
        case .noLetterID: return "Your provider did not return a letter id — the send is not confirmed. Check your provider dashboard before assuming it mailed."
        }
    }
}

enum MailSend {
    static func egressHost(_ vendor: MailVendor) -> String { vendor.host }

    typealias Send = (URLRequest) async throws -> (Data, URLResponse)
    static let liveSend: Send = { req in try await URLSession.shared.data(for: req) }

    // MARK: Readiness — the honest gate the UI renders before enabling Send.
    static func readiness(vendor: MailVendor, hasKey: Bool, piece: MailPiece) -> [String] {
        var blockers: [String] = []
        if !hasKey { blockers.append("Add your \(vendor.label) API key in Settings.") }
        if !piece.to.isComplete { blockers.append("Recipient address needs: \(piece.to.missingFields.joined(separator: ", ")).") }
        if !piece.from.isComplete { blockers.append("Your return address needs: \(piece.from.missingFields.joined(separator: ", ")).") }
        if piece.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blockers.append("The letter has no body.") }
        return blockers
    }

    // MARK: Request builder (pure). Buyer-authed; sent ONLY to the vendor host.
    static func buildRequest(piece: MailPiece, vendor: MailVendor, apiKey: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw MailSendError.notConfigured }
        guard piece.to.isComplete else { throw MailSendError.incompleteAddress("recipient") }
        guard piece.from.isComplete else { throw MailSendError.incompleteAddress("return") }
        guard !piece.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailSendError.emptyBody }

        var req = URLRequest(url: vendor.endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("BlackLabelRealEstate/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        func addr(_ a: MailAddress) -> [String: String] {
            var d = ["name": a.name, "address_line1": a.line1,
                     "address_city": a.city, "address_state": a.state, "address_zip": a.zip]
            if !a.line2.trimmingCharacters(in: .whitespaces).isEmpty { d["address_line2"] = a.line2 }
            return d
        }
        var body: [String: Any]
        switch vendor {
        case .lob:
            // Lob: HTTP Basic, API key as username with empty password.
            let token = Data("\(key):".utf8).base64EncodedString()
            req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            body = ["to": addr(piece.to), "from": addr(piece.from),
                    "file": piece.html, "color": piece.color, "description": piece.description]
        case .postgrid:
            // PostGrid: x-api-key header; addresses use line1/city/provinceOrState/postalOrZip.
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            func pgAddr(_ a: MailAddress) -> [String: String] {
                var d = ["firstName": a.name, "addressLine1": a.line1,
                         "city": a.city, "provinceOrState": a.state, "postalOrZip": a.zip, "country": "US"]
                if !a.line2.trimmingCharacters(in: .whitespaces).isEmpty { d["addressLine2"] = a.line2 }
                return d
            }
            body = ["to": pgAddr(piece.to), "from": pgAddr(piece.from),
                    "html": piece.html, "color": piece.color, "description": piece.description]
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
        return req
    }

    // MARK: Response parser (pure). MUST find a real letter id, else throws (never a fake "sent").
    static func parse(_ data: Data, vendor: MailVendor) throws -> MailSendResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MailSendError.decode("not JSON")
        }
        let obj = (root["data"] as? [String: Any]) ?? root      // PostGrid wraps in {data:{…}}
        guard let id = (obj["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else {
            throw MailSendError.noLetterID
        }
        let status = (obj["status"] as? String) ?? "submitted"
        let delivery = (obj["expected_delivery_date"] as? String) ?? (obj["sendDate"] as? String) ?? ""
        let url = (obj["url"] as? String) ?? ""
        return MailSendResult(id: id, status: status, expectedDelivery: delivery, url: url, vendorLabel: vendor.label)
    }

    // MARK: Send (build → transport → parse). Throws on any failure — no fabricated confirmation.
    static func send(piece: MailPiece, vendor: MailVendor, apiKey: String,
                     send: Send = liveSend) async throws -> MailSendResult {
        let req = try buildRequest(piece: piece, vendor: vendor, apiKey: apiKey)
        guard req.url?.host == egressHost(vendor) else { throw MailSendError.transport("blocked: send host mismatch") }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await send(req) }
        catch { throw MailSendError.transport(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw MailSendError.transport("no response") }
        guard (200...299).contains(http.statusCode) else {
            throw MailSendError.http(http.statusCode, String((String(data: data, encoding: .utf8) ?? "").prefix(200)))
        }
        return try parse(data, vendor: vendor)
    }

    /// Wrap a plaintext LOI/letter body into minimal print-ready HTML (both vendors accept HTML).
    static func htmlForLetter(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br/>")
        return """
        <html><head><meta charset="utf-8"><style>
        body{font-family:Georgia,'Times New Roman',serif;font-size:11pt;line-height:1.5;margin:1in;color:#111}
        </style></head><body>\(escaped)</body></html>
        """
    }

    static func serverMessage(_ body: String) -> String? {
        let t = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let d = t.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        if let e = o["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = o["message"] as? String { return m }
        return nil
    }
}
