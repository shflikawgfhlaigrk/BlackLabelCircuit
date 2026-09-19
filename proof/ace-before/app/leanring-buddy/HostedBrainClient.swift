//
//  HostedBrainClient.swift
//  Ace's blank-Mac model transport.
//
//  The shipped app carries only a revocable, per-device access token issued by
//  Ace activation. The gateway queues work for Black Label's outbound-only HQ
//  Codex CLI relay; no OpenAI API key or founder login leaves HQ. This client
//  exposes no model tool loop: model text and planner JSON stay untrusted until
//  the existing native validators and confirmation broker act.
//

#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct HostedBrainCredentials: Sendable, Equatable {
    let licenseKey: String
    let deviceIdentifier: String
    let accessToken: String

    nonisolated var proofIdentity: String {
        let bytes = Data("\(licenseKey)\n\(deviceIdentifier)".utf8)
        return SHA256.hash(data: bytes).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum HostedBrainRequestKind: String, Sendable {
    case answer
    case planner
    case background
    case meetingSummary = "meeting_summary"
    case workflowPlanner = "workflow_planner"
    case probe
}

struct HostedBrainImage: Sendable {
    let data: Data
    let label: String

    nonisolated var mimeType: String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47])
            ? "image/png"
            : "image/jpeg"
    }
}

enum HostedBrainError: LocalizedError, Equatable {
    case notActivated
    case invalidResponse
    case service(message: String)

    var errorDescription: String? {
        switch self {
        case .notActivated:
            return "Activate Ace again to connect its CLI brain."
        case .invalidResponse:
            return "Ace's CLI brain returned an invalid response."
        case .service(let message):
            return message
        }
    }
}

struct HostedBrainQueuedJob: Equatable {
    let jobIdentifier: String
    let expiresAt: Date
    let pollAfterMilliseconds: Int
}

