// Sovereign — private focus timeline.
//
// With the buyer's opt-in, Sovereign samples the frontmost application's Accessibility graph when
// app focus changes and stores a bounded, redacted timeline in a local SQLite database. The feature
// ships off and empty. It opens no network path.
//
// Accessibility permission is explicit runtime state. Without it, a row may contain only the app
// identity available from NSWorkspace and is labelled `accessibility-not-granted`; missing element
// text is never represented as a successful capture. Pure formatting and sanitization stay separate
// from the live AX and SQLite boundaries.
import Foundation
#if canImport(AppKit)
import AppKit
#else
/// Keeps the shared sampler API compilable on iOS; every use remains inside
/// `canImport(AppKit)` branches and therefore records nothing on that platform.
private final class NSRunningApplication {}
#endif
#if canImport(ApplicationServices)
import ApplicationServices
#endif
#if canImport(SQLite3) && !CIRCUIT_WINDOWS_SIM
import SQLite3
#else
import SwiftToolchainCSQLite
#endif
#if canImport(os) && !CIRCUIT_WINDOWS_SIM
import os
#else
import CircuitPortKit
#endif

// SQLite wants this for TEXT binds (SQLITE_TRANSIENT tells it to copy the bytes).
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Pure sample model

/// One local focus interval. Times are epoch seconds for compact SQLite storage.
struct FocusSample: Equatable, Codable, Identifiable {
    var id: Int64 = 0
    var startedAt: Double
    var endedAt: Double?
    var appBundleID: String
    var appName: String
    var windowTitle: String?
    var siteHost: String?
    var contextSummary: String?
    var deepContext: String?

    var started: Date { Date(timeIntervalSince1970: startedAt) }
    var ended: Date? { endedAt.map { Date(timeIntervalSince1970: $0) } }
}

// MARK: - Pure AX node + formatting (testable with no live AX)

/// A single element pulled from the focused-window AX walk. Plain strings so formatting is
/// deterministic and unit-testable.
struct AmbientNode: Equatable {
    var role: String        // AX role, e.g. "AXButton"
    var text: String        // best human text: title → value → roleDescription
    var url: String         // AXURL when the element exposes one (browser web areas / links)
}

enum AmbientFormat {
    /// Compact model-facing line: "[index] kind text -> url" (URL omitted when empty).
    static func line(index: Int, node: AmbientNode) -> String {
        let kind = shortKind(node.role)
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = "[\(index)] \(kind)"
        if !text.isEmpty { s += " " + collapse(text) }
        let u = node.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.isEmpty { s += " -> " + u }
        return s
    }

    /// Whole accessible-context string from an ordered node list (one line each).
    static func deepContext(_ nodes: [AmbientNode]) -> String {
        nodes.enumerated().map { line(index: $0.offset, node: $0.element) }.joined(separator: "\n")
    }

    /// Human role → short kind, dropping the system `AX` prefix.
    static func shortKind(_ role: String) -> String {
        role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
    }

