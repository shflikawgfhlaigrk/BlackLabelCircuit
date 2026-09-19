import Foundation

/// Active Trading reads current market state from one fresh screen capture.
/// Explicit all-display wording remains authoritative; every narrower or absent
/// generic scope is promoted to the relevant display for a market-data turn.
nonisolated enum TradingModeScreenScopePolicy {
    static func resolvedScope(
        requestedScope: ScreenContextScope,
        isTradingModeActive: Bool,
        requiresMarketData: Bool
    ) -> ScreenContextScope {
        guard isTradingModeActive, requiresMarketData else {
            return requestedScope
        }
        switch requestedScope {
        case .allDisplays:
            return .allDisplays
        case .none, .relevantDisplay:
            return .relevantDisplay
        }
    }
}
