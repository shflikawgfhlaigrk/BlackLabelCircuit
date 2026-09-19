#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — MULTI-STEP AGENTIC EXECUTION (plan → act → verify).
//
// Single-shot chat answers a question. An AGENT pursues a goal: it plans, takes real steps
// using a small, SAFE, local tool surface, observes results, and verifies before declaring
// done. This runs on the buyer's own External API/OAuth account (tool use requires Anthropic's
// structured tool protocol) — on-device, external CLI, and Secondary CLI are text-only here, so the UI
// says so honestly when that brain cannot drive tools.
//
// PROOF-OF-EXECUTION (the standard's differentiator): every tool the agent runs writes a real
// RECEIPT (what it did, the actual result) into a transcript the buyer can review. Nothing is
// narrated as done unless a tool actually returned a result. No fabricated work.
//
// TOOL SURFACE (all over the buyer's OWN data, or confirmation-gated for side effects):
//   search_knowledge — read the buyer's Knowledge docs + indexed files (RAG)
//   recall_memory    — read the buyer's standing saved memories
//   read_calendar    — read the buyer's upcoming events (only if the Calendar connector is on)
//   search_files     — keyword-search the buyer's granted folders
//   save_note        — write a fact to Memory (CONFIRMATION-GATED)
//   fetch_url        — fetch readable text of a public web page (CONFIRMATION-GATED)
//
// A CUSTOM AGENT restricts this surface to the buyer's allowlist and runs with the buyer's own
// instructions — same real loop, same receipts.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

/// One recorded step in an agent run — a real receipt, never a narration.
struct AgentStep: Identifiable, Hashable {
    enum Kind: String { case thought, toolCall, toolResult, answer, error, awaitingConfirm }
    let id = UUID()
    let kind: Kind
    let title: String
    let detail: String
    let at = Date()
}

/// The status of an agent run, for honest UI.
enum AgentRunStatus: Equatable {
    case idle, planning, acting, verifying, done, failed(String), unavailable(String)
    case awaitingConfirmation(String)   // a side-effect/external tool needs the buyer's OK
}

/// A pending confirmation-gated tool call, surfaced to the UI before it runs.
struct PendingToolApproval: Identifiable, Equatable {
    let id = UUID()
    let toolName: String
    let summary: String          // human description of what's about to happen
}

@MainActor
final class AgentEngine: ObservableObject {
    @Published var status: AgentRunStatus = .idle
    @Published var steps: [AgentStep] = []
    @Published var finalAnswer: String = ""
    @Published var pendingApproval: PendingToolApproval?

    private weak var router: BrainRouter?
    private weak var store: Store?
    private weak var memory: MemoryStore?
    private weak var calendar: CalendarConnector?
    private weak var files: FilesConnector?
    private weak var activity: ActivityLog?
    private weak var mcp: MCPManager?
    private weak var crm: ClientStore?
    /// The shared OPERATOR grant engine (SV-22). The agent loop invokes the operator ONLY through
    /// this — its Manual/Auto/Skip dial + hard deny-list is the single policy for cross-app actions,
    /// so there is never a second, divergent gate. nil = the operator tool is unavailable this run.
    private weak var operatorEngine: OperatorEngine?
    /// Owns both UI routes for this run. The arbiter plans semantic-first and executes one engine;
    /// the agent never invokes the pixel driver or OperatorEngine directly.
    private var controlArbiter: ControlArbiter?
    private var runTask: Task<Void, Never>?
    private var runGoal: String = ""
    private var runStartedAt: Date?
    /// The id of THIS run's terminal receipt. Generated at start so every per-step receipt can be
    /// linked to its parent run BEFORE the terminal receipt is written. This is what makes the
    /// full agent trace (each tool call + its real observation) survive the run in the ledger.
    private var runID = UUID()

    // The tool surface for THIS run (a custom agent narrows it). Default = everything safe.
    private var allowedTools: Set<AgentTool> = Set(AgentTool.allCases)
    private var runSystem: String = ""
    /// model-facing MCP tool name -> (server, tool). Rebuilt by `toolDefs()` each run so dispatch
    /// can route a External tool_use back to the buyer's real server. Empty unless `.useConnectors`.
    private var mcpRoutes: [String: (server: String, tool: String)] = [:]

    // Continuation machinery for confirmation-gated tools.
    private var approvalContinuation: CheckedContinuation<Bool, Never>?

    // GUARDRAILS: the buyer's safety posture for THIS run, captured at start. The deterministic
    // policy engine (Guardrails) classifies every side-effecting tool call and the loop ENFORCES the
    // decision before the tool runs. `guardrailPostureOverride` lets tests/advanced callers pin a
    // posture; when nil the engine reads the live buyer posture mirrored from Settings.
    var guardrailPostureOverride: GuardrailPosture? = nil
    private var runPosture: GuardrailPosture = .confirmSideEffects

    /// Hard ceiling so a run can never loop forever (and never silently burn the buyer's tokens).
    static let maxIterations = 8
    private var runPrefersAllAllowedLocalTools = false

    /// The local/text-brain fallback cannot ask a model to choose structured tools, so it runs a
    /// deterministic, read-only receipt set first. Side-effecting/external tools stay reserved for
    /// the API/OAuth structured-tool loop.
    static func localReadOnlyToolNames(for goal: String, allowedTools: Set<AgentTool>,
                                       includeAllAllowed: Bool = false) -> [String] {
        let readOnlyOrder: [AgentTool] = [.recallMemory, .searchKnowledge, .dailyDigest,
                                          .readCalendar, .lookupClient, .searchFiles]
        var chosen: [AgentTool] = []
        func add(_ tool: AgentTool) {
            guard allowedTools.contains(tool), !chosen.contains(tool) else { return }
            chosen.append(tool)
        }

        if includeAllAllowed {
            readOnlyOrder.forEach(add)
            return chosen.map(\.rawValue)
        }

        let lower = goal.lowercased()
        add(.recallMemory)
        add(.searchKnowledge)
        if Self.goal(lower, containsAny: ["today", "moved", "changed", "morning", "brief", "daily", "recap"]) { add(.dailyDigest) }
        if Self.goal(lower, containsAny: ["calendar", "schedule", "meeting", "week", "availability", "appointment"]) { add(.readCalendar) }
        if Self.goal(lower, containsAny: ["client", "customer", "deal", "pipeline", "follow-up", "follow up", "lead"]) { add(.lookupClient) }
        if Self.goal(lower, containsAny: ["file", "files", "document", "doc", "spec", "folder", "search", "find"]) { add(.searchFiles) }
        if chosen.isEmpty { readOnlyOrder.forEach { if chosen.isEmpty { add($0) } } }
        return chosen.map(\.rawValue)
    }

