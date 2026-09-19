import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

nonisolated struct AceDeviceAuthorizationSession:
    Equatable,
    Sendable,
    Codable
{
    let requestID: String
    let pollSecret: String
    let userCode: String
    let verificationURL: URL
    let expiresAt: Date
    let intervalSeconds: Int
}

/// Durable half of the device-link transaction. Build 61 held the request ID
/// and poll secret only in memory, so a quit, crash, or Private Mode entry
/// between browser approval and local commit destroyed the ONLY path by which
/// the approved credential could reach this Mac — the website said "linked"
/// while Ace stayed locked forever. Persisting the session lets a relaunch
/// resume the claim; the server retains approved requests beyond the pending
/// window for exactly this recovery.
nonisolated enum AceDeviceLinkTransactionStore {
    /// Where the plaintext v1 files lived. Kept only so migration can import
    /// and delete them; nothing is ever written here again.
    static var defaultLegacyDirectoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/BlackLabel/Ace",
                isDirectory: true
            )
    }

    private static func legacySessionURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(
            "device-link.v1.json",
            isDirectory: false
        )
    }

    private static func legacyAcknowledgementURL(in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent(
            "device-link-ack-pending.v1.json",
            isDirectory: false
        )
    }

    /// False when the phase could not be durably persisted inside the sealed
    /// credential document — the flow continues in memory, but the caller
    /// must gate visible state on this result instead of silently pretending
    /// durability. The poll secret never touches disk as plaintext.
    @discardableResult
    static func save(
        _ session: AceDeviceAuthorizationSession,
        credentialStore: AceCredentialStoring = PromptFreeCredentialStore.shared
    ) -> Bool {
        persistPhase(
            session,
            into: \.deviceLinkSessionJSON,
            credentialStore: credentialStore
        )
    }

    static func load(
        legacyDirectoryURL: URL = defaultLegacyDirectoryURL,
        credentialStore: AceCredentialStoring = PromptFreeCredentialStore.shared
    ) -> AceDeviceAuthorizationSession? {
        migrateLegacyPlaintextIfPresent(
            from: legacySessionURL(in: legacyDirectoryURL),
            into: \.deviceLinkSessionJSON,
            credentialStore: credentialStore
        )
        return loadPhase(\.deviceLinkSessionJSON, credentialStore: credentialStore)
    }

    static func clear(
        legacyDirectoryURL: URL = defaultLegacyDirectoryURL,
        credentialStore: AceCredentialStoring = PromptFreeCredentialStore.shared
    ) {
        try? credentialStore.update { $0.deviceLinkSessionJSON = nil }
        try? FileManager.default.removeItem(
            at: legacySessionURL(in: legacyDirectoryURL)
        )
    }

    /// The credential was committed locally but the server has not yet
    /// confirmed receipt. The website's account pages only call this Mac
    /// "linked" once the acknowledgement lands (delivered_at), so a lost ack
    /// must survive relaunches and keep retrying — one best-effort attempt
    /// left the account page saying "waiting for your Mac" forever.
    @discardableResult
    static func saveAcknowledgementPending(
        _ session: AceDeviceAuthorizationSession,
        credentialStore: AceCredentialStoring = PromptFreeCredentialStore.shared
    ) -> Bool {
        persistPhase(
            session,
            into: \.deviceLinkAcknowledgementPendingJSON,
            credentialStore: credentialStore
        )
    }

    static func loadAcknowledgementPending(
        legacyDirectoryURL: URL = defaultLegacyDirectoryURL,
        credentialStore: AceCredentialStoring = PromptFreeCredentialStore.shared
    ) -> AceDeviceAuthorizationSession? {
        migrateLegacyPlaintextIfPresent(
            from: legacyAcknowledgementURL(in: legacyDirectoryURL),
            into: \.deviceLinkAcknowledgementPendingJSON,
            credentialStore: credentialStore
        )
        return loadPhase(
            \.deviceLinkAcknowledgementPendingJSON,
            credentialStore: credentialStore
        )
    }

    static func clearAcknowledgementPending(
        legacyDirectoryURL: URL = defaultLegacyDirectoryURL,
        credentialStore: AceCredentialStoring = PromptFreeCredentialStore.shared
    ) {
        try? credentialStore.update {
            $0.deviceLinkAcknowledgementPendingJSON = nil
        }
        try? FileManager.default.removeItem(
            at: legacyAcknowledgementURL(in: legacyDirectoryURL)
        )
    }

    private static func persistPhase(
        _ session: AceDeviceAuthorizationSession,
        into phaseKeyPath: WritableKeyPath<AceCredentialDocument, String?>,
        credentialStore: AceCredentialStoring
    ) -> Bool {
        guard let encoded = try? JSONEncoder().encode(session),
              let encodedJSON = String(data: encoded, encoding: .utf8) else {
            return false
        }
        do {
            try credentialStore.update { document in
                document[keyPath: phaseKeyPath] = encodedJSON
            }
            return true
        } catch {
            return false
        }
    }

    private static func loadPhase(
        _ phaseKeyPath: WritableKeyPath<AceCredentialDocument, String?>,
        credentialStore: AceCredentialStoring
    ) -> AceDeviceAuthorizationSession? {
        guard let document = try? credentialStore.load(),
              let encodedJSON = document[keyPath: phaseKeyPath],
              let encoded = encodedJSON.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(
            AceDeviceAuthorizationSession.self,
            from: encoded
        )
    }

    /// One-shot import of a Build ≤63 plaintext phase file. The plaintext is
    /// removed only AFTER the encrypted document durably holds the phase, and
    /// an already-populated encrypted phase always wins over a stale file —
    /// an explicit clear must never be resurrected from legacy plaintext.
    private static func migrateLegacyPlaintextIfPresent(
        from legacyURL: URL,
        into phaseKeyPath: WritableKeyPath<AceCredentialDocument, String?>,
        credentialStore: AceCredentialStoring
    ) {
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            return
        }
        guard let existingDocument = try? credentialStore.load() else {
            // The sealed store is unreadable (tampered key, unsafe modes) —
            // fail closed: keep the legacy file for operator recovery and
            // expose nothing.
            return
        }
        if existingDocument[keyPath: phaseKeyPath] != nil {
            // Encrypted state is newer authority; the stale plaintext only
            // needs to disappear.
            try? FileManager.default.removeItem(at: legacyURL)
            return
        }
        guard let legacyData = try? Data(contentsOf: legacyURL),
              let legacySession = try? JSONDecoder().decode(
                  AceDeviceAuthorizationSession.self,
                  from: legacyData
              ) else {
            // Unreadable/undecodable plaintext carries no recoverable phase;
            // remove the dead file rather than re-reading it forever.
            try? FileManager.default.removeItem(at: legacyURL)
            return
        }
        guard persistPhase(
            legacySession,
            into: phaseKeyPath,
            credentialStore: credentialStore
        ) else {
            // Encrypted write failed: keep the plaintext so the buyer's
            // recovery path survives; migration retries on the next load.
            return
        }
        try? FileManager.default.removeItem(at: legacyURL)
    }
}

