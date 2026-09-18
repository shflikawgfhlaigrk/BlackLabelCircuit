#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Academy — UI. Custom 3-pane layout for full holographic control.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(CoreSpotlight) && !CIRCUIT_WINDOWS_SIM
import CoreSpotlight
#endif
#if canImport(AppKit)
import AppKit
typealias BLImage = NSImage
#elseif canImport(UIKit)
import UIKit
typealias BLImage = UIImage
#endif

// Cross-platform Image initializer (NSImage on macOS, UIImage on iOS).
extension Image {
    init(blImage: BLImage) {
        #if canImport(AppKit)
        self.init(nsImage: blImage)
        #else
        self.init(uiImage: blImage)
        #endif
    }
}

func appIcon() -> BLImage? {
    #if canImport(AppKit)
    if let p = Bundle.main.resourcePath, let img = NSImage(contentsOfFile: p + "/AppIcon.icns") { return img }
    return NSImage(named: "AppIcon")
    #else
    return UIImage(named: "AppIcon")
    #endif
}

struct RootView: View {
    @StateObject private var model = AppModel()
    @State private var section: LibrarySection = .pillar(.niches)
    @State private var entry: Entry?
    @State private var showSettings = false
    @State private var showCertificates = false
    @State private var showCalculators = false
    // AC-19 Daily Review (spaced repetition) + AC-20 Library Tutor surfaces.
    @State private var showRecall = false
    @State private var showTutor = false
    // AC-21: the "Review Due Cards" App Intent (Spotlight/Shortcuts) flips this router; RootView opens
    // Daily Review in response, so an OS-native invocation lands the buyer straight in the review.
    @ObservedObject private var reviewRouter = DailyReviewRouter.shared
    // Resume-last-lesson runs exactly once per launch, before any manual navigation.
    @State private var didResume = false
    #if os(macOS) && !MAS_BUILD
    // First-run onboarding: a one-time guided welcome. The flag defaults to unseen (false), so the
    // tour shows once on first launch and never again after it is dismissed. macOS-only — the tour
    // names the 7-day trial / $30-mo offer and the config-driven checkout, none of which exist on
    // the iOS build (App Store Guideline 3.1.1: no purchase UI outside StoreKit).
    @AppStorage("bl.academy.onboarded") private var onboarded = false
    @State private var showOnboarding = false
    #endif

