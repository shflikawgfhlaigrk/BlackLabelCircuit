#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — cross-platform paid-feature gate facade + paywall.
//
// The trial machinery (Trial.swift) is macOS-Developer-ID-only (App Store Guideline 3.1.1 — no
// non-StoreKit selling in either store build). Call-sites that gate a paid feature (list-build,
// export) shouldn't have to #if-guard the trial-only types, so this facade answers one question
// everywhere: "are paid features allowed right now?" — always yes on iOS and in the Mac App Store
// build (both ship full), trial-driven on the macOS Dev-ID build.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

@MainActor
enum REAccess {
    /// True when list-build / export are allowed. iOS + Mac App Store: always (those builds ship
    /// full). macOS Dev-ID: false only once the 14-day trial expired AND the buyer hasn't purchased.
    static var allowsPaidFeatures: Bool {
        #if os(macOS) && !MAS_BUILD
        return RETrialStore.shared.entitlement.allowsPaidFeatures
        #elseif os(iOS) || MAS_BUILD
        // Store builds sell the paid workflow through StoreKit (3.1.1). The App Store's own
        // entitlement ledger is the only authority — see REStore.swift.
        return REStore.shared.isSubscribed
        #else
        return true
        #endif
    }

    /// True when the Dev-ID trial has expired (drives the paywall + banner). Always false on iOS/MAS.
    static var isTrialExpired: Bool {
        #if os(macOS) && !MAS_BUILD
        return RETrialStore.shared.isExpired
        #else
        return false
        #endif
    }

    /// Days left in the Dev-ID trial (0 when expired/purchased or on iOS/MAS).
    static var trialDaysRemaining: Int {
        #if os(macOS) && !MAS_BUILD
        return RETrialStore.shared.daysRemaining
        #else
        return 0
        #endif
    }

    /// True while the Dev-ID trial is counting down (not yet purchased) — drives the countdown pill.
    static var isInTrial: Bool {
        #if os(macOS) && !MAS_BUILD
        if case .trial = RETrialStore.shared.entitlement { return true }
        #endif
        return false
    }

    /// Refresh the access authority. Called at launch AND on every return to the foreground
    /// (RootView's scenePhase hook) — not once per process.
    ///
    /// Dev-ID: advance the rollback-resistant trial clock.
    /// Store builds: RE-DERIVE the entitlement from `Transaction.currentEntitlements` now.
    /// Merely touching the singleton (what this used to do) only warmed it the FIRST time, so the
    /// first gated tap could still read the cold default (false) and paywall a paying subscriber,
    /// and a subscription started, renewed or cancelled on another device stayed invisible for the
    /// life of the process.
    static func refresh() {
        #if os(macOS) && !MAS_BUILD
        RETrialStore.shared.refresh()
        #elseif os(iOS) || MAS_BUILD
        REStore.shared.refreshFromAppLifecycle()
        #endif
    }

    /// Open the config-driven storefront checkout page (never touches Stripe directly).
    /// Compiles to a no-op outside the Dev-ID build — a store binary must never link to an
    /// external checkout (3.1.1).
    static func openCheckout() {
        #if os(macOS) && !MAS_BUILD
        NSWorkspace.shared.open(RETrialConfig.checkoutURL)
        #endif
    }
}

#if os(macOS) && !MAS_BUILD
// MARK: - Paywall (shown when an expired-trial buyer taps a gated action)
struct TrialPaywallSheet: View {
    @Environment(\.dismiss) var dismiss
    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) { IconBadge(system: "lock.fill", size: 30); Text("Your free trial has ended").font(.blSystem(size: 20, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text); Spacer() }
            Text("Building lists and exporting are unlocked with a purchase. Everything you've already saved stays on this Mac — nothing is deleted. Your workspace is never uploaded to Black Label. Data leaves this Mac only when you trigger it: a skip trace or a letter send goes to the provider you connected yourself, and searches, parcel/comp lookups and route planning query public-records and mapping services.")
                .font(BLFont.body(13, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                gateRow("Unlimited list building over the public-records index")
                gateRow("CSV / list export + LOI mail-send")
                gateRow("Your parcels, owners, routes — all stored locally")
            }
            HStack {
                Spacer()
                GhostButton(label: "Not now", tint: BLTheme.sub) { dismiss() }
                GoldButton(label: "Unlock full access", icon: "arrow.up.right.square") { REAccess.openCheckout(); dismiss() }
            }
        }.blScreenPadding(26) }.sheetFrame(520, 420)
    }
    @ViewBuilder private func gateRow(_ t: String) -> some View {
        HStack(spacing: 8) { Image(systemName: "checkmark.circle.fill").foregroundColor(BLTheme.green); Text(t).font(BLFont.body(12.5, .semibold)).foregroundColor(BLTheme.text).fixedSize(horizontal: false, vertical: true); Spacer() }
    }
}

// MARK: - Trial status pill (countdown while in trial; "ended" CTA when expired)
struct TrialStatusPill: View {
    var onUpgrade: () -> Void = { REAccess.openCheckout() }
    var body: some View {
        Group {
            if REAccess.isTrialExpired {
                Button(action: onUpgrade) {
                    HStack(spacing: 6) { Image(systemName: "lock.fill"); Text("Trial ended — Unlock").font(BLFont.mono(9.5, .bold)) }
                        .foregroundColor(BLTheme.ink).padding(.vertical, 5).padding(.horizontal, 11).background(BLTheme.goldGrad).clipShape(Capsule())
                }.buttonStyle(.plain)
            } else if REAccess.isInTrial {
                HStack(spacing: 6) { Image(systemName: "clock.badge.checkmark"); Text("Trial · \(REAccess.trialDaysRemaining)d left").font(BLFont.mono(9.5, .bold)) }
                    .foregroundColor(BLTheme.gold).padding(.vertical, 5).padding(.horizontal, 11).background(BLTheme.bg2).clipShape(Capsule())
            }
        }
    }
}
#else
// Store builds (iOS + Mac App Store): the paid workflow is sold through StoreKit, so this presents
// the StoreKit paywall. The name is kept so the gated call sites stay #if-free, and no
// hosted-checkout string ever reaches a store binary.
struct TrialPaywallSheet: View { var body: some View { REStorePaywall() } }
struct TrialStatusPill: View {
    var onUpgrade: () -> Void = {}
    var body: some View { EmptyView() }
}
#endif
#endif // circuit-convert
