#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Growth-tier screens:
//   Social Profiles (connect + per-platform bio generator)
//   Ad Campaigns (builder + budget pacing + honest provider connect)
//   Email Journeys (visual drip automation: trigger → wait → send → branch)
//   Scheduler (calendar view + best-time-to-post from the buyer's own data)
//   Influencers (CRM + fit scoring from entered facts)
// All on the buyer's OWN/empty data. No fabricated metrics anywhere.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// Local money helper — honest formatting, no fabricated figures.
private func money(_ v: Double) -> String {
    let f = NumberFormatter(); f.numberStyle = .currency; f.maximumFractionDigits = v.truncatingRemainder(dividingBy: 1) == 0 ? 0 : 2
    return f.string(from: NSNumber(value: v)) ?? "$\(Int(v))"
}
private func copyStr(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
private func openURLString(_ s: String) {
    if let u = URL(string: s) {
        DemoMode.openExternal(u, simulatedNote: "Demo: this would open \(s) in your browser.")
    }
}

// MARK: - 1) Social Profiles + per-platform bio generator

struct SocialProfilesScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var connecting: SocialPlatform? = nil
    @State private var bios: [SocialPlatform: String] = [:]
    @State private var toast = ""

    private var voice: BrandVoiceInput {
        BrandVoiceInput(brand: prefs.brandName, tagline: prefs.tagline,
                        city: prefs.defaultMarket, industry: prefs.defaultVertical, hashtag: prefs.captionHashtag)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Social Profiles",
                             subtitle: "Link your own brand accounts and generate a platform-perfect bio for each.")

                if prefs.brandName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Panel(title: "Set your brand first", icon: "exclamationmark.circle") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bios are generated from your brand name, tagline, market and hashtag. Add them in Settings → Brand identity so nothing is invented.")
                                .font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }
                }

                Panel(title: "Your platforms", icon: "antenna.radiowaves.left.and.right") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(SocialPlatform.allCases) { p in
                            platformCard(p)
                        }
                    }
                }

                if !toast.isEmpty {
                    Text(toast).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green)
                }
            }
            .padding(28)
        }
        .sheet(item: $connecting) { p in ConnectSheet(platform: p) { toast = "\(p.rawValue) linked." }.environmentObject(model).sheetCloseBar() }
        .onAppear { model.refreshSocialCredentialFlags() }
    }

    @ViewBuilder private func platformCard(_ p: SocialPlatform) -> some View {
        let prof = model.profile(for: p)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: p.icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                    .frame(width: 28, height: 28).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.rawValue).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    if let prof = prof {
                        Text("@\(prof.handle)").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    } else {
                        Text("Not linked").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
                Spacer()
                // Green means "we checked the expiry and it is still in the future" — never merely
                // "a token exists". Expired reads red; unknown reads gold, not green.
                if let prof = prof {
                    StatusPill(text: prof.connectionLabel, tint: socialPillTint(prof))
                }
            }

            // Bio generator
            let generated = bios[p] ?? prof?.bio ?? ""
            if !generated.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(generated).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(generated.count)/\(p.bioLimit)")
                        .font(BLFonts.mono(9.5, weight: .bold))
                        .foregroundColor(generated.count > p.bioLimit ? BLTheme.danger : BLTheme.sub)
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
            }

            HStack(spacing: 8) {
                GhostButton(label: "Generate bio", icon: "wand.and.stars") {
                    bios[p] = BioEngine.bio(voice, for: p)
                }
                if let g = bios[p], !g.isEmpty {
                    IconButton(system: "doc.on.doc") { copyStr(g); toast = "Bio copied." }
                    if prof != nil {
                        IconButton(system: "checkmark.circle") {
                            if var pr = prof { pr.bio = g; model.connect(pr); toast = "Bio saved to \(p.rawValue)." }
                        }
                    }
                }
                Spacer()
                if prof == nil {
                    GhostButton(label: "Link", icon: "link") { connecting = p }
                } else {
                    if let prof = prof, let url = p.profileURL(handle: prof.handle) {
                        IconButton(system: "arrow.up.right.square") { openURLString(url) }
                    }
                    IconButton(system: "trash", tint: BLTheme.danger) { if let prof = prof { model.disconnect(prof) } }
                }
            }
        }
        .padding(13).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassBackground(radius: 14, sweep: false))
    }

    /// Pill colour from CREDENTIAL HEALTH, not from a token merely being on disk.
    /// live → green · expired → red · unknown expiry (or profile-only) → gold.
    private func socialPillTint(_ prof: SocialProfile) -> Color {
        switch prof.liveness() {
        case .live:    return BLTheme.green
        case .expired: return BLTheme.danger
        case .unknown: return BLTheme.gold
        }
    }
}

/// Honest connect sheet. Primary path = one-tap own-it OAuth: the buyer enters their own App ID
/// (+ secret for confidential providers), taps Connect, authorizes in THEIR own account, and the
/// token is captured automatically through OUR hosted redirect and minted on-device — no pasting,
/// no self-hosted redirect. Manual token paste remains as a fallback. Tokens live in Keychain, never
/// in workspace JSON; we never mint a token or fake a connection.
struct ConnectSheet: View {
    let platform: SocialPlatform
    var onLinked: () -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var handle = ""
    @State private var token = ""
    @State private var appID = ""
    @State private var appSecret = ""
    @State private var note = ""
    @State private var connecting = false

    private var canAuthorize: Bool { SocialOAuth.supportsAuthorize(platform) }
    private var needsSecret: Bool { SocialOAuth.provider(for: platform)?.secretInBody ?? false }
    private var appIDKey: String { "social.appID.\(platform.rawValue)" }

    /// Plain-language, end-user framing of what linking this network involves and why. No developer jargon
    /// up front. TikTok has no desktop-OAuth publish path, so we say so honestly instead of hiding it.
    private var connectIntro: String {
        if canAuthorize {
            return "Add your \(platform.rawValue) profile so the app can plan content, open the right account, and hand off finished posts. Direct API publishing is available under Advanced setup."
        } else {
            return "\(platform.rawValue) has no desktop publishing API. Rendered reels reach \(platform.rawValue) through the Reel Relay — the app hands the finished video to your phone and opens \(platform.rawValue)’s own composer. Here you can link your profile for reference; publishing happens from your phone."
        }
    }

