#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — LIST BUILDER (guided, database-backed).
//
// The primary list-building experience runs on OUR live 28M+ public-records index:
//   Step 1  What type of list?   (honest category predicates — see DatabaseListEngine)
//   Step 2  Where?               (state / county / city / ZIP / current map viewport)
//   Step 3  Optional filters     (only fields the index REALLY has; the rest say so)
//   Step 4  Results              (count FIRST, then preview rows, map pins, save/export)
//
// The buyer never has to paste or upload anything to build a list. Types the index
// can't derive yet (tax delinquent / pre-foreclosure) say so honestly and offer real
// adjacent lists — never placeholder rows. The buyer's own CRM smart lists remain as
// a secondary tab (they operate on saved leads, not on the index).
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif

struct ListBuilderScreen: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case database = "Build from database", crm = "My CRM lists"
        var id: String { rawValue }
    }
    @EnvironmentObject var model: AppModel
    var go: (Section) -> Void = { _ in }
    @State private var tab: Tab = .database

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeaderRow(title: "List Builder",
                      subtitle: "Build targeted lists straight from the live public-records database — pick a type, pick a place, get real parcels") {
                TrialStatusPill()
            }.blScreenPadding(28).padding(.bottom, 8)
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, BLScale.gutter(28)).padding(.bottom, 4)
            switch tab {
            case .database: DatabaseListBuilder(go: go)
            case .crm: CRMSmartListsView()
            }
        }
    }
}

// MARK: - The guided database-backed builder

private struct DatabaseListBuilder: View {
    @EnvironmentObject var model: AppModel
    var go: (Section) -> Void = { _ in }

    @State private var step = 1
    @State private var criteria = DatabaseListCriteria()
    @State private var pickedType = false
    @State private var showPaywall = false

    // Step 4 state
    @State private var loading = false
    // Monotonic query stamp: only the newest in-flight search may publish results. Without it two
    // overlapping runs (saved-list Run taps) race and the LAST response wins — stale rows and a
    // stale count rendering under the newer query's criteria summary.
    @State private var searchGeneration = 0
    @State private var error = ""
    // True when `error` is a connectivity failure (offline / unreachable); false when the database
    // answered and rejected the query (e.g. a filter needs a location). Drives the recovery copy.
    @State private var errorIsConnectivity = true
    @State private var page = PropertyPage.empty
    @State private var pageIndex = 1
    @State private var ran = false
    @State private var listName = ""
    @State private var note = ""
    @State private var exporting = false
    private let perPage = 25

    // Step 3 field mirrors (text-editable money fields)
    @State private var minValueText = ""
    @State private var maxValueText = ""

