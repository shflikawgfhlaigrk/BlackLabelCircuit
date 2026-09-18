// Black Label Marketing — Audience / Segmentation engine + Email Builder.
//
// Everything here runs on the BUYER's OWN data (their CRM leads + saved clients),
// fully on-device. No network, no fabrication: segments are pure boolean rules,
// personalization resolves only from real contact fields (missing -> neutral
// fallback, never invented), and a "send" hands a personalized email to the
// buyer's own mail client via mailto (we log "Composed", never a fake "Delivered").
//
// The pure logic in this file is mirrored by Tests/AudienceTests.swift.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

// MARK: - Unified contact (projected from the buyer's CRM + saved clients)

/// A contact the segment engine evaluates. Built from CapturedLead (CRM) and
/// ClientLead (saved businesses) so a segment can span both pools.
struct Contact: Identifiable, Hashable {
    let id: UUID
    var name = ""
    var email = ""
    var phone = ""
    var company = ""
    var industry = ""
    var city = ""
    var tags: [String] = []
    var source = ""          // campaign / origin label
    var created = Date()      // when the contact entered the system
    var origin: String = ""  // "CRM lead" or "Saved client" (for the UI)

    /// Whole-day age of the contact (0 = today). Drives recency rules.
    var createdDaysAgo: Int {
        max(0, Calendar.current.dateComponents([.day], from: created, to: Date()).day ?? 0)
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    /// Project the buyer's own CRM leads + saved clients into one contact pool.
    /// Real data only — nothing synthesized. De-dupes by lowercased email then name.
    ///
    /// CACHED: rebuilding + deduping this pool is O(leads + clients) and was previously
    /// re-run several times per render (and once per row / per segment) on the heavy
    /// screens. We memoize the result keyed on `contactsGeneration` (bumped only when
    /// `leads`/`clients`/`postStats` mutate), so repeated reads in one render are O(1).
    var allContacts: [Contact] {
        if _contactsCacheGen == contactsGeneration, let cached = _contactsCache { return cached }
        let built = Self.buildContacts(leads: leads)
        _contactsCache = built
        _contactsCacheGen = contactsGeneration
        return built
    }

    /// Pure builder (no `self` state) so it is trivially testable and side-effect free.
    /// Projects the unified Lead pool (site forms, finder hits, DB imports, manual adds).
    static func buildContacts(leads: [Lead]) -> [Contact] {
        var out: [Contact] = []
        out.reserveCapacity(leads.count)
        for l in leads {
            let industry = l.industry.isEmpty ? (l.type == .other ? "" : l.type.label) : l.industry
            out.append(Contact(id: l.id, name: l.name, email: l.email, phone: l.phone,
                               company: l.company, industry: industry, city: addrCity(l.address),
                               tags: l.tags, source: l.sourceCampaign, created: l.created,
                               origin: l.source.label))
        }
        // De-dupe: prefer the first occurrence.
        var seen = Set<String>(); seen.reserveCapacity(out.count)
        var deduped: [Contact] = []; deduped.reserveCapacity(out.count)
        for c in out {
            let key = c.email.isEmpty ? "name:\(c.name.lowercased())" : "email:\(c.email.lowercased())"
            if key == "name:" { deduped.append(c); continue }   // truly anonymous, keep
            if seen.contains(key) { continue }; seen.insert(key)
            deduped.append(c)
        }
        return deduped
    }
    /// Best-effort city from a saved client's free-form address ("123 Main, Austin").
    fileprivate static func addrCity(_ address: String) -> String {
        let parts = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.count >= 2 ? parts[parts.count - 1] : ""
    }
}
#endif // circuit-convert

// MARK: - Segment rules

enum SegField: String, CaseIterable, Codable, Identifiable {
    case name, email, phone, company, industry, city, source, tag, recencyDays
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"; case .email: return "Email"; case .phone: return "Phone"
        case .company: return "Company"; case .industry: return "Industry"; case .city: return "City"
        case .source: return "Campaign/source"; case .tag: return "Tag"; case .recencyDays: return "Added (days ago)"
        }
    }
}