    /// Meta (Instagram / Facebook / Threads) all authorize on Facebook’s developer portal — surfacing
    /// this removes the “why is Instagram asking about Facebook?” confusion the 2026-07-08 tester hit.
    private var metaPortalNote: String? {
        switch platform {
        case .instagram, .threads:
            return "Note: \(platform.rawValue) is a Meta product, so you create the app on Facebook’s developer site (developers.facebook.com) with an Instagram/Meta business account. That’s expected — it isn’t a mistake."
        case .facebook:
            return nil
        default:
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: platform.icon).font(.system(size: 16, weight: .bold)).foregroundColor(BLTheme.gold)
                    Text("Link \(platform.rawValue)").font(BLFonts.display(22, weight: .medium)).foregroundColor(BLTheme.text)
                    Spacer()
                }
                // Plain-language framing so an end user (not a developer) understands what this sheet asks
                // for and why — the 2026-07-08 tester hit a bare "app ID" field with no explanation.
                Text(connectIntro)
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                if let meta = metaPortalNote {
                    Text(meta)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Field(title: "Your @handle on \(platform.rawValue)", text: $handle, prompt: "yourbrand")
                Text("Your handle is your public username on \(platform.rawValue) — the name after the @ (e.g. @yourbrand). Used to label the account and to open your profile.")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    GhostButton(label: "Open \(platform.rawValue)", icon: "arrow.up.right") { openSocialTarget() }
                }

                // One-tap own-it OAuth. The buyer registers OUR hosted redirect (no self-hosting),
                // taps Connect, authorizes in their own account; the code returns through our bounce
                // to the app and the token is exchanged on-device. Nothing is proxied through us.
                if canAuthorize {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Direct publishing requires a one-time provider app registration. This is optional; profile linking and post handoff work without it.")
                                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                            // Lands on the app list / credential surface itself — not the portal's
                            // marketing home, which has no route to an App ID.
                            GhostButton(label: "Get your App ID", icon: "arrow.up.right") {
                                DemoMode.openExternal(platform.credentialURL, simulatedNote: "Demo: this would open \(platform.credentialURL.absoluteString).")
                            }
                            Text("Opens \(platform.credentialPageName) — create an app there (or open an existing one) and its App ID\(needsSecret ? " and secret are" : " is") on that app's settings.")
                                .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                            Field(title: "App ID (also called Client ID)", text: $appID, prompt: "Paste the App ID from \(platform.devPortal)")
                            if needsSecret {
                                SecureRow(title: "App secret", prompt: "Paste the secret from that same app") { appSecret = $0 }
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("REDIRECT URL TO REGISTER")
                                    .font(BLFonts.mono(8.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                                HStack(spacing: 6) {
                                    Text(SocialOAuth.redirectURI).font(BLFonts.mono(10.5, weight: .semibold)).foregroundColor(BLTheme.gold)
                                        .lineLimit(1).truncationMode(.middle)
                                    IconButton(system: "doc.on.doc") { copyStr(SocialOAuth.redirectURI) }
                                }
                            }
                            GoldButton(label: connecting ? "Connecting…" : "Authorize \(platform.rawValue)", fill: true, icon: "link") {
                                startConnect()
                            }
                            .opacity(connecting ? 0.6 : 1).disabled(connecting)
                            if !note.isEmpty {
                                Text(note).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(note.hasPrefix("✓") ? BLTheme.green : BLTheme.gold).fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Authorization happens in your own \(platform.rawValue) account. Credentials and tokens remain in this \(PlatformWords.device)'s Keychain.")
                                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "slider.horizontal.3")
                            Text("Advanced direct publishing setup")
                        }
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                    .padding(11).background(BLTheme.panel.opacity(0.5)).clipShape(RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 5) {
                        Field(title: "Access token", text: $token, prompt: "Paste a token you already have")
                        Text("Optional fallback. Tokens stay in Keychain on this device and are excluded from workspace backup.")
                            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 6)
                } label: {
                    Text("Paste a token instead").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                }

                Text("“Link by profile” just saves your @handle so the app can label the account and open your profile — it does NOT connect for publishing (that needs the token setup above). It stays marked “profile only” until a real token is stored.")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    GhostButton(label: "Cancel") { dismiss() }
                    Spacer()
                    GoldButton(label: "Add profile", icon: "person.crop.circle") {
                        let h = handle.trimmingCharacters(in: CharacterSet(charactersIn: " @"))
                        guard !h.isEmpty else { note = "Enter your @handle above first — it’s your public username on \(platform.rawValue)."; return }
                        model.connect(SocialProfile(platform: platform, handle: h), token: token)
                        onLinked(); dismiss()
                    }
                }
            }
            .padding(26)
        }
        #if os(macOS)
        .frame(width: 460, height: canAuthorize ? 600 : 340)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
        .onAppear { appID = UserDefaults.standard.string(forKey: appIDKey) ?? "" }
    }

    private func startConnect() {
        let id = appID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else {
            note = "Enter your own App ID first. Opening \(platform.credentialPageName)."
            DemoMode.openExternal(platform.credentialURL, simulatedNote: "Demo: this would open \(platform.credentialURL.absoluteString).")
            return
        }
        if needsSecret && appSecret.trimmingCharacters(in: .whitespaces).isEmpty {
            note = "Enter your app secret so the token can be minted on this device — it is on the same app's settings. Opening \(platform.credentialPageName)."
            DemoMode.openExternal(platform.credentialURL, simulatedNote: "Demo: this would open \(platform.credentialURL.absoluteString).")
            return
        }
        UserDefaults.standard.set(id, forKey: appIDKey)
        note = ""; connecting = true
        SocialOAuthSession.shared.connect(platform: platform, appID: id,
                                          appSecret: needsSecret ? appSecret : nil) { result in
            connecting = false
            switch result {
            case .success(let tok):
                let h = handle.trimmingCharacters(in: CharacterSet(charactersIn: " @"))
                // The provider's own `expires_in`/`expires_at` is the only trustworthy source for
                // when this token dies. Record it now — nil (provider said nothing) is stored as
                // nil, so liveness reads UNKNOWN rather than pretending the token is good.
                let expiry = SocialTokenExpiryStore.expiryDate(fromOAuthResponse: tok.raw)
                model.connect(SocialProfile(platform: platform, handle: h.isEmpty ? appID : h),
                              token: tok.accessToken, expiry: expiry)
                onLinked(); dismiss()
            case .failure(let e):
                note = (e as? LocalizedError)?.errorDescription ?? e.localizedDescription
            }
        }
    }

    private func openSocialTarget() {
        let h = handle.trimmingCharacters(in: CharacterSet(charactersIn: " @"))
        if let s = platform.profileURL(handle: h), let url = URL(string: s) {
            DemoMode.openExternal(url, simulatedNote: "Demo: this would open \(s).")
        } else {
            DemoMode.openExternal(platform.accountHomeURL, simulatedNote: "Demo: this would open \(platform.accountHomeURL.absoluteString).")
        }
    }
}