    // Saved-list detail sheet (Workspace v2).
    @State private var detailList: SavedDatabaseList?
    @State private var pendingDelete: SavedDatabaseList?
    // RE-21 saved-search monitors sheet.
    @State private var showMonitors = false
    private let monitorStore = SavedSearchStore()

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            stepHeader
            switch step {
            case 1: stepType
            case 2: stepWhere
            case 3: stepFilters
            default: stepResults
            }
            savedListsPanel
        }.padding(.horizontal, BLScale.gutter(28)).padding(.bottom, 28).padding(.top, 10) }
        .onAppear { runListsUISmokeIfRequested() }
        // A newly-saved database key raises the row cap — re-run the current list
        // immediately so the buyer sees the bigger pages without hunting for a button.
        .onReceive(NotificationCenter.default.publisher(for: .blreLeadDBTokenChanged)) { _ in
            if ran { startSearch() }
        }
        .sheet(item: $detailList) { saved in
            SavedDatabaseListDetail(
                saved: saved,
                onDuplicate: { criteria in
                    detailList = nil
                    self.criteria = criteria
                    pickedType = true
                    minValueText = criteria.minValue.map(String.init) ?? ""
                    maxValueText = criteria.maxValue.map(String.init) ?? ""
                    withAnimation { step = 3 }
                },
                onOpenMap: { criteria, total in
                    detailList = nil
                    model.pendingPropertyMapRequest = .forList(criteria, total: total)
                    go(.map)
                },
                onAddKey: {
                    detailList = nil
                    go(.settings)
                })
                .environmentObject(model)
                .sheetCloseBar()
        }
        .sheet(isPresented: $showMonitors) {
            SavedSearchMonitorSheet().environmentObject(model).sheetCloseBar()
        }
        // Root-attached so every gated action can present it — "Show results" (step 3), a saved
        // list's Run (any step), and Export CSV (step 4). A sheet bound inside one step's subtree
        // can only present while that step is mounted.
        .sheet(isPresented: $showPaywall) { TrialPaywallSheet().sheetCloseBar() }
    }

    /// Save the current or a saved list's criteria as a while-you-sleep monitor, then open the panel.
    private func addMonitor(name: String, criteria: DatabaseListCriteria) {
        let s = SavedSearch(name: name.isEmpty ? criteria.type.label : name, criteria: criteria)
        monitorStore.upsert(s)
        showMonitors = true
    }

    // MARK: step chrome

    private var stepHeader: some View {
        HStack(spacing: 8) {
            ForEach(Array(["What", "Where", "Filters", "Results"].enumerated()), id: \.offset) { i, name in
                let n = i + 1
                Button { if n < step { withAnimation { step = n } } } label: {
                    HStack(spacing: 6) {
                        Text("\(n)").font(BLFont.mono(10, .bold))
                            .foregroundColor(step >= n ? BLTheme.ink : BLTheme.sub)
                            .frame(width: 20, height: 20)
                            .background(step >= n ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                            .clipShape(Circle())
                        Text(name).font(BLFont.body(11.5, step == n ? .bold : .semibold))
                            .foregroundColor(step == n ? BLTheme.text : BLTheme.sub)
                    }
                }
                .buttonStyle(.plain)
                .disabled(n >= step)
                if n < 4 { Rectangle().fill(BLTheme.stroke).frame(width: 22, height: 1) }
            }
            Spacer()
            if step > 1 {
                GhostButton(label: "Start over", icon: "arrow.counterclockwise", tint: BLTheme.sub) { resetFlow() }
            }
        }
    }

    private func resetFlow() {
        withAnimation {
            step = 1; criteria = DatabaseListCriteria(); pickedType = false
            page = .empty; ran = false; error = ""; note = ""; pageIndex = 1
            minValueText = ""; maxValueText = ""
        }
    }

    // MARK: Step 1 — what type of list?

    private var stepType: some View {
        Panel(title: "1 · What type of list?", icon: "rectangle.stack.fill", glow: true) {
            Text("Every type maps to a real public-record signal in the database — no signal, no list, and it says so.")
                .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: BLScale.cardMin(210, spacing: 10)), spacing: 10)], spacing: 10) {
                ForEach(DatabaseListType.allCases) { t in
                    Button {
                        criteria.type = t; pickedType = true
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { step = 2 }
                    } label: {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 8) {
                                IconBadge(system: t.icon, size: 26, active: criteria.type == t && pickedType)
                                Text(t.label).font(BLFont.body(13, .bold)).foregroundColor(BLTheme.text)
                                Spacer()
                                if !t.indexedToday {
                                    Text("INDEXING").font(BLFont.mono(8, .bold)).foregroundColor(.orange).tracking(0.6)
                                        .padding(.vertical, 2).padding(.horizontal, 6)
                                        .background(Color.orange.opacity(0.12)).clipShape(Capsule())
                                }
                            }
                            Text(t.signalBlurb).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
                        .background(criteria.type == t && pickedType ? BLTheme.gold.opacity(0.10) : BLTheme.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(criteria.type == t && pickedType ? BLTheme.gold.opacity(0.5) : BLTheme.stroke, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Step 2 — where?

    private var stepWhere: some View {
        Panel(title: "2 · Where?", icon: "mappin.and.ellipse", glow: true) {
            HStack(spacing: 8) {
                IconBadge(system: criteria.type.icon, size: 24, active: true)
                Text(criteria.type.label).font(BLFont.body(13, .bold)).foregroundColor(BLTheme.text)
                Text("· \(criteria.type.signalBlurb)").font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub).lineLimit(2)
                Spacer()
            }
            HStack(spacing: 10) {
                Field(title: "State", text: $criteria.area.state, prompt: "GA or Georgia")
                Field(title: "County", text: $criteria.area.county, prompt: "County name")
                Field(title: "City", text: $criteria.area.city, prompt: "City name")
                Field(title: "ZIP", text: $criteria.area.zip, prompt: "ZIP code")
            }
            whereInterpretationHint
            if model.lastMapBounds != nil || criteria.area.hasViewport {
                HStack(spacing: 8) {
                    Button {
                        if criteria.area.hasViewport {
                            criteria.area.north = nil; criteria.area.south = nil
                            criteria.area.east = nil; criteria.area.west = nil
                        } else if let b = model.lastMapBounds {
                            criteria.area.north = b.north; criteria.area.south = b.south
                            criteria.area.east = b.east; criteria.area.west = b.west
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: criteria.area.hasViewport ? "checkmark.circle.fill" : "circle")
                                .font(.blSystem(size: 11, weight: .bold))
                            Text("Use current map viewport").font(BLFont.body(11.5, .semibold))
                        }
                        .foregroundColor(criteria.area.hasViewport ? BLTheme.ink : BLTheme.sub)
                        .padding(.vertical, 6).padding(.horizontal, 11)
                        .background(criteria.area.hasViewport ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2))
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(criteria.area.hasViewport ? Color.clear : BLTheme.stroke, lineWidth: 1))
                    }.buttonStyle(.plain)
                    Text("The area the Property Map is currently showing.").font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
                    Spacer()
                }
            }
            if !criteria.type.indexedToday { coveragePanel }
            HStack(spacing: 10) {
                GhostButton(label: "Back", icon: "chevron.left", tint: BLTheme.sub) { withAnimation { step = 1 } }
                if criteria.type.indexedToday {
                    GoldButton(label: "Continue", icon: "arrow.right") { withAnimation { step = 3 } }
                        .disabled(!criteria.area.hasLocation)
                }
                if !criteria.area.hasLocation {
                    Text("Pick at least a state, county, city, ZIP, or the map viewport.")
                        .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub)
                }
                Spacer()
            }
        }
    }

    /// Live confirmation of how the typed location will actually be searched — so a buyer who
    /// enters "Georgia" or "Bibb County" SEES it become "GA" / "Bibb" instead of silently getting
    /// zero results. A genuinely unrecognized state gets a gentle format tip, not a dead end.
    @ViewBuilder private var whereInterpretationHint: some View {
        let rawState = criteria.area.state.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawCounty = criteria.area.county.trimmingCharacters(in: .whitespacesAndNewlines)
        let stateChanged = !rawState.isEmpty && rawState.uppercased() != criteria.area.canonicalState
        let countyChanged = !rawCounty.isEmpty && rawCounty != criteria.area.canonicalCounty
        if USStates.isUnresolvedState(rawState) {
            Label("\"\(rawState)\" isn't a state we recognize — use a 2-letter code (GA) or full name (Georgia).",
                  systemImage: "info.circle")
                .font(BLFont.body(10.5, .medium)).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if stateChanged || countyChanged {
            Label("Searching \(criteria.area.summary)", systemImage: "checkmark.circle")
                .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.green)
        }
    }

    /// Honest coverage state for list types the index is still integrating — offers
    /// real adjacent database-backed lists instead of a paste prompt or fake rows.
    private var coveragePanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(criteria.type.coverageNote ?? "", systemImage: "clock.badge.exclamationmark")
                .font(BLFont.body(11.5, .medium)).foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(criteria.type.fallbackTypes) { t in
                    Button {
                        criteria.type = t
                        withAnimation { step = criteria.area.hasLocation ? 3 : 2 }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: t.icon).font(.blSystem(size: 10, weight: .bold))
                            Text(t.label).font(BLFont.body(11.5, .semibold))
                        }
                        .foregroundColor(BLTheme.gold).padding(.vertical, 6).padding(.horizontal, 11)
                        .background(BLTheme.bg2).clipShape(Capsule())
                        .overlay(Capsule().stroke(BLTheme.gold.opacity(0.4), lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            Text("Already have this list from your county? Import it under My Leads → Import external leads.")
                .font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub)
        }
        .padding(11).background(Color.orange.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.orange.opacity(0.25), lineWidth: 1))
    }

    // MARK: Step 3 — optional filters

    private var stepFilters: some View {
        Panel(title: "3 · Optional filters", icon: "slider.horizontal.3", glow: true) {
            Text("\(criteria.type.label) · \(criteria.area.summary)").font(BLFont.body(12.5, .bold)).foregroundColor(BLTheme.gold)
            HStack(spacing: 12) {
                moneyField("Min assessed value $", text: $minValueText) { criteria.minValue = $0 }
                moneyField("Max assessed value $", text: $maxValueText) { criteria.maxValue = $0 }
            }
            HStack(spacing: 12) {
                dayField("Last sale after (YYYY-MM-DD)", text: $criteria.soldAfter)
                dayField("Last sale before (YYYY-MM-DD)", text: $criteria.soldBefore)
            }
            FlowLayout(spacing: 8) {
                filterChip("Mailing ≠ property (absentee)", on: criteria.absenteeOnly) {
                    criteria.absenteeOnly.toggle(); if criteria.absenteeOnly { criteria.ownerOccupiedOnly = false }
                }
                filterChip("Owner occupied (mailing = property)", on: criteria.ownerOccupiedOnly) {
                    criteria.ownerOccupiedOnly.toggle(); if criteria.ownerOccupiedOnly { criteria.absenteeOnly = false }
                }
            }
            // Fields the public index does NOT carry — said plainly, never faked.
            VStack(alignment: .leading, spacing: 5) {
                Text("NOT IN THE PUBLIC INDEX YET").font(BLFont.mono(8.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
                Text("Bedrooms/baths, lot size, property type, and owner phone/email aren't public assessor fields in this index — lists never guess them. Value, sale history, owner names, and addresses are real.")
                    .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10).background(BLTheme.bg2.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                GhostButton(label: "Back", icon: "chevron.left", tint: BLTheme.sub) { withAnimation { step = 2 } }
                GoldButton(label: "Show results", icon: "magnifyingglass") {
                    // Trial gate (macOS): list-building is a paid feature once the 14-day trial ends.
                    guard REAccess.allowsPaidFeatures else { showPaywall = true; return }
                    withAnimation { step = 4 }
                    startSearch()
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private func moneyField(_ title: String, text: Binding<String>, set: @escaping (Int?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(BLFont.mono(9, .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
            TextField("any", text: Binding(get: { text.wrappedValue }, set: { v in
                text.wrappedValue = v
                set(Int(v.filter(\.isNumber)))
            }))
            .textFieldStyle(.plain).font(.blSystem(size: 14, weight: .medium, design: .rounded)).foregroundColor(BLTheme.text)
            .padding(.vertical, 10).padding(.horizontal, 12).background(BLTheme.bg2)
            .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func dayField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased()).font(BLFont.mono(9, .bold)).foregroundColor(BLTheme.sub).tracking(0.6)
            TextField("any", text: text)
                .textFieldStyle(.plain).font(.blSystem(size: 13, weight: .medium, design: .monospaced)).foregroundColor(BLTheme.text)
                .padding(.vertical, 10).padding(.horizontal, 12).background(BLTheme.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                    text.wrappedValue.isEmpty || DatabaseListCriteria.validDay(text.wrappedValue) != nil
                        ? BLTheme.stroke : BL.danger.opacity(0.6), lineWidth: 1))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func filterChip(_ label: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.blSystem(size: 10, weight: .bold))
                Text(label).font(BLFont.body(11.5, .semibold))
            }
            .foregroundColor(on ? BLTheme.ink : BLTheme.sub).padding(.vertical, 6).padding(.horizontal, 11)
            .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(BLTheme.bg2)).clipShape(Capsule())
            .overlay(Capsule().stroke(on ? Color.clear : BLTheme.stroke, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    // MARK: Step 4 — results (count first)

    private var stepResults: some View {
        Panel(title: "4 · Results", icon: "checkmark.seal", glow: true) {
            Text(criteria.summary).font(BLFont.body(12, .bold)).foregroundColor(BLTheme.gold)
            // Which Results-step case renders is decided by a PURE, unit-tested resolver
            // (ListBuilderResults.state) — the view only DRAWS the chosen case. That keeps the
            // count-first honesty rules assertable: loading/idle show no number, an unreachable
            // database is NEVER papered over with a fabricated count, a rejected query is a "fix the
            // search" state (not a wifi one), a real zero is shown plainly, and only a real answer
            // is `.counted` with the server's own total.
            switch ListBuilderResults.state(loading: loading, ran: ran, error: error,
                                            errorIsConnectivity: errorIsConnectivity, page: page,
                                            unresolvedState: USStates.isUnresolvedState(criteria.area.state)) {
            case .idle:
                EmptyView()
            case .loading:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Counting matching records…").font(BLFont.body(12.5, .semibold)).foregroundColor(BLTheme.text)
                }
                .padding(.vertical, 6)
            case .unreachable:
                EmptyState(icon: "wifi.exclamationmark", title: "Can't reach the live index",
                           hint: "The database didn't answer, so there is no count to show — nothing was fabricated to fill the gap. Check your connection and try again.")
                resultErrorActions
            case .rejected(let reason):
                // The database answered and rejected the query — show its plain reason and send
                // the buyer back to fix the search, not to check their connection.
                EmptyState(icon: "exclamationmark.magnifyingglass", title: "That search needs a tweak",
                           hint: reason.isEmpty ? "Adjust the area or filters and try again." : reason)
                resultErrorActions
            case .empty(let unresolved):
                // COUNT FIRST — the honest zero still leads with the database's own "0", never a hidden gap.
                countHeadline
                if ListBuilderResults.isMasked(page) { maskedCapRow }
                EmptyState(icon: "magnifyingglass", title: "No matching records",
                           hint: unresolved
                               ? "\"\(criteria.area.state.trimmingCharacters(in: .whitespacesAndNewlines))\" isn't a recognized state — try a 2-letter code (GA) or full name (Georgia). No records were invented."
                               : "The database answered with zero matches for these criteria. Widen the area or loosen the filters — no records were invented.")
            case .counted(_, let masked):
                // COUNT FIRST — the headline number, straight from the database.
                countHeadline
                if masked { maskedCapRow }
                actionRow
                if !note.isEmpty { Label(note, systemImage: "checkmark.circle.fill").font(BLFont.body(12, .bold)).foregroundColor(BLTheme.green) }
                Text("PREVIEW — tap rows to select").font(BLFont.mono(9, .bold)).foregroundColor(BLTheme.sub).tracking(0.8).padding(.top, 4)
                DatabaseRecordSaveList(records: page.results,
                                       origin: .databaseList,
                                       apiCategory: criteria.categoryOverride ?? criteria.type.apiCategory,
                                       criteriaSummary: criteria.summary)
                pager
            }
        }
    }

    /// COUNT-FIRST headline — the big number is the database's real total (or its real row count when
    /// the server omits a total); it is never a padded or fabricated figure.
    private var countHeadline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(PIIndexFormat.full(ListBuilderResults.displayCount(page)))
                .font(.blSystem(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(BLTheme.goldGrad)
            Text("matching properties").font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
            Spacer()
            tierPill
        }
    }

    /// Precise, calm cap copy — full counts are always real; only page/export size is capped until an
    /// owned database key is added.
    private var maskedCapRow: some View {
        HStack(spacing: 8) {
            Text("25-row preview · full count shown · export capped until a database key is added")
                .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
            GhostButton(label: "Add key", icon: "key.fill", tint: BLTheme.gold) { go(.settings) }
            Spacer()
        }
    }

    private var resultErrorActions: some View {
        HStack(spacing: 10) {
            GhostButton(label: errorIsConnectivity ? "Retry" : "Adjust search", icon: errorIsConnectivity ? "arrow.clockwise" : "slider.horizontal.3", tint: BLTheme.gold) {
                if errorIsConnectivity { startSearch() } else { withAnimation { step = 2 } }
            }
            GhostButton(label: "Back", icon: "chevron.left", tint: BLTheme.sub) { withAnimation { step = 3 } }
            Spacer()
        }
    }

    @ViewBuilder private var tierPill: some View {
        if page.masked == true {
            StatusPill(text: "Preview tier · \(page.per_page ?? perPage)-row pages", tint: BLTheme.gold)
        } else if let tier = page.tier, !tier.isEmpty {
            StatusPill(text: "\(tier.capitalized) tier · \(page.per_page ?? perPage)-row pages", tint: .blue)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            TextField("Name this list (e.g. \"Fulton absentee\")", text: $listName)
                .textFieldStyle(.plain).font(BLFont.body(13, .medium)).foregroundColor(BLTheme.text)
                .padding(.vertical, 9).padding(.horizontal, 12).background(BLTheme.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(BLTheme.stroke, lineWidth: 1))
                .frame(maxWidth: 300)
            GoldButton(label: "Save list", icon: "tray.and.arrow.down") { saveList() }
            GhostButton(label: "Open in Map", icon: "mappin.and.ellipse", tint: BLTheme.gold) { openInMap() }
            GhostButton(label: exporting ? "Exporting…" : "Export CSV", icon: "square.and.arrow.up", tint: BLTheme.gold) { exportCSV() }
                .disabled(exporting)
            GhostButton(label: "Refine", icon: "slider.horizontal.3", tint: BLTheme.sub) { withAnimation { step = 3 } }
            Spacer()
        }
    }

    @ViewBuilder private var pager: some View {
        let total = ListBuilderResults.displayCount(page)
        let pages = ListBuilderResults.pageCount(total: total, perPage: page.per_page ?? perPage)
        if pages > 1 {
            HStack(spacing: 10) {
                GhostButton(label: "Previous", icon: "chevron.left", tint: BLTheme.sub) {
                    if pageIndex > 1 { pageIndex -= 1; runSearch() }
                }.disabled(pageIndex <= 1 || loading)
                Text("Page \(pageIndex) of \(PIIndexFormat.full(pages))")
                    .font(BLFont.mono(11.5, .semibold)).foregroundColor(BLTheme.sub)
                GhostButton(label: "Next", icon: "chevron.right", tint: BLTheme.sub) {
                    if pageIndex < pages { pageIndex += 1; runSearch() }
                }.disabled(pageIndex >= pages || loading)
                Spacer()
            }.padding(.top, 6)
        }
    }

    // MARK: saved lists

    @ViewBuilder private var savedListsPanel: some View {
        if !model.databaseLists.isEmpty {
            Panel(title: "Saved database lists", icon: "square.stack.3d.up.fill") {
                HStack {
                    Text("Monitor a list — every \u{201C}Check all now\u{201D} re-runs it and notifies you only when a genuinely new parcel appears.")
                        .font(BLFont.body(10.5)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    GhostButton(label: "Monitors", icon: "bell.badge", tint: BLTheme.gold) { showMonitors = true }
                }
                ForEach(model.databaseLists) { saved in
                    Button { detailList = saved } label: {
                        HStack(spacing: 10) {
                            IconBadge(system: saved.criteria.type.icon, size: 30, active: false)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(saved.name.isEmpty ? saved.criteria.type.label : saved.name)
                                    .font(BLFont.body(13.5, .bold)).foregroundColor(BLTheme.text)
                                HStack(spacing: 6) {
                                    Text(saved.criteria.summary).font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub).lineLimit(1)
                                    if let t = saved.lastTotal {
                                        Text("· \(PIIndexFormat.full(t)) at last run").font(BLFont.mono(10, .semibold)).foregroundColor(BLTheme.gold)
                                    }
                                }
                            }
                            Spacer()
                            GhostButton(label: "Details", icon: "doc.text.magnifyingglass", tint: BLTheme.gold) { detailList = saved }
                            GhostButton(label: "Monitor", icon: "bell.badge", tint: BLTheme.gold) { addMonitor(name: saved.name, criteria: saved.criteria) }
                            GhostButton(label: "Run", icon: "play.fill", tint: BLTheme.gold) { load(saved) }
                            GhostButton(label: "Delete", icon: "trash", tint: BL.danger) { pendingDelete = saved }
                        }
                        .contentShape(Rectangle())
                        .padding(11).background(BLTheme.bg2).clipShape(RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(BLTheme.stroke, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .confirmationDialog("Delete this saved list?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let s = pendingDelete { model.deleteDatabaseList(s) }; pendingDelete = nil }
                Button("Cancel", role: .cancel) {}
            } message: { Text("This permanently removes it — there is no undo.") }
        }
    }

    // MARK: actions

    private func startSearch() {
        pageIndex = 1
        runSearch()
    }

    private func runSearch() {
        loading = true; error = ""; note = ""
        searchGeneration += 1
        let gen = searchGeneration
        let crit = criteria, p = pageIndex
        Task {
            do {
                let result = try await RealEstateAPI.listSearch(crit, page: p, perPage: perPage)
                await MainActor.run {
                    guard gen == searchGeneration else { return }   // superseded — a newer run owns the UI
                    loading = false; ran = true; page = result; error = ""
                    emitListsUISmoke(total: result.total ?? result.results.count, rows: result.results.count, error: nil)
                }
            } catch {
                await MainActor.run {
                    guard gen == searchGeneration else { return }   // superseded — a newer run owns the UI
                    loading = false; ran = true; page = .empty
                    // Distinguish "database unreachable" from "query rejected" so the buyer gets the
                    // right fix (check connection vs adjust the search), not a blanket "can't reach".
                    errorIsConnectivity = (error as? RealEstateAPIError)?.isConnectivity ?? true
                    self.error = (error as? RealEstateAPIError)?.errorDescription ?? error.localizedDescription
                    emitListsUISmoke(total: 0, rows: 0, error: error.localizedDescription)
                }
            }
        }
    }

    private func load(_ saved: SavedDatabaseList) {
        // Same paid workflow as "Show results" — a saved list's Run must not bypass the gate.
        guard REAccess.allowsPaidFeatures else { showPaywall = true; return }
        criteria = saved.criteria
        listName = saved.name
        pickedType = true
        minValueText = saved.criteria.minValue.map(String.init) ?? ""
        maxValueText = saved.criteria.maxValue.map(String.init) ?? ""
        withAnimation { step = 4 }
        startSearch()
    }

    private func saveList() {
        var saved = SavedDatabaseList(name: listName.trimmingCharacters(in: .whitespaces), criteria: criteria)
        if saved.name.isEmpty { saved.name = "\(criteria.type.label) — \(criteria.area.summary)" }
        saved.lastTotal = page.total ?? page.results.count
        saved.lastRunAt = Date()
        // v2 snapshot: what the buyer saw, when, and under which tier caps.
        saved.updatedAt = Date()
        saved.lastPreview = Array(page.results.prefix(25))
        saved.lastTier = page.tier
        saved.lastPerPage = page.per_page
        model.upsert(saved)
        note = "Saved \"\(saved.name)\"."
        listName = ""
    }

    private func openInMap() {
        model.pendingPropertyMapRequest = .forList(criteria, total: page.total)
        go(.map)
    }

    /// Export up to the tier's row cap of REAL rows, with an honest note when the
    /// export is smaller than the full count (preview tier) — never padded.
    private func exportCSV() {
        // The paywall sells "CSV / list export" as paid — the export path must enforce it.
        guard REAccess.allowsPaidFeatures else { showPaywall = true; return }
        exporting = true
        let crit = criteria
        Task {
            // nil = couldn't reach the database; a real empty page = genuine zero. Collapsing the
            // two made an outage read as "no rows" — the exact failure the results state machine
            // exists to prevent.
            let fetched = try? await RealEstateAPI.listSearch(crit, page: 1, perPage: 2000)
            await MainActor.run {
                exporting = false
                guard let export = fetched else { note = "Couldn't reach the database — check your connection and try again."; return }
                guard !export.results.isEmpty else { note = "Nothing to export — the database returned no rows."; return }
                let name = "list-\(crit.type.rawValue)-\(Int(Date().timeIntervalSince1970)).csv"
                guard exportTextFile(suggestedName: name, contents: DatabaseListEngine.csv(export.results), type: .commaSeparatedText) != nil else {
                    note = "Export cancelled."; return
                }
                let total = export.total ?? export.results.count
                note = export.results.count < total
                    ? "Exported \(export.results.count) of \(PIIndexFormat.full(total)) rows (tier cap — add a key in Settings for bigger exports)."
                    : "Exported \(export.results.count) rows."
            }
        }
    }

    // MARK: DEV-ONLY UI smoke (BLRE_LISTS_UI_SMOKE=1) — proves the guided builder
    // returns database-backed results end-to-end. Never ships enabled.

    private func runListsUISmokeIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["BLRE_LISTS_UI_SMOKE"] == "1", !ran, !loading else { return }
        criteria = DatabaseListCriteria()
        criteria.type = .absentee
        criteria.area.state = env["BLRE_SMOKE_STATE"] ?? "RI"
        pickedType = true
        step = 4
        startSearch()
    }

    private func emitListsUISmoke(total: Int, rows: Int, error: String?) {
        let env = ProcessInfo.processInfo.environment
        guard env["BLRE_LISTS_UI_SMOKE"] == "1" else { return }
        let line = error.map { "BLRE_LISTS_UI|phase=error|error=\($0)" }
            ?? "BLRE_LISTS_UI|phase=results|type=\(criteria.type.rawValue)|state=\(criteria.area.state)|total=\(total)|rows=\(rows)"
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8) ?? Data())
        #if os(macOS)
        if env["BLRE_LISTS_UI_SMOKE_QUIT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
        }
        #endif
    }
}

// MARK: - Results-step view-model (PURE — unit-tested in EngineTests → testListBuilderResultsState)
//
// The count-first Results step is a small state machine over (loading, ran, error, page). It used to
// be inlined in `DatabaseListBuilder.stepResults`; pulling it out makes the HONESTY rules assertable
// instead of eyeballed:
//   • `.loading` / `.idle` never surface a number;
//   • a database that DIDN'T answer is `.unreachable` — NO count is fabricated to fill the gap;
//   • a database that answered and REJECTED the query is `.rejected` (fix the search, not the wifi);
//   • a real zero is `.empty` — shown plainly, never hidden or padded;
//   • only a real answer is `.counted`, and its total is the server's OWN number.
enum ListBuilderResultState: Equatable {
    case idle                              // Results step reached, no search run yet
    case loading                           // counting matching records…
    case unreachable                       // DB didn't answer — no count shown, nothing invented
    case rejected(String)                  // DB answered and rejected the query — its reason
    case empty(unresolvedState: Bool)      // a real zero (state typo vs a genuine no-match)
    case counted(total: Int, masked: Bool) // count-first headline; `total` is the server's real number
}

enum ListBuilderResults {
    /// The single source of truth for which Results-step case renders. `unresolvedState` is precomputed
    /// by the view from the typed state string (USStates.isUnresolvedState) so this stays UI-free.
    static func state(loading: Bool, ran: Bool, error: String, errorIsConnectivity: Bool,
                      page: PropertyPage, unresolvedState: Bool) -> ListBuilderResultState {
        if loading { return .loading }
        if !error.isEmpty { return errorIsConnectivity ? .unreachable : .rejected(error) }
        guard ran else { return .idle }
        if (page.total ?? 0) == 0 { return .empty(unresolvedState: unresolvedState) }
        return .counted(total: displayCount(page), masked: isMasked(page))
    }

    /// The count the headline shows — the server's real total, or the real row count when the server
    /// omits a total. NEVER a padded or fabricated figure.
    static func displayCount(_ page: PropertyPage) -> Int { page.total ?? page.results.count }

    /// Preview-tier masking flag (page/export capped; the full count is still real). `nil` → false.
    static func isMasked(_ page: PropertyPage) -> Bool { page.masked == true }

    /// Total pages for the pager — mirrors the inlined ceil() so navigation math is tested too.
    static func pageCount(total: Int, perPage: Int) -> Int {
        max(1, Int(ceil(Double(total) / Double(max(1, perPage)))))
    }
}

// MARK: - Saved-list detail (Workspace v2)
//
// The first-class view of a saved database list: criteria + the real signal behind
// it, dated count/preview snapshots, honest tier caps, and every action — Refresh
// Count, Open in Map, Export CSV, Save Preview to My Leads, Duplicate & Refine.
struct SavedDatabaseListDetail: View {
    @EnvironmentObject var model: AppModel
    @State var saved: SavedDatabaseList
    var onDuplicate: (DatabaseListCriteria) -> Void = { _ in }
    var onOpenMap: (DatabaseListCriteria, Int?) -> Void = { _, _ in }
    var onAddKey: () -> Void = {}

    @State private var refreshing = false
    @State private var exporting = false
    @State private var note = ""
    @State private var error = ""
    @State private var showPaywall = false

    private var preview: [PropertyRecord] { saved.lastPreview ?? [] }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                IconBadge(system: saved.criteria.type.icon, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(saved.name.isEmpty ? saved.criteria.type.label : saved.name)
                        .font(.blSystem(size: 18, weight: .heavy, design: .rounded)).foregroundColor(BLTheme.text)
                    Text(saved.criteria.summary).font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.gold)
                }
                Spacer()
            }

            // The real signal behind this list — never a black box.
            Panel(title: "Signal", icon: "waveform.path.ecg") {
                Text(saved.criteria.categoryOverride.map { "Server category: \($0) — " + DatabaseListCriteria.humanCategory($0) }
                     ?? saved.criteria.type.signalBlurb)
                    .font(BLFont.body(12, .regular)).foregroundColor(BLTheme.sub).fixedSize(horizontal: false, vertical: true)
                if let cat = saved.criteria.categoryOverride ?? saved.criteria.type.apiCategory {
                    Text("Query category: \(cat)").font(BLFont.mono(10, .semibold)).foregroundColor(BLTheme.sub)
                }
            }

            // Count + caps — dated snapshots, full count vs what this tier can page.
            Panel(title: "Count & caps", icon: "number.circle", glow: true) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(saved.lastTotal.map { PIIndexFormat.full($0) } ?? "—")
                        .font(.blSystem(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(BLTheme.goldGrad)
                    Text("matching properties").font(BLFont.body(12.5, .semibold)).foregroundColor(BLTheme.text)
                    Spacer()
                    GhostButton(label: refreshing ? "Refreshing…" : "Refresh count", icon: "arrow.clockwise", tint: BLTheme.gold) { refresh() }
                        .disabled(refreshing)
                }
                Text(saved.capSummary())
                    .font(BLFont.body(11, .medium)).foregroundColor(BLTheme.sub)
                if (saved.lastTier ?? "preview") == "preview" {
                    HStack(spacing: 8) {
                        Text("25-row preview · full count shown · export capped until a database key is added")
                            .font(BLFont.body(10.5, .medium)).foregroundColor(BLTheme.sub)
                        GhostButton(label: "Add key", icon: "key.fill", tint: BLTheme.gold) { onAddKey() }
                        Spacer()
                    }
                }
                HStack(spacing: 14) {
                    detailStamp("Created", saved.created)
                    if let u = saved.updatedAt { detailStamp("Updated", u) }
                    if let r = saved.lastRunAt { detailStamp("Last run", r) }
                }
                if !error.isEmpty {
                    Label(error, systemImage: "wifi.exclamationmark").font(BLFont.body(11.5, .semibold)).foregroundColor(BL.danger)
                }
                if !note.isEmpty {
                    Label(note, systemImage: "checkmark.circle.fill").font(BLFont.body(12, .bold)).foregroundColor(BLTheme.green)
                }
            }

            // Actions.
            Panel(title: "Actions", icon: "bolt.fill") {
                HStack(spacing: 10) {
                    GoldButton(label: "Open in Map", icon: "mappin.and.ellipse") { onOpenMap(saved.criteria, saved.lastTotal) }
                    GhostButton(label: exporting ? "Exporting…" : "Export CSV", icon: "square.and.arrow.up", tint: BLTheme.gold) { exportCSV() }
                        .disabled(exporting)
                    GhostButton(label: "Save preview to My Leads", icon: "person.crop.circle.badge.plus", tint: BLTheme.green) { savePreviewToLeads() }
                        .disabled(preview.isEmpty)
                    GhostButton(label: "Duplicate & refine", icon: "square.on.square", tint: BLTheme.gold) { onDuplicate(saved.criteria) }
                    Spacer()
                }
                Text("Save preview adds the \(preview.count) snapshot rows below (deduped against My Leads). Export re-queries the database up to your tier's row cap.")
                    .font(BLFont.body(10, .medium)).foregroundColor(BLTheme.sub)
            }

            // Preview rows (dated snapshot — refresh to update).
            Panel(title: "Preview rows (\(preview.count))", icon: "list.bullet.rectangle") {
                if preview.isEmpty {
                    EmptyState(icon: "list.bullet.rectangle",
                               title: "No preview snapshot yet",
                               hint: "Refresh the count to pull the first page of real rows for this list.")
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach(preview) { record in PropertyRecordRow(record: record) }
                    }
                }
            }
        }.blScreenPadding(26) }
        .sheetFrame(720, 760)
        .sheet(isPresented: $showPaywall) { TrialPaywallSheet().sheetCloseBar() }
    }

    @ViewBuilder private func detailStamp(_ label: String, _ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(BLFont.mono(8.5, .bold)).foregroundColor(BLTheme.sub).tracking(0.8)
            Text(date.formatted(date: .abbreviated, time: .shortened)).font(BLFont.body(11.5, .semibold)).foregroundColor(BLTheme.text)
        }
    }

    /// Re-run the saved criteria: fresh total + preview snapshot + tier caps, persisted.
    private func refresh() {
        // Same paid workflow as the builder's "Show results" — a saved list must not bypass the gate.
        guard REAccess.allowsPaidFeatures else { showPaywall = true; return }
        refreshing = true; error = ""; note = ""
        let crit = saved.criteria
        Task {
            do {
                let page = try await RealEstateAPI.listSearch(crit, page: 1, perPage: 25)
                await MainActor.run {
                    refreshing = false
                    saved.lastTotal = page.total ?? page.results.count
                    saved.lastRunAt = Date()
                    saved.updatedAt = Date()
                    saved.lastPreview = Array(page.results.prefix(25))
                    saved.lastTier = page.tier
                    saved.lastPerPage = page.per_page
                    model.upsert(saved)
                    note = "Refreshed — count and preview are current as of now."
                }
            } catch {
                await MainActor.run {
                    refreshing = false
                    self.error = "Couldn't reach the live index — the saved snapshot is unchanged. Nothing was fabricated."
                }
            }
        }
    }

    private func savePreviewToLeads() {
        let result = model.saveDatabaseRecords(preview,
                                               origin: .databaseList,
                                               apiCategory: saved.criteria.categoryOverride ?? saved.criteria.type.apiCategory,
                                               criteriaSummary: saved.criteria.summary)
        note = result.added == 0
            ? "All \(result.duplicates) preview rows are already in My Leads."
            : "Saved \(result.added) to My Leads\(result.duplicates > 0 ? " · \(result.duplicates) already saved" : "")."
    }

    private func exportCSV() {
        // The paywall sells "CSV / list export" as paid — the export path must enforce it.
        guard REAccess.allowsPaidFeatures else { showPaywall = true; return }
        exporting = true; error = ""; note = ""
        let crit = saved.criteria
        Task {
            // nil = unreachable, distinct from a genuine zero-row page (outage must never read as "no rows").
            let fetched = try? await RealEstateAPI.listSearch(crit, page: 1, perPage: 2000)
            await MainActor.run {
                exporting = false
                guard let export = fetched else { note = "Couldn't reach the database — check your connection and try again."; return }
                guard !export.results.isEmpty else { note = "Nothing to export — the database returned no rows."; return }
                let name = "list-\(crit.type.rawValue)-\(Int(Date().timeIntervalSince1970)).csv"
                guard exportTextFile(suggestedName: name, contents: DatabaseListEngine.csv(export.results), type: .commaSeparatedText) != nil else {
                    note = "Export cancelled."; return
                }
                let total = export.total ?? export.results.count
                note = export.results.count < total
                    ? "Exported \(export.results.count) of \(PIIndexFormat.full(total)) rows — export capped until a database key is added."
                    : "Exported \(export.results.count) rows."
            }
        }
    }
}
#endif // circuit-convert
