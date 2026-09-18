// Black Label Real Estate — SKIP TRACE (free parcel enrichment + bring-your-own provider).
//
// Skip tracing = turning an owner name + property into a reachable contact (mailing address,
// phone, email, relatives). The honest split this product makes:
//   • FREE TIER (built-in, no cost): resolve the owner's MAILING address + recorded owner name
//     + assessed value + absentee signal straight off the county's open parcel layer
//     (ParcelLookup). That is a real, mailable direct-mail target — the highest-ROI skip-trace
//     output, and it costs nothing.
//   • PHONE / EMAIL TIER (the buyer's OWN provider): phone numbers and emails are NOT in any
//     free public source. The product never fabricates them. Instead it lets the buyer connect
//     THEIR OWN skip-trace API key (BatchData, etc.); until one is connected this tier shows an
//     honest "connect a provider" state. With a key, calls go out under the buyer's account.
//
// This file owns the FREE tier (fully working today) + the provider-config gate. It returns a
// per-lead result that says exactly what was found and what's gated — never a faked phone.
import Foundation

// MARK: - What a skip-trace pass produced for one lead (honest, per-field provenance).
struct SkipResult: Hashable {
    var leadID: UUID
    var mailingFound = false
    var mailing = ""
    var ownerResolved = false
    var owner = ""
    var situs = ""                  // resolved subject-property (situs) address off the parcel layer
    var confidence = ""             // ownership-match confidence (high/medium/low) when resolved
    var assessedValue: Int? = nil
    var absentee = false
    var phoneFound = false          // only ever true via the buyer's connected provider
    var phone = ""
    var emailFound = false
    var email = ""
    var note = ""                   // honest reason when a field is gated/unavailable
}

// MARK: - Outcome of a batch.
struct SkipBatchSummary: Hashable {
    var attempted = 0
    var mailingResolved = 0
    var phonesFound = 0
    var gated = 0                    // counties with no open source / owner not found
    var results: [SkipResult] = []
}

// MARK: - Bring-your-own provider config (key stored by the caller in the Keychain/Defaults).
struct SkipProvider: Codable, Hashable {
    var name: String = ""           // e.g. "BatchData", "MyProvider"
    var apiKeyPresent = false       // the engine never holds the key text; just whether one is set
    var connected: Bool { apiKeyPresent && !name.isEmpty }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum SkipTrace {
    /// FREE tier — resolve mailing/owner/value off the county parcel layer for ONE lead.
    /// Phone/email stay gated (never fabricated). Reuses the proven ParcelLookup engine.
    static func freeTrace(_ lead: Lead, fetch: ParcelLookup.Fetch = ParcelLookup.liveFetch) async -> SkipResult {
        var r = SkipResult(leadID: lead.id)
        guard ParcelRegistry.covers(lead.county) else {
            r.note = "No open parcel source for \(lead.county.isEmpty ? "this" : lead.county.capitalized) County — phone/mailing can't be pulled free. Connect a provider or add the county."
            return r
        }
        let rec = await ParcelLookup.resolve(name: lead.name, county: lead.county, fetch: fetch)
        guard rec.available else { r.note = rec.note; return r }
        if let o = rec.owner, !o.isEmpty { r.ownerResolved = true; r.owner = o }
        if let a = rec.address, !a.isEmpty { r.situs = a }
        if rec.ownershipConfidence != .none { r.confidence = rec.ownershipConfidence.rawValue }
        if let v = rec.assessedValue { r.assessedValue = v }
        if !rec.ownerMail.isEmpty {
            r.mailingFound = true; r.mailing = rec.ownerMail.full
            r.absentee = ParcelEnrich.isAbsentee(rec)
        } else if rec.address == nil {
            r.note = "Owner not matched on the county layer — nothing invented."
        } else {
            r.note = "Parcel found, but this layer publishes no owner-mailing field. Address is the situs only."
        }
        return r
    }

    /// Merge a free-trace result back into a lead (only fills BLANK fields — never overwrites
    /// what the buyer typed, and never writes a phone/email the free tier didn't actually find).
    static func merge(_ r: SkipResult, into lead: Lead) -> Lead {
        var l = lead
        if l.mailingAddress.isEmpty, r.mailingFound { l.mailingAddress = r.mailing }
        if l.propertyAddress.isEmpty, !r.situs.isEmpty { l.propertyAddress = r.situs }
        if l.ownershipConfidence.isEmpty, !r.confidence.isEmpty { l.ownershipConfidence = r.confidence }
        if l.ownerName.isEmpty, r.ownerResolved { l.ownerName = r.owner }
        if l.assessedValue == 0, let v = r.assessedValue { l.assessedValue = v }
        if l.phone.isEmpty, r.phoneFound { l.phone = r.phone }
        if l.email.isEmpty, r.emailFound { l.email = r.email }
        if r.absentee, l.source == .probate, !l.sourceDetail.lowercased().contains("absentee") {
            l.sourceDetail = l.sourceDetail.isEmpty ? "Absentee owner" : "\(l.sourceDetail) · absentee"
        }
        return l
    }

    /// Batch free-trace over a set of leads; returns a summary + per-lead results.
    static func freeBatch(_ leads: [Lead], fetch: ParcelLookup.Fetch = ParcelLookup.liveFetch,
                          onProgress: ((Int, Int) -> Void)? = nil) async -> SkipBatchSummary {
        var s = SkipBatchSummary(attempted: leads.count)
        for (i, l) in leads.enumerated() {
            let r = await freeTrace(l, fetch: fetch)
            if r.mailingFound { s.mailingResolved += 1 }
            if r.phoneFound { s.phonesFound += 1 }
            if !r.mailingFound && !r.ownerResolved { s.gated += 1 }
            s.results.append(r)
            onProgress?(i + 1, leads.count)
        }
        return s
    }
}
#endif // circuit-convert
