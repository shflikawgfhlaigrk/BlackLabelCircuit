// Black Label Marketing (lead engine, merged from Black Label Leads) — Custom workflow / rules builder (Tier-3 + Tier-6 rulesets).
// A real trigger → condition → action engine over the buyer's OWN data. "WHEN a reply is detected
// AND type == saas → create a task + move stage + tag." Every rule run is grounded — it only fires
// on a real event for a real prospect, and actions mutate real saved state (no fabricated runs).
// On-device, Codable snapshots. Conditions/actions are pure & deterministic so they are unit-testable.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - triggers (the events that can start a rule)
enum WorkflowTrigger: String, Codable, CaseIterable, Identifiable {
    case leadCreated, replyReceived, bounceReceived, emailSent, callLogged, stageEntered, leadImported
    var id: String { rawValue }
    var label: String {
        switch self {
        case .leadCreated: return "A lead is created"; case .replyReceived: return "A reply is detected"
        case .bounceReceived: return "A bounce is detected"; case .emailSent: return "An email is sent"
        case .callLogged: return "A call is logged"; case .stageEntered: return "A deal enters a stage"
        case .leadImported: return "A lead is imported"
        }
    }
    var icon: String {
        switch self {
        case .leadCreated: return "sparkles"; case .replyReceived: return "arrowshape.turn.up.left.fill"
        case .bounceReceived: return "exclamationmark.arrow.circlepath"; case .emailSent: return "paperplane.fill"
        case .callLogged: return "phone.fill"; case .stageEntered: return "arrow.right.circle.fill"
        case .leadImported: return "tray.and.arrow.down.fill"
        }
    }
}

// MARK: - condition fields + operators
enum RuleField: String, Codable, CaseIterable, Identifiable {
    case status, type, tag, email, phone, company, hasEmail
    var id: String { rawValue }
    var label: String {
        switch self {
        case .status: return "Status"; case .type: return "Business type"; case .tag: return "Tag"
        case .email: return "Email"; case .phone: return "Phone"; case .company: return "Company"
        case .hasEmail: return "Has deliverable email"
        }
    }
}

enum RuleOp: String, Codable, CaseIterable, Identifiable {
    case equals, notEquals, contains, isEmpty, isNotEmpty
    var id: String { rawValue }
    var label: String {
        switch self {
        case .equals: return "is"; case .notEquals: return "is not"; case .contains: return "contains"
        case .isEmpty: return "is empty"; case .isNotEmpty: return "is not empty"
        }
    }
    var needsValue: Bool { self == .equals || self == .notEquals || self == .contains }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - a single condition (ANDed within a rule)
struct RuleCondition: Identifiable, Codable, Hashable {
    var id = UUID()
    var field: RuleField = .status
    var op: RuleOp = .equals
    var value: String = ""