    var body: some View {
        Group {
            #if os(macOS) && !MAS_BUILD
            if model.isEntitled {
                platformBody
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if case .trial = model.entitlement { TrialBanner(model: model) }
                    }
            } else {
                PaywallView(model: model)   // hard gate: trial expired, not subscribed (macOS only)
            }
            #else
            // iOS ships the full library FREE — no trial, no paywall, no external checkout,
            // no subscription UI at all (App Store Guideline 3.1.1).
            platformBody
            #endif
        }
        .sheet(isPresented: $showSettings) { SettingsSheet(model: model) }
        .sheet(isPresented: $showCertificates) { CertificatesSheet(model: model) }
        .sheet(isPresented: $showCalculators) { CalculatorsSheet() }
        .sheet(isPresented: $showRecall) { DailyReviewSheet(model: model, openEntry: openEntryFromID) }
        .sheet(isPresented: $showTutor) { LibraryTutorSheet(model: model, openEntry: openEntryFromID) }
        .preferredColorScheme(.dark)
        // Resume-last-lesson (both targets): reopen the last read lesson on launch, and record every
        // opened lesson so the next launch can resume it. Runs once, before any manual navigation.
        .onAppear { resumeIfNeeded() }
        // AC-18: keep the OS Spotlight index in lockstep with the served library (rebuilt on launch
        // and after an in-app content update), and open the lesson when the buyer taps a Spotlight hit.
        .onAppear { SpotlightIndexer.reindex(model.entries) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            openFromSpotlight(activity)
        }
        // AC-21: the "Review Due Cards" App Intent asked to open Daily Review — present it and reset.
        .onChangeCompat(of: reviewRouter.openRequested) { requested in
            if requested { showRecall = true; reviewRouter.openRequested = false }
        }
        .onChangeCompat(of: entry) { newValue in
            if let e = newValue { model.recordOpened(e) }
        }
        #if os(macOS) && !MAS_BUILD
        // Re-check the trial clock whenever the app returns to the foreground; surface the first-run
        // tour once if it has not been seen yet.
        .onAppear {
            model.trial.refresh()
            if !onboarded { showOnboarding = true }
            // Updates + new content are gated to active entitlements. A paid-then-canceled (lapsed)
            // reader keeps the on-device library (AC-12) but stops receiving new lessons until they
            // resubscribe — so the automatic update check only runs when the account can receive them.
            if model.entitlement.canReceiveUpdates { UpdaterUI.checkInBackgroundIfDue() }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(model: model) { onboarded = true; showOnboarding = false }
        }
        #endif
    }

    #if os(iOS)
    private var platformBody: some View {
        CompactRoot(model: model, section: $section, entry: $entry,
                    showSettings: $showSettings, showCertificates: $showCertificates,
                    showCalculators: $showCalculators, showRecall: $showRecall, showTutor: $showTutor)
    }
    #else
    private var platformBody: some View {
        ZStack {
            AuroraBackdrop()
            HStack(spacing: 0) {
                Sidebar(model: model, section: $section, entry: $entry,
                        showSettings: $showSettings, showCertificates: $showCertificates,
                        showCalculators: $showCalculators, showRecall: $showRecall, showTutor: $showTutor)
                    .frame(width: 248)
                Divider().overlay(BLTheme.line)
                EntryList(model: model, section: section, entry: $entry)
                    .frame(width: 330)
                Divider().overlay(BLTheme.line)
                Group {
                    if let e = entry {
                        #if MAS_BUILD
                        // b102 access gate, same rule as iOS: a locked lesson renders the paywall
                        // in the reader pane. Live — completing the purchase re-evaluates it and
                        // the lesson appears in place.
                        if model.isUnlocked(e) {
                            EntryReader(entry: e, model: model)
                        } else {
                            StorePaywall(model: model, lockedTitle: e.title)
                        }
                        #else
                        EntryReader(entry: e, model: model)
                        #endif
                    } else {
                        EmptyState(icon: "sparkles", title: "Black Label Academy",
                                   hint: "Choose a pillar, then open an entry. Learn the business and the build — honestly, with every number sourced.")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1060, minHeight: 700)
    }
    #endif

    /// Auto-select the last-opened lesson exactly once on launch, moving the sidebar to its pillar
    /// so the reader restores where the buyer left off. No-op on a first-ever launch (no history).
    private func resumeIfNeeded() {
        guard !didResume else { return }
        didResume = true
        #if os(iOS)
        // Purchase-lane hermeticity: the UI tests launch with this argument so a resume push
        // from a previous run's state can never sit between the test and the home surface.
        // Test-only escape hatch — it disables nothing but the auto-resume navigation.
        if ProcessInfo.processInfo.arguments.contains("-bl-uitest-no-resume") { return }
        #endif
        guard let e = model.resumeEntry else { return }
        #if os(iOS)
        // b21: never resume into a lesson the current tier can't open (e.g. the subscription
        // lapsed since last launch) — home is the honest landing, not a paywall ambush.
        guard model.isUnlocked(e) else { return }
        #endif
        section = .pillar(Pillar(rawValue: e.pillar) ?? .niches)
        entry = e
    }

    /// Deep-link from a Spotlight search hit (AC-18): resolve the tapped lesson id and open it in
    /// the reader, moving the sidebar to its pillar. Ignores unknown/stale ids.
    private func openFromSpotlight(_ activity: NSUserActivity) {
        guard let id = SpotlightIndexer.lessonID(from: activity.userInfo),
              let e = model.entries.first(where: { $0.id == id }) else { return }
        section = .pillar(Pillar(rawValue: e.pillar) ?? .niches)
        entry = e
        model.recordOpened(e)
    }

    /// Open a lesson by id from a sheet (Daily Review card / Tutor citation): dismiss the sheet, move
    /// the sidebar to the lesson's pillar, and open the reader. Ignores unknown ids.
    private func openEntryFromID(_ id: String) {
        guard let e = model.entries.first(where: { $0.id == id }) else { return }
        showRecall = false; showTutor = false
        section = .pillar(Pillar(rawValue: e.pillar) ?? .niches)
        entry = e
        model.recordOpened(e)
    }
}

struct Sidebar: View {
    @ObservedObject var model: AppModel
    @Binding var section: LibrarySection
    @Binding var entry: Entry?
    @Binding var showSettings: Bool
    @Binding var showCertificates: Bool
    @Binding var showCalculators: Bool
    @Binding var showRecall: Bool
    @Binding var showTutor: Bool
    #if MAS_BUILD
    @State private var showUnlock = false
    #endif

    // Access badge reflects the REAL entitlement on macOS (7-day trial → $30/mo): during the trial
    // it counts down, once subscribed it says so. iOS ships the full library free, so it honestly
    // reads "Free · full library" there. Replaces a permanent hardcoded "Free · full library" that
    // contradicted the trial banner + paywall a paying macOS buyer actually sees (§5.1 honesty).
    private var accessBadgeText: String {
        #if os(macOS) && !MAS_BUILD
        switch model.entitlement {
        case .subscribed: return "Subscribed · full library"
        case .trial(let n): return "Free trial · \(n) day\(n == 1 ? "" : "s") left"
        case .lapsed: return "Canceled · your library stays yours"
        case .expired: return "Trial ended · subscribe"
        }
        #elseif MAS_BUILD
        // b102: counts computed from the loaded library, never a literal — and never the old
        // "Free · full library", which stopped being true the moment this build gained a paywall.
        return model.isSubscribed
            ? "Subscribed · full library"
            : "Free · \(model.freeLessonIDs.count) of \(model.totalCount) lessons + all tools"
        #else
        return "Free · full library"
        #endif
    }
    private var accessBadgeIcon: String {
        #if os(macOS) && !MAS_BUILD
        switch model.entitlement {
        case .subscribed: return "checkmark.seal.fill"
        case .trial: return "hourglass"
        case .lapsed: return "externaldrive.fill.badge.checkmark"
        case .expired: return "lock.fill"
        }
        #elseif MAS_BUILD
        return model.isSubscribed ? "checkmark.seal.fill" : "lock.open"
        #else
        return "checkmark.seal.fill"
        #endif
    }
    private var accessBadgeColor: Color {
        #if os(macOS) && !MAS_BUILD
        switch model.entitlement {
        case .subscribed: return BLTheme.green
        case .trial: return BLTheme.goldLite
        case .lapsed: return BLTheme.goldLite
        case .expired: return BLTheme.red
        }
        #else
        return BLTheme.green
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let img = appIcon() {
                    Image(blImage: img).resizable().frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("BLACK LABEL").font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundColor(BLTheme.sub).tracking(2)
                    FoilText(text: "Academy", size: 20)
                }
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 6)

            // Owner-positioning line (AC-15, founder-approved). H4 ban holds: never frame it as beating a degree.
            Text("Degrees train employees. This trains owners.")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 12)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(BLTheme.sub).font(.system(size: 12))
                TextField("Search the library", text: $model.query)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundColor(BLTheme.text)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(BLTheme.sub)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.stroke, lineWidth: 1))
            .padding(.horizontal, 14).padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 4) {
                    LibrarySectionRow(section: .newThisMonth,
                                      count: model.count(.newThisMonth),
                                      completed: model.completedCount(for: .newThisMonth),
                                      selected: section == .newThisMonth) {
                        model.query = ""; section = .newThisMonth; entry = nil
                    }
                    Divider().overlay(BLTheme.line).padding(.vertical, 5)
                    ForEach(Pillar.allCases) { p in
                        let librarySection = LibrarySection.pillar(p)
                        LibrarySectionRow(section: librarySection,
                                          count: model.count(librarySection),
                                          completed: model.completedCount(for: librarySection),
                                          selected: section == librarySection && model.query.isEmpty) {
                            model.query = ""; section = librarySection; entry = nil
                        }
                    }
                }
                .padding(.horizontal, 10)
            }

            Spacer(minLength: 0)
            Divider().overlay(BLTheme.line)
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: accessBadgeIcon)
                        .foregroundColor(accessBadgeColor).font(.system(size: 12))
                    Text(accessBadgeText)
                        .font(.system(size: 11.5, weight: .medium)).foregroundColor(BLTheme.sub)
                    Spacer()
                    #if MAS_BUILD
                    // The purchase has to be reachable without hunting through Settings.
                    if !model.isSubscribed {
                        Button { showUnlock = true } label: {
                            Text("Unlock").font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundColor(.black)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(BLTheme.goldGrad, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bl.unlock.banner")
                    }
                    #endif
                }
                ReceiptsBadge(model: model, compact: true)
                ProgressSummary(completed: model.completedCount, total: model.totalCount)
                // AC-19 Daily Review (spaced repetition) — badges the count of recall cards due now.
                Button { showRecall = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "brain.head.profile")
                        Text("Daily Review")
                        Spacer()
                        let due = model.recall.dueCount
                        if due > 0 {
                            Text("\(due)")
                                .font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.bg)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(BLTheme.goldLite, in: Capsule())
                        }
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundColor(BLTheme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                // AC-21 study habit — honest self-set streak + "due today", both from real data.
                StudyHabitStrip(model: model)
                // AC-20 grounded Library Tutor — cite-or-refuse Q&A over the bundled library.
                Button { showTutor = true } label: {
                    HStack(spacing: 6) { Image(systemName: "text.magnifyingglass"); Text("Library Tutor") }
                        .font(.system(size: 12, weight: .medium)).foregroundColor(BLTheme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button { showCertificates = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "rosette")
                        Text("Certificates")
                        Spacer()
                        let unlocked = model.certificateStatuses.filter(\.unlocked).count
                        if unlocked > 0 {
                            Text("\(unlocked)")
                                .font(.system(size: 10, weight: .bold)).foregroundColor(BLTheme.bg)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(BLTheme.goldLite, in: Capsule())
                        }
                    }
                    .font(.system(size: 12, weight: .medium)).foregroundColor(BLTheme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button { showCalculators = true } label: {
                    HStack(spacing: 6) { Image(systemName: "function"); Text("Calculators") }
                        .font(.system(size: 12, weight: .medium)).foregroundColor(BLTheme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
                Button { showSettings = true } label: {
                    HStack(spacing: 6) { Image(systemName: "gearshape"); Text("Settings") }
                        .font(.system(size: 12, weight: .medium)).foregroundColor(BLTheme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            .padding(14)
        }
        .background(BLTheme.bg2.opacity(0.55))
        #if MAS_BUILD
        .sheet(isPresented: $showUnlock) {
            StorePaywall(model: model, isCover: true)
                .frame(minWidth: 460, minHeight: 640)
        }
        #endif
    }
}

// AC-21 — the honest study-habit strip: a self-set streak (flame + live day count) and a "Due today"
// count read straight from the real recall scheduler. Both numbers are derived from real data (the
// append-only completed-review log / the live deck), never fabricated: a fresh learner honestly reads
// "Start your streak" and "Nothing due today". No betting, no ranking vs. others.
struct StudyHabitStrip: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let streak = model.habit.liveStreak
        let due = model.habit.dueToday
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 11))
                    .foregroundColor(streak > 0 ? BLTheme.goldLite : BLTheme.sub.opacity(0.5))
                Text(streak > 0 ? "\(streak)-day streak" : "Start your streak")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(streak > 0 ? BLTheme.text : BLTheme.sub)
                if model.habit.reviewedToday {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10)).foregroundColor(BLTheme.green)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "tray.full")
                    .font(.system(size: 10)).foregroundColor(BLTheme.sub)
                Text(due == 0 ? "Nothing due today" : "\(due) due today")
                    .font(.system(size: 10.5, weight: .medium)).foregroundColor(BLTheme.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 2)
    }
}

