#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CircuitPortKit

nonisolated struct AceDetectedInstallation:
    Equatable,
    Identifiable,
    Sendable
{
    let id: String
    let path: String
    let version: String
    let build: String
    let sourceSHA256: String?
    let includesQwen: Bool?
    let includesBackgroundHelper: Bool?
    let isAuthoritative: Bool
    let isMountedInstallerCopy: Bool

    var releaseIdentitySnapshot: AceInstalledReleaseIdentitySnapshot {
        AceInstalledReleaseIdentitySnapshot(
            version: version == "unknown" ? nil : version,
            build: build == "unknown" ? nil : build,
            sourceSha256: sourceSHA256,
            includesQwen: includesQwen,
            includesBackgroundHelper: includesBackgroundHelper
        )
    }
}

nonisolated enum AceInstallationInventory {
    static let authoritativePath = "/Applications/Ace.app"

    private static let duplicateNamePattern =
        #"^ace(?: copy(?: [0-9]+)?| \([0-9]+\)| [0-9]+|[-_](?:copy|old|backup|[0-9][a-z0-9._-]*))?\.app$"#

    private struct FileIdentity: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private static func fileIdentity(
        atPath path: String,
        fileManager: FileManager
    ) -> FileIdentity? {
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: path
        ),
        let device = attributes[.systemNumber] as? NSNumber,
        let inode = attributes[.systemFileNumber] as? NSNumber else {
            return nil
        }
        return FileIdentity(
            device: device.uint64Value,
            inode: inode.uint64Value
        )
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func isPotentialAceApplicationName(_ name: String) -> Bool {
        name.range(
            of: duplicateNamePattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func applicationInfo(atPath path: String) -> [String: Any]? {
        let infoURL = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ),
              let info = propertyList as? [String: Any] else {
            return nil
        }
        return info
    }

    static func scan(
        homeDirectory: URL = FileManager.default
            .homeDirectoryForCurrentUser,
        mountedVolumesRoot: URL = URL(fileURLWithPath: "/Volumes"),
        systemApplicationsRoot: URL = URL(
            fileURLWithPath: "/Applications"
        ),
        authoritativePath: String = authoritativePath
    ) -> [AceDetectedInstallation] {
        let fileManager = FileManager.default
        var candidates: Set<String> = [authoritativePath]
        let userApplications = homeDirectory
            .appendingPathComponent("Applications", isDirectory: true)
        for root in [systemApplicationsRoot, userApplications] {
            for name in (try? fileManager.contentsOfDirectory(
                atPath: root.path
            )) ?? [] where isPotentialAceApplicationName(name) {
                candidates.insert(root.appendingPathComponent(name).path)
            }
        }
        for volumeName in (try? fileManager.contentsOfDirectory(
            atPath: mountedVolumesRoot.path
        )) ?? [] {
            let volume = mountedVolumesRoot
                .appendingPathComponent(volumeName, isDirectory: true)
            for appName in ["Ace.app", "Applications/Ace.app"] {
                candidates.insert(
                    volume.appendingPathComponent(appName).path
                )
            }
        }
        let authoritativeCanonicalPath = canonicalPath(authoritativePath)
        let orderedCandidates = candidates.sorted { lhs, rhs in
            if lhs == authoritativePath { return true }
            if rhs == authoritativePath { return false }
            return lhs < rhs
        }
        var seenCanonicalPaths = Set<String>()
        var seenFileIdentities = Set<FileIdentity>()
        return orderedCandidates.compactMap { path in
            guard fileManager.fileExists(atPath: path),
                  let info = applicationInfo(atPath: path),
                  info["CFBundleIdentifier"] as? String
                    == "com.blacklabel.assistant"
                    || URL(fileURLWithPath: path).lastPathComponent
                        .lowercased() == "ace.app" else {
                return nil
            }
            let resolvedPath = canonicalPath(path)
            let identity = fileIdentity(
                atPath: path,
                fileManager: fileManager
            )
            guard !seenCanonicalPaths.contains(resolvedPath),
                  identity.map({ !seenFileIdentities.contains($0) })
                    ?? true else {
                return nil
            }
            seenCanonicalPaths.insert(resolvedPath)
            if let identity {
                seenFileIdentities.insert(identity)
            }
            return AceDetectedInstallation(
                id: path,
                path: path,
                version: info["CFBundleShortVersionString"] as? String
                    ?? "unknown",
                build: info["CFBundleVersion"] as? String ?? "unknown",
                sourceSHA256: info["BLAppSourceSHA256"] as? String,
                includesQwen: info["BLIncludesQwen"] as? Bool,
                includesBackgroundHelper:
                    info["BLIncludesBackgroundHelper"] as? Bool,
                isAuthoritative:
                    resolvedPath == authoritativeCanonicalPath,
                isMountedInstallerCopy:
                    path.hasPrefix(mountedVolumesRoot.path + "/")
            )
        }.sorted {
            if $0.isAuthoritative != $1.isAuthoritative {
                return $0.isAuthoritative
            }
            return $0.path < $1.path
        }
    }
}

/// Capture before the visible app starts; a Finder replacement later must not
/// relabel the already-running process with the new files' version or source.
nonisolated struct AceRunningReleaseSnapshot: Sendable {
    static let atLaunch = capture()
    let path: String
    let processID: Int32
    let identity: AceInstalledReleaseIdentitySnapshot

    static func capture() -> Self {
        let info = Bundle.main.infoDictionary ?? [:]
        return Self(path: Bundle.main.bundlePath, processID: ProcessInfo.processInfo.processIdentifier,
                    identity: AceInstalledReleaseIdentitySnapshot(
                        version: info["CFBundleShortVersionString"] as? String,
                        build: info["CFBundleVersion"] as? String,
                        sourceSha256: info["BLAppSourceSHA256"] as? String,
                        includesQwen: info["BLIncludesQwen"] as? Bool,
                        includesBackgroundHelper: info["BLIncludesBackgroundHelper"] as? Bool))
    }
}

@MainActor
final class AceBuyerRecoveryModel: ObservableObject {
    @Published private(set) var installations: [AceDetectedInstallation] = []
    @Published private(set) var publicReleaseLine = "Public release not checked"
    @Published private(set) var publicCheckFailed = false
    @Published private(set) var isChecking = false
    @Published private(set) var hasScanned = false

    let running: AceRunningReleaseSnapshot
    private let scan: @Sendable () async -> [AceDetectedInstallation]
    private let fetch: @Sendable () async throws -> (Data, URLResponse)

    init(running: AceRunningReleaseSnapshot = .atLaunch,
         scan: @escaping @Sendable () async -> [AceDetectedInstallation] = {
             await Task.detached(priority: .utility) { AceInstallationInventory.scan() }.value
         },
         fetch: @escaping @Sendable () async throws -> (Data, URLResponse) = {
             var request = URLRequest(url: URL(string: "https://ace-bl.tech/api/ace/version")!)
             request.timeoutInterval = 15
             request.cachePolicy = .reloadIgnoringLocalCacheData
             return try await StealthURLSessionRequest().perform(request)
         }) {
        self.running = running
        self.scan = scan
        self.fetch = fetch
    }

    var duplicateCount: Int { installations.filter { !$0.isAuthoritative }.count }

    private var authoritative: AceDetectedInstallation? {
        installations.first(where: \.isAuthoritative)
    }

    var runningIdentityLine: String {
        "Running: \(running.path) • PID \(running.processID) • "
            + Self.identityLine(running.identity) + " (captured at launch)"
    }

    var installedIdentityLine: String {
        guard hasScanned else { return "On disk: /Applications/Ace.app • not checked" }
        guard let authoritative else { return "On disk: /Applications/Ace.app • missing or unreadable" }
        return "On disk: /Applications/Ace.app • " + Self.identityLine(authoritative.releaseIdentitySnapshot)
    }

    var runtimeDifferenceLine: String? {
        guard hasScanned else { return nil }
        guard let authoritative else {
            return "The running process has no readable canonical installation. Restore Ace in Applications from your original receipt."
        }
        guard running.path == AceInstallationInventory.authoritativePath else {
            return "This process started from another location. Quit it and open /Applications/Ace.app."
        }
        guard running.identity != authoritative.releaseIdentitySnapshot else { return nil }
        return "The running process and files in Applications differ. Finish or stop active work, then quit and reopen /Applications/Ace.app to load the installed copy."
    }

    private static func identityLine(_ identity: AceInstalledReleaseIdentitySnapshot) -> String {
        "version \(identity.version ?? "unknown") • build \(identity.build ?? "unknown") • source \(identity.sourceSha256 ?? "unavailable")"
    }

    func refresh() {
        guard !isChecking, !StealthEntryLatch.shared.isRaised else { return }
        isChecking = true
        publicReleaseLine = "Checking the public release…"
        publicCheckFailed = false
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.isChecking = false }
            do {
                let found = await self.scan()
                try Task.checkCancellation()
                self.installations = found
                self.hasScanned = true
                guard let installed = self.authoritative?.releaseIdentitySnapshot else {
                    self.fail("The canonical installation is missing or unreadable. Restore Ace in Applications from your original receipt before checking its update.")
                    return
                }
                if let field = AceUpdateManifestPolicy.installedIdentityFailure(installed) {
                    self.fail("The installed app's \(field.rawValue) identity is missing or invalid. Reinstall from your original receipt; reconnecting to the internet will not repair these files.")
                    return
                }
                try Task.checkCancellation()
                let (data, response) = try await self.fetch()
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    self.fail("The release service returned an invalid response. No public version was verified.")
                    return
                }
                guard http.statusCode == 200 else {
                    self.fail("The release service returned HTTP \(http.statusCode). Retry later; no public version was verified.")
                    return
                }
                guard let release = AceUpdateManifestPolicy.validatedPublicRelease(
                    installed: installed, manifestData: data) else {
                    self.fail("The public release metadata is invalid or has no matching Ace edition. No update was verified. Retry later or contact Ace Support from your original receipt.")
                    return
                }
                self.publicReleaseLine = "Verified public release: version \(release.version) • build \(release.build) • DMG \(release.dmgBytes) bytes • SHA \(release.dmgSha256)"
            } catch is CancellationError {
                self.publicReleaseLine = "Public release check cancelled; no new version was verified."
            } catch {
                if Task.isCancelled {
                    self.publicReleaseLine = "Public release check cancelled; no new version was verified."
                } else if let error = error as? URLError,
                          [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                           .cannotConnectToHost, .dnsLookupFailed, .timedOut].contains(error.code) {
                    self.fail("The release service could not be reached. Check your connection and retry; no public version was verified.")
                } else {
                    self.fail("The release check failed before a public version could be verified. Retry or contact Ace Support from your original receipt.")
                }
            }
        }
        let cutoff = StealthEntryLatch.shared.registerSynchronousEntryCutoff { task.cancel() }
        Task {
            await task.value
            StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(cutoff)
        }
    }

    private func fail(_ message: String) {
        publicReleaseLine = message
        publicCheckFailed = true
    }
}