    /// The concrete value of a field on a prospect (lowercased for case-insensitive matching).
    private func fieldValue(_ p: Lead) -> String {
        switch field {
        case .status:   return p.status.rawValue.lowercased()
        case .type:     return p.type.rawValue.lowercased()
        case .tag:      return p.tags.joined(separator: " ").lowercased()
        case .email:    return p.email.lowercased()
        case .phone:    return p.phone.lowercased()
        case .company:  return p.company.lowercased()
        case .hasEmail: return p.email.isEmpty ? "" : "yes"
        }
    }
    /// Pure, deterministic match. Used by both the test harness and the live engine.
    func matches(_ p: Lead) -> Bool {
        let fv = fieldValue(p)
        let v = value.lowercased().trimmingCharacters(in: .whitespaces)
        switch op {
        case .equals:     return fv == v
        case .notEquals:  return fv != v
        case .contains:   return !v.isEmpty && fv.contains(v)
        case .isEmpty:    return fv.isEmpty
        case .isNotEmpty: return !fv.isEmpty
        }
    }
    /// Human-readable summary for the UI ("Status is replied").
    var summary: String {
        let v = op.needsValue ? " \(value)" : ""
        return "\(field.label) \(op.label)\(v)"
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - actions a rule performs (real mutations on saved state)
enum RuleAction: Codable, Hashable, Identifiable {
    case createTask(title: String)
    case moveToStage(stageID: UUID)
    case addTag(tag: String)
    case setStatus(status: ProspectStatus)
    case addNote(text: String)

    var id: String {
        switch self {
        case .createTask(let t): return "task:\(t)"; case .moveToStage(let s): return "stage:\(s)"
        case .addTag(let t): return "tag:\(t)"; case .setStatus(let s): return "status:\(s.rawValue)"
        case .addNote(let n): return "note:\(n)"
        }
    }
    var kindLabel: String {
        switch self {
        case .createTask: return "Create task"; case .moveToStage: return "Move to stage"
        case .addTag: return "Add tag"; case .setStatus: return "Set status"; case .addNote: return "Add note"
        }
    }
    var icon: String {
        switch self {
        case .createTask: return "checklist"; case .moveToStage: return "arrow.right.circle.fill"
        case .addTag: return "tag.fill"; case .setStatus: return "flag.fill"; case .addNote: return "text.bubble.fill"
        }
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - a workflow rule
struct WorkflowRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = "New rule"
    var trigger: WorkflowTrigger = .replyReceived
    var conditions: [RuleCondition] = []     // ALL must match (AND)
    var actions: [RuleAction] = []
    var enabled: Bool = true
    var created = Date()
    /// Real run counter (incremented only when the rule actually fires) — grounded, never fabricated.
    var fireCount: Int = 0
    var lastFired: Date? = nil

    var summary: String {
        let cond = conditions.isEmpty ? "always" : conditions.map { $0.summary }.joined(separator: " AND ")
        return "WHEN \(trigger.label.lowercased()) IF \(cond) → \(actions.count) action\(actions.count == 1 ? "" : "s")"
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - the engine (live execution on real AppModel state)
extension AppModel {
    /// Render the small token set actions support, against a real prospect.
    private func resolveTokens(_ s: String, _ p: Lead) -> String {
        let first = p.name.split(separator: " ").first.map(String.init) ?? (p.company.isEmpty ? "there" : p.company)
        return s
            .replacingOccurrences(of: "{{first}}", with: first)
            .replacingOccurrences(of: "{{company}}", with: p.company.isEmpty ? "your team" : p.company)
            .replacingOccurrences(of: "{{email}}", with: p.email)
    }

    /// Execute every enabled rule that matches this trigger for one prospect. Returns the number of
    /// rules that fired. Each fired rule runs ALL its actions (idempotent where it makes sense:
    /// tags/stage are no-ops if already applied). Mutations write to real saved state + the timeline.
    @discardableResult
    func runWorkflows(trigger: WorkflowTrigger, prospectID: UUID, stages: [DealStage]) -> Int {
        guard let p0 = leads.first(where: { $0.id == prospectID }) else { return 0 }
        var fired = 0
        for ri in workflowRules.indices {
            let rule = workflowRules[ri]
            guard rule.enabled, rule.trigger == trigger else { continue }
            // Re-read the prospect each rule (an earlier rule may have mutated it).
            guard let p = leads.first(where: { $0.id == prospectID }) else { break }
            guard rule.conditions.allSatisfy({ $0.matches(p) }) else { continue }
            // Fire: run actions in order.
            for action in rule.actions { apply(action, to: prospectID, rule: rule.name, stages: stages) }
            workflowRules[ri].fireCount += 1
            workflowRules[ri].lastFired = Date()
            fired += 1
        }
        _ = p0
        return fired
    }

    /// Apply a single action to a prospect (real mutation, grounded activity log).
    private func apply(_ action: RuleAction, to prospectID: UUID, rule: String, stages: [DealStage]) {
        guard let i = leads.firstIndex(where: { $0.id == prospectID }) else { return }
        switch action {
        case .createTask(let title):
            let t = LeadTask(prospectID: prospectID, title: resolveTokens(title, leads[i]), due: nil)
            addTask(t)
        case .moveToStage(let stageID):
            if let p = leads.first(where: { $0.id == prospectID }) {
                let deal = ensureDeal(for: p, stages: stages)
                if deal.stageID != stageID { moveDeal(deal, to: stageID, stages: stages) }   // idempotent
            }
        case .addTag(let tag):
            addTag(tag, to: prospectID)   // addTag already dedupes
        case .setStatus(let status):
            if leads[i].status != status { leads[i].status = status; log(prospectID, .status_changed, "\(status.label) (rule: \(rule))") }
        case .addNote(let text):
            let resolved = resolveTokens(text, leads[i])
            log(prospectID, .note, resolved)
        }
    }

    // CRUD for the rules list.
    func upsertWorkflow(_ r: WorkflowRule) {
        if let i = workflowRules.firstIndex(where: { $0.id == r.id }) { workflowRules[i] = r } else { workflowRules.append(r) }
    }
    func deleteWorkflow(_ r: WorkflowRule) { workflowRules.removeAll { $0.id == r.id } }
}
#endif // circuit-convert
