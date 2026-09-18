#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — "WHAT MOVED TODAY" daily digest aggregator.
//
// The website promises the buyer can ask, spoken, "what moved today?" and Sovereign reads back
// what actually changed. This is that path — a PURE, deterministic aggregator over the buyer's
// own, real, on-device data. It scans TODAY only and summarizes three real sources:
//
//   1. The proof-of-execution ledger (ActivityLog) — every receipt timestamped today: automation
//      runs, agent runs, skill runs, reminders, connector changes, and the granular tool/MCP
//      execution STEPS those runs made.
//   2. The CRM pipeline (Clients/Deals) — every StageChange dated today: a deal advancing a stage,
//      or a new deal opened (its initial stage). This is the real "what moved" in the pipeline.
//   3. Standing Memory — notes/facts the buyer added today.
//
// ZERO FABRICATION (§5.1): it summarizes ONLY what is really stored. If nothing happened today it
// says so plainly ("Nothing moved today.") — it never invents activity. There is no trading /
// posts / leads subsystem in Sovereign (those are other products), so it never claims those moved.
//
// Pure + nonisolated so the whole thing unit-tests off the main actor against fixed dates.
import Foundation

enum DailyDigest {

    // MARK: - One pipeline change that happened today (a deal advanced, or a new deal opened).
    struct DealMove: Hashable {
        var dealTitle: String
        var clientName: String
        var from: DealStage?     // nil = the deal was OPENED today at `to` (its first stage)
        var to: DealStage
        var at: Date

        var isNew: Bool { from == nil }

        /// Clean-for-speech phrasing — no arrows or symbols that read badly aloud.
        var spokenLine: String {
            let who = clientName.isEmpty ? "" : " for \(clientName)"
            if isNew { return "\(dealTitle)\(who) opened at \(to.label)" }
            return "\(dealTitle)\(who) moved from \(from!.label) to \(to.label)"
        }
        /// Display phrasing for the on-screen digest (markdown line).
        var detailLine: String {
            let who = clientName.isEmpty ? "" : " · \(clientName)"
            if isNew { return "\(dealTitle)\(who) — opened (\(to.label))" }
            return "\(dealTitle)\(who) — \(from!.label) → \(to.label)"
        }
    }

    // MARK: - A count of one ledger receipt kind today.
    struct KindCount: Hashable { var kind: ActivityKind; var count: Int }

    // MARK: - The computed digest.
    struct Summary {
        var dayLabel: String
        var dealMoves: [DealMove]        // pipeline changes today (chronological)
        var receipts: [KindCount]        // top-level receipts today, EXCLUDING .crm (deals covered above)
        var toolCalls: Int               // agent step receipts today — the granular tool/MCP executions
        var notesAdded: Int              // standing-memory items created today

        var receiptTotal: Int { receipts.reduce(0) { $0 + $1.count } }

        /// Honest emptiness: nothing real happened on this device today.
        var isEmpty: Bool {
            dealMoves.isEmpty && receipts.isEmpty && toolCalls == 0 && notesAdded == 0
        }

        /// One-line summary, e.g. "3 deals moved · 2 agent runs · 1 tool call · 1 note added".
        var headline: String {
            isEmpty ? "Nothing moved today." : DailyDigest.clauses(self).joined(separator: " · ")
        }

        /// TTS-friendly prose read aloud by the existing Voice engine. No markdown, no symbols.
        var spoken: String { DailyDigest.spokenText(self) }

        /// Markdown shown in the digest sheet / returned by the agent tool + chat grounding.
        var detailText: String { DailyDigest.detailText(self) }
    }

    // MARK: - The aggregator (pure). Pass the raw value arrays; `now`/`calendar` injectable for tests.

