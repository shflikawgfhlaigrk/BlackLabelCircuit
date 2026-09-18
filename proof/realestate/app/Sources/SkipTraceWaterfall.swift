// Black Label Real Estate — RE-15 buyer-key skip-trace WATERFALL (chained, cached, honest).
//
// The parity gap this closes: paid tools (BatchLeads/DealMachine skip-trace, Clay-style waterfalls)
// chain several data providers so that if provider A misses, provider B is tried — maximizing the
// right-party hit-rate — and bill you per look-up. We give the buyer the SAME waterfall on THEIR OWN
// provider keys, running ON-DEVICE, and CACHE every outcome on the local lead so a re-run is instant
// and FREE (never re-hits a paid provider for an answer we already have). Structurally this stays
// inside the LOCAL-PII-CUSTODY wedge: every request goes to the buyer's own provider host
// (SkipTraceProvider.enrich enforces the host invariant); an owner's name/address is NEVER proxied
// through our own public-records index API.
//
// This file is PURE (no I/O of its own — the transport is injected as SkipTraceProvider.Send), so
// the whole waterfall + cache path is unit-tested with canned fixtures. Zero fabrication (§5.1): a
// chain that finds nothing yields no contact and an honest exhausted-miss record — it never invents
// a phone, an email, a winner, or a per-provider yield number. "We never fabricate contact info."
import Foundation

// MARK: - per-vendor attempt outcome (honest; per-provider yield renders from REAL outcomes only)
enum SkipWaterfallOutcome: Equatable {
    case hit(contact: SkipTraceContact)  // this vendor returned a confirmed phone/email
    case noMatch                          // this vendor ran, found nothing (honest)
    case skipped(reason: String)          // no key connected — NEVER counted as a miss
    case error(String)                    // transport/HTTP/decode — surfaced, never hidden

    /// The compact tag persisted in SkipTraceCacheEntry.attemptsSummary.
    var tag: String {
        switch self {
        case .hit: return "hit"; case .noMatch: return "noMatch"
        case .skipped: return "skipped"; case .error: return "error"
        }
    }
}

struct SkipVendorAttempt: Equatable {
    var vendor: SkipTraceVendor
    var outcome: SkipWaterfallOutcome
    var didHit: Bool { if case .hit = outcome { return true }; return false }
    /// A REAL network attempt was made (hit / noMatch / error). A skipped vendor did not run and must
    /// never be counted as tried in any yield/coverage number.
    var ran: Bool { if case .skipped = outcome { return false }; return true }
}

// MARK: - the result of running a full ordered chain
struct SkipWaterfallResult: Equatable {
    var attempts: [SkipVendorAttempt] = []
    var winner: SkipTraceVendor? = nil      // the FIRST vendor to return a confirmed contact
    var contact: SkipTraceContact = SkipTraceContact()  // the winning contact (empty if exhausted)
    var fromCache: Bool = false             // true when reconstructed from the local cache (no network)
    var isHit: Bool { !contact.isEmpty }
    /// How many vendors actually ran a network attempt (skipped-no-key vendors excluded — honest).
    var ranCount: Int { attempts.filter { $0.ran }.count }
}