    private static func goal(_ lower: String, containsAny needles: [String]) -> Bool {
        needles.contains { lower.contains($0) }
    }

    func attach(router: BrainRouter, store: Store, memory: MemoryStore,
                calendar: CalendarConnector? = nil, files: FilesConnector? = nil,
                activity: ActivityLog? = nil, mcp: MCPManager? = nil, crm: ClientStore? = nil,
                operatorEngine: OperatorEngine? = nil) {
        self.router = router; self.store = store; self.memory = memory
        self.calendar = calendar; self.files = files; self.activity = activity
        self.mcp = mcp; self.crm = crm; self.operatorEngine = operatorEngine
        if let operatorEngine {
            let arbiter = ControlArbiter(operatorEngine: operatorEngine)
            if let activity { arbiter.attach(activity: activity) }
            self.controlArbiter = arbiter
        } else {
            self.controlArbiter = nil
        }
    }

    /// Record ONE terminal proof-of-execution receipt for the just-finished run, using the
    /// pre-generated `runID` as its id so the per-step receipts written during the run link to it.
    /// Called from every terminal path (done / failed / step-limit) so the ledger never narrates
    /// fake work and never misses a real run. The detail is the agent's REAL final answer or error.
    private func recordReceipt(outcome: ActivityOutcome, detail: String) {
        let ms = runStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
        let title = runGoal.isEmpty ? "Agent run" : String(runGoal.prefix(80))
        var head = ActivityEntry(id: runID, kind: .agent, title: title, detail: detail,
                                 outcome: outcome, durationMS: ms)
        head.stepCount = activity?.steps(of: runID).count ?? steps.count
        activity?.record(head)
    }

    /// Record ONE real per-step receipt for a tool call + its actual observation, linked to this
    /// run. No narration: a step receipt exists only because a tool truly returned a result.
    private func recordStepReceipt(tool: String, display: String, output: String) {
        let detail = display.isEmpty ? output : "\(display)\n\n\(output)"
        activity?.recordStep(parentID: runID, title: "Tool · \(tool)", detail: detail, outcome: .info)
    }

    /// PROOF-OF-EXECUTION for a guardrail policy decision: persists ONE real receipt (linked to the
    /// run) for a block, a confirmation demand, or an auto-allowed side-effect. Read-only allows are
    /// not logged here (they're captured by the tool's own step receipt). A block is recorded as a
    /// `.failure` step — the honest record that the action was prevented and did NOT run.
    private func recordGuardrailReceipt(_ decision: GuardrailDecision, _ action: Guardrails.PendingAction) {
        guard let r = Guardrails.receipt(for: decision, action: action) else { return }
        activity?.recordStep(parentID: runID, title: r.title, detail: r.detail,
                             outcome: r.isFailure ? .failure : .info)
    }

    /// Apply the guardrail decision at the moment a side-effecting tool is about to run. Auto-allow
    /// (autonomous posture) proceeds silently but writes an audit receipt; confirm prompts the buyer;
    /// block is handled earlier in `runTool` and never reaches here. Returns whether to PROCEED.
    private func passesGate(_ decision: GuardrailDecision, action: Guardrails.PendingAction,
                            tool: String, summary: String) async -> Bool {
        recordGuardrailReceipt(decision, action)
        switch decision {
        case .allow:   return true                                   // autonomous — audited, no prompt
        case .confirm: return await awaitApproval(tool: tool, summary: summary)
        case .block:   return false                                  // defensive; block caught upstream
        }
    }

