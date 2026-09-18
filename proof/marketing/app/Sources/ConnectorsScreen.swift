#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — the UNIFIED Connectors screen.
//
// Founder directive: "connectors should all be in one place." This is that one place — every login /
// integration in the app is reachable and status-chipped here:
//   • App account & sign-in (Google client ID; Apple gate note)
//   • Lead Database subscription key
//   • Mailboxes — SMTP send (add/edit/remove + real "Test connection")
//   • Inbox — IMAP reply detection (+ real "Test connection")
//   • Social accounts — real OAuth Connect for every network (shared ConnectSheet)
//   • Newsletters via Cloudflare (endpoint + from + secret + auto-send)
//   • CRM / Telephony / Enrichment / Analytics — honest "works" or "not yet available" states
//
// Every field ships EMPTY (ship-no-data). Secrets (SMTP/IMAP passwords, the CF token) live only in
// the data-protection Keychain. Each connector shows a live Connected / Off / Error chip derived by
// the pure ConnectorStatusEngine so a chip can never overclaim.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

struct ConnectorsScreen: View {
    private enum ConnectorGroup: String, CaseIterable, Identifiable {
        case all = "All"
        case email = "Email"
        case social = "Social"
        case data = "Data & CRM"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var leadEngine: LeadEngineStore
    @EnvironmentObject var session: Session

    // Account / keys (UserDefaults-backed, same keys the rest of the app reads).
    @State private var googleClientID = UserDefaults.standard.string(forKey: GoogleAuth.clientIDDefaultsKey) ?? ""
    @State private var leadDBToken = LeadDBCredential.token
    /// Recorded transmission-consent grants, keyed by provider id. Re-read whenever the panel
    /// appears so a withdrawal made elsewhere is never shown as still granted.
    @State private var consentGrants: [String: TransmissionConsentRecord] = [:]
    @State private var leadDBValidation: LeadDBTokenValidation? = nil
    @State private var leadDBTesting = false

    // Real Google OAuth sign-in (the connection = a completed OAuth + validated userinfo, not a saved id).
    @State private var googleSignedInEmail = UserDefaults.standard.string(forKey: "GoogleSignedInEmail") ?? ""
    @State private var googleSigningIn = false

    // Provider-API email (Gmail API / Microsoft Graph) — real OAuth send path alongside SMTP.
    @State private var gmailClientID = UserDefaults.standard.string(forKey: EmailAPIProvider.gmail.clientIDDefaultsKey) ?? ""
    @State private var msClientID = UserDefaults.standard.string(forKey: EmailAPIProvider.microsoft.clientIDDefaultsKey) ?? ""
    @State private var connectingProvider: EmailAPIProvider? = nil
    @State private var emailAPINote: [String: String] = [:]
    @State private var emailAPICallOK: [String: Bool] = [:]

    // Mailbox editing.
    @State private var editingMailbox: Mailbox? = nil
    @State private var editingIsPrimary = false
    @State private var mailboxTest: [UUID: String] = [:]
    @State private var testing: Set<UUID> = []
    // The ONLY source of a green "Connected" mailbox chip: true only after a real SMTP probe succeeded,
    // false after a failed/timed-out probe, absent (nil) until a probe runs or after credentials change.
    @State private var mailboxProbeOK: [UUID: Bool] = [:]

    // IMAP.
    @State private var imapTest = ""
    @State private var imapTesting = false
    @State private var imapProbeOK: Bool? = ConnectorVerificationStore.verdict(ConnectorVerificationStore.imap)

    // Social.
    @State private var connectingSocial: SocialPlatform? = nil

    // Cloudflare newsletter.
    @State private var cfEndpoint = CloudflareEmailConfig.endpoint
    @State private var cfFromEmail = CloudflareEmailConfig.fromEmail
    @State private var cfFromName = CloudflareEmailConfig.fromName
    @State private var cfToken = ""
    @State private var cfAutoSend = CloudflareEmailConfig.autoSend
    @State private var cfHasToken = CloudflareEmailConfig.hasToken
    @State private var cfNote = ""

    // Cloudflare Analytics (real GraphQL pull).
    @State private var cfaAccount = CloudflareAnalyticsConfig.accountID
    @State private var cfaZone = CloudflareAnalyticsConfig.zone
    @State private var cfaSiteTag = CloudflareAnalyticsConfig.siteTag
    @State private var cfaToken = ""
    @State private var cfaHasToken = CloudflareAnalyticsConfig.hasToken
    @State private var cfaResult: CFAnalyticsResult? = CloudflareAnalyticsConfig.lastResult
    @State private var cfaTesting = false
    @State private var cfaNote = ""

    // CRM sync (Salesforce / HubSpot / Pipedrive real push).
    @State private var crmLoaded = false
    @State private var crmProvider: CRMProvider = .none
    @State private var crmInstanceURL = ""
    @State private var crmToken = ""
    @State private var crmHasToken = false
    @State private var crmTesting = false
    @State private var crmNote = ""
    // CRM two-way sync — pull (remote → local, never-destructive merge).
    @State private var crmPulling = false
    @State private var crmPullProgress = ""
    @State private var crmPullPreview: CRMPullPreviewModel? = nil

    // Enrichment (BYO Hunter/Apollo email-finder)
    @State private var enrichLoaded = false
    @State private var enrichProvider: EnrichmentProvider = .none
    @State private var enrichKey = ""
    @State private var enrichHasKey = false
    @State private var enrichNote = ""

    // Sendblue messaging (BYO iMessage / RCS / SMS line). Ships empty — see Sendblue.swift.
    @State private var sbKeyID = ""
    @State private var sbSecret = ""
    @State private var sbFromNumber = SendblueConfig.fromNumber
    @State private var sbDailyCap = String(SendblueConfig.dailyLineCap == 0 ? "" : "\(SendblueConfig.dailyLineCap)")
    @State private var sbHasCredential = SendblueConfig.hasCredential
    @State private var sbTesting = false
    @State private var sbNote = ""

    // The shipped guide being read IN the app (GuideReaderView) — never handed to an external editor.
    @State private var readingGuide: BundledGuides.Guide? = nil

    @State private var toast = ""
    @State private var repairingSavedCredentials = false
    @State private var savedCredentialRepairNote = ""
    @State private var selectedGroup: ConnectorGroup = .all

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Connectors",
                             subtitle: "Every sign-in and integration in one place — your account, mailboxes, social, newsletters, and data sources. Every integration runs on your own provider accounts, and nothing is transmitted to any of them until you allow it under Data sharing.")