enum HostedBrainQueueResponsePolicy {
    static func decodeEnqueue(
        statusCode: Int,
        data: Data,
        now: Date = Date()
    ) -> Result<HostedBrainQueuedJob, HostedBrainError> {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return .failure(.invalidResponse)
        }
        guard statusCode == 202,
              object["ok"] as? Bool == true,
              object["status"] as? String == "queued",
              let jobIdentifier = object["jobId"] as? String,
              jobIdentifier.count == 32,
              jobIdentifier.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef")
                    .contains($0)
              }),
              let expiresAtNumber = object["expiresAt"] as? NSNumber else {
            return failure(from: object)
        }
        let expiry = Date(
            timeIntervalSince1970:
                expiresAtNumber.doubleValue / 1_000
        )
        guard expiry.timeIntervalSince(now) >= 30,
              expiry.timeIntervalSince(now) <= 15 * 60 else {
            return .failure(.invalidResponse)
        }
        let rawPollAfter = (object["pollAfterMs"] as? NSNumber)?.intValue
            ?? 1_000
        let pollAfterMilliseconds = min(max(rawPollAfter, 250), 5_000)
        return .success(
            HostedBrainQueuedJob(
                jobIdentifier: jobIdentifier,
                expiresAt: expiry,
                pollAfterMilliseconds: pollAfterMilliseconds
            )
        )
    }

    static func decodePoll(
        statusCode: Int,
        data: Data
    ) -> Result<String?, HostedBrainError> {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return .failure(.invalidResponse)
        }
        if statusCode == 202,
           object["ok"] as? Bool == true,
           let status = object["status"] as? String,
           status == "pending" || status == "leased" {
            return .success(nil)
        }
        return HostedBrainResponsePolicy.decode(
            statusCode: statusCode,
            data: data
        ).map(Optional.some)
    }

    private static func failure(
        from object: [String: Any]
    ) -> Result<HostedBrainQueuedJob, HostedBrainError> {
        let message = String(
            String(object["message"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(500)
        )
        return message.isEmpty
            ? .failure(.invalidResponse)
            : .failure(.service(message: message))
    }
}

nonisolated enum HostedBrainResponsePolicy {
    static func decode(
        statusCode: Int,
        data: Data
    ) -> Result<String, HostedBrainError> {
        guard let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any] else {
            return .failure(.invalidResponse)
        }
        if statusCode == 200,
           object["ok"] as? Bool == true,
           let rawText = object["text"] as? String {
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty
                ? .failure(.invalidResponse)
                : .success(text)
        }
        let rawMessage = object["message"] as? String ?? ""
        let message = rawMessage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(500)
        guard !message.isEmpty else {
            return .failure(.invalidResponse)
        }
        return .failure(.service(message: String(message)))
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
nonisolated enum HostedBrainClient {
    private static let endpoint = URL(
        string: "https://blacklabelbots.com/api/ace/brain"
    )!
    private static let resultEndpoint = URL(
        string: "https://blacklabelbots.com/api/ace/brain/result"
    )!
    private static let maximumImages = 4
    private static let maximumImageBytes = 3 * 1_024 * 1_024
    private static let maximumWait: TimeInterval = 145

    static func complete(
        kind: HostedBrainRequestKind,
        prompt: String,
        images: [HostedBrainImage] = [],
        expectedCredentials: HostedBrainCredentials? = nil,
        isCurrent: @Sendable () -> Bool = { true }
    ) async throws -> String {
        let credentials = await MainActor.run {
            AceLicense.shared.hostedBrainCredentials
        }
        guard let credentials else {
            throw HostedBrainError.notActivated
        }
        guard isCurrent(), !Task.isCancelled,
              expectedCredentials == nil || expectedCredentials == credentials else {
            throw CancellationError()
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              images.count <= maximumImages,
              images.allSatisfy({ !$0.data.isEmpty && $0.data.count <= maximumImageBytes }) else {
            throw HostedBrainError.invalidResponse
        }

        let startedAt = Date()
        do {
            return try await performCompletion(
                kind: kind, prompt: prompt, images: images,
                credentials: credentials
            )
        } catch {
            if !(error is CancellationError),
               (error as? URLError)?.code != .cancelled,
               !Task.isCancelled, isCurrent() {
                await MainActor.run {
                    guard !Task.isCancelled, isCurrent(),
                          !StealthEntryLatch.shared.isRaised,
                          AceBrainRoute.current == .founderHosted,
                          AceLicense.shared.hostedBrainCredentials == credentials else { return }
                    HostedBrainConnectionProof.recordRuntimeFailure(
                        credentials: credentials, startedAt: startedAt,
                        cause: AceReasoningRecoveryPolicy.failureCause(
                            errorTypeName: String(describing: type(of: error)),
                            errorDescription: error.localizedDescription
                        )
                    )
                }
            }
            throw error
        }
    }

    private static func performCompletion(
        kind: HostedBrainRequestKind, prompt: String,
        images: [HostedBrainImage], credentials: HostedBrainCredentials
    ) async throws -> String {
        try Task.checkCancellation()

        let encodedImages: [[String: String]] = images.map {
            [
                "mimeType": $0.mimeType,
                "label": String($0.label.prefix(80)),
                "data": $0.data.base64EncodedString(),
            ]
        }
        let body: [String: Any] = [
            "key": credentials.licenseKey,
            "deviceId": credentials.deviceIdentifier,
            "kind": kind.rawValue,
            "prompt": prompt,
            "images": encodedImages,
        ]
        guard JSONSerialization.isValidJSONObject(body) else {
            throw HostedBrainError.invalidResponse
        }

        let request = try makeRequest(
            endpoint: endpoint,
            credentials: credentials,
            body: body,
            timeout: 30
        )
        let (enqueueData, enqueueResponse) =
            try await StealthURLSessionRequest().perform(request)
        guard let enqueueHTTPResponse = enqueueResponse
                as? HTTPURLResponse else {
            throw HostedBrainError.invalidResponse
        }
        let queuedJob = try HostedBrainQueueResponsePolicy.decodeEnqueue(
            statusCode: enqueueHTTPResponse.statusCode,
            data: enqueueData
        ).get()
        let deadline = min(
            queuedJob.expiresAt,
            Date().addingTimeInterval(maximumWait)
        )
        var pollAfterMilliseconds = queuedJob.pollAfterMilliseconds

        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(
                nanoseconds:
                    UInt64(pollAfterMilliseconds) * 1_000_000
            )
            let pollRequest = try makeRequest(
                endpoint: resultEndpoint,
                credentials: credentials,
                body: [
                    "key": credentials.licenseKey,
                    "deviceId": credentials.deviceIdentifier,
                    "jobId": queuedJob.jobIdentifier,
                ],
                timeout: 20
            )
            let (pollData, pollResponse) =
                try await StealthURLSessionRequest().perform(
                    pollRequest
                )
            guard let pollHTTPResponse = pollResponse
                    as? HTTPURLResponse else {
                throw HostedBrainError.invalidResponse
            }
            if let answer = try HostedBrainQueueResponsePolicy.decodePoll(
                statusCode: pollHTTPResponse.statusCode,
                data: pollData
            ).get() {
                return answer
            }
            pollAfterMilliseconds = min(
                pollAfterMilliseconds + 250,
                2_000
            )
        }
        throw HostedBrainError.service(
            message: "Ace's CLI brain did not answer in time. Try again."
        )
    }

    private static func makeRequest(
        endpoint: URL,
        credentials: HostedBrainCredentials,
        body: [String: Any],
        timeout: TimeInterval
    ) throws -> URLRequest {
        guard JSONSerialization.isValidJSONObject(body) else {
            throw HostedBrainError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(
            "application/json",
            forHTTPHeaderField: "content-type"
        )
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "authorization"
        )
        request.setValue(
            "1",
            forHTTPHeaderField: "x-ace-queue-client"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body
        )
        return request
    }
}
#endif // circuit-convert

private struct HostedBrainProofReceipt: Codable, Equatable {
    let schemaVersion: Int
    let proofIdentity: String
    let answeredAt: Date
}

struct HostedBrainRuntimeFailure: Codable, Equatable {
    let proofIdentity: String
    let startedAt: Date
    let cause: String
}

enum HostedBrainConnectionProof {
    private static let defaultsKey = "HostedBrainConnectionProof.v1"
    private static let failureKey = "HostedBrainRuntimeFailure.v1"
    private static let lifetime: TimeInterval = 24 * 60 * 60

    static func hasAnsweredRealProbe(
        credentials: HostedBrainCredentials?,
        now: Date = Date()
    ) -> Bool {
        guard let credentials,
              let encoded = UserDefaults.standard.data(forKey: defaultsKey),
              let receipt = try? JSONDecoder().decode(
                HostedBrainProofReceipt.self,
                from: encoded
              ),
              receipt.schemaVersion == 1,
              receipt.proofIdentity == credentials.proofIdentity else {
            invalidate()
            return false
        }
        let age = now.timeIntervalSince(receipt.answeredAt)
        guard age >= 0, age <= lifetime else {
            invalidate()
            return false
        }
        if let failure = runtimeFailure(credentials: credentials),
           failure.startedAt >= receipt.answeredAt { return false }
        return true
    }

    @discardableResult
    static func recordSuccessfulProbe(
        credentials: HostedBrainCredentials,
        answeredAt: Date = Date()
    ) -> Bool {
        let receipt = HostedBrainProofReceipt(
            schemaVersion: 1,
            proofIdentity: credentials.proofIdentity,
            answeredAt: answeredAt
        )
        guard let encoded = try? JSONEncoder().encode(receipt) else {
            invalidate()
            return false
        }
        return StealthEntryLatch.shared.performUnlessRaised {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
            return true
        } == true
    }

    static func invalidate() {
        if UserDefaults.standard.object(forKey: defaultsKey) != nil {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        }
    }

    static func runtimeFailure(
        credentials: HostedBrainCredentials?
    ) -> HostedBrainRuntimeFailure? {
        guard let credentials,
              let data = UserDefaults.standard.data(forKey: failureKey),
              let failure = try? JSONDecoder().decode(HostedBrainRuntimeFailure.self, from: data),
              failure.proofIdentity == credentials.proofIdentity else { return nil }
        return failure
    }

    static func recordRuntimeFailure(
        credentials: HostedBrainCredentials, startedAt: Date, cause: String
    ) {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let receipt = try? JSONDecoder().decode(HostedBrainProofReceipt.self, from: data),
           receipt.proofIdentity == credentials.proofIdentity,
           receipt.answeredAt > startedAt { return }
        if let newer = runtimeFailure(credentials: credentials),
           newer.startedAt > startedAt { return }
        let failure = HostedBrainRuntimeFailure(
            proofIdentity: credentials.proofIdentity,
            startedAt: startedAt, cause: cause
        )
        guard let encoded = try? JSONEncoder().encode(failure) else { return }
        UserDefaults.standard.set(encoded, forKey: failureKey)
        NotificationCenter.default.post(name: .aceProviderInvocationReceiptDidChange, object: nil)
    }
}