    nonisolated static func build(activity: [ActivityEntry],
                                  clients: [Client],
                                  deals: [Deal],
                                  memories: [MemoryItem],
                                  now: Date = Date(),
                                  calendar: Calendar = .current) -> Summary {
        let isToday: (Date) -> Bool = { calendar.isDate($0, inSameDayAs: now) }

        // 1. CRM pipeline: every StageChange dated today, joined to its client + deal title.
        var moves: [DealMove] = []
        let nameByID = Dictionary(clients.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        for deal in deals {
            for sc in deal.history where isToday(sc.at) {
                moves.append(DealMove(dealTitle: deal.displayTitle,
                                      clientName: nameByID[deal.clientID] ?? "",
                                      from: sc.from, to: sc.to, at: sc.at))
            }
        }
        moves.sort { $0.at < $1.at }

        // 2. Proof-of-execution ledger. Top-level receipts today, grouped by kind — EXCLUDING .crm
        //    (deal moves are reported in full above, so counting the .crm receipt too would double).
        let todayTop = activity.filter { $0.parentID == nil && $0.kind != .crm && isToday($0.at) }
        var byKind: [ActivityKind: Int] = [:]
        for e in todayTop { byKind[e.kind, default: 0] += 1 }
        let receipts = ActivityKind.allCases.compactMap { k -> KindCount? in
            guard let c = byKind[k], c > 0 else { return nil }
            return KindCount(kind: k, count: c)
        }
        // The granular tool/MCP execution steps recorded under agent runs today.
        let toolCalls = activity.filter { $0.parentID != nil && isToday($0.at) }.count

        // 3. Memory notes added today.
        let notesAdded = memories.filter { !$0.trimmed.isEmpty && isToday($0.created) }.count

        let label = now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return Summary(dayLabel: label, dealMoves: moves, receipts: receipts,
                       toolCalls: toolCalls, notesAdded: notesAdded)
    }

    // MARK: - Chat grounding: only injects when the prompt actually asks for the digest.

    /// Conservative detector for "what moved today?"-class prompts. Every trigger names "today" or is
    /// an explicit "digest"/"recap", so a normal chat never pulls the digest in.
    nonisolated static func isDigestQuery(_ prompt: String) -> Bool {
        let p = prompt.lowercased()
        let triggers = [
            "what moved today", "what's moved today", "whats moved today", "moved today",
            "what changed today", "what happened today", "what did i do today",
            "daily digest", "today's digest", "todays digest",
            "recap of today", "today's recap", "todays recap",
            "summary of today", "summarize today", "summarise today", "recap my day"
        ]
        return triggers.contains { p.contains($0) }
    }

    /// Grounding block for ChatScreen — so ANY brain (even a text-only on-device model) answers
    /// "what moved today?" from REAL data. Returns "" unless the prompt is a digest query.
    nonisolated static func grounding(activity: [ActivityEntry],
                                      clients: [Client],
                                      deals: [Deal],
                                      memories: [MemoryItem],
                                      for prompt: String,
                                      now: Date = Date(),
                                      calendar: Calendar = .current) -> String {
        guard isDigestQuery(prompt) else { return "" }
        let s = build(activity: activity, clients: clients, deals: deals, memories: memories,
                      now: now, calendar: calendar)
        return "The user asked what moved/changed today. Here is the REAL daily digest, computed from "
            + "their OWN on-device activity ledger, CRM pipeline, and memory. Answer from THIS only — "
            + "never invent activity, deals, or events that are not listed here:\n\n" + s.detailText
    }

    // MARK: - Text builders (shared by headline / spoken / detail so they never disagree)

    nonisolated static func plural(_ n: Int, _ word: String) -> String {
        "\(n) \(word)\(n == 1 ? "" : "s")"
    }

    /// Readable noun for a ledger kind in the digest.
    nonisolated static func noun(_ kind: ActivityKind) -> String {
        switch kind {
        case .automation: return "automation run"
        case .agent:      return "agent run"
        case .skill:      return "skill run"
        case .reminder:   return "reminder"
        case .connector:  return "connector change"
        case .crm:        return "pipeline change"   // excluded from receipts; here for completeness
        }
    }

    /// The non-empty clauses describing the day, in a stable order.
    nonisolated static func clauses(_ s: Summary) -> [String] {
        var c: [String] = []
        if !s.dealMoves.isEmpty { c.append(plural(s.dealMoves.count, "deal") + " moved") }
        for kc in s.receipts { c.append(plural(kc.count, noun(kc.kind))) }
        if s.toolCalls > 0 { c.append(plural(s.toolCalls, "tool call")) }
        if s.notesAdded > 0 { c.append(plural(s.notesAdded, "note") + " added") }
        return c
    }

    /// "a", "a and b", or "a, b, and c".
    nonisolated static func joinNaturally(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", and " + items.last!
        }
    }

    nonisolated static func spokenText(_ s: Summary) -> String {
        if s.isEmpty {
            return "Nothing moved today. No deals changed, no tasks ran, and no notes were added on this device today."
        }
        var out = "Here's what moved today, \(s.dayLabel). "
        if !s.dealMoves.isEmpty {
            out += plural(s.dealMoves.count, "deal") + " moved. "
            let shown = s.dealMoves.prefix(6).map { $0.spokenLine }
            out += shown.joined(separator: ". ") + ". "
            if s.dealMoves.count > 6 { out += "And \(s.dealMoves.count - 6) more. " }
        }
        var rest: [String] = []
        for kc in s.receipts { rest.append(plural(kc.count, noun(kc.kind))) }
        if s.toolCalls > 0 { rest.append(plural(s.toolCalls, "tool call")) }
        if !rest.isEmpty { out += "Also today: " + joinNaturally(rest) + ". " }
        if s.notesAdded > 0 { out += "You added " + plural(s.notesAdded, "note") + " to memory." }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func detailText(_ s: Summary) -> String {
        var lines: [String] = ["# What moved today", "**\(s.dayLabel)**", ""]
        if s.isEmpty {
            lines.append("**Nothing moved today.** No deals changed, no tasks ran, and no notes were added on this device today.")
            return lines.joined(separator: "\n")
        }
        if !s.dealMoves.isEmpty {
            lines.append("## Pipeline — \(plural(s.dealMoves.count, "deal")) moved")
            for d in s.dealMoves { lines.append("- \(d.detailLine)") }
            lines.append("")
        }
        if !s.receipts.isEmpty || s.toolCalls > 0 {
            lines.append("## Activity")
            for kc in s.receipts { lines.append("- \(plural(kc.count, noun(kc.kind)))") }
            if s.toolCalls > 0 { lines.append("- \(plural(s.toolCalls, "tool call")) (execution steps)") }
            lines.append("")
        }
        if s.notesAdded > 0 {
            lines.append("## Memory")
            lines.append("- \(plural(s.notesAdded, "note")) added today")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif // circuit-convert