                #if os(macOS)
                if !toast.isEmpty {
                    Text(toast).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green)
                }
                #endif

                savedCredentialReconnectPanel
                dataSharingPanel
                #if os(macOS)
                // Mac-only surfaces. The MCP server ships in the macOS bundle and needs a local
                // Node runtime — on iOS the panel could only ever render a false error state.
                // The bundled guides document the macOS product (Trash uninstall, zip install,
                // macOS permissions) and are not in the iOS bundle — dead Open buttons and
                // wrong-platform instructions are both worse than no panel.
                claudeMCPPanel
                guidesPanel
                #endif
                connectionCenterPanel
                if selectedGroup == .all || selectedGroup == .email {
                    mailboxesPanel
                    emailAPIPanel
                    imapPanel
                    cloudflarePanel
                    sendbluePanel
                }
                if selectedGroup == .all || selectedGroup == .social {
                    socialPanel
                }
                if selectedGroup == .all || selectedGroup == .data {
                    // b25: back on iOS — the same access is purchasable in-app (StoreKit 2),
                    // making the key path a legal 3.1.3(b) multiplatform unlock.
                    leadDBPanel
                    otherConnectorsPanel
                }
                if selectedGroup == .all {
                    accountPanel
                }
            }
            .padding(28)
        }
        .sheet(item: $editingMailbox) { mb in
            MailboxEditorSheet(mailbox: mb, isPrimary: editingIsPrimary,
                               onSave: saveMailbox, onDelete: editingIsPrimary ? nil : { deleteMailbox(mb) })
                .sheetCloseBar()
        }
        .sheet(item: $connectingSocial) { p in
            ConnectSheet(platform: p) {
                ConnectorVerificationStore.clear(ConnectorVerificationStore.social(p.rawValue))
                model.refreshSocialCredentialFlags()
                flash("\(p.rawValue) linked. Publish once to verify the connection.")
            }
                .environmentObject(model).sheetCloseBar()
        }
        .sheet(item: $crmPullPreview) { preview in
            CRMPullPreviewSheet(plan: preview.plan) { applyCRMPullPlan(preview.plan) }
                .sheetCloseBar()
        }
        .sheet(item: $readingGuide) { guide in
            GuideReaderView(guide: guide).sheetCloseBar()
        }
        #if os(iOS)
        // The screen is long: a message inline at the top of the scroll content sits above the
        // viewport whenever the buyer acts on a lower panel, so success AND failure feedback
        // vanished unseen. Pin it to the visible screen instead.
        .overlay(alignment: .bottom) {
            if !toast.isEmpty {
                Text(toast)
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 10).padding(.horizontal, 14)
                    .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(BLTheme.stroke, lineWidth: 1))
                    .padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        #endif
        .onAppear {
            model.refreshSocialCredentialFlags()
            loadCRMStateIfNeeded()
            loadEnrichmentStateIfNeeded()
            validateSavedLeadDBToken()
        }
        .onReceive(NotificationCenter.default.publisher(for: CRMAutoPull.foregroundNotification)) { _ in
            // Auto-pull on app foreground (buyer opt-in; throttled + demo-safe inside).
            CRMAutoPull.pullIfEnabled(model: model, leadEngine: leadEngine)
        }
    }

    // MARK: chip helper
    @ViewBuilder private func chip(_ state: ConnectorState) -> some View {
        let tint: Color = {
            switch state {
            case .connected: return BLTheme.green
            case .off: return BLTheme.sub
            case .error: return BLTheme.danger
            case .unavailable: return BLTheme.gold
            case .testing: return BLTheme.gold        // a probe is in flight — amber, not green
            case .unverified: return BLTheme.sub       // configured but never verified — neutral, never green
            }
        }()
        StatusPill(text: state.chip, tint: tint)
    }

    private func flash(_ m: String) {
        toast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if toast == m { toast = "" } }
    }

    // MARK: - foreground reconnect-all for saved-but-unreadable Keychain items
    private var savedCredentialReconnectAccounts: [String] {
        let s = leadEngine.settings
        var seen = Set<String>()
        var out: [String] = []
        func add(_ raw: String) {
            let account = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !account.isEmpty,
                  SendKeychain.hasSavedPasswordItem(account: account),
                  !SendKeychain.hasReadablePassword(account: account),
                  seen.insert(account.lowercased()).inserted else { return }
            out.append(account)
        }
        for mailbox in [s.mailbox] + s.extraMailboxes where !mailbox.usesProviderAPI {
            add(mailbox.username)
        }
        if s.imapEnabled {
            add(s.imapUsername)
        }
        return out
    }

    private func configuredSMTPMailboxesNeedingHumanPassword(_ mailboxes: [Mailbox]) -> [Mailbox] {
        mailboxes.filter { mailbox in
            guard !mailbox.usesProviderAPI else { return false }
            let hasAddress = !mailbox.fromEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasUser = !mailbox.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (hasAddress || hasUser) && !mailboxReady(mailbox)
        }
    }

    private var imapNeedsHumanPassword: Bool {
        let s = leadEngine.settings
        let user = s.imapUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = s.imapHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.imapEnabled && !host.isEmpty && !user.isEmpty && !SendKeychain.hasReadablePassword(account: user)
    }

    private func credentialGateDetail(smtpNeedingPassword: [Mailbox],
                                      imapNeedsPassword: Bool,
                                      savedAccounts: [String],
                                      needsNewsletter: Bool,
                                      needsAnalytics: Bool) -> String {
        var parts: [String] = []
        if !savedAccounts.isEmpty || needsNewsletter || needsAnalytics {
            parts.append(reconnectSummary(accounts: savedAccounts, needsNewsletter: needsNewsletter, needsAnalytics: needsAnalytics))
        }
        if !smtpNeedingPassword.isEmpty {
            parts.append("\(smtpNeedingPassword.count) SMTP mailbox password\(smtpNeedingPassword.count == 1 ? "" : "s") need reconnect or re-entry")
        }
        if imapNeedsPassword {
            parts.append("IMAP password needs reconnect or re-entry")
        }
        return parts.isEmpty
            ? "No SMTP, IMAP, or Cloudflare secrets need a foreground account action."
            : parts.joined(separator: " + ")
    }

    private func startCredentialGateAction(smtpNeedingPassword: [Mailbox],
                                           imapNeedsPassword: Bool,
                                           needsSavedCredentialReconnect: Bool) {
        if needsSavedCredentialReconnect {
            reconnectAllSavedCredentials()
            return
        }
        if let mailbox = smtpNeedingPassword.first {
            editingIsPrimary = mailbox.id == leadEngine.settings.mailbox.id
            editingMailbox = mailbox
            return
        }
        if imapNeedsPassword {
            imapTest = "Paste the IMAP app password below, then Test connection."
        }
    }

    // MARK: - Data sharing (explicit per-provider transmission consent)
    //
    // The gate in Sources/ProviderConsent.swift refuses every outbound call to a provider that has
    // no current grant. This panel is the ONLY place a grant can be made: the buyer reads the exact
    // hostnames and the exact fields that leave this device, then allows or withdraws, per provider.
    // Nothing here is pre-checked and nothing grants itself as a side effect of saving a key.
    @ViewBuilder private var dataSharingPanel: some View {
        Panel(title: "Data sharing", icon: "hand.raised.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("This app sends nothing to anyone until you say so, per service. Read what leaves this Mac, then allow the ones you want to use. Withdraw any of them at any time and the next send is refused — not queued, not silently dropped.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(TransmissionProvider.allCases) { provider in
                    let granted = consentGrants[provider.rawValue] != nil
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(provider.displayName)
                                .font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            StatusPill(text: granted ? "Allowed" : "Not allowed",
                                       tint: granted ? BLTheme.green : BLTheme.sub)
                            Spacer()
                            GhostButton(label: granted ? "Withdraw" : "Allow",
                                        icon: granted ? "xmark.circle" : "checkmark.seal",
                                        tint: granted ? BLTheme.danger : BLTheme.gold) {
                                if granted { TransmissionConsentStore.withdraw(provider) }
                                else { TransmissionConsentStore.grant(provider) }
                                consentGrants = TransmissionConsentStore.all()
                                flash(granted
                                      ? "\(provider.displayName) can no longer receive your data."
                                      : "\(provider.displayName) may now receive the data listed above.")
                            }
                        }
                        Text(provider.whatLeaves)
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Sent to: " + provider.hosts.joined(separator: ", ")
                             + (provider.isFirstParty ? " (operated by Black Label)" : ""))
                            .font(BLFonts.mono(10, weight: .medium)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        .onAppear { consentGrants = TransmissionConsentStore.all() }
    }

    @ViewBuilder private var savedCredentialReconnectPanel: some View {
        let accounts = savedCredentialReconnectAccounts
        let needsNewsletter = CloudflareEmailConfig.tokenNeedsReconnect
        let needsAnalytics = CloudflareAnalyticsConfig.tokenNeedsReconnect
        if !accounts.isEmpty || needsNewsletter || needsAnalytics {
            Panel(title: "Reconnect saved credentials", icon: "key.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "key.fill").foregroundColor(BLTheme.gold)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("One deliberate recovery moves these legacy Keychain secrets into Marketing's private on-device store. macOS may confirm each legacy entry; after recovery, normal launches never ask Keychain for them again.")
                                .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Text(reconnectSummary(accounts: accounts, needsNewsletter: needsNewsletter, needsAnalytics: needsAnalytics))
                                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        GoldButton(label: repairingSavedCredentials ? "Reconnecting..." : "Reconnect all saved credentials",
                                   icon: "key.fill") {
                            reconnectAllSavedCredentials()
                        }
                        .disabled(repairingSavedCredentials)
                    }
                    if !savedCredentialRepairNote.isEmpty {
                        Text(savedCredentialRepairNote)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(savedCredentialRepairNote.hasPrefix("✓") ? BLTheme.green : BLTheme.gold)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func reconnectSummary(accounts: [String], needsNewsletter: Bool, needsAnalytics: Bool) -> String {
        var parts: [String] = []
        if !accounts.isEmpty {
            parts.append("\(accounts.count) SMTP/IMAP password\(accounts.count == 1 ? "" : "s")")
        }
        if needsNewsletter { parts.append("Cloudflare newsletter secret") }
        if needsAnalytics { parts.append("Cloudflare Analytics token") }
        return parts.joined(separator: " + ")
    }

    private func reconnectAllSavedCredentials() {
        guard !repairingSavedCredentials else { return }
        repairingSavedCredentials = true
        savedCredentialRepairNote = "Reconnecting saved credentials..."

        let accounts = savedCredentialReconnectAccounts
        let needsNewsletter = CloudflareEmailConfig.tokenNeedsReconnect
        let needsAnalytics = CloudflareAnalyticsConfig.tokenNeedsReconnect
        guard !accounts.isEmpty || needsNewsletter || needsAnalytics else {
            savedCredentialRepairNote = "No saved credentials need reconnect."
            repairingSavedCredentials = false
            return
        }

        Task {
            var reconnected: [String] = []
            var stillBlocked: [String] = []
            var passwordAccounts = Set<String>()
            for account in accounts {
                if await runSelfMigration(["--migrate-mail-password", account]) {
                    reconnected.append(account)
                    passwordAccounts.insert(account.lowercased())
                } else {
                    stillBlocked.append(account)
                }
            }

            if needsNewsletter {
                if await runSelfMigration(["--migrate-cloudflare-newsletter"], timeout: 30) {
                    reconnected.append("Cloudflare newsletter")
                } else {
                    stillBlocked.append("Cloudflare newsletter")
                }
            }
            if needsAnalytics {
                if await runSelfMigration(["--migrate-cloudflare-analytics"], timeout: 60) {
                    reconnected.append("Cloudflare Analytics")
                } else {
                    stillBlocked.append("Cloudflare Analytics")
                }
            }

            await MainActor.run {
                if !passwordAccounts.isEmpty {
                    var settings = leadEngine.settings
                    if passwordAccounts.contains(settings.mailbox.username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                        settings.mailbox.hasPassword = true
                    }
                    for i in settings.extraMailboxes.indices {
                        let account = settings.extraMailboxes[i].username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        if passwordAccounts.contains(account) {
                            settings.extraMailboxes[i].hasPassword = true
                        }
                    }
                    leadEngine.settings = settings
                }
                cfHasToken = CloudflareEmailConfig.hasToken
                cfaHasToken = CloudflareAnalyticsConfig.hasToken
                repairingSavedCredentials = false
                if stillBlocked.isEmpty {
                    savedCredentialRepairNote = "✓ Reconnected \(reconnected.count) saved credential\(reconnected.count == 1 ? "" : "s"). Run the tests below to verify the live accounts."
                    flash("Saved credentials reconnected.")
                } else if reconnected.isEmpty {
                    savedCredentialRepairNote = "macOS did not grant access. Re-enter these secrets once: \(stillBlocked.joined(separator: ", "))."
                } else {
                    savedCredentialRepairNote = "Reconnected \(reconnected.count); still needs approval or re-entry: \(stillBlocked.joined(separator: ", "))."
                    flash("Some saved credentials reconnected.")
                }
            }
        }
    }

    private func runSelfMigration(_ arguments: [String], timeout: TimeInterval = 20) async -> Bool {
        #if os(macOS)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let executableURL = Bundle.main.executableURL else {
                    continuation.resume(returning: false)
                    return
                }
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                let output = Pipe()
                process.standardOutput = output
                process.standardError = output
                let finished = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in finished.signal() }
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: false)
                    return
                }
                if finished.wait(timeout: .now() + timeout) == .timedOut {
                    process.terminate()
                    _ = finished.wait(timeout: .now() + 2)
                    continuation.resume(returning: false)
                    return
                }
                continuation.resume(returning: process.terminationStatus == 0)
            }
        }
        #else
        return false
        #endif
    }

    // MARK: - Buffer-style connection center
    private var connectionCenterPanel: some View {
        let savedAccounts = savedCredentialReconnectAccounts
        let needsNewsletterReconnect = CloudflareEmailConfig.tokenNeedsReconnect
        let needsAnalyticsReconnect = CloudflareAnalyticsConfig.tokenNeedsReconnect
        let needsSavedCredentialReconnect = !savedAccounts.isEmpty || needsNewsletterReconnect || needsAnalyticsReconnect

        let mailboxes = [leadEngine.settings.mailbox] + leadEngine.settings.extraMailboxes
        let smtpMailboxes = mailboxes.filter { !$0.usesProviderAPI && (!$0.fromEmail.trimmingCharacters(in: .whitespaces).isEmpty || !$0.username.trimmingCharacters(in: .whitespaces).isEmpty) }
        let smtpReady = smtpMailboxes.filter { ConnectorVerificationStore.verdict(ConnectorVerificationStore.smtp($0.id)) == true }.count
        let smtpFailed = smtpMailboxes.contains { ConnectorVerificationStore.verdict(ConnectorVerificationStore.smtp($0.id)) == false }
        let smtpNeedingPassword = configuredSMTPMailboxesNeedingHumanPassword(smtpMailboxes)
        let imapNeedsPassword = imapNeedsHumanPassword
        let needsCredentialAction = needsSavedCredentialReconnect || !smtpNeedingPassword.isEmpty || imapNeedsPassword
        let gmailAddress = connectedAPIAddress(for: .gmail)
        let microsoftAddress = connectedAPIAddress(for: .microsoft)
        let gmailOK = gmailAddress.flatMap { ConnectorVerificationStore.verdict(ConnectorVerificationStore.emailAPI(EmailAPIProvider.gmail.rawValue, address: $0)) }
        let microsoftOK = microsoftAddress.flatMap { ConnectorVerificationStore.verdict(ConnectorVerificationStore.emailAPI(EmailAPIProvider.microsoft.rawValue, address: $0)) }
        let apiConfigured = gmailAddress != nil || microsoftAddress != nil
        let emailVerified = smtpReady + (gmailOK == true ? 1 : 0) + (microsoftOK == true ? 1 : 0)
        let emailConfigured = smtpMailboxes.count + (gmailAddress == nil ? 0 : 1) + (microsoftAddress == nil ? 0 : 1)
        let emailFailed = smtpFailed || gmailOK == false || microsoftOK == false
        let socialTokenPlatforms = SocialPlatform.allCases.filter { model.profile(for: $0).map { SocialCredentialStore.hasToken(for: $0.platform) } == true }
        // "Ready" counts a network only when its credential is KNOWN live (expiry still ahead of now)
        // AND a real provider call succeeded. An expired credential counts as a failure, not as a
        // neutral gap — the group summary must not stay green while a member is dead.
        let socialReady = socialTokenPlatforms.filter {
            ConnectorVerificationStore.verdict(ConnectorVerificationStore.social($0.rawValue)) == true
                && model.profile(for: $0)?.liveness().isKnownLive == true
        }.count
        let socialFailed = socialTokenPlatforms.contains {
            ConnectorVerificationStore.verdict(ConnectorVerificationStore.social($0.rawValue)) == false
                || model.profile(for: $0)?.liveness().isKnownDead == true
        }
        let crmState = ConnectorStatusEngine.crm(isConnected: leadEngine.settings.crmConnector.isConnected,
                                                 providerSelected: leadEngine.settings.crmConnector.provider != .none)
        let enrichmentVendor = leadEngine.settings.enrichment.provider.finderVendor
        let enrichmentOK = enrichmentVendor.flatMap { ConnectorVerificationStore.verdict(ConnectorVerificationStore.enrichment($0.rawValue)) }
        // A cached analytics result is useful history, but it is not a current connection after the
        // account/token/zone has been removed. Keep the group summary aligned with the detailed chip.
        let analyticsVerified = CloudflareAnalyticsConfig.isConfigured && cfaResult?.ok == true
        let analyticsFailed = CloudflareAnalyticsConfig.isConfigured && cfaResult?.ok == false
        let dataVerified = leadDBValidation?.valid == true || analyticsVerified || crmState == .connected || enrichmentOK == true
        let dataFailed = leadDBValidation?.valid == false || analyticsFailed || crmState == .error || enrichmentOK == false
        let dataConfigured = !leadDBToken.isEmpty || CloudflareAnalyticsConfig.isConfigured || leadEngine.settings.crmConnector.provider != .none || enrichmentVendor != nil

        let emailState: ConnectorState = emailFailed || needsCredentialAction ? .error : (emailVerified > 0 ? .connected : (emailConfigured > 0 || apiConfigured ? .unverified : .off))
        let socialState: ConnectorState = socialFailed ? .error : (socialReady > 0 ? .connected : (socialTokenPlatforms.isEmpty ? .off : .unverified))
        let dataState: ConnectorState = dataFailed ? .error : (dataVerified ? .connected : (dataConfigured ? .unverified : .off))

        return Panel(title: "Connections", icon: "link.circle.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect only the channels you use. Saved settings stay neutral until a real provider check succeeds; every connection has one clear next step.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Picker("Connector group", selection: $selectedGroup) {
                    ForEach(ConnectorGroup.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                readinessRow(icon: "paperplane.fill",
                             title: "Email",
                             detail: emailConfigured == 0 ? "Add a sending mailbox; reply detection and Cloudflare routing are optional." : "\(emailVerified) of \(emailConfigured) sending connections verified in the last 7 days.",
                             state: emailState,
                             buttonLabel: "Manage",
                             buttonIcon: "arrow.right.circle") {
                    selectedGroup = .email
                }

                readinessRow(icon: "antenna.radiowaves.left.and.right",
                             title: "Social channels",
                             detail: socialTokenPlatforms.isEmpty ? "Link the channels you publish to; profile-only links remain clearly labeled." : "\(socialReady) of \(socialTokenPlatforms.count) publishing connections verified by a live provider call.",
                             state: socialState,
                             buttonLabel: "Manage",
                             buttonIcon: "arrow.right.circle") {
                    selectedGroup = .social
                }

                readinessRow(icon: "chart.bar.xaxis",
                             title: "Data & CRM",
                             detail: "Lead Database, CRM, enrichment, and analytics are optional. Each stays neutral until its live test passes.",
                             state: dataState,
                             buttonLabel: "Manage",
                             buttonIcon: "arrow.right.circle") {
                    selectedGroup = .data
                }

                if needsCredentialAction {
                    readinessRow(icon: "key.fill",
                                 title: "Reconnect saved credentials",
                                 detail: credentialGateDetail(smtpNeedingPassword: smtpNeedingPassword,
                                                              imapNeedsPassword: imapNeedsPassword,
                                                              savedAccounts: savedAccounts,
                                                              needsNewsletter: needsNewsletterReconnect,
                                                              needsAnalytics: needsAnalyticsReconnect),
                                 state: .error,
                                 buttonLabel: needsSavedCredentialReconnect ? "Reconnect all" : "Review",
                                 buttonIcon: "key.fill",
                                 disabled: repairingSavedCredentials) {
                        startCredentialGateAction(smtpNeedingPassword: smtpNeedingPassword,
                                                  imapNeedsPassword: imapNeedsPassword,
                                                  needsSavedCredentialReconnect: needsSavedCredentialReconnect)
                    }
                }
            }
        }
    }

    private func emailLaunchState(smtpReady: Int, smtpTotal: Int, gmailAddress: String?, microsoftAddress: String?) -> ConnectorState {
        if smtpReady > 0 || gmailAddress != nil || microsoftAddress != nil { return .connected }
        return smtpTotal > 0 ? .error : .off
    }

    private func emailLaunchButtonLabel(gmailAddress: String?, microsoftAddress: String?) -> String? {
        if gmailAddress == nil, EmailOAuth.isConfigured(.gmail) { return "Connect Gmail" }
        if microsoftAddress == nil, EmailOAuth.isConfigured(.microsoft) { return "Connect Microsoft" }
        return nil
    }

    private func startNextEmailLaunchAction(gmailAddress: String?, microsoftAddress: String?) {
        if gmailAddress == nil, EmailOAuth.isConfigured(.gmail) {
            connectEmailAPI(.gmail)
        } else if microsoftAddress == nil, EmailOAuth.isConfigured(.microsoft) {
            connectEmailAPI(.microsoft)
        }
    }

    @ViewBuilder
    private func readinessRow(icon: String,
                              title: String,
                              detail: String,
                              state: ConnectorState,
                              buttonLabel: String? = nil,
                              buttonIcon: String = "arrow.right.circle",
                              disabled: Bool = false,
                              action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(BLTheme.gold)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(BLTheme.text)
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            chip(state)
            if let buttonLabel, let action {
                GoldButton(label: buttonLabel, icon: buttonIcon) { action() }
                    .disabled(disabled)
                    .opacity(disabled ? 0.55 : 1)
            }
        }
        .padding(11)
        .background(BLTheme.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    #if os(macOS)
    // MARK: - Claude / MCP (LOCAL control surface — deliberately NOT a Data-sharing row)
    //
    // Every row in `dataSharingPanel` means "this data LEAVES this Mac, to this named host". The MCP
    // is the exact opposite: a local server that Claude connects INTO, which then drives this app's
    // own headless paths on this machine. Nothing about it transmits buyer data to Black Label or to
    // anyone else, so listing it as a transmission provider would be the first dishonest line on the
    // most honest screen in the product. It gets its own panel, and it states its own limits.
    //
    // The gating shown here is REAL and lives in the server, not in this copy: renders run local,
    // reads are read-only, and the two actions that are public/irreversible or that spend money stay
    // off unless the operator explicitly opens them.
    private var claudeMCPPanel: some View {
        Panel(title: "Claude / MCP", icon: "terminal.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Drive this app from Claude. The MCP server runs on this Mac and Claude connects to it — nothing about this connector sends your work to Black Label or to any third party. Rendering happens through the same headless path the Reel Studio button uses.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text("MCP server")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    StatusPill(text: mcpServerPresent ? "Ships inside this app" : "Not found",
                               tint: mcpServerPresent ? BLTheme.green : BLTheme.sub)
                    StatusPill(text: nodeRuntimePresent ? "Node found" : "Node not installed",
                               tint: nodeRuntimePresent ? BLTheme.green : BLTheme.danger)
                    Spacer()
                    GhostButton(label: "Copy Claude config", icon: "doc.on.doc", tint: BLTheme.gold) {
                        #if os(macOS)
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(mcpClaudeConfig, forType: .string)
                        #else
                        UIPasteboard.general.string = mcpClaudeConfig
                        #endif
                        flash("Claude config copied. Paste it into your Claude MCP settings and restart Claude.")
                    }
                }

                if !nodeRuntimePresent {
                    Text("This connector needs the free Node.js runtime (version 18 or newer) from nodejs.org — the one piece that can't ship inside the app. Everything else is already here: install Node, then copy the config above. Nothing about your workspace is affected either way.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(mcpClaudeConfig)
                    .font(BLFonts.mono(10, weight: .medium)).foregroundColor(BLTheme.sub)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))

                Text("What Claude can do through it")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)

                ForEach(mcpCapabilities, id: \.tool) { cap in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(cap.tool)
                                .font(BLFonts.mono(11, weight: .bold)).foregroundColor(BLTheme.text)
                            StatusPill(text: cap.gated ? "Gated off" : "Open",
                                       tint: cap.gated ? BLTheme.sub : BLTheme.green)
                            Spacer()
                        }
                        Text(cap.detail)
                            .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                }

                Text("Publishing and paid generation stay off unless you open them yourself. A render never contacts a provider, never reads a credential, and never queues a post.")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    #endif

    // MARK: - Guides (the documents that ship INSIDE this app — Sources/BundledGuides.swift)
    //
    // DOD-3.7: the setup guide must exist in the product, not in a repository. Every row opens the
    // bundled Markdown IN THE APP (GuideReaderView) — it used to be handed to NSWorkspace, which
    // launched whatever the Mac registered for .md (VS Code on a dev machine) and ejected the buyer
    // into a code editor. A build that genuinely lacks a guide says "not included in this build"
    // instead of silently doing nothing.
    @ViewBuilder private var guidesPanel: some View {
        Panel(title: "Guides", icon: "book.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Shipped with this app — first run, features, permissions, integrations, recovery, and uninstall. Each one opens right here: read it, search it, or save a copy.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(BundledGuides.library) { guide in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(guide.title)
                                .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Text(guide.detail)
                                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        GhostButton(label: "Read", icon: "doc.text", tint: BLTheme.gold) {
                            openBundledGuide(guide.file)
                        }
                    }
                    .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    /// Open a shipped guide in the in-app reader, or say plainly that this build doesn't carry it.
    /// The presence check happens here so a missing guide never opens an empty sheet. Nothing else
    /// changes either way — reading a guide never touches the workspace.
    private func openBundledGuide(_ file: String) {
        guard BundledGuides.url(file) != nil else {
            flash("That guide isn't included in this build. All guides are published with every release; nothing in your workspace is affected.")
            return
        }
        readingGuide = BundledGuides.entry(for: file)
    }

    #if os(macOS)
    // MCP panel helpers — macOS-only with the panel itself (homeDirectoryForCurrentUser and the
    // Node probe paths do not exist on iOS).
    /// One capability row. `gated` mirrors the server's own refusal, not a marketing adjective.
    private struct MCPCapability { let tool: String; let gated: Bool; let detail: String }

    private var mcpCapabilities: [MCPCapability] {
        [
            MCPCapability(tool: "generate_reel", gated: false,
                          detail: "Renders a reel to an .mp4 on this disk through the app's own --render-reel path, with your stills, your video clips and your music. No network call, no credential read, nothing queued."),
            MCPCapability(tool: "list_connections", gated: false,
                          detail: "Read-only. Reports which social credentials are live, judged from token expiry rather than the upstream 'publishable' flag, which can read true for a lapsed token."),
            MCPCapability(tool: "schedule_post", gated: true,
                          detail: "Publishing is public and irreversible, so it is refused by default and must be opened deliberately."),
            MCPCapability(tool: "blitz_generate", gated: true,
                          detail: "Spends one paid generation credit per successful call, with no refund. Refused unless the spend gate is set AND the call confirms the charge."),
            MCPCapability(tool: "send_message", gated: true,
                          detail: "Needs your own Sendblue credentials. Until they exist every send is marked simulated and nothing leaves this Mac."),
        ]
    }

    /// True when the MCP server file actually exists at the path the config points to. Reported
    /// honestly — a missing server is stated, never implied to be present because the panel renders.
    private var mcpServerPresent: Bool {
        FileManager.default.fileExists(atPath: mcpServerPath)
    }

    /// The server SHIPS inside this app (Contents/Resources/mcp/server.mjs), so the config never
    /// points a buyer at a developer checkout that only exists on the build machine. The checkout
    /// path survives solely as a fallback for running an unbundled build straight from the repo.
    private var mcpServerPath: String {
        if let bundled = Bundle.main.url(forResource: "server", withExtension: "mjs",
                                         subdirectory: "mcp")?.path {
            return bundled
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/BlackLabelMarketing/mcp/server.mjs"
    }

    /// Node 18+ is the ONE prerequisite that cannot ship inside the bundle. Checked honestly at
    /// the standard install locations so the card can say "install Node" BEFORE the buyer pastes
    /// a config that would silently fail in Claude. This only STATS the file — nothing here (or
    /// anywhere in Sources/) launches it, which the outbound-host registry contract enforces.
    private var nodeRuntimePresent: Bool {
        ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin"]
            .contains { FileManager.default.isExecutableFile(atPath: ($0 as NSString).appendingPathComponent("node")) }
    }

    /// The exact block to paste into Claude's MCP settings. MARKETING_APP_BINARY is pinned to the
    /// running bundle so Claude drives THIS build rather than whichever stale copy discovery finds
    /// first — a wrong binary renders with an older engine and looks like a bug in the app.
    private var mcpClaudeConfig: String {
        let binary = Bundle.main.executableURL?.path ?? "/Applications/Black Label Marketing.app/Contents/MacOS/Black Label Marketing"
        return """
        {
          "mcpServers": {
            "marketing": {
              "command": "node",
              "args": ["\(mcpServerPath)"],
              "env": { "MARKETING_APP_BINARY": "\(binary)" }
            }
          }
        }
        """
    }
    #endif

    // MARK: - 1) App account & sign-in
    private var accountPanel: some View {
        Panel(title: "App account & sign-in", icon: "person.crop.circle.fill") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundColor(BLTheme.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.email.isEmpty ? "Signed in" : session.email)
                            .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Text("Email, guest, and Apple sign-in work out of the box.")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                    Spacer()
                }
                Divider().background(BLTheme.stroke)

                // Google sign-in — the REAL connection is a completed OAuth, not a saved client id.
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "g.circle.fill").foregroundColor(BLTheme.gold)
                        Text("Google sign-in").font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                        Spacer()
                        chip(ConnectorStatusEngine.google(clientIDConfigured: GoogleAuth.isConfigured, signedIn: !googleSignedInEmail.isEmpty))
                    }
                    if !googleSignedInEmail.isEmpty {
                        Text("Signed in as \(googleSignedInEmail)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green)
                    }
                    // P1-10: end-user framing first — what it's for, that it's optional. Developer setup
                    // (the OAuth client ID) is tucked behind an Advanced disclosure so it never confronts a
                    // non-technical buyer with "paste your Google OAuth client ID" as the first thing.
                    Text("Optional. Sign in with your Google account for one-tap access instead of a password. Email, guest, and Apple sign-in already work out of the box — you don't need this unless you want to use Google.")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    // The action that actually connects: runs the real OAuth consent + a validated userinfo call.
                    HStack(spacing: 10) {
                        GoldButton(label: googleSigningIn ? "Signing in…" : (googleSignedInEmail.isEmpty ? "Sign in with Google" : "Re-authorize"),
                                   icon: "person.crop.circle.badge.checkmark") { signInWithGoogle() }
                            .disabled(googleSigningIn || !GoogleAuth.isConfigured)
                            .opacity(GoogleAuth.isConfigured ? 1 : 0.5)
                        if !googleSignedInEmail.isEmpty {
                            GhostButton(label: "Sign out", icon: "xmark.circle", tint: BLTheme.danger) { signOutGoogle() }
                        }
                    }
                    if !GoogleAuth.isConfigured {
                        Text("One-time setup needed first — open Advanced below to connect your own Google project.")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                    }
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Google requires each app to use its OWN project. Create a free OAuth client ID (Google Cloud Console → APIs & Services → Credentials → Create credentials → OAuth client ID → Application type: Desktop app), then paste it here. You authorize on Google's real consent screen; nothing is stored on our servers, and the chip turns Connected only after a live token + userinfo check. A saved client ID alone is not a connection.")
                                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                            Field(title: "Google Desktop client ID", text: $googleClientID, prompt: "xxxxxxxx.apps.googleusercontent.com")
                            HStack(spacing: 10) {
                                GoldButton(label: "Save client ID", icon: "checkmark.circle") { saveGoogleClientID() }
                                if !googleClientID.trimmingCharacters(in: .whitespaces).isEmpty {
                                    GhostButton(label: "Clear", icon: "xmark.circle", tint: BLTheme.danger) { googleClientID = ""; saveGoogleClientID() }
                                }
                                GhostButton(label: "Open console", icon: "arrow.up.right") { open("https://console.cloud.google.com/apis/credentials") }
                            }
                        }.padding(.top, 6)
                    } label: {
                        Text("Advanced — set up your own Google client ID")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
                .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))

                Text("Sign in with Apple shows on the sign-in screen and activates for real in the signed (provisioned) build of this app.")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 2) Lead Database
    // Store builds (iOS App Store AND Mac App Store) are StoreKit-only — the in-app subscription
    // is the ONLY unlock (Guideline 3.1.1: rejected b23→b25 on iOS, again on macOS build 61
    // 2026-07-27 — the axis is DISTRIBUTION, not OS). The pasted "Subscription key" surface
    // compiles ONLY in the Developer-ID / direct lane (-D DIRECT_DISTRIBUTION), where a license
    // key is permitted.
    private var leadDBPanel: some View {
        Panel(title: "Lead Database", icon: "tray.full.fill") {
            VStack(alignment: .leading, spacing: 12) {
                #if !DIRECT_DISTRIBUTION
                LeadDBSubscribeCard()
                #else
                HStack {
                    Text("Subscription key").font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Spacer()
                    chip(ConnectorStatusEngine.leadDB(
                        hasToken: !leadDBToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        testing: leadDBTesting,
                        lastValidationOK: leadDBValidation?.valid))
                }
                Text("Without a key, the Lead Database shows a masked preview. Paste your subscription key to unlock full contact details. Saves on this device only.")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                Text("Where do I get a key? Your key is emailed to you when you start a Lead Database subscription — it looks like blk_… . Paste it here to switch the preview into full, unmasked contacts. No key? You keep the masked preview; nothing is unlocked until a real key validates.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                Field(title: "Subscription key", text: $leadDBToken, prompt: "Paste your Lead Database key")
                HStack(spacing: 10) {
                    GoldButton(label: leadDBTesting ? "Validating…" : "Validate & save", icon: "checkmark.circle") { saveLeadDBToken() }
                        .disabled(leadDBTesting)
                    if !leadDBToken.trimmingCharacters(in: .whitespaces).isEmpty {
                        GhostButton(label: "Clear", icon: "xmark.circle", tint: BLTheme.danger) { leadDBToken = ""; saveLeadDBToken() }
                    }
                }
                if let validation = leadDBValidation {
                    Text(validation.detail)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(validation.valid ? BLTheme.green : BLTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                #endif
            }
        }
    }

    // MARK: - 3) Mailboxes (SMTP send)
    private var mailboxesPanel: some View {
        Panel(title: "Mailboxes — sending (SMTP)", icon: "paperplane.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your own email accounts. Every real send (sequences, journeys, spotlights) goes from a mailbox you add here over encrypted SMTP — port 465 (SSL) or port 587 (STARTTLS), whichever your provider offers. App passwords are stored only in your Mac's Keychain.")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

                mailboxRow(leadEngine.settings.mailbox, isPrimary: true)
                ForEach(leadEngine.settings.extraMailboxes) { mb in
                    mailboxRow(mb, isPrimary: false)
                }

                GhostButton(label: "Add a mailbox", icon: "plus.circle") {
                    editingIsPrimary = false
                    editingMailbox = Mailbox()
                }
            }
        }
    }

    @ViewBuilder private func mailboxRow(_ mb: Mailbox, isPrimary: Bool) -> some View {
        let account = mb.username.trimmingCharacters(in: .whitespaces)
        let savedButUnreadable = !mb.usesProviderAPI && !account.isEmpty &&
            SendKeychain.hasSavedPasswordItem(account: account) &&
            !SendKeychain.hasReadablePassword(account: account)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: "envelope.fill").foregroundColor(BLTheme.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(mb.fromEmail.isEmpty ? (isPrimary ? "Primary mailbox — not set up" : "Mailbox — not set up") : mb.fromEmail)
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(mailboxSubtitle(mb, isPrimary: isPrimary))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(mb.usesProviderAPI ? BLTheme.green : BLTheme.sub)
                }
                Spacer()
                chip(ConnectorStatusEngine.mailboxProbe(configured: mailboxReady(mb),
                                                        testing: testing.contains(mb.id),
                                                        lastProbeOK: mailboxProbeOK[mb.id] ?? ConnectorVerificationStore.verdict(ConnectorVerificationStore.smtp(mb.id))))
            }
            if let t = mailboxTest[mb.id], !t.isEmpty {
                Text(t).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(t.hasPrefix("✓") ? BLTheme.green : BLTheme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if mb.usesProviderAPI {
                    // OAuth mailbox: edit CAN-SPAM/cap details, re-authorize, or disconnect (no SMTP fields).
                    GhostButton(label: "Details", icon: "pencil") {
                        editingIsPrimary = isPrimary; editingMailbox = mb
                    }
                    GhostButton(label: "Reconnect", icon: "arrow.clockwise") {
                        if let p = mb.authKind.provider { connectEmailAPI(p) }
                    }
                    Spacer()
                    if !isPrimary {
                        IconButton(system: "trash", tint: BLTheme.danger) { disconnectAPIMailbox(mb) }
                    }
                } else {
                    GhostButton(label: mailboxReady(mb) ? "Edit" : "Set up", icon: "pencil") {
                        editingIsPrimary = isPrimary; editingMailbox = mb
                    }
                    GhostButton(label: testing.contains(mb.id) ? "Testing…" : "Test connection", icon: "bolt.horizontal") {
                        testMailbox(mb)
                    }
                    .disabled(!mailboxReady(mb) || testing.contains(mb.id))
                    .opacity(mailboxReady(mb) ? 1 : 0.5)
                    if savedButUnreadable {
                        GhostButton(label: "Reconnect saved password", icon: "key.fill", tint: BLTheme.gold) {
                            reconnectMailPassword(mb)
                        }
                    }
                    Spacer()
                    if isPrimary {
                        // P0-2: a Connected card must never be a dead end. The primary mailbox can't be
                        // deleted (it's the default sender) but its credentials can always be cleared.
                        if mailboxReady(mb) {
                            GhostButton(label: "Disconnect", icon: "xmark.circle", tint: BLTheme.danger) {
                                disconnectPrimaryMailbox(mb)
                            }
                        }
                    } else {
                        IconButton(system: "trash", tint: BLTheme.danger) { deleteMailbox(mb) }
                    }
                }
            }
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: - 3b) Provider-API sending (Gmail API / Microsoft Graph over real OAuth)
    private var emailAPIPanel: some View {
        Panel(title: "Mailboxes — sending (provider API)", icon: "checkmark.seal.fill") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Connect a mailbox over the provider's REAL API instead of SMTP: you authorize on Google's or Microsoft's own consent screen and every send calls the Gmail API / Microsoft Graph with your token — no app-password. Paste your own OAuth client ID, then Connect. The chip turns Connected only after a live API check returns 200.")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                emailAPIRow(.gmail, clientID: $gmailClientID)
                emailAPIRow(.microsoft, clientID: $msClientID)
            }
        }
    }

    @ViewBuilder private func emailAPIRow(_ provider: EmailAPIProvider, clientID: Binding<String>) -> some View {
        let connectedAddr = connectedAPIAddress(for: provider)
        let liveVerdict = connectedAddr.flatMap {
            emailAPICallOK[provider.rawValue] ?? ConnectorVerificationStore.verdict(ConnectorVerificationStore.emailAPI(provider.rawValue, address: $0))
        }
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: provider == .gmail ? "envelope.badge.fill" : "envelope.circle.fill").foregroundColor(BLTheme.gold)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(connectedAddr.map { liveVerdict == true ? "Verified as \($0)" : "Authorized as \($0) · verify again to confirm" } ?? "Not connected")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(liveVerdict == true ? BLTheme.green : BLTheme.sub)
                }
                Spacer()
                chip(ConnectorStatusEngine.emailAPI(hasToken: connectedAddr != nil,
                                                    lastCallOK: liveVerdict))
            }
            Field(title: "\(provider.displayName) OAuth client ID", text: clientID,
                  prompt: provider == .gmail ? "xxxxxxxx.apps.googleusercontent.com" : "Application (client) ID")
            if let note = emailAPINote[provider.rawValue], !note.isEmpty {
                Text(note).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(note.hasPrefix("✓") ? BLTheme.green : BLTheme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                GoldButton(label: "Save client ID", icon: "checkmark.circle") { saveEmailAPIClientID(provider, clientID.wrappedValue) }
                GoldButton(label: connectingProvider == provider ? "Connecting…" : (connectedAddr == nil ? "Connect" : "Reconnect"),
                           icon: "person.crop.circle.badge.checkmark") { connectEmailAPI(provider) }
                    .disabled(connectingProvider == provider)
                if connectedAddr != nil {
                    GhostButton(label: "Disconnect", icon: "xmark.circle", tint: BLTheme.danger) { disconnectEmailAPI(provider) }
                }
                GhostButton(label: "Console", icon: "arrow.up.right") { open(provider.consoleURL) }
            }
            Text("Register \(EmailOAuth.redirectURI(for: provider)) as a redirect URI in your \(provider == .gmail ? "Google Desktop app" : "Microsoft public-client") OAuth app — in the same console page where you created the client ID, under its redirect-URI settings.")
                .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: - 4) Inbox (IMAP)
    private var imapPanel: some View {
        let s = leadEngine.settings
        let configured = !s.imapHost.trimmingCharacters(in: .whitespaces).isEmpty && !s.imapUsername.trimmingCharacters(in: .whitespaces).isEmpty
        let imapAccount = s.imapUsername.trimmingCharacters(in: .whitespaces)
        let savedButUnreadable = s.imapEnabled && configured &&
            SendKeychain.hasSavedPasswordItem(account: imapAccount) &&
            !SendKeychain.hasReadablePassword(account: imapAccount)
        return Panel(title: "Inbox — reply detection (IMAP)", icon: "tray.and.arrow.down.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Read-only reply detection on your own mailbox — never sends, never deletes.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    Spacer()
                    chip(ConnectorStatusEngine.imap(enabled: s.imapEnabled, configured: configured,
                                                    testing: imapTesting, lastProbeOK: imapProbeOK))
                }
                Toggle(isOn: Binding(get: { leadEngine.settings.imapEnabled }, set: {
                    leadEngine.settings.imapEnabled = $0
                    imapProbeOK = nil
                    ConnectorVerificationStore.clear(ConnectorVerificationStore.imap)
                })) {
                    Text("Enable reply detection").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                }.tint(BLTheme.gold)
                if leadEngine.settings.imapEnabled {
                    Field(title: "IMAP host", text: Binding(get: { leadEngine.settings.imapHost }, set: {
                        leadEngine.settings.imapHost = $0; imapProbeOK = nil
                        ConnectorVerificationStore.clear(ConnectorVerificationStore.imap)
                    }), prompt: "imap.gmail.com")
                    HStack(spacing: 10) {
                        Field(title: "Username", text: Binding(get: { leadEngine.settings.imapUsername }, set: {
                            leadEngine.settings.imapUsername = $0; imapProbeOK = nil
                            ConnectorVerificationStore.clear(ConnectorVerificationStore.imap)
                        }), prompt: "you@yourbrand.com")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PORT").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                            Stepper("\(leadEngine.settings.imapPort)", value: Binding(get: { leadEngine.settings.imapPort }, set: {
                                leadEngine.settings.imapPort = $0; imapProbeOK = nil
                                ConnectorVerificationStore.clear(ConnectorVerificationStore.imap)
                            }), in: 1...65535)
                                .font(.system(size: 12, design: .rounded))
                        }
                    }
                    SecureRow(title: "App password (stored in Keychain)", prompt: passwordPrompt(for: leadEngine.settings.imapUsername), onCommit: { pw in
                        let user = leadEngine.settings.imapUsername.trimmingCharacters(in: .whitespaces)
                        if !user.isEmpty && !pw.isEmpty {
                            SendKeychain.setPassword(pw, account: user); imapProbeOK = nil
                            ConnectorVerificationStore.clear(ConnectorVerificationStore.imap)
                        }
                    })
                    if !imapTest.isEmpty {
                        Text(imapTest).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundColor(imapTest.hasPrefix("✓") ? BLTheme.green : BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                    GhostButton(label: imapTesting ? "Testing…" : "Test connection", icon: "bolt.horizontal") { testIMAP() }
                        .disabled(imapTesting)
                    if savedButUnreadable {
                        GhostButton(label: "Reconnect saved password", icon: "key.fill", tint: BLTheme.gold) {
                            reconnectIMAPPassword()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 5) Social
    private var socialPanel: some View {
        Panel(title: "Social accounts", icon: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Connect each network with its own OAuth — you authorize in your own account and the token is minted on this device.")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(SocialPlatform.allCases) { p in
                        let prof = model.profile(for: p)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 9) {
                                Image(systemName: p.icon).font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                                    .frame(width: 26, height: 26).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 7))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.rawValue).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Text(prof.map { $0.hasToken ? "@\($0.handle) · \($0.liveness().label)" : "@\($0.handle) · profile only" } ?? "Not linked")
                                        .font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                                }
                                Spacer()
                                // Liveness is passed in explicitly: an expired credential must read
                                // "Needs attention" even when a cached round-trip receipt says the
                                // last call succeeded, and an unrecorded expiry must not read green.
                                chip(ConnectorStatusEngine.social(
                                    hasToken: prof?.hasToken ?? false,
                                    linked: prof != nil,
                                    lastCallOK: ConnectorVerificationStore.verdict(ConnectorVerificationStore.social(p.rawValue)),
                                    liveness: prof?.liveness() ?? .unknown))
                            }
                            HStack(spacing: 8) {
                                GhostButton(label: prof?.hasToken == true ? "Reconnect" : "Connect", icon: "link") { connectingSocial = p }
                                GhostButton(label: prof == nil ? "Open \(p.rawValue)" : "Open profile", icon: "arrow.up.right") {
                                    openSocialProfile(p, prof: prof)
                                }
                                Spacer()
                                if let prof = prof {
                                    IconButton(system: "trash", tint: BLTheme.danger) {
                                        ConnectorVerificationStore.clear(ConnectorVerificationStore.social(p.rawValue))
                                        model.disconnect(prof)
                                    }
                                }
                            }
                        }
                        .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                }
                Text("Connect opens each provider's authorization/setup path. A profile-only handle is not shown as Connected until a real token is stored.")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
            }
        }
    }

    // MARK: - 6) Newsletters via Cloudflare
    private var cloudflarePanel: some View {
        let configured = CloudflareEmailConfig.isConfigured(endpoint: cfEndpoint, fromEmail: cfFromEmail, hasToken: cfHasToken)
        let savedButUnreadable = !cfHasToken && CloudflareEmailConfig.hasSavedTokenItem
        return Panel(title: "Newsletters — Cloudflare send (optional/advanced)", icon: "cloud.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Optional. Newsletters already send over your own mailbox with no setup — this is only for high-volume senders who'd rather route through their own Cloudflare Email Sending Worker. If that's not you, skip this and just Send from the Newsletters screen.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    chip(ConnectorStatusEngine.cloudflareNewsletter(
                        isConfigured: configured,
                        lastCallOK: ConnectorVerificationStore.verdict(ConnectorVerificationStore.cloudflareNewsletter)))
                }
                Field(title: "Worker endpoint (https)", text: $cfEndpoint, prompt: "https://newsletter.yourname.workers.dev/send")
                HStack(spacing: 10) {
                    Field(title: "From email (a domain onboarded to CF Email Sending)", text: $cfFromEmail, prompt: "news@yourbrand.com")
                    Field(title: "From name", text: $cfFromName, prompt: "Acme Studio")
                }
                SecureRow(title: savedButUnreadable ? "Shared secret (saved — re-enter to reconnect)" : "Shared secret (Bearer token; stored in Keychain)",
                          prompt: cfHasToken ? "•••••••• saved — type to replace" : (savedButUnreadable ? "Saved token needs reconnect" : "Paste the token you set with wrangler secret put"),
                          onCommit: { cfToken = $0 })
                Toggle(isOn: $cfAutoSend) {
                    Text("Auto-send due newsletters through Cloudflare").font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                }.tint(BLTheme.gold)
                Text("When on, the app checks your saved newsletters on launch and periodically while running, and sends any that are due on their cadence through Cloudflare — to your own contacts.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    GoldButton(label: "Save Cloudflare settings", icon: "checkmark.circle") { saveCloudflare() }
                    if savedButUnreadable {
                        GhostButton(label: "Reconnect saved token", icon: "key.fill", tint: BLTheme.gold) {
                            reconnectCloudflareNewsletter()
                        }
                    }
                    GhostButton(label: "Deploy guide", icon: "arrow.up.right") { open("https://developers.cloudflare.com/email-service/") }
                }
                if !cfNote.isEmpty {
                    Text(cfNote).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(cfNote.hasPrefix("✓") ? BLTheme.green : BLTheme.gold).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 7) CRM / Telephony / Enrichment / Analytics (honest states)
    private var otherConnectorsPanel: some View {
        let s = leadEngine.settings
        return Panel(title: "Other integrations", icon: "square.grid.2x2.fill") {
            VStack(alignment: .leading, spacing: 12) {
                crmConnectorPanel
                honestRow(icon: "phone.fill", name: "Telephony",
                          detail: s.telephony.provider.needsCredential ? "BYO \(s.telephony.provider.label) — connect your credential to place programmatic calls." : "System dialer active — click-to-call hands off to your Mac's calling app.",
                          state: ConnectorStatusEngine.telephony(providerNeedsCredential: s.telephony.provider.needsCredential, canPlaceProgrammatic: s.telephony.canPlaceProgrammatic))
                enrichmentConnectorPanel
                Divider().background(BLTheme.stroke)
                Text("ANALYTICS SOURCES").font(BLFonts.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                cloudflareAnalyticsPanel
                Text("Cloudflare pulls REAL requests + page views from your own account (above). GA4 / Ads / Meta save your own IDs below and stay a configured source until you authorize each provider's API — never fabricated numbers.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                DataSourcesPanel()
            }
        }
    }

    private var crmConnectorPanel: some View {
        let state = ConnectorStatusEngine.crm(isConnected: leadEngine.settings.crmConnector.isConnected,
                                              providerSelected: leadEngine.settings.crmConnector.provider != .none)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "cloud.fill").foregroundColor(BLTheme.gold)
                Text("CRM sync").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                chip(state)
            }
            Text("Push a real saved lead into your own Salesforce, HubSpot, or Pipedrive account. The chip turns Connected only after a live 2xx CRM response.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROVIDER").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                    Picker("", selection: $crmProvider) {
                        ForEach(CRMProvider.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
                if crmProvider.needsInstanceURL {
                    Field(title: crmProvider == .salesforce ? "Instance URL" : "Pipedrive domain",
                          text: $crmInstanceURL,
                          prompt: crmProvider == .salesforce ? "https://acme.my.salesforce.com" : "acme.pipedrive.com")
                }
            }

            if crmProvider != .none {
                SecureRow(title: crmHasToken ? "API token (saved - type to replace)" : "API token",
                          prompt: crmHasToken ? "•••••••• saved" : "Paste your CRM API token") { crmToken = $0 }
                HStack(spacing: 10) {
                    GoldButton(label: "Save CRM settings", icon: "checkmark.circle") { saveCRM() }
                    GoldButton(label: crmTesting ? "Pushing..." : "Push first lead", icon: "arrow.up.circle") {
                        Task { await pushFirstLeadToCRM() }
                    }
                    .disabled(crmTesting || model.leads.isEmpty || session.demoMode)
                    .opacity((crmTesting || model.leads.isEmpty || session.demoMode) ? 0.55 : 1)
                    if crmHasToken {
                        GhostButton(label: "Clear token", icon: "xmark.circle", tint: BLTheme.danger) { clearCRMToken() }
                    }
                    GhostButton(label: "Token help", icon: "arrow.up.right") { openCRMHelp() }
                }
                Toggle(isOn: Binding(get: { leadEngine.settings.crmConnector.autoPushNewLeads },
                                     set: { value in updateCRMConfig { $0.autoPushNewLeads = value && $0.isConnected } })) {
                    Text("Auto-push new leads after a successful live test")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                }
                .toggleStyle(.checkbox)
                .disabled(!leadEngine.settings.crmConnector.isConnected)
                .opacity(leadEngine.settings.crmConnector.isConnected ? 1 : 0.55)

                // MARK: two-way sync — pull remote changes INTO the local workspace
                Rectangle().fill(BLTheme.stroke).frame(height: 1).padding(.vertical, 2)
                Text("Pull from \(crmProvider.label) — two-way sync")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text("Brings new and changed \(crmProvider == .pipedrive ? "persons" : "contacts") and deals from your own \(crmProvider.label) account into this workspace. A pull only fills empty fields or applies remote edits to fields you haven't changed since the last sync — it never deletes a local lead and never overwrites a local edit. Preview shows the exact change-set before anything is written.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    GoldButton(label: crmPulling ? "Pulling…" : "Pull now", icon: "arrow.down.circle") {
                        Task { await pullFromCRM(dryRun: false) }
                    }
                    .disabled(crmPulling || crmTesting || session.demoMode)
                    .opacity((crmPulling || crmTesting || session.demoMode) ? 0.55 : 1)
                    GhostButton(label: "Preview pull (dry run)", icon: "eye") {
                        Task { await pullFromCRM(dryRun: true) }
                    }
                    .disabled(crmPulling || crmTesting || session.demoMode)
                    .opacity((crmPulling || crmTesting || session.demoMode) ? 0.55 : 1)
                }
                if crmPulling && !crmPullProgress.isEmpty {
                    Text(crmPullProgress)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                }
                if let at = leadEngine.settings.crmConnector.lastPullAt {
                    Text("Last pull \(at.formatted(date: .abbreviated, time: .shortened)) — \(leadEngine.settings.crmConnector.lastPullSummary)")
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !leadEngine.settings.crmConnector.lastPullSummary.isEmpty {
                    Text(leadEngine.settings.crmConnector.lastPullSummary)
                        .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: Binding(get: { leadEngine.settings.crmConnector.autoPull },
                                     set: { value in updateCRMConfig { $0.autoPull = value } })) {
                    Text("Auto-pull when the app comes to the foreground")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                }
                .toggleStyle(.checkbox)
                .disabled(!leadEngine.settings.crmConnector.isConfigured)
                .opacity(leadEngine.settings.crmConnector.isConfigured ? 1 : 0.55)
            }

            if model.leads.isEmpty {
                Text("Add or import a lead before testing a CRM push.")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
            } else if session.demoMode {
                Text("Demo data will not be pushed to a real CRM. Connect your own workspace first.")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
            }
            if !crmNote.isEmpty {
                Text(crmNote)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(crmNote.hasPrefix("✓") ? BLTheme.green : BLTheme.gold)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !leadEngine.settings.crmConnector.lastPushMessage.isEmpty {
                Text(leadEngine.settings.crmConnector.lastPushMessage)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(leadEngine.settings.crmConnector.lastPushOK == true ? BLTheme.green : BLTheme.gold)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func honestRow(icon: String, name: String, detail: String, state: ConnectorState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: icon).foregroundColor(BLTheme.gold)
                Text(name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                chip(state)
            }
            Text(detail).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
        }
        .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: - Sendblue messaging (BYO iMessage / RCS / SMS line)
    //
    // Ships EMPTY: no key, no number, no endpoint. The chip goes green ONLY after a real
    // authenticated Sendblue read (GET /api/accounts/lines) returns 2xx with THIS key pair —
    // a saved key alone reads "Ready to verify", never Connected.
    private var sendbluePanel: some View {
        let savedButUnreadable = SendblueConfig.credentialNeedsReconnect
        let state = ConnectorStatusEngine.sendblue(
            hasCredential: sbHasCredential,
            savedButUnreadable: savedButUnreadable,
            testing: sbTesting,
            lastProbeOK: ConnectorVerificationStore.verdict(ConnectorVerificationStore.sendblue))
        return Panel(title: "Messaging — Sendblue (iMessage / RCS / SMS)", icon: "message.badge.waveform.fill") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Text your own leads from your own Sendblue line. Sendblue routes iMessage → RCS → SMS per number; we never send from a Black Label number and never touch a shared list. Your key stays in this Mac's Keychain.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    chip(state)
                }

                SecureRow(title: sbHasCredential ? "API key id (saved — type to replace)" : (savedButUnreadable ? "API key id (saved — re-enter to reconnect)" : "Sendblue API key id"),
                          prompt: sbHasCredential ? "•••••••• saved" : "sb-api-key-id",
                          onCommit: { sbKeyID = $0 })
                SecureRow(title: sbHasCredential ? "API secret (saved — type to replace)" : (savedButUnreadable ? "API secret (saved — re-enter to reconnect)" : "Sendblue API secret"),
                          prompt: sbHasCredential ? "•••••••• saved" : "sb-api-secret-key",
                          onCommit: { sbSecret = $0 })
                HStack(spacing: 10) {
                    Field(title: "Your Sendblue line (optional)", text: $sbFromNumber, prompt: "+15551234567")
                    Field(title: "Daily cap per line (0 = none)", text: $sbDailyCap, prompt: "0")
                }

                HStack(spacing: 10) {
                    GoldButton(label: "Save messaging settings", icon: "checkmark.circle") { saveSendblue() }
                    if savedButUnreadable {
                        GhostButton(label: "Reconnect saved key", icon: "key.fill", tint: BLTheme.gold) { reconnectSendblue() }
                    }
                    GhostButton(label: sbTesting ? "Verifying…" : "Verify credential", icon: "bolt.horizontal") { verifySendblue() }
                        .disabled(sbTesting)
                    // app.sendblue.com has NO DNS record — that button opened nothing. The real
                    // console (where the API key ID + secret are issued) is dashboard.sendblue.com,
                    // which answers and forwards a signed-out visitor to its own sign-in.
                    GhostButton(label: "Get your API key", icon: "arrow.up.right") { open("https://dashboard.sendblue.com") }
                }

                Text("Compliance: texting is TCPA/10DLC territory. The app blocks any send without recorded prior express consent, blocks a number that replied STOP, and holds sends outside 8am–9pm local. Those gates run in the app regardless of what the provider allows.")
                    .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)

                if !sbNote.isEmpty {
                    Text(sbNote).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(sbNote.hasPrefix("✓") ? BLTheme.green : BLTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func saveSendblue() {
        SendblueConfig.fromNumber = sbFromNumber
        sbFromNumber = SendblueConfig.fromNumber
        SendblueConfig.dailyLineCap = Int(sbDailyCap.trimmingCharacters(in: .whitespaces)) ?? 0
        sbDailyCap = SendblueConfig.dailyLineCap == 0 ? "" : "\(SendblueConfig.dailyLineCap)"
        let id = sbKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = sbSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty || !secret.isEmpty {
            guard !id.isEmpty, !secret.isEmpty else {
                sbNote = "✗ Sendblue needs BOTH the key id and the secret — nothing was saved."
                return
            }
            SendblueConfig.setCredential(keyID: id, secret: secret)
            sbKeyID = ""; sbSecret = ""
            // A new credential invalidates any earlier green: it has proven nothing yet.
            ConnectorVerificationStore.clear(ConnectorVerificationStore.sendblue)
        }
        sbHasCredential = SendblueConfig.hasCredential
        sbNote = sbHasCredential
            ? "✓ Saved. Hit Verify credential — the chip stays neutral until a real Sendblue call succeeds."
            : "Saved. Add your Sendblue key id + secret to send for real; until then every message is marked simulated."
    }

    private func reconnectSendblue() {
        let ok = SendblueConfig.migrateSavedCredential()
        sbHasCredential = SendblueConfig.hasCredential
        sbNote = ok ? "✓ Reconnected the saved Sendblue key." : "✗ The saved key still can't be read — re-enter it above."
    }

    private func verifySendblue() {
        sbNote = ""
        guard let credential = SendblueConfig.credential else {
            sbNote = "✗ No readable Sendblue credential to verify — save your key id + secret first."
            return
        }
        sbTesting = true
        Task {
            let result = await MessagingSender.verifyCredential(keyID: credential.keyID, secret: credential.secret)
            await MainActor.run {
                sbTesting = false
                ConnectorVerificationStore.record(ConnectorVerificationStore.sendblue, ok: result.ok, detail: result.detail)
                sbHasCredential = SendblueConfig.hasCredential
                sbNote = (result.ok ? "✓ " : "✗ ") + result.detail
            }
        }
    }

    // MARK: - Cloudflare Analytics (real requests + page-view pull)
    private var cloudflareAnalyticsPanel: some View {
        let savedButUnreadable = !cfaHasToken && CloudflareAnalyticsConfig.hasSavedTokenItem
        let state = ConnectorStatusEngine.cloudflareAnalytics(
            hasToken: cfaHasToken,
            hasAccount: !cfaAccount.trimmingCharacters(in: .whitespaces).isEmpty,
            hasZone: !cfaZone.trimmingCharacters(in: .whitespaces).isEmpty,
            lastPullOK: cfaResult?.ok)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cloud.bolt.fill").font(.system(size: 13, weight: .bold)).foregroundColor(BLTheme.gold)
                Text("Cloudflare Analytics").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                chip(state)
            }
            Text("Pull your site's real HTTP requests and page views straight from your own Cloudflare account over the GraphQL Analytics API. Create a scoped token (Analytics: Read) — the setup guide below walks through it.")
                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            GhostButton(label: "Open Cloudflare setup guide", icon: "book", tint: BLTheme.gold) {
                openBundledGuide("CLOUDFLARE-ANALYTICS-SETUP.md")
            }

            SecureRow(title: cfaHasToken ? "API token (saved — type to replace)" : (savedButUnreadable ? "Cloudflare API token (saved — re-enter to reconnect)" : "Cloudflare API token (Analytics: Read)"),
                      prompt: cfaHasToken ? "•••••••• saved" : (savedButUnreadable ? "Saved token needs reconnect" : "Paste your scoped API token"),
                      onCommit: { cfaToken = $0 })
            HStack(spacing: 10) {
                Field(title: "Account ID", text: $cfaAccount, prompt: "32-hex account ID")
                Field(title: "Zone (domain)", text: $cfaZone, prompt: "yourbrand.com")
            }
            Field(title: "Web Analytics site tag (optional — enables page views)", text: $cfaSiteTag, prompt: "Paste your Web Analytics site tag")

            HStack(spacing: 10) {
                GoldButton(label: "Save settings", icon: "checkmark.circle") { saveCloudflareAnalytics() }
                if savedButUnreadable {
                    GhostButton(label: "Reconnect saved token", icon: "key.fill", tint: BLTheme.gold) {
                        reconnectCloudflareAnalytics()
                    }
                }
                GhostButton(label: cfaTesting ? "Testing…" : "Test / Refresh", icon: "bolt.horizontal") { testCloudflareAnalytics() }
                    .disabled(cfaTesting)
                GhostButton(label: "Setup guide", icon: "arrow.up.right") { open("https://dash.cloudflare.com/profile/api-tokens") }
            }

            // Real, sourced numbers from the last successful pull — or an honest empty/needs-tag state.
            if let r = cfaResult {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 18) {
                        cfaMetric(label: "Requests", value: r.requests.map { Self.grouped($0) } ?? "—")
                        cfaMetric(label: "Page views", value: cfaPageViewsDisplay(r))
                    }
                    Text(cfaResultCaption(r))
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundColor(r.ok ? BLTheme.sub : BLTheme.danger).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
            if !cfaNote.isEmpty {
                Text(cfaNote).font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(cfaNote.hasPrefix("✓") ? BLTheme.green : BLTheme.danger).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func cfaMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text(label.uppercased()).font(BLFonts.mono(8.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
        }
    }
    private func cfaPageViewsDisplay(_ r: CFAnalyticsResult) -> String {
        switch r.pageViewsState {
        case .value: return r.pageViews.map { Self.grouped($0) } ?? "—"
        case .noSiteTag, .notAvailable: return "—"
        }
    }
    private func cfaResultCaption(_ r: CFAnalyticsResult) -> String {
        if !r.ok { return r.detail }
        var s = "\(r.rangeStart) → \(r.rangeEnd), pulled from your Cloudflare account."
        switch r.pageViewsState {
        case .value: break
        case .noSiteTag: s += " Add your Web Analytics site tag above to pull page views."
        case .notAvailable: s += " Page views need Web Analytics enabled for this site (with account Analytics: Read on the token)."
        }
        return s
    }
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func saveCloudflareAnalytics() {
        CloudflareAnalyticsConfig.accountID = cfaAccount
        CloudflareAnalyticsConfig.zone = cfaZone
        CloudflareAnalyticsConfig.siteTag = cfaSiteTag
        cfaAccount = CloudflareAnalyticsConfig.accountID
        cfaZone = CloudflareAnalyticsConfig.zone
        cfaSiteTag = CloudflareAnalyticsConfig.siteTag
        if !cfaToken.trimmingCharacters(in: .whitespaces).isEmpty {
            CloudflareAnalyticsConfig.setToken(cfaToken); cfaToken = ""
        }
        cfaHasToken = CloudflareAnalyticsConfig.hasToken
        cfaNote = CloudflareAnalyticsConfig.isConfigured
            ? "✓ Saved. Hit Test / Refresh to pull your real numbers."
            : "Saved — add the token, Account ID, and Zone to pull real data."
    }

    private func testCloudflareAnalytics() {
        cfaNote = ""
        cfaTesting = true
        Task {
            let r = await CloudflareAnalytics.refresh(days: 30)
            await MainActor.run {
                cfaTesting = false
                cfaResult = r
                cfaHasToken = CloudflareAnalyticsConfig.hasToken
                cfaNote = r.ok ? "✓ Pulled real data from Cloudflare." : "✗ " + r.detail
            }
        }
    }

    // MARK: - actions
    private func passwordPrompt(for user: String) -> String {
        SendKeychain.hasReadablePassword(account: user.trimmingCharacters(in: .whitespaces)) ? "•••••••• saved — type to replace" : "App password"
    }

    private func mailboxReady(_ mb: Mailbox) -> Bool {
        guard mb.isConfigured else { return false }
        if let provider = mb.authKind.provider {
            return EmailTokenStore.hasToken(provider: provider, address: mb.fromEmail)
        }
        return SendKeychain.hasReadablePassword(account: mb.username.trimmingCharacters(in: .whitespaces))
    }

    private func open(_ s: String) { if let u = URL(string: s) { DemoMode.openExternal(u, simulatedNote: "Demo: this would open \(s).") } }

    private func openSocialProfile(_ platform: SocialPlatform, prof: SocialProfile?) {
        if let handle = prof?.handle, let s = platform.profileURL(handle: handle), let url = URL(string: s) {
            DemoMode.openExternal(url, simulatedNote: "Demo: this would open \(s).")
        } else {
            DemoMode.openExternal(platform.accountHomeURL, simulatedNote: "Demo: this would open \(platform.accountHomeURL.absoluteString).")
        }
    }

    // MARK: CRM connector actions
    private func loadCRMStateIfNeeded() {
        guard !crmLoaded else { return }
        let c = leadEngine.settings.crmConnector
        crmProvider = c.provider
        crmInstanceURL = c.instanceURL
        crmHasToken = c.hasToken
        crmLoaded = true
    }

    // MARK: - Enrichment (BYO Hunter/Apollo email-finder) — interactive connect
    private var enrichmentConnectorPanel: some View {
        let s = leadEngine.settings.enrichment
        let vendor = enrichProvider.finderVendor
        let ready = s.providerReady
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "sparkle.magnifyingglass").foregroundColor(BLTheme.gold)
                Text("Enrichment — find missing emails").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Spacer()
                chip(ConnectorStatusEngine.enrichment(
                    providerNeedsKey: enrichProvider.needsKey,
                    providerReady: ready,
                    lastCallOK: vendor.flatMap { ConnectorVerificationStore.verdict(ConnectorVerificationStore.enrichment($0.rawValue)) }))
            }
            Text("Bring your OWN Hunter or Apollo API key. Look-ups run on your Mac against your provider account and attach only to the local lead — your lead list never touches our servers. Nothing is ever fabricated.")
                .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("PROVIDER").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                    Picker("", selection: $enrichProvider) {
                        ForEach(EnrichmentProvider.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().frame(width: 220)
                    .onChange(of: enrichProvider) { _ in enrichHasKey = vendorHasSavedKey() }
                }
                Spacer()
            }
            if enrichProvider == .clearbit {
                Text("Clearbit has no name→email finder — pick Hunter or Apollo to find missing emails.")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
            }
            if let v = vendor {
                SecureRow(title: enrichHasKey ? "\(v.label) API key (saved — type to replace)" : "\(v.label) API key",
                          prompt: enrichHasKey ? "•••••••• saved" : "Paste your \(v.label) API key") { enrichKey = $0 }
                HStack(spacing: 10) {
                    GoldButton(label: "Save key", icon: "checkmark.circle") { saveEnrichment(vendor: v) }
                    if enrichHasKey {
                        GhostButton(label: "Clear key", icon: "xmark.circle", tint: BLTheme.danger) { clearEnrichmentKey(vendor: v) }
                    }
                    // The hint below names the click-path; this opens the key page itself.
                    GhostButton(label: "Get your key", icon: "arrow.up.right") { open(v.apiKeyURL.absoluteString) }
                }
                Text(v.signupHint).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            }
            waterfallChainSection
            if !enrichNote.isEmpty {
                Text(enrichNote).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(enrichNote.hasPrefix("✓") ? BLTheme.green : BLTheme.gold).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: - MK-17 waterfall chain builder — the buyer's OWN ordered provider chain + real yield
    private var waterfallChainSection: some View {
        let chain = leadEngine.settings.enrichment.enrichmentChain
        let wired: [EnrichmentVendor] = [.hunter, .apollo, .prospeo]
        let yield = model.enrichmentProviderYield
        return VStack(alignment: .leading, spacing: 8) {
            Rectangle().fill(BLTheme.stroke).frame(height: 1).padding(.vertical, 2)
            Text("Waterfall — try your providers in order").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            Text("Add your own provider keys and order them. Enrichment runs each provider in order until the first confirmed email, then stops — and caches the result on the lead so re-running is instant and free. Nothing is ever fabricated or proxied through us.")
                .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            if chain.isEmpty {
                Text("No providers in the waterfall yet — add one below.").font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
            } else {
                ForEach(Array(chain.enumerated()), id: \.offset) { idx, v in
                    HStack(spacing: 8) {
                        Text("\(idx + 1)").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.gold).frame(width: 15)
                        Image(systemName: EnrichmentKeychain.hasKey(v) ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundColor(EnrichmentKeychain.hasKey(v) ? BLTheme.green : BLTheme.gold).font(.system(size: 11))
                        Text(v.label).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                        if !EnrichmentKeychain.hasKey(v) { Text("needs key").font(BLFonts.mono(8.5)).foregroundColor(BLTheme.sub) }
                        Spacer()
                        Button { moveChain(idx, by: -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).disabled(idx == 0)
                        Button { moveChain(idx, by: 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).disabled(idx == chain.count - 1)
                        Button { removeFromChain(v) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundColor(BLTheme.danger)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8).background(BLTheme.panel, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            let addable = wired.filter { !chain.contains($0) }
            if !addable.isEmpty {
                HStack(spacing: 8) {
                    ForEach(addable) { v in
                        Button { addToChain(v) } label: {
                            HStack(spacing: 4) { Image(systemName: "plus"); Text(v.label) }.font(.system(size: 10.5, weight: .bold, design: .rounded))
                        }.buttonStyle(.plain).foregroundColor(BLTheme.gold)
                        .padding(.vertical, 4).padding(.horizontal, 9).overlay(Capsule().stroke(BLTheme.gold.opacity(0.4), lineWidth: 1))
                    }
                }
            }
            if !yield.isEmpty {
                Text("Provider yield (your real results)").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).padding(.top, 2)
                ForEach(yield, id: \.vendor) { row in
                    HStack(spacing: 6) {
                        Text(EnrichmentVendor(rawValue: row.vendor)?.label ?? row.vendor).font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        Spacer()
                        Text("\(row.hits) confirmed").font(BLFonts.mono(10, weight: .bold)).foregroundColor(BLTheme.green)
                    }
                }
            }
        }
    }
    private func addToChain(_ v: EnrichmentVendor) {
        updateEnrichmentConfig { if !$0.enrichmentChain.contains(v) { $0.enrichmentChain.append(v) } }
    }
    private func removeFromChain(_ v: EnrichmentVendor) {
        updateEnrichmentConfig { $0.enrichmentChain.removeAll { $0 == v } }
    }
    private func moveChain(_ idx: Int, by delta: Int) {
        updateEnrichmentConfig {
            var c = $0.enrichmentChain
            let j = idx + delta
            guard c.indices.contains(idx), c.indices.contains(j) else { return }
            c.swapAt(idx, j); $0.enrichmentChain = c
        }
    }

    private func vendorHasSavedKey() -> Bool {
        guard let v = enrichProvider.finderVendor else { return false }
        return EnrichmentKeychain.hasKey(v)
    }

    private func loadEnrichmentStateIfNeeded() {
        guard !enrichLoaded else { return }
        enrichProvider = leadEngine.settings.enrichment.provider
        enrichHasKey = vendorHasSavedKey()
        enrichLoaded = true
    }

    private func updateEnrichmentConfig(_ mutate: (inout EnrichmentConfig) -> Void) {
        var s = leadEngine.settings
        mutate(&s.enrichment)
        leadEngine.settings = s
    }

    private func saveEnrichment(vendor: EnrichmentVendor) {
        let key = enrichKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            EnrichmentKeychain.set(key, vendor: vendor)
            ConnectorVerificationStore.clear(ConnectorVerificationStore.enrichment(vendor.rawValue))
            enrichKey = ""
        }
        let hasKey = EnrichmentKeychain.hasKey(vendor)
        enrichHasKey = hasKey
        updateEnrichmentConfig { $0.provider = enrichProvider; $0.hasKey = hasKey }
        enrichNote = hasKey ? "Saved. Open Leads → Find missing emails to verify \(vendor.label)."
                            : "Paste your \(vendor.label) API key to connect."
    }

    private func clearEnrichmentKey(vendor: EnrichmentVendor) {
        EnrichmentKeychain.clear(vendor)
        ConnectorVerificationStore.clear(ConnectorVerificationStore.enrichment(vendor.rawValue))
        enrichHasKey = false
        updateEnrichmentConfig { $0.hasKey = false }
        enrichNote = "\(vendor.label) key cleared."
    }

    private func updateCRMConfig(_ mutate: (inout CRMConnectorConfig) -> Void) {
        var s = leadEngine.settings
        mutate(&s.crmConnector)
        leadEngine.settings = s
    }

    private func saveCRM() {
        let old = leadEngine.settings.crmConnector
        var config = old
        config.provider = crmProvider
        config.instanceURL = crmInstanceURL.trimmingCharacters(in: .whitespacesAndNewlines)

        let account = CRMConnectorKeychain.account(for: config)
        let token = crmToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            CRMConnectorKeychain.setToken(token, account: account)
            crmToken = ""
            config.hasToken = true
            config.lastPushOK = nil
            config.lastPushMessage = "CRM token saved. Push a real lead to verify the connection."
        } else if old.provider != config.provider || old.instanceURL != config.instanceURL {
            config.hasToken = CRMConnectorKeychain.token(account: account) != nil
            config.lastPushOK = nil
            config.lastPushMessage = config.hasToken ? "CRM settings changed. Push a real lead to verify the connection." : ""
        }

        if config.provider == .none {
            config.hasToken = false
            config.lastPushOK = nil
            config.lastPushMessage = ""
            config.autoPushNewLeads = false
        }

        updateCRMConfig { $0 = config }
        crmHasToken = config.hasToken
        crmNote = config.isConfigured
            ? (config.isConnected ? "✓ CRM is connected from the last successful live push." : "Saved. Push a real lead to verify.")
            : "Saved — choose a provider, required instance/domain, and token."
    }

    private func clearCRMToken() {
        var config = leadEngine.settings.crmConnector
        CRMConnectorKeychain.delete(account: CRMConnectorKeychain.account(for: config))
        config.hasToken = false
        config.lastPushOK = nil
        config.lastPushMessage = ""
        config.autoPushNewLeads = false
        updateCRMConfig { $0 = config }
        crmHasToken = false
        crmToken = ""
        crmNote = "CRM token cleared."
    }

    @MainActor
    private func pushFirstLeadToCRM() async {
        if session.demoMode {
            crmNote = "Demo data is not pushed to a real CRM. Connect your own workspace first."
            return
        }
        saveCRM()
        guard let lead = model.leads.first else {
            crmNote = "Add or import a lead before testing a CRM push."
            return
        }
        let config = leadEngine.settings.crmConnector
        guard config.isConfigured else {
            crmNote = "Save a provider, required instance/domain, and token first."
            return
        }
        crmTesting = true
        crmNote = ""
        do {
            let result = try await CRMConnectorClient.pushLead(lead, config: config)
            var updated = leadEngine.settings.crmConnector
            updated.lastPushOK = true
            updated.lastSyncAt = Date()
            updated.lastSyncCount = 1
            updated.lastPushMessage = "✓ Pushed \(lead.displayName) to \(result.provider.label)\(result.remoteID.map { " (#\($0))" } ?? "")."
            updateCRMConfig { $0 = updated }
            crmNote = updated.lastPushMessage
        } catch {
            var updated = leadEngine.settings.crmConnector
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            updated.lastPushOK = false
            updated.lastPushMessage = "✗ \(message)"
            updateCRMConfig { $0 = updated }
            crmNote = updated.lastPushMessage
        }
        crmTesting = false
    }

    // MARK: CRM two-way sync — pull remote changes into the local workspace
    /// Fetch the remote change-set. dryRun opens the preview sheet with the plan; otherwise the
    /// plan is applied immediately. Either path runs the SAME plan, so preview and apply can't diverge.
    @MainActor
    private func pullFromCRM(dryRun: Bool) async {
        if session.demoMode {
            crmNote = "Demo data stays local — connect your own CRM workspace first."
            return
        }
        saveCRM()
        let config = leadEngine.settings.crmConnector
        guard config.isConfigured else {
            crmNote = "Save a provider, required instance/domain, and token first."
            return
        }
        crmPulling = true
        crmPullProgress = "Contacting \(config.provider.label)…"
        crmNote = ""
        do {
            let plan = try await CRMPullEngine.fetchPlan(config: config,
                                                         localLeads: model.leads,
                                                         localDeals: model.deals) { note in
                Task { @MainActor in crmPullProgress = note }
            }
            if dryRun {
                crmPullPreview = CRMPullPreviewModel(plan: plan)
                crmNote = plan.isEmpty
                    ? "Dry run: \(plan.summary)."
                    : "Dry run ready: \(plan.summary). Review the change-set and apply from the preview."
            } else {
                applyCRMPullPlan(plan)
            }
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            crmNote = "✗ Pull failed: \(msg)"
        }
        crmPulling = false
        crmPullProgress = ""
    }

    @MainActor
    private func applyCRMPullPlan(_ plan: CRMPullPlan) {
        let summary = CRMPullEngine.apply(plan, model: model,
                                          stages: leadEngine.settings.stages,
                                          config: leadEngine.settings.crmConnector)
        updateCRMConfig { $0.lastPullAt = Date(); $0.lastPullSummary = summary }
        crmPullPreview = nil
        crmNote = "✓ Pull applied — \(summary)."
    }

    /// Where the buyer's CRM token actually comes from. Pipedrive issues a personal API token on a
    /// real settings page, so we open THAT — built from the company domain they typed above, since
    /// the page is per-account (app.pipedrive.com is the account-agnostic entry when it's blank).
    /// Salesforce and HubSpot have no single credential page — a Salesforce token comes out of an
    /// OAuth flow against a connected app, a HubSpot one out of a private app scoped to a portal id
    /// we don't have — so those stay on the documentation that actually walks it, rather than a
    /// guessed deep link that 404s (app.hubspot.com/private-apps does exactly that).
    private func openCRMHelp() {
        switch crmProvider {
        case .salesforce: open("https://help.salesforce.com/s/articleView?id=sf.remoteaccess_oauth_flows.htm&type=5")
        case .hubspot: open("https://developers.hubspot.com/docs/api/private-apps")
        case .pipedrive: open(pipedriveAPITokenURL)
        case .none: break
        }
    }

    /// `acme.pipedrive.com` (or a pasted https URL) → that company's API-token settings page.
    private var pipedriveAPITokenURL: String {
        var host = crmInstanceURL.trimmingCharacters(in: .whitespaces)
        if let parsed = URL(string: host), let h = parsed.host { host = h }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard host.hasSuffix(".pipedrive.com") else { return "https://app.pipedrive.com/settings/api" }
        return "https://\(host)/settings/api"
    }

    private func saveGoogleClientID() {
        let t = googleClientID.trimmingCharacters(in: .whitespaces); googleClientID = t
        let d = UserDefaults.standard
        if t.isEmpty { d.removeObject(forKey: GoogleAuth.clientIDDefaultsKey) } else { d.set(t, forKey: GoogleAuth.clientIDDefaultsKey) }
        flash(t.isEmpty ? "Google client ID cleared." : "Google client ID saved.")
    }

    // MARK: real Google OAuth sign-in (connection = completed OAuth + validated userinfo)
    private func signInWithGoogle() {
        guard GoogleAuth.isConfigured else { flash("Save your Google Desktop client ID first."); return }
        googleSigningIn = true
        GoogleAuth.shared.signIn { result in
            googleSigningIn = false
            switch result {
            case .success(let email):
                googleSignedInEmail = email
                UserDefaults.standard.set(email, forKey: "GoogleSignedInEmail")
                flash("Signed in with Google as \(email).")
            case .failure(let e):
                let msg = (e as? LocalizedError)?.errorDescription ?? "\(e)"
                flash("Google sign-in failed: \(msg)")
            }
        }
    }
    private func signOutGoogle() {
        googleSignedInEmail = ""
        UserDefaults.standard.removeObject(forKey: "GoogleSignedInEmail")
        flash("Signed out of Google.")
    }

    // MARK: mailbox row helpers
    private func mailboxSubtitle(_ mb: Mailbox, isPrimary: Bool) -> String {
        if mb.usesProviderAPI { return "Connected via \(mb.authKind.transportLabel) · \(isPrimary ? "primary" : "rotation")" }
        return mb.host.isEmpty ? "No SMTP host" : "\(mb.host):\(mb.port) · \(isPrimary ? "primary" : "rotation")"
    }

    // MARK: provider-API email (Gmail API / Microsoft Graph) actions
    /// The connected address for a provider = a mailbox with that transport AND a stored OAuth token.
    private func connectedAPIAddress(for provider: EmailAPIProvider) -> String? {
        let all = [leadEngine.settings.mailbox] + leadEngine.settings.extraMailboxes
        guard let mb = all.first(where: { $0.authKind == provider.authKind && !$0.fromEmail.isEmpty }),
              EmailTokenStore.hasToken(provider: provider, address: mb.fromEmail) else { return nil }
        return mb.fromEmail
    }

    private func saveEmailAPIClientID(_ provider: EmailAPIProvider, _ id: String) {
        let t = id.trimmingCharacters(in: .whitespaces)
        let d = UserDefaults.standard
        if t.isEmpty { d.removeObject(forKey: provider.clientIDDefaultsKey) } else { d.set(t, forKey: provider.clientIDDefaultsKey) }
        if provider == .gmail { gmailClientID = t } else { msClientID = t }
        emailAPINote[provider.rawValue] = t.isEmpty ? "Client ID cleared." : "✓ Client ID saved — now Connect."
    }

    private func connectEmailAPI(_ provider: EmailAPIProvider) {
        // Persist the client id first so EmailOAuth picks it up.
        saveEmailAPIClientID(provider, provider == .gmail ? gmailClientID : msClientID)
        guard EmailOAuth.isConfigured(provider) else {
            emailAPINote[provider.rawValue] = "Add your \(provider.displayName) OAuth client ID first. Opening the provider console."
            open(provider.consoleURL)
            return
        }
        connectingProvider = provider
        emailAPINote[provider.rawValue] = ""
        EmailOAuth.shared.connect(provider: provider) { result in
            connectingProvider = nil
            switch result {
            case .success(let c):
                upsertAPIMailbox(provider: provider, address: c.address)
                emailAPICallOK[provider.rawValue] = true   // a real validate call returned 200
                ConnectorVerificationStore.record(
                    ConnectorVerificationStore.emailAPI(provider.rawValue, address: c.address),
                    ok: true, detail: "Authenticated account validation succeeded")
                emailAPINote[provider.rawValue] = "✓ Connected as \(c.address) via \(provider.authKind.transportLabel)."
                flash("\(provider.displayName) connected as \(c.address).")
            case .failure(let e):
                let msg = (e as? LocalizedError)?.errorDescription ?? "\(e)"
                if let address = connectedAPIAddress(for: provider) {
                    emailAPICallOK[provider.rawValue] = false
                    ConnectorVerificationStore.record(
                        ConnectorVerificationStore.emailAPI(provider.rawValue, address: address),
                        ok: false, detail: msg)
                } else {
                    emailAPICallOK[provider.rawValue] = nil
                }
                emailAPINote[provider.rawValue] = "✗ \(msg)"
            }
        }
    }

    /// Insert (or update) the connected mailbox in settings. If the primary slot is empty, take it;
    /// otherwise join the rotation. CAN-SPAM address + from-name are seeded from the primary mailbox.
    private func upsertAPIMailbox(provider: EmailAPIProvider, address: String) {
        var s = leadEngine.settings
        // Capture the primary's CAN-SPAM address + from-name up front so `seed` never reads `s`
        // while it holds an inout on `s.mailbox` (exclusive-access rule).
        let seedName = s.mailbox.fromName
        let seedAddress = s.mailbox.physicalAddress
        func seed(_ m: inout Mailbox) {
            m.authKind = provider.authKind
            m.fromEmail = address
            m.username = address
            if m.fromName.isEmpty { m.fromName = seedName }
            if m.physicalAddress.isEmpty { m.physicalAddress = seedAddress }
        }
        if s.mailbox.authKind == provider.authKind, s.mailbox.fromEmail.caseInsensitiveCompare(address) == .orderedSame {
            seed(&s.mailbox)
        } else if let i = s.extraMailboxes.firstIndex(where: { $0.authKind == provider.authKind && $0.fromEmail.caseInsensitiveCompare(address) == .orderedSame }) {
            seed(&s.extraMailboxes[i])
        } else if !s.mailbox.isConfigured && s.mailbox.fromEmail.isEmpty {
            var m = Mailbox(); seed(&m); s.mailbox = m
        } else {
            var m = Mailbox(); seed(&m); s.extraMailboxes.append(m)
        }
        leadEngine.settings = s
    }

    private func disconnectEmailAPI(_ provider: EmailAPIProvider) {
        guard let addr = connectedAPIAddress(for: provider) else { return }
        EmailTokenStore.delete(provider: provider, address: addr)
        ConnectorVerificationStore.clear(ConnectorVerificationStore.emailAPI(provider.rawValue, address: addr))
        removeAPIMailbox(authKind: provider.authKind, address: addr)
        emailAPICallOK[provider.rawValue] = nil
        emailAPINote[provider.rawValue] = "Disconnected."
        flash("\(provider.displayName) disconnected.")
    }
    private func disconnectAPIMailbox(_ mb: Mailbox) {
        if let p = mb.authKind.provider {
            EmailTokenStore.delete(provider: p, address: mb.fromEmail)
            ConnectorVerificationStore.clear(ConnectorVerificationStore.emailAPI(p.rawValue, address: mb.fromEmail))
        }
        removeAPIMailbox(authKind: mb.authKind, address: mb.fromEmail)
        flash("Mailbox disconnected.")
    }
    private func removeAPIMailbox(authKind: EmailAuthKind, address: String) {
        var s = leadEngine.settings
        s.extraMailboxes.removeAll { $0.authKind == authKind && $0.fromEmail.caseInsensitiveCompare(address) == .orderedSame }
        if s.mailbox.authKind == authKind, s.mailbox.fromEmail.caseInsensitiveCompare(address) == .orderedSame {
            s.mailbox = Mailbox()   // clear the primary slot back to an empty SMTP mailbox
        }
        leadEngine.settings = s
    }
    private func saveLeadDBToken() {
        let t = leadDBToken.trimmingCharacters(in: .whitespacesAndNewlines); leadDBToken = t
        if t.isEmpty {
            LeadDBCredential.clear()
            leadDBValidation = nil
            leadDBTesting = false
            flash("Lead Database key cleared.")
            return
        }
        leadDBTesting = true
        leadDBValidation = nil
        Task {
            let validation = await LeadDB.validateToken(t)
            await MainActor.run {
                leadDBTesting = false
                leadDBValidation = validation
                if validation.valid {
                    LeadDBCredential.save(t)
                    flash("Lead Database key validated and saved to your Keychain.")
                }
            }
        }
    }

    private func validateSavedLeadDBToken() {
        let t = leadDBToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !leadDBTesting else { return }
        leadDBTesting = true
        Task {
            let validation = await LeadDB.validateToken(t)
            await MainActor.run {
                leadDBTesting = false
                leadDBValidation = validation
            }
        }
    }

    private func saveMailbox(_ mb: Mailbox, newPassword: String?) {
        var m = mb
        let user = m.username.trimmingCharacters(in: .whitespaces)
        if let pw = newPassword, !pw.isEmpty, !user.isEmpty {
            SendKeychain.setPassword(pw, account: user); m.hasPassword = true
        } else if !user.isEmpty {
            m.hasPassword = SendKeychain.hasReadablePassword(account: user)
        }
        if editingIsPrimary {
            leadEngine.settings.mailbox = m
        } else if let i = leadEngine.settings.extraMailboxes.firstIndex(where: { $0.id == m.id }) {
            leadEngine.settings.extraMailboxes[i] = m
        } else {
            leadEngine.settings.extraMailboxes.append(m)
        }
        // Credentials just changed — any prior "Connected" verdict is stale. Force re-verification so the
        // chip drops to "Not tested" until the buyer runs Test connection against the new credentials.
        mailboxProbeOK[m.id] = nil
        ConnectorVerificationStore.clear(ConnectorVerificationStore.smtp(m.id))
        mailboxTest[m.id] = ""
        editingMailbox = nil
        flash("Mailbox saved. Run Test connection to verify.")
    }
    private func deleteMailbox(_ mb: Mailbox) {
        leadEngine.settings.extraMailboxes.removeAll { $0.id == mb.id }
        ConnectorVerificationStore.clear(ConnectorVerificationStore.smtp(mb.id))
        mailboxProbeOK[mb.id] = nil; mailboxTest[mb.id] = ""
        editingMailbox = nil
        flash("Mailbox removed.")
    }
    /// P0-2: clear the primary mailbox's saved credentials so the buyer can re-enter them. The primary
    /// row itself stays (it's the default sender slot) but drops back to a "not set up" empty state.
    private func disconnectPrimaryMailbox(_ mb: Mailbox) {
        let account = mb.username.trimmingCharacters(in: .whitespaces)
        if !account.isEmpty { SendKeychain.delete(account: account) }
        var cleared = Mailbox()
        cleared.id = mb.id
        leadEngine.settings.mailbox = cleared
        ConnectorVerificationStore.clear(ConnectorVerificationStore.smtp(mb.id))
        mailboxProbeOK[mb.id] = nil; mailboxTest[mb.id] = ""
        flash("Primary mailbox disconnected. Add your credentials to reconnect.")
    }
    private func testMailbox(_ mb: Mailbox) {
        guard let pw = SendKeychain.password(account: mb.username.trimmingCharacters(in: .whitespaces)), !pw.isEmpty else {
            mailboxProbeOK[mb.id] = false
            ConnectorVerificationStore.record(ConnectorVerificationStore.smtp(mb.id), ok: false, detail: "No app password saved")
            mailboxTest[mb.id] = "✗ No app password saved — edit the mailbox and add it first."; return
        }
        // Enter the testing state and clear any prior verdict so the chip cannot show a stale "Connected"
        // while a fresh probe is in flight.
        testing.insert(mb.id); mailboxTest[mb.id] = ""; mailboxProbeOK[mb.id] = nil
        Task {
            let r = await SMTPClient(mailbox: mb, password: pw).verify()
            await MainActor.run {
                testing.remove(mb.id)
                mailboxProbeOK[mb.id] = r.ok          // the ONLY place the chip is allowed to go green
                ConnectorVerificationStore.record(ConnectorVerificationStore.smtp(mb.id), ok: r.ok, detail: r.message)
                mailboxTest[mb.id] = (r.ok ? "✓ " : "✗ ") + r.message
            }
        }
    }
    private func reconnectMailPassword(_ mb: Mailbox) {
        let account = mb.username.trimmingCharacters(in: .whitespaces)
        guard !account.isEmpty, SendKeychain.hasSavedPasswordItem(account: account) else {
            mailboxTest[mb.id] = "✗ No saved app password item found — edit the mailbox and paste it once."; return
        }
        mailboxTest[mb.id] = "Reconnecting saved password..."
        Task {
            let ok = await runSelfMigration(["--migrate-smtp-account", account])
            await MainActor.run {
                if ok && SendKeychain.hasReadablePassword(account: account) {
                    var settings = leadEngine.settings
                    if settings.mailbox.id == mb.id {
                        settings.mailbox.hasPassword = true
                    } else if let idx = settings.extraMailboxes.firstIndex(where: { $0.id == mb.id }) {
                        settings.extraMailboxes[idx].hasPassword = true
                    }
                    leadEngine.settings = settings
                    mailboxProbeOK[mb.id] = nil   // reconnected keychain item is not a live SMTP verification
                    ConnectorVerificationStore.clear(ConnectorVerificationStore.smtp(mb.id))
                    mailboxTest[mb.id] = "✓ Saved app password reconnected. Test connection to verify SMTP."
                    flash("Mailbox keychain item reconnected.")
                } else {
                    mailboxTest[mb.id] = "✗ macOS did not grant access to the saved password. Re-enter the app password once."
                }
            }
        }
    }
    private func testIMAP() {
        let s = leadEngine.settings
        let user = s.imapUsername.trimmingCharacters(in: .whitespaces)
        let pw = SendKeychain.password(account: user) ?? SendKeychain.password(account: s.mailbox.username) ?? ""
        guard !s.imapHost.isEmpty, !user.isEmpty, !pw.isEmpty else {
            imapProbeOK = false
            ConnectorVerificationStore.record(ConnectorVerificationStore.imap, ok: false, detail: "Host, username, or password missing")
            imapTest = "✗ Add host, username, and app password first."; return
        }
        imapTesting = true; imapTest = ""
        let cfg = IMAPConfig(host: s.imapHost, port: UInt16(s.imapPort), username: user, password: pw)
        Task {
            let r = await IMAPClient(config: cfg).test()
            await MainActor.run {
                imapTesting = false
                imapProbeOK = r.ok
                ConnectorVerificationStore.record(ConnectorVerificationStore.imap, ok: r.ok, detail: r.message)
                imapTest = (r.ok ? "✓ " : "✗ ") + r.message
            }
        }
    }
    private func reconnectIMAPPassword() {
        let user = leadEngine.settings.imapUsername.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, SendKeychain.hasSavedPasswordItem(account: user) else {
            imapTest = "✗ No saved IMAP password item found — paste the app password once."; return
        }
        imapTest = "Reconnecting saved IMAP password..."
        Task {
            let ok = await runSelfMigration(["--migrate-imap-account", user])
            await MainActor.run {
                if ok && SendKeychain.hasReadablePassword(account: user) {
                    imapProbeOK = nil
                    ConnectorVerificationStore.clear(ConnectorVerificationStore.imap)
                    imapTest = "✓ Saved IMAP password reconnected. Test connection to verify inbox access."
                    flash("IMAP keychain item reconnected.")
                } else {
                    imapTest = "✗ macOS did not grant access to the saved IMAP password. Re-enter it once."
                }
            }
        }
    }
    private func saveCloudflare() {
        let oldEndpoint = CloudflareEmailConfig.endpoint
        let oldFrom = CloudflareEmailConfig.fromEmail
        let replacingToken = !cfToken.trimmingCharacters(in: .whitespaces).isEmpty
        CloudflareEmailConfig.endpoint = cfEndpoint
        CloudflareEmailConfig.fromEmail = cfFromEmail
        CloudflareEmailConfig.fromName = cfFromName
        CloudflareEmailConfig.autoSend = cfAutoSend
        if !cfToken.trimmingCharacters(in: .whitespaces).isEmpty {
            CloudflareEmailConfig.setToken(cfToken); cfToken = ""
        }
        if oldEndpoint != CloudflareEmailConfig.endpoint || oldFrom != CloudflareEmailConfig.fromEmail || replacingToken {
            ConnectorVerificationStore.clear(ConnectorVerificationStore.cloudflareNewsletter)
        }
        cfHasToken = CloudflareEmailConfig.hasToken
        cfEndpoint = CloudflareEmailConfig.endpoint; cfFromEmail = CloudflareEmailConfig.fromEmail
        let ok = CloudflareEmailConfig.isConfigured
        cfNote = ok ? "Saved. Send a newsletter once to verify the Worker." : "Saved — fill the endpoint (https), a valid from-email, and the secret to finish."
    }
    private func reconnectCloudflareNewsletter() {
        guard CloudflareEmailConfig.hasSavedTokenItem else {
            cfNote = "No saved Cloudflare token item was found — paste the Worker secret once."; return
        }
        cfNote = "Reconnecting saved Cloudflare token..."
        Task {
            let ok = await runSelfMigration(["--migrate-cloudflare-newsletter"], timeout: 30)
            await MainActor.run {
                if ok {
                    cfHasToken = CloudflareEmailConfig.hasToken
                    cfNote = CloudflareEmailConfig.isConfigured
                        ? "✓ Saved Cloudflare token reconnected."
                        : "Saved token reconnected — finish endpoint and from-email."
                    flash("Cloudflare newsletter token reconnected.")
                } else {
                    cfNote = "macOS did not grant access to the saved token. Re-enter the Worker secret once."
                }
            }
        }
    }

    private func reconnectCloudflareAnalytics() {
        guard CloudflareAnalyticsConfig.hasSavedTokenItem else {
            cfaNote = "No saved Cloudflare Analytics token item was found — paste the token once."; return
        }
        cfaNote = "Reconnecting saved Cloudflare Analytics token..."
        Task {
            let ok = await runSelfMigration(["--migrate-cloudflare-analytics"], timeout: 60)
            await MainActor.run {
                if ok {
                    cfaHasToken = CloudflareAnalyticsConfig.hasToken
                    cfaNote = CloudflareAnalyticsConfig.isConfigured
                        ? "✓ Saved Cloudflare Analytics token reconnected. Test / Refresh to verify."
                        : "Saved token reconnected — finish Account ID and Zone."
                    flash("Cloudflare Analytics token reconnected.")
                } else {
                    cfaNote = "macOS did not grant access to the saved Analytics token. Re-enter it once."
                }
            }
        }
    }
}

// MARK: - a reusable secure field row (password entry; commits on change, never displays the secret)
struct SecureRow: View {
    let title: String
    let prompt: String
    let onCommit: (String) -> Void
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
            SecureField(prompt, text: $value)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .rounded)).foregroundColor(BLTheme.text)
                .padding(9).background(BLTheme.bg).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(BLTheme.stroke, lineWidth: 1))
                .onChangeCompat(of: value) { onCommit($0) }
        }
    }
}

// MARK: - mailbox editor sheet (host/port/username/from + app password + presets)
struct MailboxEditorSheet: View {
    @State var mailbox: Mailbox
    let isPrimary: Bool
    let onSave: (Mailbox, String?) -> Void
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) var dismiss
    @State private var newPassword = ""
    @State private var note = ""

    private var isAPI: Bool { mailbox.usesProviderAPI }

    /// Which provider this host maps to, for the setup walkthrough.
    private enum MailProvider { case gmail, microsoft, icloud, yahoo, other }
    private var mailProvider: MailProvider {
        let h = mailbox.host.lowercased()
        if h.contains("gmail") || h.contains("googlemail") { return .gmail }
        if h.contains("office365") || h.contains("outlook") || h.contains("microsoft") { return .microsoft }
        if h.contains("icloud") || h.contains("me.com") { return .icloud }
        if h.contains("yahoo") { return .yahoo }
        return .other
    }
    private var mailSetupTitle: String {
        switch mailProvider {
        case .gmail: return "Set up your Gmail / Google Workspace app password"
        case .microsoft: return "Set up your Microsoft 365 / Outlook app password"
        case .icloud: return "Set up your iCloud Mail app password"
        case .yahoo: return "Set up your Yahoo Mail app password"
        case .other: return "About the app password"
        }
    }
    private var mailSetupSteps: [String] {
        switch mailProvider {
        case .gmail:
            return ["Turn on 2-Step Verification at myaccount.google.com → Security (required before app passwords exist).",
                    "Go to myaccount.google.com/apppasswords, name it \u{201C}Marketing\u{201D}, and Create.",
                    "Google shows a 16-character password — copy it (spaces don't matter).",
                    "Paste it into App password above. Username = your full Gmail address. Host stays smtp.gmail.com : 465."]
        case .microsoft:
            return ["Turn on two-step verification at account.microsoft.com → Security (app passwords require it).",
                    "Open account.microsoft.com/security → \u{201C}Advanced security options\u{201D} → \u{201C}App passwords\u{201D} → Create a new app password.",
                    "Copy the generated password (NOT your normal Outlook password).",
                    "Paste it into App password above. Username = your full 365/Outlook address. Host = smtp.office365.com : 465 (pick the Outlook preset).",
                    "If your organization blocks app passwords, ask your admin to enable them or use the provider-API (Microsoft Graph) connector instead."]
        case .icloud:
            return ["Enable two-factor authentication for your Apple ID.",
                    "At appleid.apple.com → Sign-In and Security → App-Specific Passwords → Generate.",
                    "Copy it and paste into App password above. Host = smtp.mail.me.com : 465."]
        case .yahoo:
            return ["At login.yahoo.com → Account Security, turn on two-step verification.",
                    "Generate an app password for \u{201C}Other app\u{201D}.",
                    "Paste it into App password above. Host = smtp.mail.yahoo.com : 465."]
        case .other:
            return ["Most providers require an APP-SPECIFIC password (not your login password), usually after enabling two-factor.",
                    "Create one in your provider's account security settings, then paste it above.",
                    "Use port 465 (SSL) if your provider offers it, or port 587 (STARTTLS) if it doesn't — both send."]
        }
    }

    @ViewBuilder private var mailboxSetupGuide: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.gold)
                Text(mailSetupTitle).font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
            }
            ForEach(Array(mailSetupSteps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 7) {
                    Text("\(i + 1)").font(BLFonts.mono(9.5, weight: .bold)).foregroundColor(BLTheme.gold)
                        .frame(width: 15, height: 15).background(BLTheme.gold.opacity(0.14)).clipShape(Circle())
                    Text(step).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if mailProvider == .gmail || mailProvider == .microsoft {
                Button {
                    let s = mailProvider == .gmail ? "https://myaccount.google.com/apppasswords" : "https://account.microsoft.com/security"
                    if let u = URL(string: s) { DemoMode.openExternal(u, simulatedNote: "Demo: this would open \(s).") }
                } label: {
                    HStack(spacing: 5) { Image(systemName: "arrow.up.right"); Text(mailProvider == .gmail ? "Open Google app passwords" : "Open Microsoft security") }
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold)
                }.buttonStyle(.plain)
            }
        }
        .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(isAPI ? "\(mailbox.authKind.transportLabel) mailbox" : (isPrimary ? "Primary mailbox" : "Sending mailbox"))
                    .font(BLFonts.display(22, weight: .medium)).foregroundColor(BLTheme.text)
                Text(isAPI
                     ? "Connected over \(mailbox.authKind.transportLabel) — sends call the provider's real API with your OAuth token (no SMTP, no app-password). Set your from-name and CAN-SPAM address below; reconnect from the Connectors list."
                     : "Your own email account. Sends go out over encrypted SMTP on port 465 (SSL) or port 587 (STARTTLS). Most providers require an app-specific password (not your login password).")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)

                if !isAPI {
                    // Provider preset picker (SMTP only)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PROVIDER PRESET").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                        Menu {
                            ForEach(Array(Mailbox.presets.enumerated()), id: \.offset) { _, preset in
                                Button(preset.name) { mailbox.host = preset.host; mailbox.port = preset.port }
                            }
                        } label: {
                            HStack {
                                Text(Mailbox.presets.first { $0.host == mailbox.host }?.name ?? "Custom SMTP")
                                    .font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                Spacer(); Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.sub)
                            }
                            .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                Field(title: "From name", text: $mailbox.fromName, prompt: "Jane at Acme")
                if isAPI {
                    Field(title: "From email (from your provider — read-only)", text: .constant(mailbox.fromEmail), prompt: "you@yourbrand.com")
                        .disabled(true).opacity(0.7)
                } else {
                    Field(title: "From email (your address)", text: $mailbox.fromEmail, prompt: "jane@acme.com")
                    HStack(spacing: 10) {
                        Field(title: "SMTP host", text: $mailbox.host, prompt: "smtp.gmail.com")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PORT").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                            Stepper("\(mailbox.port)", value: $mailbox.port, in: 1...65535).font(.system(size: 12, design: .rounded))
                        }
                    }
                    Field(title: "Username (usually your email)", text: $mailbox.username, prompt: "jane@acme.com")
                    SecureRow(title: mailbox.hasPassword ? "App password (saved — type to replace)" : "App password",
                              prompt: mailbox.hasPassword ? "•••••••• saved" : "app-specific password",
                              onCommit: { newPassword = $0 })
                    // P2-15: provider-specific, step-by-step app-password guidance so a non-expert can
                    // finish the setup that stalled the tester (Gmail / Microsoft 365 both need a special
                    // app password, NOT the login password, and both require 2-step verification on first).
                    mailboxSetupGuide
                }
                Field(title: "Physical mailing address (CAN-SPAM, required)", text: $mailbox.physicalAddress, prompt: "123 Main St, Springfield, IL")
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DAILY CAP").font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
                        Stepper("\(mailbox.dailyCap)/day", value: $mailbox.dailyCap, in: 5...2000, step: 5).font(.system(size: 12, design: .rounded))
                    }
                    Toggle(isOn: $mailbox.enabled) { Text("In rotation").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text) }.tint(BLTheme.gold)
                }
                if !isAPI, !mailbox.usesSupportedSMTPPort {
                    Text("Use port 465 (SSL) or port 587 (STARTTLS) — port \(mailbox.port) isn't an SMTP submission port this app can send on.")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold).fixedSize(horizontal: false, vertical: true)
                }
                if !note.isEmpty { Text(note).font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger) }

                HStack {
                    if let onDelete = onDelete {
                        GhostButton(label: "Remove", icon: "trash", tint: BLTheme.danger) { onDelete(); dismiss() }
                    }
                    Spacer()
                    GhostButton(label: "Cancel") { dismiss() }
                    GoldButton(label: "Save mailbox", icon: "checkmark.circle") {
                        let email = mailbox.fromEmail.trimmingCharacters(in: .whitespaces)
                        if isAPI {
                            guard email.contains("@") else { note = "This mailbox has no provider address — reconnect it."; return }
                        } else {
                            guard email.contains("@"), !mailbox.host.trimmingCharacters(in: .whitespaces).isEmpty,
                                  !mailbox.username.trimmingCharacters(in: .whitespaces).isEmpty else {
                                note = "Add a from-email, SMTP host, and username first."; return
                            }
                        }
                        onSave(mailbox, newPassword.isEmpty ? nil : newPassword)
                        dismiss()
                    }
                }
            }
            .padding(26)
        }
        #if os(macOS)
        .frame(width: 480, height: 680)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
    }
}

