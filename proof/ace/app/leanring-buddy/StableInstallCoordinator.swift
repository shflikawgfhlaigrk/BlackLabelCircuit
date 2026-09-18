import Foundation

enum StableInstallLocation: Equatable, Sendable {
    case systemApplications
}

enum StableInstallRejection: Equatable, Sendable {
    case appTranslocated
    case diskImage
    case downloads
    case symlink
    case readOnlyVolume
    case unsupportedLocation
}

struct StableInstallAssessment: Equatable, Sendable {
    let acceptedLocation: StableInstallLocation?
    let rejection: StableInstallRejection?
    let canonicalRepairURL: URL

    var isAccepted: Bool {
        acceptedLocation != nil && rejection == nil
    }
}

struct StableInstallSnapshot: Equatable, Sendable {
    let launchBundleURL: URL
    let resolvedBundleURL: URL
    let homeDirectoryURL: URL
    let isSymbolicLink: Bool
    let isVolumeReadOnly: Bool
}

enum StableInstallCoordinator {
    static let systemApplicationsURL = URL(
        fileURLWithPath: "/Applications/Ace.app",
        isDirectory: true
    )
    static let repairInstruction =
        "Click Show Ace in Finder. Drag Ace into Applications, quit this installer, then open Ace from Applications."
    static let repairActionTitle = "Show Ace in Finder"

    static func finderDirectory(
        for bundleURL: URL,
        homeDirectory: URL
    ) -> URL {
        let path = bundleURL.standardizedFileURL.path.lowercased()
        if path.contains("/apptranslocation/") || path.contains("/.apptranslocation/") {
            // The randomized protected copy is not the owner's downloadable
            // app. Finder must lead back to the original installer instead.
            return homeDirectory.appendingPathComponent("Downloads", isDirectory: true)
        }
        return bundleURL.deletingLastPathComponent()
    }

    static func assess(
        _ snapshot: StableInstallSnapshot
    ) -> StableInstallAssessment {
        let repairURL = systemApplicationsURL
        let launchURL = snapshot.launchBundleURL.standardizedFileURL
        let resolvedURL = snapshot.resolvedBundleURL.standardizedFileURL
        let launchPath = launchURL.path
        let resolvedPath = resolvedURL.path
        let lowercasedLaunchPath = launchPath.lowercased()
        let lowercasedResolvedPath = resolvedPath.lowercased()

        func rejected(
            _ reason: StableInstallRejection
        ) -> StableInstallAssessment {
            StableInstallAssessment(
                acceptedLocation: nil,
                rejection: reason,
                canonicalRepairURL: repairURL
            )
        }

        if lowercasedLaunchPath.contains("/apptranslocation/")
            || lowercasedLaunchPath.contains("/.apptranslocation/")
            || lowercasedResolvedPath.contains("/apptranslocation/")
            || lowercasedResolvedPath.contains("/.apptranslocation/") {
            return rejected(.appTranslocated)
        }
        if launchPath == "/Volumes"
            || launchPath.hasPrefix("/Volumes/")
            || resolvedPath == "/Volumes"
            || resolvedPath.hasPrefix("/Volumes/") {
            return rejected(.diskImage)
        }

        let downloadsURL = snapshot.homeDirectoryURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .standardizedFileURL
        if launchPath == downloadsURL.path
            || launchPath.hasPrefix(downloadsURL.path + "/")
            || resolvedPath == downloadsURL.path
            || resolvedPath.hasPrefix(downloadsURL.path + "/") {
            return rejected(.downloads)
        }
        if snapshot.isSymbolicLink {
            return rejected(.symlink)
        }
        if snapshot.isVolumeReadOnly {
            return rejected(.readOnlyVolume)
        }

        let systemPath = systemApplicationsURL.standardizedFileURL.path
        if launchPath == systemPath, resolvedPath == systemPath {
            return StableInstallAssessment(
                acceptedLocation: .systemApplications,
                rejection: nil,
                canonicalRepairURL: repairURL
            )
        }
        return rejected(.unsupportedLocation)
    }

    static func liveAssessment(
        bundleURL: URL = Bundle.main.bundleURL,
        homeDirectoryURL: URL =
            FileManager.default.homeDirectoryForCurrentUser
    ) -> StableInstallAssessment {
        let standardizedBundleURL = bundleURL.standardizedFileURL
        let resolvedBundleURL =
            standardizedBundleURL.resolvingSymlinksInPath()
        let values = try? standardizedBundleURL.resourceValues(
            forKeys: [
                .isSymbolicLinkKey,
                .volumeIsReadOnlyKey
            ]
        )
        let pathResolutionChanged =
            resolvedBundleURL.path != standardizedBundleURL.path
        return assess(
            StableInstallSnapshot(
                launchBundleURL: standardizedBundleURL,
                resolvedBundleURL: resolvedBundleURL,
                homeDirectoryURL: homeDirectoryURL,
                isSymbolicLink:
                    values?.isSymbolicLink == true
                        || pathResolutionChanged,
                isVolumeReadOnly: values?.volumeIsReadOnly == true
            )
        )
    }
}
