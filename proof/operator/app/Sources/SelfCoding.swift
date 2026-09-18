// Sovereign — SELF-CODING TOOL-LOOP (SV-11): buyer-reachable, deny-by-default, approve-every-step.
//
// THE HONEST CLAIM. Sovereign's brain can extend itself — read the project, propose a change, and
// (with the owner's explicit grant + approval) write it. The dev runtime
// (~/sovereign-live · sovereign/brain/toolloop.py) already does this behind a RESERVED grant
// subject `brain.toolloop` in ~/.sovereign/grants.json: deny-by-default, and the whole loop stands
// down with zero grants. This file is the buyer-facing surface + the SAME discipline, made reachable
// and gated inside the app so a buyer can SEE exactly what the loop may touch and approve each step:
//
//   · MASTER OFF by default — turning the loop on is a FOUNDER policy gate (`sov grant brain.toolloop`).
//     It is NEVER silently ungated: the UI shows the reachable, honest gated surface; the flip is
//     owner-only. With the master off the loop stands down entirely (no tool is even visible).
//   · PER-TOOL grants, deny-by-default — even with the master on, only tools the owner explicitly
//     granted are visible/runnable; an ungranted-but-known tool is REFUSED without executing.
//   · APPROVE every step — each proposed tool call is decided by the deterministic gate
//     (allow / confirm / block) before anything runs, exactly like the operator + guardrail engines.
//   · DIFF BEFORE APPLY — a step that WRITES a file produces a real unified diff the owner reviews
//     and approves before a single byte is written; nothing touches the file until then.
//   · RECEIPTS — every proposed / blocked / applied step writes ONE real proof-of-execution receipt
//     into the ActivityLog. No narrated fake edits.
//
// The PURE core (tool catalog + risk, deny-by-default decision, unified diff, receipt content) is
// static/value-typed so it is exhaustively unit-tested with NO filesystem, NO shell, NO UI. The
// engine ties it to the ActivityLog and an INJECTED writer, so a file is only ever written through
// an approved, diffed, granted step — and the tests prove that without touching disk.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Tool catalog (pure) — mirrors the reserved-subject capabilities of the dev toolloop

/// A capability the self-coding loop may be granted. Names mirror the dev runtime's capability keys
/// (`filesystem.read`, `filesystem.write`, …) so a buyer's grant reads the same across app + CLI.
enum SelfCodingTool: String, Codable, CaseIterable, Identifiable, Hashable {
    case readFile   = "filesystem.read"
    case listDir    = "filesystem.list"
    case writeFile  = "filesystem.write"
    // NOTE: `shell.run` (a command runner) was REMOVED. The injected writer only ever applies a
    // `.writeFile`, so a granted/approved `shell.run` silently no-op'd and then reported "the write
    // failed" — a dead, mis-honest high-stakes control. Per ship-no-dead-controls we do not advertise a
    // grantable action that can never run; command execution is not offered rather than faked.

    var id: String { rawValue }

    /// Does running this change anything on the buyer's machine? A read/list never does. With command
    /// execution removed, the only mutating capability is the diff-gated file write.
    var mutates: Bool { self == .writeFile }
    /// A write-to-file step must go through DIFF-BEFORE-APPLY: the owner sees the exact change first.
    var touchesFiles: Bool { self == .writeFile }

    var label: String {
        switch self {
        case .readFile:   return "Read a file"
        case .listDir:    return "List a directory"
        case .writeFile:  return "Write a file (diff-gated)"
        }
    }
    var blurb: String {
        switch self {
        case .readFile:   return "Read the contents of a file in the project so the brain can reason over real code."
        case .listDir:    return "List the files in a directory so the brain can find what it needs."
        case .writeFile:  return "Apply an edit — but only after you review the exact unified diff and approve it."
        }
    }
    var icon: String {
        switch self {
        case .readFile:   return "doc.text"
        case .listDir:    return "folder"
        case .writeFile:  return "square.and.pencil"
        }
    }
}

// MARK: - Write containment (pure) — a self-coding file write can only land inside the workspace it OWNS

