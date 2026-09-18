import Foundation

struct AceCommittedDeviceCredential: Equatable {
    let licenseKey: String
    let expiry: Date
    let brainRoute: AceBrainRoute
    let brainToken: String?
    let trialEndsAt: Date?
    let signedLease: AceSignedLeaseEnvelope
}

enum AceDeviceAuthorizationCredentialCommitError: Error, Equatable {
    case invalidCredential
    case persistenceFailed
}

/// Verifies the server signature for this exact Mac before atomically writing
/// the selected key, signed lease, and optional hosted credential together.
enum AceDeviceAuthorizationCredentialCommitter {
    static func commit(
        _ credential: AceDeviceAuthorizationCredential,
        expectedDeviceIdentifier: String,
        now: Date = Date(),
        publicKeysByKeyID: [String: Data] =
            AceSignedLeasePolicy.pinnedPublicKeysByKeyID,
        credentialStore: any AceCredentialStoring =
            PromptFreeCredentialStore.shared
    ) -> Result<
        AceCommittedDeviceCredential,
        AceDeviceAuthorizationCredentialCommitError
    > {
        let verdict = AceLicenseServerResponsePolicy.classify(
            httpStatusCode: 200,
            data: credential.activationResponseData,
            expectedLicenseKey: credential.licenseKey,
            expectedDeviceIdentifier: expectedDeviceIdentifier,
            now: now,
            publicKeysByKeyID: publicKeysByKeyID
        )
        guard case let .success(
                  expiry,
                  brainRoute,
                  brainToken,
                  trialEndsAt,
                  signedLease
              ) = verdict else {
            return .failure(.invalidCredential)
        }
        do {
            try credentialStore.update {
                $0.licenseToken = credential.licenseKey
                $0.signedLicenseLeaseKeyId = signedLease.keyId
                $0.signedLicenseLeasePayload = signedLease.payload
                $0.signedLicenseLeaseSignature = signedLease.signature
                $0.hostedBrainToken = brainToken
            }
        } catch {
            return .failure(.persistenceFailed)
        }
        return .success(
            AceCommittedDeviceCredential(
                licenseKey: credential.licenseKey,
                expiry: expiry,
                brainRoute: brainRoute,
                brainToken: brainToken,
                trialEndsAt: trialEndsAt,
                signedLease: signedLease
            )
        )
    }
}
