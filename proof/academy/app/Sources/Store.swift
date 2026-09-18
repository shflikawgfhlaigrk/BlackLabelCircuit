// Black Label Academy — iOS StoreKit 2 auto-renewable subscription (b21).
//
// iOS sells the full library IN StoreKit (Guideline 3.1.1-compliant IAP — the macOS
// Developer-ID build keeps its own Stripe trial machinery in Trial.swift; the two never mix).
// Freemium split (4.2.2 posture — the free tier stays genuinely useful):
//   FREE forever:  the FIRST lesson of every pillar, the entire "New This Month" section, and
//                  every native tool (Daily Review, Tutor, calculators, certificates,
//                  notes/bookmarks/search) operating over accessible content.
//   SUBSCRIBED:    the full lesson library.
//
// Honesty invariants (§5.1):
//   * The price is NEVER hardcoded in copy — it renders exclusively from the StoreKit
//     `Product.displayPrice` the App Store returns. No product loaded -> an honest
//     "price unavailable" state, never a painted number.
//   * Unlock state derives ONLY from `Transaction.currentEntitlements` (+ the
//     `Transaction.updates` listener) — never a locally planted flag.
//   * Every count on the paywall is computed from the loaded library, never a literal.
//   * NO free trial (founder rule 2026-07-21: no free trials anywhere).
#if os(iOS) || MAS_BUILD
import Foundation
import Combine
import StoreKit
import SwiftUI

enum StoreCatalog {
    /// The one App Store Connect product (group "Academy Full Access").
    static let monthlyProductID = "com.blacklabel.academy.full.monthly"
    /// 3.1.2 required links for auto-renewable subscriptions. Both verified serving 200 with real
    /// content (2026-07-22): "Privacy Policy — Black Label Trading LLC" / "Terms of Service…".
    static let privacyURL = URL(string: "https://blacklabelbots.com/privacy")!
    static let termsURL = URL(string: "https://blacklabelbots.com/terms")!
    /// Where "Manage subscription" goes on the Mac App Store build — iOS has an in-app sheet
    /// (`manageSubscriptionsSheet`), macOS does not, so it hands off to the App Store itself.
    static let manageSubscriptionsURL = URL(string: "macappstore://apps.apple.com/account/subscriptions")!
}

/// StoreKit 2 store front: loads the subscription product, tracks the live entitlement, and
/// performs purchase/restore. `@MainActor` ObservableObject driving the paywall + lock state.
@MainActor
final class AcademyStore: ObservableObject {
    enum PurchasePhase: Equatable {
        case idle
        case purchasing
        case pending          // e.g. Ask to Buy — honest "waiting for approval" state
        case failed(String)
    }

    /// The App Store product, or nil until (unless) it loads. All price copy reads from this.
    @Published private(set) var product: Product?
    /// True only when `Transaction.currentEntitlements` carries a verified, unrevoked
    /// transaction for the subscription. The single unlock authority.
    @Published private(set) var isSubscribed = false
    /// True after a product load ATTEMPT failed (offline / no StoreKit environment) — drives the
    /// honest "price unavailable" paywall state instead of a hardcoded figure.
    @Published private(set) var productLoadFailed = false
    @Published private(set) var purchasePhase: PurchasePhase = .idle
    /// Honest outcome of the last Restore Purchases tap (nil until used).
    @Published private(set) var restoreMessage: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        // Observe App Store transaction updates for the app's lifetime (renewals, revocations,
        // Ask-to-Buy approvals, purchases on other devices) and re-derive the entitlement.
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

    /// Load the subscription product from the App Store. Failure is a published, honest state.
    func loadProduct() async {
        do {
            let products = try await Product.products(for: [StoreCatalog.monthlyProductID])
            if let p = products.first(where: { $0.id == StoreCatalog.monthlyProductID }) {
                product = p
                productLoadFailed = false
            } else {
                productLoadFailed = true
            }
        } catch {
            productLoadFailed = true
        }
    }

    /// Re-derive the unlock from the App Store's own entitlement ledger. Never trusts a cache.
    func refreshEntitlement() async {
        var active = false
        for await entitlement in Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == StoreCatalog.monthlyProductID,
               transaction.revocationDate == nil {
                active = true
            }
        }
        isSubscribed = active
    }

    /// Purchase the subscription through StoreKit. The outcome is published, never assumed.
    func purchase() async {
        guard let product else {
            purchasePhase = .failed("The App Store could not be reached. Try again.")
            return
        }
        purchasePhase = .purchasing
        do {
            let result = try await product.purchase()
            switch result {
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

    /// Restore Purchases: sync with the App Store, then re-derive the entitlement. The message
    /// states exactly what happened — restored, or honestly nothing to restore.
    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            restoreMessage = "Restore failed: \(error.localizedDescription)"
            return
        }
        await refreshEntitlement()
        restoreMessage = isSubscribed
            ? "Purchases restored — full library unlocked."
            : "No purchases to restore on this Apple Account."
    }
}

// MARK: - Paywall (the 3.1.1-compliant unlock surface; also the ASC review screenshot)

