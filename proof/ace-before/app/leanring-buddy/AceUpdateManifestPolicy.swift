import Foundation

struct AceInstalledReleaseIdentitySnapshot: Equatable, Sendable {
    let version: String?
    let build: String?
    let sourceSha256: String?
    let includesQwen: Bool?
    let includesBackgroundHelper: Bool?
}

enum AceInstalledIdentityField: String, Error, Equatable {
    case version
    case build
    case sourceSha256 = "source_sha256"
    case includesQwen = "includes_qwen"
    case includesBackgroundHelper = "includes_background_helper"
}

struct AceValidatedPublicRelease: Equatable, Sendable {
    let version: String
    let build: Int
    let sourceSha256: String
    let dmgSha256: String
    let dmgBytes: Int
    let appCdhashArm64: String
    let appCdhashX86_64: String
    let includesQwen: Bool
    let includesBackgroundHelper: Bool

    var skippedIdentity: String {
        "\(build):\(sourceSha256):\(dmgSha256)"
    }
}

enum AceUpdateEvaluation: Equatable {
    case installedIdentityInvalid(AceInstalledIdentityField)
    case manifestUnavailable
    case current
    case update(AceValidatedPublicRelease)
}

enum AceUpdateManifestPolicy {
    private struct InstalledIdentity {
        let version: String
        let build: Int
        let sourceSha256: String
        let includesQwen: Bool
        let includesBackgroundHelper: Bool
    }

    private struct WireManifest: Decodable {
        let ok: Bool
        let product: String
        let version: String
        let build: Int
        let sourceSha256: String
        let dmgSha256: String
        let dmgBytes: Int
        let appCdhashArm64: String
        let appCdhashX86_64: String
        let includesQwen: Bool
        let includesBackgroundHelper: Bool
        let variants: [WireVariant]?
    }

    private struct WireVariant: Decodable {
        let name: String
        let sourceSha256: String
        let dmgSha256: String
        let dmgBytes: Int
        let appCdhashArm64: String
        let appCdhashX86_64: String
        let includesQwen: Bool
        let includesBackgroundHelper: Bool
    }

    static func installedIdentityFailure(
        _ snapshot: AceInstalledReleaseIdentitySnapshot
    ) -> AceInstalledIdentityField? {
        switch validateInstalled(snapshot) {
        case .success:
            return nil
        case let .failure(field):
            return field
        }
    }

    static func evaluate(
        installed snapshot: AceInstalledReleaseIdentitySnapshot,
        manifestData: Data?
    ) -> AceUpdateEvaluation {
        let installed: InstalledIdentity
        switch validateInstalled(snapshot) {
        case let .success(identity):
            installed = identity
        case let .failure(field):
            return .installedIdentityInvalid(field)
        }

        guard let manifestData,
              let remote = validateManifest(
                  manifestData,
                  installed: installed
              ) else {
            return .manifestUnavailable
        }

        if remote.build < installed.build {
            return .current
        }
        if remote.build > installed.build {
            return .update(remote)
        }

        let exactInstalledIdentity =
            remote.version == installed.version
            && remote.sourceSha256 == installed.sourceSha256
            && remote.includesQwen == installed.includesQwen
            && remote.includesBackgroundHelper
                == installed.includesBackgroundHelper
        return exactInstalledIdentity ? .current : .update(remote)
    }

    static func validatedPublicRelease(
        installed snapshot: AceInstalledReleaseIdentitySnapshot,
        manifestData: Data
    ) -> AceValidatedPublicRelease? {
        guard case let .success(installed) = validateInstalled(snapshot)
        else { return nil }
        return validateManifest(manifestData, installed: installed)
    }

    private static func validateInstalled(
        _ snapshot: AceInstalledReleaseIdentitySnapshot
    ) -> Result<InstalledIdentity, AceInstalledIdentityField> {
        guard let version = snapshot.version,
              isCanonicalVersion(version) else {
            return .failure(.version)
        }
        guard let rawBuild = snapshot.build,
              let build = Int(rawBuild),
              build > 0,
              String(build) == rawBuild else {
            return .failure(.build)
        }
        guard let sourceSha256 = snapshot.sourceSha256,
              isLowercaseHex(sourceSha256, count: 64) else {
            return .failure(.sourceSha256)
        }
        guard let includesQwen = snapshot.includesQwen else {
            return .failure(.includesQwen)
        }
        guard let includesBackgroundHelper =
                snapshot.includesBackgroundHelper else {
            return .failure(.includesBackgroundHelper)
        }
        return .success(
            InstalledIdentity(
                version: version,
                build: build,
                sourceSha256: sourceSha256,
                includesQwen: includesQwen,
                includesBackgroundHelper: includesBackgroundHelper
            )
        )
    }

