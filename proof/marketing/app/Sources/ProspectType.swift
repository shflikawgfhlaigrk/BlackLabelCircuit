// Black Label Marketing — the business-type vocabulary.
//
// Lifted verbatim out of LeadDomain.swift. Reason: Sources/LeadFinder.swift stamps every
// DiscoveredLead with a ProspectType, and LeadDomain.swift pulls in SwiftUI and the whole Lead /
// CRM graph — which would make the finder impossible to compile (and therefore impossible to
// EXECUTE) in the headless suite that proves its consent refusal. Pure Foundation, no behaviour
// change, same on-wire raw values so persisted data still decodes.
import Foundation

// Business type drives type-aware outreach (keyed to the prospect's business type).
enum ProspectType: String, Codable, CaseIterable, Identifiable {
    case realEstate, agency, ecommerce, restaurant, fitness, dental, legal, contractor, saas, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .realEstate: return "Real Estate"; case .agency: return "Agency"; case .ecommerce: return "E-commerce"
        case .restaurant: return "Restaurant"; case .fitness: return "Fitness / Gym"; case .dental: return "Dental"
        case .legal: return "Legal"; case .contractor: return "Contractor / Trades"; case .saas: return "SaaS"
        case .other: return "Other"
        }
    }
}