/// Full-screen unlock surface. Presented as a full-screen cover from the home banner, or pushed
/// in place of the reader when a locked lesson is tapped. Honest by construction: free-vs-full
/// lists computed from the live library, price only from StoreKit, no trial copy.
struct StorePaywall: View {
    @ObservedObject var model: AppModel
    /// Title of the locked lesson that routed here (nil when opened from the banner/settings).
    var lockedTitle: String? = nil
    /// True when presented modally (shows a close affordance + dismisses itself on unlock).
    var isCover: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            AuroraBackdrop().ignoresSafeArea()
            ScrollView {
                VStack(spacing: 18) {
                    header
                    if let t = lockedTitle { lockedContext(t) }
                    accessSplit
                    priceBlock
                    legalBlock
                }
                .padding(.horizontal, 28).padding(.vertical, 26)
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
            }
        }
        .background(BLTheme.bg)
        .accessibilityIdentifier("bl.paywall")
        .overlay(alignment: .topTrailing) {
            if isCover {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.sub)
                        .padding(10)
                        .background(BLTheme.bg2.opacity(0.8), in: Circle())
                        .overlay(Circle().stroke(BLTheme.stroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 14).padding(.trailing, 14)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("bl.paywall.close")
            }
        }
        // A completed purchase closes the modal paywall by itself; the pushed variant is replaced
        // in place by the reader (navigationDestination re-evaluates isUnlocked).
        .onChangeCompat(of: model.store.isSubscribed) { subscribed in
            if subscribed && isCover { dismiss() }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            if let img = appIcon() {
                Image(blImage: img).resizable().frame(width: 58, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            Text("BLACK LABEL").font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.sub).tracking(2.4)
            FoilText(text: "Academy Full Library", size: 27)
            Text("Every lesson, every pillar — with every figure traced to a real source.")
                .font(.system(size: 12.5)).foregroundColor(BLTheme.sub)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private func lockedContext(_ title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").font(.system(size: 11)).foregroundColor(BLTheme.goldLite)
            Text("\u{201C}\(title)\u{201D} is in the full library.")
                .font(.system(size: 12, weight: .semibold)).foregroundColor(BLTheme.text)
                .lineLimit(2).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 13)
        .background(BLTheme.goldBase.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.goldBase.opacity(0.3), lineWidth: 1))
    }

    /// Honest free-vs-subscribed split. Every number is computed from the loaded library.
    private var accessSplit: some View {
        VStack(spacing: 10) {
            splitPanel(
                icon: "checkmark.seal.fill", tint: BLTheme.green, title: "Free forever",
                lines: [
                    "The first lesson of every pillar (\(Pillar.allCases.count) pillars)",
                    "All of New This Month — \(model.count(.newThisMonth)) latest lessons",
                    "Daily Review, Library Tutor, calculators, certificates, notes & search",
                ])
            splitPanel(
                icon: "books.vertical.fill", tint: BLTheme.goldLite, title: "Full library",
                lines: [
                    "All \(model.totalCount) lessons across \(Pillar.allCases.count) pillars",
                    "\(model.totalSourceCount) linked primary sources — every figure cited or cut",
                    "New lessons as they ship, while subscribed",
                ])
        }
    }

    private func splitPanel(icon: String, tint: Color, title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12)).foregroundColor(tint)
                Text(title.uppercased()).font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundColor(tint).tracking(1.6)
            }
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                        .foregroundColor(tint).padding(.top, 3)
                    Text(line).font(.system(size: 12.5)).foregroundColor(BLTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.22), lineWidth: 1))
    }

    /// Price + purchase. The figure comes ONLY from StoreKit; no product -> honest unavailability.
    @ViewBuilder private var priceBlock: some View {
        VStack(spacing: 10) {
            if let product = model.store.product {
                VStack(spacing: 3) {
                    Text("\(product.displayPrice) / month")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundColor(BLTheme.text)
                        .accessibilityIdentifier("bl.paywall.price")
                    Text("Auto-renews monthly until canceled. No free trial.")
                        .font(.system(size: 11)).foregroundColor(BLTheme.sub)
                }
                if model.store.purchasePhase == .purchasing {
                    ProgressView().tint(BLTheme.goldBase).padding(.vertical, 6)
                } else {
                    GoldButton(label: "Subscribe", fill: true, icon: "lock.open") {
                        Task { await model.store.purchase() }
                    }
                    .accessibilityIdentifier("bl.paywall.subscribe")
                }
            } else {
                VStack(spacing: 6) {
                    Text(model.store.productLoadFailed
                         ? "Price unavailable — the App Store could not be reached."
                         : "Loading price from the App Store…")
                        .font(.system(size: 12, weight: .medium)).foregroundColor(BLTheme.sub)
                        .multilineTextAlignment(.center)
                    GhostButton(label: "Try again", icon: "arrow.clockwise") {
                        Task { await model.store.loadProduct() }
                    }
                }
                .padding(.vertical, 4)
            }

            if case .failed(let reason) = model.store.purchasePhase {
                Text(reason).font(.system(size: 11)).foregroundColor(BLTheme.red)
                    .multilineTextAlignment(.center)
            }
            if model.store.purchasePhase == .pending {
                Text("Purchase pending approval (Ask to Buy). Access unlocks when it is approved.")
                    .font(.system(size: 11)).foregroundColor(BLTheme.amber)
                    .multilineTextAlignment(.center)
            }

            GhostButton(label: "Restore Purchases", icon: "arrow.counterclockwise") {
                Task { await model.store.restore() }
            }
            .accessibilityIdentifier("bl.paywall.restore")
            if let msg = model.store.restoreMessage {
                Text(msg).font(.system(size: 11, weight: .medium)).foregroundColor(BLTheme.sub)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("bl.paywall.restorestatus")
            }
        }
        .padding(.top, 4)
    }

    /// Where the buyer actually cancels. Naming the iOS path on a Mac would be an instruction they
    /// cannot follow (§5.1: never put something untrue on screen).
    static var cancelPathLine: String {
        #if os(iOS)
        "Cancel anytime in Settings \u{2192} Apple Account \u{2192} Subscriptions."
        #else
        "Cancel anytime in App Store \u{2192} Account Settings \u{2192} Subscriptions."
        #endif
    }

    /// 3.1.2: functional Privacy Policy + Terms of Use links, plus the cancel path.
    private var legalBlock: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button { openURL(StoreCatalog.privacyURL) } label: {
                    Text("Privacy Policy").font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(BLTheme.cyan)
                }.buttonStyle(.plain)
                Text("·").foregroundColor(BLTheme.sub)
                Button { openURL(StoreCatalog.termsURL) } label: {
                    Text("Terms of Use").font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(BLTheme.cyan)
                }.buttonStyle(.plain)
            }
            Text(Self.cancelPathLine)
                .font(.system(size: 10.5)).foregroundColor(BLTheme.sub)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 12)
    }
}

