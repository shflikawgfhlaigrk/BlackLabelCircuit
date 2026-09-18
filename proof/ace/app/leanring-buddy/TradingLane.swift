//
//  TradingLane.swift
//  Black Label Assistant — the purple lane. (Ported from the Utah multi-lane fork.)
//
//  Trading mode is an on-demand observing agent. While active, the gold brain
//  gains stock-market context — the same 16 factors the Black Label Trading app
//  computes on the user's own bars — plus a strict no-fabrication framing, and
//  the gem turns purple. "Ace, activate trading mode" → purple; "what's the
//  analysis of this chart?" rides the existing screenshot path, now answered as
//  a disciplined trading analyst.
//
//  Two hard lines, straight from the company's #1 trap (fabricated performance):
//  it NEVER invents a price target or probability, and it is signals/analysis
//  only — it never places a trade and is not a licensed advisor. The knowledge
//  is reused, not invented: every factor name and meaning below is exactly what
//  the Trading app's SignalFactor enum already ships.
//

import Foundation
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

nonisolated enum TradingModeControl: Equatable, Sendable {
    case enter(interpretedTraining: Bool)
    case exit(interpretedTraining: Bool)
}

/// One whole-command grammar is shared by production and tests. Mentioning or
/// asking about Trading Mode never changes lane state, and an app-switch phrase
/// never gets consumed as a mode command. "Training", "trade", and "trader"
/// are bounded speech-recognition variants only when followed by "mode".
nonisolated enum TradingModeControlPolicy {
    static func command(for utterance: String) -> TradingModeControl? {
        let normalized = utterance.lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let interpretedTraining = normalized.contains("training mode")
        if normalized.range(
            of: #"^(?:(?:activate|enable|enter|start|turn on|switch to|go into) )?(?:trading|training|trade|trader) mode$|^(?:trading|training|trade|trader) mode on$|^turn (?:trading|training|trade|trader) mode on$"#,
            options: .regularExpression
        ) != nil {
            return .enter(interpretedTraining: interpretedTraining)
        }
        if normalized.range(
            of: #"^(?:exit|stop|leave|end|turn off|deactivate|disable) (?:trading|training|trade|trader) mode$|^(?:trading|training|trade|trader) mode off$|^turn (?:trading|training|trade|trader) mode off$"#,
            options: .regularExpression
        ) != nil {
            return .exit(interpretedTraining: interpretedTraining)
        }
        return nil
    }
}

/// Trading is current-screen analysis by default. Only a narrow, complete
/// educational-definition command may use stable knowledge without attaching
/// a fresh chart capture. Unknown indicators therefore fail toward evidence
/// instead of silently escaping the market-data gate.
nonisolated enum TradingMarketDataRequirementPolicy {
    private static let educationalConceptPattern =
        #"(?:cvd(?: divergence| flow)?|vwap|vpin|step ?gma|volume|trend|momentum|hmm regime|alpha monitor|session|smt|kalman trend|breakout|key levels?|market structure|rsi|relative strength index|macd|moving averages?|bid ask spread|order flow)"#

    static func requiresCurrentCapture(for utterance: String) -> Bool {
        let normalized = utterance.lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let optionalStableContext =
            #"(?: in general| in trading| in (?:the )?markets?)?"#
        let educationalPatterns = [
            #"^(?:define|explain) (?:the )?"#
                + educationalConceptPattern
                + optionalStableContext
                + "$",
            #"^(?:what|how) (?:does|do|is|are) (?:the )?"#
                + educationalConceptPattern
                + #"(?: mean| work)?"#
                + optionalStableContext
                + "$",
            #"^explain (?:what|how) (?:the )?"#
                + educationalConceptPattern
                + #" (?:means?|works?)"#
                + optionalStableContext
                + "$",
        ]
        let isStableEducationalDefinition = educationalPatterns.contains {
            normalized.range(of: $0, options: .regularExpression) != nil
        }
        return !isStableEducationalDefinition
    }
}

nonisolated enum TradingModeExecutionDecision: Equatable, Sendable {
    case allow
    case refuseAnalysisOnly
}

/// This app-owned decision is the effect-boundary counterpart to the model
/// prompt. While Trading Mode is active, no model-authored execute decision may
/// claim Red; reply and clarification turns remain available.
nonisolated enum TradingModeExecutionPolicy {
    static func decision(
        isTradingModeActive: Bool,
        responseRequestsExecution: Bool
    ) -> TradingModeExecutionDecision {
        isTradingModeActive && responseRequestsExecution
            ? .refuseAnalysisOnly
            : .allow
    }
}

