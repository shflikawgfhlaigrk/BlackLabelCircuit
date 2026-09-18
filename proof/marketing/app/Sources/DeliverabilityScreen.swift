#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Deliverability workbench (the UI for the already-real engines).
//
// Makes the in-house deliverability toolkit buyer-reachable in one place:
//   * Domain health — live SPF / DKIM / DMARC / MX (AuthChecker) + public-blocklist lookups
//     (BlocklistChecker) on the buyer's OWN sending domain, fused into ONE transparent composite
//     score where every point traces to a named check (same explained-score model the email
//     scorer uses — DeliverabilityScore/DeliverabilityFactor).
//   * Content lint — the deterministic SpamLinter over a pasted/loaded draft, live as you type,
//     plus a SpintaxEngine variant counter + seeded preview.
//   * Bulk verify — EmailVerifier over the buyer's CRM leads or pasted addresses, with real
//     per-address progress, honest verdict rollups, timeline logging, and a CSV export.
//
// HONESTY (CHARTER §5.1): every verdict on this screen is a real DNS answer or deterministic
// on-device text analysis, run live on demand. Empty states say "run it to see it" — nothing is
// estimated, sampled, or invented. In demo mode the MX lookup is skipped for the synthetic sample
// domains (and says so) — the same convention the send path uses.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UniformTypeIdentifiers) && !CIRCUIT_WINDOWS_SIM
import UniformTypeIdentifiers
#else
import CircuitPortKit
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - hub shell (pinned header + tabs; children own their scrolling — see LeadsHubScreen)

struct DeliverabilityScreen: View {
    enum Mode: String, Hashable {
        case health, lint, verify
    }

    @State private var mode: Mode
    private let tabs = [
        HubTab(id: Mode.health, title: "Domain Health", icon: "shield.lefthalf.filled"),
        HubTab(id: Mode.lint, title: "Content Lint", icon: "text.magnifyingglass"),
        HubTab(id: Mode.verify, title: "Bulk Verify", icon: "checkmark.seal.fill")
    ]

