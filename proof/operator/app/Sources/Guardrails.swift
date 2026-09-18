// Sovereign — GUARDRAILS: a deterministic policy gate over side-effecting actions.
//
// THE HONEST CLAIM. The website says a "safety model" must approve before the operator does
// anything consequential. There is no magic AI here that guarantees safety, and Sovereign has no
// "production deploy" concept to gate. What IS real and enforced is THIS: a deterministic, testable
// policy engine that classifies every pending tool call by risk and returns a decision — allow /
// require-confirmation / block — BEFORE the action runs. The AgentEngine honors that decision: a
// `.block` action NEVER executes; a `.confirm` action waits for the buyer's explicit OK; an
// auto-allowed side-effect is logged. Every consequential decision writes a real proof-of-execution
// receipt into the buyer's audit ledger.
//
// SCOPE — what is genuinely gated: memory writes (save_note), external web fetches (fetch_url), and
// the buyer's connected MCP/connector tool calls (sends, writes, deletes, publishes). Read-only
// tools over the buyer's own data (search_knowledge, recall_memory, lookup_client, daily_digest,
// read_calendar, search_files) are allowed without friction.
//
// Pure + static → unit-tested with NO network, NO actor, NO UI. The AgentEngine wires it into the
// real execution path so enforcement is genuine, not advisory.
import Foundation

/// The buyer's safety posture — the policy that governs how side-effecting & destructive actions are
/// gated. Persisted in AppSettings (the buyer owns it). Defaults to the safe `.confirmSideEffects`.
enum GuardrailPosture: String, Codable, CaseIterable, Identifiable, Hashable {
    /// DEFAULT. Read-only actions run; any side-effecting action needs the buyer's confirmation;
    /// destructive / irreversible actions need an explicit confirmation (never auto-run).
    case confirmSideEffects
    /// STRICT. Same as above, but destructive / irreversible actions are BLOCKED outright — they
    /// never run, even with a confirmation. A hard floor for cautious buyers.
    case blockDestructive
    /// AUTONOMOUS. Side-effecting actions inside the agent's own tool allowlist run WITHOUT a prompt
    /// (the buyer opted into autonomy) — but destructive / irreversible actions STILL require an
    /// explicit confirmation. The safety floor holds even here.
    case autonomousAllowlist

    var id: String { rawValue }
    var label: String {
        switch self {
        case .confirmSideEffects:  return "Confirm side-effects"
        case .blockDestructive:    return "Block destructive"
        case .autonomousAllowlist: return "Autonomous (allowlist)"
        }
    }
    var blurb: String {
        switch self {
        case .confirmSideEffects:
            return "Default. Read-only actions run freely; anything that sends, writes, or reaches outside your data asks first; destructive actions always need your explicit OK."
        case .blockDestructive:
            return "Strictest. Adds a hard floor: destructive or irreversible actions (delete, overwrite, mass-send, external publish) are blocked outright and never run."
        case .autonomousAllowlist:
            return "Hands-off. Side-effecting tools inside an agent's allowlist run without asking — but destructive or irreversible actions still require your explicit confirmation."
        }
    }
}

/// Process-wide live posture, mirrored from AppSettings so the AgentEngine can read the buyer's
/// current choice without threading a settings reference through the app's root wiring. AppSettings
/// is the single source of truth + persistence; it pushes every change here. Defaults to the safe
/// posture before settings loads. (Tests set the engine's own override instead of touching this.)
@MainActor
enum GuardrailPolicy {
    static var current: GuardrailPosture = .confirmSideEffects
}

/// The risk class the engine acts on. Pure classification — no side effects.
enum GuardrailRisk: String, Equatable {
    case readOnly       // reads the buyer's own data; no mutation, no external reach
    case sideEffecting  // mutates state or reaches outside the buyer's local data (reversible)
    case destructive    // irreversible / mass / external-publish — the highest-stakes class
}

