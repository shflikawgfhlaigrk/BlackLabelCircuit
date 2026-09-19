// Black Label Real Estate — StoreKit 2 auto-renewable subscription (store builds only).
//
// Both App Store builds (iOS and the Mac App Store target, which defines MAS_BUILD) sell the paid
// workflow THROUGH StoreKit — Guideline 3.1.1 forbids selling it any other way. The separately
// distributed macOS Developer-ID build keeps its own 14-day trial → hosted checkout in Trial.swift,
// behind `os(macOS) && !MAS_BUILD`; the two never mix and no checkout URL is linked here.
//
// The paid line matches what the Dev-ID trial already gates (founder ruling 2026-07-25 — keep
// today's line): building lists, exporting an LOI, and sending outreach mail. Everything else —
// sourcing, search, the parcel/owner index, comps, ARV and route optimization — stays free.
//
// Honesty invariants (§5.1):
//   * The price renders ONLY from `Product.displayPrice`. No product loaded -> an honest
//     "price unavailable" state, never a painted figure.
//   * Access derives ONLY from `Transaction.currentEntitlements` (+ the `Transaction.updates`
//     listener) — never a local flag, never a cached bool.
//   * The trial claim on this screen must match what StoreKit will actually deliver. Founder
//     ruling 2026-08-04 moves every app to a 14-day free trial; on the Dev-ID lane that is a code
//     constant (RETrialConfig.trialDays, changed this round). HERE it is not: a store free trial is
//     an App Store Connect INTRODUCTORY OFFER on `com.blacklabel.realestate.pro.monthly`, and this
//     repo cannot create one. Until that offer exists in ASC, `com.blacklabel.realestate.pro.monthly`
//     genuinely has no trial, so the copy below still says so — printing "14-day free trial" over a
//     product that charges on day 0 would be a false claim and a 3.1.2 rejection. The moment the
//     intro offer is configured, render it from `product.subscription?.introductoryOffer` (never a
//     hardcoded number) so the screen can only ever state what the buyer will actually be charged.
//     Superseded: founder rule 2026-07-21 ("no trials anywhere").
import Foundation
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit
#if os(iOS) || MAS_BUILD
import Foundation
import StoreKit
import SwiftUI

enum REStoreCatalog {
    /// The one App Store Connect product (group "Real Estate Pro").
    static let monthlyProductID = "com.blacklabel.realestate.pro.monthly"
    /// 3.1.2 required links. These MUST resolve — a subscription screen whose privacy/terms links
    /// 404 is a 3.1.2 rejection, and the blbestate.com routes do not exist (verified 2026-08-02:
    /// https://blbestate.com/privacy -> HTTP 404). They point at the live, published company policy
    /// pages, which return HTTP 200 and are the policies that actually govern this app. That is a
    /// deliberate, narrow exception to the brand-isolation rule (which governs SITE trees, not the
    /// legally-required policy link inside a Black Label app): a working policy link beats a
    /// same-brand dead one. Move these back to blbestate.com the moment those routes are published.
    static let privacyURL = URL(string: "https://blacklabelbots.com/privacy")!
    static let termsURL = URL(string: "https://blacklabelbots.com/terms")!
    /// "Manage subscription" on the Mac App Store build — iOS has an in-app sheet, macOS does not.
    static let manageSubscriptionsURL = URL(string: "macappstore://apps.apple.com/account/subscriptions")!
}

/// StoreKit 2 store front: loads the product, tracks the live entitlement, purchases and restores.
/// A singleton because `REAccess` is a static facade every gated call site already reads.
@MainActor
final class REStore: ObservableObject {
    static let shared = REStore()

    enum PurchasePhase: Equatable {
        case idle
        case purchasing
        case pending          // Ask to Buy — honest "waiting for approval", never an early unlock
        case failed(String)
    }

    /// The App Store product, or nil until (unless) it loads. All price copy reads from this.
    @Published private(set) var product: Product?
    /// True only when `Transaction.currentEntitlements` carries a verified, unrevoked transaction
    /// for the subscription. The single access authority.
    @Published private(set) var isSubscribed = false
    /// True after a load ATTEMPT failed — drives the honest "price unavailable" state.
    @Published private(set) var productLoadFailed = false
    @Published private(set) var purchasePhase: PurchasePhase = .idle
    /// Honest outcome of the last Restore Purchases tap (nil until used).
    @Published private(set) var restoreMessage: String?