// MARK: - 2) Ad Campaigns

struct AdCampaignsScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var editing: AdCampaign? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Ad Campaigns",
                             subtitle: "Plan budgets, auto-build trackable links (UTM tags), and track the real spend you log from your ad account.")

                Panel(title: "Connect an ad account", icon: "link.badge.plus") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Publishing & live metrics require your own ad account. Connect a provider below, or run a campaign in plan-only mode and log spend manually — nothing is ever fabricated.")
                            .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        LazyVGrid(columns: blGridColumns(), spacing: 9) {
                            ForEach(AdProvider.allCases) { pr in
                                HStack(spacing: 7) {
                                    Image(systemName: pr.icon).font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(pr.rawValue).font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                        Text("Connect at \(pr.devPortal)").font(.system(size: 8.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                                    }
                                    Spacer()
                                    IconButton(system: "arrow.up.right") { openURLString(pr.credentialURL.absoluteString) }
                                }
                                .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                            }
                        }
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your campaigns").font(BLFonts.display(20, weight: .medium)).foregroundColor(BLTheme.text)
                        Text("Plans live here — the ads themselves run in your ad account; nothing is published from this screen.")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                    Spacer()
                    GoldButton(label: "New campaign", icon: "plus") { editing = AdCampaign(name: "", destinationURL: "") }
                }

                if model.adCampaigns.isEmpty {
                    EmptyState(icon: "megaphone", title: "No campaigns yet",
                               hint: "Create a campaign to plan a budget, auto-build a trackable link, and track real spend you log.")
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(model.adCampaigns) { c in adCard(c) }
                }
            }
            .padding(28)
        }
        .sheet(item: $editing) { e in AdEditor(campaign: e) { model.upsertAd($0) }.environmentObject(model).sheetCloseBar() }
    }

    @ViewBuilder private func adCard(_ c: AdCampaign) -> some View {
        let pacing = AdEngine.pacing(for: c)
        let pace = AdEngine.paceRatio(pacing)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: c.provider.icon).font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name.isEmpty ? "Untitled campaign" : c.name).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("\(c.provider.rawValue) · \(c.objective.rawValue)").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                if let pace = pace {
                    StatusPill(text: pace > 1.08 ? "Over pace" : (pace < 0.92 ? "Under pace" : "On pace"),
                               tint: pace > 1.08 ? BLTheme.danger : (pace < 0.92 ? BLTheme.gold : BLTheme.green))
                }
                IconButton(system: "pencil") { editing = c }
                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteAd(c) }
            }

            // Budget progress (real: logged spend vs planned budget)
            if c.totalBudget > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 5).fill(BLTheme.bg2).frame(height: 10)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(AdEngine.budgetClamped(pacing) ? AnyShapeStyle(BLTheme.danger) : AnyShapeStyle(BLTheme.goldGrad))
                                .frame(width: max(0, min(1, c.spent / c.totalBudget)) * geo.size.width, height: 10)
                        }
                    }.frame(height: 10)
                    HStack {
                        Text("\(money(c.spent)) spent of \(money(c.totalBudget))").font(BLFonts.mono(10.5, weight: .bold)).foregroundColor(BLTheme.text)
                        Spacer()
                        Text("\(money(AdEngine.remaining(pacing))) left · \(AdEngine.daysLeft(pacing))d").font(BLFonts.mono(10.5, weight: .bold)).foregroundColor(BLTheme.sub)
                    }
                }
            }

            // Real metrics (only what the buyer logged; honest "—" when unknown)
            HStack(spacing: 18) {
                miniMetric("Daily", money(AdEngine.dailyBudget(pacing)))
                miniMetric("Clicks", c.loggedClicks > 0 ? "\(c.loggedClicks)" : "—")
                miniMetric("CPC", c.costPerClick.map { money($0) } ?? "—")
                miniMetric("Conv.", c.loggedConversions > 0 ? "\(c.loggedConversions)" : "—")
                miniMetric("CPA", c.costPerConversion.map { money($0) } ?? "—")
            }

            if let tagged = c.taggedURL {
                HStack(spacing: 7) {
                    Image(systemName: "link").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.gold)
                    Text(tagged).font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.sub).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    IconButton(system: "doc.on.doc") { copyStr(tagged) }
                }
                .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassBackground(radius: 14, sweep: false))
    }

    private func miniMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(BLFonts.mono(14, weight: .heavy)).foregroundColor(BLTheme.gold)
            Text(label.uppercased()).font(.system(size: 8.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
        }
    }
}

