// Vigil — the automation engine (the foundational spine, §2 of the standard).
//
// Pure, deterministic, Foundation-only: the standard's "triggers → conditions →
// actions" evaluator. A trigger fires a candidate set; each candidate's
// AND-combined conditions are then evaluated against a point-in-time HomeSnapshot;
// only candidates that pass BOTH the trigger and every condition run their actions.
//
// Everything here is a pure function over value types (no live store, no clock,
// no I/O) so the whole spine is unit-testable on synthetic events + snapshots.
// §5.1: this only routes REAL events (real sensing presence, real device-state
// edges, real sensor-node liveness, the real clock) to actions — it never invents
// an event or a reading.

import Foundation

enum AutomationEvaluator {

    /// Backward-compatible entry point (trigger-only, no condition gating). Kept so
    /// existing callers and tests that pass no snapshot still compile; prefer
    /// `fired(by:automations:snapshot:)` so conditions are honored.
    static func fired(by event: HomeEvent,
                      automations: [HFAutomation]) -> [(HFAutomation, [HomeAction])] {
        automations.compactMap { auto in
            guard auto.enabled, matches(auto.trigger, event) else { return nil }
            return (auto, auto.actions)
        }
    }

    /// The full spine: trigger matches AND every condition passes against the
    /// snapshot. Returns the (automation, actions) pairs that should run, in
    /// stable input order. Pure & deterministic.
    static func fired(by event: HomeEvent,
                      automations: [HFAutomation],
                      snapshot: HomeSnapshot) -> [(HFAutomation, [HomeAction])] {
        automations.compactMap { auto in
            guard auto.enabled,
                  matches(auto.trigger, event),
                  conditionsPass(auto.conditions, snapshot)
            else { return nil }
            return (auto, auto.actions)
        }
    }

    // MARK: - Trigger matching

    static func matches(_ t: Trigger, _ e: HomeEvent) -> Bool {
        switch (t.kind, e) {
        case (.presenceEnter, .presenceEntered(let r)): return t.roomID == nil || t.roomID == r
        case (.presenceLeave, .presenceLeft(let r)):    return t.roomID == nil || t.roomID == r
        case (.timeOfDay, .minuteTick(let m)):          return t.minuteOfDay == m
        case (.sunrise, .sunrise):                      return true
        case (.sunset, .sunset):                        return true
        case (.securityMode, .securityModeChanged(let m)): return t.mode == nil || t.mode == m
        case (.deviceOn, .deviceTurnedOn(let d)):       return t.deviceID == nil || t.deviceID == d
        case (.deviceOff, .deviceTurnedOff(let d)):     return t.deviceID == nil || t.deviceID == d
        case (.sensorOnline, .sensorCameOnline(let tr)):  return t.tier == nil || t.tier == tr
        case (.sensorOffline, .sensorWentOffline(let tr)): return t.tier == nil || t.tier == tr
        case (.geofenceArrive, .geofenceEntered): return true
        case (.geofenceDepart, .geofenceLeft):    return true
        default: return false
        }
    }

    // MARK: - Condition evaluation (AND-combined; empty = pass)

    static func conditionsPass(_ conditions: [Condition], _ s: HomeSnapshot) -> Bool {
        conditions.allSatisfy { passes($0, s) }
    }

    static func passes(_ c: Condition, _ s: HomeSnapshot) -> Bool {
        switch c.kind {
        case .securityModeIs:
            // nil mode is an under-specified condition → fail closed (never silently pass).
            guard let m = c.mode else { return false }
            return s.securityMode == m
        case .timeWindow:
            guard let start = c.startMinute, let end = c.endMinute else { return false }
            return minuteInWindow(s.minuteOfDay, start: start, end: end)
        case .presenceIs:
            guard let want = c.present else { return false }
            return s.homePresent == want
        case .deviceIsOn:
            guard let id = c.deviceID else { return false }
            // Unknown device → not on → fail closed (no fabricated "on" state).
            return s.deviceOnByID[id] == true
        }
    }

    /// True if `m` is within [start, end], inclusive, wrapping past midnight when
    /// start > end (e.g. 22:00→06:00 = "overnight"). A start==end window is the
    /// single matching minute.
    static func minuteInWindow(_ m: Int, start: Int, end: Int) -> Bool {
        if start <= end { return m >= start && m <= end }
        return m >= start || m <= end   // wraps midnight
    }
}