    private static func validateManifest(
        _ data: Data,
        installed: InstalledIdentity
    ) -> AceValidatedPublicRelease? {
        guard let wire = try? JSONDecoder().decode(
            WireManifest.self,
            from: data
        ),
        wire.ok,
        wire.product == "ace",
        isCanonicalVersion(wire.version),
        wire.build > 0,
        isLowercaseHex(wire.sourceSha256, count: 64),
        isLowercaseHex(wire.dmgSha256, count: 64),
        wire.dmgBytes > 0,
        isLowercaseHex(wire.appCdhashArm64, count: 40),
        wire.appCdhashX86_64.isEmpty
            || isLowercaseHex(wire.appCdhashX86_64, count: 40)
        else {
            return nil
        }

        guard let fullRelease = validatedRelease(
            version: wire.version,
            build: wire.build,
            sourceSha256: wire.sourceSha256,
            dmgSha256: wire.dmgSha256,
            dmgBytes: wire.dmgBytes,
            appCdhashArm64: wire.appCdhashArm64,
            appCdhashX86_64: wire.appCdhashX86_64,
            includesQwen: wire.includesQwen,
            includesBackgroundHelper: wire.includesBackgroundHelper
        ) else { return nil }

        guard let variants = wire.variants else {
            return fullRelease.includesQwen == installed.includesQwen
                && fullRelease.includesBackgroundHelper
                    == installed.includesBackgroundHelper
                ? fullRelease : nil
        }
        guard variants.count == 2,
              Set(variants.map(\.name)) == Set(["full", "slim"])
        else { return nil }

        let releases: [AceValidatedPublicRelease] = variants.compactMap {
            variant -> AceValidatedPublicRelease? in
            guard (variant.name == "full" && variant.includesQwen)
                    || (variant.name == "slim" && !variant.includesQwen)
            else { return nil }
            return validatedRelease(
                version: wire.version,
                build: wire.build,
                sourceSha256: variant.sourceSha256,
                dmgSha256: variant.dmgSha256,
                dmgBytes: variant.dmgBytes,
                appCdhashArm64: variant.appCdhashArm64,
                appCdhashX86_64: variant.appCdhashX86_64,
                includesQwen: variant.includesQwen,
                includesBackgroundHelper:
                    variant.includesBackgroundHelper
            )
        }
        guard releases.count == variants.count,
              releases.first(where: { $0.includesQwen }) == fullRelease
        else { return nil }
        let matchingReleases = releases.filter {
            $0.includesQwen == installed.includesQwen
                && $0.includesBackgroundHelper
                    == installed.includesBackgroundHelper
        }
        guard matchingReleases.count == 1 else { return nil }
        return matchingReleases[0]
    }

    private static func validatedRelease(
        version: String,
        build: Int,
        sourceSha256: String,
        dmgSha256: String,
        dmgBytes: Int,
        appCdhashArm64: String,
        appCdhashX86_64: String,
        includesQwen: Bool,
        includesBackgroundHelper: Bool
    ) -> AceValidatedPublicRelease? {
        guard isCanonicalVersion(version),
              build > 0,
              isLowercaseHex(sourceSha256, count: 64),
              isLowercaseHex(dmgSha256, count: 64),
              dmgBytes > 0,
              isLowercaseHex(appCdhashArm64, count: 40),
              appCdhashX86_64.isEmpty
                || isLowercaseHex(appCdhashX86_64, count: 40)
        else { return nil }
        return AceValidatedPublicRelease(
            version: version,
            build: build,
            sourceSha256: sourceSha256,
            dmgSha256: dmgSha256,
            dmgBytes: dmgBytes,
            appCdhashArm64: appCdhashArm64,
            appCdhashX86_64: appCdhashX86_64,
            includesQwen: includesQwen,
            includesBackgroundHelper: includesBackgroundHelper
        )
    }

    private static func isCanonicalVersion(_ value: String) -> Bool {
        guard value.count <= 80 else { return false }
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2 ... 4).contains(components.count) else { return false }
        return components.allSatisfy { component in
            !component.isEmpty
                && component.utf8.allSatisfy { byte in
                    byte >= 48 && byte <= 57
                }
        }
    }

    private static func isLowercaseHex(
        _ value: String,
        count: Int
    ) -> Bool {
        guard value.utf8.count == count else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}