struct AdEditor: View {
    @State var campaign: AdCampaign
    var onSave: (AdCampaign) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(campaign.name.isEmpty ? "New campaign" : "Edit campaign").font(BLFonts.display(22, weight: .medium)).foregroundColor(BLTheme.text)
                Field(title: "Campaign name", text: $campaign.name, prompt: "Spring lead-gen")
                HStack(spacing: 12) {
                    pickerBox("Provider") {
                        Picker("", selection: $campaign.provider) { ForEach(AdProvider.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                    }
                    pickerBox("Objective") {
                        Picker("", selection: $campaign.objective) { ForEach(AdObjective.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                    }
                }
                Field(title: "Destination URL", text: $campaign.destinationURL, prompt: "https://yoursite.com/offer")
                HStack(spacing: 12) {
                    doubleField("Total budget", $campaign.totalBudget)
                    doubleField("Spent so far (logged)", $campaign.spent)
                }
                HStack(spacing: 12) {
                    intField("Clicks logged", $campaign.loggedClicks)
                    intField("Conversions logged", $campaign.loggedConversions)
                }
                HStack(spacing: 12) {
                    dateBox("Start", $campaign.startDate)
                    dateBox("End", $campaign.endDate)
                }
                Text("Spend, clicks and conversions are values you read from your own ad account and enter here. The app never auto-fills or invents them.")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                HStack {
                    GhostButton(label: "Cancel") { dismiss() }
                    Spacer()
                    GoldButton(label: "Save campaign", icon: "checkmark") { onSave(campaign); dismiss() }
                }
            }
            .padding(26)
        }
        #if os(macOS)
        .frame(width: 520, height: 620)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
    }

    private func pickerBox<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
            content().padding(.vertical, 4).padding(.horizontal, 8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func doubleField(_ title: String, _ v: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
            TextField("0", value: v, format: .number).textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(.vertical, 10).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func intField(_ title: String, _ v: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
            TextField("0", value: v, format: .number).textFieldStyle(.plain)
                .font(.system(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(.vertical, 10).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func dateBox(_ title: String, _ v: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
            DatePicker("", selection: v, displayedComponents: .date).labelsHidden().tint(BLTheme.gold)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 3) Email Journeys (visual drip automation)

struct JourneyScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var leadEngine: LeadEngineStore
    @State private var editing: Journey? = nil
    @State private var ranNote = ""
    @State private var running = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Email Journeys",
                             subtitle: "Build automations: trigger → wait → send → branch — then run them. Contacts enroll, advance through waits, and their next email is queued within your warmup cap.")

                if !model.journeys.isEmpty {
                    Panel(title: "Run", icon: "play.circle.fill") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                GoldButton(label: running ? "Running…" : "Run journeys now", icon: "bolt.fill") {
                                    guard !running else { return }
                                    running = true
                                    ranNote = ""
                                    Task {
                                        let r = await JourneyExecutor.runDue(model: model, settings: leadEngine.settings)
                                        running = false
                                        let active = model.journeys.filter { $0.enabled }.count
                                        if active == 0 {
                                            ranNote = "No active journeys — toggle one on to enroll contacts."
                                        } else if r.due == 0 {
                                            ranNote = "No journey emails are due yet."
                                        } else {
                                            ranNote = "\(r.sent) sent · \(r.blocked) held · \(r.due) due. Held messages stay due and retry without advancing."
                                        }
                                    }
                                }
                                Spacer()
                                Text("\(model.journeyRuns.filter { !$0.done }.count) active · \(model.journeyRuns.filter { $0.done }.count) finished")
                                    .font(BLFonts.mono(10, weight: .semibold)).foregroundColor(BLTheme.sub)
                            }
                            if !ranNote.isEmpty {
                                Text(ranNote).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Sends use your connected mailbox through the shared delivery gate. A journey advances only after provider acceptance; suppression, pacing, or transport failures stay due.")
                                .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                HStack {
                    Text("Your journeys").font(BLFonts.display(20, weight: .medium)).foregroundColor(BLTheme.text)
                    Spacer()
                    GoldButton(label: "New journey", icon: "plus") {
                        editing = Journey(name: "", steps: [JourneyStep(kind: .trigger, note: "New lead")])
                    }
                }
                if model.journeys.isEmpty {
                    EmptyState(icon: "arrow.triangle.branch", title: "No journeys yet",
                               hint: "Create a drip automation that sends the right email at the right time after a trigger.")
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(model.journeys) { j in journeyCard(j) }
                }
            }
            .padding(28)
        }
        .sheet(item: $editing) { j in JourneyEditor(journey: j) { model.upsertJourney($0) }.environmentObject(model).sheetCloseBar() }
    }

    @ViewBuilder private func journeyCard(_ j: Journey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(j.name.isEmpty ? "Untitled journey" : j.name).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                StatusPill(text: j.enabled ? "Active" : "Off", tint: j.enabled ? BLTheme.green : BLTheme.sub)
                Spacer()
                IconButton(system: "pencil") { editing = j }
                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteJourney(j) }
            }
            HStack(spacing: 6) {
                ForEach(j.steps) { s in
                    HStack(spacing: 4) {
                        Image(systemName: s.kind.icon).font(.system(size: 9, weight: .bold)).foregroundColor(BLTheme.gold)
                        Text(stepLabel(s)).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8).background(BLTheme.bg2).clipShape(Capsule())
                    if s.id != j.steps.last?.id { Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundColor(BLTheme.sub.opacity(0.5)) }
                }
            }
            Text("\(JourneyEngine.sendCount(j.steps)) sends over \(JourneyEngine.span(j.steps)) days")
                .font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.sub)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassBackground(radius: 14, sweep: false))
    }

    private func stepLabel(_ s: JourneyStep) -> String {
        switch s.kind {
        case .trigger: return s.note.isEmpty ? "Trigger" : s.note
        case .wait: return "Wait \(s.waitDays)d"
        case .send: return s.campaignName.isEmpty ? "Send" : s.campaignName
        case .branch: return "If #\(s.branchTag)"
        }
    }
}

// MARK: - Newsletters (recurring broadcast on the buyer's own list)

/// A pending newsletter send awaiting the recipient-count confirmation sheet.
struct NewsletterConfirm: Identifiable {
    let id = UUID()
    var newsletter: Newsletter
    var recipients: [String]
    var plan: NewsletterPlan
}