// MARK: - CRM pull preview (dry run): the EXACT change-set, rendered before anything is written
struct CRMPullPreviewModel: Identifiable {
    let id = UUID()
    let plan: CRMPullPlan
}

struct CRMPullPreviewSheet: View {
    let plan: CRMPullPlan
    let onApply: () -> Void
    @Environment(\.dismiss) var dismiss

    private var updatesWithChanges: [CRMPlannedContactUpdate] { plan.updates.filter { !$0.changes.isEmpty } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Pull preview — \(plan.provider.label)")
                    .font(BLFonts.display(22, weight: .medium)).foregroundColor(BLTheme.text)
                Text("This is the exact change-set a pull would apply — computed by the same engine that applies it. Nothing has been written yet. A pull never deletes a local lead and never overwrites a local edit made since the last sync.")
                    .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 16) {
                    countCell("New leads", plan.creates.count, tint: BLTheme.green)
                    countCell("Updated", updatesWithChanges.count, tint: BLTheme.gold)
                    countCell("New deals", plan.dealCreates.count, tint: BLTheme.green)
                    countCell("Deal updates", plan.dealUpdates.count, tint: BLTheme.gold)
                    countCell("Unchanged", plan.unchanged, tint: BLTheme.sub)
                    countCell("Kept local", plan.keptLocalCount, tint: BLTheme.sub)
                }

