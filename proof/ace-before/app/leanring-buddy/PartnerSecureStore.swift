#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
import Foundation

nonisolated enum PartnerSecureStoreError: Error, Equatable {
    case missingKey
    case authenticationFailed
    case invalidProfile
    case unsafeStoragePath
}

nonisolated protocol PartnerProfileStoring: Sendable {
    func loadProfile(
        profileIdentifier: UUID
    ) throws -> PartnerProfile

    func saveProfile(_ profile: PartnerProfile) throws

    func exportProfile(
        profileIdentifier: UUID,
        to destinationURL: URL
    ) throws

    func resetProfile(
        profileIdentifier: UUID
    ) throws -> PartnerProfile

    func permanentlyDeleteProfile(
        profileIdentifier: UUID
    ) throws

    func removeAbandonedTemporaryMaterial() throws
}

nonisolated final class PartnerSecureStore:
    PartnerProfileStoring,
    @unchecked Sendable
{
    static func ownerFacingFailure(_ error: Error) -> String {
        if let error = error as? PromptFreeCredentialStoreError {
            return error.localizedDescription
        }
        switch error as? PartnerSecureStoreError {
        case .missingKey:
            return "Partner memory's encryption key is missing. Restore the original credential files from your backup before resetting memory. The saved profile has been preserved."
        case .authenticationFailed:
            return "Partner memory could not be decrypted. Restore the matching profile and credential files from your backup. The saved profile has been preserved."
        case .invalidProfile:
            return "The saved Partner profile could not be read. Restore a valid profile from your backup, or review Reset Partner memory to start again."
        case .unsafeStoragePath:
            return "Partner memory's storage must be private, owned by this macOS account, and free of symbolic or hard links. Restore its permissions, then try again."
        case nil:
            return "Partner memory could not be updated. Check available disk space and access to Ace's Application Support folder, then try again."
        }
    }

    private static let temporaryFilePrefix =
        ".partner-temporary-"

    private let baseDirectoryURL: URL
    private let legacyMemoryURL: URL
    private let keyProvider: any PartnerProfileKeyProviding
    private let fileManager: FileManager

    init(
        baseDirectoryURL: URL? = nil,
        legacyMemoryURL: URL? = nil,
        keyProvider: any PartnerProfileKeyProviding =
            PartnerCredentialFileKeyProvider(),
        fileManager: FileManager = .default
    ) {
        let resolvedBaseDirectoryURL: URL
        if let baseDirectoryURL {
            resolvedBaseDirectoryURL = baseDirectoryURL
        } else {
            resolvedBaseDirectoryURL = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "BlackLabel",
                isDirectory: true
            )
            .appendingPathComponent(
                "Partner",
                isDirectory: true
            )
        }
        self.baseDirectoryURL = resolvedBaseDirectoryURL
        self.legacyMemoryURL =
            legacyMemoryURL
            ?? resolvedBaseDirectoryURL
                .deletingLastPathComponent()
                .appendingPathComponent("memory.md")
        self.keyProvider = keyProvider
        self.fileManager = fileManager
    }

    func profileFileURL(
        profileIdentifier: UUID
    ) -> URL {
        profileDirectoryURL(
            profileIdentifier: profileIdentifier
        ).appendingPathComponent("profile.v1.aesgcm")
    }

    func loadProfile(
        profileIdentifier: UUID
    ) throws -> PartnerProfile {
        let profileURL = profileFileURL(
            profileIdentifier: profileIdentifier
        )
        guard fileManager.fileExists(atPath: profileURL.path) else {
            return try migrateLegacyMemoryIfPresent(
                profileIdentifier: profileIdentifier
            )
        }
        guard let profileKey = try keyProvider.key(
            for: profileIdentifier,
            createIfMissing: false
        ) else {
            throw PartnerSecureStoreError.missingKey
        }
        let encryptedData = try Data(contentsOf: profileURL)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(
                combined: encryptedData
            )
        } catch {
            throw PartnerSecureStoreError.authenticationFailed
        }
        let profileData: Data
        do {
            profileData = try AES.GCM.open(
                sealedBox,
                using: profileKey,
                authenticating: authenticationData(
                    profileIdentifier: profileIdentifier
                )
            )
        } catch {
            throw PartnerSecureStoreError.authenticationFailed
        }
        let profile: PartnerProfile
        do {
            profile = try JSONDecoder().decode(
                PartnerProfile.self,
                from: profileData
            )
        } catch {
            throw PartnerSecureStoreError.invalidProfile
        }
        guard profile.profileIdentifier == profileIdentifier,
              profile.schemaVersion == 1 else {
            throw PartnerSecureStoreError.invalidProfile
        }
        return profile
    }

    private func migrateLegacyMemoryIfPresent(
        profileIdentifier: UUID,
        timestamp: Date = Date()
    ) throws -> PartnerProfile {
        var profile = PartnerProfile.empty(
            profileIdentifier: profileIdentifier,
            timestamp: timestamp
        )
        guard fileManager.fileExists(
            atPath: legacyMemoryURL.path
        ) else {
            return profile
        }

        let legacyText = try String(
            contentsOf: legacyMemoryURL,
            encoding: .utf8
        )
        var seenContents: Set<String> = []
        let sourceSessionIdentifier = UUID()
        for rawLine in legacyText.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ).prefix(300) {
            let strippedLine = String(rawLine)
                .replacingOccurrences(
                    of: #"^\s*[-*]\s*(?:\[[^\]]+\]\s*)?"#,
                    with: "",
                    options: .regularExpression
                )
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            let content = String(strippedLine.prefix(1_200))
            let deduplicationKey = content.lowercased()
            guard !content.isEmpty,
                  seenContents.insert(deduplicationKey).inserted else {
                continue
            }
            let digest = SHA256.hash(data: Data(content.utf8))
            let stableSuffix = digest.prefix(8)
                .map { String(format: "%02x", $0) }
                .joined()
            profile.memoryRecords.append(
                PartnerMemoryRecord(
                    identifier: UUID(),
                    domain: .identityAndLifeHistory,
                    stableKey:
                        "legacy.memory.\(stableSuffix)",
                    normalizedContent: content,
                    userVisibleWording:
                        "Legacy memory: \(content)",
                    confidence: 0,
                    confirmationState: .unconfirmed,
                    linkedRecordIdentifiers: [],
                    sourceSessionIdentifier:
                        sourceSessionIdentifier,
                    sourceTurnIdentifier: UUID(),
                    firstLearnedAt: timestamp,
                    lastUpdatedAt: timestamp,
                    lastConfirmedAt: nil,
                    correctionHistory: []
                )
            )
        }
        guard !profile.memoryRecords.isEmpty else {
            return profile
        }

        profile.updatedAt = timestamp
        // Commit encrypted data before touching the recoverable plaintext
        // source. A failed save leaves memory.md exactly where it was.
        try saveProfile(profile)
        let backupURL = legacyMemoryURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "memory.migrated-partner-"
                    + "\(Int(timestamp.timeIntervalSince1970))-"
                    + "\(UUID().uuidString.lowercased()).bak"
            )
        try fileManager.moveItem(
            at: legacyMemoryURL,
            to: backupURL
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: backupURL.path
        )
        return profile
    }

    func saveProfile(_ profile: PartnerProfile) throws {
        try ensurePrivateDirectories(
            profileIdentifier: profile.profileIdentifier
        )
        guard let profileKey = try keyProvider.key(
            for: profile.profileIdentifier,
            createIfMissing: true
        ) else {
            throw PartnerSecureStoreError.missingKey
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let profileData = try encoder.encode(profile)
        let sealedBox = try AES.GCM.seal(
            profileData,
            using: profileKey,
            authenticating: authenticationData(
                profileIdentifier: profile.profileIdentifier
            )
        )
        guard let encryptedData = sealedBox.combined else {
            throw PartnerSecureStoreError.authenticationFailed
        }
        let profileURL = profileFileURL(
            profileIdentifier: profile.profileIdentifier
        )
        try encryptedData.write(
            to: profileURL,
            options: .atomic
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: profileURL.path
        )
    }

    func exportProfile(
        profileIdentifier: UUID,
        to destinationURL: URL
    ) throws {
        let profile = try loadProfile(
            profileIdentifier: profileIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let exportData = try encoder.encode(profile)
        try exportData.write(
            to: destinationURL,
            options: .atomic
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destinationURL.path
        )
    }

    func resetProfile(
        profileIdentifier: UUID
    ) throws -> PartnerProfile {
        let emptyProfile = PartnerProfile.empty(
            profileIdentifier: profileIdentifier
        )
        try saveProfile(emptyProfile)
        return emptyProfile
    }

    func permanentlyDeleteProfile(
        profileIdentifier: UUID
    ) throws {
        let profileURL = profileFileURL(
            profileIdentifier: profileIdentifier
        )
        if fileManager.fileExists(atPath: profileURL.path) {
            try fileManager.removeItem(at: profileURL)
        }
        let profileDirectory = profileDirectoryURL(
            profileIdentifier: profileIdentifier
        )
        if fileManager.fileExists(
            atPath: profileDirectory.path
        ) {
            let remainingItems = try fileManager.contentsOfDirectory(
                atPath: profileDirectory.path
            )
            if remainingItems.isEmpty {
                try fileManager.removeItem(at: profileDirectory)
            }
        }
        try keyProvider.deleteKey(for: profileIdentifier)
    }

    func removeAbandonedTemporaryMaterial() throws {
        guard fileManager.fileExists(
            atPath: baseDirectoryURL.path
        ) else {
            return
        }
        let resourceKeys: [URLResourceKey] = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: baseDirectoryURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        for case let itemURL as URL in enumerator {
            guard itemURL.lastPathComponent.hasPrefix(
                Self.temporaryFilePrefix
            ) else {
                continue
            }
            let values = try itemURL.resourceValues(
                forKeys: Set(resourceKeys)
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            try fileManager.removeItem(at: itemURL)
        }

        // Hidden files are intentionally skipped by the safe recursive
        // enumerator, so inspect the private root directly for our exact
        // hidden temporary prefix.
        for itemName in try fileManager.contentsOfDirectory(
            atPath: baseDirectoryURL.path
        ) where itemName.hasPrefix(Self.temporaryFilePrefix) {
            let itemURL = baseDirectoryURL
                .appendingPathComponent(itemName)
            let values = try itemURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isRegularFile == true,
               values.isSymbolicLink != true {
                try fileManager.removeItem(at: itemURL)
            }
        }
    }

    private func ensurePrivateDirectories(
        profileIdentifier: UUID
    ) throws {
        do {
            try PrivateSupportDirectory.ensure(
                at: baseDirectoryURL,
                fileManager: fileManager
            )
            try PrivateSupportDirectory.ensure(
                at: profilesDirectoryURL,
                fileManager: fileManager
            )
            try PrivateSupportDirectory.ensure(
                at: profileDirectoryURL(
                    profileIdentifier: profileIdentifier
                ),
                fileManager: fileManager
            )
        } catch {
            throw PartnerSecureStoreError.unsafeStoragePath
        }
    }

    private var profilesDirectoryURL: URL {
        baseDirectoryURL.appendingPathComponent(
            "profiles",
            isDirectory: true
        )
    }

    private func profileDirectoryURL(
        profileIdentifier: UUID
    ) -> URL {
        profilesDirectoryURL.appendingPathComponent(
            profileIdentifier.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func authenticationData(
        profileIdentifier: UUID
    ) -> Data {
        Data(
            "AcePartnerProfile:v1:\(profileIdentifier.uuidString.lowercased())"
                .utf8
        )
    }
}