struct NewsletterScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var leadEngine: LeadEngineStore
    @State private var name = ""
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var cadence = 7
    @State private var note = ""
    @State private var sending: UUID? = nil
    @State private var sendNote = ""
    @State private var confirm: NewsletterConfirm? = nil
    @State private var lastResults: [NewsletterRecipientOutcome] = []

    /// The buyer's own configured + enabled sending mailboxes (Connectors → Mailboxes). This is the
    /// zero-config send path — no Cloudflare Worker, no wrangler, no shared secret.
    private var mailboxes: [Mailbox] { OutboundMailer.sendReadyMailboxes(leadEngine.settings) }
    private var canSend: Bool { !mailboxes.isEmpty }
    private var primary: Mailbox { mailboxes.first ?? leadEngine.settings.mailbox }

    /// Cleaned + de-duplicated recipient emails drawn from the buyer's OWN contacts, excluding the
    /// tenant's explicit suppressions, known bounces, and opt-out CRM tags.
    private var suppressionKeys: Set<String> {
        let settings = leadEngine.settings
        var keys = Set(settings.suppressedEmails.map(EmailSuppression.normalized))
        for lead in model.leads where EmailSuppression.isSuppressed(
            lead.email, configured: settings.suppressedEmails,
            bounced: lead.sendStatus == .bounced, tags: lead.tags
        ) {
            keys.insert(EmailSuppression.normalized(lead.email))
        }
        return keys
    }
    private var recipients: [String] {
        NewsletterDispatch.recipients(from: model.allContacts, suppressed: suppressionKeys)
    }

    /// Warmup capacity of each mailbox today (cap − sent), for the recipient-count confirm sheet.
    private var capacities: [MailboxCapacity] {
        mailboxes.map { MailboxCapacity(dailyCap: $0.dailyCap, sentToday: model.sentToday(mailboxID: $0.id), enabled: $0.enabled) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Newsletters", subtitle: "Recurring broadcasts to your own list — sent over your own mailbox on your cadence. No developer setup.")

                // Own-mailbox send-path status — honest about whether a real send can fire.
                Panel(title: "Send path", icon: "envelope.badge.fill") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: canSend ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundColor(canSend ? BLTheme.green : BLTheme.gold)
                            Text(canSend
                                 ? "Sends over your own mailbox (\(primary.fromEmail)) — warmup-capped, CAN-SPAM footer + one-click unsubscribe added automatically."
                                 : "Connect a sending mailbox in Connectors → Mailboxes to send newsletters. No Cloudflare Worker or wrangler needed.")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundColor(canSend ? BLTheme.text : BLTheme.gold).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                        }
                        if primary.physicalAddress.isEmpty && canSend {
                            Text("Add your physical mailing address to your mailbox (CAN-SPAM) before the first send.")
                                .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !sendNote.isEmpty {
                            Text(sendNote).font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundColor(sendNote.hasPrefix("✓") ? BLTheme.green : BLTheme.gold).fixedSize(horizontal: false, vertical: true)
                        }
                        if !lastResults.isEmpty {
                            let failures = lastResults.filter { $0.state == .failed }
                            if !failures.isEmpty {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(failures.count) recipient\(failures.count == 1 ? "" : "s") failed:")
                                        .font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.danger)
                                    ForEach(failures.prefix(6), id: \.email) { r in
                                        Text("• \(r.email): \(r.detail)").font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
                Panel(title: "New newsletter", icon: "envelope.open.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        Field(title: "Name", text: $name, prompt: "Monthly update")
                        Field(title: "Subject", text: $subject, prompt: "What's new at \(prefs.displayBrand)")
                        VStack(alignment: .leading, spacing: 4) {
                            Text("BODY").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                            TextEditor(text: $bodyText).frame(minHeight: 100)
                                .font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                                .padding(6).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                        }
                        Stepper("Cadence: every \(cadence) day\(cadence == 1 ? "" : "s")", value: $cadence, in: 1...90).font(.system(size: 12, design: .rounded))
                        GoldButton(label: "Save newsletter", fill: true, icon: "tray.and.arrow.down.fill") {
                            guard !subject.trimmingCharacters(in: .whitespaces).isEmpty else { note = "Add a subject first."; return }
                            model.upsertNewsletter(Newsletter(name: name, subject: subject, body: bodyText, cadenceDays: cadence))
                            name = ""; subject = ""; bodyText = ""; cadence = 7; note = "Saved."
                        }
                        if !note.isEmpty { Text(note).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green) }
                    }
                }
                if !model.newsletters.isEmpty {
                    Panel(title: "Your newsletters (\(model.newsletters.count))", icon: "envelope.fill") {
                        VStack(spacing: 8) {
                            ForEach(model.newsletters) { n in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(n.subject.isEmpty ? (n.name.isEmpty ? "Untitled" : n.name) : n.subject)
                                            .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                        Text("Every \(n.cadenceDays)d · \(n.isDue(now: Date()) ? "due now" : "scheduled")")
                                            .font(.system(size: 10.5, design: .rounded)).foregroundColor(n.isDue(now: Date()) ? BLTheme.gold : BLTheme.sub)
                                    }
                                    Spacer()
                                    GhostButton(label: sending == n.id ? "Sending…" : "Send now", icon: "paperplane.fill") {
                                        prepareSend(n)
                                    }
                                    .disabled(!canSend || sending != nil)
                                    .opacity(canSend ? 1 : 0.5)
                                    IconButton(system: "trash", tint: BLTheme.danger) { model.deleteNewsletter(n) }
                                }
                                .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .sheet(item: $confirm) { c in
            NewsletterConfirmSheet(confirm: c,
                                   fromEmail: primary.fromEmail,
                                   onCancel: { confirm = nil },
                                   onSend: { confirm = nil; performSend(c) })
                .sheetCloseBar()
        }
    }

    /// Step 1: validate readiness, compute the recipient count + warmup plan, and raise the
    /// confirm sheet. A non-developer never sees a socket or a Worker — just "send to N people?".
    private func prepareSend(_ n: Newsletter) {
        var newsletter = n
        if var progress = newsletter.deliveryProgress {
            progress.markSuppressed(suppressionKeys)
            if progress.isComplete {
                newsletter.lastSentAt = Date()
                newsletter.deliveryProgress = nil
                model.upsertNewsletter(newsletter)
                sendNote = "✓ Delivery complete — \(progress.completedCount) sent · \(progress.suppressedCount) suppressed."
                return
            }
            newsletter.deliveryProgress = progress
            model.upsertNewsletter(newsletter)
        }
        let targetRecipients = newsletter.deliveryProgress?.retryableRecipients ?? recipients
        if targetRecipients.isEmpty {
            sendNote = "No unsuppressed contacts with a valid email yet."
            return
        }
        let blockers = NewsletterMailbox.readiness(
            mailboxCount: mailboxes.count, recipientCount: targetRecipients.count,
            hasFromIdentity: !primary.fromEmail.isEmpty,
            hasPhysicalAddress: !primary.physicalAddress.isEmpty)
        guard blockers.isEmpty else { sendNote = blockers.first!; return }
        lastResults = []; sendNote = ""
        let plan = NewsletterMailbox.plan(recipientCount: targetRecipients.count, mailboxes: capacities)
        confirm = NewsletterConfirm(newsletter: newsletter, recipients: targetRecipients, plan: plan)
    }

    /// Step 2 (after the buyer confirms): send over the buyer's OWN mailbox through the shared
    /// warmup-capped transport, with the CAN-SPAM footer + one-click List-Unsubscribe header added.
    /// Advances the cadence only when every intended recipient has a confirmed send. Per-recipient
    /// failures are surfaced honestly; recipients beyond today's warmup cap are deferred.
    private func performSend(_ c: NewsletterConfirm) {
        let n = c.newsletter
        sending = n.id; sendNote = ""
        let mb = primary
        let settings = leadEngine.settings
        let subject = n.subject.isEmpty ? n.name : n.subject
        let body = NewsletterMailbox.composeBody(
            n.body, fromName: mb.fromName, fromEmail: mb.fromEmail,
            physicalAddress: mb.physicalAddress, unsubscribe: "mailto:\(mb.fromEmail)?subject=unsubscribe")
        let headers = NewsletterMailbox.listUnsubscribeHeaders(mailtoEmail: mb.fromEmail, oneClickURL: nil)
        let capacity = c.plan.capacityToday
        Task {
            let report = await NewsletterMailbox.run(recipients: c.recipients, capacity: capacity) { addr in
                let r = await OutboundMailer.send(to: addr, subject: subject, body: body,
                                                  model: model, settings: settings, extraHeaders: headers)
                return (r.sent, r.detail)
            }
            await MainActor.run {
                sending = nil
                lastResults = report.results
                var progress = n.deliveryProgress ?? NewsletterDeliveryProgress(
                    recipients: c.recipients,
                    deliveryID: NewsletterDeliveryProgress.stableDeliveryID(newsletterID: n.id, lastSentAt: n.lastSentAt)
                )
                for outcome in report.results {
                    switch outcome.state {
                    case .sent: progress.record(email: outcome.email, landed: true, detail: outcome.detail)
                    case .failed: progress.record(email: outcome.email, landed: false, detail: outcome.detail)
                    case .deferred: break
                    }
                }
                var updated = n
                if progress.isComplete {
                    updated.lastSentAt = Date()
                    updated.deliveryProgress = nil
                    sendNote = "✓ \(progress.completedCount) sent · \(progress.suppressedCount) suppressed"
                } else {
                    updated.deliveryProgress = progress
                    sendNote = report.summary + " · \(progress.remainingCount) remain due"
                }
                model.upsertNewsletter(updated)
            }
        }
    }
}

/// Recipient-count confirmation before a real newsletter send. A non-developer sees exactly who this
/// goes to and how the warmup cap splits the send — no wrangler, no Worker, no surprise blast.
struct NewsletterConfirmSheet: View {
    let confirm: NewsletterConfirm
    let fromEmail: String
    var onCancel: () -> Void
    var onSend: () -> Void

    var body: some View {
        let p = confirm.plan
        VStack(alignment: .leading, spacing: 16) {
            Text("Send this newsletter?").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text(confirm.newsletter.subject.isEmpty ? confirm.newsletter.name : confirm.newsletter.subject)
                .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
            VStack(alignment: .leading, spacing: 8) {
                row("Recipients", "\(p.recipientCount) contact\(p.recipientCount == 1 ? "" : "s")")
                row("Sends now", "\(p.willSend) — from \(fromEmail)")
                if p.willDefer > 0 {
                    row("Deferred", "\(p.willDefer) — over today's warmup cap; go out on the next run")
                }
                row("Compliance", "CAN-SPAM footer + one-click unsubscribe added automatically")
            }
            .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                GhostButton(label: "Cancel", icon: "xmark") { onCancel() }
                Spacer()
                GoldButton(label: p.willSend == 0 ? "Nothing to send" : "Send to \(p.willSend)", fill: true, icon: "paperplane.fill") {
                    if p.willSend > 0 { onSend() } else { onCancel() }
                }
            }
        }
        .padding(22)
        #if os(macOS)
        .frame(width: 420)
        #else
        .frame(maxWidth: .infinity)
        #endif
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label.uppercased()).font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).frame(width: 88, alignment: .leading)
            Text(value).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct JourneyEditor: View {
    @State var journey: Journey
    var onSave: (Journey) -> Void
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var simTags = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(journey.name.isEmpty ? "New journey" : "Edit journey").font(BLFonts.display(22, weight: .medium)).foregroundColor(BLTheme.text)
                Field(title: "Journey name", text: $journey.name, prompt: "Welcome series")
                Toggle(isOn: $journey.enabled) { Text("Active").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text) }
                    .toggleStyle(.switch).tint(BLTheme.gold)

                // Distinct sender for this journey (managed in Settings → Senders).
                VStack(alignment: .leading, spacing: 6) {
                    Text("SEND FROM").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
                    if model.senders.isEmpty {
                        Text("Add a sender identity in Settings to send from a distinct address; otherwise your default mailbox is used.")
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    } else {
                        Picker("", selection: Binding(get: { journey.senderID ?? model.senders.first!.id },
                                                       set: { journey.senderID = $0 })) {
                            ForEach(model.senders) { Text($0.label).tag($0.id) }
                        }.labelsHidden().pickerStyle(.menu).tint(BLTheme.gold)
                    }
                }

                // Steps
                VStack(alignment: .leading, spacing: 8) {
                    Text("STEPS").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.7)
                    ForEach($journey.steps) { $s in stepRow($s) }
                    HStack(spacing: 8) {
                        ForEach(JourneyStepKind.allCases) { k in
                            GhostButton(label: k.label, icon: k.icon) { journey.steps.append(JourneyStep(kind: k)) }
                        }
                    }
                }

                // Deterministic simulation preview
                Divider().background(BLTheme.stroke)
                VStack(alignment: .leading, spacing: 8) {
                    Field(title: "Preview for a contact with tags (comma-sep)", text: $simTags, prompt: "vip, newsletter")
                    let tags = simTags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let events = JourneyEngine.simulate(journey.steps, contactTags: tags)
                    if events.isEmpty {
                        Text("No sends fire for this contact.").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    } else {
                        ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                            HStack {
                                Text("Day \(e.day)").font(BLFonts.mono(11, weight: .bold)).foregroundColor(BLTheme.gold).frame(width: 60, alignment: .leading)
                                Text(e.campaign.isEmpty ? "Send" : e.campaign).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                Spacer()
                            }
                            .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                HStack {
                    GhostButton(label: "Cancel") { dismiss() }
                    Spacer()
                    GoldButton(label: "Save journey", icon: "checkmark") { onSave(journey); dismiss() }
                }
            }
            .padding(26)
        }
        #if os(macOS)
        .frame(width: 560, height: 680)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
    }

    @ViewBuilder private func stepRow(_ s: Binding<JourneyStep>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: s.wrappedValue.kind.icon).font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.gold).frame(width: 22)
            Text(s.wrappedValue.kind.label).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).frame(width: 84, alignment: .leading)
            switch s.wrappedValue.kind {
            case .trigger:
                TextField("New lead / signup", text: s.note).textFieldStyle(.plain).font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)
            case .wait:
                Stepper(value: s.waitDays, in: 0...90) { Text("\(s.wrappedValue.waitDays) days").font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text) }
            case .send:
                Picker("", selection: s.campaignName) {
                    Text("Choose campaign").tag("")
                    ForEach(model.campaigns) { Text($0.name.isEmpty ? "Untitled" : $0.name).tag($0.name) }
                }.labelsHidden().tint(BLTheme.gold)
            case .branch:
                TextField("tag", text: s.branchTag).textFieldStyle(.plain).font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.text)
            }
            Spacer()
            IconButton(system: "trash", tint: BLTheme.danger) { journey.steps.removeAll { $0.id == s.wrappedValue.id } }
        }
        .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
    }
}

