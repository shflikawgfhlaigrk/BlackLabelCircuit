// Sovereign — REAL local Calendar connector via EventKit.
//
// Reads the buyer's OWN calendar events from the system calendar database — fully local,
// no cloud, no Black Label backend. The buyer must EXPLICITLY grant calendar access at the
// system prompt; nothing is read until they do. This is the opposite of background mining:
// it surfaces only the events the buyer's own Calendar already holds, on demand, with an
// honest empty/denied state.
//
// Two consumers:
//   1. The agent tool surface (read_calendar) — the multi-step agent can look at the buyer's
//      real upcoming schedule to ground answers ("what's on my calendar tomorrow?").
//   2. Unified RAG — upcoming events become a retrievable, citable source alongside files/docs.
//
// HONESTY: every value (title, time, location) is read straight from EventKit. When access is
// denied or there are no events in the window, callers get an honest empty result — never a
// fabricated event.
import Foundation
#if canImport(EventKit)
import EventKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import CircuitPortKit

/// A single real calendar event, decoupled from EventKit so the formatting logic is unit-testable.
struct CalEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String
    let calendarName: String

    /// One-line human rendering used in the agent transcript + RAG grounding.
    /// Pure + deterministic so it can be tested without EventKit.
    func line(now: Date = Date(), calendar: Calendar = .current) -> String {
        let df = DateFormatter()
        df.calendar = calendar
        df.locale = .current
        let day: String
        if calendar.isDate(start, inSameDayAs: now) { day = "Today" }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(start, inSameDayAs: tomorrow) { day = "Tomorrow" }
        else { df.dateFormat = "EEE MMM d"; day = df.string(from: start) }

        var time = ""
        if isAllDay { time = "all day" }
        else {
            df.dateFormat = "h:mm a"
            time = "\(df.string(from: start))–\(df.string(from: end))"
        }
        var s = "\(day) \(time): \(title.isEmpty ? "(untitled)" : title)"
        let loc = location.trimmingCharacters(in: .whitespacesAndNewlines)
        if !loc.isEmpty { s += " @ \(loc)" }
        return s
    }
}

/// Honest availability of the calendar connector on this device / for this buyer's grant state.
enum CalendarAccess: Equatable {
    case notDetermined      // never asked — UI offers to request
    case granted
    case denied             // buyer said no, or restricted — UI explains how to enable
    case unavailable(String)// EventKit not present (shouldn't happen on macOS) — honest reason
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class CalendarConnector: ObservableObject {
    @Published var access: CalendarAccess = .notDetermined
    @Published var lastError: String?
    /// The buyer toggles the connector on/off independent of system permission (defense in depth:
    /// even if macOS granted access, the brain never sees the calendar unless the buyer enabled it).
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: enabledKey)
            // Record a real connector receipt the moment the buyer toggles it (ignore the no-op
            // initial load assignment in init()). This exercises the .connector ledger kind at the
            // exact moment a grant/state change happens — never narrated.
            if didLoadInitial, oldValue != enabled {
                activity?.record(kind: .connector, title: "Calendar connector",
                                 detail: enabled ? "Enabled — the assistant may read your upcoming events when access is granted."
                                                 : "Disabled — the assistant can no longer read your calendar.",
                                 outcome: .info)
            }
        }
    }
    private let enabledKey = "com.blacklabel.sovereign.calendar.enabled.v1"
    private var didLoadInitial = false
    /// Optional ledger so a grant/toggle writes a real proof-of-execution receipt. Wired at app init.
    weak var activity: ActivityLog?

    #if canImport(EventKit)
    private let store = EKEventStore()
    #endif

    init() {
        enabled = (UserDefaults.standard.object(forKey: enabledKey) as? Bool) ?? false
        didLoadInitial = true   // any enabled change AFTER init is a real buyer action worth a receipt
        refreshAccess()
    }

    /// Read the current system authorization without prompting.
    func refreshAccess() {
        #if canImport(EventKit)
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .notDetermined: access = .notDetermined
        case .restricted, .denied: access = .denied
        case .fullAccess: access = .granted
        case .authorized: access = .granted          // pre-macOS 14 value
        case .writeOnly: access = .denied            // write-only can't read events → honest denied for reads
        @unknown default: access = .denied
        }
        #else
        access = .unavailable("Calendar isn't available on this system.")
        #endif
    }

    /// Prime the system permission prompt. Honest: resolves to .granted / .denied based on the
    /// buyer's real answer; never assumes access.
    func requestAccess() {
        #if canImport(EventKit)
        lastError = nil
        let done: @Sendable (Bool, Error?) -> Void = { [weak self] granted, err in
            Task { @MainActor in
                guard let self else { return }
                if let err { self.lastError = err.localizedDescription }
                self.refreshAccess()
                // Real receipt at the moment the system grant resolves (granted OR denied) — honest
                // either way. The enable-toggle below records its own receipt only if it flips.
                let deniedDetail = "System calendar access denied" + (err.map { ": \($0.localizedDescription)" } ?? ".")
                self.activity?.record(kind: .connector, title: "Calendar access",
                                      detail: granted ? "System calendar access granted." : deniedDetail,
                                      outcome: granted ? .success : .info)
                if granted { self.enabled = true }   // turning it on after an explicit grant is the buyer's intent
            }
        }
        if #available(macOS 14.0, iOS 17.0, *) {
            store.requestFullAccessToEvents(completion: done)
        } else {
            store.requestAccess(to: .event, completion: done)
        }
        #else
        access = .unavailable("Calendar isn't available on this system.")
        #endif
    }

    /// True when the connector may actually be read (buyer enabled it AND the system granted access).
    var isReadable: Bool { enabled && access == .granted }

    /// Fetch the buyer's real events in the next `days` days (clamped 1...60). Honest empty on
    /// no-access / no-events. Never fabricates.
    func upcoming(days: Int = 7, now: Date = Date(), cap: Int = 50) -> [CalEvent] {
        guard isReadable else { return [] }
        #if canImport(EventKit)
        let d = max(1, min(60, days))
        let cal = Calendar.current
        guard let end = cal.date(byAdding: .day, value: d, to: now) else { return [] }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(cap)
        return events.map {
            CalEvent(id: $0.eventIdentifier ?? UUID().uuidString,
                     title: $0.title ?? "",
                     start: $0.startDate ?? now,
                     end: $0.endDate ?? now,
                     isAllDay: $0.isAllDay,
                     location: $0.location ?? "",
                     calendarName: $0.calendar?.title ?? "")
        }
    #else
        return []
    #endif
    }

    /// Grounding/transcript text block of the buyer's upcoming events for the brain to read.
    /// Returns "" when nothing is readable — the brain never invents a schedule.
    func groundingText(days: Int = 7, now: Date = Date()) -> String {
        Self.groundingText(upcoming(days: days, now: now), days: days, now: now)
    }

    /// Pure builder — unit-testable without EventKit.
    nonisolated static func groundingText(_ events: [CalEvent], days: Int, now: Date = Date()) -> String {
        guard !events.isEmpty else { return "" }
        let body = events.map { "• " + $0.line(now: now) }.joined(separator: "\n")
        return "The user's real upcoming calendar events (next \(days) days), read from their own Calendar:\n" + body
    }
}
#endif // circuit-convert
