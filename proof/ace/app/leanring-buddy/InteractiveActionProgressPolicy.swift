//
//  InteractiveActionProgressPolicy.swift
//  Ace
//
//  Keeps the visible processing state owned by the active owner action after
//  push-to-talk releases, without overwriting live dictation or a continuing
//  conversational response.
//

import Foundation

enum InteractiveActionProgressPolicy {
    static func shouldHoldProcessing(
        dictationIsIdle: Bool,
        actionIsRunning: Bool
    ) -> Bool {
        dictationIsIdle && actionIsRunning
    }

    static func shouldClearProcessing(
        actionGenerationIsCurrent: Bool,
        currentStateIsProcessing: Bool,
        continuingResponseIsRunning: Bool
    ) -> Bool {
        actionGenerationIsCurrent
            && currentStateIsProcessing
            && !continuingResponseIsRunning
    }
}
