//
//  AcePanelVisualTarget.swift
//  Ace
//
//  Exact app-owned targets whose live NSView geometry can drive the gold gem
//  without asking Accessibility to introspect Ace's own process.
//

import Foundation

nonisolated enum AcePanelVisualTarget: String, Hashable, Sendable {
    case tradingModeToggle
    case stealthEntry
}

nonisolated enum AcePanelVisualTargetPolicy {
    static func target(for exactDescription: String)
        -> AcePanelVisualTarget? {
        let ignoredWords: Set<String> = [
            "the", "a", "an", "button", "control", "toggle",
        ]
        let words = exactDescription
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .unicodeScalars
            .map {
                CharacterSet.alphanumerics.contains($0)
                    ? String($0) : " "
            }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !ignoredWords.contains($0) }
            .joined(separator: " ")

        switch words {
        case "enter trading mode", "exit trading mode", "trading mode":
            return .tradingModeToggle
        case "go stealth", "stealth entry":
            return .stealthEntry
        default:
            return nil
        }
    }
}