    private var updatesTask: Task<Void, Never>?

    private init() {
        // Observe App Store transaction updates for the app's lifetime (renewals, revocations,
        // Ask-to-Buy approvals, purchases made on another device) and re-derive access.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        }
        Task { [weak self] in
            await self?.refreshEntitlement()
            await self?.loadProduct()
        }
    }

    deinit { updatesTask?.cancel() }

    /// Load the subscription product. Failure is a published, honest state — never a fake price.
    func loadProduct() async {
        do {
            let products = try await Product.products(for: [REStoreCatalog.monthlyProductID])
            if let p = products.first(where: { $0.id == REStoreCatalog.monthlyProductID }) {
                product = p
                productLoadFailed = false
            } else {
                productLoadFailed = true
            }
        } catch {
            productLoadFailed = true
        }
    }

    /// Re-derive access from the App Store's own entitlement ledger. Never trusts a cache.
    func refreshEntitlement() async {
        var active = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == REStoreCatalog.monthlyProductID,
               transaction.revocationDate == nil {
                active = true
            }
        }
        isSubscribed = active
    }

    /// Purchase through StoreKit. The outcome is published, never assumed.
    func purchase() async {
        guard let product else {
            purchasePhase = .failed("The App Store could not be reached. Try again.")
            return
        }
        purchasePhase = .purchasing
        do {
            switch try await product.purchase() {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    await refreshEntitlement()
                    purchasePhase = .idle
                case .unverified:
                    purchasePhase = .failed("The App Store could not verify this purchase.")
                }
            case .userCancelled:
                purchasePhase = .idle
            case .pending:
                purchasePhase = .pending
            @unknown default:
                purchasePhase = .failed("Unrecognized App Store response.")
            }
        } catch {
            purchasePhase = .failed(error.localizedDescription)
        }
    }

    /// Restore Purchases: sync, then re-derive. The message states exactly what happened —
    /// restored, or honestly nothing to restore.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            restoreMessage = "Restore failed: \(error.localizedDescription)"
            return
        }
        await refreshEntitlement()
        restoreMessage = isSubscribed
            ? "Subscription restored."
            : "No active subscription found on this Apple Account."
    }

    /// A freshly-presented paywall must not open pre-loaded with a previous presentation's
    /// outcome (a stale failure line, a long-decided Ask-to-Buy, an old restore verdict). Clears
    /// finished transient state only — a genuinely in-flight purchase keeps its live phase.
    func clearTransientPurchaseState() {
        if purchasePhase != .purchasing { purchasePhase = .idle }
        restoreMessage = nil
    }

    /// Launch AND foreground entry point (see `REAccess.refresh()` + RootView's scenePhase hook).
    ///
    /// `isSubscribed` starts cold at `false`. Warming it only once, lazily, on first access left a
    /// real window where an active subscriber's first gated tap read the cold default and got the
    /// paywall for content they already own — and left a subscription bought/cancelled/renewed on
    /// ANOTHER device invisible until the process was killed. Re-deriving on every activation
    /// closes both: the authority is still only `Transaction.currentEntitlements`, it is just
    /// asked again. A failed product load is retried here too, so a launch with no network
    /// recovers its price the moment the app comes back to the foreground.
    func refreshFromAppLifecycle() {
        Task { [weak self] in
            guard let self else { return }
            await self.refreshEntitlement()
            if self.product == nil { await self.loadProduct() }
        }
    }
}

// MARK: - Paywall (the 3.1.1 unlock surface; also the App Store Connect review screenshot)