nonisolated struct AceDeviceAuthorizationCredential:
    Equatable,
    Sendable
{
    let licenseKey: String
    let activationResponseData: Data
}

nonisolated enum AceDeviceAuthorizationStartVerdict:
    Equatable,
    Sendable
{
    case ready(AceDeviceAuthorizationSession)
    case refused(message: String)
    case retryable
    case invalidResponse
}

nonisolated enum AceDeviceAuthorizationStatusVerdict:
    Equatable,
    Sendable
{
    case pending(expiresAt: Date, intervalSeconds: Int)
    case approved(AceDeviceAuthorizationCredential)
    case expired(message: String)
    case invalid(message: String)
    case retryable
    case invalidResponse
}

enum AceDeviceAuthorizationState: Equatable {
    case idle
    case starting
    case checkingLegacyKey
    case awaitingApproval(
        userCode: String,
        verificationURL: URL,
        expiresAt: Date,
        message: String,
        messageIsFailure: Bool
    )
    case linked(message: String)
    case failed(message: String)
    /// Credential committed locally; the server delivery acknowledgement is
    /// not yet durably verified. Never renders as linked or licensed.
    case finishing(message: String)

    var isWorking: Bool {
        switch self {
        case .starting, .checkingLegacyKey, .awaitingApproval, .finishing:
            return true
        case .idle, .linked, .failed:
            return false
        }
    }