// MARK: - 4) Scheduler (calendar + best-time)

struct SchedulerScreen: View {
    @EnvironmentObject var model: AppModel
    @State private var month = Date()
    @State private var showLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Scheduler",
                             subtitle: "See your scheduled posts on a calendar and your best time to post — computed from your own logged engagement.")

                bestTimePanel

                Panel(title: monthTitle, icon: "calendar") {
                    VStack(spacing: 10) {
                        HStack {
                            IconButton(system: "chevron.left") { month = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month }
                            Spacer()
                            Text(monthTitle).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Spacer()
                            IconButton(system: "chevron.right") { month = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month }
                        }
                        calendarGrid
                    }
                }
            }
            .padding(28)
        }
        .sheet(isPresented: $showLog) { LogEngagementSheet().environmentObject(model).sheetCloseBar() }
    }

    private var monthTitle: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f.string(from: month)
    }

    private var bestTimePanel: some View {
        Panel(title: "Best time to post", icon: "clock.badge.checkmark") {
            VStack(alignment: .leading, spacing: 10) {
                if let best = BestTimeEngine.best(model.postStats) {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(BestTimeEngine.weekdayName(best.weekday)) · \(BestTimeEngine.hourLabel(best.hour))")
                                .font(BLFonts.mono(22, weight: .heavy)).foregroundStyle(BLTheme.goldText)
                            Text("\(best.total) total engagement logged in this slot").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                        Spacer()
                    }
                    let top = BestTimeEngine.topHours(model.postStats, n: 3)
                    if !top.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(Array(top.enumerated()), id: \.offset) { _, t in
                                VStack(spacing: 1) {
                                    Text(BestTimeEngine.hourLabel(t.hour)).font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Text("\(t.total)").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.gold)
                                }
                                .padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                            }
                        }
                    }
                } else {
                    Text("No engagement logged yet. Log the real engagement of past posts to compute your best time — we never guess a default.")
                        .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
                GhostButton(label: "Log post engagement", icon: "plus.circle") { showLog = true }
            }
        }
    }

    private var calendarGrid: some View {
        let byDay = SchedulerCalendar.postsByDay(model.posts, month: month)
        let blanks = SchedulerCalendar.leadingBlankCount(month: month)
        let days = SchedulerCalendar.daysInMonth(month)
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return VStack(spacing: 6) {
            HStack { ForEach(Array(["S","M","T","W","T","F","S"].enumerated()), id: \.offset) { _, d in
                Text(d).font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).frame(maxWidth: .infinity) } }
            LazyVGrid(columns: cols, spacing: 6) {
                // Prefix blank identities so they can never collide with day numbers in the sibling
                // ForEach (the July 1/2 cells disappeared when blank 1/2 shared those identities).
                ForEach((0..<blanks).map { "blank-\($0)" }, id: \.self) { _ in Color.clear.frame(height: 56) }
                ForEach(1...days, id: \.self) { d in
                    let posts = byDay[d] ?? []
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(d)").font(BLFonts.mono(10, weight: .bold)).foregroundColor(posts.isEmpty ? BLTheme.sub : BLTheme.gold)
                        ForEach(posts.prefix(2)) { p in
                            Text(p.channel).font(.system(size: 7.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.inkOnGold)
                                .padding(.vertical, 1).padding(.horizontal, 4).background(BLTheme.goldGrad).clipShape(Capsule()).lineLimit(1)
                        }
                        if posts.count > 2 { Text("+\(posts.count - 2)").font(.system(size: 7.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub) }
                    }
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
                    .padding(5).background(posts.isEmpty ? BLTheme.bg2 : BLTheme.gold.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(posts.isEmpty ? BLTheme.stroke : BLTheme.gold.opacity(0.3), lineWidth: 1))
                }
            }
        }
    }
}

