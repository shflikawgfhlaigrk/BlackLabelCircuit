// Sovereign — CUSTOM AGENT BUILDER (tier-4).
//
// The buyer defines their own agent in natural language: a name, a role/instructions block, and
// which of the safe local tools it may use. The agent then runs through the SAME real plan→act→
// verify loop (AgentEngine) with its tool surface restricted to the buyer's allowlist. Persisted
// on-device. Nothing about an agent is fabricated — it's exactly what the buyer wrote.
//
// HONESTY: a custom agent can never grant itself more power than the app's real tool surface. The
// allowlist is intersected with the tools that actually exist, so a saved agent referencing a tool
// that isn't available simply doesn't get it (and the UI shows which tools are wired).
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

/// The catalog of real, safe tools a custom agent may be granted. The id is the tool name the
/// AgentEngine dispatches on; nothing here is aspirational — each maps to a wired implementation.
enum AgentTool: String, Codable, CaseIterable, Identifiable {
    case searchKnowledge = "search_knowledge"
    case recallMemory    = "recall_memory"
    case lookupClient    = "lookup_client"
    case dailyDigest     = "daily_digest"
    case saveNote        = "save_note"
    case readCalendar    = "read_calendar"
    case searchFiles     = "search_files"
    case fetchURL        = "fetch_url"
    case useConnectors   = "use_connectors"
    case operateUI       = "operate_ui"
    case visualControl   = "visual_control"
    case recentActivity  = "recent_activity"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .searchKnowledge: return "Search Knowledge & Files"
        case .recallMemory:    return "Recall Memory"
        case .lookupClient:    return "Look up Clients & Pipeline"
        case .dailyDigest:     return "What Moved Today (daily digest)"
        case .saveNote:        return "Save a Note (memory)"
        case .readCalendar:    return "Read Calendar"
        case .searchFiles:     return "Search Files"
        case .fetchURL:        return "Fetch a Web Page"
        case .useConnectors:   return "Use Connected Tools (MCP)"
        case .operateUI:       return "Operate Apps (Accessibility)"
        case .visualControl:   return "Operate Visual Surfaces"
        case .recentActivity:  return "Recent On-Screen Context"
        }
    }
    var blurb: String {
        switch self {
        case .searchKnowledge: return "Read the buyer's own documents & indexed files for grounding."
        case .recallMemory:    return "Recall the buyer's standing saved memories."
        case .lookupClient:    return "Look up the buyer's saved client records & deal pipeline (history + stages)."
        case .dailyDigest:     return "Summarize what really moved today — deals that changed stage, activity receipts, and notes added."
        case .saveNote:        return "Write a short fact into the buyer's Memory (confirmation-gated)."
        case .readCalendar:    return "Read the buyer's upcoming calendar events (if the connector is on)."
        case .searchFiles:     return "Keyword-search the buyer's granted folders."
        case .fetchURL:        return "Fetch the readable text of a web page the buyer's agent names."
        case .useConnectors:   return "Discover + call tools on the buyer's OWN connected MCP servers (confirmation-gated)."
        case .operateUI:       return "Read + act on the buyer's macOS apps via Accessibility — every step passes the approval dial and the payment/send/delete deny-list."
        case .visualControl:   return "Inspect numbered on-screen controls and use approved pointer/keyboard input when Accessibility cannot address the target."
        case .recentActivity:  return "Recall the buyer's recent on-screen context — which apps/windows/sites they worked in — from the private, local ambient timeline (read-only)."
        }
    }
    var icon: String {
        switch self {
        case .searchKnowledge: return "doc.text.magnifyingglass"
        case .recallMemory:    return "brain.head.profile"
        case .lookupClient:    return "person.crop.rectangle.stack.fill"
        case .dailyDigest:     return "sun.max.fill"
        case .saveNote:        return "square.and.pencil"
        case .readCalendar:    return "calendar"
        case .searchFiles:     return "folder.fill.badge.questionmark"
        case .fetchURL:        return "globe"
        case .useConnectors:   return "puzzlepiece.extension.fill"
        case .operateUI:       return "cursorarrow.rays"
        case .visualControl:   return "scope"
        case .recentActivity:  return "clock.arrow.circlepath"
        }
    }
    /// Tools that PERFORM a side effect / reach outside the buyer's own local data — must be
    /// confirmation-gated before they run. Both UI-control tools route through the control arbiter
    /// and its single Manual/Auto/Skip decision, not the generic tool-confirmation path.
    var requiresConfirmation: Bool {
        switch self {
        case .saveNote, .fetchURL, .useConnectors, .operateUI, .visualControl: return true
        default: return false
        }
    }
}

