#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Sovereign — Activity Log screen: the buyer's reviewable, searchable, exportable
// PROOF-OF-EXECUTION ledger. Every row is a real receipt written by the live runtime,
// agent, skills, or reminder path — never narrated, never seeded. Filter by kind/outcome,
// free-text search, expand a row to read the full real output/error, export to Markdown.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif

/// SV-19 — the "needs review" inbox copy, pinned in one place so the tests assert the exact,
/// honest strings the buyer reads (and that they never over-claim what's waiting).
enum ReviewInboxCopy {
    static let title = "Needs review"
    static let subtitle = "Runs that finished while you were away. Review each one, then mark it seen — the receipt stays in your log as proof."
    static let markReviewed = "Mark reviewed"
    static let markAll = "Mark all reviewed"
    static let emptyTitle = "You're all caught up"
    static let emptyHint = "When a scheduled, unattended run finishes, it leaves one item here so you can review what it did. Nothing is waiting right now."
}

struct ActivityScreen: View {
    @EnvironmentObject var activity: ActivityLog
    @EnvironmentObject var crm: ClientStore
    @EnvironmentObject var memory: MemoryStore
    @EnvironmentObject var voice: VoiceEngine
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var nav: Nav

    @State private var showDigest = false
    @State private var showReview = false   // SV-19: the "needs review" walk-away inbox sheet
    @State private var search = ""
    @State private var kindFilter: ActivityKind? = nil
    @State private var outcomeFilter: ActivityOutcome? = nil
    @State private var expanded: Set<UUID> = []
    @State private var detail: ActivityEntry?
    @State private var confirmClear = false
    // Date-range filter (Gap 4): a small set of presets + a custom span scope the ledger by time.
    @State private var datePreset: DatePreset = .all
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var customEnd = Date()
    // Deep-link highlight (Gap 4): the row ⌘K jumped to, briefly ringed + scrolled into view.
    @State private var highlighted: UUID? = nil

    enum DatePreset: String, CaseIterable, Identifiable {
        case all = "All time", today = "Today", week = "Last 7 days", month = "Last 30 days", custom = "Custom"
        var id: String { rawValue }
    }