    init(initial: Mode = .health) {
        _mode = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ScreenHeader(title: "Deliverability",
                             subtitle: "Will your emails land in inboxes? Check your domain's setup, lint a draft for spam triggers, and verify addresses in bulk — every result comes from live DNS or on-device analysis, never guessed.")
                HubTabs(tabs: tabs, selection: $mode)
            }
            .padding(.horizontal, 26).padding(.top, 26)
            Group {
                switch mode {
                case .health: DomainHealthTab()
                case .lint: ContentLintTab()
                case .verify: BulkVerifyTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

// MARK: - shared tint mapping (semantic model tints → theme colors; file-private, view-side only)

private func tintColor(_ t: DeliverabilityScore.Tint) -> Color {
    switch t {
    case .green: return BLTheme.green
    case .blue: return Color(hex: 0x6FA8DC)
    case .amber: return BLTheme.gold
    case .red: return BLTheme.danger
    case .gray: return BLTheme.sub
    }
}

private func verdictColor(_ v: EmailVerdict) -> Color {
    switch v {
    case .deliverable: return BLTheme.green
    case .risky: return BLTheme.gold
    case .undeliverable, .invalid: return BLTheme.danger
    case .unknown: return BLTheme.sub
    }
}

private func authVerdictColor(_ v: AuthRecord.Verdict) -> Color {
    switch v {
    case .pass: return BLTheme.green
    case .warn: return BLTheme.gold
    case .fail: return BLTheme.danger
    case .info: return BLTheme.sub
    }
}

private func factorIcon(_ k: DeliverabilityFactor.Kind) -> (name: String, color: Color) {
    switch k {
    case .confirm: return ("checkmark.circle.fill", BLTheme.green)
    case .penalty: return ("exclamationmark.triangle.fill", BLTheme.gold)
    case .hardFail: return ("xmark.octagon.fill", BLTheme.danger)
    }
}

// MARK: - domain-health composite (deterministic fusion of the LIVE checks; every point attributed)

enum DomainHealthComposite {
    /// Fuse live AuthChecker + BlocklistChecker results into one explained DeliverabilityScore.
    /// PURE and deterministic over its inputs — every factor quotes the real check's own detail, so
    /// the buyer sees exactly which DNS answer cost which points. `ipsChecked` is false when the
    /// apex published no A record (the RBL IP lookups couldn't run) — an honest small deduction,
    /// same pattern as the email scorer's "MX not verified" cap.
    static func score(auth: [AuthRecord], blocklist: [BlocklistResult], ipsChecked: Bool) -> DeliverabilityScore {
        var factors: [DeliverabilityFactor] = []

        // Hard fail: the domain can't receive mail at all. Replies and bounces have nowhere to go
        // and many receivers reject mail from a domain with no MX.
        if let mx = auth.first(where: { $0.kind == .mx }), mx.verdict == .fail {
            factors.append(DeliverabilityFactor(label: "No mail server (MX)", impact: -100,
                                                detail: mx.detail, kind: .hardFail))
            for rec in auth where rec.kind != .mx {
                factors.append(factor(for: rec).0)
            }
            return DeliverabilityScore(score: 0, grade: .undeliverable, verdict: .undeliverable,
                                       factors: factors, mxChecked: true)
        }

        var score = 100
        for rec in auth {
            let (f, delta) = factor(for: rec)
            factors.append(f)
            score += delta
        }

        let listed = blocklist.filter { $0.listed }
        if listed.isEmpty && !blocklist.isEmpty {
            factors.append(DeliverabilityFactor(label: "Not on the checked blocklists", impact: 0,
                detail: "None of the public DNS blocklists queried (\(blocklist.map { $0.zone }.joined(separator: ", "))) list this domain or its resolved IPs.", kind: .confirm))
        }
        for l in listed {
            score -= 40
            factors.append(DeliverabilityFactor(label: "Listed on \(l.zone)", impact: -40,
                detail: "The blocklist returned a listing: \(l.note). Delisting instructions are on the operator's site — sending while listed lands in spam.", kind: .penalty))
        }
        if !ipsChecked {
            score -= 5
            factors.append(DeliverabilityFactor(label: "Mail-server IPs not resolved", impact: -5,
                detail: "The domain publishes no apex A record, so the IP blocklists couldn't be queried — only the domain blocklist was. Ask your mail provider for your outbound IPs to check them directly.", kind: .penalty))
        }

        score = max(0, min(100, score))
        let grade: DeliverabilityScore.Grade
        switch score {
        case 90...100: grade = .excellent
        case 75...89:  grade = .good
        case 55...74:  grade = .fair
        case 35...54:  grade = .risky
        default:       grade = .poor
        }
        return DeliverabilityScore(score: score, grade: grade,
                                   verdict: score >= 55 ? .deliverable : .risky,
                                   factors: factors, mxChecked: true)
    }

    /// One auth record → one attributed factor (+ its signed score delta). The factor quotes the
    /// checker's own plain-English detail so the explanation IS the real check, not a paraphrase.
    private static func factor(for rec: AuthRecord) -> (DeliverabilityFactor, Int) {
        let weights: [AuthRecord.Kind: (warn: Int, fail: Int)] = [
            .spf: (-15, -30), .dkim: (-15, -25), .dmarc: (-10, -20), .mx: (0, 0),
        ]
        let w = weights[rec.kind] ?? (0, 0)
        switch rec.verdict {
        case .pass, .info:
            return (DeliverabilityFactor(label: "\(rec.kind.rawValue) — \(rec.verdict == .pass ? "pass" : "info")",
                                         impact: 0, detail: rec.detail, kind: .confirm), 0)
        case .warn:
            return (DeliverabilityFactor(label: "\(rec.kind.rawValue) needs work", impact: w.warn,
                                         detail: rec.detail, kind: .penalty), w.warn)
        case .fail:
            return (DeliverabilityFactor(label: "\(rec.kind.rawValue) missing", impact: w.fail,
                                         detail: rec.detail, kind: .penalty), w.fail)
        }
    }
}

// MARK: - tab 1: domain health (live SPF / DKIM / DMARC / MX + blocklists + composite)

private struct DomainHealthTab: View {
    @EnvironmentObject var leadEngine: LeadEngineStore
    @State private var domain = ""
    @State private var extraSelector = ""
    @State private var running = false
    @State private var auth: [AuthRecord] = []
    @State private var blockIPs: [String] = []
    @State private var blocklist: [BlocklistResult] = []
    @State private var composite: DeliverabilityScore?
    @State private var checkedDomain = ""
    @State private var inputError = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel(title: "Your sending domain", icon: "shield.lefthalf.filled") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Enter the domain you send from. The checks below run live against real DNS the moment you run them — SPF, DKIM, DMARC, MX, and the public blocklists. Nothing is cached or invented.")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        Field(title: "Your email domain (the part after @)", text: $domain, prompt: "yourbrand.com", onSubmit: run)
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Only needed if your email provider gave you a custom DKIM selector name — most people can leave this empty; the common ones are checked automatically.")
                                    .font(.system(size: 10.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                                    .fixedSize(horizontal: false, vertical: true)
                                Field(title: "Extra DKIM selector (optional)", text: $extraSelector, prompt: "e.g. mandrill")
                            }.padding(.top, 6)
                        } label: {
                            Text("Advanced").font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                        }.tint(BLTheme.sub)
                        HStack(spacing: 10) {
                            GoldButton(label: running ? "Checking…" : "Run live checks", icon: "bolt.fill") { run() }
                            if running { ProgressView().controlSize(.small).tint(BLTheme.gold) }
                            if !inputError.isEmpty {
                                Text(inputError)
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(BLTheme.danger)
                            }
                        }
                        Text("Common provider selectors (\(AuthChecker.commonSelectors.prefix(5).joined(separator: ", ")), …) are probed automatically, plus any custom selectors saved in Settings.")
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.sub.opacity(0.85))
                    }
                }