                if plan.isEmpty {
                    Text("Nothing to apply — \(plan.summary).")
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.green)
                }

                if !plan.creates.isEmpty {
                    sampleSection("NEW LEADS (sample)") {
                        ForEach(plan.creates.prefix(6)) { c in
                            sampleRow(icon: "person.badge.plus",
                                      title: c.lead.displayName,
                                      detail: [c.lead.company, c.lead.email].filter { !$0.isEmpty }.joined(separator: " · ")
                                          + "  ·  #\(c.remoteID)")
                        }
                        overflowNote(plan.creates.count, shown: 6)
                    }
                }

                if !updatesWithChanges.isEmpty {
                    sampleSection("UPDATED LEADS (sample)") {
                        ForEach(updatesWithChanges.prefix(6)) { u in
                            VStack(alignment: .leading, spacing: 3) {
                                sampleRow(icon: "arrow.triangle.2.circlepath",
                                          title: u.displayName, detail: "#\(u.remoteID)")
                                ForEach(u.changes.prefix(3)) { ch in
                                    Text("\(ch.field): \(ch.localValue.isEmpty ? "(empty)" : "\"\(ch.localValue)\"") → \"\(ch.remoteValue)\"")
                                        .font(BLFonts.mono(9.5)).foregroundColor(BLTheme.sub)
                                        .padding(.leading, 24).fixedSize(horizontal: false, vertical: true)
                                }
                                if u.changes.count > 3 {
                                    Text("+ \(u.changes.count - 3) more field\(u.changes.count - 3 == 1 ? "" : "s")")
                                        .font(BLFonts.mono(9)).foregroundColor(BLTheme.sub).padding(.leading, 24)
                                }
                                if !u.keptLocal.isEmpty {
                                    Text("\(u.keptLocal.count) local edit\(u.keptLocal.count == 1 ? "" : "s") kept (yours wins)")
                                        .font(BLFonts.mono(9)).foregroundColor(BLTheme.gold).padding(.leading, 24)
                                }
                            }
                        }
                        overflowNote(updatesWithChanges.count, shown: 6)
                    }
                }

                if !plan.dealCreates.isEmpty || !plan.dealUpdates.isEmpty {
                    sampleSection("DEALS (sample)") {
                        ForEach(plan.dealCreates.prefix(4)) { d in
                            sampleRow(icon: "plus.circle",
                                      title: d.title,
                                      detail: d.value > 0 ? String(format: "value %.2f · #%@", d.value, d.remoteID) : "#\(d.remoteID)")
                        }
                        ForEach(plan.dealUpdates.prefix(4)) { d in
                            sampleRow(icon: "arrow.triangle.2.circlepath",
                                      title: d.title, detail: "update · #\(d.remoteID)")
                        }
                    }
                }

                if !plan.notes.isEmpty {
                    sampleSection("NOTES") {
                        ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, n in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "info.circle").font(.system(size: 10)).foregroundColor(BLTheme.gold)
                                Text(n).font(.system(size: 10, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                HStack {
                    Spacer()
                    GhostButton(label: "Cancel") { dismiss() }
                    GoldButton(label: plan.isEmpty ? "Nothing to apply" : "Apply \(plan.applyCount) change\(plan.applyCount == 1 ? "" : "s")",
                               icon: "checkmark.circle") {
                        onApply()
                        dismiss()
                    }
                    .disabled(plan.isEmpty)
                    .opacity(plan.isEmpty ? 0.55 : 1)
                }
            }
            .padding(26)
        }
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .background(BLTheme.bg)
    }

    private func countCell(_ label: String, _ n: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(n)").font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(n > 0 ? tint : BLTheme.sub)
            Text(label.uppercased()).font(BLFonts.mono(8, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.5)
        }
    }

    @ViewBuilder private func sampleSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(BLFonts.mono(9, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
            content()
        }
        .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func sampleRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(BLTheme.gold).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 9.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func overflowNote(_ total: Int, shown: Int) -> some View {
        if total > shown {
            Text("+ \(total - shown) more (all applied — the full change-set is logged per lead)")
                .font(BLFonts.mono(9)).foregroundColor(BLTheme.sub)
        }
    }
}
#endif // circuit-convert
