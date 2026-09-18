#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Black Label Real Estate — RE-21 saved-search monitor UI + native notifier (app-only, not test-compiled).
//
// The buyer saves a List-Builder search here and "Check all now" re-runs every enabled monitor,
// firing a native notification through UNUserNotificationCenter ONLY when SavedSearchMonitorEngine
// reports a genuinely new parcel (the pure diff in SavedSearchMonitor.swift decides that — this file
// just performs the live re-run and posts). There is NO background scheduler in this build: checks
// run only when the buyer triggers them, and the copy says so. Un-metered: there is no per-alert
// charge and nothing is ever synthesized as "new."
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(UserNotifications) && !CIRCUIT_WINDOWS_SIM
import UserNotifications
#endif

// MARK: - Native notifier (the ONLY thing that touches UNUserNotificationCenter).
enum SavedSearchNotifier {
    static let pitch = "Save searches as monitors, then re-run them all with one tap — Check all now pings you the moment a re-run finds a genuinely new parcel. Un-metered; nothing is invented."

    /// Foreground presenter: the check runs while the app is frontmost, and without a willPresent
    /// delegate the OS suppresses the banner — the alert would silently never be shown at all.
    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
        static let shared = ForegroundPresenter()
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }

    /// Ask once for notification permission (no-op if already decided) and install the foreground
    /// presenter so a check run from inside the app can actually show its banner.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().delegate = ForegroundPresenter.shared
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    /// Post a native notification for a real new-match delta. Caller has already confirmed
    /// `delta.shouldNotify`; the copy + deep link come from the pure engine.
    static func post(for search: SavedSearch, delta: SavedSearchDelta) {
        guard delta.shouldNotify else { return }   // belt-and-suspenders: never fire on a non-delta
        let content = UNMutableNotificationContent()
        content.title = SavedSearchMonitorEngine.notificationTitle(search)
        content.body = SavedSearchMonitorEngine.notificationBody(search, newCount: delta.newCount)
        content.sound = .default
        content.userInfo = ["deepLink": SavedSearchMonitorEngine.deepLink(search),
                            "savedSearchID": search.id.uuidString]
        let req = UNNotificationRequest(identifier: "saved-search-\(search.id.uuidString)",
                                        content: content, trigger: nil)   // deliver now
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - The monitor management sheet.
struct SavedSearchMonitorSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var searches: [SavedSearch] = []
    @State private var status: String = ""
    @State private var checking = false
    /// Monitors whose LAST check failed to fetch (baseline untouched). Session-only honesty marker.
    @State private var failedIDs: Set<UUID> = []
    private let store = SavedSearchStore()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Saved-search monitors")
                    .font(BLFont.display(26, .semibold)).foregroundColor(BLTheme.text)
                Text(SavedSearchNotifier.pitch)
                    .font(BLFont.body(12)).foregroundColor(BLTheme.text.opacity(0.6))

                if searches.isEmpty {
                    Text(SavedSearchMonitorEngine.emptyNote)
                        .font(BLFont.body(12)).foregroundColor(BLTheme.text.opacity(0.55))
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(BLTheme.bg2).cornerRadius(10)
                } else {
                    ForEach(searches) { s in monitorRow(s) }
                    Button(checking ? "Checking…" : "Check all now") { Task { await checkAll() } }
                        .disabled(checking)
                        .font(BLFont.body(13, .semibold)).foregroundColor(BLTheme.text)
                }

                if !status.isEmpty {
                    Text(status).font(BLFont.mono(11)).foregroundColor(BLTheme.text.opacity(0.7))
                }
            }
            .blScreenPadding(24)
        }
        .sheetFrame(560, 640)
        .onAppear {
            SavedSearchNotifier.requestAuthorization()
            searches = store.load()
        }
    }

    @ViewBuilder private func monitorRow(_ s: SavedSearch) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(s.name.isEmpty ? "Saved search" : s.name)
                    .font(BLFont.body(14, .semibold)).foregroundColor(BLTheme.text)
                Spacer()
                Button(role: .destructive) { searches = store.remove(s.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundColor(BLTheme.text.opacity(0.5))
            }
            Text(s.summary).font(BLFont.body(11)).foregroundColor(BLTheme.text.opacity(0.6))
            Text(lastCheckedLine(s)).font(BLFont.mono(10)).foregroundColor(BLTheme.text.opacity(0.5))
            if failedIDs.contains(s.id) {
                Text("Last check failed — baseline kept, nothing was marked new. Run Check all now again.")
                    .font(BLFont.mono(10)).foregroundColor(BL.danger.opacity(0.85))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BLTheme.bg2).cornerRadius(10)
    }

    private func lastCheckedLine(_ s: SavedSearch) -> String {
        guard let t = s.lastCheckedAt else { return s.baselined ? "Baselined — watching for new parcels" : "Not checked yet" }
        let df = DateFormatter(); df.dateStyle = .short; df.timeStyle = .short
        return "Last checked \(df.string(from: t)) · \(s.lastNewCount) new"
    }

    /// Re-run every enabled saved search against the live index and fire notifications on real deltas.
    private func checkAll() async {
        checking = true; defer { checking = false }
        var updated: [SavedSearch] = []
        var fired = 0
        var failed: Set<UUID> = []
        for s in searches where s.enabled {
            // Fetch the observed window for this saved search (the same bounded query each cycle).
            // A failed fetch is NOT an observation: coercing it to an empty page would advance the
            // baseline to the empty set and stamp a "successful" check, making the next healthy run
            // report the ENTIRE result set as new — the exact fabricated delta the engine's
            // silent-baseline rule exists to prevent. Keep the search untouched and say so.
            guard let page = try? await RealEstateAPI.listSearch(s.criteria, page: 1, perPage: 100) else {
                failed.insert(s.id)
                updated.append(s)
                continue
            }
            let (next, delta) = SavedSearchMonitorEngine.observe(s, current: page.results)
            if delta.shouldNotify { SavedSearchNotifier.post(for: next, delta: delta); fired += 1 }
            updated.append(next)
        }
        // Preserve any disabled searches untouched.
        let disabled = searches.filter { !$0.enabled }
        let merged = updated + disabled
        store.save(merged)
        await MainActor.run {
            searches = merged
            failedIDs = failed
            let checked = updated.count - failed.count
            var line = "Checked \(checked) monitor\(checked == 1 ? "" : "s") · fired \(fired) notification\(fired == 1 ? "" : "s") on real new matches."
            if !failed.isEmpty {
                line += " \(failed.count) check\(failed.count == 1 ? "" : "s") failed — baselines kept."
            }
            status = line
        }
    }
}
#endif // circuit-convert
