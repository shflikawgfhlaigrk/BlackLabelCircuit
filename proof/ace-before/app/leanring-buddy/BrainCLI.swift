import Foundation

/// The three customer-selectable model providers. Provider choice changes the
/// model transport only; Red authority and tool capabilities are shared.
nonisolated enum BrainCLI: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case qwen

    /// Qwen is an optional artifact capability, never a dependency of the
    /// Codex or Claude lanes. The sealed build flag keeps the provider-only
    /// download from advertising a runtime it intentionally does not contain.
    static var includesQwen: Bool {
        Bundle.main.object(forInfoDictionaryKey: "BLIncludesQwen") as? Bool
            == true
    }

    static var customerChoices: [BrainCLI] {
        customerChoices(includesQwen: includesQwen)
    }

    static func customerChoices(includesQwen: Bool) -> [BrainCLI] {
        includesQwen ? [.codex, .claude, .qwen] : [.codex, .claude]
    }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex CLI"
        case .claude: return "Claude Code"
        case .qwen: return "Qwen3 Abliterated"
        }
    }

    var vendorLine: String {
        switch self {
        case .codex: return "OpenAI · runs on your Codex subscription"
        case .claude: return "Anthropic · runs on your Claude subscription"
        case .qwen: return "Embedded in Ace · runs fully on this Mac"
        }
    }

    var symbolName: String {
        switch self {
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .claude: return "sparkle"
        case .qwen: return "cpu"
        }
    }

    var installCommand: String {
        switch self {
        case .codex: return "Repair Ace to restore Codex"
        case .claude: return "Repair Ace to restore Claude Code"
        case .qwen: return "Repair Ace to restore embedded Qwen"
        }
    }

    var missingRuntimeTitle: String {
        if self == .qwen {
#if arch(arm64)
            return "Ace's embedded Qwen runtime or model is missing."
#else
            return "Embedded Qwen requires an Apple-silicon Mac."
#endif
        }
        return "Ace's bundled \(displayName.replacingOccurrences(of: " CLI", with: "")) runtime is missing."
    }

    var automaticInstallCommand: String? { nil }

    var manualDownloadURL: URL? { nil }

    var alternateInstallCommand: String { "" }

    var signInCommand: String {
        switch self {
        case .codex: return "Sign in with ChatGPT"
        case .claude: return "claude"
        case .qwen: return "Verify local model"
        }
    }

    var requiresBrowserAuthentication: Bool { self != .qwen }

    var signInHint: String {
        switch self {
        case .codex:
            return "Ace opens ChatGPT sign-in in your browser and checks the connection automatically."
        case .claude:
            return "Ace opens Anthropic sign-in in your browser and checks the connection automatically."
        case .qwen:
            return "Ace verifies its embedded llama.cpp runtime and Qwen3 model. No account, browser sign-in, service, or separate install is needed."
        }
    }
}