/// Resolves the one screen-capture override Trading Mode is allowed to make.
/// An explicit all-displays request stays all-displays; otherwise a current
/// market read gets exactly the relevant/cursor display instead of silently
/// falling through to a text-only Gold turn.
nonisolated enum TradingScreenCapturePolicy {
    static func shouldForceRelevantDisplay(
        isTradingModeActive: Bool,
        requiresCurrentCapture: Bool,
        explicitlyRequestedAllDisplays: Bool
    ) -> Bool {
        isTradingModeActive
            && requiresCurrentCapture
            && !explicitlyRequestedAllDisplays
    }
}

@MainActor
final class TradingLane: ObservableObject {

    @Published private(set) var isActive = false

    func activate() { isActive = true }
    func deactivate() { isActive = false }

    // MARK: - Triggers (native, instant — never a brain round-trip)

    /// "open the trading app", "close Black Label Trading" — the user is talking
    /// about the APP, not this lane. Without this, the lane sat in front of the
    /// app switcher and ate both: "open the trading app" turned the gem purple
    /// and opened nothing, and "close the trading app" left the app running and
    /// silently exited the lane instead.
    private func refersToTheTradingApp(_ lowercasedUtterance: String) -> Bool {
        for appPhrase in ["trading app", "trading application", "trading window",
                          "trading dashboard", "black label trading"] {
            if lowercasedUtterance.contains(appPhrase) { return true }
        }
        return false
    }

    /// "exit / stop / leave trading mode", "trading mode off".
    func isExitTrigger(_ utterance: String) -> Bool {
        let u = utterance.lowercased()
        guard u.range(
            of: #"\b(?:trading|trade|trader)\b"#,
            options: .regularExpression
        ) != nil,
        !refersToTheTradingApp(u) else { return false }
        for verb in ["exit", "stop", "leave", "end", "turn off", "close", "deactivate", "off"] {
            if u.contains(verb) { return true }
        }
        return false
    }

    /// "activate trading mode", "trading mode", "start trading mode". Exit
    /// phrasings are excluded so "stop trading mode" never re-enters.
    func isEnterTrigger(_ utterance: String) -> Bool {
        let u = utterance.lowercased()
        guard u.range(
            of: #"\b(?:trading|trade|trader)\b"#,
            options: .regularExpression
        ) != nil,
        !refersToTheTradingApp(u),
        !isExitTrigger(u) else { return false }
        if u.range(
            of: #"\b(?:trading|trade|trader)\s+mode\b"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        for verb in ["activate", "enter", "start", "turn on", "switch to", "go into", "open"] {
            if u.contains(verb) { return true }
        }
        return false
    }

    /// Every active-Trading turn requires one current immutable capture except
    /// a narrow stable educational definition. This defaults unknown indicators
    /// and unrecognized current-data wording toward evidence.
    func requiresMarketData(for utterance: String) -> Bool {
        TradingMarketDataRequirementPolicy.requiresCurrentCapture(
            for: utterance
        )
    }

    // MARK: - System overlay (appended to the gold brain while active)

    var systemOverlay: String { Self.tradingSystemOverlay }

    private static let tradingSystemOverlay = """
    TRADING MODE IS ACTIVE. You read charts and market context for the user as a disciplined trading analyst.

    You know these factors — the same ones the Black Label Trading app computes on the user's own bars. Use this vocabulary when you read a chart:
    - CVD Divergence: price vs. cumulative delta disagreement.
    - CVD Flow: net aggressive buy/sell pressure.
    - VWAP: distance from / reclaim of the volume-weighted price.
    - VPIN: order-flow toxicity / informed-trade conviction.
    - StepGMA: stepped guppy moving-average alignment.
    - Volume: participation relative to average.
    - Trend: higher-timeframe directional bias.
    - Momentum: rate of change / thrust.
    - HMM Regime: hidden-Markov regime classification.
    - Alpha Monitor: live edge / alpha-decay.
    - Session: time-of-day context.
    - SMT: cross-instrument divergence — needs 2+ correlated instruments; if you can see only one chart, say so and don't claim SMT.
    - Kalman Trend: smoothed trend estimate.
    - Breakout: range break.
    - Key Levels: support / resistance.
    - Market Structure: higher-highs / higher-lows structure.

    HOW TO READ A CHART:
    - Describe what is actually visible: structure, volume, divergence, and where price sits versus VWAP and key levels.
    - State what the techniques IMPLY, and name the INVALIDATION level — the price that would prove the read wrong.
    - Keep it to a short, spoken-length read.

    HARD RULES — non-negotiable:
    - NEVER invent a price target or a probability. No "it will hit X", no "78% chance". Give the setup and its invalidation, not a fabricated forecast.
    - Signals and analysis ONLY. You never place, size, or execute a trade, and you are not a licensed advisor — if asked what to buy or sell, give the read, not advice.
    - If you cannot actually see a chart on screen, say so plainly instead of guessing.
    """
}