struct LogEngagementSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var date = Date()
    @State private var hour = 12
    @State private var engagement = 0
    @State private var channel = "Instagram"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Log post engagement").font(BLFonts.display(22, weight: .medium)).foregroundColor(BLTheme.text)
            Text("Enter the real engagement (likes + comments + shares) you observed on a past post. This is the only source for your best-time calculation.")
                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            DatePicker("Posted on", selection: $date, displayedComponents: .date).tint(BLTheme.gold).foregroundColor(BLTheme.text)
            Stepper(value: $hour, in: 0...23) { Text("Hour: \(BestTimeEngine.hourLabel(hour))").foregroundColor(BLTheme.text) }
            VStack(alignment: .leading, spacing: 5) {
                Text("ENGAGEMENT").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextField("0", value: $engagement, format: .number).textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
                    .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            }
            Picker("Channel", selection: $channel) { ForEach(MarketingChannel.allCases) { Text($0.rawValue).tag($0.rawValue) } }.tint(BLTheme.gold)
            HStack {
                GhostButton(label: "Cancel") { dismiss() }
                Spacer()
                GoldButton(label: "Log", icon: "checkmark") {
                    let wd = Calendar.current.component(.weekday, from: date)
                    model.logEngagement(PostEngagement(weekday: wd, hour: hour, engagement: max(0, engagement), channel: channel))
                    dismiss()
                }
            }
        }
        .padding(26)
        #if os(macOS)
        .frame(width: 440)
        #else
        .frame(maxWidth: .infinity)
        #endif
        .background(BLTheme.bg)
    }
}

