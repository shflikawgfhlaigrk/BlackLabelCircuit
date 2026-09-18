// Black Label Marketing — MK-17 buyer-key WATERFALL enrichment (chained, cached, honest).
//
// The parity gap this closes: paid tools (Clay, Bettercontact, Prospeo's own waterfall) chain several
// data providers so that if provider A misses, provider B is tried — maximizing the hit rate — and bill
// you per look-up. We give the buyer the SAME waterfall on THEIR OWN provider keys, running ON-DEVICE,
// and we CACHE every outcome on the local lead so a re-run is instant and FREE (never re-hits a paid
// provider for an answer we already have). Structurally this stays inside the LOCAL-PII-CUSTODY wedge:
// every request goes to the buyer's own provider host (EnrichmentProviderClient enforces the host
// invariant); a lead's name/domain is NEVER proxied through our own leads API.
//
// This file is PURE (no I/O of its own — the transport is injected as EnrichmentProviderClient.Send),
// so the whole waterfall + cache path is unit-tested with canned fixtures. Zero fabrication: a chain
// that finds nothing yields no email and an honest exhausted-miss record — it never invents an address,
// a winner, or a per-provider yield number.
import Foundation

// MARK: - per-vendor attempt outcome (honest; per-provider yield renders from REAL outcomes only)
enum WaterfallOutcome: Equatable {
    case hit(email: String, confidence: Int?)   // this vendor returned a confirmed address
    case noMatch                                 // this vendor ran, found nothing (honest)
    case skipped(reason: String)                 // no key connected — NEVER counted as a miss
    case error(String)                           // transport/HTTP/decode — surfaced, never hidden

    /// The compact tag persisted in EnrichmentCacheEntry.attemptsSummary.
    var tag: String {
        switch self {
        case .hit: return "hit"; case .noMatch: return "noMatch"
        case .skipped: return "skipped"; case .error: return "error"
        }
    }
}

struct VendorAttempt: Equatable {
    var vendor: EnrichmentVendor
    var outcome: WaterfallOutcome
    var didHit: Bool { if case .hit = outcome { return true }; return false }
    /// A REAL network attempt was made (hit / noMatch / error). A skipped vendor did not run and must
    /// never be counted as tried in any yield/coverage number.
    var ran: Bool { if case .skipped = outcome { return false }; return true }
}

// MARK: - the result of running a full ordered chain
struct WaterfallResult: Equatable {
    var attempts: [VendorAttempt] = []
    var winner: EnrichmentVendor? = nil      // the FIRST vendor to return a confirmed hit
    var email: String = ""                   // the winning confirmed address ("" if the chain exhausted)
    var confidence: Int? = nil
    var fromCache: Bool = false              // true when reconstructed from the local cache (no network)
    var isHit: Bool { !email.isEmpty }
    /// How many vendors actually ran a network attempt (skipped-no-key vendors excluded — honest).
    var ranCount: Int { attempts.filter { $0.ran }.count }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum EnrichmentWaterfall {
    /// The signature that keys the local cache — the SAME name+domain always maps to the same slot, so a
    /// re-enrichment of an unchanged lead is served from cache with zero network.
    static func signature(name: String, domain: String) -> String {
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let d = EmailEngine.normalizeDomain(domain)
        return "\(n)|\(d)"
    }

    /// Reconstruct a result from the lead's cache WITHOUT any network, IFF the cache was computed for
    /// this exact name+domain. Returns nil when there's no cache or the lead changed (forcing a fresh
    /// run). This is the "instant + free" re-enrichment path — the cache-hit-means-no-network contract.
    static func cached(_ entry: EnrichmentCacheEntry?, name: String, domain: String) -> WaterfallResult? {
        guard let e = entry, e.signature == signature(name: name, domain: domain) else { return nil }
        var r = WaterfallResult()
        r.fromCache = true
        r.email = e.email
        r.confidence = e.confidence
        r.winner = e.winner.isEmpty ? nil : EnrichmentVendor(rawValue: e.winner)
        return r
    }

    /// Run the buyer's ORDERED provider chain until the FIRST confirmed hit, then STOP (the whole point
    /// of a waterfall — don't spend a second provider's quota once we have an address). `keyFor` returns
    /// the buyer's stored key for a vendor; a nil/empty key SKIPS that vendor (never a miss). Every
    /// attempt is recorded honestly. Never fabricates: an exhausted chain returns an empty result.
    static func run(name: String, domain: String, chain: [EnrichmentVendor],
                    keyFor: (EnrichmentVendor) -> String?,
                    send: @escaping EnrichmentProviderClient.Send = EnrichmentProviderClient.liveSend) async -> WaterfallResult {
        var out = WaterfallResult()
        // De-dupe while preserving order so a buyer who lists a provider twice doesn't double-bill it.
        var seen = Set<EnrichmentVendor>()
        for vendor in chain where seen.insert(vendor).inserted {
            guard let key = keyFor(vendor)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                out.attempts.append(VendorAttempt(vendor: vendor, outcome: .skipped(reason: "no key connected")))
                continue
            }
            do {
                let r = try await EnrichmentProviderClient.find(name: name, domain: domain, vendor: vendor,
                                                                apiKey: key, send: send)
                out.attempts.append(VendorAttempt(vendor: vendor, outcome: .hit(email: r.email, confidence: r.confidence)))
                out.winner = vendor; out.email = r.email; out.confidence = r.confidence
                return out   // first confirmed hit wins — stop the waterfall here
            } catch EnrichmentProviderError.noMatch {
                out.attempts.append(VendorAttempt(vendor: vendor, outcome: .noMatch))
            } catch let e as EnrichmentProviderError {
                out.attempts.append(VendorAttempt(vendor: vendor, outcome: .error(e.errorDescription ?? "provider error")))
            } catch {
                out.attempts.append(VendorAttempt(vendor: vendor, outcome: .error(error.localizedDescription)))
            }
        }
        return out   // exhausted the chain with no confirmed hit — honest empty (no fabrication)
    }

    /// Build the cache record to persist on the lead from a completed (non-cache) run.
    static func cacheEntry(name: String, domain: String, result: WaterfallResult, at: Date = Date()) -> EnrichmentCacheEntry {
        EnrichmentCacheEntry(signature: signature(name: name, domain: domain),
                             winner: result.winner?.rawValue ?? "",
                             email: result.email,
                             confidence: result.confidence,
                             at: at,
                             attemptsSummary: result.attempts.map { "\($0.vendor.rawValue):\($0.outcome.tag)" })
    }

    /// Per-provider yield across the buyer's REAL cached results — how many confirmed hits each vendor
    /// won. Pure count over stored outcomes; renders nothing it can't source. Never estimated.
    static func providerYield(_ entries: [EnrichmentCacheEntry]) -> [(vendor: String, hits: Int)] {
        var counts: [String: Int] = [:]
        for e in entries where e.isHit && !e.winner.isEmpty { counts[e.winner, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                     .map { (vendor: $0.key, hits: $0.value) }
    }
}
#endif // circuit-convert
