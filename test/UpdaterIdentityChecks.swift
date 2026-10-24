import Foundation
import Security

@main
struct UpdaterIdentityChecks {
    static func main() throws {
        let manifest = UpdateManifest(product: "circuit", latestBuild: 10)
        let info: [String: Any] = ["CFBundleIdentifier": "com.blacklabel.circuit", "CFBundleVersion": "10"]
        try Updater.validateStagedInfo(info, manifest: manifest, current: 9)
        for bad in [["CFBundleIdentifier": "com.example.other", "CFBundleVersion": "10"],
                    ["CFBundleIdentifier": "com.blacklabel.circuit", "CFBundleVersion": "9"],
                    ["CFBundleIdentifier": "com.blacklabel.circuit", "CFBundleVersion": "11"]] {
            do { try Updater.validateStagedInfo(bad, manifest: manifest, current: 9); fatalError("accepted wrong app or build") }
            catch is UpdaterError { }
        }
        do { try Updater.validateStagedInfo(info, manifest: manifest, current: 10); fatalError("accepted downgrade/reinstall") }
        catch is UpdaterError { }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"745ZPGFRA5\" and notarized" as CFString
        precondition(SecRequirementCreateWithString(text, SecCSFlags(), &requirement) == errSecSuccess)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("circuit-update-check-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("Circuit.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path); try? FileManager.default.removeItem(at: dir) }
        try Updater.validateInstallLocation(app)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        do { try Updater.validateInstallLocation(app); fatalError("accepted unwritable install parent") }
        catch is UpdaterError { }
        print("PASS: expected bundle/build, newer-only policy, notarization requirement grammar, and install-location preflight")
    }
}