struct LibrarySectionRow: View {
    let section: LibrarySection
    let count: Int
    let completed: Int
    let selected: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.icon).font(.system(size: 14))
                    .foregroundColor(selected ? BLTheme.goldLite : BLTheme.sub).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.title).font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundColor(selected ? BLTheme.text : BLTheme.text.opacity(0.85))
                    Text(section.subtitle).font(.system(size: 10.5)).foregroundColor(BLTheme.sub).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(count)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                    if completed > 0 {
                        Text("\(completed) done").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                    }
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(selected ? BLTheme.goldBase.opacity(0.12) : (hover ? BLTheme.bg3.opacity(0.6) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? BLTheme.goldBase.opacity(0.4) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

struct EntryList: View {
    @ObservedObject var model: AppModel
    let section: LibrarySection
    @Binding var entry: Entry?

    var rows: [Entry] { model.query.isEmpty ? model.entries(for: section) : model.searchResults }
    var title: String { model.query.isEmpty ? section.title : "Search" }
    var subtitle: String {
        if !model.query.isEmpty { return "\(rows.count) result(s)" }
        let done = model.completedCount(for: section)
        return done > 0 ? "\(section.subtitle) · \(done)/\(rows.count) complete" : section.subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(subtitle).font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
            }
            .padding(.horizontal, 16).padding(.top, 18).padding(.bottom, 12)
            Divider().overlay(BLTheme.line)
            if rows.isEmpty {
                EmptyState(icon: "tray",
                           title: "Nothing here yet",
                           hint: model.query.isEmpty ? "Entries are being researched and will appear here." : "No matches for that search.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { e in
                            #if os(iOS) || MAS_BUILD
                            // b21: locked lessons list with an honest lock; the tap routes to the
                            // paywall through the platform's access gate (CompactRoot's
                            // navigationDestination on iOS, the reader pane on the Mac App Store).
                            EntryRow(entry: e, progress: model.progress(for: e),
                                     selected: entry?.id == e.id,
                                     locked: model.isLocked(e)) { entry = e }
                            #else
                            EntryRow(entry: e, progress: model.progress(for: e), selected: entry?.id == e.id) { entry = e }
                            #endif
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(BLTheme.bg.opacity(0.35))
    }
}

struct EntryRow: View {
    let entry: Entry
    let progress: LessonProgress
    let selected: Bool
    #if os(iOS) || MAS_BUILD
    // b21: subtle lock on lessons outside the free tier. Both App Store builds carry it; only the
    // Developer-ID macOS build has no per-lesson lock (it gates the whole app through the trial).
    var locked: Bool = false
    #endif
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    #if os(iOS) || MAS_BUILD
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 10))
                            .foregroundColor(BLTheme.sub)
                    }
                    #endif
                    Text(entry.title).font(.system(size: 13.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.text).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer()
                    if progress.bookmarked {
                        Image(systemName: "bookmark.fill").font(.system(size: 10)).foregroundColor(BLTheme.goldLite)
                    }
                    if progress.completed {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundColor(BLTheme.green)
                    }
                }
                HStack(spacing: 6) {
                    Tag(text: entry.difficulty, color: BLTheme.cyan)
                    Text("\(entry.estReadMin) min").font(.system(size: 10.5)).foregroundColor(BLTheme.sub)
                    if let cr = entry.attributionCreator {
                        Text("· \(cr)").font(.system(size: 10.5)).foregroundColor(BLTheme.sub).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    TrustChip(entry: entry, compact: true)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? BLTheme.goldBase.opacity(0.10) : (hover ? BLTheme.bg3.opacity(0.6) : BLTheme.bg2.opacity(0.5)),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? BLTheme.goldBase.opacity(0.4) : BLTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        #if os(iOS) || MAS_BUILD
        .accessibilityIdentifier(locked ? "bl.entry.locked" : "bl.entry.open")
        #endif
    }
}

struct EntryReader: View {
    let entry: Entry
    @ObservedObject var model: AppModel
    #if os(iOS)
    // b20 (App Review 4.2.2): visible in-reader affordance to practice THIS lesson's sourced recall
    // cards with the real AC-19 engine. iOS-only; macOS keeps its sidebar Daily Review entry.
    @State private var showLessonReview = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    FoilText(text: entry.title, size: 26)
                    HStack(spacing: 8) {
                        Tag(text: entry.difficulty, color: BLTheme.cyan)
                        Text("\(entry.estReadMin) min read").font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
                        Text("· updated \(entry.lastUpdated)").font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
                        TrustChip(entry: entry)
                    }
                    if let cr = entry.attributionCreator {
                        HStack(spacing: 5) {
                            Image(systemName: "person.fill").font(.system(size: 10)).foregroundColor(BLTheme.goldBase)
                            Text("As taught by \(cr)").font(.system(size: 12, weight: .medium)).foregroundColor(BLTheme.goldLite)
                            if let link = entry.attributionLink, let url = URL(string: link) {
                                Link("· source", destination: url).font(.system(size: 11)).foregroundColor(BLTheme.cyan)
                            }
                        }
                    }
                }
                if let d = entry.disclaimer { DisclaimerBanner(text: d) }
                LearningPanel(entry: entry, model: model)
                #if os(iOS)
                // Renders only when the lesson actually has recall cards (real per-lesson count).
                LessonReviewButton(model: model, entry: entry) { showLessonReview = true }
                #endif
                if !entry.metrics.isEmpty { MetricsCard(metrics: entry.metrics) }
                // Failures pillar renders as a structured post-mortem (AC-17): tried -> broke ->
                // fix as distinct titled blocks + an honest proof-link. Every other pillar keeps
                // the plain markdown reader. The Sources ("receipts") ledger below is shared.
                if entry.isPostMortem {
                    FailurePostMortem(entry: entry)
                } else {
                    MarkdownView(text: entry.body)
                }
                if !entry.checkpoints.isEmpty { CheckpointsBlock(checkpoints: entry.checkpoints) }
                if !entry.sources.isEmpty { SourcesPanel(sources: entry.sources) }
            }
            .padding(26).frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .sheet(isPresented: $showLessonReview) { LessonReviewSheet(model: model, entry: entry) }
        #endif
    }
}