    /// The active date window from the preset/custom selection.
    private var dateRange: ActivityLog.DateRange {
        let cal = Calendar.current; let now = Date()
        switch datePreset {
        case .all:    return .init()
        case .today:  return .init(start: cal.startOfDay(for: now), end: now)
        case .week:   return .init(start: cal.date(byAdding: .day, value: -7, to: now), end: now)
        case .month:  return .init(start: cal.date(byAdding: .day, value: -30, to: now), end: now)
        case .custom: return .init(start: cal.startOfDay(for: customStart),
                                   end: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: customEnd)).map { $0.addingTimeInterval(-1) } ?? customEnd)
        }
    }
    /// Human description of the current scope, written into the scoped export header.
    private var scopeNote: String {
        var parts: [String] = []
        if datePreset != .all { parts.append("date: \(datePreset.rawValue.lowercased())") }
        if let k = kindFilter { parts.append("kind: \(k.label)") }
        if let o = outcomeFilter { parts.append("outcome: \(o.label)") }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count >= 2 { parts.append("search: “\(q)”") }
        return parts.isEmpty ? "" : parts.joined(separator: ", ")
    }
    /// Whether ANY scoping is active — drives the "Export filtered" affordance.
    private var isScoped: Bool { !scopeNote.isEmpty }

    private var rows: [ActivityEntry] { activity.filtered(kind: kindFilter, outcome: outcomeFilter, query: search, range: dateRange) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            controls
            Divider().background(BLTheme.stroke).padding(.horizontal, 24).padding(.top, 4)
            content
        }
        .sheet(item: $detail) { e in detailSheet(e).sheetCloseBar() }
        .sheet(isPresented: $showDigest, onDismiss: { voice.stop() }) { digestSheet().sheetCloseBar() }
        .sheet(isPresented: $showReview) { reviewSheet().sheetCloseBar() }
        .alert("Clear the entire activity log?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { withAnimation { activity.clear(); expanded = [] } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every recorded receipt from this device. It cannot be undone.")
        }
        // Deep-link: when ⌘K targets a receipt, clear filters that would hide it, expand it,
        // scroll to it, and ring it briefly. Handled in `content` via ScrollViewReader.
        .onAppear { consumeDeepLink() }
        .onChange(of: nav.activityTarget) { _ in consumeDeepLink() }
    }

    /// Make a deep-linked receipt visible: drop filters that could hide it and open it.
    private func consumeDeepLink() {
        guard let id = nav.activityTarget else { return }
        guard activity.topLevel.contains(where: { $0.id == id }) else { nav.activityTarget = nil; return }
        // Reset scoping so the target row is guaranteed to be in `rows`.
        search = ""; kindFilter = nil; outcomeFilter = nil; datePreset = .all
        expanded.insert(id)
        highlighted = id
    }

    // MARK: Header + live, honest summary

    private var header: some View {
        HStack(alignment: .top) {
            ScreenTitle(title: "Activity", subtitle: "Proof of execution — every real action your operator took, on your machine")
            Spacer()
            HStack(spacing: 8) {
                // SV-19: the walk-away review inbox. Always reachable (so the buyer can check even when
                // empty); the live pending count rides along as a badge when there's something waiting.
                Button { showReview = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full.fill").font(.system(size: 11, weight: .bold))
                        Text(ReviewInboxCopy.title).font(.system(size: 12, weight: .semibold, design: .rounded))
                        if activity.pendingReviewCount > 0 {
                            Text("\(activity.pendingReviewCount)")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundColor(BLTheme.ink)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(BLTheme.gold).clipShape(Capsule())
                        }
                    }
                    .foregroundColor(activity.pendingReviewCount > 0 ? BLTheme.gold : BLTheme.sub)
                    .padding(.vertical, 6).padding(.horizontal, 11)
                    .background(BLTheme.bg2).clipShape(Capsule())
                    .overlay(Capsule().stroke(activity.pendingReviewCount > 0 ? BLTheme.gold.opacity(0.5) : BLTheme.stroke, lineWidth: 1))
                }.buttonStyle(.plain)
                GhostButton(label: "What moved today", icon: "sun.max.fill", tint: BLTheme.gold) { showDigest = true }
                if isScoped {
                    GhostButton(label: "Export filtered", icon: "line.3.horizontal.decrease.circle") { export(scoped: true) }
                        .disabled(rows.isEmpty).opacity(rows.isEmpty ? 0.5 : 1)
                }
                GhostButton(label: "Export all…", icon: "square.and.arrow.up") { export(scoped: false) }
                    .disabled(activity.isEmpty).opacity(activity.isEmpty ? 0.5 : 1)
                GhostButton(label: "Clear", icon: "trash", tint: .orange) { confirmClear = true }
                    .disabled(activity.isEmpty).opacity(activity.isEmpty ? 0.5 : 1)
            }
        }.padding(24).padding(.bottom, 6)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Live counts — read straight from the ledger, nothing simulated.
            HStack(spacing: 8) {
                summaryPill("\(activity.entries.count)", "receipts", BLTheme.gold)
                summaryPill("\(activity.successCount)", "succeeded", BLTheme.green)
                summaryPill("\(activity.failureCount)", "failed", .orange)
            }
            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                TextField("Search activity (title or output)", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12.5, design: .rounded)).foregroundColor(BLTheme.text)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.sub) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    chip("All", selected: kindFilter == nil && outcomeFilter == nil) { kindFilter = nil; outcomeFilter = nil }
                    ForEach(ActivityKind.allCases) { k in
                        chip(k.label, icon: k.icon, selected: kindFilter == k, count: activity.count(of: k)) {
                            kindFilter = (kindFilter == k) ? nil : k
                        }
                    }
                    Divider().frame(height: 16).background(BLTheme.stroke)
                    chip("Succeeded", selected: outcomeFilter == .success, tint: BLTheme.green) { outcomeFilter = (outcomeFilter == .success) ? nil : .success }
                    chip("Failed", selected: outcomeFilter == .failure, tint: .orange) { outcomeFilter = (outcomeFilter == .failure) ? nil : .failure }
                }
            }
            // Date-range filter row.
            HStack(spacing: 7) {
                Image(systemName: "calendar").font(.system(size: 10.5, weight: .bold)).foregroundColor(BLTheme.sub)
                ForEach(DatePreset.allCases) { p in
                    chip(p.rawValue, selected: datePreset == p, tint: BLTheme.champagne) { datePreset = p }
                }
                if datePreset == .custom {
                    DatePicker("", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                        .labelsHidden().compactFieldDatePicker()
                    Text("→").font(.system(size: 11)).foregroundColor(BLTheme.sub)
                    DatePicker("", selection: $customEnd, in: customStart...Date(), displayedComponents: .date)
                        .labelsHidden().compactFieldDatePicker()
                }
            }
        }.padding(.horizontal, 24).padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if activity.isEmpty {
            VStack {
                Spacer()
                EmptyState(icon: "checklist.checked",
                           title: "No activity yet",
                           hint: "When an automation runs, an agent completes a task, you run a skill, or a reminder fires, a real receipt appears here — with the actual output and a timestamp. Nothing is ever invented.")
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if rows.isEmpty {
            VStack {
                Spacer()
                EmptyState(icon: "line.3.horizontal.decrease.circle",
                           title: "No matching receipts",
                           hint: "No activity matches your current search and filters. Clear them to see the full ledger.")
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(rows) { e in row(e).id(e.id) }
                    }.padding(24).padding(.top, 8)
                }
                .onChange(of: highlighted) { target in scrollTo(target, proxy: proxy) }
                .onAppear { scrollTo(highlighted, proxy: proxy) }
            }
        }
    }

    /// Scroll a deep-linked row into view, then fade the highlight ring after a beat. Clears the
    /// nav target so re-entering the screen doesn't re-trigger.
    private func scrollTo(_ target: UUID?, proxy: ScrollViewProxy) {
        guard let id = target else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { proxy.scrollTo(id, anchor: .center) }
        }
        nav.activityTarget = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeOut(duration: 0.5)) { if highlighted == id { highlighted = nil } }
        }
    }

    // MARK: Row

    @ViewBuilder private func row(_ e: ActivityEntry) -> some View {
        let isOpen = expanded.contains(e.id)
        let isHot = highlighted == e.id
        HoloCard(cornerRadius: 14, sweep: false, padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        if isOpen { expanded.remove(e.id) } else { expanded.insert(e.id) }
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: e.kind.icon).font(.system(size: 13, weight: .bold))
                            .foregroundColor(e.outcome.tint)
                            .frame(width: 34, height: 34)
                            .background(e.outcome.tint.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Text(e.kind.label.uppercased()).font(.system(size: 9, weight: .bold, design: .rounded))
                                    .foregroundColor(BLTheme.sub).tracking(0.8)
                                StatusPill(text: e.outcome.label, tint: e.outcome.tint)
                            }
                            Text(e.title).font(.system(size: 13.5, weight: .semibold, design: .rounded))
                                .foregroundColor(BLTheme.text).lineLimit(1)
                            if !isOpen {
                                Text(e.snippet).font(.system(size: 11.5, design: .rounded))
                                    .foregroundColor(BLTheme.sub).lineLimit(1)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(e.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.system(size: 10.5, design: .monospaced)).foregroundColor(BLTheme.sub)
                            HStack(spacing: 6) {
                                if let ms = e.durationMS { metaTag("\(ms) ms") }
                                if let n = e.stepCount { metaTag("\(n) step\(n == 1 ? "" : "s")") }
                            }
                        }
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.sub)
                    }
                    .padding(14).contentShape(Rectangle())
                }.buttonStyle(.plain)

                if isOpen {
                    Divider().background(BLTheme.stroke).padding(.horizontal, 14)
                    VStack(alignment: .leading, spacing: 10) {
                        ScrollView { MarkdownView(text: e.detail.isEmpty ? "(no output)" : e.detail)
                            .frame(maxWidth: .infinity, alignment: .leading) }
                            .frame(maxHeight: 220)
                        // Real agent step trace (Gap 1): every recorded tool call + its observation.
                        let trace = activity.steps(of: e.id)
                        if !trace.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("EXECUTION TRACE · \(trace.count) STEP\(trace.count == 1 ? "" : "S")")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(BLTheme.sub).tracking(0.8)
                                ForEach(Array(trace.enumerated()), id: \.element.id) { i, s in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text("\(i + 1)").font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                            .foregroundColor(BLTheme.ink).frame(width: 18, height: 18)
                                            .background(BLTheme.champagne).clipShape(Circle())
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(s.title).font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                                            Text(s.snippet).font(.system(size: 10.5, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(3)
                                        }
                                        Spacer()
                                    }
                                }
                            }
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                        }
                        HStack(spacing: 8) {
                            GhostButton(label: "Copy output", icon: "doc.on.doc") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(e.detail, forType: .string)
                            }
                            GhostButton(label: "Open", icon: "arrow.up.left.and.arrow.down.right") { detail = e }
                            Spacer()
                            GhostButton(label: "Delete", icon: "trash", tint: .orange) {
                                withAnimation { activity.delete(e.id); expanded.remove(e.id) }
                            }
                        }
                    }.padding(14)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(BLTheme.gold, lineWidth: isHot ? 2 : 0)
                .shadow(color: isHot ? BLTheme.gold.opacity(0.5) : .clear, radius: isHot ? 10 : 0)
                .animation(.easeOut(duration: 0.3), value: isHot)
                .allowsHitTesting(false)
        )
    }

    private func detailSheet(_ e: ActivityEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: e.kind.icon).font(.system(size: 15, weight: .bold)).foregroundColor(e.outcome.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.title).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text("\(e.kind.label) · \(e.at.formatted(date: .complete, time: .standard))")
                        .font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                StatusPill(text: e.outcome.label, tint: e.outcome.tint)
            }
            ScrollView { MarkdownView(text: e.detail.isEmpty ? "(no output)" : e.detail)
                .frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 360)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
            HStack {
                GhostButton(label: "Copy", icon: "doc.on.doc") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(e.detail, forType: .string)
                }
                Spacer()
            }
        }.padding(24).sheetWidth(600).background(BLTheme.bg)
    }

    // MARK: What moved today (daily digest + spoken readback)

    /// Build the digest fresh from the live stores so it reflects the moment it's opened.
    private func buildDigest() -> DailyDigest.Summary {
        DailyDigest.build(activity: activity.entries, clients: crm.clients,
                          deals: crm.deals, memories: memory.items)
    }

    /// The "what moved today?" sheet: the real digest, with a button to read it aloud through the
    /// existing on-device Voice engine — exactly the spoken readback the website promises.
    private func digestSheet() -> some View {
        let s = buildDigest()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sun.max.fill").font(.system(size: 15, weight: .bold)).foregroundColor(BLTheme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What moved today").font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(s.dayLabel).font(.system(size: 11, design: .monospaced)).foregroundColor(BLTheme.sub)
                }
                Spacer()
                StatusPill(text: s.isEmpty ? "Quiet" : "Active", tint: s.isEmpty ? BLTheme.sub : BLTheme.green)
            }
            ScrollView { MarkdownView(text: s.detailText).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 300)
                .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
            HStack(spacing: 8) {
                if voice.speaking {
                    GhostButton(label: "Stop", icon: "stop.fill", tint: BLTheme.danger) { voice.stop() }
                } else {
                    GhostButton(label: "Read aloud", icon: "speaker.wave.2.fill", tint: BLTheme.gold) {
                        voice.speak(s.spoken, voiceID: settings.voiceIdentifier)
                    }
                }
                Spacer()
                Text(s.headline).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(BLTheme.sub).lineLimit(1)
            }
        }.padding(24).sheetWidth(560).background(BLTheme.bg)
    }

    // MARK: SV-19 — the "needs review" walk-away inbox

    /// The review inbox: every completed UNATTENDED run still awaiting a look (newest first), each
    /// markable as reviewed — which drops it from the inbox but KEEPS the receipt as proof. When the
    /// inbox is empty it shows an honest "all caught up" state, never a fabricated pending item.
    private func reviewSheet() -> some View {
        let pending = activity.reviewInbox
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "tray.full.fill").font(.system(size: 15, weight: .bold)).foregroundColor(BLTheme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReviewInboxCopy.title).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(ReviewInboxCopy.subtitle).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !pending.isEmpty {
                    StatusPill(text: "\(pending.count) waiting", tint: BLTheme.gold)
                }
            }
            if pending.isEmpty {
                VStack {
                    Spacer(minLength: 30)
                    EmptyState(icon: "checkmark.circle", title: ReviewInboxCopy.emptyTitle, hint: ReviewInboxCopy.emptyHint)
                    Spacer(minLength: 30)
                }.frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(pending) { e in reviewRow(e) }
                    }
                }.frame(maxHeight: 360)
                HStack {
                    Spacer()
                    GhostButton(label: ReviewInboxCopy.markAll, icon: "checkmark.circle.fill", tint: BLTheme.green) {
                        withAnimation { for e in pending { activity.markReviewed(e.id) } }
                    }
                }
            }
        }.padding(24).sheetWidth(580).background(BLTheme.bg)
    }

    private func reviewRow(_ e: ActivityEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: e.kind.icon).font(.system(size: 13, weight: .bold)).foregroundColor(e.outcome.tint)
                .frame(width: 30, height: 30)
                .background(e.outcome.tint.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text).lineLimit(1)
                Text(e.snippet).font(.system(size: 11, design: .rounded)).foregroundColor(BLTheme.sub).lineLimit(2)
                Text(e.at.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 9.5, design: .monospaced)).foregroundColor(BLTheme.sub)
            }
            Spacer()
            GhostButton(label: ReviewInboxCopy.markReviewed, icon: "checkmark.circle", tint: BLTheme.green) {
                withAnimation { activity.markReviewed(e.id) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: Bits

    private func summaryPill(_ value: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(value).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundColor(tint)
            Text(label).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(BLTheme.sub)
        }
        .padding(.vertical, 5).padding(.horizontal, 11)
        .background(BLTheme.bg2).clipShape(Capsule())
        .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
    }

    private func metaTag(_ s: String) -> some View {
        Text(s).font(.system(size: 9.5, design: .monospaced)).foregroundColor(BLTheme.sub)
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func chip(_ label: String, icon: String = "", selected: Bool, count: Int? = nil,
                      tint: Color = BLTheme.gold, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if !icon.isEmpty { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
                Text(label).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                if let c = count, c > 0 {
                    Text("\(c)").font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(selected ? BLTheme.ink.opacity(0.7) : BLTheme.sub)
                }
            }
            .foregroundColor(selected ? BLTheme.ink : BLTheme.text)
            .padding(.vertical, 6).padding(.horizontal, 11)
            .background(selected ? AnyShapeStyle(tint) : AnyShapeStyle(BLTheme.bg2))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(selected ? .clear : BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func export(scoped: Bool) {
        let suffix = scoped ? "Filtered" : "All"
        let name = "Sovereign-Activity-\(suffix)-\(Date().formatted(.iso8601.year().month().day())).md"
        let md = scoped ? activity.exportMarkdown(rows, scopeNote: scopeNote) : activity.exportMarkdown()
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            try? md.data(using: .utf8)?.write(to: url)
        }
        #else
        iosExportText(md, suggestedName: name)
        #endif
    }
}
#endif // circuit-convert