/// Shown when a gated action (list build / LOI export / mail send) is tapped without a
/// subscription. Presented by `TrialPaywallSheet` on the store builds, so the existing call sites
/// need no change.
struct REStorePaywall: View {
    @ObservedObject var store: REStore = .shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                access
                priceBlock
                legal
            }
            .blScreenPadding(26)
        }
        .sheetFrame(520, 620)
        .onAppear { store.clearTransientPurchaseState() }
        .onChangeCompat(of: store.isSubscribed) { subscribed in
            if subscribed { dismiss() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconBadge(system: "lock.open.fill", size: 30)
            Text("Real Estate Pro")
                .font(.blSystem(size: 20, weight: .heavy, design: .rounded))
                .foregroundColor(BLTheme.text)
            Spacer()
        }
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Subscribe to unlock the paid workflow. Everything you have already saved stays on this device — nothing is deleted. Your workspace is never uploaded to Black Label. Data leaves this device only when you trigger it: a skip trace or a letter send goes to the provider you connected yourself, and searches, parcel/comp lookups and route planning query public-records and mapping services.")
                .font(BLFont.body(13, .regular)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            row("Unlimited list building over the public-records index")
            row("List-results CSV export and LOI packets")
            row("Outreach mail sent from your own account")
            Text("Free without a subscription: sourcing and search, the parcel and owner index, comps, ARV and the deal calculators, route planning, and CSV export of the leads already saved in your workspace.")
                .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    @ViewBuilder private func row(_ t: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(BLTheme.green)
            Text(t).font(BLFont.body(12.5, .semibold)).foregroundColor(BLTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Price + purchase. The figure comes ONLY from StoreKit; no product -> honest unavailability.
    @ViewBuilder private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let product = store.product {
                Text("\(product.displayPrice) / month")
                    .font(.blSystem(size: 21, weight: .bold, design: .rounded))
                    .foregroundColor(BLTheme.text)
                    .accessibilityIdentifier("bl.re.paywall.price")
                Text("Auto-renews monthly until canceled. No free trial.")
                    .font(BLFont.body(11, .regular)).foregroundColor(BLTheme.sub)
                if store.purchasePhase == .purchasing {
                    ProgressView()
                } else {
                    GoldButton(label: "Subscribe", fill: true, icon: "lock.open") {
                        Task { await store.purchase() }
                    }
                    .accessibilityIdentifier("bl.re.paywall.subscribe")
                }
            } else {
                Text(store.productLoadFailed
                     ? "Price unavailable — the App Store could not be reached."
                     : "Loading price from the App Store…")
                    .font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.sub)
                GhostButton(label: "Try again", icon: "arrow.clockwise", tint: BLTheme.sub) {
                    Task { await store.loadProduct() }
                }
            }

            if case .failed(let reason) = store.purchasePhase {
                Text(reason).font(BLFont.body(11, .regular)).foregroundColor(BLTheme.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.purchasePhase == .pending {
                Text("Purchase pending approval (Ask to Buy). Access unlocks when it is approved.")
                    .font(BLFont.body(11, .regular)).foregroundColor(BLTheme.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                GhostButton(label: "Restore Purchases", icon: "arrow.counterclockwise", tint: BLTheme.sub) {
                    Task { await store.restore() }
                }
                .accessibilityIdentifier("bl.re.paywall.restore")
                GhostButton(label: "Not now", tint: BLTheme.sub) { dismiss() }
            }
            if let msg = store.restoreMessage {
                Text(msg).font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.sub)
                    .accessibilityIdentifier("bl.re.paywall.restorestatus")
            }
        }
    }

    /// 3.1.2: functional Privacy Policy + Terms of Use links, plus the platform's cancel path.
    private var legal: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Button { openURL(REStoreCatalog.privacyURL) } label: {
                    Text("Privacy Policy").font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.gold)
                }.buttonStyle(.plain)
                Button { openURL(REStoreCatalog.termsURL) } label: {
                    Text("Terms of Use").font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.gold)
                }.buttonStyle(.plain)
            }
            Text(Self.cancelPathLine)
                .font(BLFont.body(10.5, .regular)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Naming the iOS cancel path on a Mac would be an instruction the buyer cannot follow.
    static var cancelPathLine: String {
        #if os(iOS)
        "Cancel anytime in Settings \u{2192} Apple Account \u{2192} Subscriptions."
        #else
        "Cancel anytime in App Store \u{2192} Account Settings \u{2192} Subscriptions."
        #endif
    }
}

// MARK: - Always-visible subscription surface (Settings → Real Estate Pro)