// MARK: - Settings panel (subscription status + manage/restore + legal)

/// The iOS Settings "Subscription" section: honest live status, the standard manage-subscriptions
/// sheet, Restore Purchases, and the 3.1.2 legal links.
struct StoreStatusPanel: View {
    @ObservedObject var model: AppModel
    @State private var showManage = false
    @State private var showUnlockSheet = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "creditcard").foregroundColor(BLTheme.goldLite).font(.system(size: 12))
                Text("Subscription").font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(BLTheme.goldLite)
                Spacer()
            }
            HStack(spacing: 6) {
                Image(systemName: model.store.isSubscribed ? "checkmark.seal.fill" : "lock.fill")
                    .foregroundColor(model.store.isSubscribed ? BLTheme.green : BLTheme.sub)
                    .font(.system(size: 11))
                Text(statusLine).font(.system(size: 12)).foregroundColor(BLTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if model.store.isSubscribed {
                    Button { showManage = true } label: {
                        Text("Manage subscription").font(.system(size: 11, weight: .semibold))
                            .foregroundColor(BLTheme.cyan)
                    }.buttonStyle(.plain)
                } else {
                    Button { showUnlockSheet = true } label: {
                        Text("Unlock the full library").font(.system(size: 11, weight: .semibold))
                            .foregroundColor(BLTheme.cyan)
                    }.buttonStyle(.plain)
                }
                Button { Task { await model.store.restore() } } label: {
                    Text("Restore Purchases").font(.system(size: 11, weight: .semibold))
                        .foregroundColor(BLTheme.sub)
                }.buttonStyle(.plain)
            }
            if let msg = model.store.restoreMessage {
                Text(msg).font(.system(size: 10.5)).foregroundColor(BLTheme.sub)
            }
            HStack(spacing: 10) {
                Button { openURL(StoreCatalog.privacyURL) } label: {
                    Text("Privacy Policy").font(.system(size: 10.5)).foregroundColor(BLTheme.cyan)
                }.buttonStyle(.plain)
                Button { openURL(StoreCatalog.termsURL) } label: {
                    Text("Terms of Use").font(.system(size: 10.5)).foregroundColor(BLTheme.cyan)
                }.buttonStyle(.plain)
            }
        }
        // Presentation differs by platform: iOS has the in-app manage sheet and full-screen
        // covers; on the Mac App Store neither exists, so managing hands off to the App Store's
        // own subscriptions page and the paywall opens as a sheet.
        #if os(iOS)
        .manageSubscriptionsSheet(isPresented: $showManage)
        .fullScreenCover(isPresented: $showUnlockSheet) {
            StorePaywall(model: model, isCover: true)
        }
        #else
        .sheet(isPresented: $showUnlockSheet) {
            StorePaywall(model: model, isCover: true)
                .frame(minWidth: 460, minHeight: 640)
        }
        .onChangeCompat(of: showManage) { open in
            if open {
                openURL(StoreCatalog.manageSubscriptionsURL)
                showManage = false
            }
        }
        #endif
    }

    private var statusLine: String {
        if model.store.isSubscribed {
            return "Subscribed \u{00B7} full library unlocked"
        }
        return "Free \u{00B7} \(model.freeLessonIDs.count) of \(model.totalCount) lessons free \u{00B7} all tools included"
    }
}
#endif