/// The self-coding loop's file writes are confined to a single workspace root it owns. Even once the
/// model is wired to `propose`, an approved `.writeFile` can NEVER escape that root to touch
/// `~/Library/LaunchAgents`, the app bundle, arbitrary dotfiles, or anything else — the containment
/// check runs BEFORE the write and refuses anything outside. Purely lexical (tilde-expanded, `.`/`..`
/// collapsed), so it needs no disk access and is exhaustively unit-tested.
enum SelfCodingContainment {
    /// Returns the standardized absolute path IFF `target` resolves to a location strictly INSIDE
    /// `root` (a descendant file, never the root directory itself). Otherwise `nil` — refused.
    ///  · `~` in either input is expanded.
    ///  · `.`/`..` are collapsed lexically first, so `root/../../etc/passwd` is rejected.
    ///  · Containment is checked on a path-COMPONENT boundary, so a sibling like `root-evil/x` is
    ///    never mistaken for being inside `root`.
    static func containedPath(target: String, root: String) -> String? {
        let t = (target as NSString).expandingTildeInPath
        let r = (root as NSString).expandingTildeInPath
        guard t.hasPrefix("/"), r.hasPrefix("/") else { return nil }        // both must be absolute
        let stdTarget = URL(fileURLWithPath: t).standardizedFileURL.path    // collapses . and .. lexically
        let stdRoot = URL(fileURLWithPath: r).standardizedFileURL.path
        guard stdTarget != stdRoot else { return nil }                      // must be a file WITHIN, not the dir
        let rootWithSep = stdRoot.hasSuffix("/") ? stdRoot : stdRoot + "/"
        guard stdTarget.hasPrefix(rootWithSep) else { return nil }          // component-boundary containment
        return stdTarget
    }
}

// MARK: - The deterministic gate (pure + static → exhaustively unit-tested)

/// The gate's decision for a proposed self-coding step. `reason` is shown to the buyer + written to
/// the receipt — always honest.
enum SelfCodingDecision: Equatable {
    case allow(reason: String)    // a granted read/list — safe, runs
    case confirm(reason: String)  // a granted mutating step — held for explicit approval (diff first for a write)
    case block(reason: String)    // master off, or an ungranted tool — refused WITHOUT executing

    var isAllow: Bool   { if case .allow = self { return true }; return false }
    var isConfirm: Bool { if case .confirm = self { return true }; return false }
    var isBlock: Bool   { if case .block = self { return true }; return false }
    var reason: String { switch self { case .allow(let r), .confirm(let r), .block(let r): return r } }
}

enum SelfCodingLoop {
    /// The reserved grant subject — IDENTICAL to the dev runtime's, so a grant means the same thing
    /// in the app and at the CLI (`sov grant brain.toolloop tools=…`).
    static let grantSubject = "brain.toolloop"

    /// THE GATE. Deny-by-default. Pure → exhaustively unit-tested; the engine enforces the result
    /// before anything runs.
    ///
    ///  · MASTER OFF → BLOCK everything (the loop stands down; this is the founder policy gate).
    ///  · Tool NOT granted → BLOCK without executing (grants are the only unlock).
    ///  · Granted read/list → ALLOW (no mutation).
    ///  · Granted file write → CONFIRM, and the caller must present a diff first.
    ///    (There is no command capability — `shell.run` was removed; the only mutating tool is a file write.)
    static func decide(tool: SelfCodingTool, masterEnabled: Bool, granted: Set<SelfCodingTool>) -> SelfCodingDecision {
        guard masterEnabled else {
            return .block(reason: "Self-coding is off. Turning it on is an owner policy gate (grant `\(grantSubject)`); the loop performs nothing until then.")
        }
        guard granted.contains(tool) else {
            // Mirrors toolloop.py: "tool not granted" — refused without executing.
            return .block(reason: "\u{201C}\(tool.rawValue)\u{201D} is not granted to the self-coding loop. Grant it explicitly first; ungranted tools never run.")
        }
        if !tool.mutates {
            return .allow(reason: "Granted read-only step (\(tool.label)) — no change to your machine.")
        }
        if tool.touchesFiles {
            return .confirm(reason: "The loop wants to \(tool.label.lowercased()). Review the diff below and approve before any byte is written.")
        }
        // Defensive default: the only mutating capability is the diff-gated file write above, so this is
        // unreachable today — any future mutating tool is still HELD for explicit approval, never auto-run.
        return .confirm(reason: "The loop wants to \(tool.label.lowercased()). This is a high-stakes action — approve it explicitly before it runs.")
    }

