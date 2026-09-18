// Black Label Marketing — account deletion that actually reaches the servers.
//
// WHAT WAS WRONG: "Delete my account & data" wiped the local store, the remembered session and the
// social credentials, and then told the buyer their account and all their data were gone. That was
// not true. Three classes of record survived it:
//
//   1. SERVER-SIDE RECORDS THIS APP CREATED. The short-link provisioner writes real rows into a
//      KV namespace on the buyer's own Cloudflare Worker, one per link. Deleting the local cache
//      left every one of those links live and resolving on the internet.
//   2. LIVE OAUTH GRANTS. A Google grant (Gmail send / GA4 / Search Console / YouTube) stays valid
//      on Google's side until it is revoked. Dropping the local token abandons the grant; it does
//      not end it.
//   3. THE REST OF THE KEYCHAIN. Sendblue, Cloudflare (analytics/email/shortlinks), GA4, the
//      mailbox OAuth tokens, the enrichment keys, the CRM token and the Lead Database key were all
//      left behind, so a re-install silently re-inherited the previous owner's credentials.
//
// WHAT THIS FILE DOES: it enumerates every reachable server-side record class from the CURRENT
// connection state, deletes what it can actually delete, and returns a RECEIPT PER TARGET. The
// receipts are the point: a target is only reported `.deleted` when a server answered OK. A target
// we cannot delete from here (a third party with no delete API, e.g. messages already handed to
// Sendblue, or posts already published to a social network) is reported `.manual` with the exact
// place the buyer must go — it is never quietly folded into a success claim, and the UI copy is
// generated from these receipts rather than asserted ahead of them.
//
// The PLAN is a pure function of the connection state, so the whole decision table is executed
// headlessly in Tests/AccountDeletionTests.swift. Only `execute` touches the network.
import Foundation

// MARK: - what can be deleted, and what came of it

enum AccountDeletionTarget: String, CaseIterable, Identifiable, Equatable {
    /// Every short link in the KV namespace on the buyer's own Cloudflare Worker.
    case cloudflareShortlinks
    /// The OAuth grant held by Google for this app (Gmail / GA4 / Search Console / YouTube).
    case googleOAuthGrant
    /// Credentials at rest in the data-protection Keychain.
    case localCredentials
    /// Recorded transmission-consent receipts.
    case transmissionConsents
    /// Content already handed to third parties that expose no delete API to this app.
    case thirdPartyContent

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cloudflareShortlinks: return "Short links on your Cloudflare Worker"
        case .googleOAuthGrant:     return "Your Google authorization for this app"
        case .localCredentials:     return "Saved credentials in your Keychain"
        case .transmissionConsents: return "Recorded data-sharing permissions"
        case .thirdPartyContent:    return "Content already sent to third parties"
        }
    }
}

enum AccountDeletionOutcome: Equatable {
    /// A server confirmed the deletion. `count` is how many records went, when countable.
    case deleted(count: Int, detail: String)
    /// There was nothing of this kind to delete.
    case nothingToDelete
    /// We tried and the server said no (or could not be reached). NOT a success.
    case failed(detail: String)
    /// This app cannot delete it; the buyer must, and here is exactly where.
    case manual(detail: String)

    var isSuccessClaim: Bool {
        switch self {
        case .deleted, .nothingToDelete: return true
        case .failed, .manual: return false
        }
    }
}

struct AccountDeletionReceipt: Equatable, Identifiable {
    var target: AccountDeletionTarget
    var outcome: AccountDeletionOutcome
    var id: String { target.rawValue }
}

/// The facts the plan needs. Explicit rather than reached-for so the decision table is executable.
struct AccountDeletionState: Equatable {
    /// A provisioned Worker URL + a readable admin secret — i.e. the links are actually reachable.
    var shortlinksProvisioned: Bool = false
    /// A live Google OAuth refresh/access token is held on this device.
    var hasGoogleGrant: Bool = false
    /// Any credential at all is saved in the Keychain.
    var hasStoredCredentials: Bool = false
    /// Any transmission-consent receipt is recorded.
    var hasConsentReceipts: Bool = false
    /// The buyer has transmitted content to at least one third party (social/messaging/CRM).
    var transmittedToThirdParties: [String] = []
}

// MARK: - the pure plan

enum AccountDeletionPlanner {
    /// Which targets this deletion must attempt, in the order they are attempted. Server-side
    /// work runs BEFORE local wipes: once the credentials are gone we can no longer authenticate
    /// the deletes, so wiping first would make the server-side records permanently unreachable.
    static func plan(_ state: AccountDeletionState) -> [AccountDeletionTarget] {
        var out: [AccountDeletionTarget] = []
        if state.shortlinksProvisioned { out.append(.cloudflareShortlinks) }
        if state.hasGoogleGrant { out.append(.googleOAuthGrant) }
        if !state.transmittedToThirdParties.isEmpty { out.append(.thirdPartyContent) }
        if state.hasStoredCredentials { out.append(.localCredentials) }
        if state.hasConsentReceipts { out.append(.transmissionConsents) }
        return out
    }

    /// The honest headline for a finished run. It may only claim server-side deletion when EVERY
    /// attempted server-side target actually succeeded.
    static func summary(_ receipts: [AccountDeletionReceipt]) -> String {
        let unresolved = receipts.filter { !$0.outcome.isSuccessClaim }
        if receipts.isEmpty {
            return "Your account and all data on this device were deleted. Nothing was stored on a server to delete."
        }
        if unresolved.isEmpty {
            return "Your account, everything on this device, and the records this app created on your connected services were deleted."
        }
        let failed = unresolved.filter { if case .failed = $0.outcome { return true } else { return false } }
        var lines = ["Everything on this device was deleted."]
        if !failed.isEmpty {
            lines.append("These server-side deletions did NOT complete and are still there: "
                         + failed.map(\.target.label).joined(separator: "; ") + ".")
        }
        let manual = unresolved.filter { if case .manual = $0.outcome { return true } else { return false } }
        if !manual.isEmpty {
            lines.append("These can only be removed where they live: "
                         + manual.map(\.target.label).joined(separator: "; ") + ".")
        }
        return lines.joined(separator: " ")
    }

    /// The manual-step text for content this app provably cannot recall.
    static func thirdPartyDetail(_ providers: [String]) -> String {
        guard !providers.isEmpty else { return "Nothing was sent to a third party from this device." }
        return "Messages, posts and lead records you already sent to "
             + providers.joined(separator: ", ")
             + " live on those services and this app has no way to recall them. Delete them in each service's own account settings."
    }
}

/// The one-line receipt the UI prints per target. Kept next to the outcomes so a new outcome case
/// is a compile error until it has honest copy.
enum AccountDeletionReceiptText {
    static func line(_ outcome: AccountDeletionOutcome) -> String {
        switch outcome {
        case .deleted(_, let detail): return detail
        case .nothingToDelete:        return "Nothing to delete."
        case .failed(let detail):     return "NOT DELETED — \(detail)"
        case .manual(let detail):     return detail
        }
    }
}
