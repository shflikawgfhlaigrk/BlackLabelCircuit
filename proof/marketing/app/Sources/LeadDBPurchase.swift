// Black Label Marketing — Lead Database purchase & entitlement (StoreKit 2, App Store only).
//
// b26 removes the user-pasted access-key unlock from iOS ENTIRELY after the b23→b24→b25 rejections
// under Guideline 3.1.1 ("the app uses license keys to unlock subscriptions"). The App Store app is
// CONSUMER-ONLY: there is no enterprise / web-key / multiplatform-unlock audience for iOS (that
// channel is blacklabeltec.com, not the app). The compliant shape is therefore StoreKit-only:
//
//   • Unlock = an active App Store entitlement for the auto-renewable subscription
//     (com.blacklabel.marketing.leaddb.monthly, group "Marketing Lead Database"). NOTHING else
//     unlocks on iOS — no pasted key, no external code. Neither entitlement → the masked preview
//     tier (masking is SERVER-side; the app never receives full contacts unless the catalog
//     service grants a tier — nothing is "unmasked" client-side, §5.1).
//   • Pricing copy comes ONLY from the StoreKit Product API (displayPrice). Never hardcoded.
//   • NO introductory offer of any kind (founder rule) — the ASC product carries none and
//     this file never advertises one.
//
// Server note (honest by design, IAP-based and legal): an entitlement alone cannot reveal data the
// API doesn't send. After a purchase/restore the app POSTs the SIGNED App Store transaction to the
// catalog service (POST /v1/appstore/link) which issues this subscriber's access credential; that
// credential is what unmasks contacts server-side. Until that service call succeeds, the UI says so
// plainly — it never fakes an unlocked state. The credential is stored in the data-protection
// Keychain via LeadDBCredential, which
// on iOS is written ONLY by that server link (and the dev-only UI-test bridge) — never by a user.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum LeadDBAccess {
    /// The auto-renewable subscription product configured in App Store Connect.
    static let subscriptionProductID = "com.blacklabel.marketing.leaddb.monthly"

    /// Required 3.1.2 links on the subscribe surface. Both verified serving HTTP 200.
    static let privacyPolicyURL = URL(string: "https://blacklabelbots.com/privacy")!
    static let termsOfUseURL = URL(string: "https://blacklabelbots.com/terms")!

    /// Single unlock rule (iOS, App Store): ONLY an active StoreKit entitlement unlocks. There is no
    /// pasted-key path on iOS (Guideline 3.1.1) — the masked preview is the only other state.
    static func unlocked(storeEntitled: Bool) -> Bool {
        storeEntitled
    }

    /// Paywall price line — built ONLY from a Product-API display price. Not loaded yet (or the
    /// store is unreachable) → an honest loading line with NO invented figure.
    static func priceLine(displayPrice: String?) -> String {
        guard let p = displayPrice?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else {
            return "Fetching the current price from the App Store…"
        }
        return "\(p) per month · auto-renews until canceled"
    }

    /// One-line access status for Settings/Connectors. Honest about the pending server link:
    /// an entitlement without a catalog credential is "active" but not yet showing contacts.
    static func statusLine(storeEntitled: Bool) -> String {
        storeEntitled
            ? "Subscription active via the App Store."
            : "Preview tier — contacts are masked."
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Store builds ONLY (iOS App Store + Mac App Store): compiled whenever DIRECT_DISTRIBUTION is
// absent. The Developer-ID / direct macOS lane compiles with -D DIRECT_DISTRIBUTION and keeps the
// license-key unlock instead — a pasted key is permitted OUTSIDE the App Store, and only there
// (Guideline 3.1.1 rejected it in b23→b25 on iOS and again on macOS build 61, 2026-07-27).
#if !DIRECT_DISTRIBUTION
import StoreKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// StoreKit 2 subscription state for the Lead Database. One shared instance: entitlement truth
/// comes from `Transaction.currentEntitlements`, kept live by a `Transaction.updates` observer.
@MainActor
final class LeadDBSubscriptionStore: ObservableObject {
    static let shared = LeadDBSubscriptionStore()

    @Published private(set) var product: Product?
    @Published private(set) var entitled = false
    @Published private(set) var latestTransactionJWS: String?
    @Published private(set) var working = false
    @Published private(set) var note = ""
    @Published private(set) var productLoadError = ""

    private var updatesTask: Task<Void, Never>?

    private init() {
        // Unfinished-transaction / renewal / revocation observer — required so an entitlement
        // change made outside this process (renewal, refund, Ask to Buy approval) lands live.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { break }
                if case .verified(let t) = update, t.productID == LeadDBAccess.subscriptionProductID {
                    await t.finish()
                }
                await self.refreshEntitlement()
            }
        }
        Task {
            await self.refreshEntitlement()
            await self.loadProduct()
        }
    }

    deinit { updatesTask?.cancel() }

    func loadProduct() async {
        do {
            product = try await Product.products(for: [LeadDBAccess.subscriptionProductID]).first
            productLoadError = product == nil
                ? "The subscription isn't available from the App Store right now."
                : ""
        } catch {
            productLoadError = "Couldn't reach the App Store: \(error.localizedDescription)"
        }
    }

    /// Entitlement truth — current, verified, unrevoked transactions only.
    func refreshEntitlement() async {
        var active = false
        var jws: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let t) = result,
                  t.productID == LeadDBAccess.subscriptionProductID,
                  t.revocationDate == nil else { continue }
            active = true
            jws = result.jwsRepresentation
        }
        entitled = active
        latestTransactionJWS = jws
        if !active { note = "" }
    }

    func subscribe() async {
        if product == nil { await loadProduct() }
        guard let product else {
            note = productLoadError.isEmpty ? "The subscription isn't available right now." : productLoadError
            return
        }
        working = true; note = ""
        defer { working = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let t):
                    await t.finish()
                    await refreshEntitlement()
                    await linkEntitlementToCatalog()
                case .unverified:
                    note = "The App Store receipt couldn't be verified on this device."
                }
            case .userCancelled:
                break
            case .pending:
                note = "Purchase pending approval. Access unlocks as soon as it's approved."
            @unknown default:
                break
            }
        } catch {
            note = "Purchase failed: \(error.localizedDescription)"
        }
    }

    func restore() async {
        working = true; note = ""
        defer { working = false }
        do { try await AppStore.sync() } catch {
            note = "Restore failed: \(error.localizedDescription)"
            return
        }
        await refreshEntitlement()
        if entitled {
            await linkEntitlementToCatalog()
            if note.isEmpty { note = "Purchases restored — your subscription is active." }
        } else {
            note = "No active Lead Database subscription was found for this Apple Account."
        }
    }

    /// Ask the catalog service to issue this subscriber's access credential from the signed App
    /// Store transaction, and store it in the Keychain via LeadDBCredential so every downstream surface (search,
    /// export, connector chips) unlocks identically. This is the ONLY writer of that credential on
    /// iOS (the user-pasted key path was removed in b26). Honest failure: masking is server-side,
    /// so until this succeeds the UI keeps saying contacts are masked.
    @discardableResult
    func linkEntitlementToCatalog() async -> Bool {
        let existing = LeadDBCredential.token
        guard existing.isEmpty else { return true } // a credential is already present — data path unlocked
        guard let jws = latestTransactionJWS else { return false }
        var request = URLRequest(url: URL(string: "\(LeadDB.base)/v1/appstore/link")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["jws": jws])
        do {
            // blacklabel-leads-api is a REGISTERED transmission host, so the entitlement link
            // goes through the CONSENT door — not the allowlist. A buyer who has not allowed the
            // lead catalog gets an honest refusal instead of a silent upload of their receipt.
            let (data, response) = try await ConsentedEgress.send(request, to: .blackLabelLeads)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data),
                  let token = decoded["token"], !token.isEmpty else {
                note = "Subscription active. The contact-unlock service isn't reachable yet — full details appear once it responds; billing stays with the App Store."
                return false
            }
            LeadDBCredential.save(token)
            note = "Subscription active — full contact details are unlocked."
            return true
        } catch let refusal as ConsentedEgressError {
            // The app itself refused to send (missing/stale consent). The service is fine, so the
            // generic "isn't reachable" line would name the wrong cause AND the wrong remedy —
            // the refusal text directs the buyer to Connectors → Data sharing (§5.1).
            note = refusal.errorDescription ?? "The request was refused before anything was sent."
            return false
        } catch {
            note = "Subscription active. The contact-unlock service isn't reachable yet — full details appear once it responds; billing stays with the App Store."
            return false
        }
    }

    /// A 401/403 from the catalog means the stored credential is dead — subscription lapsed and
    /// re-subscribed, server-side revocation, or a stale legacy carry-over. On store builds the
    /// only writer of that credential is the server link, so a rejected token is never user data:
    /// drop it, and while the App Store entitlement is live, re-issue from the current signed
    /// transaction. Returns true when a fresh credential landed.
    @discardableResult
    func reissueCatalogCredential() async -> Bool {
        LeadDBCredential.clear()
        await refreshEntitlement()
        guard entitled else { return false }
        return await linkEntitlementToCatalog()
    }
}