    /// The local, safe tool DEFINITIONS sent to External, restricted to the run's allowlist.
    private func toolDefs() -> [[String: Any]] {
        var defs: [[String: Any]] = []
        if allowedTools.contains(.searchKnowledge) {
            defs.append(["name": "search_knowledge",
             "description": "Search the user's own Knowledge documents AND indexed files for relevant excerpts. Use this to ground answers in the user's own data before relying on general knowledge.",
             "input_schema": ["type": "object",
                              "properties": ["query": ["type": "string", "description": "What to look for"]],
                              "required": ["query"]]])
        }
        if allowedTools.contains(.recallMemory) {
            defs.append(["name": "recall_memory",
             "description": "Recall the user's saved standing memories (their stated facts, preferences, ongoing projects).",
             "input_schema": ["type": "object", "properties": [:]]])
        }
        if allowedTools.contains(.lookupClient) {
            defs.append(["name": "lookup_client",
             "description": "Look up the user's own saved CLIENT records and DEAL PIPELINE. Pass a client name or company to get that client's contact details, notes, and every deal with its current stage, value, next action, and stage-change history. Omit the query to get a summary of the whole pipeline. Use this for questions about a client's status or history, or the deal pipeline.",
             "input_schema": ["type": "object",
                              "properties": ["client": ["type": "string", "description": "Client name or company to look up (optional; omit for the whole pipeline)"]]]])
        }
        if allowedTools.contains(.dailyDigest) {
            defs.append(["name": "daily_digest",
             "description": "Summarize what MOVED on the user's machine TODAY: deals that changed stage in their CRM pipeline (and any deal opened today), real proof-of-execution receipts from today (automations, agent runs, skills, reminders, connector changes) plus the tool/MCP execution steps those runs made, and notes added to standing Memory today. Use when the user asks 'what moved today', 'what changed today', or wants a daily recap. Returns an honest 'Nothing moved today.' when there was no activity. Reads only the user's own local data — never invents activity.",
             "input_schema": ["type": "object", "properties": [:]]])
        }
        if allowedTools.contains(.recentActivity) {
            defs.append(["name": "recent_activity",
             "description": "Recall the user's RECENT on-screen context from Sovereign's private, LOCAL ambient timeline: which apps, windows, and web sites they were working in, newest first, captured on their own machine via Accessibility. Use when the goal references 'what I was just doing', 'the thing on my screen', the current task, or needs grounding in the user's live work. Reads only the user's own local timeline — never invents activity; returns an honest empty note when nothing was captured.",
             "input_schema": ["type": "object",
                              "properties": ["detail": ["type": "boolean", "description": "true to include the deep element context per window (verbose); default false"]]]])
        }
        if allowedTools.contains(.readCalendar) {
            defs.append(["name": "read_calendar",
             "description": "Read the user's REAL upcoming calendar events for the next N days from their own Calendar. Use when the goal involves scheduling, availability, or what's coming up.",
             "input_schema": ["type": "object",
                              "properties": ["days": ["type": "integer", "description": "How many days ahead to look (1-30)"]]]])
        }
        if allowedTools.contains(.searchFiles) {
            defs.append(["name": "search_files",
             "description": "Keyword-search the user's granted local folders for files whose name or contents match. Returns file paths and snippets of real content.",
             "input_schema": ["type": "object",
                              "properties": ["query": ["type": "string", "description": "Keyword or phrase to find in the user's files"]],
                              "required": ["query"]]])
        }
        if allowedTools.contains(.saveNote) {
            defs.append(["name": "save_note",
             "description": "Save a short fact to the user's standing Memory so it is remembered in future conversations. Use only when the user clearly wants something remembered. Requires the user's confirmation.",
             "input_schema": ["type": "object",
                              "properties": ["text": ["type": "string", "description": "The fact to remember"]],
                              "required": ["text"]]])
        }
        if allowedTools.contains(.fetchURL) {
            defs.append(["name": "fetch_url",
             "description": "Fetch the readable text of a PUBLIC web page by URL. Use only when the goal needs information from a specific page the user named. Requires the user's confirmation.",
             "input_schema": ["type": "object",
                              "properties": ["url": ["type": "string", "description": "The full http(s) URL to fetch"]],
                              "required": ["url"]]])
        }
        // The OPERATOR (SV-22): the agent can read + act across the buyer's macOS apps via
        // Accessibility. This is registered as a tool ONLY when an OperatorEngine is wired (macOS
        // app) AND the run's allowlist grants it. Its gating is NOT the generic tool-confirmation
        // path — every proposed step flows through the operator's Manual/Auto/Skip dial + hard
        // deny-list (payment/send/delete), so the loop can never auto-click a consequential control.
        if allowedTools.contains(.operateUI), operatorEngine != nil {
            defs.append(["name": "operate_ui",
             "description": "Operate the user's Mac apps through macOS Accessibility, on their machine, with their grant. Use action \"read\" to OBSERVE the on-screen element graph before acting; \"press\" to click a control; \"setValue\" to type a value into the focused field; \"focus\" to raise/focus an element. Every action passes the user's approval dial (Manual = approve each step, Auto = allowlisted actions run, Skip = watch only) and a HARD deny-list that NEVER auto-acts on a payment, send, or delete control. Before it acts the operator reads the REAL focused control and re-checks it against the deny-list, so a payment/send/delete surface is caught even if you didn't name it. Prefer 'read' first, then act on what you actually saw. Nothing runs silently — each step is written to the activity log.",
             "input_schema": ["type": "object",
                              "properties": [
                                "action": ["type": "string", "enum": ["read", "press", "setValue", "focus"],
                                           "description": "read (observe only, never mutates), press (click), setValue (type into the focused field), or focus"],
                                "app": ["type": "string", "description": "Display name of the target app (e.g. \"TextEdit\"), for the approval prompt + deny-list context"],
                                "target": ["type": "string", "description": "The visible label of the control being acted on (e.g. \"Save\", \"Send\") — drives the deny-list check and the receipt"],
                                "value": ["type": "string", "description": "For setValue only: the text to type into the focused field"]],
                              "required": ["action"]]])
        }
        if allowedTools.contains(.visualControl), controlArbiter != nil {
            defs.append(["name": "visual_control",
             "description": "Inspect and operate visual Mac surfaces through Sovereign's semantic-first control arbiter. Call action=inspect first; it returns a short-lived observation_id and numbered controls. For an action, send that observation_id plus a mark, or x/y coordinates tied to that observation. The arbiter chooses Accessibility whenever the observed control supports it and uses pixel input only when semantics cannot perform the gesture. The two engines never both act. Manual asks before every input, Auto permits corroborated benign input, Skip performs none, and payments/sends/deletes always require explicit approval. Unlabelled pixel targets also require approval under Auto.",
             "input_schema": ["type": "object",
                              "properties": [
                                "action": ["type": "string", "enum": ["inspect", "move", "click", "double_click", "right_click", "scroll", "type", "key"]],
                                "observation_id": ["type": "string", "description": "UUID returned by the immediately preceding inspect call; required for every input action"],
                                "mark": ["type": "integer", "description": "One-based numbered control from inspect; use instead of x/y"],
                                "x": ["type": "number", "description": "Global screen x tied to the observation; use only when no numbered control addresses the target"],
                                "y": ["type": "number", "description": "Global screen y tied to the observation; use only when no numbered control addresses the target"],
                                "target": ["type": "string", "description": "Visible target label for policy and receipt context"],
                                "text": ["type": "string", "description": "Text for action=type"],
                                "key": ["type": "string", "enum": ["return", "tab", "space", "delete", "escape", "left", "right", "down", "up"]],
                                "modifiers": ["type": "array", "items": ["type": "string"]],
                                "dy": ["type": "integer"], "dx": ["type": "integer"]],
                              "required": ["action"]]])
        }
        // The buyer's OWN connected MCP servers become real, agent-callable tools — the Tier-3
        // "Integrations via MCP" differentiator. Only tools a server ACTUALLY advertised are added
        // (never an invented tool); routes map the model-facing name back to (server, tool) for
        // dispatch. Each call is confirmation-gated in runTool (external reach, possible side effect).
        mcpRoutes = [:]
        if allowedTools.contains(.useConnectors), let mcp, !mcp.allTools.isEmpty {
            let built = MCPAgentBridge.build(from: mcp.allTools)
            defs.append(contentsOf: built.defs)
            mcpRoutes = built.routes
        }
        return defs
    }

