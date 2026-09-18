// Black Label Marketing — email-pattern permutation engine.
//
// Lifted verbatim out of LeadEngines.swift so the lead-finder lane (Sources/LeadFinder.swift) can
// be compiled and EXECUTED on its own in the headless suite: `DiscoveredLead.domain` calls
// EmailEngine.normalizeDomain, and dragging in the whole of LeadEngines.swift would drag in the
// SwiftUI-dependent Lead/AppModel graph with it. On-device only; no network.
import Foundation

// MARK: - Email pattern engine (real permutations, no network)
struct EmailCandidate: Identifiable, Hashable {
    let id = UUID()
    let address: String
    let pattern: String
    let top: Bool
}

enum EmailEngine {
    /// Normalize a raw domain string ("Acme Inc", "https://acme.com/", "@acme.com") -> "acme.com".
    static func normalizeDomain(_ raw: String) -> String {
        var d = raw.lowercased().trimmingCharacters(in: .whitespaces)
        d = d.replacingOccurrences(of: "https://", with: "")
        d = d.replacingOccurrences(of: "http://", with: "")
        d = d.replacingOccurrences(of: "www.", with: "")
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        d = d.replacingOccurrences(of: "@", with: "")
        return d.trimmingCharacters(in: .whitespaces)
    }

    private static func clean(_ s: String) -> String {
        let allowed = CharacterSet.lowercaseLetters
        return String(s.lowercased().unicodeScalars.filter { allowed.contains($0) })
    }

    /// Split a full name into (first, last). Handles single names.
    static func splitName(_ name: String) -> (String, String) {
        let parts = name.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard let first = parts.first else { return ("", "") }
        let last = parts.count > 1 ? parts.last! : ""
        return (clean(first), clean(last))
    }

    /// Generate the real common business-email permutations for a name + domain.
    static func candidates(name: String, domain rawDomain: String) -> [EmailCandidate] {
        let domain = normalizeDomain(rawDomain)
        let (f, l) = splitName(name)
        guard !domain.isEmpty, !f.isEmpty else { return [] }
        let fi = String(f.prefix(1))
        let li = l.isEmpty ? "" : String(l.prefix(1))

        var specs: [(String, String)] = []   // (local, patternLabel)
        if !l.isEmpty {
            specs = [
                ("\(f).\(l)",  "first.last@"),
                ("\(fi)\(l)",  "flast@"),
                ("\(f)\(l)",   "firstlast@"),
                ("\(fi).\(l)", "f.last@"),
                ("\(f)",       "first@"),
                ("\(f)_\(l)",  "first_last@"),
                ("\(f).\(li)", "first.l@"),
                ("\(l).\(f)",  "last.first@"),
                ("\(l)\(fi)",  "lastf@"),
            ]
        } else {
            specs = [("\(f)", "first@")]
        }

        // De-dup while preserving order; mark first.last@ as the top pick.
        var seen = Set<String>()
        var out: [EmailCandidate] = []
        for (local, pat) in specs {
            let addr = "\(local)@\(domain)"
            if seen.contains(addr) { continue }
            seen.insert(addr)
            out.append(EmailCandidate(address: addr, pattern: pat, top: pat == "first.last@"))
        }
        // Ensure the top pick floats to the front.
        out.sort { $0.top && !$1.top }
        return out
    }
}

