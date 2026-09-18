import Foundation

nonisolated enum BrainConnectionAuthenticationPolicy {
    static func shouldVerifyExistingSession(
        hasPrivateState: Bool,
        lastAttemptRejectedAuthentication: Bool
    ) -> Bool {
        hasPrivateState && !lastAttemptRejectedAuthentication
    }
}

/// Why a provider status evaluation is happening. Automatic lifecycle events
/// are deliberately represented alongside the only owner action that may start
/// a real CLI probe, so adding a new caller requires an explicit policy choice.
nonisolated enum BrainConnectionProbeRequestSource: Equatable {
    case returningLaunch
    case setupAppearance
    case navigationGuard
    case explicitRefresh
}

nonisolated enum BrainConnectionProbeAction: Equatable {
    case cachedOnly
    case runRealProbe
}

/// The visible state of one buyer-selected provider connection. It is kept
/// separate from a probe result: `connected` is entered only after that probe
/// supplied a real authenticated answer.
nonisolated enum BrainConnectionProviderOnboardingState: Equatable {
    case readyToConnect
    case launchingOAuth
    case waitingForAuthentication
    case connected
    case retryConnection
}

nonisolated enum BrainConnectionProviderOnboardingEvent: Equatable {
    case connectTapped
    case oauthLaunched
    case pollAnsweredRealProbe
    case pollTimedOut
    case cancelled
}

nonisolated enum BrainConnectionProviderPollDisposition: Equatable {
    case connected
    case keepWaiting
    case retryConnection
}

/// Browser OAuth returning successfully does not guarantee the provider's
/// credential store is visible to the next subprocess in the same instant.
/// Keep the existing bounded poll flight alive through transient probe
/// failures. A confirmed usage limit ends polling immediately and preserves
/// the existing account session for a later retry.
nonisolated enum BrainConnectionProviderPollPolicy {
    static func disposition(
        answeredRealProbe: Bool,
        attemptsRemaining: Int,
        providerUsageLimited: Bool = false,
        checkingSavedAccount: Bool = false
    ) -> BrainConnectionProviderPollDisposition {
        if answeredRealProbe {
            return .connected
        }
        if providerUsageLimited || checkingSavedAccount {
            return .retryConnection
        }
        return attemptsRemaining > 0 ? .keepWaiting : .retryConnection
    }

    /// A timer tick represents an attempt only when it actually starts a new
    /// provider process. Codex can legitimately take longer than the 20-second
    /// poll cadence, so ticks observed during that process are no-ops.
    static func shouldConsumeAttempt(probeIsChecking: Bool) -> Bool {
        !probeIsChecking
    }
}

/// Pure, provider-local one-click onboarding reducer. A repeated click has no
/// additional effect while OAuth/polling is in flight, and cancellation never
/// leaves an old provider task able to make the card look connected later.
nonisolated enum BrainConnectionProviderOnboardingPolicy {
    static let initialState: BrainConnectionProviderOnboardingState = .readyToConnect

    static func transition(
        from state: BrainConnectionProviderOnboardingState,
        event: BrainConnectionProviderOnboardingEvent
    ) -> BrainConnectionProviderOnboardingState {
        switch event {
        case .cancelled:
            return .readyToConnect
        case .connectTapped:
            switch state {
            case .readyToConnect, .retryConnection:
                return .launchingOAuth
            case .connected:
                // Re-authenticating is the whole point of tapping Connect on a
                // provider that already says "connected". `.connected` used to
                // return itself here, and connectProvider's guard admits a tap
                // only when the state CHANGES or is readyToConnect /
                // retryConnection — so the card went permanently dead the moment
                // a provider first connected. When the sign-in later expired
                // while the cached state still read connected, the buyer had no
                // way back in and the documented escape hatch could not fire.
                return .launchingOAuth
            case .launchingOAuth, .waitingForAuthentication:
                // A flight is genuinely in the air; native sign-in may run for
                // 300 seconds. Leave it alone.
                return state
            }
        case .oauthLaunched:
            return state == .launchingOAuth
                ? .waitingForAuthentication : state
        case .pollAnsweredRealProbe:
            return state == .waitingForAuthentication
                ? .connected : state
        case .pollTimedOut:
            return state == .waitingForAuthentication
                ? .retryConnection : state
        }
    }
}