    private let defaultSystem = """
    You are an autonomous operator working toward the user's goal in multiple steps. \
    PLAN briefly, then ACT using the available tools to gather real information from the user's \
    own data, then VERIFY your conclusion against what the tools actually returned before you \
    answer. Only state things you can support from tool results or the user's stated facts — \
    never invent file contents, calendar events, memories, or results. When you have enough to \
    answer, stop calling tools and give a clear final answer. If the tools return nothing \
    relevant, say so honestly rather than guessing.
    """

    /// Run a free-form goal with the FULL safe tool surface (the built-in agent).
    func run(goal: String) {
        allowedTools = Set(AgentTool.allCases)
        runSystem = defaultSystem
        runPrefersAllAllowedLocalTools = false
        start(goal: goal)
    }

    /// Run a CUSTOM agent: the buyer's instructions + their tool allowlist (intersected with what
    /// actually exists, so an agent can never grant itself a tool the app doesn't have).
    func run(custom agent: CustomAgent, goal: String, basePersona: String) {
        allowedTools = Set(agent.tools).intersection(Set(AgentTool.allCases))
        if allowedTools.isEmpty { allowedTools = [.searchKnowledge, .recallMemory] }
        runSystem = agent.systemPrompt(base: basePersona)
        runPrefersAllAllowedLocalTools = true
        start(goal: goal)
    }