enum SegOp: String, CaseIterable, Codable, Identifiable {
    case contains, equals, notEquals, startsWith, isEmpty, isNotEmpty, hasTag, withinDays, olderThanDays
    var id: String { rawValue }
    var label: String {
        switch self {
        case .contains: return "contains"; case .equals: return "is"; case .notEquals: return "is not"
        case .startsWith: return "starts with"; case .isEmpty: return "is empty"; case .isNotEmpty: return "is not empty"
        case .hasTag: return "has tag"; case .withinDays: return "within (days)"; case .olderThanDays: return "older than (days)"
        }
    }
    /// Whether this operator needs a value field in the UI.
    var needsValue: Bool {
        switch self { case .isEmpty, .isNotEmpty: return false; default: return true }
    }
    /// Operators that make sense for a given field (recency is numeric-only).
    static func valid(for field: SegField) -> [SegOp] {
        switch field {
        case .recencyDays: return [.withinDays, .olderThanDays]
        case .tag: return [.hasTag, .isEmpty, .isNotEmpty]
        default: return [.contains, .equals, .notEquals, .startsWith, .isEmpty, .isNotEmpty]
        }
    }
}

struct SegRule: Identifiable, Codable, Hashable {
    var id = UUID()
    var field: SegField = .city
    var op: SegOp = .contains
    var value: String = ""
}

enum SegMatch: String, Codable, CaseIterable, Identifiable {
    case all, any
    var id: String { rawValue }
    var label: String { self == .all ? "Match ALL rules (AND)" : "Match ANY rule (OR)" }
}

/// A saved, named audience segment (persisted with the buyer's data).
struct Segment: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var match: SegMatch = .all
    var rules: [SegRule] = []
    var created = Date()
}

// MARK: - Segment evaluation engine (pure)

enum SegEngine {
    static func ruleMatches(_ r: SegRule, _ c: Contact) -> Bool {
        func field(_ f: SegField) -> String {
            switch f {
            case .name: return c.name
            case .email: return c.email
            case .phone: return c.phone
            case .company: return c.company
            case .industry: return c.industry
            case .city: return c.city
            case .source: return c.source
            case .tag: return c.tags.joined(separator: ",")
            case .recencyDays: return String(c.createdDaysAgo)
            }
        }
        let lhs = field(r.field).lowercased().trimmingCharacters(in: .whitespaces)
        let rhs = r.value.lowercased().trimmingCharacters(in: .whitespaces)
        switch r.op {
        case .contains:      return rhs.isEmpty ? true : lhs.contains(rhs)
        case .equals:        return lhs == rhs
        case .notEquals:     return lhs != rhs
        case .startsWith:    return lhs.hasPrefix(rhs)
        case .isEmpty:       return lhs.isEmpty
        case .isNotEmpty:    return !lhs.isEmpty
        case .hasTag:        return c.tags.contains { $0.lowercased().trimmingCharacters(in: .whitespaces) == rhs }
        case .withinDays:    return (Int(rhs) ?? 0) >= c.createdDaysAgo
        case .olderThanDays: return c.createdDaysAgo > (Int(rhs) ?? 0)
        }
    }
    static func matches(_ seg: Segment, _ c: Contact) -> Bool {
        guard !seg.rules.isEmpty else { return true }   // empty segment = everyone
        switch seg.match {
        case .all: return seg.rules.allSatisfy { ruleMatches($0, c) }
        case .any: return seg.rules.contains { ruleMatches($0, c) }
        }
    }
    static func evaluate(_ seg: Segment, over contacts: [Contact]) -> [Contact] {
        contacts.filter { matches(seg, $0) }
    }
    /// Live count for the segment builder (shown as the buyer edits rules).
    static func count(_ seg: Segment, over contacts: [Contact]) -> Int {
        contacts.reduce(0) { $0 + (matches(seg, $1) ? 1 : 0) }
    }
}

// MARK: - Personalization tokens

enum Personalize {
    static func firstName(_ full: String) -> String {
        full.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
    }
    /// Resolve {{token}} (and {{ token }}) against a real contact. Missing fields
    /// fall back to neutral defaults — never an invented value. Unknown tokens are
    /// stripped so a raw {{token}} is never shipped in a sent email.
    static func render(_ template: String, for c: Contact, fallbackName: String = "there") -> String {
        var out = template
        let fn = firstName(c.name)
        let map: [String: String] = [
            "first_name": fn.isEmpty ? fallbackName : fn,
            "name": c.name.isEmpty ? fallbackName : c.name,
            "company": c.company.isEmpty ? (c.name.isEmpty ? "your business" : c.name) : c.company,
            "city": c.city,
            "industry": c.industry,
            "email": c.email,
        ]
        for (k, v) in map {
            out = out.replacingOccurrences(of: "{{\(k)}}", with: v)
            out = out.replacingOccurrences(of: "{{ \(k) }}", with: v)
        }
        while let open = out.range(of: "{{"), let close = out.range(of: "}}", range: open.upperBound..<out.endIndex) {
            out.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return out
    }
    static let tokens = ["first_name", "name", "company", "city", "industry", "email"]
}

// MARK: - Email builder (block-based, compiles to text + XSS-safe HTML)

enum EmailBlockKind: String, CaseIterable, Codable, Identifiable {
    case heading, paragraph, button, divider, spacer
    var id: String { rawValue }
    var label: String {
        switch self {
        case .heading: return "Heading"; case .paragraph: return "Text"; case .button: return "Button"
        case .divider: return "Divider"; case .spacer: return "Spacer"
        }
    }
    var icon: String {
        switch self {
        case .heading: return "textformat.size.larger"; case .paragraph: return "text.alignleft"
        case .button: return "capsule.fill"; case .divider: return "minus"; case .spacer: return "arrow.up.and.down"
        }
    }
}

struct EmailBlock: Identifiable, Codable, Hashable {
    var id = UUID()
    var kind: EmailBlockKind = .paragraph
    var text: String = ""
    var url: String = ""
}

/// A saved email campaign: a subject + ordered blocks, optionally an A/B variant.
struct EmailCampaign: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String = ""
    var subject: String = ""
    var blocks: [EmailBlock] = []
    // A/B (optional): when enabled, half the segment gets variantB's subject/blocks.
    var abEnabled: Bool = false
    var subjectB: String = ""
    var blocksB: [EmailBlock] = []
    var segmentID: UUID? = nil
    var created = Date()
}

