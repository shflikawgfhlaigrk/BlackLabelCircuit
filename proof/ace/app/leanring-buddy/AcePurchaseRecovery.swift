import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

nonisolated enum AcePurchaseRecoveryAction: String, Sendable {
    case account, billing, support
}

nonisolated enum AcePurchaseRecoveryError: LocalizedError {
    case missingLicence, refused, unavailable, noSubscription, invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingLicence:
            return "Use the receipt from your original purchase. Black Label Bots receipts contain the private licence, download and billing links. Enter that licence in Ace to reopen its receipt here."
        case .refused:
            return "This Mac could not verify the original purchase. Use its receipt or contact hello@ace-bl.tech."
        case .noSubscription:
            return "Your Ace access is complimentary; there is no separate Ace subscription to cancel."
        case .unavailable, .invalidResponse:
            return "Purchase recovery is unavailable. Use your original receipt or contact hello@ace-bl.tech."
        }
    }
}

/// Private receipt URLs exist only for this handoff. The request uses the
/// existing licence and Mac binding, with no cookies, redirect, cache or logs.
nonisolated enum AcePurchaseRecovery {
    static let endpoint = URL(string: "https://blacklabelbots.com/api/007/ace/recovery")!

    static func request(action: AcePurchaseRecoveryAction, key: String,
                        deviceIdentifier: String) throws -> URLRequest {
        guard key.range(of: #"^ACE-(?:[A-Z0-9]{4}-){3}[A-Z0-9]{4}$"#, options: .regularExpression) != nil,
              !deviceIdentifier.isEmpty, deviceIdentifier.utf8.count <= 200,
              deviceIdentifier.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw AcePurchaseRecoveryError.missingLicence
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": action.rawValue, "key": key, "deviceId": deviceIdentifier,
        ])
        return request
    }

    static func destination(data: Data, response: URLResponse,
                            action: AcePurchaseRecoveryAction) throws -> URL {
        guard let response = response as? HTTPURLResponse,
              response.url == endpoint else { throw AcePurchaseRecoveryError.invalidResponse }
        switch response.statusCode {
        case 200: break
        case 403: throw AcePurchaseRecoveryError.refused
        case 409: throw AcePurchaseRecoveryError.noSubscription
        default: throw AcePurchaseRecoveryError.unavailable
        }
        guard data.count <= 4096,
              response.mimeType == "application/json",
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(payload.keys) == ["ok", "channel", "url"],
              let ok = payload["ok"] as? NSNumber,
              CFGetTypeID(ok) == CFBooleanGetTypeID(), ok.boolValue,
              let channel = payload["channel"] as? String,
              let rawURL = payload["url"] as? String,
              let components = URLComponents(string: rawURL),
              components.scheme == "https", components.user == nil,
              components.password == nil, components.port == nil,
              components.fragment == nil, let destination = components.url else {
            throw AcePurchaseRecoveryError.invalidResponse
        }
        if channel == "ace", rawURL == "https://ace-bl.tech/account" { return destination }
        guard channel == "blacklabelbots", components.host == "blacklabelbots.com",
              components.percentEncodedPath == components.path,
              components.path.range(of: #"^/r/[A-Za-z0-9_-]{32,80}(?:/manage|/ace)?$"#,
                                    options: .regularExpression) != nil,
              let items = components.queryItems, items.count == 1,
              items[0].name == "session_id", let session = items[0].value,
              session.range(of: #"^cs_live_[A-Za-z0-9_]{8,240}$"#, options: .regularExpression) != nil,
              components.percentEncodedQuery == "session_id=" + session,
              (action == .billing) == components.path.hasSuffix("/manage") else {
            throw AcePurchaseRecoveryError.invalidResponse
        }
        return destination
    }

    static func resolve(action: AcePurchaseRecoveryAction, key: String,
                        deviceIdentifier: String) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 15
        let session = URLSession(configuration: configuration,
                                 delegate: AcePurchaseRecoveryRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let result = try await StealthURLSessionRequest(session: session).perform(
            request(action: action, key: key, deviceIdentifier: deviceIdentifier)
        )
        try Task.checkCancellation()
        return try destination(data: result.0, response: result.1, action: action)
    }
}

nonisolated final class AcePurchaseRecoveryRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
