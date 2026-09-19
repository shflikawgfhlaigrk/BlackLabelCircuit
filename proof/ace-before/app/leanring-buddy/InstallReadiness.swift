#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM
import Darwin
#elseif canImport(ucrt)
import ucrt
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

nonisolated enum InstallReadinessActivity:
    String, CaseIterable, Codable, Hashable, Sendable
{
    case ownerWork = "owner_work"
    case backgroundWork = "background_work"
    case workflowBuild = "workflow_build"
    case notesStartup = "notes_startup"
    case notesCapture = "notes_capture"
    case notesFinalization = "notes_finalization"
    case notesReview = "notes_review"
    case voiceCapture = "voice_capture"
    case voicePlayback = "voice_playback"
    case privateModeEntry = "private_mode_entry"
    case privateModeAnswer = "private_mode_answer"
    case partnerSession = "partner_session"
    case setupAuth = "setup_auth"
    case pendingUserDecision = "pending_user_decision"
    case visiblePanel = "visible_panel"
}

nonisolated enum InstallReadinessResult: String, Equatable, Sendable {
    case idle
    case busy
}

nonisolated struct InstallReadinessSnapshot: Equatable, Sendable {
    let generation: UInt64
    let activeActivities: [InstallReadinessActivity]

    var result: InstallReadinessResult {
        activeActivities.isEmpty ? .idle : .busy
    }
}

nonisolated enum InstallReadinessError: Error, Equatable {
    case malformedRequest
    case invalidNonce
    case invalidProcessIdentifier
    case invalidBuild
    case invalidSourceIdentity
    case unsafePath
    case writeFailed
}

nonisolated struct InstallReadinessRequest: Equatable, Sendable {
    static let schema = "ace-install-readiness-request-v1"
    static let canonicalKeys = ["schema", "nonce", "expected_pid"]

    let nonce: String
    let expectedProcessIdentifier: Int32

    init(nonce: String, expectedProcessIdentifier: Int32) throws {
        guard Self.isValidNonce(nonce) else {
            throw InstallReadinessError.invalidNonce
        }
        guard expectedProcessIdentifier > 0 else {
            throw InstallReadinessError.invalidProcessIdentifier
        }
        self.nonce = nonce
        self.expectedProcessIdentifier = expectedProcessIdentifier
    }

    var canonicalText: String {
        [
            "schema=\(Self.schema)",
            "nonce=\(nonce)",
            "expected_pid=\(expectedProcessIdentifier)",
            "",
        ].joined(separator: "\n")
    }

    static func parse(
        _ data: Data,
        actualProcessIdentifier: Int32
    ) throws -> InstallReadinessRequest {
        let fields = try InstallReadinessCanonicalFields.parse(
            data,
            exactKeys: canonicalKeys
        )
        guard fields["schema"] == schema,
              let nonce = fields["nonce"],
              let processText = fields["expected_pid"],
              let expectedProcessIdentifier = Int32(processText),
              expectedProcessIdentifier == actualProcessIdentifier else {
            throw InstallReadinessError.malformedRequest
        }
        return try InstallReadinessRequest(
            nonce: nonce,
            expectedProcessIdentifier: expectedProcessIdentifier
        )
    }

    static func load(
        from requestURL: URL,
        actualProcessIdentifier: Int32
    ) throws -> InstallReadinessRequest {
        let descriptor = Darwin.open(
            requestURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw InstallReadinessError.unsafePath
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o777 == 0o600,
              status.st_size > 0,
              status.st_size <= 1_024,
              let data = try handle.readToEnd() else {
            throw InstallReadinessError.unsafePath
        }
        return try parse(
            data,
            actualProcessIdentifier: actualProcessIdentifier
        )
    }

    private static func isValidNonce(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{32,128}$"#,
            options: .regularExpression
        ) != nil
    }
}

nonisolated struct InstallReadinessReceipt: Equatable, Sendable {
    static let schema = "ace-install-readiness-receipt-v1"
    static let canonicalKeys = [
        "schema", "nonce", "pid", "build", "source_sha256",
        "generation", "utc", "result", "activities",
    ]

    let nonce: String
    let processIdentifier: Int32
    let build: String
    let sourceSHA256: String
    let generation: UInt64
    let createdAt: Date
    let result: InstallReadinessResult
    let activities: [InstallReadinessActivity]

    init(
        nonce: String,
        processIdentifier: Int32,
        build: String,
        sourceSHA256: String,
        generation: UInt64,
        createdAt: Date,
        result: InstallReadinessResult,
        activities: [InstallReadinessActivity]
    ) throws {
        _ = try InstallReadinessRequest(
            nonce: nonce,
            expectedProcessIdentifier: processIdentifier
        )
        guard build.range(
            of: #"^[A-Za-z0-9._-]{1,64}$"#,
            options: .regularExpression
        ) != nil else {
            throw InstallReadinessError.invalidBuild
        }
        guard sourceSHA256.range(
            of: #"^[0-9a-f]{64}$"#,
            options: .regularExpression
        ) != nil else {
            throw InstallReadinessError.invalidSourceIdentity
        }
        let sortedActivities = activities.sorted {
            $0.rawValue < $1.rawValue
        }
        guard result == (sortedActivities.isEmpty ? .idle : .busy) else {
            throw InstallReadinessError.malformedRequest
        }
        self.nonce = nonce
        self.processIdentifier = processIdentifier
        self.build = build
        self.sourceSHA256 = sourceSHA256
        self.generation = generation
        self.createdAt = createdAt
        self.result = result
        self.activities = sortedActivities
    }

    var canonicalText: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let activityText = activities.isEmpty
            ? "none"
            : activities.map(\.rawValue).joined(separator: ",")
        return [
            "schema=\(Self.schema)",
            "nonce=\(nonce)",
            "pid=\(processIdentifier)",
            "build=\(build)",
            "source_sha256=\(sourceSHA256)",
            "generation=\(generation)",
            "utc=\(formatter.string(from: createdAt))",
            "result=\(result.rawValue)",
            "activities=\(activityText)",
            "",
        ].joined(separator: "\n")
    }
}