struct ProgressSummary: View {
    let completed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(completed) / Double(total))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Library progress").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text.opacity(0.86))
                Spacer()
                Text("\(completed)/\(total)").font(.system(size: 10.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(BLTheme.bg3)
                    Capsule().fill(BLTheme.goldGrad).frame(width: geo.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 5)
        }
        .padding(10)
        .background(BLTheme.bg.opacity(0.34), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.line, lineWidth: 1))
    }
}

struct LearningPanel: View {
    let entry: Entry
    @ObservedObject var model: AppModel
    @State private var notes: String

    init(entry: Entry, model: AppModel) {
        self.entry = entry
        self.model = model
        _notes = State(initialValue: model.progress(for: entry).notes)
    }

    var progress: LessonProgress { model.progress(for: entry) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconStateButton(title: progress.completed ? "Completed" : "Complete",
                                icon: progress.completed ? "checkmark.circle.fill" : "checkmark.circle",
                                active: progress.completed,
                                activeColor: BLTheme.green) {
                    model.toggleCompleted(entry)
                }
                IconStateButton(title: progress.bookmarked ? "Bookmarked" : "Bookmark",
                                icon: progress.bookmarked ? "bookmark.fill" : "bookmark",
                                active: progress.bookmarked,
                                activeColor: BLTheme.goldLite) {
                    model.toggleBookmark(entry)
                }
                Spacer()
                if progress.completed {
                    Tag(text: "done", color: BLTheme.green)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                TextEditor(text: $notes)
                    .font(.system(size: 12.5))
                    .foregroundColor(BLTheme.text)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 84)
                    .padding(8)
                    .background(BLTheme.bg.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.line, lineWidth: 1))
                    .onChangeCompat(of: notes) { newValue in
                        model.updateNotes(entry, newValue)
                    }
            }
        }
        .padding(14)
        .background(BLTheme.bg2.opacity(0.50), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.goldBase.opacity(0.18), lineWidth: 1))
        .id(entry.id)
    }
}

struct IconStateButton: View {
    let title: String
    let icon: String
    let active: Bool
    let activeColor: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 12.5, weight: .bold, design: .rounded))
            .foregroundColor(active ? activeColor : (hover ? BLTheme.goldLite : BLTheme.text))
            .padding(.vertical, 8).padding(.horizontal, 12)
            .background(active ? activeColor.opacity(0.12) : BLTheme.bg.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(active ? activeColor.opacity(0.42) : BLTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct DisclaimerBanner: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield").foregroundColor(BLTheme.amber)
            Text(text).font(.system(size: 12)).foregroundColor(BLTheme.text.opacity(0.9))
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.amber.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.amber.opacity(0.3), lineWidth: 1))
    }
}

struct MetricsCard: View {
    let metrics: [EntryMetric]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.doc.horizontal").foregroundColor(BLTheme.goldBase)
                Text("Market & numbers").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.goldLite)
                Spacer()
                Text("every figure sourced").font(.system(size: 10)).foregroundColor(BLTheme.sub)
            }
            ForEach(Array(metrics.enumerated()), id: \.offset) { _, m in
                HStack(alignment: .top, spacing: 10) {
                    Text(m.key.uppercased()).font(.system(size: 11, weight: .bold)).foregroundColor(BLTheme.sub).frame(width: 86, alignment: .leading)
                    Text(m.display).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(BLTheme.text).frame(width: 96, alignment: .leading)
                    Text(m.provenance).font(.system(size: 11)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .holoCard(radius: 14)
    }
}

struct SourcesPanel: View {
    let sources: [EntrySource]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundColor(BLTheme.goldBase)
                Text("The receipts").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.goldLite)
                Spacer()
                Text(sources.count == 1 ? "1 source" : "\(sources.count) sources")
                    .font(.system(size: 10.5, weight: .medium)).foregroundColor(BLTheme.sub)
            }
            ForEach(Array(sources.enumerated()), id: \.offset) { _, s in
                HStack(alignment: .top, spacing: 6) {
                    #if os(iOS)
                    // Store posture (4.2.2): receipts stay visible but are plain text — the reader
                    // never bounces to a browser from the sources ledger.
                    Image(systemName: "doc.text").font(.system(size: 10)).foregroundColor(BLTheme.sub)
                    Text(s.label).font(.system(size: 12)).foregroundColor(BLTheme.text)
                    #else
                    Image(systemName: "link").font(.system(size: 10)).foregroundColor(BLTheme.sub)
                    if let url = URL(string: s.url) {
                        Link(s.label, destination: url).font(.system(size: 12)).foregroundColor(BLTheme.cyan)
                    } else {
                        Text(s.label).font(.system(size: 12)).foregroundColor(BLTheme.text)
                    }
                    #endif
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.line, lineWidth: 1))
    }
}

// MARK: - AC-10 Recall checkpoints (in-lesson practice)
// A short "test yourself" panel below the lesson. Each checkpoint is a fill-in-the-blank recall
// prompt whose answer is a figure the lesson SOURCES inline — compiled + provenance-checked at build
// time, so the practice can never assert a number the lesson doesn't cite. The answer stays hidden
// until the reader reveals it, alongside the citation that backs it.
struct CheckpointsBlock: View {
    let checkpoints: [EntryCheckpoint]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.badge.questionmark").foregroundColor(BLTheme.goldBase)
                Text("Recall checkpoint").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.goldLite)
                Spacer()
                Text("test yourself · answers sourced").font(.system(size: 10)).foregroundColor(BLTheme.sub)
            }
            ForEach(checkpoints) { c in CheckpointRow(checkpoint: c) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.goldBase.opacity(0.18), lineWidth: 1))
    }
}

struct CheckpointRow: View {
    let checkpoint: EntryCheckpoint
    @State private var revealed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(checkpoint.prompt).font(.system(size: 13)).foregroundColor(BLTheme.text)
                .fixedSize(horizontal: false, vertical: true)
            if revealed {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "key.fill").font(.system(size: 10)).foregroundColor(BLTheme.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(checkpoint.answer).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                        if let url = URL(string: checkpoint.sourceURL) {
                            Link("source", destination: url).font(.system(size: 10.5)).foregroundColor(BLTheme.cyan)
                        }
                    }
                }
            } else {
                Button { revealed = true } label: {
                    HStack(spacing: 5) { Image(systemName: "eye"); Text("Reveal answer") }
                        .font(.system(size: 11.5, weight: .semibold)).foregroundColor(BLTheme.cyan)
                }.buttonStyle(.plain)
            }
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.line, lineWidth: 1))
    }
}

// MARK: - AC-17 Failures post-mortem renderer (macOS + iOS via the shared EntryReader)

/// One `## ` section of a post-mortem body, split at compile-uniform headings.
struct PostMortemSection: Identifiable {
    let id = UUID()
    let title: String
    let content: String
}

extension Entry {
    /// Failures lessons are structured post-mortems (tried -> broke -> fix -> proof-link).
    var isPostMortem: Bool { pillar == "failures" }