/// Pure ownership seam for the single customer-provider connection flight.
/// Tapping another provider atomically retires the old card before the new
/// provider may launch. A completion carrying an older generation is stale.
nonisolated struct BrainConnectionProviderFlightCoordinator: Equatable {
    struct Flight: Equatable {
        let providerIdentifier: String
        let generation: UInt64
    }

    private(set) var activeFlight: Flight?
    private(set) var nextGeneration: UInt64 = 0
    private var onboardingStates:
        [String: BrainConnectionProviderOnboardingState] = [:]
    private var checkingProviderIdentifiers: Set<String> = []

    func onboardingState(
        for providerIdentifier: String
    ) -> BrainConnectionProviderOnboardingState {
        onboardingStates[providerIdentifier]
            ?? BrainConnectionProviderOnboardingPolicy.initialState
    }

    func probeIsChecking(providerIdentifier: String) -> Bool {
        checkingProviderIdentifiers.contains(providerIdentifier)
    }

    mutating func begin(
        providerIdentifier: String
    ) -> (retiredProviderIdentifier: String?, flight: Flight) {
        let retiredProviderIdentifier = activeFlight?.providerIdentifier
        if let retiredProviderIdentifier {
            onboardingStates[retiredProviderIdentifier] = .readyToConnect
            checkingProviderIdentifiers.remove(retiredProviderIdentifier)
        }
        nextGeneration &+= 1
        let flight = Flight(
            providerIdentifier: providerIdentifier,
            generation: nextGeneration
        )
        activeFlight = flight
        onboardingStates[providerIdentifier] = .launchingOAuth
        return (retiredProviderIdentifier, flight)
    }

    mutating func beginIfIdle(
        providerIdentifier: String
    ) -> Flight? {
        guard activeFlight == nil else { return nil }
        return begin(providerIdentifier: providerIdentifier).flight
    }

    func admits(_ flight: Flight) -> Bool {
        activeFlight == flight
    }

    mutating func markOAuthLaunched(_ flight: Flight) -> Bool {
        guard admits(flight) else { return false }
        onboardingStates[flight.providerIdentifier] =
            BrainConnectionProviderOnboardingPolicy.transition(
                from: onboardingState(for: flight.providerIdentifier),
                event: .oauthLaunched
            )
        return true
    }

    mutating func markProbeStarted(_ flight: Flight) -> Bool {
        guard admits(flight) else { return false }
        checkingProviderIdentifiers.insert(flight.providerIdentifier)
        return true
    }

    mutating func markProbeFinished(_ flight: Flight) -> Bool {
        guard admits(flight) else { return false }
        checkingProviderIdentifiers.remove(flight.providerIdentifier)
        return true
    }

    @discardableResult
    mutating func finishConnected(_ flight: Flight) -> Bool {
        guard admits(flight) else { return false }
        checkingProviderIdentifiers.remove(flight.providerIdentifier)
        onboardingStates[flight.providerIdentifier] = .connected
        activeFlight = nil
        return true
    }

    @discardableResult
    mutating func finishForRetry(_ flight: Flight) -> Bool {
        guard admits(flight) else { return false }
        checkingProviderIdentifiers.remove(flight.providerIdentifier)
        onboardingStates[flight.providerIdentifier] = .retryConnection
        activeFlight = nil
        return true
    }

    @discardableResult
    mutating func cancelActive() -> Flight? {
        guard let activeFlight else { return nil }
        onboardingStates[activeFlight.providerIdentifier] = .readyToConnect
        checkingProviderIdentifiers.remove(activeFlight.providerIdentifier)
        nextGeneration &+= 1
        self.activeFlight = nil
        return activeFlight
    }

    mutating func cancelAll() {
        for providerIdentifier in onboardingStates.keys {
            onboardingStates[providerIdentifier] = .readyToConnect
        }
        checkingProviderIdentifiers.removeAll(keepingCapacity: true)
        nextGeneration &+= 1
        activeFlight = nil
    }
}

nonisolated enum BrainConnectionProbeInvocationKind: Equatable {
    case executableVersion
    case isolatedZeroToolAnswer
    case invalidConfiguration
}

/// A provider connection proof needs one authenticated answer, not Ace's full
/// production brain surface. Codex 0.146.0 otherwise blocks a cold first run
/// on remote model/plugin catalog refreshes before it even sends that answer.
/// Keep the proof real while selecting the smallest model in this pinned
/// runtime and removing only discovery features that cannot affect auth.
nonisolated enum BrainConnectionCodexProbePolicy {
    static func arguments(
        answerFilePath: String,
        model: String
    ) -> [String] {
        CLIPrivacyPolicy.codexArguments([
            "exec",
            "--model", model,
            "--sandbox", "read-only",
            "--skip-git-repo-check",
            "--color", "never",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--disable", "remote_models",
            "--disable", "plugins",
            "--disable", "apps",
            "--disable", "plugin_sharing",
            "-c", "model_reasoning_effort=\"low\"",
            "--output-last-message", answerFilePath,
            "-",
        ])
    }
}

