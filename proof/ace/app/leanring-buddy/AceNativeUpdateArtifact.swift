import Foundation
#if canImport(CryptoKit) && !CIRCUIT_WINDOWS_SIM
import CryptoKit
#else
import Crypto
#endif
#if canImport(Security) && !CIRCUIT_WINDOWS_SIM
import Security
#else
import CircuitPortKit
#endif

nonisolated enum AceNativeUpdateArtifact {
    static func verifyMount(_ data: Data, expectedURL: URL) throws {
        guard let plist = try PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            throw AceNativeUpdateError.rejected("macOS returned an invalid update mount receipt.")
        }
        let mountedPaths = entities.compactMap { $0["mount-point"] as? String }
        // Foundation and hdiutil spell the system temporary directory as /var
        // and /private/var respectively. Compare filesystem destinations, not
        // spellings; still require exactly one mount at this transaction's URL.
        guard mountedPaths.count == 1,
              mountedPaths[0].hasPrefix("/"),
              URL(fileURLWithPath: mountedPaths[0], isDirectory: true)
                .resolvingSymlinksInPath().standardizedFileURL
                == expectedURL.resolvingSymlinksInPath().standardizedFileURL else {
            throw AceNativeUpdateError.rejected("The update disk image did not mount at its private destination.")
        }
    }

    static let signingRequirement =
        "identifier \"com.blacklabel.assistant\" and anchor apple generic "
        + "and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
        + "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists "
        + "and certificate leaf[subject.OU] = \"745ZPGFRA5\""

    static func verifyDownload(_ url: URL, release: AceValidatedPublicRelease,
                               checkpoint: () throws -> Void) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == release.dmgBytes else {
            throw AceNativeUpdateError.rejected("The downloaded package has the wrong size or file type.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var byteCount = 0
        while true {
            try checkpoint()
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            byteCount += data.count
            guard byteCount <= release.dmgBytes else {
                throw AceNativeUpdateError.rejected("The update package changed during verification.")
            }
            hasher.update(data: data)
        }
        guard byteCount == release.dmgBytes,
              hasher.finalize().map({ String(format: "%02x", $0) }).joined() == release.dmgSha256 else {
            throw AceNativeUpdateError.rejected("The update package failed its SHA-256 check. Download it again.")
        }
    }

    static func verifyBundle(_ url: URL, release: AceValidatedPublicRelease) throws {
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL else {
            throw AceNativeUpdateError.rejected("The update app is a shortcut.")
        }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(signingRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(
                kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)),
                requirement) == errSecSuccess else {
            throw AceNativeUpdateError.rejected("The update app does not have an intact Black Label Developer ID signature.")
        }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: infoURL)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              matchesInfo(info, release: release) else {
            throw AceNativeUpdateError.rejected("The signed app does not match the selected release.")
        }
        var signingInformation: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation),
                                           &signingInformation) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let digest = information[kSecCodeInfoUnique as String] as? Data else {
            throw AceNativeUpdateError.rejected("The update app's signed identity could not be read.")
        }
        #if arch(arm64)
        let expected = release.appCdhashArm64
        #else
        let expected = release.appCdhashX86_64
        #endif
        guard !expected.isEmpty, digest.map({ String(format: "%02x", $0) }).joined() == expected else {
            throw AceNativeUpdateError.rejected("The update app's executable does not match the release receipt.")
        }
    }

    static func matchesInfo(_ info: [String: Any], release: AceValidatedPublicRelease) -> Bool {
        info["CFBundleIdentifier"] as? String == "com.blacklabel.assistant"
            && info["CFBundleVersion"] as? String == String(release.build)
            && info["CFBundleShortVersionString"] as? String == release.version
            && info["BLAppSourceSHA256"] as? String == release.sourceSha256
            && info["BLIncludesQwen"] as? Bool == release.includesQwen
            && info["BLIncludesBackgroundHelper"] as? Bool == release.includesBackgroundHelper
    }
}

/// Only fixed macOS utilities are invoked, with argument arrays and no shell.
/// Stdout goes to a private file so a full pipe cannot deadlock cancellation.
nonisolated enum AceNativeUpdateCommand {
    static func run(_ executable: String, _ arguments: [String],
                    directory: URL, timeout: TimeInterval = 120,
                    cleanupOnly: Bool = false) async throws -> Data {
        guard ["/usr/bin/hdiutil", "/usr/sbin/spctl"].contains(executable) else {
            throw AceNativeUpdateError.rejected("Invalid update utility.")
        }
        guard !cleanupOnly || (executable == "/usr/bin/hdiutil"
            && arguments.count == 2 && arguments.first == "detach") else {
            throw AceNativeUpdateError.rejected("Only unmounting is allowed during update cleanup.")
        }
        let output = directory.appendingPathComponent("command-\(UUID().uuidString).txt")
        guard FileManager.default.createFile(atPath: output.path, contents: nil,
                                              attributes: [.posixPermissions: 0o600]) else {
            throw AceNativeUpdateError.rejected("The update workspace is not writable.")
        }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        let box = RunningProcessBox()
        let registration: UUID? = cleanupOnly ? nil :
            StealthEntryLatch.shared.registerSynchronousEntryCutoff {
                box.terminate(generation: 1)
            }
        defer {
            if let registration { StealthEntryLatch.shared.unregisterSynchronousEntryCutoff(registration) }
            box.clear(generation: 1)
        }
        return try await withTaskCancellationHandler {
            if cleanupOnly {
                try process.run()
            } else {
                try Task.checkCancellation()
                guard try StealthEntryLatch.shared.performUnlessRaised({
                    try process.run()
                    return true
                }) == true else { throw CancellationError() }
            }
            box.register(process, generation: 1)
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            while process.isRunning {
                if ContinuousClock.now >= deadline {
                    box.terminate(generation: 1)
                    throw AceNativeUpdateError.rejected("The update utility timed out. Your previous Ace is preserved.")
                }
                if !cleanupOnly { try Task.checkCancellation() }
                try await Task.sleep(for: .milliseconds(100))
            }
            if !cleanupOnly {
                try Task.checkCancellation()
                guard !StealthEntryLatch.shared.isRaised else { throw CancellationError() }
            }
            guard process.terminationStatus == 0 else {
                throw AceNativeUpdateError.rejected(executable == "/usr/sbin/spctl"
                    ? "macOS could not verify this update's notarization. Your previous Ace is preserved."
                    : "macOS could not open the update disk image. Your previous Ace is preserved.")
            }
            try handle.close()
            let count = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard count <= 1024 * 1024 else {
                throw AceNativeUpdateError.rejected("The update utility returned an invalid response.")
            }
            return try Data(contentsOf: output)
        } onCancel: {
            if !cleanupOnly { box.terminate(generation: 1) }
        }
    }
}