    /// Split the compiled body into its `## ` sections. The chunk before the first heading (the
    /// H1 title + lede) is `intro`; each heading becomes a titled section, preserving order.
    func postMortemSections() -> (intro: String, sections: [PostMortemSection]) {
        var intro: [String] = []
        var sections: [PostMortemSection] = []
        var curTitle: String?
        var curBody: [String] = []
        func flush() {
            if let t = curTitle {
                sections.append(PostMortemSection(
                    title: t,
                    content: curBody.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            curBody = []
        }
        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                curTitle = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if curTitle == nil {
                if line.hasPrefix("# ") { continue }   // drop the H1 (already shown as reader header)
                intro.append(line)
            } else {
                curBody.append(line)
            }
        }
        flush()
        return (intro.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), sections)
    }

    /// The proof-link as a real URL, or nil when there is no public proof ("no-public-proof"/absent).
    /// Never fabricates: only a compiled http(s) value becomes a link; everything else is honestly nil.
    var postmortemProofURL: URL? {
        guard let p = postmortemProof, p != "no-public-proof",
              p.hasPrefix("http://") || p.hasPrefix("https://") else { return nil }
        return URL(string: p)
    }
    var hasPublicProof: Bool { postmortemProofURL != nil }
}

/// Maps a post-mortem section title to an SF Symbol. Unknown sections get a neutral glyph.
func postMortemIcon(_ title: String) -> String {
    let t = title.lowercased()
    if t.hasPrefix("what we tried") { return "hammer" }
    if t.hasPrefix("what broke") { return "exclamationmark.triangle.fill" }
    if t.hasPrefix("the root cause") || t.hasPrefix("why") { return "magnifyingglass" }
    if t.hasPrefix("the fix") { return "wrench.and.screwdriver.fill" }
    if t.hasPrefix("apply") { return "checklist" }
    return "text.alignleft"
}

struct FailurePostMortem: View {
    let entry: Entry
    var body: some View {
        let parsed = entry.postMortemSections()
        VStack(alignment: .leading, spacing: 14) {
            if !parsed.intro.isEmpty { MarkdownView(text: parsed.intro) }
            ForEach(parsed.sections) { s in
                PostMortemSectionBlock(title: s.title, content: s.content)
            }
            ProofLinkBlock(entry: entry)
        }
    }
}

struct PostMortemSectionBlock: View {
    let title: String
    let content: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: postMortemIcon(title))
                    .font(.system(size: 12)).foregroundColor(BLTheme.goldBase)
                Text(title).font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundColor(BLTheme.goldLite)
            }
            MarkdownView(text: content)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .holoCard(radius: 14)
    }
}

/// The post-mortem proof-link block. A public URL renders as a clickable link labeled honestly;
/// when none exists we show a plain "No public proof — internal post-mortem" marker, never a
/// fabricated link (§5.1). The full Sources ledger still renders below via SourcesPanel.
struct ProofLinkBlock: View {
    let entry: Entry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: entry.hasPublicProof ? "link.circle.fill" : "lock.slash")
                    .font(.system(size: 12)).foregroundColor(entry.hasPublicProof ? BLTheme.goldBase : BLTheme.sub)
                Text("Proof").font(.system(size: 13.5, weight: .bold, design: .rounded))
                    .foregroundColor(entry.hasPublicProof ? BLTheme.goldLite : BLTheme.sub)
            }
            if let url = entry.postmortemProofURL {
                Link(destination: url) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                        Text(url.absoluteString).font(.system(size: 12)).multilineTextAlignment(.leading)
                    }.foregroundColor(BLTheme.cyan)
                }
                Text("Public reference documenting this failure mode.")
                    .font(.system(size: 11)).foregroundColor(BLTheme.sub)
            } else {
                Text("No public proof — internal Black Label post-mortem.")
                    .font(.system(size: 12)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.line, lineWidth: 1))
    }
}

/// Per-lesson receipts chip (AC-16) — extends the library-wide provenance badge down to the
/// row/header level. Shows "N sourced / N figures" computed LIVE from the lesson's compiled
/// metrics; never a hardcoded or optimistic number (§5.1). A lesson with no figures renders
/// nothing (no claim to receipt); a lesson whose figures aren't all cited shows the honest
/// shortfall in a muted tone rather than a green seal.
struct TrustChip: View {
    let entry: Entry
    var compact: Bool = false

    private var allSourced: Bool { entry.sourcedClaimCount == entry.claimCount }
    private var tint: Color { allSourced ? BLTheme.green : BLTheme.sub }

    var body: some View {
        if entry.hasClaims {
            HStack(spacing: 4) {
                Image(systemName: allSourced ? "checkmark.seal.fill" : "seal")
                    .font(.system(size: compact ? 9 : 10.5)).foregroundColor(tint)
                Text(compact
                     ? "\(entry.sourcedClaimCount)/\(entry.claimCount)"
                     : "\(entry.sourcedClaimCount)/\(entry.claimCount) figures sourced")
                    .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold, design: .rounded))
                    .foregroundColor(tint)
            }
            .padding(.horizontal, compact ? 5 : 7).padding(.vertical, compact ? 1.5 : 3)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.3), lineWidth: 1))
            .help("\(entry.claimCount) figure\(entry.claimCount == 1 ? "" : "s") in this lesson · \(entry.sourcedClaimCount) cite a source. Every figure is source- or estimate-gated by the build lint.")
        }
    }
}

/// Library-wide trust badge — the provenance-lint wedge made visible on the buy surface.
/// Every number is computed LIVE from the loaded, lint-gated library (`model.*`), never hardcoded:
/// re-introducing a fixed "234/6"-style figure is the exact honesty regression b19 removed (§5.1).
/// `compact` is the one-line sidebar form; the full form is a card for the paywall / onboarding.
struct ReceiptsBadge: View {
    @ObservedObject var model: AppModel
    var compact: Bool = false

    private var lintLine: String { "\(model.provenancePassCount)/\(model.totalCount) lessons pass the provenance lint" }
    private var sourceLine: String { "\(model.sourcedCount) cite a linked source · \(model.totalSourceCount) sources in all" }

    var body: some View {
        if compact {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 11)).foregroundColor(BLTheme.goldBase)
                VStack(alignment: .leading, spacing: 1) {
                    Text(lintLine).font(.system(size: 10.5, weight: .semibold)).foregroundColor(BLTheme.text.opacity(0.9))
                    Text("Every figure sourced or it never ships.").font(.system(size: 9.5)).foregroundColor(BLTheme.sub)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(BLTheme.bg.opacity(0.34), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(BLTheme.goldBase.opacity(0.22), lineWidth: 1))
            .help(sourceLine)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 13)).foregroundColor(BLTheme.goldBase)
                    Text("Show the receipts").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(BLTheme.goldLite)
                }
                Text(lintLine).font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                Text("\(sourceLine). An unsourced number blocks the build — no competitor ships that.")
                    .font(.system(size: 11)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(BLTheme.bg2.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.goldBase.opacity(0.25), lineWidth: 1))
        }
    }
}

