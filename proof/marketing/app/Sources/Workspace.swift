// Black Label Marketing (lead engine, merged from Black Label Leads) — RBAC / workspace + roles (Tier-2).
// A real role model + scoped permission engine. Single-user-default: on first run the buyer is the
// sole Admin/owner, so NOTHING is locked — the gate only tightens when they add teammates and choose
// to "act as" one. On-device, Codable snapshots in the app's SQLite workspace. No seeded data, no
// network, no Michael info. Every permission decision is a pure function of (role, capability).
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - capabilities (the gateable actions in the product)
enum Capability: String, CaseIterable, Codable {
    case viewLeads          // see the lead/account DB
    case editLeads          // create / update a lead
    case deleteLeads        // delete / bulk-delete
    case importLeads        // CSV / bulk import
    case exportData         // CSV export / CRM push
    case sendOutreach       // send email / enroll in a sequence / place calls
    case editTemplates      // edit outreach templates & sequences
    case editPipeline       // reorder / rename pipeline stages
    case editWorkflows      // create / edit automation rules
    case manageMembers      // add / remove / re-role teammates
    case manageWorkspace    // branding, billing, connectors, destructive workspace ops
    var label: String {
        switch self {
        case .viewLeads: return "View leads"; case .editLeads: return "Edit leads"
        case .deleteLeads: return "Delete leads"; case .importLeads: return "Import leads"
        case .exportData: return "Export / push data"; case .sendOutreach: return "Send outreach"
        case .editTemplates: return "Edit templates & sequences"; case .editPipeline: return "Edit pipeline"
        case .editWorkflows: return "Edit workflows"; case .manageMembers: return "Manage members"
        case .manageWorkspace: return "Manage workspace"
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - roles (Admin / Manager / Rep) with a real, fixed capability matrix
enum WorkspaceRole: String, CaseIterable, Codable, Identifiable {
    case admin, manager, rep
    var id: String { rawValue }
    var label: String { switch self { case .admin: return "Admin"; case .manager: return "Manager"; case .rep: return "Rep" } }
    var blurb: String {
        switch self {
        case .admin:   return "Full control — members, billing, connectors, and all data."
        case .manager: return "Manage leads, pipeline, templates & workflows; send outreach. No member/workspace control."
        case .rep:     return "Work assigned leads: view, edit, and send. No bulk-delete, member, or workspace control."
        }
    }
    var tint: Color { switch self { case .admin: return BLTheme.gold; case .manager: return .blue; case .rep: return BLTheme.green } }

    /// The fixed capability set per role. Admin ⊇ Manager ⊇ Rep, plus role-exclusive caps.
    var capabilities: Set<Capability> {
        switch self {
        case .admin:
            return Set(Capability.allCases)
        case .manager:
            return [.viewLeads, .editLeads, .deleteLeads, .importLeads, .exportData,
                    .sendOutreach, .editTemplates, .editPipeline, .editWorkflows]
        case .rep:
            return [.viewLeads, .editLeads, .importLeads, .exportData, .sendOutreach]
        }
    }
    func can(_ c: Capability) -> Bool { capabilities.contains(c) }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - a workspace member (a teammate the buyer adds)
struct WorkspaceMember: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var email: String = ""
    var role: WorkspaceRole = .rep
    var isOwner: Bool = false      // the original account holder — always Admin, cannot be demoted/removed
    var created = Date()
    var displayName: String { name.isEmpty ? (email.isEmpty ? "Member" : email) : name }
    var initials: String {
        let parts = displayName.split(separator: " ")
        let s = parts.prefix(2).compactMap { $0.first }.map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - the persisted workspace document
struct Workspace: Codable {
    var name: String = "My Workspace"
    var members: [WorkspaceMember] = []
    /// Lead ownership: prospectID -> memberID. A lead with no entry is "unassigned" (visible to Admin/Manager).
    var leadOwners: [UUID: UUID] = [:]
    /// Whether ownership scoping is enforced for Reps (a Rep only sees leads they own). Buyer-toggleable.
    var enforceLeadScoping: Bool = true

    init() {}
    enum CodingKeys: String, CodingKey { case name, members, leadOwners, enforceLeadScoping }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? "My Workspace"
        members = (try? c.decode([WorkspaceMember].self, forKey: .members)) ?? []
        // leadOwners decoded as [String:String] (JSON dict keys are strings) → rebuild UUID map.
        if let raw = try? c.decode([String: String].self, forKey: .leadOwners) {
            var m: [UUID: UUID] = [:]
            for (k, v) in raw { if let a = UUID(uuidString: k), let b = UUID(uuidString: v) { m[a] = b } }
            leadOwners = m
        } else { leadOwners = [:] }
        enforceLeadScoping = (try? c.decode(Bool.self, forKey: .enforceLeadScoping)) ?? true
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(members, forKey: .members)
        var raw: [String: String] = [:]
        for (k, v) in leadOwners { raw[k.uuidString] = v.uuidString }
        try c.encode(raw, forKey: .leadOwners)
        try c.encode(enforceLeadScoping, forKey: .enforceLeadScoping)
    }

    var owner: WorkspaceMember? { members.first { $0.isOwner } }
}
#endif // circuit-convert

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// MARK: - live store + the active-identity gate
final class TeamStore: ObservableObject {
    @Published var workspace: Workspace { didSet { save() } }
    /// The member the buyer is currently "acting as" (defaults to the owner). Drives every `can(...)` gate.
    @Published var actingMemberID: UUID

    static let blobName = "team"
    private let database: WorkspaceDatabase?

    /// `ephemeral` builds an in-memory store (tests). Production persists to the sandbox container.
    init(ephemeral: Bool = false) {
        if ephemeral {
            database = nil
            var ws = Workspace()
            let owner = WorkspaceMember(name: "Owner", email: "", role: .admin, isOwner: true)
            ws.members = [owner]
            workspace = ws
            actingMemberID = owner.id
            return
        }
        let db = WorkspaceDatabase(demo: DemoMode.active)
        database = db
        if let data = try? db.readBlob(named: Self.blobName),
           let ws = try? JSONDecoder().decode(Workspace.self, from: data), !ws.members.isEmpty {
            workspace = ws
            actingMemberID = ws.owner?.id ?? ws.members[0].id
        } else {
            // First run: the buyer is the sole Admin/owner. Nothing is locked.
            var ws = Workspace()
            let owner = WorkspaceMember(name: "Me", email: "", role: .admin, isOwner: true)
            ws.members = [owner]
            workspace = ws
            actingMemberID = owner.id
            save()
        }
    }
    private func save() {
        guard let database else { return }
        guard let data = try? JSONEncoder().encode(workspace) else { return }
        try? database.writeBlob(data, named: Self.blobName)
    }

    // MARK: active identity
    var currentMember: WorkspaceMember? { workspace.members.first { $0.id == actingMemberID } }
    var currentRole: WorkspaceRole { currentMember?.role ?? .admin }
    func actAs(_ memberID: UUID) { if workspace.members.contains(where: { $0.id == memberID }) { actingMemberID = memberID } }
    func actAsOwner() { if let o = workspace.owner { actingMemberID = o.id } }

    // MARK: the gate
    func can(_ c: Capability) -> Bool { currentRole.can(c) }

    /// Lead-ownership scope check: an Admin/Manager sees all; a Rep (when scoping is on) sees only
    /// leads they own. `leadOwner` is the assigned member (nil = unassigned).
    func canAccessLead(ownerID: UUID, leadOwner: UUID?) -> Bool {
        guard let m = workspace.members.first(where: { $0.id == ownerID }) else { return false }
        // Admin/Manager (or scoping disabled) see every lead, including unassigned ones.
        if m.role != .rep || !workspace.enforceLeadScoping { return true }
        // A scoped Rep sees only the leads explicitly assigned to them.
        return leadOwner == ownerID
    }
    /// True if the current acting member may see a given prospect (used to filter list views).
    func currentCanSee(prospectID: UUID) -> Bool {
        guard currentRole == .rep, workspace.enforceLeadScoping else { return true }
        return workspace.leadOwners[prospectID] == actingMemberID
    }

    // MARK: member management
    @discardableResult
    func addMember(name: String, email: String, role: WorkspaceRole) -> WorkspaceMember {
        let m = WorkspaceMember(name: name, email: email, role: role, isOwner: false)
        workspace.members.append(m)
        return m
    }
    func setRole(_ memberID: UUID, _ role: WorkspaceRole) {
        guard let i = workspace.members.firstIndex(where: { $0.id == memberID }), !workspace.members[i].isOwner else { return }
        workspace.members[i].role = role
    }
    func removeMember(_ memberID: UUID) {
        guard let m = workspace.members.first(where: { $0.id == memberID }), !m.isOwner else { return }
        workspace.members.removeAll { $0.id == memberID }
        for (lead, owner) in workspace.leadOwners where owner == memberID { workspace.leadOwners[lead] = nil }
        if actingMemberID == memberID { actAsOwner() }
    }
    func assignLead(_ prospectID: UUID, to memberID: UUID?) {
        if let memberID { workspace.leadOwners[prospectID] = memberID } else { workspace.leadOwners[prospectID] = nil }
    }
    func member(_ id: UUID?) -> WorkspaceMember? { id.flatMap { mid in workspace.members.first { $0.id == mid } } }
}
#endif // circuit-convert