    /// Which granted tools the loop may even SEE this run — deny-by-default: empty when the master is
    /// off (stand down) or nothing is granted. Mirrors the dev runtime hiding ungranted tools from the
    /// model entirely, so the brain can't call what the owner didn't authorize.
    static func visibleTools(masterEnabled: Bool, granted: Set<SelfCodingTool>) -> Set<SelfCodingTool> {
        guard masterEnabled else { return [] }
        return granted.intersection(Set(SelfCodingTool.allCases))
    }

    /// Build the proof-of-execution receipt content for a self-coding decision. A `.block` is a
    /// failure (the step was prevented). Pure → the content is unit-testable; the engine records it.
    static func receipt(for decision: SelfCodingDecision, tool: SelfCodingTool, target: String)
        -> (title: String, detail: String, isFailure: Bool) {
        let where_ = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = where_.isEmpty ? tool.label : "\(tool.label) \u{00B7} \(where_)"
        switch decision {
        case .block:
            return ("Self-coding \u{00B7} refused \u{00B7} \(scope)", decision.reason, true)
        case .confirm:
            return ("Self-coding \u{00B7} awaiting approval \u{00B7} \(scope)", decision.reason, false)
        case .allow:
            return ("Self-coding \u{00B7} \(scope)", decision.reason, false)
        }
    }

    /// The honest, buyer-facing description — used in Settings so the claim is never inflated. There
    /// is no autonomous coder loose on your machine: there is a granted, diffed, approved loop.
    static let honestDescription =
        "Sovereign's brain can extend itself — read the project, propose an edit, and (only with your "
        + "grant and approval) apply it. It is off by default and stays off until it's turned on as an "
        + "owner policy gate. Even then it is deny-by-default: it can only see the exact tools you grant, "
        + "an ungranted tool never runs, every step waits for your approval, and any file write shows you "
        + "the full diff before a single byte changes. Every step is written to your activity log."
}

// MARK: - Unified diff (pure) — the "see the exact change before it's applied" primitive

enum SelfCodingDiff {
    /// A minimal, honest unified diff between a file's current contents and the proposed contents.
    /// Trims the common leading/trailing lines so the hunk shows only what actually changes, then
    /// emits `-` removed / `+` added lines. Deterministic + pure → unit-tested. Returns an explicit
    /// "no changes" marker when the two are identical (so the UI never shows an empty, misleading diff).
    static func unified(path: String, old: String, new: String) -> String {
        if old == new {
            return "--- \(path)\n+++ \(path)\n(no changes)"
        }
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        // Common prefix.
        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        // Common suffix (not overlapping the prefix).
        var suffix = 0
        while suffix < (oldLines.count - prefix), suffix < (newLines.count - prefix),
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        let removed = oldLines[prefix..<(oldLines.count - suffix)]
        let added = newLines[prefix..<(newLines.count - suffix)]

        var out = "--- \(path)\n+++ \(path)\n"
        // A 1-based hunk header naming the changed region in the OLD file, for orientation.
        let startLine = prefix + 1
        out += "@@ -\(startLine),\(removed.count) +\(startLine),\(added.count) @@\n"
        for line in removed { out += "-\(line)\n" }
        for line in added { out += "+\(line)\n" }
        return String(out.dropLast())   // drop the trailing newline for a tidy block
    }
}

// MARK: - A single proposed/applied self-coding step (the live, ordered trace)

struct SelfCodingStep: Identifiable, Equatable {
    let id = UUID()
    var tool: SelfCodingTool
    var target: String                // file path / dir / command being acted on
    var proposedContents: String?     // for a writeFile: the full proposed new contents
    var currentContents: String?      // for a writeFile: the current on-disk contents (for the diff)
    var decision: SelfCodingDecision
    var diff: String?                 // the unified diff shown before apply (writeFile only)
    var applied: Bool = false         // true once an approved step actually ran
    var preApplyBytes: String?        // the EXACT on-disk contents captured before an approved write (for rollback)
    var rolledBack: Bool = false      // true once an applied write was restored to its pre-apply bytes
    var published: Bool = false       // true once an applied self-authored tool was exported as an MCP definition (SV-17)
    var registeredToolName: String?   // the MCP name this tool was REGISTERED into the local registry as (SV-17); cleared on unregister/rollback
    var result: String = ""           // the real outcome text (or the block/decline reason)
    var at = Date()