/// The engine's decision for a pending action. `reason` is shown / logged honestly.
enum GuardrailDecision: Equatable {
    case allow(reason: String)
    case confirm(reason: String)
    case block(reason: String)

    var isAllow: Bool   { if case .allow = self { return true }; return false }
    var isConfirm: Bool { if case .confirm = self { return true }; return false }
    var isBlock: Bool   { if case .block = self { return true }; return false }
    var reason: String {
        switch self { case .allow(let r), .confirm(let r), .block(let r): return r }
    }
}

/// The deterministic policy engine. Everything is pure + static so it is exhaustively unit-tested,
/// then enforced for real by the AgentEngine before any tool runs.
enum Guardrails {
    /// A pending tool call awaiting a policy decision.
    struct PendingAction: Equatable {
        let toolName: String        // the model-facing dispatch name (e.g. "save_note" / "mcp__github__delete_file")
        let underlyingName: String  // the REAL underlying tool name used for classification (MCP: the server tool; else == toolName)
        let sideEffecting: Bool     // base class from the caller: a built-in tool's confirmation flag, or true for any MCP call
        let arguments: [String: String]   // stringified args (keys + values) scanned for destructive intent

        init(toolName: String, underlyingName: String? = nil, sideEffecting: Bool,
             arguments: [String: String] = [:]) {
            self.toolName = toolName
            self.underlyingName = underlyingName ?? toolName
            self.sideEffecting = sideEffecting
            self.arguments = arguments
        }
    }

    /// Substrings that mark an action as DESTRUCTIVE / irreversible / mass-external. Matched against
    /// the underlying tool name AND argument keys. Conservative-but-meaningful: these are the verbs a
    /// buyer would never want run silently.
    static let destructivePatterns: [String] = [
        "delete", "destroy", "remove", "drop", "truncate", "wipe", "purge", "erase",
        "overwrite", "replace_all", "force_push", "force-push", "reset_hard",
        "send", "email", "publish", "post", "broadcast", "deploy", "release",
        "merge", "transfer", "wire", "payout", "charge", "refund", "revoke", "deactivate",
        "uninstall", "format", "shutdown"
    ]

    /// Argument keys whose truthy value flips an otherwise-ordinary side-effect into a destructive one
    /// (e.g. a `force` overwrite, a `recursive` delete, a `permanent` removal).
    static let destructiveFlagKeys: Set<String> = ["force", "recursive", "permanent", "hard"]

    /// True if the action looks destructive / irreversible / mass-external. A pure read can never be
    /// destructive. Pure → testable.
    static func isDestructive(_ action: PendingAction) -> Bool {
        guard action.sideEffecting else { return false }
        if matches(action.underlyingName.lowercased()) { return true }
        for (k, v) in action.arguments {
            let key = k.lowercased()
            if destructiveFlagKeys.contains(key) && truthy(v) { return true }
            if matches(key) { return true }
        }
        return false
    }