// MARK: - Local cache record (persisted on the lead; the ONLY basis for a free re-trace / yield).
struct SkipTraceCacheEntry: Codable, Hashable {
    var signature: String
    var winner: String = ""              // winning vendor rawValue ("" on an exhausted miss)
    var phones: [String] = []
    var emails: [String] = []
    var matchedName: String = ""
    var at: Date = Date()
    var attemptsSummary: [String] = []   // ["batchData:noMatch","rocketSkip:hit"] — honest per-vendor
    var isHit: Bool { !phones.isEmpty || !emails.isEmpty }
    var contact: SkipTraceContact {
        var c = SkipTraceContact(); c.phones = phones; c.emails = emails; c.matchedName = matchedName; return c
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum SkipTraceWaterfall {
    /// The name a trace uses (recorded owner preferred over the raw lead name).
    static func traceName(_ lead: Lead) -> String {
        let n = lead.ownerName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? lead.name : n
    }
    /// The address a trace uses (owner mailing preferred, else the situs) — mirrors SkipTraceProvider.
    static func traceAddress(_ lead: Lead) -> String {
        let m = lead.mailingAddress.trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? lead.propertyAddress.trimmingCharacters(in: .whitespaces) : m
    }

    /// The signature that keys the local cache — the SAME name+address always maps to the same slot,
    /// so a re-trace of an unchanged lead is served from cache with zero network. Case/whitespace-
    /// insensitive so trivial edits still hit the cache.
    static func signature(name: String, address: String) -> String {
        func norm(_ s: String) -> String {
            s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).joined(separator: " ")
        }
        return "\(norm(name))|\(norm(address))"
    }

    /// Reconstruct a result from the lead's cache WITHOUT any network, IFF the cache was computed for
    /// this exact name+address. Returns nil when there's no cache or the lead changed (forcing a fresh
    /// run). This is the "instant + free" re-trace path — the cache-hit-means-no-network contract.
    static func cached(_ entry: SkipTraceCacheEntry?, name: String, address: String) -> SkipWaterfallResult? {
        guard let e = entry, e.signature == signature(name: name, address: address) else { return nil }
        var r = SkipWaterfallResult()
        r.fromCache = true
        r.contact = e.contact
        r.winner = e.winner.isEmpty ? nil : SkipTraceVendor(rawValue: e.winner)
        return r
    }

    /// Run the buyer's ORDERED provider chain until the FIRST confirmed contact, then STOP (the whole
    /// point of a waterfall — don't spend a second provider's credits once we have a phone/email).
    /// `keyFor` returns the buyer's stored key for a vendor; a nil/empty key SKIPS that vendor (never a
    /// miss). Every attempt is recorded honestly. Never fabricates: an exhausted chain returns empty.
    static func run(lead: Lead, chain: [SkipTraceVendor],
                    keyFor: (SkipTraceVendor) -> String?,
                    send: @escaping SkipTraceProvider.Send = SkipTraceProvider.liveSend) async -> SkipWaterfallResult {
        var out = SkipWaterfallResult()
        // De-dupe while preserving order so a buyer who lists a provider twice doesn't double-bill it.
        var seen = Set<SkipTraceVendor>()
        for vendor in chain where seen.insert(vendor).inserted {
            guard let key = keyFor(vendor)?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                out.attempts.append(SkipVendorAttempt(vendor: vendor, outcome: .skipped(reason: "no key connected")))
                continue
            }
            do {
                let contact = try await SkipTraceProvider.enrich(lead: lead, vendor: vendor, apiKey: key, send: send)
                if contact.isEmpty {
                    out.attempts.append(SkipVendorAttempt(vendor: vendor, outcome: .noMatch))  // honest, ran, no hit
                    continue
                }
                out.attempts.append(SkipVendorAttempt(vendor: vendor, outcome: .hit(contact: contact)))
                out.winner = vendor; out.contact = contact
                return out   // first confirmed contact wins — stop the waterfall here
            } catch let e as SkipTraceProviderError {
                out.attempts.append(SkipVendorAttempt(vendor: vendor, outcome: .error(e.errorDescription ?? "provider error")))
            } catch {
                out.attempts.append(SkipVendorAttempt(vendor: vendor, outcome: .error(error.localizedDescription)))
            }
        }
        return out   // exhausted the chain with no confirmed contact — honest empty (no fabrication)
    }

    /// Build the cache record to persist on the lead from a completed (non-cache) run.
    static func cacheEntry(lead: Lead, result: SkipWaterfallResult, at: Date = Date()) -> SkipTraceCacheEntry {
        SkipTraceCacheEntry(signature: signature(name: traceName(lead), address: traceAddress(lead)),
                            winner: result.winner?.rawValue ?? "",
                            phones: result.contact.phones,
                            emails: result.contact.emails,
                            matchedName: result.contact.matchedName,
                            at: at,
                            attemptsSummary: result.attempts.map { "\($0.vendor.rawValue):\($0.outcome.tag)" })
    }

    /// Attach the winning contact to the lead LOCALLY (fills only blank phone/email) AND stamp the
    /// cache — even on an exhausted miss, so a re-run re-serves for free instead of re-billing every
    /// provider for the same nothing.
    static func attach(_ result: SkipWaterfallResult, to lead: Lead) -> Lead {
        var l = SkipTraceProvider.attach(result.contact, to: lead,
                                         vendorLabel: result.winner?.label ?? "your provider")
        l.skipTraceCache = cacheEntry(lead: lead, result: result)
        return l
    }

    /// Bridge to RE-17 SkipTraceYield: one REAL waterfall run → a recordable outcome so the pre-charge
    /// yield math covers the WHOLE chain (right-party = any confirmed contact across providers).
    static func outcome(_ result: SkipWaterfallResult, dncRemoved: Int) -> SkipTraceOutcome {
        SkipTraceOutcome(traced: 1,
                         rightPartyHits: result.isHit ? 1 : 0,
                         phonesReturned: result.contact.phones.count,
                         dncRemoved: max(0, min(dncRemoved, result.contact.phones.count)))
    }

    /// Per-provider yield across the buyer's REAL cached results — how many confirmed contacts each
    /// vendor won. Pure count over stored outcomes; renders nothing it can't source. Never estimated.
    static func providerYield(_ entries: [SkipTraceCacheEntry]) -> [(vendor: String, hits: Int)] {
        var counts: [String: Int] = [:]
        for e in entries where e.isHit && !e.winner.isEmpty { counts[e.winner, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
                     .map { (vendor: $0.key, hits: $0.value) }
    }
}
#endif // circuit-convert
