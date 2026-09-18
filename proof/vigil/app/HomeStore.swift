#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
// Vigil — the live home store: holds HomeState, persists it to the local
// SQLite workspace, and runs the automation + security runtime on top of the pure
// HomeCore logic. SwiftUI views bind to this; the sensing engine feeds it
// presence. Nothing here fabricates a device or a reading.

import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(UserNotifications) && !CIRCUIT_WINDOWS_SIM
import UserNotifications
#endif
import CircuitPortKit

/// Presents Vigil's local notifications as banners even when the app is frontmost.
/// macOS suppresses foreground banner presentation unless a delegate opts in via
/// `willPresent`; for a fall/security product the app-open path is a primary alert
/// surface, so it must not be silent. Held by a static `shared` so the delegate
/// (a weak reference on UNUserNotificationCenter) is never deallocated.
final class VigilNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = VigilNotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

@MainActor
final class HomeStore: ObservableObject {
    @Published private(set) var state: HomeState = .empty
    @Published var lastAlert: String? = nil
    /// True only while an Away Alerts "Send test alert" POST is in flight, so the button
    /// shows a real "Sending…" state and disables — never a fake instant "sent". Cleared
    /// from the URLSession completion (both success and failure) in sendRemoteRelay.
    @Published private(set) var testAlertInFlight: Bool = false
    /// The OS notification-authorization status, read into a published field so the
    /// Fall/emergency card can show ON / OFF / DENIED honestly — never a silent
    /// "armed" claim when the OS would drop the alert (§5.1, the delivery gate).
    @Published private(set) var notifAuth: NotifAuthState = .unknown
    /// The CoreLocation authorization for the arrive/leave-home geofence triggers, read
    /// into a published field so the trigger row shows access on / needed / denied
    /// honestly — never a fabricated "monitoring" (§5.1). Pure GeofenceAuthState, fed by
    /// the live GeofenceMonitor.
    @Published private(set) var geofenceAuth: GeofenceAuthState = .unknown
    /// The live CoreLocation monitor (the only CoreLocation-touching object). Crossings
    /// are routed through GeofenceModel.event so a denied/unconfigured state can never
    /// fabricate an arrive/leave event.
    private let geofence = GeofenceMonitor()

    /// Persistence health, surfaced as a banner: a corrupt state blob on load or a
    /// failed save must never pass silently in an app that logs everything else —
    /// silent loss reads as a data wipe with no explanation (§5.1).
    @Published private(set) var persistenceWarning: String? = nil
    /// One warning per failure streak — cleared by the next successful save.
    private var saveFailureSurfaced = false

    private let database: VigilDatabase
    private let legacyURL: URL

    // presence edge-detection per room (+ a whole-home pseudo signal)
    private var occupied: Set<UUID> = []
    private var homePresent = false
    private var presence = PresenceDebouncer()   // GAP #D: raw sensing → confirmed transitions only
    /// VG-27 monitor mode: the live 20s vitals-concern debouncer (runtime only — the
    /// debounce state is transient; only MonitorConfig persists). Fed by stepVitalsMonitor.
    private var vitalsMonitor = VitalsMonitor()
    private var lastMinute = -1

    // security alarm runtime (pure SecurityModel.phase drives it; these are its clock inputs).
    // Deliberately NOT persisted: after a relaunch, armedAt=nil means "armed long ago" —
    // the safe side is monitoring immediately, never an indefinite exit grace.
    @Published private(set) var alarmPhase: SecurityModel.AlarmPhase = .quiet
    private var armedAt: Date? = nil
    private var presenceSince: Date? = nil
    private var alarmTimer: Timer? = nil

    init() {
        let base = VigilDatabase.baseURL()
        database = VigilDatabase(baseURL: base)
        legacyURL = base.appendingPathComponent("home.json")
        // Present fall/security banners even when Vigil is the frontmost app. Without a
        // UNUserNotificationCenter delegate, macOS SUPPRESSES banner presentation while
        // the app is active — so a caregiver watching the window would get no visible
        // alert on a fall (it would land silently in History only). Set once, early.
        UNUserNotificationCenter.current().delegate = VigilNotificationDelegate.shared
        load()
        wireGeofence()
    }

    // MARK: geofence (arrive/leave-home triggers — real CoreLocation, fail-closed)
    /// Wire the live monitor to the store: surface authorization honestly, route real
    /// region crossings through the pure GeofenceModel (so missing access / no region
    /// emits NO event), and (re)start monitoring whenever access + a configured region
    /// are both present. Reads current authorization on cold boot.
    private func wireGeofence() {
        geofence.onAuth = { [weak self] s in
            guard let self else { return }
            self.geofenceAuth = s
            if s.monitoringEligible, self.state.geofence.isConfigured {
                self.geofence.startMonitoring(self.state.geofence)
            }
        }
        geofence.onCrossing = { [weak self] crossing in
            guard let self else { return }
            // Fail-closed: only a live (authorized + configured) crossing becomes an
            // event — never a fabricated arrive/leave the OS didn't report (§5.1).
            guard let ev = GeofenceModel.event(for: crossing, auth: self.geofenceAuth,
                                               isConfigured: self.state.geofence.isConfigured) else { return }
            self.log(.presence, crossing == .entered ? "Arrived home (geofence)" : "Left home (geofence)")
            self.fire(ev)
        }
        geofenceAuth = geofence.authState
        if state.geofence.isConfigured, geofenceAuth.monitoringEligible {
            geofence.startMonitoring(state.geofence)
        }
    }