                if let c = composite {
                    Panel(title: "Domain health score", icon: "gauge.with.needle") {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(c.score)")
                                    .font(BLFonts.mono(44, weight: .heavy))
                                    .foregroundStyle(BLTheme.goldText)
                                Text("/100")
                                    .font(BLFonts.mono(16, weight: .bold))
                                    .foregroundColor(BLTheme.sub)
                                StatusPill(text: c.grade.rawValue, tint: tintColor(c.grade.tint))
                                Spacer()
                                Text(checkedDomain)
                                    .font(BLFonts.mono(12, weight: .bold))
                                    .foregroundColor(BLTheme.sub)
                            }
                            VStack(spacing: 0) {
                                ForEach(c.factors) { f in
                                    let icon = factorIcon(f.kind)
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: icon.name)
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundColor(icon.color)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 3) {
                                            HStack {
                                                Text(f.label)
                                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                                    .foregroundColor(BLTheme.text)
                                                Spacer()
                                                if f.impact != 0 {
                                                    Text("\(f.impact) pts")
                                                        .font(BLFonts.mono(11.5, weight: .bold))
                                                        .foregroundColor(icon.color)
                                                }
                                            }
                                            Text(f.detail)
                                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                                .foregroundColor(BLTheme.sub)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    if f.id != c.factors.last?.id {
                                        Rectangle().fill(BLTheme.stroke).frame(height: 1)
                                    }
                                }
                            }
                        }
                    }

                    Panel(title: "Raw records", icon: "doc.plaintext") {
                        VStack(spacing: 0) {
                            ForEach(auth) { rec in
                                HStack(alignment: .top, spacing: 10) {
                                    StatusPill(text: rec.kind.rawValue, tint: BLTheme.gold)
                                        .frame(width: 62, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(rec.value)
                                                .font(BLFonts.mono(11, weight: .medium))
                                                .foregroundColor(BLTheme.text)
                                                .lineLimit(3)
                                                .textSelection(.enabled)
                                            Spacer()
                                            StatusPill(text: rec.verdict.rawValue, tint: authVerdictColor(rec.verdict))
                                        }
                                        Text(rec.detail)
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundColor(BLTheme.sub)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.vertical, 8)
                                if rec.id != auth.last?.id {
                                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                                }
                            }
                        }
                    }

                    Panel(title: "Blocklists", icon: "nosign") {
                        VStack(alignment: .leading, spacing: 10) {
                            if blockIPs.isEmpty {
                                Text("The domain publishes no apex A record, so only the domain blocklist (DBL) could be queried. Your real outbound IPs belong to your mail provider — ask them for the list to check those directly.")
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.sub)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("Resolved IPs checked: \(blockIPs.joined(separator: ", ")). The apex A record is a free proxy for your mail IPs — your provider's actual outbound IPs may differ.")
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.sub)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            VStack(spacing: 0) {
                                ForEach(blocklist) { r in
                                    HStack {
                                        Text(r.zone)
                                            .font(BLFonts.mono(12, weight: .bold))
                                            .foregroundColor(BLTheme.text)
                                        Spacer()
                                        Text(r.note)
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundColor(BLTheme.sub)
                                            .lineLimit(2)
                                        StatusPill(text: r.listed ? "Listed" : "Clean",
                                                   tint: r.listed ? BLTheme.danger : BLTheme.green)
                                    }
                                    .padding(.vertical, 8)
                                    if r.id != blocklist.last?.id {
                                        Rectangle().fill(BLTheme.stroke).frame(height: 1)
                                    }
                                }
                            }
                        }
                    }
                } else if !running {
                    EmptyState(icon: "shield.lefthalf.filled", title: "No checks run yet",
                               hint: "Enter your sending domain and run the live checks to see your SPF, DKIM, DMARC, MX, and blocklist status. Results appear only after a real lookup — never before.")
                        .frame(maxWidth: .infinity)
                }

                Panel(title: "About inbox-placement testing", icon: "envelope.open") {
                    Text("True inbox-placement (seed-list) testing requires seed mailboxes at every major provider — a paid service this app doesn't fake. The checks above are the real, free half: authentication and reputation, verified live against DNS.")
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 26).padding(.bottom, 26).padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            if domain.isEmpty {
                let from = leadEngine.settings.mailbox.fromEmail
                if !from.isEmpty { domain = Deliverability.domain(of: from) }
            }
        }
    }

    private func run() {
        guard !running else { return }
        let d = EmailEngine.normalizeDomain(domain)
        guard !d.isEmpty, d.contains(".") else {
            inputError = "Enter a domain like yourbrand.com first."
            return
        }
        inputError = ""
        running = true
        auth = []; blockIPs = []; blocklist = []; composite = nil
        let extras = ([extraSelector] + leadEngine.settings.dkimSelectors)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        Task { @MainActor in
            let records = await AuthChecker.check(domain: d, extraSelectors: extras)
            let bl = await BlocklistChecker.check(domain: d)
            auth = records
            blockIPs = bl.ips
            blocklist = bl.results
            composite = DomainHealthComposite.score(auth: records, blocklist: bl.results,
                                                    ipsChecked: !bl.ips.isEmpty)
            checkedDomain = d
            running = false
        }
    }
}