/// Pure acceptance policy for the live authentication probe. A successful
/// presence or version check can never satisfy this policy.
nonisolated enum BrainConnectionLiveProbePolicy {
    static func argumentsDescribeIsolatedZeroToolInvocation(
        _ arguments: [String]
    ) -> Bool {
        if argumentsDescribeEmbeddedQwenProbe(arguments) {
            return true
        }
        if let codexArguments = isolatedCodexArguments(from: arguments) {
            return value(after: "--sandbox", in: codexArguments) == "read-only"
                && value(after: "--output-last-message", in: codexArguments) != nil
                && codexArguments.contains("--skip-git-repo-check")
                && codexArguments.contains("--ephemeral")
                && codexArguments.contains("--ignore-user-config")
                && codexArguments.contains("--ignore-rules")
                && !codexArguments.contains("-i")
                && !codexArguments.contains(
                    "--dangerously-bypass-approvals-and-sandbox"
                )
        }

        guard arguments.filter({ $0 == "--tools" }).count == 1,
              value(after: "--tools", in: arguments) == "",
              value(after: "--permission-mode", in: arguments) == "dontAsk",
              value(after: "--setting-sources", in: arguments) == "",
              value(after: "--max-turns", in: arguments) == "1",
              arguments.contains("-p"),
              arguments.contains("--safe-mode"),
              arguments.contains("--disable-slash-commands"),
              arguments.contains("--no-chrome"),
              arguments.contains("--no-session-persistence"),
              arguments.contains("--strict-mcp-config"),
              !arguments.contains(where: {
                  $0 == "--allowedTools"
                      || $0.hasPrefix("--allowedTools=")
                      || $0.hasPrefix("--tools=")
                      || $0 == "--mcp-config"
                      || $0.hasPrefix("--mcp-config=")
                      || $0 == "--plugin-dir"
                      || $0.hasPrefix("--plugin-dir=")
                      || $0 == "--add-dir"
                      || $0.hasPrefix("--add-dir=")
              }),
              !arguments.contains("bypassPermissions"),
              !arguments.contains("--dangerously-skip-permissions") else {
            return false
        }
        return true
    }

    private static func argumentsDescribeEmbeddedQwenProbe(
        _ arguments: [String]
    ) -> Bool {
        guard arguments.count == 17,
              arguments[0] == "--model",
              URL(fileURLWithPath: arguments[1]).lastPathComponent
                == "qwen3-abliterated-30b-a3b-q4_k_m.gguf" else {
            return false
        }
        return Array(arguments.dropFirst(2)) == [
            "--offline",
            "--simple-io",
            "--conversation",
            "--single-turn",
            "--no-display-prompt",
            "--no-show-timings",
            "--log-disable",
            "--reasoning", "off",
            "--temp", "0",
            "--ctx-size", "4096",
            "--n-predict", "32",
        ]
    }

    static func provesLiveAuthenticatedAnswer(
        invocationKind: BrainConnectionProbeInvocationKind,
        exitCode: Int32,
        answerText: String,
        timedOut: Bool
    ) -> Bool {
        guard invocationKind == .isolatedZeroToolAnswer,
              exitCode == 0,
              !timedOut else {
            return false
        }
        return answerText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "ready"
    }

    private static func isolatedCodexArguments(
        from arguments: [String]
    ) -> [String]? {
        guard let codexArguments = CLIPrivacyPolicy
            .codexCommandArguments(from: arguments) else { return nil }
        return codexArguments.first == "exec" ? codexArguments : nil
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag) else { return nil }
        let valueIndex = arguments.index(after: flagIndex)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
}

nonisolated enum BrainConnectionCachedStatusKind: Equatable {
    case runtimeMissing
    case notChecked
    case runtimeChanged
    case previouslyVerified
}

/// Informational presentation derived without starting a provider process.
/// No case in this type means "connected" or can unlock setup.
nonisolated struct BrainConnectionCachedStatusSummary: Equatable {
    let kind: BrainConnectionCachedStatusKind
    let detail: String
}

nonisolated enum BrainConnectionStartupPolicy {
    static func action(
        for source: BrainConnectionProbeRequestSource
    ) -> BrainConnectionProbeAction {
        switch source {
        case .explicitRefresh:
            return .runRealProbe
        case .returningLaunch, .setupAppearance, .navigationGuard:
            return .cachedOnly
        }
    }

    static func cachedStatus(
        runtimeAvailable: Bool,
        hasStoredReceipt: Bool,
        receiptMatchesRuntime: Bool,
        versionDetail: String
    ) -> BrainConnectionCachedStatusSummary {
        guard runtimeAvailable else {
            return BrainConnectionCachedStatusSummary(
                kind: .runtimeMissing,
                detail: "Ace's bundled runtime is missing. Reinstall Ace to repair it."
            )
        }
        guard hasStoredReceipt else {
            return BrainConnectionCachedStatusSummary(
                kind: .notChecked,
                detail:
                    "Ready to connect your account."
            )
        }
        guard receiptMatchesRuntime else {
            return BrainConnectionCachedStatusSummary(
                kind: .runtimeChanged,
                detail:
                    "Runtime changed since the last verification. "
                    + "Retry connection."
            )
        }

        let normalizedVersion = versionDetail.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let detail = normalizedVersion.isEmpty
            ? "Previously verified. Connect to verify it again."
            : "Previously verified with \(normalizedVersion). Connect to verify it again."
        return BrainConnectionCachedStatusSummary(
            kind: .previouslyVerified,
            detail: detail
        )
    }
}