// MARK: - Paywall / subscribe surface (store builds)

/// The in-app subscribe surface shown on the masked Lead Database tier, and embedded (compact)
/// in Settings + Connectors. Price text comes only from the Product API; includes Restore,
/// manage-subscription, and the 3.1.2-required Privacy Policy + Terms of Use links.
struct LeadDBSubscribeCard: View {
    @ObservedObject private var sub = LeadDBSubscriptionStore.shared
    @State private var showManage = false
    /// Purchase is consent-gated: without a Data-sharing grant for the lead catalog, ConsentedEgress
    /// refuses both the receipt link and every search, so a purchase could not deliver anything.
    /// Money never changes hands while the app is guaranteed to refuse delivery.
    @State private var consentRefusal: String?
    /// Called after the entitlement lands (and the catalog link succeeds) so the host screen can
    /// reload live data. On iOS the ONLY unlock is the StoreKit subscription — no pasted key.
    var onUnlocked: (() async -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: sub.entitled ? "checkmark.seal.fill" : "tray.full.fill")
                    .font(.system(size: 20, weight: .bold)).foregroundColor(BLTheme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.entitled ? "Lead Database — subscription active" : "Lead Database Access")
                        .font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    // "Unlocked" only when it is TRUE end-to-end: entitlement AND the server-issued
                    // catalog credential. Entitlement alone still shows masked rows (§5.1).
                    Text(sub.entitled
                         ? (LeadDBCredential.hasToken
                            ? "Full contact details and one-tap campaign import are unlocked."
                            : "Finishing the unlock — contacts stay masked until the catalog issues this subscription's access credential.")
                         : "Search the live business catalog free with masked contacts. Subscribe to unlock full emails and phone numbers and add them straight to your campaigns.")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !sub.entitled {
                Text(LeadDBAccess.priceLine(displayPrice: sub.product?.displayPrice))
                    .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                if consentRefusal != nil {
                    Text("Before you subscribe: allow the \(TransmissionProvider.blackLabelLeads.displayName) under Connectors → Data sharing. Until then this app refuses to contact the catalog, so a subscription could not unlock anything.")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    // Enabled on a product-load failure on purpose: subscribe() re-runs
                    // loadProduct(), so the button doubles as the in-place retry.
                    GoldButton(label: sub.working ? "Working…" : "Subscribe", icon: "lock.open.fill") {
                        Task { await sub.subscribe(); if sub.entitled { await onUnlocked?() } }
                    }
                    .disabled(sub.working || consentRefusal != nil)
                    GhostButton(label: "Restore Purchases", icon: "arrow.clockwise") {
                        Task { await sub.restore(); if sub.entitled { await onUnlocked?() } }
                    }
                    .disabled(sub.working)
                }
                if !sub.productLoadError.isEmpty {
                    Text(sub.productLoadError)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                #if os(iOS)
                GhostButton(label: "Manage subscription", icon: "creditcard") { showManage = true }
                #else
                // macOS has no manageSubscriptionsSheet — open the Apple Account subscriptions page.
                GhostButton(label: "Manage subscription", icon: "creditcard") {
                    NSWorkspace.shared.open(URL(string: "https://apps.apple.com/account/subscriptions")!)
                }
                #endif
            }

            if !sub.note.isEmpty {
                Text(sub.note)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(sub.entitled ? BLTheme.green : BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                Link("Privacy Policy", destination: LeadDBAccess.privacyPolicyURL)
                Link("Terms of Use", destination: LeadDBAccess.termsOfUseURL)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(14)
        .background(BLTheme.gold.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BLTheme.gold.opacity(0.3), lineWidth: 1))
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showManage)
        #endif
        // onAppear re-reads the grant when the buyer comes back from Connectors → Data sharing.
        .onAppear { consentRefusal = TransmissionConsentStore.refusal(for: .blackLabelLeads) }
        .task {
            consentRefusal = TransmissionConsentStore.refusal(for: .blackLabelLeads)
            await sub.refreshEntitlement()
            if sub.product == nil { await sub.loadProduct() }
            // If a prior purchase entitled this Apple Account but the catalog credential isn't stored
            // yet, complete the server link so contacts unmask — no user action (or key) required.
            if sub.entitled { if await sub.linkEntitlementToCatalog() { await onUnlocked?() } }
        }
    }
}
#endif
#endif // circuit-convert