    /// A file write that actually ran and hasn't been undone can be rolled back to its pre-apply
    /// bytes. Only a writeFile step is reversible (a read/list changed nothing; a command isn't a
    /// file the loop captured), and only if we hold the exact bytes that were there before.
    var canRollback: Bool { applied && !rolledBack && tool.touchesFiles && preApplyBytes != nil }

    /// SV-17 publish-to-MCP: only an approved+applied self-authored TOOL (a file the loop actually
    /// wrote, not yet rolled back) can be exported as an MCP tool definition. A read/list/command is
    /// not a self-authored tool; a rolled-back write no longer exists to publish.
    var canPublish: Bool { applied && !rolledBack && tool.touchesFiles }

    static func == (a: SelfCodingStep, b: SelfCodingStep) -> Bool { a.id == b.id }
}

// MARK: - SelfCodingEngine — grants + master flag + orchestrated decide → diff → approve → apply

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
/// Ties the pure gate to the persisted grants, the ActivityLog, and an INJECTED writer. Holds the
/// per-tool grants (deny-by-default) and the master flag (default OFF, an owner policy gate). Nothing
/// is written to disk except through `resolve(approved:)` on a granted, diffed, master-on step — so
/// the whole discipline is enforced in code, not merely described in copy.
@MainActor
final class SelfCodingEngine: ObservableObject {
    /// Master switch. DEFAULT FALSE — turning it on is a founder policy gate; the app never flips it
    /// silently. Persisted so the (owner-set) state survives launches.
    @Published var masterEnabled: Bool { didSet { d.set(masterEnabled, forKey: Self.masterKey) } }
    /// Per-tool grants, deny-by-default. Persisted. The buyer can PRE-authorize which tools the loop
    /// may use; nothing actually runs until the master (owner) flip — belt and suspenders.
    @Published var granted: Set<SelfCodingTool> { didSet { persistGrants() } }
    /// The live, ordered trace shown in the UI. Insertion order == the order steps happened.
    @Published private(set) var trace: [SelfCodingStep] = []

    private let d: UserDefaults
    nonisolated static let masterKey = "com.blacklabel.sovereign.selfcoding.master.v1"
    nonisolated static let grantsKey = "com.blacklabel.sovereign.selfcoding.grants.v1"

    private weak var activity: ActivityLog?
    /// One run id so every self-coding step links under a single terminal receipt in the ledger.
    let runID = UUID()

    /// Injected real writer: the app wires this to a genuine file write; tests inject a deterministic
    /// stub so the orchestration (grant → diff → approve → apply) is proven with NO disk I/O. Returns
    /// (success, human-readable result). Only ever called for an APPROVED, granted, master-on step.
    var writer: (SelfCodingTool, String, String?) -> (Bool, String) =
        { _, _, _ in (false, "No self-coding writer attached.") }