    /// Collapse runs of whitespace/newlines into single spaces and cap length so one giant text
    /// area (e.g. a full Terminal scrollback) can't blow the line up unbounded — but we DO keep a
    /// generous window so shell scrollback / editor text is genuinely captured.
    static func collapse(_ s: String, cap: Int = 2000) -> String {
        let one = s.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == " " })
            .joined(separator: " ")
        return one.count > cap ? String(one.prefix(cap)) + "…" : one
    }

    /// Extract a bare host from a URL string (for the site_host column). Pure.
    static func host(from urlString: String) -> String? {
        let t = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let u = URL(string: t), let h = u.host else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// A one-line human summary for the context_summary column.
    static func summary(appName: String, windowTitle: String?, host: String?, nodeCount: Int, granted: Bool) -> String {
        if !granted { return "accessibility-not-granted" }
        var parts: [String] = [appName]
        if let w = windowTitle, !w.isEmpty { parts.append("“\(collapse(w, cap: 120))”") }
        if let h = host, !h.isEmpty { parts.append(h) }
        parts.append("\(nodeCount) elements")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Live AX capture of the focused window (self-contained; needs the Accessibility grant)

enum AmbientAX {
    static var isTrusted: Bool {
        #if canImport(ApplicationServices)
        return AXIsProcessTrusted()
        #else
        return false
        #endif
    }

    /// The result of one focused-window capture. `granted` distinguishes an honest empty (no AX
    /// grant) from a genuinely empty UI.
    struct Capture {
        var windowTitle: String?
        var siteHost: String?
        var nodes: [AmbientNode]
        var granted: Bool
    }

    /// Capture the frontmost app's focused-window element graph. Bounded in depth + node count so a
    /// deep UI can't hang the sampler. Returns granted=false (and NO fabricated nodes) when the
    /// Accessibility grant is missing.
    static func captureFocused(pid: pid_t, maxDepth: Int = 8, maxNodes: Int = 200) -> Capture {
        #if canImport(ApplicationServices)
        guard isTrusted else { return Capture(windowTitle: nil, siteHost: nil, nodes: [], granted: false) }
        let app = AXUIElementCreateApplication(pid)
        // Prefer the focused window; fall back to the app element itself.
        let root: AXUIElement = copyElement(app, kAXFocusedWindowAttribute) ?? app
        let windowTitle = str(root, kAXTitleAttribute)
        var nodes: [AmbientNode] = []
        walk(root, depth: 0, maxDepth: maxDepth, maxNodes: maxNodes, into: &nodes)
        // site_host: first node that exposes a URL (browser address bar / web area / link).
        let host = nodes.compactMap { AmbientFormat.host(from: $0.url) }.first
        return Capture(windowTitle: windowTitle.isEmpty ? nil : windowTitle,
                       siteHost: host, nodes: nodes, granted: true)
        #else
        return Capture(windowTitle: nil, siteHost: nil, nodes: [], granted: false)
        #endif
    }

    #if canImport(ApplicationServices)
    private static func walk(_ el: AXUIElement, depth: Int, maxDepth: Int, maxNodes: Int,
                             into out: inout [AmbientNode]) {
        guard depth <= maxDepth, out.count < maxNodes else { return }
        let node = describe(el)
        // Skip pure structural containers with no text and no url (they add noise, not context).
        if !node.text.isEmpty || !node.url.isEmpty || isMeaningfulRole(node.role) {
            out.append(node)
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return }
        for child in children {
            if out.count >= maxNodes { break }
            walk(child, depth: depth + 1, maxDepth: maxDepth, maxNodes: maxNodes, into: &out)
        }
    }

    /// Build a node: role + best text (title → value → roleDescription, reads TEXT FIELDS VERBATIM
    /// incl. Terminal shell scrollback) + any URL.
    private static func describe(_ el: AXUIElement) -> AmbientNode {
        let role = str(el, kAXRoleAttribute)
        let title = str(el, kAXTitleAttribute)
        let value = str(el, kAXValueAttribute)
        let roleDesc = str(el, kAXRoleDescriptionAttribute)
        let text = firstNonEmpty(title, value, roleDesc)
        let url = str(el, kAXURLAttribute)
        return AmbientNode(role: role, text: text, url: url)
    }

    private static func isMeaningfulRole(_ role: String) -> Bool {
        ["AXButton", "AXTextField", "AXTextArea", "AXStaticText", "AXLink", "AXCheckBox",
         "AXRadioButton", "AXMenuItem", "AXWebArea", "AXPopUpButton", "AXComboBox"].contains(role)
    }

    private static func copyElement(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success, let r = ref else { return nil }
        return (r as! AXUIElement)
    }

    private static func str(_ el: AXUIElement, _ attr: String) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return "" }
        if let s = ref as? String { return s }
        if let u = ref as? URL { return u.absoluteString }
        if let n = ref as? NSNumber { return n.stringValue }
        return ""
    }
    #endif

    private static func firstNonEmpty(_ ss: String...) -> String {
        for s in ss { let t = s.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { return t } }
        return ""
    }
}

// MARK: - Privacy boundary before ambient persistence