@MainActor
final class InstallReadinessCoordinator {
    static let shared = InstallReadinessCoordinator()

    private var activeActivities: Set<InstallReadinessActivity> = []
    private var generation: UInt64 = 0
    /// Process-local only. A prepared native update freezes new premium work
    /// through the existing exhaustive surface admission, while Stop, privacy
    /// and recovery remain available. The replacement process starts unlocked.
    var nativeUpdateHandoffIsActive = false

    var snapshot: InstallReadinessSnapshot {
        InstallReadinessSnapshot(
            generation: generation,
            activeActivities: activeActivities.sorted {
                $0.rawValue < $1.rawValue
            }
        )
    }

    @discardableResult
    func set(
        _ activity: InstallReadinessActivity,
        active: Bool
    ) -> Bool {
        let changed: Bool
        if active {
            changed = activeActivities.insert(activity).inserted
        } else {
            changed = activeActivities.remove(activity) != nil
        }
        if changed {
            generation &+= 1
        }
        return changed
    }

    func synchronize(
        _ states: [InstallReadinessActivity: Bool]
    ) {
        for activity in InstallReadinessActivity.allCases {
            guard let active = states[activity] else { continue }
            _ = set(activity, active: active)
        }
    }

    func makeReceipt(
        for request: InstallReadinessRequest,
        processIdentifier: Int32,
        build: String,
        sourceSHA256: String,
        now: Date = Date()
    ) throws -> InstallReadinessReceipt {
        guard request.expectedProcessIdentifier == processIdentifier else {
            throw InstallReadinessError.invalidProcessIdentifier
        }
        let snapshot = snapshot
        return try InstallReadinessReceipt(
            nonce: request.nonce,
            processIdentifier: processIdentifier,
            build: build,
            sourceSHA256: sourceSHA256,
            generation: snapshot.generation,
            createdAt: now,
            result: snapshot.result,
            activities: snapshot.activeActivities
        )
    }
}

nonisolated enum InstallReadinessReceiptWriter {
    static let requestFileName = "install-readiness.request"
    static let receiptFileName = "install-readiness.receipt"

    static func write(
        _ receipt: InstallReadinessReceipt,
        supportDirectoryURL: URL
    ) throws -> URL {
        try PrivateSupportDirectory.ensure(at: supportDirectoryURL)
        let receiptURL = supportDirectoryURL.appendingPathComponent(
            receiptFileName,
            isDirectory: false
        )
        let temporaryURL = supportDirectoryURL.appendingPathComponent(
            ".\(receiptFileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporaryURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw InstallReadinessError.writeFailed
        }

        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: true
        )
        do {
            try handle.write(contentsOf: Data(receipt.canonicalText.utf8))
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(
                temporaryURL.path,
                receiptURL.path
            ) == 0 else {
                throw InstallReadinessError.writeFailed
            }
            guard Darwin.chmod(receiptURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw InstallReadinessError.writeFailed
            }
            return receiptURL
        } catch {
            _ = Darwin.unlink(temporaryURL.path)
            throw error
        }
    }
}

nonisolated private enum InstallReadinessCanonicalFields {
    static func parse(
        _ data: Data,
        exactKeys: [String]
    ) throws -> [String: String] {
        guard data.count <= 4_096,
              let text = String(data: data, encoding: .utf8),
              text.hasSuffix("\n"),
              !text.contains("\r") else {
            throw InstallReadinessError.malformedRequest
        }
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: true
        )
        guard lines.count == exactKeys.count else {
            throw InstallReadinessError.malformedRequest
        }
        var fields: [String: String] = [:]
        for (index, line) in lines.enumerated() {
            let parts = line.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  String(parts[0]) == exactKeys[index],
                  !parts[1].isEmpty,
                  fields[exactKeys[index]] == nil else {
                throw InstallReadinessError.malformedRequest
            }
            fields[exactKeys[index]] = String(parts[1])
        }
        return fields
    }
}