    /// SV-17 close — the LOCAL MCP tool registry (the sovereign-live tools lane) a published tool is
    /// REGISTERED into. Injected exactly like `writer`, so the orchestration (publish → register,
    /// rollback → unregister) is proven with NO real registry I/O in tests. Wired only by the
    /// non-sandboxed runtime; the sandboxed App-Store build leaves the honest no-op default (a false
    /// return → the publish still EXPORTS its portable JSON but records that no local registration
    /// happened, never claiming one it didn't do). Registration is LOCAL — a definition written into
    /// the buyer's own on-machine registry, NOT a hosted network endpoint (§5.1). `(name, json) →
    /// (ok, message)`.
    var registrar: (_ toolName: String, _ definitionJSON: String) -> (Bool, String) =
        { _, _ in (false, "No local MCP tool registry attached.") }
    /// The inverse: REMOVE a previously-registered tool from the local registry. Called by `rollback`
    /// so undoing a self-authored tool also withdraws its registration — deny-by-default all the way
    /// back out. `(name) → (ok, message)`.
    var unregistrar: (_ toolName: String) -> (Bool, String) =
        { _ in (false, "No local MCP tool registry attached.") }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        masterEnabled = (d.object(forKey: Self.masterKey) as? Bool) ?? false   // DEFAULT OFF
        if let raw = d.array(forKey: Self.grantsKey) as? [String] {
            granted = Set(raw.compactMap { SelfCodingTool(rawValue: $0) })
        } else {
            granted = []                                                        // DENY BY DEFAULT
        }
    }

    private func persistGrants() {
        d.set(granted.map { $0.rawValue }, forKey: Self.grantsKey)
    }

    func attach(activity: ActivityLog) { self.activity = activity }

    /// Grant / revoke a single tool (the per-tool deny-by-default control the UI drives).
    func setGranted(_ tool: SelfCodingTool, _ on: Bool) {
        if on { granted.insert(tool) } else { granted.remove(tool) }
    }

    /// Propose one self-coding step. Decides via the shared gate, records a real receipt, and — only
    /// for a granted read/list under the master — runs immediately. A mutating step is HELD (a write
    /// carries its diff for the owner to review); the caller drives approval, then calls `resolve`.
    @discardableResult
    func propose(tool: SelfCodingTool, target: String,
                 currentContents: String? = nil, proposedContents: String? = nil) -> SelfCodingStep {
        let decision = SelfCodingLoop.decide(tool: tool, masterEnabled: masterEnabled, granted: granted)
        var step = SelfCodingStep(tool: tool, target: target,
                                  proposedContents: proposedContents, currentContents: currentContents,
                                  decision: decision)
        // Build the diff up front for a file write so it is ALWAYS shown before apply — even the
        // receipt of a blocked write carries no write, and an approved one has the diff ready.
        if tool.touchesFiles, let proposed = proposedContents {
            step.diff = SelfCodingDiff.unified(path: target, old: currentContents ?? "", new: proposed)
        }
        switch decision {
        case .block:
            step.result = decision.reason
            recordReceipt(decision, tool: tool, target: target)
        case .confirm:
            step.result = "Awaiting your approval."     // no receipt yet — terminal outcome on resolve
        case .allow:
            // A granted read/list: no mutation, so it's safe to mark done. The real read is performed
            // by the caller (it owns the filesystem access); the engine records the audited step.
            step.applied = true
            step.result = decision.reason
            recordReceipt(decision, tool: tool, target: target)
        }
        trace.append(step)
        return step
    }

    /// Resolve a confirm-gated step after the buyer reviewed the diff and answered. Approved → run the
    /// injected writer and record the real outcome; declined → recorded as not applied. Always writes
    /// ONE real receipt. A step is NEVER written unless it was granted, master-on, and approved here.
    func resolve(_ id: UUID, approved: Bool) {
        guard let idx = trace.firstIndex(where: { $0.id == id }) else { return }
        var step = trace[idx]
        guard step.decision.isConfirm else { return }
        if approved {
            // Capture the EXACT bytes on disk before we overwrite them, so an applied write can be
            // rolled back to precisely what was there. `currentContents` is the on-disk snapshot the
            // caller read when it built the diff — the same bytes the diff's `-` lines came from.
            if step.tool.touchesFiles { step.preApplyBytes = step.currentContents ?? "" }
            let (ok, msg) = writer(step.tool, step.target, step.proposedContents)
            step.applied = ok
            step.result = msg
            let d = SelfCodingDecision.allow(reason: ok ? "Approved by you and applied." : "Approved, but the write failed: \(msg)")
            recordReceipt(d, tool: step.tool, target: step.target, extra: step.result)
        } else {
            step.applied = false
            step.result = "Declined — nothing was written."
            recordReceipt(.block(reason: step.result), tool: step.tool, target: step.target)
        }
        trace[idx] = step
    }

    /// ROLLBACK an applied file write to its pre-apply bytes. Reverses a change the loop made — the
    /// owner can always take it back. Writes the captured pre-apply bytes back through the SAME
    /// injected writer (so tests prove it with no disk I/O), records ONE real proof-of-execution
    /// receipt, and marks the step rolled back. A step that wasn't an applied write, or was already
    /// rolled back, is a no-op — nothing is written and no misleading receipt is produced.
    func rollback(_ id: UUID) {
        guard let idx = trace.firstIndex(where: { $0.id == id }) else { return }
        var step = trace[idx]
        guard step.canRollback, let bytes = step.preApplyBytes else { return }
        let (ok, msg) = writer(step.tool, step.target, bytes)
        if ok {
            step.rolledBack = true
            // SV-17 close — if this tool was REGISTERED into the local MCP registry, undoing the write
            // also withdraws its registration (deny-by-default all the way back out). Best-effort: a
            // failed unregister is reported honestly but never blocks the file rollback that succeeded.
            var unregNote = ""
            if let toolName = step.registeredToolName {
                let (unOK, unMsg) = unregistrar(toolName)
                if unOK {
                    step.registeredToolName = nil
                    step.published = false
                    unregNote = " Also unregistered \u{201C}\(toolName)\u{201D} from your local MCP tool registry."
                } else {
                    unregNote = " (Note: could not unregister \u{201C}\(toolName)\u{201D} from the local registry: \(unMsg).)"
                }
            }
            step.result = "Rolled back to the pre-apply contents (\(bytes.count) character\(bytes.count == 1 ? "" : "s") restored).\(unregNote)"
            recordReceipt(.allow(reason: "Rolled back \(step.tool.label.lowercased()) \u{00B7} \(step.target) — restored the exact bytes from before the change.\(unregNote)"),
                          tool: step.tool, target: step.target, extra: step.result)
        } else {
            // The restore itself failed — an honest failure receipt; the step is NOT marked rolled back.
            recordReceipt(.block(reason: "Rollback failed: \(msg)"), tool: step.tool, target: step.target)
        }
        trace[idx] = step
    }

    private func recordReceipt(_ decision: SelfCodingDecision, tool: SelfCodingTool,
                               target: String, extra: String? = nil) {
        let r = SelfCodingLoop.receipt(for: decision, tool: tool, target: target)
        var detail = r.detail
        if let e = extra, !e.isEmpty, e != r.detail { detail += "\n\n" + e }
        activity?.recordStep(parentID: runID, title: r.title, detail: detail,
                             outcome: r.isFailure ? .failure : .success)
    }

    /// Clear the live trace (does not touch the persisted ledger — those receipts are permanent).
    func clearTrace() { trace.removeAll() }
}
#endif // circuit-convert