/// Sanitizes focused-window context before it can become a `FocusSample`. The ambient sampler
/// sees richer text than OCR alone (including accessible text fields), so it must share Recall's
/// credential-surface refusal and secret-redaction boundary rather than persisting the AX graph
/// verbatim. Pure and separately testable: raw focused-window text never reaches SQLite.
enum AmbientSanitizer {
    struct SafeContext: Equatable {
        var windowTitle: String?
        var siteHost: String?
        var deepContext: String?
        var redactedCount: Int
    }

    static func sanitize(appName: String, windowTitle: String?, siteHost: String? = nil,
                         deepContext: String?) -> SafeContext? {
        let rawTitle = windowTitle ?? ""
        let rawHost = siteHost ?? ""
        let rawDeep = deepContext ?? ""
        guard !SecretRedactor.isCredentialSurface(app: appName,
                                                   windowTitle: rawTitle,
                                                   text: rawDeep) else { return nil }

        let safeTitle = SecretRedactor.redact(rawTitle)
        let safeHost = SecretRedactor.redact(rawHost)
        let safeDeep = SecretRedactor.redact(rawDeep)
        return SafeContext(
            windowTitle: safeTitle.isEmpty ? nil : safeTitle.text,
            siteHost: safeHost.isEmpty ? nil : safeHost.text,
            deepContext: safeDeep.isEmpty ? nil : safeDeep.text,
            redactedCount: safeTitle.redactedCount + safeHost.redactedCount + safeDeep.redactedCount
        )
    }
}

// MARK: - SQLite timeline store (buyer-local, ships empty)

/// Thread-safe SQLite store for the buyer's local focus timeline.
final class AmbientTimelineStore {
    private var db: OpaquePointer?
    private let q = DispatchQueue(label: "com.blacklabel.sovereign.ambient.store")
    let path: String

    /// Process-wide store over the buyer's default timeline file. Thread-safe (internal serial
    /// queue), so the @MainActor sampler AND the agent's read-only `recent_activity` tool share ONE
    /// connection without actor hops.
    static let shared = AmbientTimelineStore(path: AmbientTimelineStore.defaultURL().path)