struct SettingsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("bl.motion") private var motion = false

    #if os(macOS) && !MAS_BUILD
    private var statusText: String {
        switch model.entitlement {
        case .subscribed: return "Subscribed · $\(AcademyConfig.monthlyPriceUSD)/mo · full library"
        case .trial(let n): return "Free trial · \(n) day\(n == 1 ? "" : "s") left"
        case .lapsed: return "Canceled · library readable · resubscribe for new lessons"
        case .expired: return "Trial ended · subscribe for full access"
        }
    }
    private var statusIcon: String {
        switch model.entitlement {
        case .subscribed: return "checkmark.seal.fill"
        case .trial: return "hourglass"
        case .lapsed: return "externaldrive.fill.badge.checkmark"
        case .expired: return "lock.fill"
        }
    }
    private var statusColor: Color {
        switch model.entitlement {
        case .subscribed: return BLTheme.green
        case .trial: return BLTheme.goldLite
        case .lapsed: return BLTheme.goldLite
        case .expired: return BLTheme.red
        }
    }

    // AC-13 renewal-date surface — computed from the REAL entitlement/trial clock, never a
    // synthesized billing date. During the trial the first-charge date is known exactly
    // (trial start + 7 days); once subscribed the exact next-charge date lives in the billing
    // portal (Stripe), so we say so honestly rather than invent one.
    private static let renewalDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
    private var renewalLine: String {
        switch model.entitlement {
        case .trial:
            if let end = model.trial.trialEndsAt {
                return "Your $\(AcademyConfig.monthlyPriceUSD)/mo subscription begins \(Self.renewalDateFmt.string(from: end)) unless you cancel first. That is the first renewal charge."
            }
            return "Your $\(AcademyConfig.monthlyPriceUSD)/mo subscription begins when your 7-day free trial ends, unless you cancel first."
        case .subscribed:
            return "Renews monthly at $\(AcademyConfig.monthlyPriceUSD)/mo. Your exact next renewal date is shown in your billing portal."
        case .lapsed:
            return "Canceled — no upcoming renewal. Your on-device library stays readable."
        case .expired:
            return "Trial ended — no active subscription. Subscribe for $\(AcademyConfig.monthlyPriceUSD)/mo to unlock the library."
        }
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            SheetCloseBar(title: "Settings") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Toggle(isOn: $motion) {
                        Text("Animated background").foregroundColor(BLTheme.text).font(.system(size: 13))
                    }
                    .toggleStyle(.switch).tint(BLTheme.goldBase)
                    #if os(macOS) && !MAS_BUILD
                    // AC-13 honest billing (marketed feature) — macOS only. iOS has no trial/
                    // subscription (App Store Guideline 3.1.1), so no billing section is shown there.
                    Divider().overlay(BLTheme.line)
                    VStack(alignment: .leading, spacing: 10) {
                        // Section header + live status.
                        HStack(spacing: 6) {
                            Image(systemName: "creditcard").foregroundColor(BLTheme.goldLite).font(.system(size: 12))
                            Text("Billing & renewal").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.goldLite)
                            Spacer()
                        }
                        HStack(spacing: 6) {
                            Image(systemName: statusIcon).foregroundColor(statusColor).font(.system(size: 11))
                            Text(statusText).font(.system(size: 12)).foregroundColor(BLTheme.text)
                        }
                        // Renewal-date surface, computed from the real trial/entitlement clock.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "calendar").foregroundColor(BLTheme.sub).font(.system(size: 11))
                            Text(renewalLine).font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        // One-tap cancel (active trial / subscription) or resubscribe (lapsed/expired).
                        HStack(spacing: 10) {
                            if model.entitlement.canCancel {
                                Button { openURL(AcademyConfig.manageURL) } label: {
                                    Text("Cancel subscription").font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(BLTheme.cyan)
                                }.buttonStyle(.plain)
                                Button { openURL(AcademyConfig.manageURL) } label: {
                                    Text("Manage billing").font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(BLTheme.sub)
                                }.buttonStyle(.plain)
                            } else {
                                Button { openURL(AcademyConfig.checkoutURL) } label: {
                                    Text("Resubscribe · $\(AcademyConfig.monthlyPriceUSD)/mo").font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(BLTheme.cyan)
                                }.buttonStyle(.plain)
                            }
                        }
                        // Named human support contact — a real person, reachable by email.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "person.crop.circle").foregroundColor(BLTheme.sub).font(.system(size: 11))
                            Text("Billing support: \(AcademyConfig.supportContactName)").font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
                            Link(AcademyConfig.supportContactEmail, destination: AcademyConfig.supportMailtoURL)
                                .font(.system(size: 11.5)).foregroundColor(BLTheme.cyan)
                        }
                        // FOUNDER INPUT NEEDED: the refund policy WORDING is not set. Do not promise a
                        // refund, a proration, or a "we email you before charging" guarantee we cannot
                        // back (§5.1). This neutral line ships until the founder rules on refund terms
                        // — tracked as a blocker in the AC-13 handoff packet.
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "questionmark.circle").foregroundColor(BLTheme.sub).font(.system(size: 11))
                            Text("Questions about billing or a refund? Reach \(AcademyConfig.supportContactName) before your trial converts.")
                                .font(.system(size: 11)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    #endif
                    #if os(iOS) || MAS_BUILD
                    // b21/b102: StoreKit subscription section — live status, manage, Restore
                    // Purchases, and the 3.1.2 legal links. Both App Store builds sell the same
                    // app-level product, so both carry the same panel.
                    Divider().overlay(BLTheme.line)
                    StoreStatusPanel(model: model)
                    #endif
                    #if os(macOS) && !MAS_BUILD
                    Divider().overlay(BLTheme.line)
                    // Keep-on-cancel ownership guarantee (AC-12). Backed by the entitlement engine:
                    // a canceled PAID account drops to `.lapsed`, which stays `isEntitled` (readable)
                    // while updates gate — the copy is only shown because the behavior is true.
                    // macOS-only: the iOS StoreKit tier reverts to the free set when a subscription
                    // lapses, so this promise would be FALSE there (§5.1 — never show it on iOS).
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .foregroundColor(BLTheme.goldLite).font(.system(size: 12))
                        Text("Your library is yours — lessons on this Mac stay readable if you cancel. New lessons resume when you resubscribe.")
                            .font(.system(size: 11)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    #endif
                    Divider().overlay(BLTheme.line)
                    // AC-09 opt-in cohort completion lever. Additive to the solo reader, ships
                    // JOINED-OFF (zero network until the buyer opts in), no price copy. A peer count
                    // renders only from a real, validated server response (see Sources/Cohort.swift).
                    CohortPanel(previewLessonID: model.entries.first?.id)
                    Divider().overlay(BLTheme.line)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Black Label Academy 1.1").font(.system(size: 12, weight: .bold)).foregroundColor(BLTheme.text)
                        Text("\(model.totalCount) entries across \(Pillar.allCases.count) pillars. \(model.completedCount) complete. Every number is sourced or labeled an estimate. Education — not financial or legal advice.")
                            .font(.system(size: 11)).foregroundColor(BLTheme.sub)
                    }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 460)
        .background(BLTheme.bg)
    }
}

// MARK: - Trial banner + paywall gate (7-day free trial → $30/mo) — macOS only
// The iOS build never compiles these views: it ships the full library free with no purchase UI,
// no "$30/mo" copy, no "Subscribe"/"restore" buttons, and no external checkout link
// (App Store Guideline 3.1.1 — a digital subscription may not be sold outside StoreKit IAP).
#if os(macOS) && !MAS_BUILD