// MARK: - Template-first automation library (VG-30)

/// A ready-made starter automation a non-technical buyer applies in ONE TAP — the
/// template-first answer to "consumer automation depth without config hell" (VG-30). Each
/// recipe is a complete `HFAutomation` that needs NO device/room/scene binding, so it works
/// the moment it is applied on an empty home (§5.2): triggers are presence / time / geofence /
/// sensor-liveness and actions are notify / arm-mode. The buyer never "learns a programming
/// language" — they pick a recipe and it runs. Editing afterwards uses the same builder (VG-11).
struct AutomationTemplate: Identifiable, Equatable {
    enum Category: String { case presence = "Presence", security = "Security", vitals = "Vitals & sensors" }
    let id: String            // stable slug (dedup on re-apply is by name, see HomeStore.applyTemplate)
    let name: String          // becomes the automation name
    let detail: String        // plain-language "what it does", no config jargon
    let category: Category
    /// Build a fresh, ENABLED automation from this template. Pure — no store, no clock.
    let build: () -> HFAutomation

    static func == (l: AutomationTemplate, r: AutomationTemplate) -> Bool { l.id == r.id }

    /// The whole starter library, grouped conceptually by category. Every recipe here is
    /// one-tap-applyable on an empty home (no unresolved device/room reference).
    static let library: [AutomationTemplate] = [
        AutomationTemplate(
            id: "arrive-disarm", name: "Arrive home → disarm",
            detail: "When your phone reaches the home geofence, turn security Off.",
            category: .security,
            build: { HFAutomation(name: "Arrive home → disarm",
                                  trigger: Trigger(kind: .geofenceArrive),
                                  actions: [HomeAction(kind: .setSecurityMode, mode: .off)]) }),
        AutomationTemplate(
            id: "leave-arm-away", name: "Leave home → arm Away",
            detail: "When you leave the home geofence, arm Away automatically.",
            category: .security,
            build: { HFAutomation(name: "Leave home → arm Away",
                                  trigger: Trigger(kind: .geofenceDepart),
                                  actions: [HomeAction(kind: .setSecurityMode, mode: .away)]) }),
        AutomationTemplate(
            id: "goodnight-arm-night", name: "Goodnight → arm Night",
            detail: "At 11:00 PM, arm Night mode so perimeter motion still alerts you.",
            category: .security,
            build: { HFAutomation(name: "Goodnight → arm Night",
                                  trigger: Trigger(kind: .timeOfDay, minuteOfDay: 23 * 60),
                                  actions: [HomeAction(kind: .setSecurityMode, mode: .night)]) }),
        AutomationTemplate(
            id: "motion-while-away", name: "Motion while armed Away → alert",
            detail: "If a room becomes occupied while you're armed Away, notify you.",
            category: .presence,
            build: { HFAutomation(name: "Motion while armed Away → alert",
                                  trigger: Trigger(kind: .presenceEnter),
                                  conditions: [Condition(kind: .securityModeIs, mode: .away)],
                                  actions: [HomeAction(kind: .notify, message: "Motion detected while armed Away.")]) }),
        AutomationTemplate(
            id: "overnight-bed-exit", name: "Overnight movement watch",
            detail: "If a monitored room is left between 10 PM and 6 AM, nudge you to check in (eldercare).",
            category: .vitals,
            build: { HFAutomation(name: "Overnight movement watch",
                                  trigger: Trigger(kind: .presenceLeave),
                                  conditions: [Condition(kind: .timeWindow, startMinute: 22 * 60, endMinute: 6 * 60)],
                                  actions: [HomeAction(kind: .notify, message: "A monitored room was left overnight — check on them.")]) }),
        AutomationTemplate(
            id: "sensor-offline", name: "Sensor node offline → alert",
            detail: "If a Vigil sensor node drops offline, tell you so a blind spot never goes unnoticed.",
            category: .vitals,
            build: { HFAutomation(name: "Sensor node offline → alert",
                                  trigger: Trigger(kind: .sensorOffline),
                                  actions: [HomeAction(kind: .notify, message: "A Vigil sensor node went offline.")]) }),
    ]
}