    /// Default buyer-local path: Application Support/Sovereign/ambient/focus-history.sqlite3.
    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Sovereign/ambient", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("focus-history.sqlite3")
    }

    init(path: String) {
        self.path = path
        q.sync {
            if sqlite3_open(path, &db) == SQLITE_OK {
                _ = execRaw("PRAGMA journal_mode=WAL;")
                _ = execRaw("""
                CREATE TABLE IF NOT EXISTS focus_timeline_entries (
                    entry_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    captured_at REAL NOT NULL,
                    finished_at REAL,
                    bundle_identifier TEXT NOT NULL,
                    application_label TEXT NOT NULL,
                    window_label TEXT,
                    website_host TEXT,
                    summary_text TEXT,
                    accessible_text TEXT
                );
                """)
                _ = execRaw("CREATE INDEX IF NOT EXISTS idx_focus_timeline_captured ON focus_timeline_entries(captured_at);")
            } else {
                os_log("AmbientTimelineStore: failed to open %{public}@", log: .default, type: .error, path)
            }
        }
    }

    deinit { if let db { sqlite3_close(db) } }

    private func execRaw(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    /// Close the previous still-open interval, then insert the new one.
    /// Returns the new row id.
    @discardableResult
    func record(_ sample: FocusSample) -> Int64 {
        q.sync {
            _ = closeOpenRows(before: sample.startedAt)
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO focus_timeline_entries
            (captured_at, finished_at, bundle_identifier, application_label, window_label,
             website_host, summary_text, accessible_text)
            VALUES (?,?,?,?,?,?,?,?);
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, sample.startedAt)
            if let e = sample.endedAt { sqlite3_bind_double(stmt, 2, e) } else { sqlite3_bind_null(stmt, 2) }
            bindText(stmt, 3, sample.appBundleID)
            bindText(stmt, 4, sample.appName)
            bindOptText(stmt, 5, sample.windowTitle)
            bindOptText(stmt, 6, sample.siteHost)
            bindOptText(stmt, 7, sample.contextSummary)
            bindOptText(stmt, 8, sample.deepContext)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return sqlite3_last_insert_rowid(db)
        }
    }

    private func closeOpenRows(before ts: Double) -> Bool {
        var stmt: OpaquePointer?
        let sql = "UPDATE focus_timeline_entries SET finished_at=? WHERE finished_at IS NULL;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, ts)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    func count() -> Int {
        q.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM focus_timeline_entries;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
        }
    }

    /// Most-recent samples (newest first), for the Timeline UI and the agent grounding tool.
    func recent(limit: Int = 50) -> [FocusSample] {
        q.sync {
            var stmt: OpaquePointer?
            let sql = """
            SELECT entry_id, captured_at, finished_at, bundle_identifier, application_label,
                   window_label, website_host, summary_text, accessible_text
            FROM focus_timeline_entries ORDER BY captured_at DESC LIMIT ?;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [FocusSample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(FocusSample(
                    id: sqlite3_column_int64(stmt, 0),
                    startedAt: sqlite3_column_double(stmt, 1),
                    endedAt: sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2),
                    appBundleID: colText(stmt, 3) ?? "",
                    appName: colText(stmt, 4) ?? "",
                    windowTitle: colText(stmt, 5),
                    siteHost: colText(stmt, 6),
                    contextSummary: colText(stmt, 7),
                    deepContext: colText(stmt, 8)))
            }
            return out
        }
    }

    /// Buyer control — wipe the whole timeline (privacy; ship-no-data verification).
    func deleteAll() { q.sync { _ = execRaw("DELETE FROM focus_timeline_entries;") } }

    /// Read-only grounding text for the agent's `recent_activity` tool: the most recent distinct
    /// app/window contexts the buyer worked in, newest first. Honest empty when nothing captured
    /// (sampler off, or ships-empty). Never invents activity.
    func groundingText(limit: Int = 12, includeDeep: Bool = false) -> String {
        let rows = recent(limit: max(limit, 40))
        if rows.isEmpty {
            return "No ambient activity has been captured. The ambient sampler is off or hasn't recorded anything yet (it ships empty and runs only on the buyer's own machine)."
        }
        let fmt = DateFormatter(); fmt.dateFormat = "HH:mm"
        var seen = Set<String>(); var lines: [String] = []
        for r in rows {
            let dedupe = r.appBundleID + "|" + (r.windowTitle ?? "")
            if seen.contains(dedupe) { continue }
            seen.insert(dedupe)
            var line = "• \(fmt.string(from: r.started)) — \(r.appName)"
            if let w = r.windowTitle, !w.isEmpty { line += ": “\(w)”" }
            if let h = r.siteHost, !h.isEmpty, h != "-" { line += " [\(h)]" }
            if includeDeep, let d = r.deepContext, !d.isEmpty {
                line += "\n" + d.split(separator: "\n").prefix(8).joined(separator: "\n")
            }
            lines.append(line)
            if lines.count >= limit { break }
        }
        return "Recent on-screen context (buyer's own machine, newest first):\n" + lines.joined(separator: "\n")
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ s: String) {
        sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
    }
    private func bindOptText(_ stmt: OpaquePointer?, _ idx: Int32, _ s: String?) {
        if let s { sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, idx) }
    }
    private func colText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }
}

// MARK: - The sampler — samples on every frontmost-app change

/// Observes NSWorkspace `didActivateApplicationNotification` and, on each app-focus change, captures
/// the focused window's AX context and records a timeline row. Off by default; the buyer turns it on
/// (privacy). Ships capturing NOTHING until enabled and running on the buyer's own machine.
@MainActor
final class AmbientSampler {
    static let shared = AmbientSampler(store: AmbientTimelineStore.shared)

    let store: AmbientTimelineStore
    private var observer: NSObjectProtocol?
    private(set) var isRunning = false
    private let log = Logger(subsystem: "com.blacklabel.sovereign", category: "ambient")

    /// THE SHIP-NO-DATA CONSTANT for ambient AX capture (§5.2), mirroring
    /// `RecallPolicy.scheduledShipsEnabled`: reading another app's window contents is a posture the
    /// buyer must reach for, never one they inherit. A fresh install samples NOTHING.
    static let shipsEnabled = false

    /// Buyer toggle, persisted. Ships OFF.
    static let enabledKey = "com.blacklabel.sovereign.ambient.enabled.v1"
    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    init(store: AmbientTimelineStore) { self.store = store }

    /// The buyer-facing Settings seam. It updates the durable opt-in and reconciles the live
    /// sampler immediately, so turning capture off stops observation without requiring a relaunch.
    func setBuyerOptIn(_ isEnabled: Bool) {
        Self.enabled = isEnabled
        if isEnabled { start() } else { stop() }
    }

    func start() {
        #if canImport(AppKit)
        // DENY BY DEFAULT (§5.2). The opt-in is enforced HERE, inside the sampler — not only at the
        // call site. An unguarded `start()` from any present or future call site must not be able to
        // arm capture, and the app's single call site lives in main.swift, which the test harness
        // cannot compile. Same shape as RecallStore.recordScheduled refusing an opt-in-off tick at
        // the store rather than trusting the UI to have hidden the switch.
        guard Self.enabled else {
            log.notice("Ambient sampler start() refused — the buyer has not opted in (ships OFF).")
            return
        }
        guard !isRunning else { return }
        isRunning = true
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                // The notification queue is .main, so we are genuinely on the main actor here.
                MainActor.assumeIsolated {
                    _ = self.capture(app: app ?? NSWorkspace.shared.frontmostApplication)
                }
        }
        if !AmbientAX.isTrusted {
            log.notice("Ambient sampler started but Accessibility is NOT granted — rows will record app focus only, marked accessibility-not-granted, until the buyer grants it.")
        }
        capture(app: NSWorkspace.shared.frontmostApplication)  // seed with the current front app
        #endif
    }

    func stop() {
        #if canImport(AppKit)
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        isRunning = false
        #endif
    }

    /// Capture the given (or frontmost) app once and record a row. Also the proof entry point.
    @discardableResult
    func captureNow() -> FocusSample? {
        #if canImport(AppKit)
        return capture(app: NSWorkspace.shared.frontmostApplication)
        #else
        return nil
        #endif
    }

    @discardableResult
    private func capture(app: NSRunningApplication?) -> FocusSample? {
        #if canImport(AppKit)
        // The SAME deny-by-default gate at the WRITE path: no opt-in, no row on disk. start() is
        // already gated, so this is the second layer — it means a direct captureNow() (the proof
        // entry point) cannot persist a sample the buyer never consented to either.
        guard Self.enabled else { return nil }
        guard let app, let bundleID = app.bundleIdentifier else { return nil }
        // Don't sample ourselves — the buyer's own assistant window isn't useful context and would
        // record the Sovereign UI into its own timeline.
        if bundleID == Bundle.main.bundleIdentifier { return nil }
        let name = app.localizedName ?? bundleID
        let cap = AmbientAX.captureFocused(pid: app.processIdentifier)
        if !cap.granted {
            log.notice("Ambient capture of \(name, privacy: .public) recorded WITHOUT AX (grant missing).")
        }
        let rawDeep = cap.granted ? AmbientFormat.deepContext(cap.nodes) : nil
        guard let safe = AmbientSanitizer.sanitize(appName: name,
                                                   windowTitle: cap.windowTitle,
                                                   siteHost: cap.siteHost,
                                                   deepContext: rawDeep) else {
            log.notice("Ambient capture skipped a credential surface in \(name, privacy: .public).")
            return nil
        }
        if safe.redactedCount > 0 {
            log.notice("Ambient capture redacted \(safe.redactedCount, privacy: .public) secret field(s) before persistence.")
        }
        let summary = AmbientFormat.summary(appName: name, windowTitle: safe.windowTitle,
                                            host: safe.siteHost, nodeCount: cap.nodes.count,
                                            granted: cap.granted)
        var sample = FocusSample(
            startedAt: Date().timeIntervalSince1970, endedAt: nil,
            appBundleID: bundleID, appName: name,
            windowTitle: safe.windowTitle, siteHost: safe.siteHost,
            contextSummary: summary, deepContext: safe.deepContext)
        let id = store.record(sample)
        sample.id = id
        return sample
        #else
        return nil
        #endif
    }
}
