// Black Label Marketing — lead engines merged from Black Label Leads (2026-07).
// Type-aware outreach drafting + CAN-SPAM lint and the Overpass/Maps query builders. Entirely
// on-device: after the 2026-08 split this file contains NO network call at all.
//
// Three neighbours were lifted out of here so the finder lane could be built and executed without
// the SwiftUI half of the app (that is what makes its consent refusal provable at runtime rather
// than by grep):
//   • Sources/EmailEngine.swift — the email-pattern permutation engine
//   • Sources/Metros.swift      — the built-in US metro catalog
//   • Sources/LeadFinder.swift  — the OpenStreetMap industry lead finder itself
import Foundation
// MARK: - Outreach engine (type-aware drafting + CAN-SPAM lint; on-device, no network)
// Mirrors the website: "drafts type-aware outreach for the niche ... CAN-SPAM checked before it sends".
struct ComplianceCheck: Identifiable, Hashable {
    let id = UUID()
    let ok: Bool
    let label: String
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum OutreachEngine {
    /// Per-type angle the opening line is keyed to (real, hand-written templates per niche).
    private static func angle(_ t: ProspectType) -> (hook: String, value: String) {
        switch t {
        case .realEstate: return ("the listing volume your team is moving this quarter",
                                  "fill your pipeline with pre-qualified buyer and seller leads without buying another portal subscription")
        case .agency:     return ("the client roster you're scaling right now",
                                  "add a white-label outbound lane so you can book retainers without hiring an SDR")
        case .ecommerce:  return ("the catalog you're driving traffic to",
                                  "recover abandoned carts and re-engage past buyers with sends that actually land")
        case .restaurant: return ("the covers you're turning each week",
                                  "keep tables full on slow nights with targeted local outreach")
        case .fitness:    return ("the members you're signing this month",
                                  "cut churn and refill class slots with timed follow-ups")
        case .dental:     return ("the new-patient flow at your practice",
                                  "book more recall and new-patient appointments without ad spend creeping up")
        case .legal:      return ("the caseload your firm is intaking",
                                  "turn more consultations into signed matters with a steady intake cadence")
        case .contractor: return ("the jobs you're bidding this season",
                                  "keep the calendar booked with qualified local project leads")
        case .saas:       return ("the accounts your team is closing this quarter",
                                  "open more qualified pipeline with outbound that's logged and measured end to end")
        case .other:      return ("what you're working to grow this quarter",
                                  "open a steady, measured lane of new conversations")
        }
    }

    /// Generate a real, type-aware outreach draft for a prospect. Personalized by name/company/type.
    /// (Full message incl. Subject line — used by the in-app editor preview.)
    static func draft(for p: Lead, senderName: String = "") -> String {
        let company = p.company.isEmpty ? "your team" : p.company
        return "Subject: Quick idea for \(company)\n\n" + draftBody(for: p, senderName: senderName)
    }

    /// Just the message BODY (no Subject line) — used by the send path / template engine.
    static func draftBody(for p: Lead, senderName: String = "") -> String {
        let firstName = p.name.split(separator: " ").first.map(String.init) ?? "there"
        let company = p.company.isEmpty ? "your team" : p.company
        let a = angle(p.type)
        // Brand isolation: never sign buyer mail with the app-maker's brand.
        let signOff = senderName.isEmpty ? "The team" : senderName
        return """
        Hi \(firstName),

        I was looking at \(a.hook) at \(company) and had one specific idea: we help \(p.type.label.lowercased()) operators \(a.value).

        If it's useful, I can send over a short, no-pressure breakdown of how it would work for \(company) — takes two minutes to read.

        Worth a quick look?

        — \(signOff)
        """
    }

    /// CAN-SPAM style lint: honest, surface-level checks on a draft (not legal advice).
    static func compliance(_ draft: String, prospect: Lead) -> [ComplianceCheck] {
        let lower = draft.lowercased()
        return [
            ComplianceCheck(ok: lower.contains("subject:"), label: "Has a clear, non-deceptive subject line"),
            ComplianceCheck(ok: lower.contains("stop") || lower.contains("opt out") || lower.contains("unsubscribe"),
                            label: "Includes an opt-out / unsubscribe instruction"),
            ComplianceCheck(ok: lower.contains("black label") || !prospect.company.isEmpty,
                            label: "Identifies the sender"),
            ComplianceCheck(ok: lower.contains("commercial message") || lower.contains("advertisement"),
                            label: "Discloses it is a commercial message"),
            ComplianceCheck(ok: !prospect.email.isEmpty, label: "Has a deliverable recipient address")
        ]
    }
}
#endif // circuit-convert

// MARK: - Query builder (real OpenStreetMap Overpass QL + Google Maps URL)
enum QueryBuilder {
    /// Build a real Overpass QL query for a keyword/vertical near a metro (bbox ~ +/-0.15 deg).
    static func overpass(keyword: String, metro: Metro) -> String {
        let k = keyword.trimmingCharacters(in: .whitespaces).lowercased()
        let d = 0.15
        let s = String(format: "%.4f", metro.lat - d)
        let w = String(format: "%.4f", metro.lon - d)
        let n = String(format: "%.4f", metro.lat + d)
        let e = String(format: "%.4f", metro.lon + d)
        let bbox = "(\(s),\(w),\(n),\(e))"
        return """
        [out:json][timeout:25];
        (
          node["shop"~"\(k)",i]\(bbox);
          node["amenity"~"\(k)",i]\(bbox);
          node["office"~"\(k)",i]\(bbox);
          node["name"~"\(k)",i]\(bbox);
        );
        out body;
        >;
        out skel qt;
        """
    }

    /// Build a real Google Maps search URL.
    static func googleMaps(keyword: String, metro: Metro) -> String {
        let q = "\(keyword) in \(metro.city), \(metro.state)"
        let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        return "https://www.google.com/maps/search/\(enc)"
    }
}


#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AppModel {
    /// Convert a discovered business into a saved lead (company = business, role-based email, no person name).
    @discardableResult
    func saveDiscovered(_ d: DiscoveredLead) -> Lead {
        let note = [d.address, d.phone].filter { !$0.isEmpty }.joined(separator: " · ")
        let p = Lead(name: "", company: d.name, domain: d.domain, email: d.suggestedEmail,
                         status: .new, notes: note, type: d.type)
        upsert(p)
        return p
    }
    /// True if a discovered business is already saved (by name+domain).
    func alreadySaved(_ d: DiscoveredLead) -> Bool {
        leads.contains { $0.company.caseInsensitiveCompare(d.name) == .orderedSame && $0.domain == d.domain }
    }
}
#endif // circuit-convert