/// A buyer-authored agent definition.
struct CustomAgent: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "New agent"
    var blurb: String = ""                 // one-line description (buyer's words)
    var instructions: String = ""          // the role/system block — what this agent is for
    var tools: [AgentTool] = [.searchKnowledge, .recallMemory]
    var icon: String = "person.crop.circle.badge.checkmark"
    var created = Date()

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isValid: Bool { !trimmedName.isEmpty && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The effective system prompt for a run: the buyer's instructions + the honest operating frame
    /// that keeps the agent grounded (no fabrication, verify before answering). Pure → testable.
    func systemPrompt(base: String) -> String {
        let role = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = """
        You are "\(trimmedName)", a focused agent. PLAN briefly, ACT using only the tools you have \
        to gather real information from the user's own data, then VERIFY against what the tools \
        returned before answering. Never invent file contents, events, memories, or results — if a \
        tool returns nothing, say so honestly.
        """
        return base.isEmpty ? "\(frame)\n\nYour role:\n\(role)" : "\(base)\n\n\(frame)\n\nYour role:\n\(role)"
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class CustomAgentStore: ObservableObject {
    @Published var agents: [CustomAgent] = [] { didSet { persist() } }
    private let d = UserDefaults.standard
    private let key = "com.blacklabel.sovereign.customagents.v1"
    /// Demo Mode: keep synthetic sample agents in memory only, never in UserDefaults.
    private var demoEphemeral = false

    init() {
        // the @Published assignment routes through the wrapper's setter, so didSet→persist WOULD
        // fire here — suppress it: loading (or seeding) must never itself write (ship-no-data §5.2)
        demoEphemeral = true
        agents = Self.loadOrSeed(from: d, key: key)
        demoEphemeral = false
    }

    /// Buyer's saved agents if a payload has EVER been written; otherwise the prebuilt catalog —
    /// in memory only (ship-no-data §5.2: nothing touches disk until the buyer's first real edit).
    /// The first edit persists whatever remains, so a buyer who deletes the prebuilts writes an
    /// empty list and never sees them forced back.
    private static func loadOrSeed(from d: UserDefaults, key: String) -> [CustomAgent] {
        let data = d.data(forKey: key)
        if PrebuiltAgents.shouldSeed(hasStoredPayload: data != nil) { return PrebuiltAgents.all }
        guard let data, let a = try? JSONDecoder().decode([CustomAgent].self, from: data) else { return [] }
        return a
    }
    private func persist() {
        guard !demoEphemeral else { return }
        if let data = try? JSONEncoder().encode(agents) { d.set(data, forKey: key) }
    }
    func upsert(_ a: CustomAgent) {
        if let i = agents.firstIndex(where: { $0.id == a.id }) { agents[i] = a }
        else { agents.insert(a, at: 0) }
    }
    func delete(_ a: CustomAgent) { agents.removeAll { $0.id == a.id } }

    /// Seed clearly-labeled SAMPLE custom agents for Demo Mode — in memory only. Idempotent.
    func seedDemo() {
        demoEphemeral = true   // ephemeral first → real agents in UserDefaults untouched; restored by endDemo()
        agents = DemoSeed.customAgents
    }
    /// Leave Demo Mode: drop sample agents, restore the buyer's real on-disk agents (or the
    /// prebuilt catalog on a never-edited install), re-enable saves.
    func endDemo() {
        demoEphemeral = true
        agents = Self.loadOrSeed(from: d, key: key)
        demoEphemeral = false
    }

    /// Permanently erase ALL of the buyer's custom agents — in memory and on disk
    /// (App Store Guideline 5.1.1(v)). Persistence is re-enabled so the empty state is written.
    func wipeAll() {
        demoEphemeral = false
        agents = []
    }
}
#endif // circuit-convert
