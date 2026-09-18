//
//  VoiceActivationRefreshPolicy.swift
//  Ace
//
//  What returning to Ace (`NSApplication.didBecomeActive`) may do to the
//  voice proof. Pure, so the offline battery pins it without a daemon, an
//  app, or a menu bar.
//

import Foundation

/// Build 62 demanded a FRESH daemon verdict on every activation. A fresh
/// verdict retires the running Nora daemon and cold-starts a replacement, so
/// the founder's live log showed `daemon-generation` climbing 1→8 in two
/// minutes — one respawn per spoken interaction — against the documented
/// contract of ONE persistent daemon warmed once at birth (issue #21).
///
/// A proven voice stays proven: the daemon that already reported its verdict
/// keeps running, and if it ever dies the next utterance restarts and re-proves
/// it lazily (`NoraVoice.ensureDaemonRunning`). Activation only re-proves a
/// voice that is NOT currently proven.
enum VoiceActivationRefreshPolicy {
    enum Action: Equatable, Sendable {
        /// The voice is proven: touch nothing, keep the daemon.
        case keepProvenVoice
        /// A correlated daemon verdict is already in flight: let it land.
        case awaitPendingVerdict
        /// No host proof exists (the first probe never ran, or Stealth cleared
        /// it): probe without retiring any daemon.
        case proveWithoutRestart
        /// The last proof failed: activation is the retry opportunity, and a
        /// retry needs a fresh daemon.
        case retryWithFreshDaemon
    }

    static func action(
        voiceIsReady: Bool,
        verdictIsPending: Bool,
        hostIsProven: Bool
    ) -> Action {
        if voiceIsReady {
            return .keepProvenVoice
        }
        if verdictIsPending {
            return hostIsProven ? .awaitPendingVerdict : .proveWithoutRestart
        }
        return .retryWithFreshDaemon
    }
}
