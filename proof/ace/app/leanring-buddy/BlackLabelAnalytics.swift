//
//  BlackLabelAnalytics.swift
//  leanring-buddy
//
//  Analytics are intentionally disabled in Black Label Assistant. The upstream
//  base shipped a PostHog integration that reported every launch, message, and
//  error to a third-party account. This product sends no telemetry anywhere, so
//  every method here is a deliberate no-op that keeps the existing call sites
//  compiling without emitting anything.
//

import Foundation

enum BlackLabelAnalytics {
    static func configure() {}

    static func trackAppOpened() {}

    static func trackOnboardingStarted() {}
    static func trackOnboardingReplayed() {}
    static func trackOnboardingVideoCompleted() {}
    static func trackOnboardingDemoTriggered() {}

    static func trackAllPermissionsGranted() {}
    static func trackPermissionGranted(permission: String) {}

    static func trackPushToTalkStarted() {}
    static func trackPushToTalkReleased() {}
    static func trackUserMessageSent(transcript: String) {}
    static func trackAIResponseReceived(response: String) {}
    static func trackElementPointed(elementLabel: String?) {}

    static func trackResponseError(error: String) {}
    static func trackTTSError(error: String) {}
}