// MARK: - First-run onboarding (macOS only)
// A one-time, 3-screen guided welcome shown on first launch: what the library is, how the 7-day
// trial → $30/mo works (routing to the SAME config-driven AcademyConfig.checkoutURL, never a
// hardcoded link), and how to browse. Dismissible in one click at any step. No ambient motion —
// this view never reads `bl.motion`, so it cannot regress the default-OFF motion posture.
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    let onFinish: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var step = 0

    private struct Page {
        let icon: String
        let kicker: String
        let title: String
        let body: String
    }

    // `model.totalCount` (not a hardcoded figure) keeps the entry count truthful to the shipped,
    // provenance-linted library — §5.1: no fabricated number, even in UI chrome.
    private var pages: [Page] {
        [
            Page(icon: "books.vertical.fill",
                 kicker: "The library",
                 title: "Welcome to Black Label Academy",
                 body: "\(model.totalCount) provenance-linted entries across \(Pillar.allCases.count) pillars — Niches, Money, Operations, AI Mastery, Our Failures, Wisdom, and Creator Lessons. Every number is sourced or it never ships."),
            Page(icon: "hourglass",
                 kicker: "Your access",
                 title: "7 days free, then $\(AcademyConfig.monthlyPriceUSD)/mo",
                 body: "The full library is open during your 7-day free trial — nothing held back. Keep everything for $\(AcademyConfig.monthlyPriceUSD)/mo after that. Cancel anytime; it's education, not financial or legal advice."),
            Page(icon: "sidebar.left",
                 kicker: "Finding your way",
                 title: "Browse, search, and track",
                 body: "Pick a pillar in the sidebar, then open an entry. Search the whole library up top, mark lessons Complete or Bookmark them, and check New This Month for the latest additions."),
        ]
    }

    private var page: Page { pages[min(step, pages.count - 1)] }
    private var isLast: Bool { step >= pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            // One-click dismiss — available at every step.
            HStack {
                Spacer()
                Button(action: onFinish) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16)).foregroundColor(BLTheme.sub)
                }
                .buttonStyle(.plain).help("Skip the tour")
            }
            .padding(.horizontal, 16).padding(.top, 14)

            Spacer(minLength: 8)

            VStack(spacing: 16) {
                Image(systemName: page.icon)
                    .font(.system(size: 46)).foregroundStyle(BLTheme.goldGrad)
                Text(page.kicker.uppercased())
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundColor(BLTheme.sub).tracking(2)
                FoilText(text: page.title, size: 26)
                    .multilineTextAlignment(.center)
                Text(page.body)
                    .font(.system(size: 14)).foregroundColor(BLTheme.sub)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .frame(maxWidth: 420)

                // Library screen: surface the provenance-lint wedge up front (computed live).
                if step == 0 {
                    ReceiptsBadge(model: model).frame(maxWidth: 420)
                }

                // Trial screen: route to the SAME config-driven checkout the paywall uses.
                if step == 1 {
                    Button { openURL(AcademyConfig.checkoutURL) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "creditcard")
                            Text("See the plan")
                        }
                        .font(.system(size: 12.5, weight: .semibold)).foregroundColor(BLTheme.cyan)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 32)

            Spacer(minLength: 8)

            // Progress dots.
            HStack(spacing: 7) {
                ForEach(0..<pages.count, id: \.self) { i in
                    Circle()
                        .fill(i == step ? BLTheme.goldBase : BLTheme.stroke)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 16)

            HStack(spacing: 10) {
                if step > 0 {
                    Button { step -= 1 } label: {
                        Text("Back").font(.system(size: 13, weight: .semibold))
                            .foregroundColor(BLTheme.sub)
                            .padding(.horizontal, 18).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    if isLast { onFinish() } else { step += 1 }
                } label: {
                    Text(isLast ? "Start reading" : "Next")
                        .font(.system(size: 13.5, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 26).padding(.vertical, 11)
                        .background(Capsule().fill(BLTheme.goldGrad))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
        .frame(width: 520, height: 460)
        .background(BLTheme.bg)
    }
}

/// Thin strip shown above the reader during the free trial. Counts down and offers to subscribe.
struct TrialBanner: View {
    @ObservedObject var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hourglass").font(.system(size: 12)).foregroundColor(BLTheme.goldLite)
            Text(daysText)
                .font(.system(size: 12, weight: .semibold)).foregroundColor(BLTheme.text)
            Text("Full library included during your trial.")
                .font(.system(size: 12)).foregroundColor(BLTheme.sub)
            Spacer(minLength: 8)
            Button { openURL(AcademyConfig.checkoutURL) } label: {
                Text("Subscribe · $\(AcademyConfig.monthlyPriceUSD)/mo")
                    .font(.system(size: 12, weight: .bold)).foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(BLTheme.goldGrad))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(BLTheme.bg2)
        .overlay(Rectangle().frame(height: 1).foregroundColor(BLTheme.line), alignment: .bottom)
    }

    private var daysText: String {
        let n = model.trial.daysRemaining
        return n == 1 ? "1 day left in your free trial" : "\(n) days left in your free trial"
    }
}

/// Hard gate shown when the trial has expired and the user has not subscribed. The reader is fully
/// replaced by this view, so no lesson is readable until the buyer subscribes.
struct PaywallView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            #if os(macOS)
            AuroraBackdrop()
            #else
            BLTheme.bg.ignoresSafeArea()
            #endif
            VStack(spacing: 18) {
                Image(systemName: "lock.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(BLTheme.goldGrad)
                FoilText(text: "Your free trial has ended", size: 28)
                Text("Keep the full Black Label Academy library — \(model.totalCount) lessons across \(Pillar.allCases.count) pillars, every number sourced, new lessons every month.")
                    .font(.system(size: 14)).foregroundColor(BLTheme.sub)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)

                Text("$\(AcademyConfig.monthlyPriceUSD)")
                    .font(.system(size: 44, weight: .heavy)).foregroundColor(BLTheme.text)
                + Text(" /month")
                    .font(.system(size: 16)).foregroundColor(BLTheme.sub)

                Button { openURL(AcademyConfig.checkoutURL) } label: {
                    Text("Subscribe — $\(AcademyConfig.monthlyPriceUSD)/mo")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.black)
                        .padding(.horizontal, 30).padding(.vertical, 14)
                        .background(Capsule().fill(BLTheme.goldGrad))
                }
                .buttonStyle(.plain)

                Button { model.trial.markSubscribed() } label: {
                    Text("I've subscribed — restore access")
                        .font(.system(size: 12)).foregroundColor(BLTheme.cyan)
                }
                .buttonStyle(.plain)

                // The un-copyable wedge, on the buy surface: every figure in the library is sourced
                // or the build blocks (computed live — never a hardcoded count).
                ReceiptsBadge(model: model).frame(maxWidth: 460)

                Text("Education, not financial or legal advice. Cancel anytime.")
                    .font(.system(size: 11)).foregroundColor(BLTheme.sub).padding(.top, 4)
            }
            .padding(40)
        }
        #if os(macOS)
        .frame(minWidth: 1060, minHeight: 700)
        #endif
    }
}

#endif  // os(macOS) — TrialBanner + PaywallView excluded from the iOS build

// MARK: - AC-19 Daily Review (spaced repetition) — cross-platform sheet
// A one-card-at-a-time review of the spaced-repetition deck. Every card is a compiled, provenance-
// gated checkpoint (H6): the answer is a figure the lesson SOURCES, shown alongside its citation.
// "Got it" / "Missed" grade the SM-2-lite schedule; the deck persists locally.