// MARK: - tab 2: content lint (deterministic spam lint + spintax preview, live as you type)

private struct ContentLintTab: View {
    @EnvironmentObject var leadEngine: LeadEngineStore
    @State private var draftSubject = ""
    @State private var draftBody = ""

    private var isEmpty: Bool {
        draftSubject.trimmingCharacters(in: .whitespaces).isEmpty &&
        draftBody.trimmingCharacters(in: .whitespaces).isEmpty
    }
    private var lint: SpamLint { SpamLinter.lint(subject: draftSubject, body: draftBody) }
    private var combined: String { draftSubject + "\n" + draftBody }
    private var hasSpintax: Bool { combined.contains("{") || combined.contains("}") }

    private func riskColor(_ r: SpamLint.Risk) -> Color {
        switch r {
        case .low: return BLTheme.green
        case .medium: return BLTheme.gold
        case .high: return BLTheme.danger
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel(title: "Email draft", icon: "text.magnifyingglass") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Paste a draft (or load one of your saved outreach templates). The lint is deterministic, runs entirely on-device, and updates as you type — the same trigger-word and structure analysis spam filters key on.")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        if !leadEngine.settings.templates.isEmpty {
                            Menu {
                                ForEach(leadEngine.settings.templates) { t in
                                    Button("\(t.type.label): \(t.subject)") {
                                        draftSubject = t.subject
                                        draftBody = t.body
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "tray.and.arrow.up").font(.system(size: 11, weight: .bold))
                                    Text("Load a saved template").font(.system(size: 12, weight: .bold, design: .rounded))
                                }
                                .foregroundColor(BLTheme.text)
                                .padding(.vertical, 7).padding(.horizontal, 12)
                                .background(BLTheme.bg2).clipShape(Capsule())
                                .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        Field(title: "Subject", text: $draftSubject, prompt: "Quick idea for {{company}}")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("BODY").font(.system(size: 10, weight: .bold, design: .rounded))
                                .foregroundColor(BLTheme.sub).tracking(0.7)
                            TextEditor(text: $draftBody)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundColor(BLTheme.text)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 160)
                                .padding(8)
                                .background(BLTheme.bg2)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(BLTheme.stroke, lineWidth: 1))
                        }
                    }
                }

                if isEmpty {
                    EmptyState(icon: "text.magnifyingglass", title: "Nothing to lint yet",
                               hint: "Paste an email subject and body above — the spam lint and spintax preview run instantly, on-device, as you type.")
                        .frame(maxWidth: .infinity)
                } else {
                    Panel(title: "Spam lint", icon: "exclamationmark.shield") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                StatusPill(text: lint.risk.rawValue, tint: riskColor(lint.risk))
                                Text("Lint score \(lint.score) — 0 is clean; higher means more spam-filter signals.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.sub)
                            }
                            if lint.hits.isEmpty {
                                Text("No trigger phrases or structural spam signals found in this draft.")
                                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.green)
                            } else {
                                VStack(spacing: 0) {
                                    ForEach(lint.hits) { hit in
                                        HStack {
                                            Image(systemName: hit.kind == .word ? "textformat.abc" : "square.stack.3d.up")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(BLTheme.gold)
                                                .frame(width: 18)
                                            Text(hit.label)
                                                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                                .foregroundColor(BLTheme.text)
                                            Spacer()
                                            Text("+\(hit.weight)")
                                                .font(BLFonts.mono(11.5, weight: .bold))
                                                .foregroundColor(BLTheme.gold)
                                        }
                                        .padding(.vertical, 7)
                                        if hit.id != lint.hits.last?.id {
                                            Rectangle().fill(BLTheme.stroke).frame(height: 1)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Panel(title: "Spintax variations", icon: "shuffle") {
                        VStack(alignment: .leading, spacing: 12) {
                            if !hasSpintax {
                                Text("No variation groups in this draft. Add {option A|option B} groups (called “spintax”) so each prospect gets slightly different wording — mail providers are more suspicious of hundreds of identical messages.")
                                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.sub)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else if let count = SpintaxEngine.variantCount(combined) {
                                HStack(spacing: 10) {
                                    Text("\(count)")
                                        .font(BLFonts.mono(24, weight: .heavy))
                                        .foregroundStyle(BLTheme.goldText)
                                    Text("distinct variant\(count == 1 ? "" : "s") this draft can produce")
                                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                        .foregroundColor(BLTheme.sub)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("PREVIEW (SEEDED — SAME SEED, SAME SPIN)")
                                        .font(BLFonts.mono(9.5, weight: .bold))
                                        .foregroundColor(BLTheme.sub).tracking(0.8)
                                    ForEach(0..<min(3, max(1, count)), id: \.self) { i in
                                        Text(SpintaxEngine.spin(combined, seed: UInt64(i + 1)))
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundColor(BLTheme.text)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(BLTheme.bg2)
                                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                .stroke(BLTheme.stroke, lineWidth: 1))
                                    }
                                }
                            } else {
                                HStack(spacing: 8) {
                                    Image(systemName: "xmark.octagon.fill")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(BLTheme.danger)
                                    Text("Unbalanced or nested { } braces — fix the spintax groups. Nesting isn't supported (kept predictable on purpose).")
                                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                        .foregroundColor(BLTheme.danger)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 26).padding(.bottom, 26).padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - tab 3: bulk verify (EmailVerifier over CRM leads or pasted addresses, with progress + CSV)

private struct BulkVerifyTab: View {
    enum Source: String, CaseIterable, Identifiable {
        case leads = "CRM leads"
        case pasted = "Pasted emails"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var leadEngine: LeadEngineStore
    @State private var source: Source = .leads
    @State private var pasted = ""
    @State private var requireMX = true
    @State private var running = false
    @State private var done = 0
    @State private var total = 0
    @State private var results: [VerificationResult] = []
    @State private var note = ""
    @State private var loggedToTimeline = false
    @State private var verifyTask: Task<Void, Never>?

    private var leadsWithEmail: [Lead] {
        model.leads.filter { !$0.email.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    private var pastedEmails: [String] {
        let seps = CharacterSet(charactersIn: " \n\r\t,;")
        var seen = Set<String>(); var out: [String] = []
        for raw in pasted.components(separatedBy: seps) {
            let e = raw.trimmingCharacters(in: .whitespaces)
            if !e.isEmpty, seen.insert(e.lowercased()).inserted { out.append(e) }
        }
        return out
    }
    private var summary: [EmailVerdict: Int] { EmailVerifier.summarize(results) }
    private static let verdictOrder: [EmailVerdict] = [.deliverable, .risky, .undeliverable, .invalid, .unknown]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Panel(title: "Verify addresses", icon: "checkmark.seal.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Runs every address through the same in-house checks the send gate uses — syntax, role address, and a live MX lookup (cached per domain). Free, on-device; no paid verifier.")
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            ForEach(Source.allCases) { s in
                                let selected = source == s
                                Button {
                                    withAnimation(.easeOut(duration: 0.16)) { source = s }
                                } label: {
                                    Text(s.rawValue)
                                        .font(.system(size: 12, weight: .bold, design: .rounded))
                                        .foregroundColor(selected ? BLTheme.inkOnGold : BLTheme.text)
                                        .padding(.vertical, 7).padding(.horizontal, 12)
                                        .background(selected ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                                        .clipShape(Capsule())
                                        .overlay(Capsule().stroke(selected ? Color.clear : BLTheme.stroke, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                            Spacer()
                            Toggle(isOn: $requireMX) {
                                Text("Live MX check")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundColor(BLTheme.text)
                            }
                            .toggleStyle(.checkbox).tint(BLTheme.gold)
                        }
                        switch source {
                        case .leads:
                            if leadsWithEmail.isEmpty {
                                Text("No leads with an email on file yet — add or import leads in Leads (CRM), or switch to pasted emails.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.sub)
                            } else {
                                Text("\(leadsWithEmail.count) of your \(model.leads.count) lead\(model.leads.count == 1 ? "" : "s") have an email to verify.")
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundColor(BLTheme.sub)
                            }
                        case .pasted:
                            VStack(alignment: .leading, spacing: 5) {
                                Text("EMAILS — ONE PER LINE (COMMAS/SPACES OK)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(BLTheme.sub).tracking(0.7)
                                TextEditor(text: $pasted)
                                    .font(BLFonts.mono(12, weight: .medium))
                                    .foregroundColor(BLTheme.text)
                                    .scrollContentBackground(.hidden)
                                    .frame(minHeight: 110)
                                    .padding(8)
                                    .background(BLTheme.bg2)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(BLTheme.stroke, lineWidth: 1))
                                if !pastedEmails.isEmpty {
                                    Text("\(pastedEmails.count) unique address\(pastedEmails.count == 1 ? "" : "es") ready.")
                                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                        .foregroundColor(BLTheme.sub)
                                }
                            }
                        }
                        HStack(spacing: 10) {
                            GoldButton(label: running ? "Verifying…" : "Verify all", icon: "checkmark.seal.fill") { run() }
                            if running {
                                GhostButton(label: "Cancel", icon: "xmark") { verifyTask?.cancel() }
                            }
                            if !note.isEmpty {
                                Text(note)
                                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    .foregroundColor(BLTheme.gold)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if running || (total > 0 && done < total) {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: Double(done), total: Double(max(1, total)))
                                    .tint(BLTheme.gold)
                                Text("\(done) of \(total) checked")
                                    .font(BLFonts.mono(11, weight: .bold))
                                    .foregroundColor(BLTheme.sub)
                            }
                        }
                    }
                }

                if results.isEmpty && !running {
                    EmptyState(icon: "checkmark.seal", title: "No verification run yet",
                               hint: "Pick your leads or paste addresses and run a verification — every verdict comes from a real check at that moment, never a stored guess.")
                        .frame(maxWidth: .infinity)
                } else if !results.isEmpty {
                    Panel(title: "Summary", icon: "chart.bar.fill") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 10) {
                                ForEach(Self.verdictOrder.filter { (summary[$0] ?? 0) > 0 }, id: \.self) { v in
                                    HStack(spacing: 6) {
                                        Image(systemName: v.icon)
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(verdictColor(v))
                                        Text("\(summary[v] ?? 0)")
                                            .font(BLFonts.mono(13, weight: .heavy))
                                            .foregroundColor(BLTheme.text)
                                        Text(v.label)
                                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                                            .foregroundColor(BLTheme.sub)
                                    }
                                    .padding(.vertical, 6).padding(.horizontal, 10)
                                    .background(BLTheme.bg2).clipShape(Capsule())
                                    .overlay(Capsule().stroke(verdictColor(v).opacity(0.35), lineWidth: 1))
                                }
                                Spacer()
                            }
                            HStack(spacing: 10) {
                                GhostButton(label: "Export CSV", icon: "square.and.arrow.up") { exportCSV() }
                                if source == .leads && !loggedToTimeline {
                                    GhostButton(label: "Log verdicts to lead timelines", icon: "clock.arrow.circlepath") { logToTimelines() }
                                }
                                if loggedToTimeline {
                                    Text("Verdicts logged to each lead's timeline.")
                                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                        .foregroundColor(BLTheme.green)
                                }
                            }
                        }
                    }

                    Panel(title: "Per-address verdicts", icon: "list.bullet.rectangle") {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { r in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: r.verdict.icon)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(verdictColor(r.verdict))
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.email)
                                            .font(BLFonts.mono(12, weight: .bold))
                                            .foregroundColor(BLTheme.text)
                                            .textSelection(.enabled)
                                        Text(r.note)
                                            .font(.system(size: 11, weight: .medium, design: .rounded))
                                            .foregroundColor(BLTheme.sub)
                                    }
                                    Spacer()
                                    StatusPill(text: r.verdict.label, tint: verdictColor(r.verdict))
                                }
                                .padding(.vertical, 8)
                                if r.id != results.last?.id {
                                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 26).padding(.bottom, 26).padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { requireMX = leadEngine.settings.requireMX }
        .onDisappear { verifyTask?.cancel() }
    }

    private func run() {
        guard !running else { return }
        let items: [(id: UUID?, email: String)]
        switch source {
        case .leads:
            items = leadsWithEmail.map { ($0.id, $0.email.trimmingCharacters(in: .whitespaces)) }
        case .pasted:
            items = pastedEmails.map { (nil, $0) }
        }
        guard !items.isEmpty else {
            note = source == .leads ? "No leads with an email to verify." : "Paste at least one address first."
            return
        }
        // Demo convention (same as the send path): never fire live DNS against the synthetic
        // sample domains — skip MX and say so, instead of painting misleading reds.
        let mx = DemoMode.active ? false : requireMX
        note = (DemoMode.active && requireMX) ? "Demo mode — live MX lookups are skipped for sample data. Connect your own leads to run the full check." : ""
        running = true
        results = []; done = 0; total = items.count; loggedToTimeline = false
        verifyTask = Task { @MainActor in
            var mxCache: [String: Bool] = [:]
            var out: [VerificationResult] = []
            for item in items {
                if Task.isCancelled { break }
                let (v, n) = await EmailVerifier.verify(item.email, requireMX: mx, mxCache: &mxCache)
                out.append(VerificationResult(id: item.id ?? UUID(), email: item.email, verdict: v, note: n))
                results = out
                done = out.count
            }
            if Task.isCancelled && done < total {
                note = "Stopped after \(done) of \(total) — the verdicts above are complete for the addresses checked."
                total = done
            }
            running = false
        }
    }

    /// Record each CRM lead's verdict on its activity timeline (single batched save).
    private func logToTimelines() {
        let leadIDs = Set(model.leads.map { $0.id })
        model.batch {
            for r in results where leadIDs.contains(r.id) { model.recordVerification(r) }
        }
        loggedToTimeline = true
    }

    private func exportCSV() {
        func field(_ s: String) -> String {
            (s.contains(",") || s.contains("\"") || s.contains("\n"))
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
        }
        let header = "email,verdict,note"
        let rows = results.map { [field($0.email), field($0.verdict.label), field($0.note)].joined(separator: ",") }
        let csv = ([header] + rows).joined(separator: "\n") + "\n"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "verification-results.csv"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                note = "Exported \(url.lastPathComponent) (\(results.count) row\(results.count == 1 ? "" : "s"))."
            } catch {
                note = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}
#endif // circuit-convert