    var ownerMessage: String? {
        switch self {
        case .idle:
            return nil
        case .starting:
            return "Starting secure account approval…"
        case .checkingLegacyKey:
            return "Checking this licence key with the Ace server…"
        case .awaitingApproval(_, _, _, let message, _),
             .linked(let message),
             .failed(let message),
             .finishing(let message):
            return message
        }
    }

    var messageIsFailure: Bool {
        switch self {
        case .awaitingApproval(_, _, _, _, let isFailure):
            return isFailure
        case .failed:
            return true
        case .idle, .starting, .checkingLegacyKey, .linked, .finishing:
            return false
        }
    }
}

/// The byte-level contract between a fresh Ace install and the browser approval
/// service. Browser URLs carry only a short user code; the high-entropy polling
/// secret remains in the app's Authorization header.
nonisolated enum AceDeviceAuthorizationProtocol {
    private static let maximumSessionLifetime: TimeInterval = 30 * 60
    private static let allowedPollInterval = 2...30

    static func makeStartRequest(
        endpoint: URL,
        deviceIdentifier: String,
        deviceName: String
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue(
            "application/json",
            forHTTPHeaderField: "content-type"
        )
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: [
                "deviceId": deviceIdentifier,
                "deviceName": deviceName,
            ]
        )
        return request
    }

    static func makeStatusRequest(
        endpoint: URL,
        session: AceDeviceAuthorizationSession
    ) -> URLRequest {
        makeAuthenticatedRequest(
            endpoint: endpoint,
            session: session
        )
    }

    static func makeAcknowledgeRequest(
        endpoint: URL,
        session: AceDeviceAuthorizationSession
    ) -> URLRequest {
        makeAuthenticatedRequest(
            endpoint: endpoint,
            session: session
        )
    }

    static func isAcknowledged(
        httpStatusCode: Int,
        data: Data
    ) -> Bool {
        guard httpStatusCode == 200,
              let object = jsonObject(data) else {
            return false
        }
        return object["ok"] as? Bool == true
            && object["status"] as? String == "acknowledged"
    }

    private static func makeAuthenticatedRequest(
        endpoint: URL,
        session: AceDeviceAuthorizationSession
    ) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue(
            "application/json",
            forHTTPHeaderField: "content-type"
        )
        request.setValue(
            "Bearer \(session.pollSecret)",
            forHTTPHeaderField: "Authorization"
        )
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["requestId": session.requestID]
        )
        return request
    }

    static func classifyStart(
        httpStatusCode: Int,
        data: Data,
        now: Date = Date()
    ) -> AceDeviceAuthorizationStartVerdict {
        if (500...599).contains(httpStatusCode) {
            return .retryable
        }
        guard let object = jsonObject(data) else {
            return .invalidResponse
        }
        if httpStatusCode != 201 {
            if let message = ownerMessage(from: object),
               (400...499).contains(httpStatusCode) {
                return .refused(message: message)
            }
            return .invalidResponse
        }
        guard object["ok"] as? Bool == true,
              let requestID = object["requestId"] as? String,
              UUID(uuidString: requestID) != nil,
              let pollSecret = object["pollSecret"] as? String,
              isValidPollSecret(pollSecret),
              let userCode = object["userCode"] as? String,
              isValidUserCode(userCode),
              let rawVerificationURL =
                object["verificationUrl"] as? String,
              let verificationURL = URL(string: rawVerificationURL),
              isValidVerificationURL(
                  verificationURL,
                  userCode: userCode
              ),
              let rawExpiry = object["expiresAt"] as? String,
              let expiresAt = parseISO8601(rawExpiry),
              expiresAt > now,
              expiresAt.timeIntervalSince(now)
                <= maximumSessionLifetime,
              let intervalSeconds = object["intervalSeconds"] as? Int,
              allowedPollInterval.contains(intervalSeconds) else {
            return .invalidResponse
        }
        return .ready(
            AceDeviceAuthorizationSession(
                requestID: requestID,
                pollSecret: pollSecret,
                userCode: userCode,
                verificationURL: verificationURL,
                expiresAt: expiresAt,
                intervalSeconds: intervalSeconds
            )
        )
    }

    static func classifyStatus(
        httpStatusCode: Int,
        data: Data,
        now: Date = Date()
    ) -> AceDeviceAuthorizationStatusVerdict {
        if (500...599).contains(httpStatusCode) {
            return .retryable
        }
        guard let object = jsonObject(data) else {
            return .invalidResponse
        }
        if httpStatusCode == 410,
           object["ok"] as? Bool == false,
           object["error"] as? String == "expired",
           let message = ownerMessage(from: object) {
            return .expired(message: message)
        }
        if httpStatusCode == 401,
           object["ok"] as? Bool == false,
           object["error"] as? String == "invalid_request",
           let message = ownerMessage(from: object) {
            return .invalid(message: message)
        }
        guard httpStatusCode == 200,
              object["ok"] as? Bool == true,
              let status = object["status"] as? String else {
            return .invalidResponse
        }

        switch status {
        case "pending":
            guard let rawExpiry = object["expiresAt"] as? String,
                  let expiresAt = parseISO8601(rawExpiry),
                  expiresAt > now,
                  let intervalSeconds =
                    object["intervalSeconds"] as? Int,
                  allowedPollInterval.contains(intervalSeconds) else {
                return .invalidResponse
            }
            return .pending(
                expiresAt: expiresAt,
                intervalSeconds: intervalSeconds
            )

        case "approved":
            guard var credential =
                    object["credential"] as? [String: Any],
                  credential["ok"] as? Bool == true,
                  let licenseKey = credential["licenseKey"] as? String,
                  isValidLicenseKey(licenseKey),
                  credential["expiresAt"] is NSNumber,
                  credential["brainRoute"] is String,
                  credential["leaseKeyId"] is String,
                  credential["leasePayload"] is String,
                  credential["leaseSignature"] is String else {
                return .invalidResponse
            }
            credential.removeValue(forKey: "licenseKey")
            guard JSONSerialization.isValidJSONObject(credential),
                  let activationResponseData = try? JSONSerialization.data(
                      withJSONObject: credential
                  ) else {
                return .invalidResponse
            }
            return .approved(
                AceDeviceAuthorizationCredential(
                    licenseKey: licenseKey,
                    activationResponseData: activationResponseData
                )
            )

        default:
            return .invalidResponse
        }
    }

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        guard data.count <= 64 * 1_024 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
            as? [String: Any]
    }

    private static func ownerMessage(
        from object: [String: Any]
    ) -> String? {
        guard let raw = object["message"] as? String else { return nil }
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 1_000 else { return nil }
        return message
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return fractional.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    private static func isValidPollSecret(_ value: String) -> Bool {
        guard value.count == 43,
              value.range(
                  of: #"^[A-Za-z0-9_-]{43}$"#,
                  options: .regularExpression
              ) != nil,
              let decoded = base64URLDecode(value),
              decoded.count == 32 else {
            return false
        }
        return base64URLEncode(decoded) == value
    }

    private static func isValidUserCode(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Z0-9]{4}-[A-Z0-9]{4}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isValidLicenseKey(_ value: String) -> Bool {
        value.range(
            of: #"^ACE-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$"#,
            options: .regularExpression
        ) != nil
    }

    private static func isValidVerificationURL(
        _ url: URL,
        userCode: String
    ) -> Bool {
        guard let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              components.scheme == "https",
              components.host?.lowercased() == "ace-bl.tech",
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.path == "/link",
              components.fragment == nil,
              components.queryItems == [
                  URLQueryItem(name: "code", value: userCode)
              ] else {
            return false
        }
        return true
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        let remainder = value.count % 4
        guard remainder != 1 else { return nil }
        let padding = remainder == 0
            ? ""
            : String(repeating: "=", count: 4 - remainder)
        return Data(
            base64Encoded: value
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
                + padding
        )
    }
}