enum EmailBuilder {
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
    static func plainText(_ blocks: [EmailBlock], for c: Contact) -> String {
        blocks.compactMap { b -> String? in
            let t = Personalize.render(b.text, for: c)
            switch b.kind {
            case .heading:   return t.isEmpty ? nil : t.uppercased()
            case .paragraph: return t.isEmpty ? nil : t
            case .button:    let u = b.url.trimmingCharacters(in: .whitespaces); return u.isEmpty ? (t.isEmpty ? nil : t) : "\(t): \(u)"
            case .divider:   return "----------"
            case .spacer:    return ""
            }
        }.joined(separator: "\n\n")
    }
    static func html(_ blocks: [EmailBlock], for c: Contact, accentHex: String = "#D9B65C") -> String {
        let body = blocks.map { b -> String in
            let t = esc(Personalize.render(b.text, for: c))
            switch b.kind {
            case .heading:   return "<h1 style=\"font-family:-apple-system,sans-serif;color:#111;font-size:24px;margin:0 0 12px\">\(t)</h1>"
            case .paragraph: return "<p style=\"font-family:-apple-system,sans-serif;color:#333;line-height:1.6;font-size:15px;margin:0 0 14px\">\(t)</p>"
            case .button:    let u = HTMLSafe.safeURL(b.url); return "<p style=\"margin:6px 0 18px\"><a href=\"\(u)\" style=\"display:inline-block;background:\(accentHex);color:#1A1305;font-weight:700;padding:12px 24px;border-radius:8px;text-decoration:none;font-family:-apple-system,sans-serif\">\(t)</a></p>"
            case .divider:   return "<hr style=\"border:none;border-top:1px solid #e2e2e2;margin:18px 0\">"
            case .spacer:    return "<div style=\"height:18px\"></div>"
            }
        }.joined(separator: "\n")
        return "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body style=\"margin:0;padding:24px;background:#f6f6f6\"><div style=\"max-width:560px;margin:0 auto;background:#fff;padding:28px;border-radius:12px;box-shadow:0 1px 4px rgba(0,0,0,.06)\">\(body)</div></body></html>"
    }
    /// Deterministic even A/B split: contact i -> variant (i % 2). Stable by index.
    static func abVariant(index: Int) -> Int { index % 2 }
}

// MARK: - Persistence additions (segments + email campaigns)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    func addSegment(_ s: Segment) { segments.insert(s, at: 0) }
    func upsertSegment(_ s: Segment) {
        if let i = segments.firstIndex(where: { $0.id == s.id }) { segments[i] = s } else { segments.insert(s, at: 0) }
    }
    func deleteSegment(_ s: Segment) { segments.removeAll { $0.id == s.id } }

    func upsertCampaign(_ c: EmailCampaign) {
        if let i = campaigns.firstIndex(where: { $0.id == c.id }) { campaigns[i] = c } else { campaigns.insert(c, at: 0) }
    }
    func deleteCampaign(_ c: EmailCampaign) { campaigns.removeAll { $0.id == c.id } }

    /// Record an audit result in the buyer's own history (newest first, last 50).
    func logAudit(_ a: AuditRecord) {
        audits.insert(a, at: 0)
        if audits.count > 50 { audits = Array(audits.prefix(50)) }
    }
    func deleteAudit(_ a: AuditRecord) { audits.removeAll { $0.id == a.id } }
}
#endif // circuit-convert
