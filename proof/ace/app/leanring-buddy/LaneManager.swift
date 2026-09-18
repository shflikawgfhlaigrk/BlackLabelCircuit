//
//  LaneManager.swift
//  leanring-buddy
//
//  Ported from utah-Ace 2026-07-26 (founder: "port all of it"). Additive
//  coordination + display-truth layer; bridged from the existing subsystems'
//  publishers in CompanionManager.
//
//  The shipping Ace ran one brain behind a flat keyword router, with one global
//  "busy" flag and a single trailing gem that was red XOR blue. Utah splits that
//  into lanes: independent capabilities that run in parallel, each with its own
//  gem, its own busy state, and (later) its own context + tools.
//
//    gold   — foreground conversational cursor (the primary gem)
//    red    — first background execution slot
//    blue   — meeting notetaker (simple but continuous)
//    purple — trading (on-demand observing agent)
//    silver — exclusive second-background/workflow slot (internal ID: green)
//
//  This does NOT replace CompanionManager's routing. It sits alongside as the
//  coordination + display-truth layer: existing subsystems (BackgroundAgent,
//  MeetingNotetaker) are bridged in through their existing publishers, so the
//  change to the shipping state machine is additive, not a rewrite.
//
//  Two things the old flat design conflated, now owned here:
//    • Per-lane busy — "busy" is per lane, not one global flag. Gold-while-red is
//      fine; one second task can occupy Silver, while a third is refused.
//    • Stealth exclusivity — stealth kills every lane and goes observe-only.
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

enum LaneGemVisualIdentity: Equatable {
    case gold
    case red
    case blue
    case purple
    case silver
}

/// The five lanes. Gold is the primary cursor; the rest are trailing indicator
/// gems that cluster around it.
enum LaneID: String, CaseIterable {
    case gold, red, blue, purple, green

    /// Gold is the cursor itself; red/blue/purple/green render as trailing gems.
    var isBackgroundLane: Bool { self != .gold }

    /// How the voice names this lane when it frames a delayed announcement
    /// ("the background agent came back and finished that").
    var spokenName: String {
        switch self {
        case .gold:   return "assistant"
        case .red:    return "background agent"
        case .blue:   return "notetaker"
        case .purple: return "trading"
        case .green:  return "build"
        }
    }

    var gemVisualIdentity: LaneGemVisualIdentity {
        switch self {
        case .gold:   return .gold
        case .red:    return .red
        case .blue:   return .blue
        case .purple: return .purple
        case .green:  return .silver
        }
    }
}

enum MeetingLaneVisualState {
    static func isActive(
        isTakingNotes: Bool,
        isStartingUp: Bool
    ) -> Bool {
        isTakingNotes || isStartingUp
    }
}

@MainActor
final class LaneManager: ObservableObject {

    /// Lanes currently lit — a lane is "active" while its work is live (red
    /// working, blue capturing, purple in trading mode, gold mid-exchange).
    /// For the per-lane-busy rule, active == busy.
    @Published private(set) var activeLanes: Set<LaneID> = []

    /// Stealth: the exclusive observe-only mode. While true, all lanes are stood
    /// down, the gems hide, and the voice is gated. It is not a lane — it is the
    /// absence of lanes plus passive observation.
    @Published private(set) var stealthActive = false

    // MARK: Lane state

    /// Reflect a lane's live state. Called by the CompanionManager bridge from the
    /// subsystems' own publishers, and directly for the new lanes (purple/gold).
    func setLane(_ lane: LaneID, active: Bool) {
        var next = activeLanes
        if active { next.insert(lane) } else { next.remove(lane) }
        if next != activeLanes { activeLanes = next }
    }

    func isActive(_ lane: LaneID) -> Bool { activeLanes.contains(lane) }

    /// Per-lane busy gate: a lane can be entered only when it isn't already active
    /// (and not while stealthed). Lanes never block *each other* — only a lane
    /// blocks its own re-entry.
    func canActivate(_ lane: LaneID) -> Bool {
        !stealthActive && !activeLanes.contains(lane)
    }

    /// Background lanes to render as trailing gems, in a stable order so the
    /// cluster doesn't reshuffle as lanes toggle. Empty while stealthed.
    var litBackgroundLanes: [LaneID] {
        guard !stealthActive else { return [] }
        return LaneID.allCases.filter { $0.isBackgroundLane && activeLanes.contains($0) }
    }

    // MARK: Stealth (exclusive)

    /// Enter stealth: kill every lane, then observe. CompanionManager is
    /// responsible for actually standing the subsystems down; clearing the set
    /// here hides the gems immediately.
    func enterStealth() {
        activeLanes.removeAll()
        stealthActive = true
    }

    /// Leave stealth. Lanes repopulate as their subsystems re-report through the
    /// bridge.
    func exitStealth() {
        stealthActive = false
    }
}