struct DailyReviewSheet: View {
    @ObservedObject var model: AppModel
    let openEntry: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    // Snapshot the due queue when the sheet opens so grading (which changes what's "due") doesn't
    // reshuffle the run underneath the reader.
    @State private var queue: [RecallCard] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var correct = 0

    var body: some View {
        VStack(spacing: 0) {
            SheetCloseBar(title: "Daily Review") { dismiss() }
            Divider().overlay(BLTheme.line).padding(.top, 8)
            content
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 460)
        .background(BLTheme.bg)
        .onAppear {
            if queue.isEmpty {
                #if os(iOS)
                // b21: the free tier reviews accessible lessons only (all of them when
                // subscribed) — a locked lesson's sourced answers are never dealt out.
                queue = model.accessibleDueCards
                #else
                queue = model.recall.dueCards
                #endif
            }
        }
    }

    @ViewBuilder private var content: some View {
        if queue.isEmpty {
            caughtUp
        } else if index >= queue.count {
            summary
        } else {
            reviewing(queue[index])
        }
    }

    private var deckSize: Int {
        #if os(iOS)
        return model.accessibleRecallCards.count
        #else
        return model.recall.totalCount
        #endif
    }

    private var caughtUp: some View {
        VStack(spacing: 10) {
            EmptyState(icon: "checkmark.seal",
                       title: "All caught up",
                       hint: "No recall cards are due right now. Spaced repetition brings them back as they come due — every answer is a figure the lesson sources.")
            Text("\(deckSize) recall cards in your deck")
                .font(.system(size: 11.5, weight: .medium)).foregroundColor(BLTheme.sub)
                .padding(.bottom, 18)
        }
    }

    private var summary: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "brain.head.profile").font(.system(size: 40, weight: .light))
                .foregroundStyle(BLTheme.goldGrad)
            Text("Review complete").font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundColor(BLTheme.text)
            Text("\(correct)/\(queue.count) recalled · spaced repetition rescheduled the rest")
                .font(.system(size: 12.5)).foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
            Button { dismiss() } label: {
                Text("Done").font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(BLTheme.bg).padding(.vertical, 9).padding(.horizontal, 26)
                    .background(BLTheme.goldGrad, in: Capsule())
            }.buttonStyle(.plain).padding(.top, 4)
            Spacer()
        }.padding(24)
    }

    @ViewBuilder private func reviewing(_ card: RecallCard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(BLTheme.goldBase).font(.system(size: 11))
                Text("Recall card \(index + 1) of \(queue.count) · spaced repetition")
                    .font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                Spacer()
                Button { openEntry(card.entryID) } label: {
                    Text(card.entryTitle).font(.system(size: 10.5, weight: .medium)).foregroundColor(BLTheme.cyan).lineLimit(1)
                }.buttonStyle(.plain)
            }

            Text(card.prompt).font(.system(size: 16)).foregroundColor(BLTheme.text)
                .fixedSize(horizontal: false, vertical: true)

            if revealed {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key.fill").font(.system(size: 12)).foregroundColor(BLTheme.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.answer).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                        if let url = URL(string: card.sourceURL) {
                            Link("source", destination: url).font(.system(size: 11)).foregroundColor(BLTheme.cyan)
                        }
                    }
                }
                .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(BLTheme.bg2.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.line, lineWidth: 1))

                HStack(spacing: 10) {
                    gradeButton(title: "Missed", icon: "arrow.counterclockwise", color: BLTheme.red) {
                        grade(card, correct: false)
                    }
                    gradeButton(title: "Got it", icon: "checkmark", color: BLTheme.green) {
                        grade(card, correct: true)
                    }
                }
            } else {
                Button { revealed = true } label: {
                    HStack(spacing: 6) { Image(systemName: "eye"); Text("Reveal answer") }
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(BLTheme.cyan)
                        .padding(.vertical, 9).padding(.horizontal, 16)
                        .background(BLTheme.bg2, in: Capsule())
                        .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gradeButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: icon); Text(title) }
                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(color)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.4), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func grade(_ card: RecallCard, correct wasCorrect: Bool) {
        model.recall.grade(card, correct: wasCorrect)
        // AC-21: a real graded recall IS a completed Daily Review session for today — record it so the
        // streak advances. Idempotent per calendar day, so it can only ever count a genuine review.
        model.habit.recordCompletedReview()
        if wasCorrect { correct += 1 }
        revealed = false
        index += 1
    }
}

// MARK: - AC-20 grounded Library Tutor — cross-platform sheet
// Ask a question; the tutor answers ONLY by quoting a real lesson passage with a clickable citation,
// or refuses verbatim ("Not covered in the library."). Zero network, zero generation beyond the
// retrieved text — the honesty guarantee is that it can only echo what the library already proved.

struct LibraryTutorSheet: View {
    @ObservedObject var model: AppModel
    let openEntry: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var answer: TutorAnswer? = nil

    var body: some View {
        VStack(spacing: 0) {
            SheetCloseBar(title: "Library Tutor") { dismiss() }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.shield").foregroundColor(BLTheme.goldLite).font(.system(size: 12))
                        Text("Grounded, cite-or-refuse. The tutor answers only by quoting a lesson and naming it — nothing is generated, nothing leaves your device. If the library doesn't cover it, it says so.")
                            .font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    askField
                    if let a = answer { answerView(a) }
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 480, idealWidth: 580, minHeight: 460)
        .background(BLTheme.bg)
    }

    private var askField: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass").foregroundColor(BLTheme.sub).font(.system(size: 13))
            TextField("Ask the library — e.g. \"how do I price a service?\"", text: $query)
                .textFieldStyle(.plain).font(.system(size: 14)).foregroundColor(BLTheme.text)
                .onSubmit(ask)
            #if os(iOS)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            #endif
            Button(action: ask) {
                Text("Ask").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.bg)
                    .padding(.vertical, 6).padding(.horizontal, 14)
                    .background(BLTheme.goldGrad, in: Capsule())
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 8).padding(.horizontal, 12)
        .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    @ViewBuilder private func answerView(_ a: TutorAnswer) -> some View {
        if a.isRefusal {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "xmark.circle").foregroundColor(BLTheme.amber).font(.system(size: 14))
                Text(a.text).font(.system(size: 14, weight: .semibold)).foregroundColor(BLTheme.text)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(BLTheme.bg2.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.amber.opacity(0.3), lineWidth: 1))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("\u{201C}\(a.text)\u{201D}").font(.system(size: 14)).foregroundColor(BLTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let id = a.entryID, let title = a.entryTitle {
                    Button { openEntry(id) } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "book.closed").font(.system(size: 11))
                            Text("from: \(title)").font(.system(size: 11.5, weight: .semibold))
                            Image(systemName: "arrow.up.right").font(.system(size: 9))
                        }.foregroundColor(BLTheme.cyan)
                    }.buttonStyle(.plain)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(BLTheme.bg2.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.green.opacity(0.25), lineWidth: 1))
        }
    }

    private func ask() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { answer = nil; return }
        #if os(iOS)
        // b21: the tutor quotes ONLY accessible lessons (all of them when subscribed) — it never
        // leaks a locked lesson's passages, and its citation always opens a readable lesson.
        answer = TutorEngine.answer(q, entries: model.accessibleEntries)
        #else
        answer = TutorEngine.answer(q, entries: model.entries)
        #endif
    }
}
#endif // circuit-convert
