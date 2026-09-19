import Foundation
#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Glibc)
import Glibc
#endif

/// A child of an admitted wrapper shares that wrapper's lock and authority
/// lifetime. The wrapper already consumed single-use authority; consuming it
/// again would reject every valid request.
nonisolated final class NativeHeadlessEffectAuthority: @unchecked Sendable {
    private let support: URL
    private let token: URL
    private let lifetime: URL
    private let parent: pid_t
    private let lifetimeDevice: dev_t
    private let lifetimeInode: ino_t
    private let multiEffect: Bool

    private init(support: URL, token: URL, lifetime: URL, parent: pid_t,
                 status: stat, multiEffect: Bool) {
        self.support = support; self.token = token; self.lifetime = lifetime
        self.parent = parent; self.lifetimeDevice = status.st_dev
        self.lifetimeInode = status.st_ino; self.multiEffect = multiEffect
    }

    static func acquire() -> NativeHeadlessEffectAuthority? {
        let environment = ProcessInfo.processInfo.environment
        let support: URL
#if NATIVE_HEADLESS_AUTHORITY_TEST
        guard let path = environment["ACE_NATIVE_TEST_SUPPORT"] else { return nil }
        support = URL(fileURLWithPath: path, isDirectory: true)
#else
        guard let directory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        support = directory.appendingPathComponent("BlackLabel", isDirectory: true)
#endif
        guard environment["ACE_APP_MUTATION_APPROVED"] == "1",
              let path = environment["ACE_APP_MUTATION_TOKEN_PATH"] else { return nil }
        let token = URL(fileURLWithPath: path).standardizedFileURL
        let approvals = support.appendingPathComponent("action-approvals", isDirectory: true)
        guard token.deletingLastPathComponent().path == approvals.path,
              token.lastPathComponent.hasPrefix("token-"),
              UUID(uuidString: String(token.lastPathComponent.dropFirst(6))) != nil,
              safeDirectory(support, privateMode: true),
              safeDirectory(approvals, privateMode: true) else { return nil }
        let parent = getppid()
        guard parent > 1, wrapperLockMatches(support: support, parent: parent) else { return nil }
        let multiEffect = environment["ACE_OWNER_TURN_MULTI_EFFECT"] == "1"
        let lifetime = multiEffect ? token : URL(fileURLWithPath: path + ".consumed")
        guard let status = ownedStatus(lifetime),
              multiEffect ? regularToken(token) : (status.st_mode & S_IFMT == S_IFDIR) else { return nil }
        if !multiEffect {
            // Only one child can inherit a one-use wrapper grant. The owner
            // destroys the consumed tree on completion or cancellation.
            let claim = lifetime.appendingPathComponent("native-child")
            guard mkdir(claim.path, 0o700) == 0 else { return nil }
        }
        let authority = NativeHeadlessEffectAuthority(support: support, token: token,
            lifetime: lifetime, parent: parent, status: status, multiEffect: multiEffect)
        return authority.isValid() ? authority : nil
    }

    func matchesPrivacyPaths(_ paths: [String]) -> Bool {
        paths == ["stealth-entry-request-v1", "stealth-intent-v1", "stealth-active"]
            .map { support.appendingPathComponent($0).path }
    }

    func isValid() -> Bool {
        guard getppid() == parent,
              kill(parent, 0) == 0 || errno == EPERM,
              Self.safeDirectory(support, privateMode: true),
              Self.safeDirectory(token.deletingLastPathComponent(), privateMode: true),
              Self.wrapperLockMatches(support: support, parent: parent),
              let current = Self.ownedStatus(lifetime),
              current.st_dev == lifetimeDevice, current.st_ino == lifetimeInode,
              multiEffect ? Self.regularToken(token) : (current.st_mode & S_IFMT == S_IFDIR)
        else { return false }
        for name in ["stealth-entry-request-v1", "stealth-intent-v1"] {
            var status = stat()
            if lstat(support.appendingPathComponent(name).path, &status) == 0 { return false }
            if errno != ENOENT { return false }
        }
        let marker = support.appendingPathComponent("stealth-active")
        var markerStatus = stat()
        if lstat(marker.path, &markerStatus) == 0 {
            guard markerStatus.st_mode & S_IFMT == S_IFREG,
                  let text = Self.readOwnedRegular(marker),
                  let pid = Int32(text.split(whereSeparator: \.isNewline).first ?? ""),
                  pid > 0 else { return false }
            if kill(pid, 0) == 0 || errno == EPERM { return false }
        } else if errno != ENOENT { return false }
        return true
    }

    private static func ownedStatus(_ url: URL) -> stat? {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_uid == geteuid(),
              status.st_mode & S_IFMT != S_IFLNK else { return nil }
        return status
    }

    private static func safeDirectory(_ url: URL, privateMode: Bool) -> Bool {
        guard let status = ownedStatus(url), status.st_mode & S_IFMT == S_IFDIR else { return false }
        return !privateMode || status.st_mode & 0o777 == 0o700
    }

    private static func readOwnedRegular(_ url: URL) -> String? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == geteuid(),
              status.st_mode & S_IFMT == S_IFREG, status.st_size > 0,
              status.st_size <= 256 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 256)
        let count = read(descriptor, &bytes, bytes.count)
        guard count == status.st_size else { return nil }
        return String(bytes: bytes.prefix(count), encoding: .utf8)
    }

    private static func regularToken(_ token: URL) -> Bool {
        guard let status = ownedStatus(token), status.st_mode & 0o777 == 0o600,
              let value = readOwnedRegular(token) else { return false }
        return value == String(token.lastPathComponent.dropFirst(6)) + "\n"
    }

    private static func wrapperLockMatches(support: URL, parent: pid_t) -> Bool {
        let lock = support.appendingPathComponent("visible-effect.lock", isDirectory: true)
        guard safeDirectory(lock, privateMode: false),
              let owner = readOwnedRegular(lock.appendingPathComponent("owner")) else { return false }
        return owner.trimmingCharacters(in: .whitespacesAndNewlines) == String(parent)
    }
}
