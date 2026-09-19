#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation

nonisolated protocol PartnerProfileKeyProviding: Sendable {
    func key(
        for profileIdentifier: UUID,
        createIfMissing: Bool
    ) throws -> SymmetricKey?

    func deleteKey(for profileIdentifier: UUID) throws
}

nonisolated enum PartnerProfileKeyStoreError: Error, Equatable {
    case malformedStoredKey
    case keyCreationDidNotCommit
}

nonisolated final class PartnerCredentialFileKeyProvider:
    PartnerProfileKeyProviding,
    @unchecked Sendable
{
    private let credentialStore: any AceCredentialStoring

    init(
        credentialStore: any AceCredentialStoring =
            PromptFreeCredentialStore.shared
    ) {
        self.credentialStore = credentialStore
    }

    func key(
        for profileIdentifier: UUID,
        createIfMissing: Bool
    ) throws -> SymmetricKey? {
        let identifier = profileIdentifier.uuidString.lowercased()
        if !createIfMissing {
            let document = try credentialStore.load()
            guard let encoded =
                document.partnerProfileKeys[identifier] else {
                return nil
            }
            return try decodeKey(encoded)
        }

        var committedKeyData: Data?
        try credentialStore.update { document in
            if let encoded =
                document.partnerProfileKeys[identifier] {
                let key = try decodeKey(encoded)
                committedKeyData = key.withUnsafeBytes {
                    Data($0)
                }
                return
            }

            let generatedKey = SymmetricKey(size: .bits256)
            let keyData = generatedKey.withUnsafeBytes {
                Data($0)
            }
            document.partnerProfileKeys[identifier] =
                keyData.base64EncodedString()
            committedKeyData = keyData
        }
        guard let committedKeyData else {
            throw PartnerProfileKeyStoreError
                .keyCreationDidNotCommit
        }
        return SymmetricKey(data: committedKeyData)
    }

    func deleteKey(for profileIdentifier: UUID) throws {
        let identifier = profileIdentifier.uuidString.lowercased()
        try credentialStore.update { document in
            document.partnerProfileKeys.removeValue(
                forKey: identifier
            )
        }
    }

    private func decodeKey(_ encoded: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: encoded),
              data.count == 32 else {
            throw PartnerProfileKeyStoreError.malformedStoredKey
        }
        return SymmetricKey(data: data)
    }
}