// MARK: - SV-17 publish-to-MCP (export half) — turn an approved+applied self-authored tool into a
// standard MCP tool definition the buyer can register into their OWN server.
//
// HONEST SCOPE (§5.1). Sovereign is an MCP *client*: it connects to the buyer's servers and gains
// their tools (see MCP.swift). The Mac App Store build is app-sandboxed — no subprocess spawn, no
// listening socket — so it cannot HOST a live server to register a new tool into. Therefore "publish
// to MCP" here is the honest, buildable half: an approved+applied self-authored tool is EXPORTED as a
// valid `tools/list`-shape MCP tool definition (name / description / JSON-Schema inputSchema) — a
// real, portable artifact the buyer registers into their own MCP server. It is NEVER presented as a
// live registration; the loop hands over the definition, it does not stand up a running endpoint.

/// A declared spec for a self-authored tool being published. Params are ONLY what the author
/// explicitly declares — never invented — so the exported inputSchema stays honest (an undeclared
/// tool publishes with an empty, truthful `properties`, not a fabricated parameter list).
struct SelfAuthoredToolSpec: Equatable {
    var summary: String
    var params: [Param] = []
    struct Param: Equatable { var name: String; var type: String = "string"; var required: Bool = false }
}

enum SelfCodingPublish {
    /// Sanitize a file/tool target into a valid MCP tool name: `[a-zA-Z0-9_-]`, 1...64, never empty.
    /// (MCP/Anthropic tool names must match that charset; a raw file path never does.) Pure → tested.
    static func toolName(from target: String) -> String {
        let base = (target as NSString).lastPathComponent
        let stem: String = {
            if let dot = base.lastIndex(of: "."), dot != base.startIndex { return String(base[..<dot]) }
            return base
        }()
        let cleaned = String(String.UnicodeScalarView(stem.unicodeScalars.map { sc in
            let ok = (sc >= "a" && sc <= "z") || (sc >= "A" && sc <= "Z") ||
                     (sc >= "0" && sc <= "9") || sc == "_" || sc == "-"
            return ok ? sc : Unicode.Scalar("_")
        }))
        let trimmed = String(cleaned.prefix(64))
        return trimmed.isEmpty ? "self_authored_tool" : trimmed
    }