// MARK: - 5) Influencers (CRM + fit)

struct InfluencerScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var editing: Influencer? = nil
    @State private var targetNiche = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Influencers",
                             subtitle: "A CRM for creator partnerships. Add influencers with the real numbers you find and track outreach.")

                Panel(title: "Fit target", icon: "scope") {
                    Field(title: "Your target niche", text: $targetNiche, prompt: prefs.defaultVertical.isEmpty ? "food, fitness, home services…" : prefs.defaultVertical)
                }

                HStack {
                    Text("Your list").font(BLFonts.display(20, weight: .medium)).foregroundColor(BLTheme.text)
                    Spacer()
                    GoldButton(label: "Add influencer", icon: "plus") { editing = Influencer() }
                }

                if model.influencers.isEmpty {
                    EmptyState(icon: "star.circle", title: "No influencers yet",
                               hint: "Add creators you're considering. Enter their real follower count and engagement — the app never invents numbers.")
                        .frame(maxWidth: .infinity)
                } else {
                    let niche = targetNiche.isEmpty ? prefs.defaultVertical : targetNiche
                    ForEach(model.influencers.sorted { InfluencerEngine.fit($0, targetNiche: niche) > InfluencerEngine.fit($1, targetNiche: niche) }) { inf in
                        infCard(inf, niche: niche)
                    }
                }
            }
            .padding(28)
        }
        .sheet(item: $editing) { i in InfluencerEditor(influencer: i) { model.upsertInfluencer($0) }.sheetCloseBar() }
    }

    @ViewBuilder private func infCard(_ i: Influencer, niche: String) -> some View {
        let fit = InfluencerEngine.fit(i, targetNiche: niche)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(i.handle.isEmpty ? "Unnamed" : i.handle).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("\(i.platform) · \(i.niche.isEmpty ? "—" : i.niche)").font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                StatusPill(text: i.status, tint: BLTheme.gold)
                VStack(spacing: 0) {
                    Text("\(fit)").font(BLFonts.mono(18, weight: .heavy)).foregroundColor(fit >= 60 ? BLTheme.green : BLTheme.gold)
                    Text("FIT").font(.system(size: 7.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                IconButton(system: "pencil") { editing = i }
                IconButton(system: "trash", tint: BLTheme.danger) { model.deleteInfluencer(i) }
            }
            HStack(spacing: 18) {
                miniM("Followers", i.followers > 0 ? abbrev(i.followers) : "—")
                miniM("Engagement", i.engagementRatePct > 0 ? String(format: "%.1f%%", i.engagementRatePct) : "—")
                if !i.email.isEmpty { miniM("Email", i.email) }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassBackground(radius: 14, sweep: false))
    }
    private func miniM(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text(l.uppercased()).font(.system(size: 8, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.5)
        }
    }
    private func abbrev(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n)/1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n)/1_000) }
        return "\(n)"
    }
}

struct InfluencerEditor: View {
    @State var influencer: Influencer
    var onSave: (Influencer) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                Text(influencer.handle.isEmpty ? "Add influencer" : "Edit").font(BLFonts.display(22, weight: .medium)).foregroundColor(BLTheme.text)
                Field(title: "Handle", text: $influencer.handle, prompt: "@creator")
                HStack(spacing: 12) {
                    Field(title: "Platform", text: $influencer.platform, prompt: "Instagram")
                    Field(title: "Niche", text: $influencer.niche, prompt: "food")
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("FOLLOWERS").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                        TextField("0", value: $influencer.followers, format: .number).textFieldStyle(.plain)
                            .font(.system(size: 14, design: .rounded)).foregroundColor(BLTheme.text)
                            .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("ENGAGEMENT %").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                        TextField("0", value: $influencer.engagementRatePct, format: .number).textFieldStyle(.plain)
                            .font(.system(size: 14, design: .rounded)).foregroundColor(BLTheme.text)
                            .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                }
                Field(title: "Email", text: $influencer.email, prompt: "creator@example.com")
                VStack(alignment: .leading, spacing: 5) {
                    Text("STATUS").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    Picker("", selection: $influencer.status) { ForEach(InfluencerEngine.statuses, id: \.self) { Text($0).tag($0) } }.labelsHidden().tint(BLTheme.gold)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("NOTES").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    TextEditor(text: $influencer.notes).font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                        .scrollContentBackground(.hidden).frame(minHeight: 70).padding(8).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Text("Enter only numbers you've verified yourself. Unknown values stay 0 and contribute nothing to the fit score.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                HStack {
                    GhostButton(label: "Cancel") { dismiss() }
                    Spacer()
                    GoldButton(label: "Save", icon: "checkmark") { onSave(influencer); dismiss() }
                }
            }
            .padding(26)
        }
        #if os(macOS)
        .frame(width: 500, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
    }
}
#endif // circuit-convert
