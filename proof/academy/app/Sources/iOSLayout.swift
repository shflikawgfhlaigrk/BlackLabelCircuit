// Black Label Academy — iOS/iPadOS responsive layout.
// macOS keeps its custom 3-pane shell (RootView); iOS uses a NavigationStack
// drill-down: pillars -> entries -> reader. Reuses EntryList / EntryReader / theme.
#if os(iOS)
import SwiftUI

struct CompactRoot: View {
    @ObservedObject var model: AppModel
    @Binding var section: LibrarySection
    @Binding var entry: Entry?
    @Binding var showSettings: Bool
    @Binding var showCertificates: Bool
    @Binding var showCalculators: Bool
    @Binding var showRecall: Bool
    @Binding var showTutor: Bool
    // b21: the full-screen unlock surface (StoreKit 2 subscription paywall).
    @State private var showUnlockCover = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    searchField
                    if model.query.isEmpty {
                        // b20 (App Review 4.2.2): the native machinery — spaced-repetition Daily
                        // Review, resume-reading, calculators/certificates/tutor — is the FIRST
                        // thing on screen, as labeled cards, not icons hidden in a toolbar. Every
                        // number below is read live from the real engines (§5.1: none fabricated).
                        todayArea
                        accessBanner
                        VStack(spacing: 8) {
                            NavigationLink(value: LibrarySection.newThisMonth) {
                                CompactSectionRow(section: .newThisMonth,
                                                  count: model.count(.newThisMonth),
                                                  completed: model.completedCount(for: .newThisMonth))
                            }
                            .buttonStyle(.plain)
                            ForEach(Pillar.allCases) { p in
                                let librarySection = LibrarySection.pillar(p)
                                NavigationLink(value: librarySection) {
                                    CompactSectionRow(section: librarySection,
                                                      count: model.count(librarySection),
                                                      completed: model.completedCount(for: librarySection))
                                }
                                    .buttonStyle(.plain)
                            }
                        }
                    } else {
                        searchResults
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .background(AuroraBackdrop().ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // AC-19 Daily Review (spaced repetition) — parity with the macOS sidebar entry.
                ToolbarItem(placement: .topBarLeading) {
                    Button { showRecall = true } label: {
                        Image(systemName: "brain.head.profile")
                    }
                    .tint(BLTheme.goldBase)
                    .accessibilityLabel("Daily Review")
                }
                // AC-20 grounded Library Tutor — cite-or-refuse parity with macOS.
                ToolbarItem(placement: .topBarLeading) {
                    Button { showTutor = true } label: { Image(systemName: "text.magnifyingglass") }
                        .tint(BLTheme.goldBase)
                        .accessibilityLabel("Library Tutor")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCalculators = true } label: { Image(systemName: "function") }
                        .tint(BLTheme.goldBase)
                        .accessibilityLabel("Calculators")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showCertificates = true } label: { Image(systemName: "rosette") }
                        .tint(BLTheme.goldBase)
                        .accessibilityLabel("Certificates")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .tint(BLTheme.goldBase)
                }
            }
            .navigationDestination(for: LibrarySection.self) { next in
                EntryList(model: model, section: next, entry: $entry)
                    .background(AuroraBackdrop().ignoresSafeArea())
                    .navigationTitle(next.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .onAppear { section = next }
            }
            .navigationDestination(item: $entry) { e in
                // b21 access gate: a locked lesson opens the paywall in place of the reader.
                // The check is live — completing the purchase re-evaluates it and the reader
                // appears right where the buyer was standing.
                if model.isUnlocked(e) {
                    EntryReader(entry: e, model: model)
                        .background(AuroraBackdrop().ignoresSafeArea())
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    StorePaywall(model: model, lockedTitle: e.title)
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .tint(BLTheme.goldBase)
        .fullScreenCover(isPresented: $showUnlockCover) {
            StorePaywall(model: model, isCover: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                if let img = appIcon() {
                    Image(blImage: img).resizable().frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("BLACK LABEL").font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundColor(BLTheme.sub).tracking(2)
                    FoilText(text: "Academy", size: 23)
                }
                Spacer()
            }
            // Owner-positioning line (AC-15, founder-approved) — iOS parity with the macOS sidebar.
            // H4 ban holds: never frame it as beating a degree.
            Text("Degrees train employees. This trains owners.")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(BLTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(BLTheme.sub).font(.system(size: 13))
            TextField("Search the library", text: $model.query)
                .textFieldStyle(.plain).font(.system(size: 15)).foregroundColor(BLTheme.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(BLTheme.sub) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 12)
        .background(BLTheme.bg2, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
    }

    // MARK: - TODAY (b20 — native-first home)
    // Surfaces the app's own working machinery above the library list: the AC-19 spaced-repetition
    // queue (real due count + AC-21 streak), the resume-reading card (real progress DB), and the
    // native tool row (real calculator/certificate counts). Honest empty states throughout — a
    // fresh install shows the true numbers, never seeded ones.
    @ViewBuilder private var todayArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TODAY")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.sub).tracking(2)
            DailyReviewCard(model: model) { showRecall = true }
            // b21: resume only surfaces a lesson the buyer can actually open (a pre-subscription
            // resume target from an older install may now be locked — never resume into a gate).
            if let e = model.resumeEntry, !model.isCompleted(e), model.isUnlocked(e) {
                ContinueReadingCard(entry: e, progress: model.progress(for: e)) { entry = e }
            }
            HStack(spacing: 8) {
                ToolCard(icon: "function", title: "Calculators",
                         detail: "\(CalcLibrary.all.count) owner tools") { showCalculators = true }
                ToolCard(icon: "rosette", title: "Certificates",
                         detail: "\(model.unlockedCertificateCount) of \(model.certificateStatuses.count) earned") { showCertificates = true }
                ToolCard(icon: "text.magnifyingglass", title: "Tutor",
                         detail: "Cited answers only") { showTutor = true }
            }
            Text("LIBRARY")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(BLTheme.sub).tracking(2)
                .padding(.top, 6)
        }
    }

    // b21 honest access banner: states the real tier (never the stale "full library free" copy)
    // and, when locked, offers the unlock. The completed/total count stays global — honest about
    // the size of the whole library, exactly as shipped.
    @ViewBuilder private var accessBanner: some View {
        HStack(spacing: 8) {
            if model.isSubscribed {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(BLTheme.green).font(.system(size: 13))
                Text("Subscribed · full library")
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(BLTheme.sub)
                    .accessibilityIdentifier("bl.access.status")
            } else {
                Image(systemName: "lock.open")
                    .foregroundColor(BLTheme.goldLite).font(.system(size: 12))
                Text("Free · \(model.freeLessonIDs.count) of \(model.totalCount) lessons + all tools")
                    .font(.system(size: 12.5, weight: .medium)).foregroundColor(BLTheme.sub)
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .accessibilityIdentifier("bl.access.status")
            }
            Spacer()
            if !model.isSubscribed {
                Button { showUnlockCover = true } label: {
                    Text("Unlock")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(BLTheme.bg)
                        .padding(.vertical, 5).padding(.horizontal, 12)
                        .background(BLTheme.goldGrad, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("bl.unlock.banner")
            }
            Text("\(model.completedCount)/\(model.totalCount) complete")
                .font(.system(size: 11.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var searchResults: some View {
        if model.searchResults.isEmpty {
            EmptyState(icon: "tray", title: "No matches", hint: "Try a different search.")
        } else {
            VStack(spacing: 6) {
                ForEach(model.searchResults) { e in
                    // Locked results stay discoverable (title/tags) with an honest lock; the tap
                    // routes to the paywall via the same navigationDestination gate.
                    Button { entry = e } label: {
                        EntryRowLabel(entry: e, progress: model.progress(for: e),
                                      locked: model.isLocked(e))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct CompactSectionRow: View {
    let section: LibrarySection
    let count: Int
    let completed: Int
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: section.icon).font(.system(size: 16)).foregroundStyle(BLTheme.goldGrad).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(section.title).font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                Text(section.subtitle).font(.system(size: 11.5)).foregroundColor(BLTheme.sub).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(count)").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.sub)
                if completed > 0 {
                    Text("\(completed) done").font(.system(size: 9.5, weight: .bold, design: .rounded)).foregroundColor(BLTheme.green)
                }
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundColor(BLTheme.sub)
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(BLTheme.bg2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.line, lineWidth: 1))
    }
}

// Label-only entry row for search results (used inside a Button so it can push the reader).
struct EntryRowLabel: View {
    let entry: Entry
    let progress: LessonProgress
    // b21: subtle lock on lessons outside the free tier (the tap opens the paywall, not the reader).
    var locked: Bool = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if locked {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                        .foregroundColor(BLTheme.sub)
                }
                Text(entry.title).font(.system(size: 14, weight: .semibold, design: .rounded))
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
                Spacer(minLength: 0)
                TrustChip(entry: entry, compact: true)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.line, lineWidth: 1))
    }
}

// MARK: - b20 Today cards (every number is read from the real engines — none fabricated, §5.1)

/// The AC-19 Daily Review entry card: real due count from the spaced-repetition scheduler, the
/// honest AC-21 streak, and a "Start review" affordance. When nothing is due it says so truthfully
/// (spaced repetition brings cards back as they come due — a fresh deck is all-due, never empty-faked).
struct DailyReviewCard: View {
    @ObservedObject var model: AppModel
    let start: () -> Void

    var body: some View {
        // b21: counts are scoped to ACCESSIBLE lessons (all of them when subscribed) so the free
        // tier's Daily Review is honest — it never advertises cards whose lessons are locked.
        let due = model.accessibleDueCards.count
        let total = model.accessibleRecallCards.count
        let streak = model.habit.liveStreak
        Button(action: start) {
            HStack(spacing: 12) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 20)).foregroundStyle(BLTheme.goldGrad)
                    .frame(width: 40, height: 40)
                    .background(BLTheme.goldBase.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Daily Review")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundColor(BLTheme.text)
                        if streak > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "flame.fill").font(.system(size: 9))
                                Text("\(streak)-day streak").font(.system(size: 10, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(BLTheme.goldLite)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(BLTheme.goldBase.opacity(0.12), in: Capsule())
                        }
                        if model.habit.reviewedToday {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundColor(BLTheme.green)
                        }
                    }
                    Text(subtitle(due: due, total: total))
                        .font(.system(size: 11.5)).foregroundColor(BLTheme.sub)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if due > 0 {
                    HStack(spacing: 6) {
                        Text("Start review")
                            .font(.system(size: 11.5, weight: .bold, design: .rounded))
                            .foregroundColor(BLTheme.bg)
                        Text("\(due)")
                            .font(.system(size: 10.5, weight: .bold, design: .rounded))
                            .foregroundColor(BLTheme.goldLite)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(BLTheme.bg.opacity(0.85), in: Capsule())
                    }
                    .padding(.vertical, 7).padding(.horizontal, 11)
                    .background(BLTheme.goldGrad, in: Capsule())
                } else {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 16)).foregroundColor(BLTheme.green)
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(BLTheme.bg2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.goldBase.opacity(0.22), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(due > 0 ? "Daily Review — \(due) cards due" : "Daily Review — all caught up")
    }

    private func subtitle(due: Int, total: Int) -> String {
        if total == 0 { return "No recall cards in this library build" }
        if due == 0 { return "All caught up · \(total) cards scheduled ahead" }
        return "\(due) of \(total) recall cards due · spaced repetition"
    }
}

/// Resume the last-opened, not-yet-completed lesson (real progress DB — hidden until a lesson has
/// actually been opened; never invents a recommendation).
struct ContinueReadingCard: View {
    let entry: Entry
    let progress: LessonProgress
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "book")
                    .font(.system(size: 18)).foregroundStyle(BLTheme.goldGrad)
                    .frame(width: 40, height: 40)
                    .background(BLTheme.goldBase.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Continue reading")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(BLTheme.sub).tracking(1.2)
                    Text(entry.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.text).lineLimit(1)
                    HStack(spacing: 6) {
                        Text("\((Pillar(rawValue: entry.pillar)?.title) ?? entry.pillar) · \(entry.estReadMin) min")
                            .font(.system(size: 11)).foregroundColor(BLTheme.sub)
                        if progress.bookmarked {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 9)).foregroundColor(BLTheme.goldLite)
                        }
                        if !progress.notes.isEmpty {
                            HStack(spacing: 2) {
                                Image(systemName: "note.text").font(.system(size: 9))
                                Text("notes").font(.system(size: 10))
                            }.foregroundColor(BLTheme.sub)
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(BLTheme.sub)
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .background(BLTheme.bg2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue reading \(entry.title)")
    }
}

/// A labeled native-tool card (calculators / certificates / tutor). The detail line carries a real
/// count where one exists (CalcLibrary.all.count, certificate statuses) — never a hardcoded figure.
struct ToolCard: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 16)).foregroundStyle(BLTheme.goldGrad)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundColor(BLTheme.text).lineLimit(1)
                Text(detail)
                    .font(.system(size: 9.5)).foregroundColor(BLTheme.sub)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 11).padding(.horizontal, 11)
            .background(BLTheme.bg2.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) — \(detail)")
    }
}

// MARK: - b20 in-reader lesson review (visible native affordance, App Review 4.2.2)

/// "Review this lesson" — shown in the reader ONLY when the open lesson actually has recall cards
/// (compiled, provenance-gated checkpoints). Renders nothing otherwise; the count is the deck's
/// real per-lesson card count.
struct LessonReviewButton: View {
    @ObservedObject var model: AppModel
    let entry: Entry
    let action: () -> Void

    private var cardCount: Int { model.recall.cards.filter { $0.entryID == entry.id }.count }

    var body: some View {
        if cardCount > 0 {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 13)).foregroundStyle(BLTheme.goldGrad)
                    Text("Review this lesson")
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundColor(BLTheme.text)
                    Spacer()
                    Text("\(cardCount) card\(cardCount == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.sub)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(BLTheme.sub)
                }
                .padding(.vertical, 11).padding(.horizontal, 14)
                .background(BLTheme.bg2.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(BLTheme.goldBase.opacity(0.22), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Review this lesson — \(cardCount) recall cards")
        }
    }
}

/// Per-lesson spaced-repetition practice: the SAME AC-19 engine and grade path as Daily Review,
/// scoped to the open lesson's cards. Grading here is a real review — it updates the real schedule
/// and (idempotently per day) advances the honest AC-21 streak, exactly like DailyReviewSheet.
struct LessonReviewSheet: View {
    @ObservedObject var model: AppModel
    let entry: Entry
    @Environment(\.dismiss) private var dismiss

    // Snapshot the lesson's cards when the sheet opens so grading doesn't reshuffle the run.
    @State private var queue: [RecallCard] = []
    @State private var index = 0
    @State private var revealed = false
    @State private var correct = 0

    var body: some View {
        VStack(spacing: 0) {
            SheetCloseBar(title: "Review this lesson") { dismiss() }
            Divider().overlay(BLTheme.line).padding(.top, 8)
            content
        }
        .background(BLTheme.bg)
        .onAppear {
            if queue.isEmpty {
                queue = model.recall.cards
                    .filter { $0.entryID == entry.id }
                    .sorted { $0.ord < $1.ord }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if queue.isEmpty {
            // Honest empty state — reachable only if the lesson's cards vanished between the
            // button render and presentation (e.g. a content update); never a fake queue.
            EmptyState(icon: "tray", title: "No recall cards",
                       hint: "This lesson has no sourced checkpoints to review.")
        } else if index >= queue.count {
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: "brain.head.profile").font(.system(size: 40, weight: .light))
                    .foregroundStyle(BLTheme.goldGrad)
                Text("Lesson review complete")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
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
        } else {
            reviewing(queue[index])
        }
    }

    @ViewBuilder private func reviewing(_ card: RecallCard) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").foregroundColor(BLTheme.goldBase).font(.system(size: 11))
                Text("Card \(index + 1) of \(queue.count) · \(card.entryTitle)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(BLTheme.sub).lineLimit(1)
                Spacer()
            }

            Text(card.prompt).font(.system(size: 16)).foregroundColor(BLTheme.text)
                .fixedSize(horizontal: false, vertical: true)

            if revealed {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key.fill").font(.system(size: 12)).foregroundColor(BLTheme.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(card.answer).font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(BLTheme.green)
                        // Citation surfaces as PLAIN TEXT — store-safe, never bounces to a browser
                        // (same 4.2.2 posture as the reader's SourcesPanel on iOS).
                        Text(card.sourceURL).font(.system(size: 10.5)).foregroundColor(BLTheme.sub)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(BLTheme.bg2.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.line, lineWidth: 1))

                HStack(spacing: 10) {
                    lessonGradeButton(title: "Missed", icon: "arrow.counterclockwise", color: BLTheme.red) {
                        grade(card, correct: false)
                    }
                    lessonGradeButton(title: "Got it", icon: "checkmark", color: BLTheme.green) {
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

    private func lessonGradeButton(title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
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
        // AC-21: a real graded recall IS a completed review for today (idempotent per calendar day).
        model.habit.recordCompletedReview()
        if wasCorrect { correct += 1 }
        revealed = false
        index += 1
    }
}
#endif
