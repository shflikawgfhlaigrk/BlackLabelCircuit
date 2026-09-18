#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Marketing — Brand Audit + SEO Toolkit screens.
// Both operate on the buyer's OWN site/URL via a real HTTP fetch (URLSession),
// analyzed deterministically. No fabricated metrics: a signal is present in the
// fetched HTML or it isn't; scores are a weighted fraction of real checks.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

// MARK: - shared severity colour

private func sevColor(_ s: Severity) -> Color {
    switch s { case .good: return BLTheme.green; case .warn: return BLTheme.gold; case .fail: return BLTheme.danger }
}
private func sevIcon(_ s: Severity) -> String {
    switch s { case .good: return "checkmark.circle.fill"; case .warn: return "exclamationmark.triangle.fill"; case .fail: return "xmark.octagon.fill" }
}

// MARK: - Brand Audit

struct BrandAuditScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs

    @State private var input = ""
    @State private var loading = false
    @State private var error = ""
    @State private var signals: PageSignals?
    @State private var items: [AuditItem] = []

    private var score: Int { AuditEngine.score(items) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "Brand Audit",
                             subtitle: "Score your brand strategy — positioning, messaging, and visual identity — into quick wins, then audit any live site's technical signals.")

                // Brand strategy (positioning / messaging / visual identity) from your own brand kit.
                let axes = BrandStrategyEngine.audit(BrandStrategyInput(
                    brandName: prefs.brandName, tagline: prefs.tagline, vertical: prefs.defaultVertical,
                    market: prefs.defaultMarket, hashtag: prefs.captionHashtag,
                    senderName: prefs.senderName, senderEmail: prefs.senderEmail,
                    hasLogo: prefs.logoData != nil, hasCustomColor: prefs.customAccentHex != 0,
                    extractedColors: prefs.brandColors.count))
                Panel(title: "Brand strategy · \(BrandStrategyEngine.overall(axes))/100", icon: "checkmark.seal.fill") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(axes) { ax in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(ax.name).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Spacer()
                                    Text("\(ax.score)/100").font(BLFonts.mono(11, weight: .semibold)).foregroundColor(ax.score >= 75 ? BLTheme.green : BLTheme.gold)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(BLTheme.bg2).frame(height: 7)
                                        Capsule().fill(BLTheme.goldGrad).frame(width: geo.size.width * CGFloat(ax.score) / 100, height: 7)
                                    }
                                }.frame(height: 7)
                                ForEach(ax.wins, id: \.self) { w in
                                    HStack(alignment: .top, spacing: 5) {
                                        Image(systemName: "arrow.up.forward.circle.fill").font(.system(size: 10)).foregroundColor(BLTheme.gold)
                                        Text(w).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        Text("Scored from your own brand kit (Settings). Fill the gaps above and the score rises — nothing is fabricated.")
                            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Panel(title: "Technical site audit", icon: "magnifyingglass.circle.fill") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Field(title: "Website URL", text: $input, prompt: "https://yoursite.com", onSubmit: run)
                            VStack { Spacer()
                                GoldButton(label: loading ? "Auditing…" : "Run audit", fill: false, icon: "bolt.fill") { run() }
                                    .disabled(loading || input.trimmingCharacters(in: .whitespaces).isEmpty)
                                    .opacity(loading || input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                            }
                        }
                        if loading {
                            HStack(spacing: 8) { ProgressView().controlSize(.small)
                                Text("Fetching and analyzing the live page…").font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub) }
                        }
                        if !error.isEmpty {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let s = prefs.defaultMarket.isEmpty ? nil : prefs.defaultMarket, signals == nil, !loading {
                            Text("Tip: audit your own site first to set a baseline — then audit prospects in \(s) to win the pitch.")
                                .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                    }
                }

                if let s = signals {
                    scoreCard(s)
                    quickWinsPanel
                    fullReport
                } else if !loading {
                    Panel(title: "How it works", icon: "info.circle.fill") {
                        EmptyState(icon: "chart.bar.doc.horizontal",
                                   title: "No audit yet",
                                   hint: "Enter a URL above and run an audit. Everything scored is read from the live page — nothing is estimated or invented.")
                    }
                }

                if !model.audits.isEmpty { history }
            }
            .padding(28)
        }
    }

    private func scoreCard(_ s: PageSignals) -> some View {
        Panel(title: "Score", icon: "gauge.high") {
            HStack(spacing: 22) {
                ZStack {
                    Circle().stroke(BLTheme.stroke, lineWidth: 10).frame(width: 116, height: 116)
                    Circle().trim(from: 0, to: CGFloat(score) / 100)
                        .stroke(AngularGradient(colors: [sevColor(score >= 80 ? .good : (score >= 55 ? .warn : .fail)), BLTheme.gold], center: .center),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 116, height: 116)
                        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: score)
                    VStack(spacing: 0) {
                        Text("\(score)").font(BLFonts.mono(34, weight: .heavy)).foregroundStyle(BLTheme.goldText)
                        Text("/ 100").font(.system(size: 10, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("Grade \(AuditEngine.grade(score))").font(BLFonts.display(22, weight: .semibold)).foregroundColor(BLTheme.text)
                        StatusPill(text: s.isHTTPS ? "HTTPS" : "HTTP", tint: s.isHTTPS ? BLTheme.green : BLTheme.danger)
                    }
                    Text(s.title.isEmpty ? "(no page title)" : s.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(2)
                    Text(s.finalURL).font(BLFonts.mono(10.5, weight: .medium)).foregroundColor(BLTheme.gold).lineLimit(1)
                    HStack(spacing: 14) {
                        miniStat("\(items.filter { $0.severity == .good }.count)", "PASS", BLTheme.green)
                        miniStat("\(items.filter { $0.severity == .warn }.count)", "WARN", BLTheme.gold)
                        miniStat("\(items.filter { $0.severity == .fail }.count)", "FAIL", BLTheme.danger)
                    }
                    GhostButton(label: "Export report (HTML)", icon: "square.and.arrow.up") { exportReport(s) }
                }
                Spacer()
            }
        }
    }
    private func miniStat(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(spacing: 1) {
            Text(v).font(BLFonts.mono(17, weight: .heavy)).foregroundColor(c)
            Text(l).font(.system(size: 8.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub).tracking(0.8)
        }
    }

    private var quickWinsPanel: some View {
        let wins = AuditEngine.quickWins(items)
        return Group {
            if wins.isEmpty {
                Panel(title: "Quick wins", icon: "checkmark.seal.fill") {
                    Label("No issues found — this page passes every check.", systemImage: "sparkles")
                        .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                }
            } else {
                Panel(title: "Quick wins (\(wins.count))", icon: "bolt.badge.clock.fill") {
                    VStack(spacing: 8) {
                        ForEach(Array(wins.enumerated()), id: \.element.id) { i, w in
                            HStack(spacing: 11) {
                                Text("\(i + 1)").font(BLFonts.mono(13, weight: .heavy)).foregroundColor(BLTheme.inkOnGold)
                                    .frame(width: 26, height: 26).background(BLTheme.goldGrad).clipShape(Circle())
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(w.label).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                                    Text(w.detail).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                StatusPill(text: "+\(w.weight)", tint: BLTheme.gold)
                            }
                            .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 11).stroke(sevColor(w.severity).opacity(0.3), lineWidth: 1))
                        }
                    }
                }
            }
        }
    }

    private var fullReport: some View {
        Panel(title: "Full report (\(items.count) checks)", icon: "list.bullet.clipboard.fill") {
            VStack(spacing: 7) {
                ForEach(items) { it in
                    HStack(spacing: 11) {
                        Image(systemName: sevIcon(it.severity)).font(.system(size: 14, weight: .bold)).foregroundColor(sevColor(it.severity)).frame(width: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(it.label).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                            Text(it.detail).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(9).background(BLTheme.bg2.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
        }
    }

    private var history: some View {
        Panel(title: "Audit history (\(model.audits.count))", icon: "clock.arrow.circlepath") {
            VStack(spacing: 8) {
                ForEach(model.audits) { a in
                    HStack(spacing: 11) {
                        Text("\(a.score)").font(BLFonts.mono(15, weight: .heavy))
                            .foregroundColor(a.score >= 80 ? BLTheme.green : (a.score >= 55 ? BLTheme.gold : BLTheme.danger))
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.url).font(.system(size: 12.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                            Text("\(a.failCount) fail · \(a.warnCount) warn · \(a.goodCount) pass · \(a.created.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10, design: .rounded)).foregroundColor(BLTheme.sub)
                        }
                        Spacer()
                        IconButton(system: "arrow.clockwise") { input = a.url; run() }
                        IconButton(system: "trash", tint: BLTheme.danger) { model.deleteAudit(a) }
                    }
                    .padding(10).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                }
            }
        }
    }

    private func run() {
        let raw = input
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        loading = true; error = ""
        Task {
            do {
                let s = try await PageFetcher.audit(raw)
                let computed = AuditEngine.items(s)
                await MainActor.run {
                    signals = s; items = computed; loading = false
                    model.logAudit(AuditRecord(url: s.finalURL, score: AuditEngine.score(computed), title: s.title,
                                               failCount: computed.filter { $0.severity == .fail }.count,
                                               warnCount: computed.filter { $0.severity == .warn }.count,
                                               goodCount: computed.filter { $0.severity == .good }.count))
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; loading = false; signals = nil; items = [] }
            }
        }
    }

    private func exportReport(_ s: PageSignals) {
        let rows = items.map { it in
            "<tr><td style=\"padding:8px 12px;color:\(it.severity == .good ? "#1a8f4a" : (it.severity == .warn ? "#b8923a" : "#c0392b"))\">\(it.severity.rawValue.uppercased())</td><td style=\"padding:8px 12px;font-weight:600\">\(SchemaEngine.esc(it.label))</td><td style=\"padding:8px 12px;color:#555\">\(SchemaEngine.esc(it.detail))</td></tr>"
        }.joined(separator: "\n")
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Brand Audit — \(SchemaEngine.esc(s.finalURL))</title></head>
        <body style="font-family:-apple-system,sans-serif;max-width:720px;margin:40px auto;color:#111">
        <h1 style="margin:0">Brand Audit</h1>
        <p style="color:#666">\(SchemaEngine.esc(s.finalURL))</p>
        <div style="font-size:48px;font-weight:800;color:#b8923a">\(score)/100 · Grade \(AuditEngine.grade(score))</div>
        <table style="width:100%;border-collapse:collapse;margin-top:20px;font-size:14px">\(rows)</table>
        <p style="color:#999;font-size:12px;margin-top:30px">Generated by \(SchemaEngine.esc(AppBrand.displayName)). Every signal read from the live page.</p>
        </body></html>
        """
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "brand-audit.html"
        if panel.runModal() == .OK, let url = panel.url {
            do { try html.write(to: url, atomically: true, encoding: .utf8) }
            catch {
                let a = NSAlert(); a.messageText = "Export failed"; a.informativeText = error.localizedDescription; a.runModal()
            }
        }
    }
}

// MARK: - SEO Toolkit (on-page checker · keyword ideas · schema generator)

struct SEOToolkitScreen: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: Prefs

    enum Tab: String, CaseIterable, Identifiable { case onPage = "On-page checker", keywords = "Keyword ideas", schema = "Schema generator"; var id: String { rawValue } }
    @State private var tab: Tab = .keywords

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScreenHeader(title: "SEO Toolkit",
                             subtitle: "Keyword ideas from your own services, a live on-page checker, and a copy-paste structured-data generator — the technical SEO foundation, all on-device.")
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().pickerStyle(.segmented).tint(BLTheme.gold)

                switch tab {
                case .onPage: OnPageChecker()
                case .keywords: KeywordTool()
                case .schema: SchemaTool()
                }
            }
            .padding(28)
        }
    }
}

// On-page checker reuses the real fetch + audit engine but presents per-element detail.
private struct OnPageChecker: View {
    @State private var input = ""
    @State private var loading = false
    @State private var error = ""
    @State private var s: PageSignals?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Panel(title: "Check a page", icon: "doc.text.magnifyingglass") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Field(title: "Page URL", text: $input, prompt: "https://yoursite.com/services", onSubmit: run)
                        VStack { Spacer()
                            GoldButton(label: loading ? "Checking…" : "Check", icon: "magnifyingglass") { run() }
                                .disabled(loading || input.trimmingCharacters(in: .whitespaces).isEmpty)
                                .opacity(loading || input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                        }
                    }
                    if loading { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Fetching page…").font(.system(size: 12, design: .rounded)).foregroundColor(BLTheme.sub) } }
                    if !error.isEmpty { Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.danger).fixedSize(horizontal: false, vertical: true) }
                }
            }
            if let s = s {
                Panel(title: "On-page elements", icon: "list.bullet.rectangle.fill") {
                    VStack(spacing: 10) {
                        elementRow("Title", s.title, ideal: "15–65 chars · \(s.title.count) now")
                        elementRow("Meta description", s.metaDescription, ideal: "50–165 chars · \(s.metaDescription.count) now")
                        elementRow("H1", s.h1s.first ?? "", ideal: s.h1s.count == 1 ? "Exactly one — good" : "\(s.h1s.count) found (use one)")
                        boolRow("Mobile viewport", s.hasViewport)
                        boolRow("Open Graph (social share)", s.hasOpenGraph)
                        boolRow("Twitter card", s.hasTwitterCard)
                        boolRow("Canonical URL", s.hasCanonical)
                        boolRow("Structured data (JSON-LD)", s.hasJSONLD)
                        countRow("Images", s.imgCount, badLabel: "\(s.imgMissingAlt) missing alt", bad: s.imgMissingAlt > 0)
                        countRow("Links", s.linkCount, badLabel: "", bad: false)
                        countRow("Visible words", s.wordCount, badLabel: s.wordCount < 300 ? "thin (<300)" : "", bad: s.wordCount < 300)
                    }
                }
            }
        }
    }
    private func elementRow(_ label: String, _ value: String, ideal: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack { Text(label.uppercased()).font(BLFonts.mono(9.5, weight: .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
                Spacer(); Text(ideal).font(.system(size: 9.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.gold) }
            Text(value.isEmpty ? "— missing —" : value).font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundColor(value.isEmpty ? BLTheme.danger : BLTheme.text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
    }
    private func boolRow(_ label: String, _ ok: Bool) -> some View {
        HStack { Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundColor(ok ? BLTheme.green : BLTheme.danger)
            Text(label).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text); Spacer()
            Text(ok ? "present" : "missing").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(ok ? BLTheme.green : BLTheme.danger) }
            .padding(9).background(BLTheme.bg2.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func countRow(_ label: String, _ n: Int, badLabel: String, bad: Bool) -> some View {
        HStack { Text(label).font(.system(size: 12.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text); Spacer()
            if bad && !badLabel.isEmpty { StatusPill(text: badLabel, tint: BLTheme.gold) }
            Text("\(n)").font(BLFonts.mono(14, weight: .heavy)).foregroundColor(BLTheme.gold) }
            .padding(9).background(BLTheme.bg2.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
    private func run() {
        let raw = input; guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        loading = true; error = ""
        Task {
            do { let r = try await PageFetcher.audit(raw); await MainActor.run { s = r; loading = false } }
            catch { await MainActor.run { self.error = error.localizedDescription; loading = false; s = nil } }
        }
    }
}

private struct KeywordTool: View {
    @EnvironmentObject var prefs: Prefs
    @State private var seed = ""
    @State private var city = ""
    @State private var copied = ""
    private var ideas: [String] { KeywordEngine.ideas(seed: seed, city: city.isEmpty ? prefs.defaultMarket : city) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Panel(title: "Keyword ideas", icon: "key.horizontal.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    Field(title: "Your service or product", text: $seed, prompt: prefs.defaultVertical.isEmpty ? "e.g. plumbing repair" : prefs.defaultVertical)
                    Field(title: "City / market (optional)", text: $city, prompt: prefs.defaultMarket.isEmpty ? "e.g. Austin" : prefs.defaultMarket)
                    Text("Ideas are built from your own seed term — location, intent, and buyer modifiers. We never invent search volumes (those require a paid keyword API you can connect later).")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
            if ideas.isEmpty {
                Panel(title: "Ideas", icon: "lightbulb.fill") {
                    EmptyState(icon: "key.horizontal", title: "Enter a service term", hint: "Type what you sell above and we'll generate location, intent, and buyer-modifier keyword variations.")
                }
            } else {
                Panel(title: "\(ideas.count) keyword ideas", icon: "lightbulb.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        GhostButton(label: copied == "all" ? "Copied!" : "Copy all", icon: "doc.on.doc") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ideas.joined(separator: "\n"), forType: .string)
                            copied = "all"; clearCopy()
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 8)], spacing: 8) {
                            ForEach(ideas, id: \.self) { kw in
                                Button {
                                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(kw, forType: .string); copied = kw; clearCopy()
                                } label: {
                                    HStack { Text(kw).font(.system(size: 12.5, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                                        Spacer(); Image(systemName: copied == kw ? "checkmark" : "doc.on.doc").font(.system(size: 10, weight: .bold)).foregroundColor(copied == kw ? BLTheme.green : BLTheme.sub) }
                                    .padding(9).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 9))
                                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }
    private func clearCopy() { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = "" } }
}

private struct SchemaTool: View {
    @EnvironmentObject var prefs: Prefs
    @State private var name = ""
    @State private var type = ""
    @State private var phone = ""
    @State private var city = ""
    @State private var url = ""
    @State private var copied = false
    private var snippet: String { SchemaEngine.localBusiness(name: name.isEmpty ? prefs.brandName : name, type: type, phone: phone, city: city.isEmpty ? prefs.defaultMarket : city, url: url) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Panel(title: "LocalBusiness schema", icon: "chevron.left.forwardslash.chevron.right") {
                VStack(alignment: .leading, spacing: 10) {
                    Field(title: "Business name", text: $name, prompt: prefs.brandName.isEmpty ? "Summit Plumbing" : prefs.brandName)
                    Field(title: "Type / description", text: $type, prompt: "Plumber serving the Austin area")
                    Field(title: "Phone", text: $phone, prompt: "(512) 555-0100")
                    Field(title: "City", text: $city, prompt: prefs.defaultMarket.isEmpty ? "Austin" : prefs.defaultMarket)
                    Field(title: "Website URL", text: $url, prompt: "https://summitplumbing.com")
                    Text("Paste this into the <head> of your site to enable rich results in Google and citation by AI answer engines. All fields are escaped — safe to embed.")
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
            Panel(title: "Generated JSON-LD", icon: "doc.plaintext.fill") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(snippet).font(BLFonts.mono(11, weight: .medium)).foregroundColor(BLTheme.green)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color.black.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                    HStack(spacing: 10) {
                        GoldButton(label: copied ? "Copied!" : "Copy snippet", icon: "doc.on.doc") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(snippet, forType: .string)
                            copied = true; DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                        }
                        GhostButton(label: "Export .html", icon: "square.and.arrow.up") {
                            let panel = NSSavePanel(); panel.allowedContentTypes = [.html]; panel.nameFieldStringValue = "schema.html"
                            if panel.runModal() == .OK, let u = panel.url {
                                do { try snippet.write(to: u, atomically: true, encoding: .utf8) }
                                catch {
                                    let a = NSAlert(); a.messageText = "Export failed"; a.informativeText = error.localizedDescription; a.runModal()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
#endif // circuit-convert