    private static func matches(_ s: String) -> Bool { destructivePatterns.contains { s.contains($0) } }
    private static func truthy(_ v: String) -> Bool {
        ["true", "yes", "1"].contains(v.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Classify the action's risk. Pure.
    static func classify(_ action: PendingAction) -> GuardrailRisk {
        if isDestructive(action) { return .destructive }
        return action.sideEffecting ? .sideEffecting : .readOnly
    }

    /// THE GATE. Given a pending action and the buyer's posture, decide allow / confirm / block.
    /// Pure → exhaustively unit-tested; the engine enforces the result before any tool runs.
    static func decide(_ action: PendingAction, posture: GuardrailPosture) -> GuardrailDecision {
        switch classify(action) {
        case .readOnly:
            return .allow(reason: "Read-only action over your own data — no confirmation needed.")
        case .sideEffecting:
            switch posture {
            case .autonomousAllowlist:
                return .allow(reason: "Autonomous posture: side-effecting action permitted within this agent's allowlist (audited).")
            case .confirmSideEffects, .blockDestructive:
                return .confirm(reason: "This action changes state or reaches outside your data — your confirmation is required.")
            }
        case .destructive:
            switch posture {
            case .blockDestructive:
                return .block(reason: "Blocked by your safety posture: \u{201C}\(action.underlyingName)\u{201D} looks destructive or irreversible and is not allowed to run.")
            case .confirmSideEffects, .autonomousAllowlist:
                return .confirm(reason: "\u{201C}\(action.underlyingName)\u{201D} looks destructive or irreversible — explicit confirmation is required even in autonomous mode.")
            }
        }
    }

    /// Build the audit-receipt content for a CONSEQUENTIAL decision (block / confirm / auto-allowed
    /// side-effect). A routine read-only allow returns nil — it is already captured by the tool's own
    /// step receipt, so the ledger is never flooded. Pure → the content is unit-testable; the engine
    /// records it. `isFailure` is true only for a block (the action was prevented).
    static func receipt(for decision: GuardrailDecision, action: PendingAction)
        -> (title: String, detail: String, isFailure: Bool)? {
        let name = action.underlyingName
        switch decision {
        case .block:
            return ("Guardrail \u{00B7} blocked \(name)", decision.reason, true)
        case .confirm:
            return ("Guardrail \u{00B7} confirm required \u{00B7} \(name)", decision.reason, false)
        case .allow:
            guard action.sideEffecting else { return nil }   // never log a read-only allow
            return ("Guardrail \u{00B7} auto-allowed \(name)", decision.reason, false)
        }
    }

    /// Flatten an arbitrary tool-arg dictionary to string keys+values for destructive scanning. Pure.
    static func stringArgs(_ input: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in input { out[k] = String(describing: v) }
        return out
    }

    // MARK: - SV-19 unattended (assign-and-walk-away) enforcement

    /// What an UNATTENDED (scheduled / triggered) run may do with a pending action. It applies the
    /// EXACT SAME deterministic gate as an interactive run — there is simply no human to answer a
    /// confirmation, so a `.confirm` becomes a `.skip` (declined, the safe interactive default) and a
    /// `.block` stays a `.block`. Nothing an interactive run would gate is ever silently run
    /// unattended: the deny-list and the Skip semantics are honored exactly as interactive.
    enum UnattendedOutcome: Equatable {
        case run(reason: String)      // allowed by the gate — runs exactly as interactive
        case skip(reason: String)     // gate demanded confirmation; no human is watching → safely skipped
        case block(reason: String)    // gate blocked it outright — never runs, attended or not

        var didRun: Bool  { if case .run = self { return true }; return false }
        var didSkip: Bool { if case .skip = self { return true }; return false }
        var didBlock: Bool { if case .block = self { return true }; return false }
        var reason: String { switch self { case .run(let r), .skip(let r), .block(let r): return r } }
    }

    /// Map the interactive gate decision to the unattended outcome. `.allow`→run, `.confirm`→skip,
    /// `.block`→block. This is exactly why the deny-list + Skip are honored the same as interactive.
    /// PURE → unit-tested; the scheduler enforces it (any confirm-demand is auto-declined mid-run).
    static func unattended(_ action: PendingAction, posture: GuardrailPosture) -> UnattendedOutcome {
        switch decide(action, posture: posture) {
        case .allow(let r):   return .run(reason: r)
        case .confirm(let r): return .skip(reason: "No one is watching this unattended run, so it was safely skipped instead of run: \(r)")
        case .block(let r):   return .block(reason: r)
        }
    }

    /// The honest, buyer-facing description of what the guardrail actually is — used in Settings so
    /// the claim is never inflated into a magic "AI safety model".
    static let honestDescription =
        "A deterministic policy gate. Before the operator runs any action that changes state, sends, "
        + "or reaches outside your data, Sovereign classifies it by risk and either allows it, asks you "
        + "to confirm, or blocks it — per the posture you set. Every consequential decision is written "
        + "to your activity log. This is real enforcement plus human confirmation, not a model that "
        + "guarantees safety."
}
