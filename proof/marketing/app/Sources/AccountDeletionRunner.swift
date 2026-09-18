#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — the executing half of account deletion.
//
// AccountDeletion.swift holds the pure decision table (what must be attempted, and how a finished
// run is honestly summarised). This file is the part that touches the app graph and the network:
// it reads the real connection state, performs the real server-side deletions, and returns the
// receipts the pure summariser turns into buyer-facing copy.
//
// ORDER MATTERS AND IS DELIBERATE: server-side deletions run FIRST, while the credentials that
// authenticate them still exist. Only when they have finished (successfully or not) are the local
// credentials destroyed. Wiping the Keychain first — which is what the old delete path effectively
// did — makes every server-side record permanently unreachable from this device.
//
// NOTHING HERE CLAIMS A DELETION IT DID NOT GET. A short link is `.deleted` only for the slugs the
// buyer's Worker actually returned OK for; a Google grant is `.deleted` only on a 200 from
// Google's revocation endpoint; anything already handed to a third party that exposes no delete
// API to this app is reported `.manual` with the place to go.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum AccountDeletionRunner {

    /// Google's documented OAuth 2.0 revocation endpoint. Revoking the refresh token invalidates
    /// the whole grant (and every access token minted from it) on Google's side.
    static let googleRevokeEndpoint = "https://oauth2.googleapis.com/revoke"

    /// Read the live connection state the planner needs.
    @MainActor
    static func currentState() -> AccountDeletionState {
        var providers: [String] = []
        for provider in TransmissionProvider.allCases where !provider.isFirstParty {
            if TransmissionConsentStore.isGranted(provider) { providers.append(provider.displayName) }
        }
        return AccountDeletionState(
            shortlinksProvisioned: CloudflareShortlinksConfig.isProvisioned,
            hasGoogleGrant: GA4AnalyticsConfig.credential != nil,
            hasStoredCredentials: hasAnyStoredCredential(),
            hasConsentReceipts: !TransmissionConsentStore.all().isEmpty,
            transmittedToThirdParties: providers)
    }

    static func hasAnyStoredCredential() -> Bool {
        if LeadDBCredential.hasSavedItem { return true }
        if SendblueConfig.hasSavedCredentialItem { return true }
        if CloudflareEmailConfig.hasSavedTokenItem { return true }
        if CloudflareAnalyticsConfig.hasSavedTokenItem { return true }
        if CloudflareShortlinksConfig.hasSavedAdminItem { return true }
        if GA4AnalyticsConfig.credential != nil || GA4AnalyticsConfig.manualToken != nil { return true }
        if EnrichmentVendor.allCases.contains(where: { EnrichmentKeychain.hasKey($0) }) { return true }
        return false
    }

    // MARK: - the run

    /// Delete every server-side record this app created that it can still reach, then destroy every
    /// local credential. Returns one receipt per attempted target, in attempt order.
    ///
    /// `mailboxes` is the list of connected API mailboxes whose provider tokens must also be
    /// destroyed; the caller passes them because only it holds the lead-engine settings.
    @MainActor
    static func run(mailboxes: [(provider: EmailAPIProvider, address: String)] = [],
                    crmAccounts: [String] = []) async -> [AccountDeletionReceipt] {
        let state = currentState()
        var receipts: [AccountDeletionReceipt] = []

        for target in AccountDeletionPlanner.plan(state) {
            switch target {
            case .cloudflareShortlinks:
                receipts.append(.init(target: target, outcome: await deleteAllShortlinks()))
            case .googleOAuthGrant:
                receipts.append(.init(target: target, outcome: await revokeGoogleGrant()))
            case .thirdPartyContent:
                receipts.append(.init(target: target,
                                      outcome: .manual(detail: AccountDeletionPlanner
                                        .thirdPartyDetail(state.transmittedToThirdParties))))
            case .localCredentials:
                let cleared = clearAllCredentials(mailboxes: mailboxes, crmAccounts: crmAccounts)
                receipts.append(.init(target: target,
                                      outcome: .deleted(count: cleared,
                                                        detail: "Every saved key, token and password was removed from your Keychain.")))
            case .transmissionConsents:
                TransmissionConsentStore.clearAll()
                receipts.append(.init(target: target,
                                      outcome: .deleted(count: 1,
                                                        detail: "Every data-sharing permission you granted was withdrawn.")))
            }
        }
        return receipts
    }

    // MARK: - server-side: the buyer's own short links

    /// Delete every link row in the KV namespace behind the buyer's Worker. These are real records
    /// on a real server that this app created, one per link.
    static func deleteAllShortlinks() async -> AccountDeletionOutcome {
        let (links, detail) = await CloudflareShortlinks.listLinks()
        guard let links else {
            return .failed(detail: "Your short links could not be listed, so none were deleted: \(detail)")
        }
        guard !links.isEmpty else { return .nothingToDelete }

        var deleted = 0
        var failures: [String] = []
        for link in links {
            let result = await CloudflareShortlinks.deleteLink(slug: link.slug)
            if result.ok { deleted += 1 } else { failures.append("/\(link.slug): \(result.detail)") }
        }
        if failures.isEmpty {
            return .deleted(count: deleted, detail: "\(deleted) short link\(deleted == 1 ? "" : "s") deleted from your Worker's KV store.")
        }
        return .failed(detail: "\(deleted) of \(links.count) short links were deleted. These are still live: "
                       + failures.prefix(5).joined(separator: "; "))
    }

    // MARK: - server-side: the Google OAuth grant

    /// Revoke the app's Google authorization at Google. Dropping the local token is not deletion —
    /// the grant stays on the buyer's Google account until this call succeeds.
    /// Revocation leaves through the choke point on the declared `oauthTokenExchange` lane: it
    /// carries only a token Google itself issued, and a consent gate must never be able to block
    /// a DISCONNECTION. `transport` stays injectable for tests.
    static func revokeGoogleGrant(transport: OutboundTransport? = nil) async -> AccountDeletionOutcome {
        guard let credential = GA4AnalyticsConfig.credential else { return .nothingToDelete }
        // Revoking the refresh token kills the whole grant; fall back to the access token when the
        // grant was issued without one.
        let candidate = (credential.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 } ?? credential.accessToken
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .manual(detail: "No usable Google token was stored, so the authorization could not be revoked from here. Remove this app at myaccount.google.com → Security → Your connections to third-party apps.")
        }
        guard let request = googleRevokeRequest(token: candidate) else {
            return .failed(detail: "The Google revocation request could not be built. Remove this app at myaccount.google.com → Security → Your connections to third-party apps.")
        }
        do {
            let (_, response) = try await ConsentedEgress.sendUngated(request, lane: .oauthTokenExchange,
                                                                      via: transport)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                return .deleted(count: 1, detail: "Google confirmed the authorization was revoked.")
            }
            return .failed(detail: "Google refused the revocation (HTTP \(code)). The authorization is still live — remove it at myaccount.google.com → Security → Your connections to third-party apps.")
        } catch {
            return .failed(detail: "Google could not be reached to revoke the authorization (\(error.localizedDescription)). It is still live — remove it at myaccount.google.com → Security → Your connections to third-party apps.")
        }
    }

    /// Pure builder so the revocation shape is testable without a socket.
    static func googleRevokeRequest(token: String) -> URLRequest? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: googleRevokeEndpoint) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        // The token goes in the BODY, never the query string.
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "token", value: trimmed)]
        request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
        return request
    }

    // MARK: - local: every credential, not just the session

    /// Destroy every credential this app can hold. Returns how many stores were cleared — the old
    /// delete path cleared two of these and left the rest behind for the next person to inherit.
    @discardableResult
    static func clearAllCredentials(mailboxes: [(provider: EmailAPIProvider, address: String)] = [],
                                    crmAccounts: [String] = []) -> Int {
        var cleared = 0
        LeadDBCredential.clear();                     cleared += 1
        SendblueConfig.clearCredential();             cleared += 1
        CloudflareEmailConfig.setToken("");           cleared += 1
        CloudflareAnalyticsConfig.setToken("");       cleared += 1
        CloudflareShortlinksConfig.clearLocal();      cleared += 1
        GA4AnalyticsConfig.disconnect();              cleared += 1
        for vendor in EnrichmentVendor.allCases { EnrichmentKeychain.clear(vendor) }
        cleared += 1
        for mailbox in mailboxes {
            EmailTokenStore.delete(provider: mailbox.provider, address: mailbox.address)
        }
        if !mailboxes.isEmpty { cleared += 1 }
        for account in crmAccounts { CRMConnectorKeychain.delete(account: account) }
        if !crmAccounts.isEmpty { cleared += 1 }
        SocialCredentialStore.clearAll();             cleared += 1
        SessionStore.clear();                         cleared += 1
        return cleared
    }
}
#endif // circuit-convert
