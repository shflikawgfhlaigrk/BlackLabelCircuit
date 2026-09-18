import Foundation

enum AgentCapabilityScope: String, CaseIterable, Codable, Sendable {
    case workspaceReadWrite
    case shellAndProcesses
    case networkAccess
    case browserControl
    case appAutomation
    case screenContext
    case bundledCLITools
    case mcpAndPlugins

    var buyerFacingDescription: String {
        switch self {
        case .workspaceReadWrite:
            return "Read, create, change, and delete files in approved folders"
        case .shellAndProcesses:
            return "Run commands and local processes"
        case .networkAccess:
            return "Use websites and network services required by the task"
        case .browserControl:
            return "Open and control the browser"
        case .appAutomation:
            return "Use buyer-approved Mac apps"
        case .screenContext:
            return "Inspect the screen when the request needs it"
        case .bundledCLITools:
            return "Use the bundled Codex or Claude tools"
        case .mcpAndPlugins:
            return "Use enabled MCP tools and plugins"
        }
    }
}

struct AgentCapabilityConsentReceipt: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let approvedScopes: Set<AgentCapabilityScope>
    let approvedWorkspaceRoots: [String]
    let approvedAt: Date

    static func complete(
        workspaceRoots: [String],
        approvedAt: Date = Date()
    ) -> AgentCapabilityConsentReceipt {
        AgentCapabilityConsentReceipt(
            schemaVersion: currentSchemaVersion,
            approvedScopes: Set(AgentCapabilityScope.allCases),
            approvedWorkspaceRoots:
                workspaceRoots.map(standardizedPath).sorted(),
            approvedAt: approvedAt
        )
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

enum AgentCapabilityConsentDecision: Equatable, Sendable {
    case approvalRequired([AgentCapabilityScope])
    case workspaceApprovalRequired([String])
    case taskConfirmationRequired
    case allowed
}

enum AgentCapabilityConsentPolicy {
    static func decision(
        receipt: AgentCapabilityConsentReceipt?,
        requestedPaths: [String],
        consequential: Bool,
        taskConfirmed: Bool
    ) -> AgentCapabilityConsentDecision {
        guard let receipt,
              receipt.schemaVersion
                == AgentCapabilityConsentReceipt.currentSchemaVersion else {
            return .approvalRequired(AgentCapabilityScope.allCases)
        }

        let missingScopes = AgentCapabilityScope.allCases.filter {
            !receipt.approvedScopes.contains($0)
        }
        guard missingScopes.isEmpty else {
            return .approvalRequired(missingScopes)
        }

        let unapprovedPaths = requestedPaths.filter {
            !path($0, isWithinAny: receipt.approvedWorkspaceRoots)
        }
        guard unapprovedPaths.isEmpty else {
            return .workspaceApprovalRequired(unapprovedPaths)
        }
        if consequential, !taskConfirmed {
            return .taskConfirmationRequired
        }
        return .allowed
    }

    static var buyerFacingScopeList: String {
        AgentCapabilityScope.allCases
            .map { "• \($0.buyerFacingDescription)" }
            .joined(separator: "\n")
    }

    private static func path(
        _ candidate: String,
        isWithinAny roots: [String]
    ) -> Bool {
        let standardizedCandidate = URL(fileURLWithPath: candidate)
            .standardizedFileURL.path
        return roots.contains { root in
            let standardizedRoot = URL(fileURLWithPath: root)
                .standardizedFileURL.path
            if standardizedRoot == "/" {
                return standardizedCandidate.hasPrefix("/")
            }
            return standardizedCandidate == standardizedRoot
                || standardizedCandidate.hasPrefix(standardizedRoot + "/")
        }
    }
}