    /// Ask the OS for location access (only effective while notDetermined; the UI routes
    /// to System Settings otherwise). Status flows back through onAuth — never assumed.
    func requestGeofenceAccess() { geofence.requestAccess() }

    /// Set the home region to an explicit coordinate + radius. REJECTED (no-op) when the
    /// coordinate/radius is invalid — never stores a phantom region (§5.1).
    func setHomeRegion(latitude: Double, longitude: Double, radiusMeters: Double, label: String) {
        let r = GeofenceRegion(latitude: latitude, longitude: longitude,
                               radiusMeters: radiusMeters, label: label)
        guard r.isConfigured else { return }
        state.geofence = r
        save()
        log(.sensor, "Home region set\(label.isEmpty ? "" : " (\(label))") · \(Int(radiusMeters)) m")
        if geofenceAuth.monitoringEligible { geofence.startMonitoring(r) }
    }

    /// Capture the buyer's CURRENT location and set it as home. A nil fix (denied/failed)
    /// is a no-op — never a fabricated home coordinate (§5.1).
    func setHomeRegionToCurrentLocation(radiusMeters: Double = 150, label: String = "Home") {
        geofence.onLocationFix = { [weak self] fix in
            guard let self, let fix else { return }
            self.setHomeRegion(latitude: fix.lat, longitude: fix.lon,
                               radiusMeters: radiusMeters, label: label)
        }
        geofence.captureCurrentLocation()
    }

    /// Clear the home region and stop monitoring (ship-empty parity / honest off).
    func clearHomeRegion() {
        state.geofence = GeofenceRegion()
        save()
        geofence.stopMonitoring()
        log(.sensor, "Home region cleared")
    }

