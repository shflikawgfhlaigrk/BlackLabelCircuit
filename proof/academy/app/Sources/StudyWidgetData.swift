// Black Label Academy — cross-process study-habit payload (AC-21 widget lane).
//
// This is the SERIALIZED form of the app's live `StudyHabitSnapshot` (Sources/StudyHabit.swift).
// The reader app publishes it into the shared App Group container on every streak refresh; the
// separately-signed, sandboxed WidgetKit extension READS exactly these numbers and never recomputes
// them — so the Home-Screen / Notification-Center widget can never display a figure the app did not
// derive from real completed reviews (H-STREAK holds across the process boundary too). Foundation
// only, so the one file compiles unchanged into the macOS app, the iOS app, and the widget .appex.
import Foundation

struct StudyWidgetData: Codable, Equatable {
    var streak: Int
    var dueToday: Int
    var reviewedToday: Bool

    /// The WidgetKit timeline "kind" the extension registers (mirrors StudyHabitSnapshot.widgetKitKind).
    static let widgetKind = "com.blacklabel.academy.StudyHabitWidget"
    /// macOS App Group shared by the reader app (writer) and the widget extension (reader). Team-scoped.
    static let appGroup = "745ZPGFRA5.com.blacklabel.academy"
    static let fileName = "study-habit-widget.json"

    var headline: String { streak > 0 ? "\(streak)-day streak" : "Start your streak" }
    var dueLine: String { dueToday == 0 ? "Nothing due today" : "\(dueToday) due today" }

    /// Neutral "no data yet" payload (honest zeros — never a fabricated streak).
    static let empty = StudyWidgetData(streak: 0, dueToday: 0, reviewedToday: false)
    /// Gallery/placeholder payload shown before real data exists (clearly illustrative, not the user's).
    static let placeholder = StudyWidgetData(streak: 5, dueToday: 8, reviewedToday: false)

    /// The shared App Group container. The sandboxed widget gets it from the entitlement-backed API;
    /// the non-sandboxed reader app (no container API result) resolves the same on-disk group path.
    static func sharedContainerURL() -> URL? {
        let fm = FileManager.default
        if let u = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) { return u }
        #if os(macOS)
        // Non-sandboxed macOS reader: no container API result — resolve the on-disk group path.
        let home = fm.homeDirectoryForCurrentUser
        return home.appendingPathComponent("Library/Group Containers/\(appGroup)", isDirectory: true)
        #else
        // iOS is always sandboxed: without the app-group entitlement there is no shared container
        // (and no widget); nil keeps the publish/read paths honest no-ops.
        return nil
        #endif
    }

    /// Publish this payload for the widget to read. Called by the app on every streak refresh.
    func writeShared() {
        guard let dir = Self.sharedContainerURL() else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.fileName)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }

    /// Read the last-published payload. Called by the widget timeline provider. nil if never written.
    static func readShared() -> StudyWidgetData? {
        guard let dir = sharedContainerURL() else { return nil }
        let url = dir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(StudyWidgetData.self, from: data)
    }
}