    private func start(goal: String) {
        steps = []; finalAnswer = ""; pendingApproval = nil
        runGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines); runStartedAt = Date()
        runID = UUID()
        runPosture = guardrailPostureOverride ?? GuardrailPolicy.current
        guard let router = router else { status = .unavailable("Not configured."); return }
        // Demo Mode: agents normally need the buyer's External account (tool use). For the reviewer
        // experience we run the REAL local tools (recall_memory, search_knowledge) over the sample
        // data — so every step receipt is genuine proof-of-execution — and finish with a clearly
        // labeled SAMPLE final answer (no account, no network).
        if router.isDemo {
            status = .planning
            runTask?.cancel()
            runTask = Task { @MainActor in await demoLoop(goal: goal) }
            return
        }
        guard let agent = router.externalForAgent() else {
            // THE LOCAL BRAIN RUNS THE REAL LOOP (2026-07-27): a tool-capable Ollama model
            // (Ornith 1.0) drives the same plan → act → verify tool loop as the External brain —
            // native structured tool calls on the buyer's own local model, same receipts, same
            // confirmation gates. Before this, local brains were hardcoded into the canned
            // receipts pass with the model reduced to summarizing ("nothing built on the model").
            if let local = router.localAgentIfCapable() {
                status = .planning
                runTask?.cancel()
                runTask = Task { @MainActor in
                    await loop(goal: goal, brain: local.brain, model: local.model, credential: local.credential)
                }
            } else if router.isAgentRunnable {
                status = .planning
                runTask?.cancel()
                runTask = Task { @MainActor in await localTextLoop(goal: goal, router: router) }
            } else {
                status = .unavailable(router.agentUnavailableReason)
            }
            return
        }
        status = .planning
        runTask?.cancel()
        runTask = Task { @MainActor in
            await loop(goal: goal, brain: agent.brain, model: agent.model, credential: agent.credential)
        }
    }

    /// Local/text-brain agent mode: execute real read-only local receipts first, then ask the
    /// active plain-text brain to answer from those receipts. This keeps the Agent page runnable on
    /// Ornith/Ollama, local endpoint, on-device, and CLI brains without pretending they support the
    /// structured tool protocol.
    private func localTextLoop(goal: String, router: BrainRouter) async {
        append(.thought, "Goal received", goal)
        append(.thought, "Local agent mode", "Using safe read-only local receipts with \(router.active.label).")
        status = .acting

        var receipts: [String] = []
        let toolNames = Self.localReadOnlyToolNames(for: goal, allowedTools: allowedTools,
                                                    includeAllAllowed: runPrefersAllAllowedLocalTools)
        for name in toolNames {
            if Task.isCancelled { status = .idle; return }
            let input = localToolInput(name: name, goal: goal)
            let (display, output) = await runTool(name: name, input: input)
            append(.toolCall, "Tool · \(name)", display)
            append(.toolResult, "Result · \(name)", output)
            recordStepReceipt(tool: name, display: display, output: output)
            receipts.append("Tool: \(name)\nCall: \(display)\nResult:\n\(output)")
        }

        let skipped = allowedTools
            .filter { $0.requiresConfirmation }
            .map(\.rawValue)
            .sorted()
        if !skipped.isEmpty {
            append(.thought, "Deferred tools", "Structured/side-effect tools need an API/OAuth tool brain: \(skipped.joined(separator: ", ")).")
        }

        status = .verifying
        let prompt = Self.localTextPrompt(goal: runGoal, receipts: receipts, skippedTools: skipped)
        let result = await completeWithActiveBrain(router: router, prompt: prompt, system: runSystem)
        if Task.isCancelled { status = .idle; return }
        switch result {
        case .success(let answer):
            finalAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(No answer produced.)" : answer
            append(.answer, "Final answer", finalAnswer)
            status = .done
            recordReceipt(outcome: .success, detail: finalAnswer)
        case .failure(let error):
            let msg = (error as? ExternalBrain.Failure)?.message
                ?? (error as? OllamaBrain.Failure)?.message
                ?? (error as? OpenAIEndpointBrain.Failure)?.message
                ?? error.localizedDescription
            append(.error, "Run failed", msg)
            status = .failed(msg)
            recordReceipt(outcome: .failure, detail: "Run failed: \(msg)")
        }
    }

    private func localToolInput(name: String, goal: String) -> [String: Any] {
        switch name {
        case "search_knowledge", "search_files":
            return ["query": goal]
        case "read_calendar":
            return ["days": Self.calendarWindowDays(for: goal)]
        case "lookup_client":
            let lower = goal.lowercased()
            if lower.contains("pipeline") || lower.contains("deals") || lower.contains("clients") { return [:] }
            return ["client": goal]
        default:
            return [:]
        }
    }

    private static func calendarWindowDays(for goal: String) -> Int {
        let lower = goal.lowercased()
        if lower.contains("month") { return 30 }
        if lower.contains("today") { return 1 }
        return 7
    }

    private static func localTextPrompt(goal: String, receipts: [String], skippedTools: [String]) -> String {
        let receiptText = receipts.isEmpty ? "No local read-only receipts were available." : receipts.joined(separator: "\n\n---\n\n")
        let skippedText = skippedTools.isEmpty ? "None." : skippedTools.joined(separator: ", ")
        return """
        Goal:
        \(goal)

        Real local receipts from this run:
        \(receiptText)

        Deferred structured/side-effect tools:
        \(skippedText)

        Answer the goal using only the receipts above and the user's stated goal. Verify against
        the receipts before answering. If the receipts are empty or do not contain enough evidence,
        say exactly what is missing and what should be connected next.
        """
    }

    private func completeWithActiveBrain(router: BrainRouter, prompt: String,
                                         system: String) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            router.complete(prompt: prompt, system: system) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// Demo Mode agent run: a real plan → act → verify trace using only LOCAL tools over the
    /// sample data (genuine receipts), capped to non-side-effecting tools so nothing external is
    /// touched, finished with a labeled SAMPLE answer. Honest about being a sample.
    private func demoLoop(goal: String) async {
        append(.thought, "Goal received", goal)
        let sleep: () async -> Void = { try? await Task.sleep(nanoseconds: 600_000_000) }
        await sleep()
        if Task.isCancelled { status = .idle; return }

        // Only read-only, local tools the run is allowed to use (never save_note/fetch_url in demo).
        let toolPlan: [(String, [String: Any])] = [
            ("recall_memory", [:]),
            ("search_knowledge", ["query": goal.isEmpty ? "summary" : goal]),
        ].filter { name, _ in
            guard let t = AgentTool(rawValue: name) else { return false }
            return allowedTools.contains(t) && !t.requiresConfirmation
        }
        status = .acting
        for (name, input) in toolPlan {
            if Task.isCancelled { status = .idle; return }
            let (display, output) = await runTool(name: name, input: input)
            append(.toolCall, "Tool · \(name)", display)
            append(.toolResult, "Result · \(name)", output)
            recordStepReceipt(tool: name, display: display, output: output)
            await sleep()
        }
        status = .verifying
        await sleep()
        finalAnswer = "Based on your sample memory and knowledge, here's a brief for “\(runGoal.isEmpty ? "your goal" : runGoal)”:\n\n• Context gathered from 2 sample sources (memory + knowledge)\n• Suggested next steps drafted from your standing preferences\n• Nothing external was touched — every step above is a real receipt over the sample data\n\nIn the full app this runs on the brain you configure, with local Ornith/Ollama as the default text route.\n\n" + DemoMode.replyFootnote
        append(.answer, "Final answer", finalAnswer)
        status = .done
        recordReceipt(outcome: .success, detail: finalAnswer)
    }

    /// TEST SEAM: run the real loop against an injected `AgentBrain` (no router, no network), so
    /// the per-step + terminal receipt recording can be proven behaviorally. Not used in the app.
    func runForTest(goal: String, brain: any AgentBrain, model: String,
                    credential: ExternalCredential, tools: Set<AgentTool> = Set(AgentTool.allCases),
                    operatorEngine: OperatorEngine? = nil,
                    controlArbiter: ControlArbiter? = nil) async {
        steps = []; finalAnswer = ""; pendingApproval = nil
        runGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines); runStartedAt = Date()
        runID = UUID()
        allowedTools = tools
        if let controlArbiter {
            self.controlArbiter = controlArbiter
            self.operatorEngine = controlArbiter.operatorEngine
            if let activity { controlArbiter.attach(activity: activity) }
        } else if let operatorEngine {
            self.operatorEngine = operatorEngine
            let arbiter = ControlArbiter(operatorEngine: operatorEngine)
            if let activity { arbiter.attach(activity: activity) }
            self.controlArbiter = arbiter
        }
        runSystem = defaultSystem
        runPosture = guardrailPostureOverride ?? GuardrailPolicy.current
        await loop(goal: goal, brain: brain, model: model, credential: credential)
    }

    func cancel() {
        runTask?.cancel(); runTask = nil
        controlArbiter?.cancelPending()
        approvalContinuation?.resume(returning: false); approvalContinuation = nil
        pendingApproval = nil
        if case .done = status {} else if case .failed = status {} else { status = .idle }
    }

    /// The UI calls this when the buyer approves/denies a confirmation-gated tool.
    func resolveApproval(_ approved: Bool) {
        pendingApproval = nil
        approvalContinuation?.resume(returning: approved)
        approvalContinuation = nil
    }

    private func append(_ k: AgentStep.Kind, _ title: String, _ detail: String) {
        steps.append(AgentStep(kind: k, title: title, detail: detail))
    }

    private func loop(goal: String, brain: any AgentBrain, model: String, credential: ExternalCredential) async {
        var messages: [[String: Any]] = [["role": "user", "content": goal]]
        var remainingOutputBudget = ModelRoutingPolicy.maxAgentOutputBudget
        append(.thought, "Goal received", goal)
        let tools = toolDefs()

        for iteration in 0..<Self.maxIterations {
            if Task.isCancelled { status = .idle; return }
            status = iteration == 0 ? .planning : .acting
            do {
                let workload = ModelRoutingPolicy.agentWorkload(iteration: iteration)
                let plan = ModelRoutingPolicy.plan(for: workload, selectedModel: model)
                // The LOCAL brain runs one model — its own. The external candidate ladder (Claude
                // fast/heavy lanes) would be nonsense against the buyer's Ollama daemon, both as a
                // fallback attempt and in the displayed receipt.
                let isLocalBrain = brain is OllamaAgentBrain || brain is OpenAIEndpointBrain
                let candidates = isLocalBrain ? [model] : plan.candidateModels
                append(.thought, "Model route · \(isLocalBrain ? "local" : plan.lane.rawValue)",
                       "Candidates: \(candidates.joined(separator: " → ")) · "
                       + "\(plan.timeoutSeconds.formatted())s timeout · "
                       + "\(remainingOutputBudget) output tokens remain")

                var routedTurn: AgentToolTurn?
                var routeFailures: [String] = []
                for candidate in candidates {
                    let callBudget = min(plan.maxOutputTokens, remainingOutputBudget)
                    guard callBudget >= 512 else { break }
                    // Reserve before the request. A timeout/failure may have consumed provider work,
                    // so failed attempts still count against this run's hard output budget.
                    remainingOutputBudget -= callBudget
                    await ModelLaneGate.shared.acquire(plan.lane, limit: plan.maxConcurrent)
                    do {
                        if Task.isCancelled { throw CancellationError() }
                        // Local models think + generate at hardware speed — give them headroom
                        // over the external lane deadlines (a cold 35B load alone can eat 30s+).
                        routedTurn = try await brain.toolTurn(model: candidate, system: runSystem,
                                                             messages: messages, tools: tools,
                                                             maxTokens: callBudget,
                                                             timeoutSeconds: isLocalBrain ? max(plan.timeoutSeconds, 240)
                                                                                          : plan.timeoutSeconds,
                                                             credential: credential)
                        ModelLaneGate.shared.release(plan.lane)
                        break
                    } catch {
                        ModelLaneGate.shared.release(plan.lane)
                        if error is CancellationError { throw error }
                        routeFailures.append("\(candidate): \(error.localizedDescription)")
                    }
                }
                guard let turn = routedTurn else {
                    let detail = routeFailures.isEmpty
                        ? "the run exhausted its \(ModelRoutingPolicy.maxAgentOutputBudget)-token output budget"
                        : routeFailures.joined(separator: " | ")
                    throw ModelRoutingFailure(message: "The \(plan.lane.rawValue) model lane failed: \(detail)")
                }
                if !turn.text.isEmpty { append(.thought, "Reasoning", turn.text) }

                // No tool calls → the agent is done. Verify-then-finish.
                if turn.toolCalls.isEmpty {
                    status = .verifying
                    finalAnswer = turn.text.isEmpty ? "(No answer produced.)" : turn.text
                    append(.answer, "Final answer", finalAnswer)
                    status = .done
                    recordReceipt(outcome: .success, detail: finalAnswer)
                    return
                }

                // Echo the assistant turn (with its tool_use blocks) back verbatim.
                messages.append(["role": "assistant", "content": turn.assistantContent])

                // Execute each requested tool LOCALLY and record a real receipt.
                var results: [[String: Any]] = []
                for call in turn.toolCalls {
                    let (display, output) = await runTool(name: call.name, input: call.input)
                    append(.toolCall, "Tool · \(call.name)", display)
                    append(.toolResult, "Result · \(call.name)", output)
                    // PROOF-OF-EXECUTION: persist this step (the tool call + its REAL observation)
                    // into the ledger, linked to the run, so the full trace survives the run.
                    recordStepReceipt(tool: call.name, display: display, output: output)
                    results.append([
                        "type": "tool_result",
                        "tool_use_id": call.id,
                        "content": output
                    ])
                    if Task.isCancelled { status = .idle; return }
                }
                messages.append(["role": "user", "content": results])
            } catch is CancellationError {
                status = .idle
                return
            } catch {
                let msg = (error as? ExternalBrain.Failure)?.message ?? error.localizedDescription
                append(.error, "Run failed", msg)
                status = .failed(msg)
                recordReceipt(outcome: .failure, detail: "Run failed: \(msg)")
                return
            }
        }
        // Hit the iteration ceiling without finishing — honest about it.
        append(.error, "Stopped", "Reached the step limit (\(Self.maxIterations)) without a final answer.")
        status = .failed("Reached the step limit without finishing. Try a narrower goal.")
        recordReceipt(outcome: .failure, detail: "Reached the step limit (\(Self.maxIterations)) without a final answer.")
    }

    /// Ask the buyer to approve a confirmation-gated tool. Suspends the loop until they answer.
    private func awaitApproval(tool: String, summary: String) async -> Bool {
        pendingApproval = PendingToolApproval(toolName: tool, summary: summary)
        append(.awaitingConfirm, "Needs your OK · \(tool)", summary)
        status = .awaitingConfirmation(summary)
        let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            self.approvalContinuation = c
        }
        status = .acting
        return ok
    }

    /// Execute a tool against the buyer's OWN data. Returns (human display of the call, result text).
    /// Side-effect / external tools are confirmation-gated before they run.
    private func runTool(name: String, input: [String: Any]) async -> (String, String) {
        // Honest guard: a tool the current run isn't allowed to use never executes.
        if let t = AgentTool(rawValue: name), !allowedTools.contains(t) {
            return ("(blocked)", "This agent isn't allowed to use \(name).")
        }
        // OPERATOR (SV-22): routed through its OWN grant engine (Manual/Auto/Skip dial + deny-list),
        // NOT the generic tool-confirmation gate below — so it is gated exactly once, by the shared
        // operator policy. Handled here, before the generic classification, and returns directly.
        if name == AgentTool.operateUI.rawValue {
            return await runOperator(input: input)
        }
        if name == AgentTool.visualControl.rawValue {
            return await runVisualControl(input: input)
        }
        // GUARDRAIL POLICY GATE — classify + decide BEFORE anything runs (REAL enforcement). The
        // underlying name (the buyer's real MCP tool, when this is a connector call) drives the
        // destructive-pattern check; the base side-effecting class comes from the tool itself.
        let underlying: String = {
            if name.hasPrefix(MCPAgentBridge.prefix), let route = mcpRoutes[name] { return route.tool }
            return name
        }()
        let baseSideEffecting: Bool = {
            if let t = AgentTool(rawValue: name) { return t.requiresConfirmation }
            if name.hasPrefix(MCPAgentBridge.prefix) { return true }   // any connector call reaches the buyer's server
            return false
        }()
        let action = Guardrails.PendingAction(toolName: name, underlyingName: underlying,
                                              sideEffecting: baseSideEffecting,
                                              arguments: Guardrails.stringArgs(input))
        let decision = Guardrails.decide(action, posture: runPosture)
        if case .block = decision {
            recordGuardrailReceipt(decision, action)
            return ("(blocked by guardrail)", decision.reason)   // never executes — honest, enforced
        }
        switch name {
        case "search_knowledge":
            let q = (input["query"] as? String) ?? ""
            let chunks = store?.retrieve(for: q, max: 6, useSemantic: true, includeFiles: true) ?? []
            if chunks.isEmpty { return ("query: \(q)", "No relevant excerpts found in the user's Knowledge or files.") }
            let body = chunks.map { "[\($0.citation)] \($0.docName): \($0.text)" }.joined(separator: "\n")
            return ("query: \(q)", body)

        case "recall_memory":
            let mems = memory?.items.filter { $0.isUsable }.map { "• \($0.trimmed)" } ?? []
            return ("(all standing memories)", mems.isEmpty ? "No saved memories." : mems.joined(separator: "\n"))

        case "lookup_client":
            let q = (input["client"] as? String) ?? (input["query"] as? String) ?? ""
            guard let crm = crm else { return ("(crm)", "No client records are available.") }
            let report = crm.lookup(query: q)
            return (q.isEmpty ? "(whole pipeline)" : "client: \(q)", report)

        case "daily_digest":
            // Pure aggregation over the buyer's OWN local data — proof-of-execution ledger, CRM
            // pipeline, and standing memory — scoped to today. Honest empty when nothing moved.
            let summary = DailyDigest.build(activity: activity?.entries ?? [],
                                            clients: crm?.clients ?? [],
                                            deals: crm?.deals ?? [],
                                            memories: memory?.items ?? [])
            return ("(today's digest)", summary.detailText)

        case "recent_activity":
            // Read-only grounding over the buyer's OWN local ambient timeline. Honest empty when
            // the sampler is off or nothing was captured — never fabricates activity.
            let detail = (input["detail"] as? Bool) ?? false
            if detail {
                // DEEP path (§5.2 consent floor): detail:true returns VERBATIM on-screen text — the
                // focused window's captured AX contents, which can include Terminal/editor text and
                // whose redaction is incomplete — and that text would then egress to the configured
                // brain. Require EXPLICIT per-call approval before returning it. This is a forced
                // confirm (independent of the guardrail posture), so a permissive posture can never
                // silently auto-allow the deep egress. Shallow app/title context (below) stays ungated.
                let deepAction = Guardrails.PendingAction(toolName: name, underlyingName: underlying,
                                                          sideEffecting: true,
                                                          arguments: Guardrails.stringArgs(input))
                let approved = await passesGate(
                    .confirm(reason: "Deep on-screen text (which may include Terminal or editor contents, incompletely redacted) would be sent to your configured brain."),
                    action: deepAction, tool: "recent_activity",
                    summary: "Allow reading the DEEP on-screen text from your recent windows — including any Terminal or editor contents — and sending it to your configured brain?")
                guard approved else {
                    // Consent withheld → return SHALLOW context only (app/title), never the deep text.
                    let shallow = AmbientTimelineStore.shared.groundingText(limit: 12, includeDeep: false)
                    return ("(recent on-screen context)", shallow + "\n\n(Deep on-screen text was withheld — it needs your explicit approval.)")
                }
            }
            let text = AmbientTimelineStore.shared.groundingText(limit: 12, includeDeep: detail)
            return ("(recent on-screen context)", text)

        case "read_calendar":
            guard let cal = calendar else { return ("(calendar)", "Calendar connector isn't configured.") }
            guard cal.isReadable else {
                return ("(calendar)", "The Calendar connector is off or access isn't granted. Turn it on in Connectors.")
            }
            let days = (input["days"] as? Int) ?? 7
            let events = cal.upcoming(days: days)
            if events.isEmpty { return ("next \(days) days", "No events in the user's calendar for the next \(days) days.") }
            return ("next \(days) days", events.map { "• " + $0.line() }.joined(separator: "\n"))

        case "search_files":
            let q = (input["query"] as? String) ?? ""
            guard let files = files else { return ("query: \(q)", "Files connector isn't configured.") }
            guard files.hasContent else { return ("query: \(q)", "No folders are connected, or they have no indexed text files. Add one in Connectors.") }
            let hits = files.search(q, max: 6)
            if hits.isEmpty { return ("query: \(q)", "No files matched “\(q)”.") }
            return ("query: \(q)", hits.map { "• \($0.file): \($0.snippet)" }.joined(separator: "\n"))

        case "save_note":
            let text = (input["text"] as? String) ?? ""
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return ("(empty)", "Nothing to save.") }
            let ok = await passesGate(decision, action: action, tool: "save_note", summary: "Save to your Memory: “\(text)”")
            guard ok else { return ("text: \(text)", "Blocked by the guardrail policy or declined — the note was NOT saved.") }
            memory?.add(text, source: "chat")
            return ("text: \(text)", "Saved to standing Memory.")

        case "fetch_url":
            let url = (input["url"] as? String) ?? ""
            guard WebFetch.isAllowed(url) else { return ("url: \(url)", "That URL isn't allowed (public http/https only).") }
            let ok = await passesGate(decision, action: action, tool: "fetch_url", summary: "Fetch the web page: \(url)")
            guard ok else { return ("url: \(url)", "Blocked by the guardrail policy or declined — the page was NOT fetched.") }
            do {
                let r = try await WebFetch.fetch(url)
                let head = r.title.isEmpty ? r.url : "\(r.title) — \(r.url)"
                return ("url: \(url)", "\(head)\n\n\(r.text)")
            } catch {
                return ("url: \(url)", "Fetch failed: \((error as? WebFetch.FetchError)?.message ?? error.localizedDescription)")
            }

        case let n where n.hasPrefix(MCPAgentBridge.prefix):
            // A buyer-connected MCP tool. Honest guards: the run must be allowed connectors, the
            // route must still resolve (the buyer may have removed the server mid-run), and the
            // call is confirmation-gated because it reaches OUTSIDE the buyer's local data.
            guard allowedTools.contains(.useConnectors) else {
                return ("(blocked)", "This agent isn't allowed to use connected tools.")
            }
            guard let route = mcpRoutes[n], let mcp else {
                return ("(unavailable)", "That connected tool is no longer available.")
            }
            let argText = input.isEmpty ? "no arguments"
                : input.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
            let ok = await passesGate(decision, action: action, tool: route.tool,
                summary: "Run \u{201C}\(route.tool)\u{201D} on your MCP server \u{201C}\(route.server)\u{201D} with \(argText)")
            guard ok else { return ("\(route.server) · \(route.tool)", "Blocked by the guardrail policy or declined — the connected tool did NOT run.") }
            // The manager performs the real round-trip; the agent records its own per-step receipt,
            // so suppress the manager's duplicate connector entry (recordReceipt defaults to false).
            guard let (text, isError) = await mcp.callTool(serverName: route.server, tool: route.tool, arguments: input) else {
                return ("\(route.server) · \(route.tool)", "The connected tool call failed or the server is unreachable.")
            }
            return ("\(route.server) · \(route.tool)", isError ? "The tool reported an error:\n\(text)" : text)

        default:
            return ("(unknown)", "No such tool.")
        }
    }

    /// Invoke semantic control through the single arbiter. The arbiter owns route exclusivity and
    /// the Manual/Auto/Skip gate; the agent owns only the approval banner.
    private func runOperator(input: [String: Any]) async -> (String, String) {
        guard let arbiter = controlArbiter else {
            return ("(operator unavailable)",
                    "The operator isn't available in this run (it needs the macOS app's Accessibility layer).")
        }
        let kindRaw = ((input["action"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // Case-insensitive match onto the four real action kinds (the model may send "setvalue").
        guard let kind = OperatorActionKind.allCases.first(where: { $0.rawValue.lowercased() == kindRaw }) else {
            return ("(operator)", "Unknown operator action “\(kindRaw)”. Use one of: read, press, setValue, focus.")
        }
        let appName = ((input["app"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let label = ((input["target"] as? String) ?? (input["label"] as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let value = input["value"] as? String
        let element = OperatorElement(role: (input["role"] as? String) ?? "",
                                      title: label,
                                      appName: appName,
                                      appBundleID: (input["bundle_id"] as? String) ?? "")
        let plan = ControlPlanner.semantic(kind: kind, element: element, value: value)
        let step = arbiter.propose(plan, dial: ApprovalDial(posture: runPosture))
        switch step.decision {
        case .allow:
            return (plan.display, step.performed
                    ? "Semantic control performed the action. \(step.result)"
                    : step.result)
        case .block:
            return (plan.display, "Semantic control did NOT act — \(step.result)")
        case .confirm:
            let ok = await awaitApproval(tool: "operate_ui", summary: step.decision.reason)
            arbiter.resolve(step.id, approved: ok)
            let resolved = arbiter.trace.first(where: { $0.id == step.id })
            return (plan.display,
                    resolved?.result ?? (ok ? "Performed." : "Declined — semantic control did NOT act."))
        }
    }

    /// Inspect or operate a numbered visual target. `inspect` is read-only and returns a short-lived
    /// observation. Every input plan is then selected and gated by ControlArbiter; the model cannot
    /// force the visual route when a semantic action exists.
    private func runVisualControl(input: [String: Any]) async -> (String, String) {
        guard let arbiter = controlArbiter else {
            return ("(visual control unavailable)", "Visual control is not wired in this run.")
        }
        let request: VisualControlRequest
        switch VisualControlParser.parse(input) {
        case .success(let parsed): request = parsed
        case .failure(let error): return ("(invalid visual action)", error.description)
        }

        if case .inspect = request.command {
            let observation = await arbiter.captureObservation()
            guard case .success(let plan) = ControlPlanner.plan(request, observation: observation) else {
                return ("inspect the frontmost app", "The control map could not be planned.")
            }
            _ = arbiter.propose(plan, dial: ApprovalDial(posture: runPosture))
            return (plan.display, observation.prompt)
        }

        let plan: ControlPlan
        switch arbiter.plan(request) {
        case .success(let value): plan = value
        case .failure(let error): return ("(visual plan stopped)", error.description)
        }
        let step = arbiter.propose(plan, dial: ApprovalDial(posture: runPosture))
        switch step.decision {
        case .allow:
            let verb = step.route == .semantic ? "Semantic control" : "Visual control"
            return (plan.display, step.performed ? "\(verb) performed the action. \(step.result)"
                                                 : step.result)
        case .block:
            return (plan.display, "\(step.route.label) control did NOT act — \(step.result)")
        case .confirm:
            let ok = await awaitApproval(tool: "visual_control", summary: step.decision.reason)
            arbiter.resolve(step.id, approved: ok)
            let resolved = arbiter.trace.first(where: { $0.id == step.id })
            return (plan.display,
                    resolved?.result ?? (ok ? "Performed." : "Declined — no input was posted."))
        }
    }
}
#endif // circuit-convert
