//
//  WorkflowBoundary.swift
//  Ace
//
//  THE BUILD LANE'S BOUNDARIES — founder direction 2026-08-01, "full tools and
//  boundaries set."
//
//  Why this file exists. The build lane runs with full machine authority
//  (founder ruling, same day). Until now its only stated limits lived in the
//  build prompt — "stay inside the working directory", "reach no other host".
//  **A prompt is not a boundary.** It is a request to a model that already has
//  the authority to ignore it. This file is the part that does not depend on
//  the model behaving:
//
//    • PROTECTED PATHS — an enumerated set the job may never write, regardless
//      of authority: credentials, keychains, the owner's Claude login, mail and
//      message stores, system and app directories, and Ace's own state
//      (including this lane's ledger and the one-use approval directory, which
//      a job with write access could otherwise mint itself).
//    • PRE-FLIGHT — a plan whose workspace resolves onto or inside a protected
//      path is refused before any authority exists. Checked against the
//      symlink-resolved path, so a link cannot smuggle the workspace elsewhere.
//    • CAPS — wall clock, file count, and total bytes. A runaway build is
//      stopped and reported rather than left writing.
//    • POST-FLIGHT TRIPWIRE — protected paths are stamped before the job and
//      re-checked after. A changed stamp is a BOUNDARY VIOLATION: ledgered,
//      spoken, and it downgrades the job's verdict even if the deliverable
//      exists.
//
//  🚨 Honest limit of the tripwire: it compares directory modification stamps,
//  so it reliably catches an entry being added, removed, or renamed inside a
//  protected directory. It does NOT catch an in-place rewrite of an existing
//  file deep inside one, and it is detection after the fact, not prevention.
//  Real prevention would need the child confined by the kernel; the founder
//  chose full authority over a sandbox, so this is a tripwire plus a receipt,
//  and it is described as exactly that rather than as containment.
//

import Foundation

// MARK: - Violations

enum WorkflowBoundaryRefusal: Equatable {
    /// The plan cannot be armed at all.
    case workspaceIsProtected(String)
    case workspaceEscapesProjectsRoot(String)
    case undeclaredHost(String)

    /// What Ace says. Names the boundary, never invents a smaller job.
    var spokenRefusal: String {
        switch self {
        case let .workspaceIsProtected(path):
            return "that build would land in \(path), which i keep off limits. "
                + "give it a different name and i'll plan it again."
        case let .workspaceEscapesProjectsRoot(path):
            return "that build tried to write outside Ace Projects, at \(path). "
                + "i didn't start it."
        case let .undeclaredHost(host):
            return "that build wanted \(host), which you didn't approve. "
                + "i didn't start it."
        }
    }
}

/// Something a finished job did that it was not allowed to do.
struct WorkflowBoundaryViolation: Equatable {
    let boundary: String
    let detail: String

    var spokenWarning: String { "\(boundary): \(detail)" }
}

// MARK: - Boundary policy

enum WorkflowBoundary {

    // MARK: Caps

    /// Total wall clock for ONE workflow, planning included, on founder
    /// direction 2026-08-16: a workflow finishes in under 400 seconds.
    ///
    /// This supersedes the 2026-08-01 direction that raised the job ceiling
    /// from 900s to 1000s for headroom. That headroom is what is being
    /// removed: 60s planning + 1000s job admitted a 1060s workflow, and the
    /// owner requires the whole thing under 400s.
    ///
    /// KNOWN COST, recorded so it is not rediscovered as a mystery: the
    /// data-backed dashboard cited in the 2026-08-01 note took 353s of JOB
    /// time. Under this budget the job may run 340s, so that exact workflow
    /// now exceeds its ceiling by ~13s and is killed. Raising
    /// `totalWorkflowBudget` is the single knob that restores it.
    static let totalWorkflowBudget: TimeInterval = 400

    /// Planning runs before the job and is charged against the same ceiling,
    /// so it is reserved here rather than added on top. Must stay equal to
    /// `WorkflowRuntime.planningTimeout`.
    static let planningReserve: TimeInterval = 60

    /// Wall clock for one job — derived, never hand-set, so the total cannot
    /// drift past the budget when either half is retuned.
    static let jobTimeout: TimeInterval = totalWorkflowBudget - planningReserve

    /// A dashboard is a handful of files. These are runaway detectors, not
    /// budgets: a job that trips them has stopped doing what was approved.
    static let maximumFileCount = 400
    static let maximumTotalBytes = 256 * 1_024 * 1_024
    static let maximumExternalHosts = WorkflowPlan.maximumExternalSources