    // MARK: persistence
    func load() {
        // A present-but-undecodable blob is DATA, not absence: preserve the bytes
        // aside and say so — never silently present an empty home over a
        // recoverable state, and never let the next save() overwrite the only copy.
        if let data = try? database.readBlob(named: VigilDatabase.homeState) {
            if let s = try? JSONDecoder().decode(HomeState.self, from: data) {
                state = migrated(s)
                occupied = []   // presence is live, never restored
                return
            }
            let keptClause = preserveCorruptState(data)
            if let legacy = try? Data(contentsOf: legacyURL),
               let s = try? JSONDecoder().decode(HomeState.self, from: legacy) {
                state = migrated(s)
                occupied = []
                try? database.writeBlob(legacy, named: VigilDatabase.homeState)
                persistenceWarning = "The latest saved home state could not be read — an older backup copy was loaded instead.\(keptClause)"
            } else {
                persistenceWarning = "Saved home state could not be read — starting empty.\(keptClause)"
            }
            return
        }
        guard let data = try? Data(contentsOf: legacyURL),
              let s = try? JSONDecoder().decode(HomeState.self, from: data) else { return }
        state = migrated(s)
        occupied = []   // presence is live, never restored
        try? database.writeBlob(data, named: VigilDatabase.homeState)
    }
    /// Load-time state repair: demote `.controllable` claims no transport backs
    /// (legacy states stored lock/blind/garage/thermostat as controllable — §5.1).
    private func migrated(_ s: HomeState) -> HomeState {
        var out = s
        out.devices = DeviceControlPolicy.demotingUncontrollable(out.devices)
        return out
    }
    /// Copy an undecodable state blob beside the database with a timestamped name
    /// so a later hand-recovery stays possible once save() has replaced the live
    /// blob. Returns the sentence describing where (whether) the copy was kept;
    /// the caller composes the full warning from the actual load outcome.
    private func preserveCorruptState(_ data: Data) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let aside = VigilDatabase.baseURL().appendingPathComponent("homeState.corrupt-\(stamp).json")
        let kept = (try? data.write(to: aside, options: .atomic)) != nil
        return kept
            ? " The unreadable copy is kept as \(aside.lastPathComponent) in Application Support/Homefront."
            : " The unreadable copy could not be preserved."
    }
    /// Dismiss the persistence banner (a new failure re-surfaces it).
    func acknowledgePersistenceWarning() { persistenceWarning = nil }
    private func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(state) else {
            surfaceSaveFailure("Could not encode home state — recent changes are not being saved.")
            return
        }
        do {
            try database.writeBlob(data, named: VigilDatabase.homeState)
            saveFailureSurfaced = false
        } catch {
            do {
                try data.write(to: legacyURL, options: .atomic)
                saveFailureSurfaced = false
            } catch {
                surfaceSaveFailure("Saving home state failed (\(error.localizedDescription)) — changes since the last successful save will be lost.")
            }
        }
    }
    /// Surface a save failure ONCE per streak. Deliberately does NOT call log():
    /// log() itself save()s, so reporting through it would recurse; the event is
    /// appended to the in-memory History directly (persistence is down anyway).
    private func surfaceSaveFailure(_ message: String) {
        persistenceWarning = message
        guard !saveFailureSurfaced else { return }
        saveFailureSurfaced = true
        state.activity.insert(ActivityEvent(at: Date(), kind: .system, message: message), at: 0)
        state.activity = ActivityRing.trimmed(state.activity)
    }
    /// Record one real total-draw sample (W) into the persisted history so the
    /// Energy tab can show measured kWh-per-day trends. Honest: only a finite,
    /// non-negative *measured* total is stored, and the caller records only when
    /// a scan actually read a device (no fabricated zero-draw sample). Pruned to
    /// the retain window each time.
    func recordEnergy(totalWatts: Double) {
        guard totalWatts.isFinite, totalWatts >= 0 else { return }
        let sample = EnergySample(ts: Date(), watts: totalWatts)
        state.energyHistory = EnergyHistory.appended(state.energyHistory, sample: sample)
        save()
    }

    /// Export a copy of the config (local-first, no cloud lock-in).
    func exportConfig(to url: URL) throws {
        try HomeConfigBackup.encode(state).write(to: url, options: .atomic)
    }

    /// Restore a previously exported config after full structural validation. The
    /// replacement is all-or-nothing: decode + validate first, then reset live-only
    /// presence state so imported history never masquerades as current occupancy.
    @discardableResult
    func importConfig(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let imported = try HomeConfigBackup.decode(data)
        state = migrated(imported)   // an old export can carry demote-needed control claims
        occupied = []
        homePresent = false
        presence = PresenceDebouncer()
        lastMinute = -1
        save()
        if state.geofence.isConfigured, geofenceAuth.monitoringEligible {
            geofence.startMonitoring(state.geofence)
        } else {
            geofence.stopMonitoring()
        }
        return HomeConfigBackup.summary(for: state)
    }

    // MARK: activity log
    func log(_ kind: ActivityKind, _ message: String) {
        state.activity.insert(ActivityEvent(at: Date(), kind: kind, message: message), at: 0)
        // Protected-retention trim: bound the ring but never silently evict a recent
        // eldercare anomaly / security alert under a presence flood (GAP #A AC5).
        state.activity = ActivityRing.trimmed(state.activity)
        save()
    }

    /// Log an event already attributed to a resident (eldercare). Stamps residentID
    /// so per-resident History views can filter; a nil resident logs unattributed —
    /// never a fabricated occupant (§5.1). Honors the same protected-retention trim.
    func log(_ kind: ActivityKind, _ message: String, resident: Resident?) {
        var e = ActivityEvent(at: Date(), kind: kind, message: message)
        e.residentID = resident?.id
        state.activity.insert(e, at: 0)
        state.activity = ActivityRing.trimmed(state.activity)
        save()
    }

    /// Log a CRITICAL eldercare/security event AND escalate it to a real desktop
    /// notification — the seam the poller uses so a fall reaches a caregiver who is
    /// not looking at the app. The escalation is gated by `CriticalAlert.notice`:
    /// non-critical kinds never notify (no spam), and the resident name is pushed
    /// only when known (§5.1, no guessed occupant). One notification per call — the
    /// per-episode transition dedup lives in the upstream FallLatch/AnomalyLatch, so
    /// a latched-active fall re-observed every 2 s poll does NOT re-notify.
    func logCritical(_ kind: ActivityKind, _ message: String, resident: Resident?) {
        log(kind, message, resident: resident)
        if let n = CriticalAlert.notice(for: kind, message: message, resident: resident) {
            notify(title: n.title, body: n.body)
        }
        // Off-device REACH (GAP#G): a fall must also reach a caregiver who is NOT at
        // this Mac. Same isCritical gate as the banner (so non-critical never POSTs —
        // no spam); only fires when the buyer has configured a real relay endpoint —
        // an empty relay never POSTs (§5.2).
        if let req = RemoteRelay.request(for: kind, message: message, resident: resident, config: state.relay) {
            sendRemoteRelay(req)
        }
    }

    // MARK: residents (eldercare — people under care; ships empty, honest "no residents yet")
    func addResident(_ name: String, room: UUID? = nil, note: String = "") {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let wasEmpty = state.residents.isEmpty
        state.residents.append(Resident(name: trimmed, roomID: room, note: note))
        save(); log(.system, "Added resident “\(trimmed)”")
        // Adding the first person under care is the right eldercare moment to ask for
        // notification permission — otherwise fall/anomaly alerts are silent-by-default
        // until the buyer finds the buried Settings toggle. Honest if denied (the system
        // prompts once; the card + History still update regardless).
        if wasEmpty { requestNotifications() }
    }
    func removeResident(_ id: UUID) {
        if let r = state.residents.first(where: { $0.id == id }) { log(.system, "Removed resident “\(r.name)”") }
        state.residents.removeAll { $0.id == id }; save()
    }
    func assignResident(_ id: UUID, toRoom room: UUID?) {
        guard let i = state.residents.firstIndex(where: { $0.id == id }) else { return }
        state.residents[i].roomID = room; save()
    }

    // MARK: rooms
    func addRoom(_ name: String, symbol: String = "square.split.bottomrightquarter") {
        state.rooms.append(HFRoom(name: name, symbol: symbol)); save()
        log(.system, "Added room “\(name)”")
    }
    func deleteRoom(_ id: UUID) {
        state.rooms.removeAll { $0.id == id }
        for i in state.devices.indices where state.devices[i].roomID == id { state.devices[i].roomID = nil }
        for i in state.sensors.indices where state.sensors[i].roomID == id { state.sensors[i].roomID = nil }
        save()
    }

    // MARK: devices
    /// True when an equivalent device is already stored — the same LAN host, or the
    /// same discovered/cast advertisement (name + service type). Drives the "Added"
    /// state on discovery rows and blocks double-click duplicates.
    func isDuplicateDevice(_ d: HFDevice) -> Bool {
        state.devices.contains { e in
            if let h = d.host, !h.isEmpty, e.host == h { return true }
            return d.source != .manual && d.source != .simulated
                && e.source == d.source && e.name == d.name && e.model == d.model
        }
    }
    /// Add a device unless an equivalent one is already stored. Returns whether it
    /// was added, so the add UI can say "already tracked" instead of silently minting
    /// duplicate tiles on every click.
    @discardableResult
    func addDevice(_ d: HFDevice) -> Bool {
        guard !isDuplicateDevice(d) else { return false }
        state.devices.append(d); save()
        log(.device, "Added \(d.kind.label.lowercased()) “\(d.name)”")
        return true
    }
    func removeDevice(_ id: UUID) {
        if let d = state.devices.first(where: { $0.id == id }) { log(.device, "Removed “\(d.name)”") }
        state.devices.removeAll { $0.id == id }; save()
    }

    // MARK: simulated home (DOD-4.1 / VIGIL-1)

    /// True when any simulated device is present (drives the add/remove affordance).
    var hasSimulatedDevices: Bool { state.devices.contains { $0.control == .simulated } }

    /// Add the simulated home: one honest SIMULATED device per supported hardware class.
    /// Idempotent by kind — kinds already simulated are not duplicated on a second tap.
    func addSimulatedDevices() {
        let existing = Set(state.devices.filter { $0.control == .simulated }.map(\.kind))
        let fresh = SimulatedHome.devices().filter { !existing.contains($0.kind) }
        guard !fresh.isEmpty else { return }
        state.devices.append(contentsOf: fresh); save()
        log(.device, "Added \(fresh.count) simulated devices (labelled SIMULATED — no hardware involved)")
    }

    /// Remove every simulated device (real devices are never touched).
    func removeSimulatedDevices() {
        let n = state.devices.filter { $0.control == .simulated }.count
        guard n > 0 else { return }
        state.devices.removeAll { $0.control == .simulated }; save()
        log(.device, "Removed \(n) simulated devices")
    }
    func assign(_ deviceID: UUID, toRoom room: UUID?) {
        guard let i = state.devices.firstIndex(where: { $0.id == deviceID }) else { return }
        state.devices[i].roomID = room; save()
    }
    func toggleFavorite(_ id: UUID) {
        guard let i = state.devices.firstIndex(where: { $0.id == id }) else { return }
        state.devices[i].favorite.toggle(); save()
    }
    /// Primary tap on a device tile. Only actuatable devices change state —
    /// controllable hardware (drives the LAN endpoint) or a simulated device
    /// (local-only state, honestly labelled SIMULATED; no radio, no LAN call).
    func primaryToggle(_ id: UUID) {
        guard let i = state.devices.firstIndex(where: { $0.id == id }),
              state.devices[i].isActuatable else { return }
        var d = state.devices[i]
        // §5.1: lock/blind/garage state may only flip LOCALLY for a SIMULATED device.
        // No local dialect drives these kinds (DeviceControlPolicy keeps hardware of
        // them out of .controllable), so no entry path may claim "Locked"/"Closed"
        // for a physical device that was never commanded.
        if [.lock, .blind, .garage].contains(d.kind), d.control != .simulated {
            log(.device, "\(d.name): Vigil has no local control path for \(d.kind.label.lowercased())s — control it from its own app or hub.")
            return
        }
        switch d.kind {
        case .lock:
            let now = !(d.state.locked ?? false); d.state.locked = now
            log(.device, "\(d.name): \(now ? "locked" : "unlocked")")
        case .blind, .garage:
            let open = (d.state.openPct ?? 0) < 0.5 ? 1.0 : 0.0; d.state.openPct = open
            log(.device, "\(d.name): \(open > 0.5 ? "opened" : "closed")")
        default:
            let prior = d.state.on ?? false
            let now = !prior; d.state.on = now
            log(.device, "\(d.name): \(now ? "on" : "off")")
            sendControl(d, on: now, revertTo: prior)   // drive the hardware; roll back if it never acks
            state.devices[i] = d; save()
            // Device-state edge → automation trigger (e.g. "when the TV turns on, dim the lamp").
            fire(now ? .deviceTurnedOn(deviceID: d.id) : .deviceTurnedOff(deviceID: d.id))
            return
        }
        state.devices[i] = d; save()
    }
    /// Best-effort real control for a device that exposes a local endpoint. Dispatches
    /// across the open dialects this app speaks (WLED / Shelly / Tasmota over HTTP,
    /// Kasa over TCP — verified acks only, dialect cached per host by LANControl).
    /// Fire-and-forget; a device that never acks is marked unreachable AND the
    /// optimistic on-state rolls back to `revertTo`, so a tile can't keep showing an
    /// ON the hardware never confirmed (§5.1).
    private func sendControl(_ d: HFDevice, on: Bool, revertTo prior: Bool? = nil) {
        guard let host = d.host, !host.isEmpty else { return }
        Task { [weak self] in
            let okHit = await LANControl.setSwitch(host: LANControl.bareHost(host), on: on)
            await MainActor.run {
                guard let self, let i = self.state.devices.firstIndex(where: { $0.id == d.id }) else { return }
                self.state.devices[i].reachable = okHit
                if !okHit {
                    if let prior, self.state.devices[i].state.on != prior {
                        self.state.devices[i].state.on = prior
                        self.log(.device, "\(d.name): no response from \(host) — switched back to \(prior ? "on" : "off")")
                    } else {
                        self.log(.device, "\(d.name): no response from \(host)")
                    }
                }
                self.save()
            }
        }
    }
    /// Dim a light. Simulated lights dim locally (honestly labelled); controllable
    /// hardware is driven over its dialect's dimmer verb, and a light that never
    /// acks (or whose dialect has no dimmer) gets its brightness/on rolled back —
    /// a slider must not paint state the lamp never took (§5.1).
    func setBrightness(_ id: UUID, _ v: Double) {
        guard let i = state.devices.firstIndex(where: { $0.id == id }) else { return }
        let d = state.devices[i]
        let prior = (brightness: d.state.brightness, on: d.state.on)
        state.devices[i].state.brightness = v
        if v > 0 { state.devices[i].state.on = true }
        save()
        guard d.control == .controllable, let host = d.host, !host.isEmpty else { return }
        Task { [weak self] in
            let ok = await LANControl.setBrightness(host: LANControl.bareHost(host), level01: v)
            await MainActor.run {
                guard let self, let i = self.state.devices.firstIndex(where: { $0.id == id }) else { return }
                switch ok {
                case true?:
                    self.state.devices[i].reachable = true
                case false?:
                    self.state.devices[i].reachable = false
                    self.state.devices[i].state.brightness = prior.brightness
                    self.state.devices[i].state.on = prior.on
                    self.log(.device, "\(d.name): no response from \(host) — brightness not changed")
                case nil:
                    self.state.devices[i].state.brightness = prior.brightness
                    self.log(.device, "\(d.name): this device's protocol has no local brightness control")
                }
                self.save()
            }
        }
    }
    /// Thermostat setpoint. Reachable only for SIMULATED thermostats (hardware
    /// thermostats are never .controllable — DeviceControlPolicy — because no local
    /// dialect pushes a setpoint; the Climate tab's plan/schedule owns that surface).
    func setTarget(_ id: UUID, tempF: Double) {
        guard let i = state.devices.firstIndex(where: { $0.id == id }) else { return }
        state.devices[i].state.targetTempF = tempF; save()
    }

    // MARK: scenes
    func addScene(_ s: HFScene) { state.scenes.append(s); save(); log(.scene, "Created scene “\(s.name)”") }
    func deleteScene(_ id: UUID) { state.scenes.removeAll { $0.id == id }; save() }
    func runScene(_ id: UUID, fromAutomation: Bool = false) {
        guard let scene = state.scenes.first(where: { $0.id == id }) else { return }
        let before = Dictionary(uniqueKeysWithValues: state.devices.map { ($0.id, $0.state.on ?? false) })
        state.devices = SceneModel.apply(scene, to: state.devices)
        save()
        log(.scene, "Ran scene “\(scene.name)”\(fromAutomation ? " (automation)" : "")")
        // Actually drive the hardware for any controllable device whose on-state changed —
        // a scene that only mutated UI state but never sent the LAN command was a silent no-op.
        for d in state.devices where d.control == .controllable && (d.host?.isEmpty == false) {
            let now = d.state.on ?? false
            if let prior = before[d.id], prior != now { sendControl(d, on: now, revertTo: prior) }
        }
    }

    // MARK: automations
    func addAutomation(_ a: HFAutomation) { state.automations.append(a); save(); log(.system, "Added automation “\(a.name)”") }
    /// VG-30: apply a starter template in ONE TAP. Idempotent by name so a double-tap can't
    /// duplicate the same recipe; returns false (no-op) when it's already applied.
    @discardableResult
    func applyTemplate(_ t: AutomationTemplate) -> Bool {
        guard !state.automations.contains(where: { $0.name == t.name }) else { return false }
        addAutomation(t.build())
        return true
    }
    /// Whether a template is already present (drives the "Added ✓" state on the library card).
    func isTemplateApplied(_ t: AutomationTemplate) -> Bool {
        state.automations.contains(where: { $0.name == t.name })
    }
    func deleteAutomation(_ id: UUID) { state.automations.removeAll { $0.id == id }; save() }
    func toggleAutomation(_ id: UUID) {
        guard let i = state.automations.firstIndex(where: { $0.id == id }) else { return }
        state.automations[i].enabled.toggle(); save()
    }

    // MARK: security
    func setSecurityMode(_ mode: SecurityMode, fromAutomation: Bool = false) {
        guard state.securityMode != mode else { return }
        let wasPending: Bool
        if case .entryPending = alarmPhase { wasPending = true } else { wasPending = false }
        state.securityMode = mode; save()
        log(.security, "Security set to \(mode.label)\(fromAutomation ? " (automation)" : "")")
        if !fromAutomation { fire(.securityModeChanged(mode)) }
        if mode.isArmed {
            // Exit grace: arming with the household still inside must NOT trip the
            // alarm on the owner (the old behavior). Presence is ignored until the
            // grace expires — logged so the countdown is visible in History too.
            armedAt = Date()
            let grace = Int(SecurityModel.exitDelay(mode))
            log(.security, "\(mode.label) arms in \(grace)s — exit delay")
        } else {
            armedAt = nil
            if wasPending { log(.security, "Disarmed during entry delay — no alarm") }
        }
        evaluateAlarm()
    }

    // MARK: sensor nodes
    func upsertSensor(tier: SensorTier, online: Bool, frames: Int) {
        if let i = state.sensors.firstIndex(where: { $0.tier == tier && $0.name.hasPrefix("Live ") }) {
            let was = state.sensors[i].online
            state.sensors[i].online = online; state.sensors[i].framesSeen = frames
            save()
            // Liveness edge → automation trigger (e.g. "when the bedroom Pulse node
            // comes online, enable vitals monitoring").
            if online && !was { fire(.sensorCameOnline(tier: tier)) }
            else if !online && was { fire(.sensorWentOffline(tier: tier)) }
            return
        } else if online {
            state.sensors.append(HFSensorNode(tier: tier, name: "Live \(tier.productName)", online: true, framesSeen: frames))
            log(.sensor, "\(tier.productName) connected")
            save()
            fire(.sensorCameOnline(tier: tier))
            return
        }
        save()
    }
    func addSensorPlaceholder(_ tier: SensorTier, name: String, room: UUID?) {
        state.sensors.append(HFSensorNode(tier: tier, name: name, roomID: room, online: false))
        save(); log(.sensor, "Registered \(tier.productName) “\(name)”")
    }
    func assignSensor(_ id: UUID, toRoom room: UUID?) {
        guard let i = state.sensors.firstIndex(where: { $0.id == id }) else { return }
        state.sensors[i].roomID = room; save()
    }
    func deleteSensor(_ id: UUID) { state.sensors.removeAll { $0.id == id }; save() }

    // MARK: live presence ingest (from the sensing engine / sonar)
    /// Called by the root view as the engine reports whole-home presence. Edge-
    /// detects enter/leave and drives automations + security off REAL sensing.
    func ingestPresence(present raw: Bool) {
        // Debounce the raw sensing signal: only a CONFIRMED transition (stable for
        // the dwell window) commits, killing the sub-second flap that otherwise
        // saturates the 500-event activity ring and evicts real events (GAP #D).
        guard let present = presence.step(raw: raw, now: Date()) else { return }
        homePresent = present
        // map whole-home presence onto rooms that have an online sensor node
        let sensedRooms = Set(state.sensors.filter { $0.online }.compactMap { $0.roomID })
        if present {
            occupied = sensedRooms
            presenceSince = presenceSince ?? Date()
            log(.presence, "Presence detected")
            if sensedRooms.isEmpty { fire(.presenceEntered(roomID: UUID())) }   // home-level rule (roomID nil matches)
            else { sensedRooms.forEach { fire(.presenceEntered(roomID: $0)) } }
        } else {
            let leaving = occupied; occupied = []
            presenceSince = nil
            log(.presence, "Room clear")
            if leaving.isEmpty { fire(.presenceLeft(roomID: UUID())) }
            else { leaving.forEach { fire(.presenceLeft(roomID: $0)) } }
        }
        evaluateAlarm()
    }

    func minuteTick(_ minuteOfDay: Int) {
        guard minuteOfDay != lastMinute else { return }
        lastMinute = minuteOfDay
        fire(.minuteTick(minuteOfDay: minuteOfDay))
    }

    /// Re-derive the alarm phase from the pure SecurityModel and act on TRANSITIONS
    /// only (log/notify once per phase, never per sensing tick). exitGrace and
    /// entryPending schedule a re-evaluation at their deadline so the phase advances
    /// even with no further presence events — a held presence must still escalate.
    private func evaluateAlarm() {
        alarmTimer?.invalidate(); alarmTimer = nil
        let now = Date()
        let phase = SecurityModel.phase(mode: state.securityMode,
                                        anyPresence: homePresent,
                                        occupiedRooms: occupied,
                                        armedAt: armedAt,
                                        presenceSince: presenceSince,
                                        now: now)
        defer { alarmPhase = phase }
        switch phase {
        case .quiet:
            if case .alarm = alarmPhase { log(.security, "Alarm cleared") }
        case .exitGrace(let until):
            scheduleAlarmCheck(at: until)
        case .entryPending(let until):
            if phase != alarmPhase {
                let secs = Int(until.timeIntervalSince(now).rounded(.up))
                log(.alert, "⚠︎ Presence while armed \(state.securityMode.label) — disarm within \(secs)s")
                notify(title: "Vigil security",
                       body: "Presence detected — disarm within \(secs)s or the alarm sounds.")
            }
            scheduleAlarmCheck(at: until)
        case .alarm:
            if phase != alarmPhase {
                let msg = "Presence detected while armed \(state.securityMode.label)"
                lastAlert = msg
                log(.alert, "⚠︎ \(msg)")
                notify(title: "Vigil security", body: msg)
                driveSiren()   // VG-13: sound a favorited controllable device as a local siren
            }
        }
    }

    /// VG-13 — local siren. On an intrusion alarm, drive a favorited controllable LAN
    /// device (strobe a light / toggle a plug / sound a speaker) as a deterrent. Vigil
    /// ships no siren hardware (§5.5); it reuses a device the buyer already controls.
    /// Honesty: with nothing controllable favorited we say so and fire NOTHING; a siren is
    /// logged as SOUNDED only on a real success from the device — a device that did not
    /// respond is logged as such, never as a siren that fired (§5.1). Fired once per alarm
    /// transition (the caller guards `phase != alarmPhase`).
    private func driveSiren() {
        guard let siren = SirenSelector.pick(from: state.devices),
              let host = siren.host, !host.isEmpty else {
            log(.security, "Alarm: no siren device connected — favorite a controllable light/plug/speaker to sound one.")
            return
        }
        log(.security, "Alarm: sounding siren on “\(siren.name)”…")
        Task { [weak self] in
            let ok = await LANControl.setSwitch(host: LANControl.bareHost(host), on: true)
            await MainActor.run {
                guard let self else { return }
                if let i = self.state.devices.firstIndex(where: { $0.id == siren.id }) {
                    self.state.devices[i].reachable = ok
                    if ok { self.state.devices[i].state.on = true }
                    self.save()
                }
                if ok { self.log(.security, "Siren sounded on “\(siren.name)”.") }
                else  { self.log(.security, "Siren device “\(siren.name)” did not respond — no siren fired.") }
            }
        }
    }

    private func scheduleAlarmCheck(at deadline: Date) {
        let interval = max(0.1, deadline.timeIntervalSinceNow + 0.05)
        alarmTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.evaluateAlarm() }
        }
    }

    // MARK: automation engine
    /// A point-in-time view of the home the condition evaluator reads, built from
    /// the live store. Pure data — no fabrication: device on-state is the real
    /// stored state, presence is the debounced sensing signal.
    private func snapshot() -> HomeSnapshot {
        var onByID: [UUID: Bool] = [:]
        for d in state.devices { onByID[d.id] = d.state.on ?? false }
        // Use the real wall-clock minute until the first minuteTick has run, so
        // time-window conditions are honest from the very first event.
        let minute: Int
        if lastMinute >= 0 { minute = lastMinute }
        else {
            let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
            minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
        return HomeSnapshot(securityMode: state.securityMode,
                            minuteOfDay: minute,
                            homePresent: homePresent,
                            deviceOnByID: onByID)
    }
    private func fire(_ event: HomeEvent) {
        // Full spine: trigger match AND every condition passes against the snapshot.
        for (auto, actions) in AutomationEvaluator.fired(by: event,
                                                         automations: state.automations,
                                                         snapshot: snapshot()) {
            for a in actions { run(a, from: auto) }
        }
    }
    private func run(_ a: HomeAction, from auto: HFAutomation) {
        switch a.kind {
        case .runScene:        if let s = a.sceneID { runScene(s, fromAutomation: true) }
        case .setSecurityMode: if let m = a.mode { setSecurityMode(m, fromAutomation: true) }
        case .setDeviceOn, .setDeviceOff:
            if let id = a.deviceID, let i = state.devices.firstIndex(where: { $0.id == id }) {
                let on = (a.kind == .setDeviceOn)
                let prior = state.devices[i].state.on ?? false
                state.devices[i].state.on = on
                log(.device, "\(state.devices[i].name): \(on ? "on" : "off") (automation)")
                save()
                // Actually drive the hardware — an automation that only flipped UI state but never
                // sent the LAN command silently failed to control the real device.
                let d = state.devices[i]
                if d.control == .controllable, d.host?.isEmpty == false { sendControl(d, on: on, revertTo: prior) }
            }
        case .notify:
            let m = a.message ?? "Automation “\(auto.name)” fired"
            lastAlert = m; log(.alert, m); notify(title: "Vigil", body: m)
        }
    }

    private func notify(title: String, body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        c.sound = .default                       // make the critical channel non-silent
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        // DG-2: surface (don't swallow) an OS-side delivery failure. The emergency
        // path must not fail silently — a dropped notification is logged so it is at
        // least visible in History. log(.system,…) does not itself notify, so this
        // cannot loop.
        UNUserNotificationCenter.current().add(req) { [weak self] error in
            guard let error = error else { return }
            Task { @MainActor in self?.log(.system, "Notification delivery failed: \(error.localizedDescription)") }
        }
    }

    /// POST a critical alert to the buyer-configured off-device relay. Mirrors the
    /// `notify` DG-2 honesty: a transport error or non-2xx is LOGGED to History, never
    /// swallowed and never read as "delivered" (§5.1). Success is logged once so the
    /// buyer can see the alert really left the box. The relay endpoint itself is never
    /// logged (it may carry a token). Non-critical/unconfigured events never reach here
    /// — they are gated out in logCritical via RemoteRelay.request.
    /// Thin adapter: RemoteRelaySender performs the POST and CLASSIFIES the result; this only
    /// logs the outcome and records the health. Keeping the decision in RemoteRelaySender is what
    /// lets test.sh drive the real 200 / 500 / transport-error / unconfigured legs against a live
    /// socket — the round-trip used to be executed by nobody but the shipped app.
    private func sendRemoteRelay(_ req: RemoteRelayRequest, isTest: Bool = false) {
        let label = isTest ? "Away Alerts test" : "Remote alert"
        RemoteRelaySender.send(req) { [weak self] result in
            Task { @MainActor in
                if isTest { self?.testAlertInFlight = false }
                self?.log(.system, result.logLine(label: label))
                self?.recordRelayDelivery(ok: result.ok)
            }
        }
    }

    /// Away Alerts "Send test alert": fire a REAL, clearly-labelled test POST to the
    /// buyer's configured relay so they can prove it reaches their phone before trusting
    /// it with a fall. Returns false (and does nothing) when no valid endpoint is set —
    /// the button never fakes a send on an empty relay (§5.2). The outcome is recorded on
    /// the SAME lastDelivery health the card reads, so a working test lights the relay
    /// health line honestly from a real URLSession result (§5.1).
    @discardableResult
    func sendTestAlert() -> Bool {
        guard let req = RemoteRelay.testRequest(config: state.relay) else { return false }
        testAlertInFlight = true
        log(.system, "Away Alerts test sent to relay…")
        sendRemoteRelay(req, isTest: true)
        return true
    }

    /// Persist the outcome of the LAST relay POST so the Fall card can show whether the
    /// off-device safety net is actually live (configured != proven-working). Records ONLY
    /// the real URLSession result — `ok: true` is reserved for a genuine 2xx (§5.1). The
    /// relay endpoint is never stored here (it may carry a token).
    private func recordRelayDelivery(ok: Bool) {
        state.relay.lastDelivery = RelayDelivery(at: Date(), ok: ok)
        save()
    }

    // MARK: off-device relay config (buyer-supplied; ships empty, §5.2)
    /// Set/replace the relay webhook URL. Validates HONESTLY: a blank value CLEARS the
    /// relay (back to "not configured"); a malformed value is REJECTED (logged, the
    /// prior config left unchanged — never silently kept as if valid, §5.1). Returns
    /// true only when a real endpoint was stored or the relay was intentionally cleared.
    @discardableResult
    func setRelayWebhook(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if !state.relay.webhook.isEmpty { state.relay.webhook = ""; state.relay.lastDelivery = nil; save(); log(.system, "Remote alert relay cleared.") }
            return true
        }
        guard RemoteRelayConfig.validate(trimmed) != nil else {
            log(.system, "Remote alert relay rejected: not a valid http(s) URL.")
            return false
        }
        if state.relay.webhook != trimmed { state.relay.lastDelivery = nil }  // new endpoint -> prior delivery health no longer applies (§5.1)
        state.relay.webhook = trimmed; save()
        log(.system, "Remote alert relay set.")
        return true
    }
    func clearRelayWebhook() { setRelayWebhook("") }

    // MARK: monitor mode (VG-27 — elder/solo vitals watch; ships disabled, §5.2)

    /// Turn monitor mode on/off. Turning it on resets the runtime debouncer so a stale
    /// concern from a prior session can never carry forward.
    func setMonitorMode(enabled: Bool) {
        state.monitor.enabled = enabled
        if enabled { vitalsMonitor = VitalsMonitor() }
        save()
        log(.system, enabled ? "Monitor mode enabled." : "Monitor mode disabled.")
    }
    /// Set the DESIGNATED CONTACT name shown in the caregiver alert. The relay endpoint
    /// (setRelayWebhook) is the channel that actually reaches them.
    func setDesignatedContact(_ name: String) {
        state.monitor.designatedContact = name.trimmingCharacters(in: .whitespacesAndNewlines); save()
    }
    /// Choose the resident under watch (or nil = unattributed — never a fabricated occupant).
    func setMonitorResident(_ id: UUID?) { state.monitor.residentID = id; save() }

    /// Feed ONE fused vitals sample into monitor mode's 20s debounce. Does nothing unless
    /// monitor mode is enabled. On a COMMITTED concern transition (a real gate-passing danger
    /// reading held for 20s) it pages the designated contact through the SAME Away Alerts relay
    /// as a fall — logCritical(.anomaly) both banners locally and POSTs off-device (§5.1: the
    /// body quotes the real reading, never a diagnosis; a nil/absent BPM can never page). A
    /// committed RECOVERY (back to .none) logs a resolve so History stays honest.
    func stepVitalsMonitor(_ sample: VitalsSample, now: Date = Date()) {
        guard state.monitor.enabled else { return }
        guard let committed = vitalsMonitor.step(sample, now: now) else { return }
        let resident = state.resident(byID: state.monitor.residentID)
        if committed.isConcern, let body = committed.alertBody(resident: resident?.name) {
            logCritical(.anomaly, body, resident: resident)
        } else if !committed.isConcern {
            log(.system, "Monitor mode: vitals returned to a normal range.")
        }
    }

    // MARK: notification authorization (the delivery gate must be HONEST)
    /// Read the OS's real authorization status into `notifAuth` so the Fall card shows
    /// ON / OFF / DENIED truthfully — never a silent "armed" claim (§5.1). Safe to call
    /// on every app/tab open: it only READS, it never prompts.
    func refreshNotifAuth() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let mapped = NotifAuthState.from(rawValue: settings.authorizationStatus.rawValue)
            Task { @MainActor in self?.notifAuth = mapped }
        }
    }

    /// Ask the OS for permission and reconcile the displayed status. DG-3: the
    /// `(granted, error)` callback is USED, not discarded — granted gives immediate
    /// feedback and refreshNotifAuth() reconciles against the authoritative settings
    /// (covers provisional/ephemeral). Once determined the OS won't re-prompt; the UI
    /// routes the buyer to System Settings via `notifAuth.canEnableInApp`.
    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Task { @MainActor in
                if let error = error { self?.log(.system, "Notification permission error: \(error.localizedDescription)") }
                self?.notifAuth = granted ? .authorized : .denied
                self?.refreshNotifAuth()
            }
        }
    }

    /// Request auth at a real eldercare moment (resident added / Fall tab opened),
    /// prompting ONLY when it has never been asked — once determined we just reconcile
    /// the card, never re-prompt on every open.
    func requestNotificationsIfNeeded() {
        switch notifAuth {
        case .denied, .authorized, .provisional: refreshNotifAuth()   // determined — reconcile only
        case .unknown, .notDetermined:           requestNotifications()
        }
    }
}
#endif // circuit-convert
