#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing (lead engine, merged from Black Label Leads) — Funnel & conversion visualizer (Tier-3).
// A real, grounded funnel computed live over the buyer's OWN deals + their configured pipeline stages.
// "Reached" is cumulative (a deal at a deeper stage also reached every earlier stage), which is how a
// sales funnel narrows: each band can only be ≤ the one above it. Conversion rates are honest — an
// empty pipeline yields zeros, never NaN/fabricated numbers. Pure functions only, no network.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - one stage band in the funnel
struct FunnelStageReport: Identifiable, Hashable {
    var id: UUID { stage.id }
    let stage: DealStage
    let index: Int
    /// Deals currently sitting IN this stage.
    let current: Int
    /// Deals that REACHED this stage or deeper (cumulative) — the funnel-band width.
    let reached: Int
    /// % of the previous stage's `reached` that made it to this stage (step conversion). First stage = 100% of entered.
    let stepConversionPct: Double
    /// % of all entered deals that reached this stage (top-line width vs the funnel mouth).
    let reachedPct: Double
    /// Drop-off from the previous stage (count that did NOT advance). 0 for the first stage.
    let droppedFromPrev: Int
    /// Sum of deal value sitting in this stage (real, never fabricated).
    let valueInStage: Double
}

// MARK: - the whole funnel report
struct FunnelReport {
    let stages: [FunnelStageReport]
    /// Total deals that entered the funnel (every deal counts at the mouth).
    let totalEntered: Int
    /// Deals that landed in a `won` terminal stage.
    let totalWon: Int
    /// Deals that landed in a `lost` terminal stage.
    let totalLost: Int
    /// Overall conversion = won / entered (the headline number). Honest 0 when nothing entered.
    let overallConversionPct: Double
    /// The open-stage name with the largest drop-off (where deals stall) — nil when empty/trivial.
    let biggestDropStageName: String?
    /// Total value still in open (non-terminal) stages.
    let openPipelineValue: Double
    /// Total value won.
    let wonValue: Double

    /// Build the funnel from raw deals + the configured stage order.
    /// Funnel order follows the buyer's stage order, but terminal `lost` stages are placed last as
    /// an exit (a lost deal didn't "reach" Won — it exited). Won is treated as the funnel floor.
    static func build(deals: [Deal], stages: [DealStage], leads: [Lead]) -> FunnelReport {
        // Map each deal to the index of its stage in the configured order.
        let stageIndex = Dictionary(uniqueKeysWithValues: stages.enumerated().map { ($0.element.id, $0.offset) })
        let entered = deals.count

        // current[i] = deals sitting in stage i; value[i] = their value sum.
        var current = Array(repeating: 0, count: stages.count)
        var value = Array(repeating: 0.0, count: stages.count)
        for d in deals {
            guard let i = stageIndex[d.stageID] else { continue }
            current[i] += 1; value[i] += d.value
        }

        // "Reached" is cumulative along the FORWARD funnel path. The subtlety: a `lost` deal EXITS the
        // funnel — it reached every stage up to where it was lost, but it did NOT advance to Won. So a
        // Lost deal must not count toward reaching Won (or any stage beyond its lost point). We model
        // each deal's "depth" as: open stage → its own index; lost stage → the index of the lost stage
        // itself (it reached that exit but progressed no further toward Won); won stage → its index.
        // reached[i] = count of deals whose effective depth >= i, BUT a lost deal never contributes to
        // a `won` terminal band, and a won deal never contributes to a `lost` band.
        var reached = Array(repeating: 0, count: stages.count)
        for i in 0..<stages.count {
            let bandKind = stages[i].terminal
            var r = 0
            for d in deals {
                guard let di = stageIndex[d.stageID] else { continue }
                let dealKind = stages[di].terminal
                // A lost deal does not count toward a won band; a won deal does not count toward a lost band.
                if bandKind == .won && dealKind == .lost { continue }
                if bandKind == .lost && dealKind == .won { continue }
                if di >= i { r += 1 }
            }
            reached[i] = r
        }

        var rows: [FunnelStageReport] = []
        for (i, stage) in stages.enumerated() {
            let prevReached = i == 0 ? entered : reached[i - 1]
            let step = prevReached > 0 ? Double(reached[i]) / Double(prevReached) * 100 : 0
            let reachedPct = entered > 0 ? Double(reached[i]) / Double(entered) * 100 : 0
            let dropped = i == 0 ? 0 : max(0, reached[i - 1] - reached[i])
            rows.append(FunnelStageReport(stage: stage, index: i, current: current[i], reached: reached[i],
                                          stepConversionPct: step, reachedPct: reachedPct,
                                          droppedFromPrev: dropped, valueInStage: value[i]))
        }

        let won = stages.enumerated().filter { $0.element.terminal == .won }.reduce(0) { $0 + current[$1.offset] }
        let lost = stages.enumerated().filter { $0.element.terminal == .lost }.reduce(0) { $0 + current[$1.offset] }
        let wonVal = stages.enumerated().filter { $0.element.terminal == .won }.reduce(0.0) { $0 + value[$1.offset] }
        let openVal = stages.enumerated().filter { $0.element.terminal == .open }.reduce(0.0) { $0 + value[$1.offset] }
        let overall = entered > 0 ? Double(won) / Double(entered) * 100 : 0

        // Biggest drop among OPEN stages (where deals stall before terminal) — grounded, nil if trivial.
        let openDrops = rows.filter { $0.stage.terminal == .open && $0.index > 0 && $0.droppedFromPrev > 0 }
        let biggest = openDrops.max { $0.droppedFromPrev < $1.droppedFromPrev }?.stage.name

        return FunnelReport(stages: rows, totalEntered: entered, totalWon: won, totalLost: lost,
                            overallConversionPct: overall, biggestDropStageName: biggest,
                            openPipelineValue: openVal, wonValue: wonVal)
    }
}
#endif // circuit-convert