/// The UNCONDITIONAL purchase surface, and the reason it exists.
///
/// Every other route to the paywall in this app is behind a gated action — each one is a
/// `guard REAccess.allowsPaidFeatures else { showPaywall = true; return }` inside List Builder or
/// the LOI editor. That means a person who never taps one of those specific actions never sees
/// that the app HAS an in-app purchase at all, and the published App Review demo account lands in
/// Sample Mode, where `OfferExportAccess.isExactSyntheticPair` deliberately opens the LOI export
/// WITHOUT the paywall. App Review reported exactly that outcome under Guideline 2.1(b)
/// ("In-app purchase products associated with the app version submitted for review, such as Real
/// Estate Pro, could not be found in the submitted binary" — submission 20bc5bb9, iOS 1.1 (22)).
///
/// This panel is rendered at the top of Settings on both store builds, ALWAYS — subscribed or not,
/// entitled or not, sample workspace or real one — so the product is at most Settings-and-scroll
/// away and can never be gated out of existence. Its price still comes only from StoreKit.
struct REProSubscriptionPanel: View {
    @ObservedObject var store: REStore = .shared
    @State private var showPaywall = false
    @State private var showManage = false

    var body: some View {
        Panel(title: "Real Estate Pro subscription", icon: "creditcard.fill", glow: true) {
            HStack(spacing: 8) {
                StatusPill(text: store.isSubscribed ? "SUBSCRIBED" : "NOT SUBSCRIBED",
                           tint: store.isSubscribed ? BLTheme.green : BLTheme.sub)
                Spacer()
            }
            .accessibilityIdentifier("bl.re.settings.subscription.status")

            priceLine

            Text("Real Estate Pro unlocks list building over the public-records index, list-results CSV export and LOI packets, and outreach mail sent from your own account. Sourcing and search, the parcel and owner index, comps, ARV, the deal calculators and route planning stay free.")
                .font(BLFont.body(11.5, .medium)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)

            controls

            if let msg = store.restoreMessage {
                Text(msg).font(BLFont.body(11, .semibold)).foregroundColor(BLTheme.sub)
                    .accessibilityIdentifier("bl.re.settings.subscription.restorestatus")
            }
            Text(REStorePaywall.cancelPathLine)
                .font(BLFont.body(10.5, .regular)).foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("bl.re.settings.subscription")
        // Opening Settings is itself an entitlement/product refresh point: the panel must never
        // render a stale "NOT SUBSCRIBED" or a stale "price unavailable" from an earlier launch.
        .task {
            await store.refreshEntitlement()
            if store.product == nil { await store.loadProduct() }
        }
        .sheet(isPresented: $showPaywall) { REStorePaywall().sheetCloseBar() }
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showManage)
        #endif
    }

    /// StoreKit is the ONLY source of the figure (§5.1). No product loaded → the state is said
    /// plainly and retried on demand; a painted price would be a fabricated number on screen.
    @ViewBuilder private var priceLine: some View {
        if let product = store.product {
            Text("\(product.displayPrice) / month")
                .font(.blSystem(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.text)
                .accessibilityIdentifier("bl.re.settings.subscription.price")
        } else {
            HStack(spacing: 10) {
                Text(store.productLoadFailed
                     ? "Price unavailable — the App Store could not be reached."
                     : "Loading price from the App Store…")
                    .font(BLFont.body(12, .semibold)).foregroundColor(BLTheme.sub)
                GhostButton(label: "Try again", icon: "arrow.clockwise", tint: BLTheme.sub) {
                    Task { await store.loadProduct() }
                }
            }
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 10) {
            if store.isSubscribed {
                GhostButton(label: "Manage subscription", icon: "gearshape", tint: BLTheme.gold) {
                    #if os(iOS)
                    showManage = true
                    #else
                    NSWorkspace.shared.open(REStoreCatalog.manageSubscriptionsURL)
                    #endif
                }
                .accessibilityIdentifier("bl.re.settings.subscription.manage")
            } else {
                GoldButton(label: "View subscription options", icon: "lock.open") { showPaywall = true }
                    .accessibilityIdentifier("bl.re.settings.subscription.subscribe")
            }
            GhostButton(label: "Restore Purchases", icon: "arrow.counterclockwise", tint: BLTheme.sub) {
                Task { await store.restore() }
            }
            .accessibilityIdentifier("bl.re.settings.subscription.restore")
            Spacer(minLength: 0)
        }
    }
}
#endif