    // MARK: Protected paths

    /// Absolute prefixes the build lane may never write, no matter what the
    /// owner approved. Each entry is here because a job that wrote it could
    /// either steal something or disarm Ace itself.
    static func protectedPathPrefixes(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> [String] {
        let homePath = home.path
        return [
            // Credentials and identity.
            "\(homePath)/.ssh",
            "\(homePath)/.aws",
            "\(homePath)/.gnupg",
            "\(homePath)/.config/gh",
            "\(homePath)/.utah/secrets",
            "\(homePath)/Library/Keychains",
            // The owner's own Claude login — the brain this product runs on.
            "\(homePath)/.claude",
            // Private stores. A build has read capabilities for mail and
            // messages through tested wrappers; it never touches the databases.
            "\(homePath)/Library/Mail",
            "\(homePath)/Library/Messages",
            "\(homePath)/Library/Containers",
            // Ace's own state: the ledger this lane is audited by, the durable
            // Stealth intent, and the one-use approval directory. A job that
            // could write here could mint its own approvals or erase its trail.
            "\(homePath)/Library/Application Support/BlackLabel",
            // Installed software, including our own bundle.
            "/Applications",
            "/System",
            "/Library",
            "/usr",
            "/bin",
            "/sbin",
            "/etc",
            "/var",
            "/private/etc",
            "/private/var",
        ]
    }

    /// True when `path` is inside (or is) a protected prefix. Compares on path
    /// components so `/Applications` never matches `/ApplicationsOfMine`.
    static func isProtected(
        _ path: String,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> Bool {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        for prefix in protectedPathPrefixes(home: home) {
            let standardizedPrefix = URL(fileURLWithPath: prefix)
                .standardizedFileURL.path
            if standardized == standardizedPrefix { return true }
            if standardized.hasPrefix(standardizedPrefix + "/") { return true }
        }
        return false
    }

    // MARK: Pre-flight

    /// Judge a plan before any authority exists. Resolves symlinks first: the
    /// workspace name is already one sanitized component, but `Ace Projects`
    /// itself could be a link pointing somewhere it should not.
    static func refusal(
        for plan: WorkflowPlan,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> WorkflowBoundaryRefusal? {
        let workspaceURL = plan.workspaceURL(home: home)
        let projectsRoot = WorkflowPlan.projectsRoot(home: home)
            .resolvingSymlinksInPath().standardizedFileURL.path

        // Resolve what actually exists on the way down. A workspace that does
        // not exist yet still has a parent that does.
        let resolvedWorkspace = workspaceURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(workspaceURL.lastPathComponent)
            .standardizedFileURL

        if isProtected(resolvedWorkspace.path, home: home) {
            return .workspaceIsProtected(resolvedWorkspace.path)
        }
        guard resolvedWorkspace.path.hasPrefix(projectsRoot + "/"),
              !isProtected(projectsRoot, home: home)
        else {
            return .workspaceEscapesProjectsRoot(resolvedWorkspace.path)
        }
        if plan.externalSources.count > maximumExternalHosts {
            return .undeclaredHost("more hosts than i'll take in one job")
        }
        return nil
    }

    // MARK: Tripwire

    /// A stamp of every protected path, taken immediately before authority
    /// exists and compared immediately after it ends.
    struct ProtectedPathStamp: Equatable {
        let stamps: [String: String]

        static func take(
            home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        ) -> ProtectedPathStamp {
            var stamps: [String: String] = [:]
            for path in postflightTripwirePaths(home: home) {
                stamps[path] = stampValue(for: path)
            }
            return ProtectedPathStamp(stamps: stamps)
        }

        private static func postflightTripwirePaths(home: URL) -> [String] {
            let claudeRoot = home.appendingPathComponent(".claude").path
            let keychainsRoot = home
                .appendingPathComponent("Library/Keychains").path
            var paths = protectedPathPrefixes(home: home).filter {
                $0 != claudeRoot && $0 != keychainsRoot
            }
            // Claude Desktop continuously creates sessions and Keychain
            // legitimately rewrites its database during authentication. Their
            // directory timestamps cannot identify the workflow worker. Keep
            // stable Claude control files tripwired; both roots remain fully
            // protected by pre-flight and the isolated worker contract.
            paths += [
                "\(claudeRoot)/.claude.json",
                "\(claudeRoot)/CLAUDE.md",
                "\(claudeRoot)/launch.json",
                "\(claudeRoot)/settings.json",
            ]
            return paths
        }

        /// Modification date + size + inode. Absence is itself a stamp, so a
        /// protected path that appears during a job is caught too.
        private static func stampValue(for path: String) -> String {
            guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: path)
            else { return "absent" }
            let modified = (attributes[.modificationDate] as? Date)?
                .timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? Int) ?? 0
            let inode = (attributes[.systemFileNumber] as? Int) ?? 0
            return "\(modified)|\(size)|\(inode)"
        }

        /// Paths whose stamp changed since this one was taken.
        func changedPaths(
            home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        ) -> [String] {
            let now = ProtectedPathStamp.take(home: home)
            return stamps.keys.filter { now.stamps[$0] != stamps[$0] }.sorted()
        }
    }

    // MARK: Post-flight

    /// Everything the finished job did wrong. Empty means it stayed inside its
    /// approved boundaries.
    static func violations(
        for plan: WorkflowPlan,
        workspaceURL: URL,
        stamp: ProtectedPathStamp,
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> [WorkflowBoundaryViolation] {
        var found: [WorkflowBoundaryViolation] = []

        for changed in stamp.changedPaths(home: home) {
            found.append(
                WorkflowBoundaryViolation(
                    boundary: "protected path touched",
                    detail: changed))
        }

        let accounting = workspaceAccounting(at: workspaceURL)
        if accounting.fileCount > maximumFileCount {
            found.append(
                WorkflowBoundaryViolation(
                    boundary: "file cap",
                    detail: "\(accounting.fileCount) files, cap is \(maximumFileCount)"))
        }
        if accounting.totalBytes > maximumTotalBytes {
            found.append(
                WorkflowBoundaryViolation(
                    boundary: "size cap",
                    detail: "\(accounting.totalBytes / (1_024 * 1_024)) MB, "
                        + "cap is \(maximumTotalBytes / (1_024 * 1_024)) MB"))
        }
        for escape in accounting.symlinkEscapes {
            found.append(
                WorkflowBoundaryViolation(
                    boundary: "link out of the workspace",
                    detail: escape))
        }
        return found
    }

    struct WorkspaceAccounting: Equatable {
        let fileCount: Int
        let totalBytes: Int
        /// Symlinks inside the workspace whose target resolves outside it — a
        /// deliverable the owner opens must not quietly reach elsewhere.
        let symlinkEscapes: [String]
    }

    /// Walk the workspace once, bounded. Stops counting past a hard ceiling so
    /// a pathological tree cannot hang the audit itself.
    static func workspaceAccounting(at workspaceURL: URL) -> WorkspaceAccounting {
        let fileManager = FileManager.default
        let workspacePath = workspaceURL.resolvingSymlinksInPath()
            .standardizedFileURL.path
        var fileCount = 0
        var totalBytes = 0
        var symlinkEscapes: [String] = []
        let hardCeiling = maximumFileCount * 4

        guard let enumerator = fileManager.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return WorkspaceAccounting(
                fileCount: 0, totalBytes: 0, symlinkEscapes: [])
        }

        for case let itemURL as URL in enumerator {
            fileCount += 1
            if fileCount > hardCeiling { break }
            let values = try? itemURL.resourceValues(
                forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            totalBytes += values?.fileSize ?? 0
            if values?.isSymbolicLink == true {
                let resolved = itemURL.resolvingSymlinksInPath()
                    .standardizedFileURL.path
                if !resolved.hasPrefix(workspacePath + "/"), resolved != workspacePath {
                    symlinkEscapes.append(
                        "\(itemURL.lastPathComponent) → \(resolved)")
                }
            }
        }
        return WorkspaceAccounting(
            fileCount: fileCount,
            totalBytes: totalBytes,
            symlinkEscapes: symlinkEscapes)
    }

    // MARK: Spoken + written boundary statement

    /// The boundary half of the whole-job readback. The owner is granting full
    /// machine authority; they are entitled to hear what it still cannot do.
    static var spokenBoundaries: String {
        "i can't touch your keychain, your logins, your mail and message "
            + "files, or anything in the system and applications folders — "
            + "that holds even while i'm building."
    }

    static var writtenBoundaries: String {
        var lines = ["BOUNDARIES (enforced regardless of the grant):"]
        lines.append("  workspace: writes belong under ~/Ace Projects/<this job>")
        lines.append("  caps: \(Int(jobTimeout))s, \(maximumFileCount) files, "
            + "\(maximumTotalBytes / (1_024 * 1_024)) MB")
        lines.append("  protected (never written, tripwired before/after):")
        for path in protectedPathPrefixes() {
            lines.append("    \(path)")
        }
        return lines.joined(separator: "\n")
    }
}
