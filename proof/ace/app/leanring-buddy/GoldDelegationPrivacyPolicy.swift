//
//  GoldDelegationPrivacyPolicy.swift
//  Ace
//
//  Keeps model-authored Gold delegation out of private Mail and Messages.
//  Direct owner turns are admitted into the app-owned routes earlier; this
//  boundary exists only to prevent a provider-generated request from gaining
//  authority it did not receive at owner-turn admission.
//

import Foundation

enum GoldDelegationPrivateRoute: Equatable, Sendable {
    case none
    case mail
    case messages
}

enum GoldDelegationPrivacyPolicy {
    static func privateRoute(
        for request: String
    ) -> GoldDelegationPrivateRoute {
        if AppleMessagesIntentPolicy.parse(request) != nil {
            return .messages
        }
        if CrossAppActionPolicy.isExplicitEmailAuthoringRequest(request)
            || CrossAppActionPolicy.isOutboundEmailRequest(request)
            || CrossAppActionPolicy.emailReadRoutingDecision(request)
                != .notReadRequest {
            return .mail
        }
        return .none
    }
}
