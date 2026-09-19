//
//  AceSignedLease.swift
//  Ace
//
//  Offline entitlement is authority from the Ace server, not a date a local
//  process can write. The server signs these exact claims with Ed25519; the app
//  pins the public key and revalidates every binding before opening runtime.
//

#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation

struct AceSignedLeaseEnvelope: Codable, Equatable, Sendable {
    let keyId: String
    let payload: String
    let signature: String
}

struct AceSignedLeaseClaims: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let keyHash: String
    let deviceId: String
    let brainRoute: String
    let issuedAt: Int64
    let expiresAt: Int64
    let nonce: String
}

enum AceSignedLeasePolicy {
    static let maximumLeaseLifetimeMilliseconds: Int64 =
        7 * 24 * 60 * 60 * 1_000
    static let maximumIssuedAtClockSkewMilliseconds: Int64 = 5 * 60 * 1_000

    /// Release engineering pins the current key and retains the immediately
    /// previous key only until its last seven-day lease expires. Private
    /// signing material remains server-side; the app ships this public
    /// authority and rejects every unknown or orphan key ID.
    /// Public-key SHA-256:
    /// f515540bd311d99ef801f08afbfc4105a49cc87ae06535a66cf47e39ae5b66b7
    static let pinnedPublicKeysByKeyID: [String: Data] = [
        "ace-ed25519-prod20260813a": Data([
            0x33, 0xF8, 0xF9, 0xDD, 0xDC, 0x95, 0xB0, 0xF4,
            0x98, 0xE9, 0xAB, 0x4D, 0x32, 0x2A, 0x9D, 0x16,
            0xFE, 0x53, 0x54, 0x92, 0x9C, 0xA1, 0x08, 0xB1,
            0x29, 0x92, 0x47, 0x75, 0xAF, 0x76, 0xC3, 0x84,
        ]),
    ]

    private static let exactClaimKeys: Set<String> = [
        "schemaVersion",
        "keyHash",
        "deviceId",
        "brainRoute",
        "issuedAt",
        "expiresAt",
        "nonce",
    ]
    private static let admittedBrainRoutes: Set<String> = [
        "customer_owned",
        "founder_hosted",
    ]

    static func keyHash(for normalizedLicenseKey: String) -> String {
        base64URLEncode(
            Data(SHA256.hash(data: Data(normalizedLicenseKey.utf8)))
        )
    }

    static func encodeClaims(_ claims: AceSignedLeaseClaims) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(claims)
    }

    static func verify(
        _ envelope: AceSignedLeaseEnvelope,
        expectedLicenseKey: String,
        expectedDeviceIdentifier: String,
        expectedBrainRoute: String? = nil,
        now: Date = Date(),
        minimumRemainingLifetime: TimeInterval = 0,
        publicKeysByKeyID: [String: Data] = pinnedPublicKeysByKeyID
    ) -> AceSignedLeaseClaims? {
        guard envelope.keyId.range(
                  of: #"^ace-ed25519-[a-z0-9]{12,32}$"#,
                  options: .regularExpression
              ) != nil,
              envelope.payload.count <= 4_096,
              envelope.signature.count <= 128,
              let payloadData = base64URLDecode(envelope.payload),
              let signatureData = base64URLDecode(envelope.signature),
              signatureData.count == 64,
              let publicKeyRaw = publicKeysByKeyID[envelope.keyId],
              publicKeyRaw.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(
                  rawRepresentation: publicKeyRaw
              ),
              publicKey.isValidSignature(
                  signatureData,
                  for: payloadData
              ),
              let object = try? JSONSerialization.jsonObject(
                  with: payloadData
              ) as? [String: Any],
              Set(object.keys) == exactClaimKeys,
              let claims = try? JSONDecoder().decode(
                  AceSignedLeaseClaims.self,
                  from: payloadData
              ) else {
            return nil
        }

        let nowMilliseconds = Int64(
            (now.timeIntervalSince1970 * 1_000).rounded(.down)
        )
        let minimumExpiry = nowMilliseconds + Int64(
            (minimumRemainingLifetime * 1_000).rounded(.up)
        )
        let lifetime = claims.expiresAt - claims.issuedAt
        guard claims.schemaVersion == 1,
              claims.keyHash == keyHash(for: expectedLicenseKey),
              claims.deviceId == expectedDeviceIdentifier,
              admittedBrainRoutes.contains(claims.brainRoute),
              expectedBrainRoute.map({ $0 == claims.brainRoute }) ?? true,
              claims.issuedAt
                <= nowMilliseconds
                    + maximumIssuedAtClockSkewMilliseconds,
              lifetime > 0,
              lifetime <= maximumLeaseLifetimeMilliseconds,
              claims.expiresAt > nowMilliseconds,
              claims.expiresAt >= minimumExpiry,
              let keyHashBytes = base64URLDecode(claims.keyHash),
              keyHashBytes.count == 32,
              let nonceBytes = base64URLDecode(claims.nonce),
              nonceBytes.count == 16 else {
            return nil
        }
        return claims
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ value: String) -> Data? {
        guard !value.isEmpty,
              !value.contains("="),
              value.unicodeScalars.allSatisfy({ scalar in
                  CharacterSet.alphanumerics.contains(scalar)
                      || scalar == "-" || scalar == "_"
              }) else {
            return nil
        }
        let remainder = value.count % 4
        guard remainder != 1 else { return nil }
        let padding = remainder == 0
            ? ""
            : String(repeating: "=", count: 4 - remainder)
        let base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            + padding
        guard let data = Data(base64Encoded: base64),
              base64URLEncode(data) == value else {
            return nil
        }
        return data
    }
}