    /// Build the MCP tool DEFINITION object — the exact shape a server returns from `tools/list`:
    /// `name` + `description` + JSON-Schema `inputSchema`. Only declared params; nothing invented.
    /// Pure → tested.
    static func definition(name: String, spec: SelfAuthoredToolSpec) -> [String: Any] {
        var props: [String: Any] = [:]
        var required: [String] = []
        for p in spec.params {
            let pn = p.name.trimmingCharacters(in: .whitespaces)
            guard !pn.isEmpty else { continue }
            props[pn] = ["type": p.type.isEmpty ? "string" : p.type]
            if p.required { required.append(pn) }
        }
        var schema: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty { schema["required"] = required }
        let trimmedSummary = spec.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let desc = trimmedSummary.isEmpty
            ? "A tool authored by Sovereign's self-coding loop, on your machine."
            : trimmedSummary
        return ["name": name, "description": desc, "inputSchema": schema]
    }

    /// The exported definition as deterministic, pretty JSON — the portable artifact the buyer
    /// registers into their own MCP server. Sorted keys → stable → tested. Pure.
    static func exportJSON(name: String, spec: SelfAuthoredToolSpec) -> String {
        let def = definition(name: name, spec: spec)
        guard let data = try? JSONSerialization.data(withJSONObject: def, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    /// The honest one-liner shown with the export so a buyer never reads it as a live registration.
    static let honestNote =
        "This exports a standard MCP tool definition you can register into your own MCP server. "
        + "Sovereign is sandboxed and does not host a live server, so it hands you the definition — it "
        + "does not stand up a running endpoint."
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension SelfCodingEngine {
    /// PUBLISH an approved+applied self-authored tool as an MCP tool definition (SV-17, export half).
    /// Gated exactly like the rest of the loop: master-OFF stands the whole thing down (returns nil +
    /// an honest blocked receipt); a step that never actually applied (or was rolled back) is not
    /// publishable. On a real publish it records ONE proof-of-execution receipt carrying the exported
    /// definition and returns the JSON. A step id that isn't in the trace returns nil (no receipt).
    @discardableResult
    func publish(_ id: UUID, as spec: SelfAuthoredToolSpec) -> String? {
        guard let idx = trace.firstIndex(where: { $0.id == id }) else { return nil }
        let step = trace[idx]
        // Master-OFF stand-down — the identical founder policy gate the loop itself honors.
        guard masterEnabled else {
            recordReceipt(.block(reason: "Self-coding is off — nothing can be published. Turning it on is an owner policy gate (grant `\(SelfCodingLoop.grantSubject)`)."),
                          tool: step.tool, target: step.target)
            return nil
        }
        // Deny-by-default: only a real, approved+applied self-authored tool may be published.
        guard step.canPublish else {
            recordReceipt(.block(reason: "Only an approved, applied tool can be published to MCP. This step hasn't been applied (or was rolled back), so there's nothing to publish."),
                          tool: step.tool, target: step.target)
            return nil
        }
        let name = SelfCodingPublish.toolName(from: step.target)
        let json = SelfCodingPublish.exportJSON(name: name, spec: spec)
        // SV-17 close — register the definition into the buyer's LOCAL MCP tool registry (the
        // sovereign-live tools lane). On a wired runtime this succeeds and the tool is now live-callable
        // locally; on the sandboxed build the no-op registrar returns false and we say so honestly —
        // the portable JSON is still handed over. Either way it's ONE receipt.
        let (registered, regMsg) = registrar(name, json)
        let reason = registered
            ? "Published \u{201C}\(name)\u{201D} to your local MCP tool registry (\(regMsg)). It can be undone — rolling back this step also unregisters it."
            : "Exported \u{201C}\(name)\u{201D} as an MCP tool definition. \(SelfCodingPublish.honestNote)"
        recordReceipt(.allow(reason: reason), tool: step.tool, target: step.target, extra: json)
        var s = step
        s.published = true
        if registered { s.registeredToolName = name }
        trace[idx] = s
        return json
    }
}
#endif // circuit-convert
