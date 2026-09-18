// Black Label Academy — AC-09 opt-in cohort completion lever (peer-progress signal).
//
// The single biggest documented completion lever is learning alongside other people — an opt-in
// cohort start-date plus a lightweight "N others finished this lesson" signal (skyline §2 cites a
// 5–15× completion lift). This file adds that ADDITIVELY on top of the solo reader without ever
// compromising Academy's two ship promises.
//
// ISOLATION (same posture as Sources/Updater.swift — the ONLY other file that touches the network):
// ALL cohort networking lives in THIS file. The read path (ContentDB / Markdown / Model) never
// imports or references it, so the offline owned reader stays zero-network (AC-03). Cohort is opt-in
// and ships JOINED-OFF, so a fresh install makes ZERO network calls until the buyer explicitly joins.
//
// HONESTY (⛔ §5.1 / H6 — non-negotiable):
//   • A fresh/not-joined install shows NO peer number and makes NO network call.
//   • A peer count renders ONLY from a REAL, validated server response for the cohort the device is
//     actually joined to. There is no locally-seeded, cached-guess, or interpolated peer number.
//   • Joined but the server is empty/unreachable → an HONEST "No cohort running yet" state, never a
//     fabricated or stale count.
//   • `CohortEngine.validate` is the runtime tooth: it REJECTS any signal that the join state cannot
//     back (rendered while not joined, for the wrong cohort/lesson, negative, or larger than the
//     cohort itself). A planted "9999 peers" is rejected — proven by `--selftest-cohort`.
//
// PRIVACY: the server stores an ANONYMOUS device token only (a random UUID minted on this device) —
// no email, no name, no PII. The token exists solely to make the per-lesson completion count
// idempotent (finishing a lesson twice never double-counts).
//
// PRICING: a cohort/community price is a founder money gate (§3). This feature ships flagged/free
// with ZERO price copy — it does not name, imply, or wire any charge.
import Foundation
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CircuitPortKit

// MARK: - Pure value types + honesty engine (testable headlessly, cannot drift from the UI)

/// A validated peer-progress signal: how many OTHER cohort members have finished a specific lesson.
/// Only ever produced by decoding a real server response (`CohortResponse`); never constructed from a
/// guess. `othersFinished` excludes the current device.
struct PeerSignal: Equatable {
    let cohortID: String
    let lessonID: String
    let othersFinished: Int   // real count from the server, excluding this device
    let cohortSize: Int       // total members in the cohort (the ceiling any honest count obeys)
}

/// The device's local cohort membership: which cohort it opted into and when that cohort starts.
/// `token` is the anonymous per-device UUID (no PII). Purely local — created only on an explicit join.
struct CohortJoin: Equatable {
    let cohortID: String
    let token: String
    let startDate: Date
}

/// The wire shape the cohort server returns for a signal request. `active:false` (or a missing body)
/// is the honest "no cohort running yet" state — it carries no count. Snake_case wire keys.
struct CohortResponse: Codable, Equatable {
    var active: Bool
    var cohortID: String?
    var lessonID: String?
    var othersFinished: Int?
    var cohortSize: Int?

    enum CodingKeys: String, CodingKey {
        case active
        case cohortID = "cohort_id"
        case lessonID = "lesson_id"
        case othersFinished = "others_finished"
        case cohortSize = "cohort_size"
    }
}

/// The wire shape returned by a join request. `cohort_id` + `start_date` (ISO-8601) identify the
/// cohort the anonymous token was enrolled into.
struct CohortJoinResponse: Codable, Equatable {
    var cohortID: String
    var startDate: String

    enum CodingKeys: String, CodingKey {
        case cohortID = "cohort_id"
        case startDate = "start_date"
    }
}

/// Pure cohort honesty logic — no I/O, no clock, fully testable. This is the AC-09 analogue of the
/// streak's `StreakEngine.validate`: a peer number is only allowed to render if the real join state
/// can back it.
enum CohortEngine {
    /// The runtime honesty tooth (§5.1 / H6). Returns the list of violations for a peer signal given
    /// the device's join state — a NON-EMPTY result REJECTS the signal so no number renders. Rejects:
    ///  • a signal rendered while the device is NOT joined to any cohort (fabricated presence);
    ///  • a signal for a different cohort than the one joined (leaked/wrong cohort);
    ///  • a signal for a different lesson than requested (mismatched context);
    ///  • a negative count, or a count larger than the cohort itself (structurally impossible).
    static func validate(_ signal: PeerSignal, joinedCohortID: String?, lessonID: String) -> [String] {
        var errors: [String] = []
        guard let joined = joinedCohortID else {
            errors.append("peer signal rendered while not joined to any cohort (fabricated presence)")
            return errors
        }
        if signal.cohortID != joined {
            errors.append("peer signal cohort \(signal.cohortID) != joined cohort \(joined) (wrong cohort)")
        }
        if signal.lessonID != lessonID {
            errors.append("peer signal lesson \(signal.lessonID) != requested lesson \(lessonID) (wrong context)")
        }
        if signal.othersFinished < 0 {
            errors.append("peer count \(signal.othersFinished) is negative (impossible)")
        }
        if signal.cohortSize < 0 {
            errors.append("cohort size \(signal.cohortSize) is negative (impossible)")
        }
        // The current device is excluded from `othersFinished`, so it can be at most cohortSize-1.
        if signal.othersFinished > max(0, signal.cohortSize - 1) {
            errors.append("peer count \(signal.othersFinished) exceeds the \(signal.cohortSize)-member cohort (fabricated)")
        }
        return errors
    }

    /// Decode a raw server response into a validated `PeerSignal`, or nil if the server reports no
    /// active cohort / an unparseable body / a signal the join state cannot back. This is the ONLY
    /// path from bytes to a rendered peer number, so a fabricated or mismatched count never surfaces.
    static func peerSignal(from data: Data, joinedCohortID: String, lessonID: String) -> PeerSignal? {
        guard let resp = try? JSONDecoder().decode(CohortResponse.self, from: data),
              resp.active,
              let cid = resp.cohortID, let lid = resp.lessonID,
              let others = resp.othersFinished, let size = resp.cohortSize
        else { return nil }
        let signal = PeerSignal(cohortID: cid, lessonID: lid, othersFinished: others, cohortSize: size)
        return validate(signal, joinedCohortID: joinedCohortID, lessonID: lessonID).isEmpty ? signal : nil
    }

    /// The human line for a validated signal. Kept here so the UI and the self-test render identically.
    static func peerLine(_ s: PeerSignal) -> String {
        switch s.othersFinished {
        case 0:  return "No one else in your cohort has finished this lesson yet."
        case 1:  return "1 other in your cohort finished this lesson."
        default: return "\(s.othersFinished) others finished this lesson in your cohort."
        }
    }
}

// MARK: - Transport (the isolated network seam)

/// The cohort endpoints. Modeled as a value so the transport is trivially mockable in the self-test
/// and so the client's control flow (never call the network when not joined) is provable.
enum CohortEndpoint: Hashable {
    case join(token: String)
    case complete(cohortID: String, lessonID: String, token: String)
    case signal(cohortID: String, lessonID: String)
}

/// The single network seam. A real implementation talks HTTPS to the cohort Worker; the self-test
/// injects a counting/failing mock. `send` returns raw server bytes or throws on any failure.
protocol CohortTransport {
    func send(_ endpoint: CohortEndpoint) throws -> Data
}

enum CohortTransportError: Error { case unreachable, badStatus(Int) }

/// The production transport — the ONLY code in the app that opens a socket for cohort. Synchronous
/// (semaphore-bridged) because it is called exclusively from explicit user actions (join / refresh),
/// never from the read path, so it can never block a render. Anonymous: it sends the device token,
/// never a name or email.
struct URLSessionCohortTransport: CohortTransport {
    let baseURL: URL
    let session: URLSession
    let timeout: TimeInterval

    init(baseURL: URL = AcademyConfig.cohortBaseURL,
         session: URLSession = .shared,
         timeout: TimeInterval = 8) {
        self.baseURL = baseURL
        self.session = session
        self.timeout = timeout
    }

    func send(_ endpoint: CohortEndpoint) throws -> Data {
        var req: URLRequest
        switch endpoint {
        case .join(let token):
            req = URLRequest(url: baseURL.appendingPathComponent("join"))
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: ["token": token])
        case .complete(let cohortID, let lessonID, let token):
            req = URLRequest(url: baseURL.appendingPathComponent("complete"))
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: [
                "cohort_id": cohortID, "lesson_id": lessonID, "token": token,
            ])
        case .signal(let cohortID, let lessonID):
            var comps = URLComponents(url: baseURL.appendingPathComponent("signal"),
                                      resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                URLQueryItem(name: "cohort_id", value: cohortID),
                URLQueryItem(name: "lesson_id", value: lessonID),
            ]
            req = URLRequest(url: comps.url!)
            req.httpMethod = "GET"
        }
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var out: Data?
        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { failure = err; return }
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                failure = CohortTransportError.badStatus(http.statusCode); return
            }
            out = data
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        if let failure { throw failure }
        guard let out else { throw CohortTransportError.unreachable }
        return out
    }
}

// MARK: - Local join store (opt-in membership; anonymous token only)

/// Durable, local-only cohort membership backed by UserDefaults (a single small record — no library
/// data, no PII). Nothing here reaches the network; it only remembers whether the buyer opted in and
/// which anonymous token/cohort/start-date they hold. A fresh install has NO join record, which is
/// exactly what keeps the app joined-off and zero-network by default.
final class CohortStore {
    private let defaults: UserDefaults
    private let kToken = "bl.academy.cohort_token"
    private let kCohort = "bl.academy.cohort_id"
    private let kStart = "bl.academy.cohort_start"   // ISO-8601

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The anonymous per-device token, minted lazily on first join. A random UUID — never tied to a
    /// person. Persisted so completion counts stay idempotent across launches.
    func deviceToken() -> String {
        if let t = defaults.string(forKey: kToken), !t.isEmpty { return t }
        let t = UUID().uuidString
        defaults.set(t, forKey: kToken)
        return t
    }

    /// The current membership, or nil if the buyer has NOT opted in (the default). While nil, the
    /// client never touches the network.
    func currentJoin() -> CohortJoin? {
        guard let cid = defaults.string(forKey: kCohort), !cid.isEmpty,
              let iso = defaults.string(forKey: kStart),
              let start = ISO8601DateFormatter().date(from: iso)
        else { return nil }
        return CohortJoin(cohortID: cid, token: deviceToken(), startDate: start)
    }

    var isJoined: Bool { currentJoin() != nil }

    /// Persist an opt-in join (called only after a real server enrollment succeeds).
    func saveJoin(cohortID: String, startDate: Date) {
        defaults.set(cohortID, forKey: kCohort)
        defaults.set(ISO8601DateFormatter().string(from: startDate), forKey: kStart)
    }

    /// Leave the cohort. The token is kept so a rejoin stays idempotent, but membership is cleared,
    /// which returns the app to the zero-network default.
    func leave() {
        defaults.removeObject(forKey: kCohort)
        defaults.removeObject(forKey: kStart)
    }
}

// MARK: - Observable client (opt-in; never calls the network when not joined)

/// Drives the cohort surface. The display state is an enum so the UI can only ever show one of three
/// HONEST things: not-joined, joined-but-no-live-cohort, or a validated peer signal. There is no
/// fourth "guessed number" state. Refreshing a signal short-circuits to `.notJoined` with ZERO
/// network calls when the buyer has not opted in.
@MainActor
final class CohortClient: ObservableObject {
    /// The only three things the UI may show. `.peer` carries a signal that already passed `validate`.
    enum Display: Equatable {
        case notJoined                    // opt-in surface; no network happened
        case joinedNoData(startDate: Date) // "No cohort running yet" — joined, server empty/unreachable
        case peer(PeerSignal)             // a REAL validated "N others finished this lesson"
    }

    @Published private(set) var display: Display = .notJoined
    @Published private(set) var lastError: String?

    private let store: CohortStore
    private let transport: CohortTransport

    init(store: CohortStore = CohortStore(),
         transport: CohortTransport? = nil) {
        self.store = store
        self.transport = transport ?? URLSessionCohortTransport()
        self.display = store.isJoined
            ? .joinedNoData(startDate: store.currentJoin()!.startDate)
            : .notJoined
    }

    var isJoined: Bool { store.isJoined }

    /// Opt in: enroll the anonymous device token with the server and persist the returned cohort +
    /// start date. Only THIS explicit action (or `refreshSignal`/`markCompleted` while joined) ever
    /// touches the network. Returns true on a real enrollment.
    @discardableResult
    func join() -> Bool {
        lastError = nil
        do {
            let data = try transport.send(.join(token: store.deviceToken()))
            guard let resp = try? JSONDecoder().decode(CohortJoinResponse.self, from: data),
                  let start = ISO8601DateFormatter().date(from: resp.startDate),
                  !resp.cohortID.isEmpty else {
                lastError = "No cohort is open to join yet."
                return false
            }
            store.saveJoin(cohortID: resp.cohortID, startDate: start)
            display = .joinedNoData(startDate: start)   // no peer number until a real signal arrives
            return true
        } catch {
            lastError = "Couldn't reach the cohort server."
            return false
        }
    }

    /// Leave the cohort — returns the surface to the opt-in, zero-network default.
    func leave() {
        store.leave()
        display = .notJoined
        lastError = nil
    }

    /// Refresh the peer signal for a lesson. HONESTY-CRITICAL CONTROL FLOW:
    ///   • NOT joined → set `.notJoined` and return WITHOUT any transport call (zero network).
    ///   • joined → exactly one transport call; a decodable+validated body renders `.peer`, anything
    ///     else (unreachable, empty, `active:false`, or a signal `validate` rejects) → `.joinedNoData`.
    /// A peer number therefore renders ONLY from a real, validated server response.
    func refreshSignal(lessonID: String) {
        guard let join = store.currentJoin() else {
            display = .notJoined         // zero network when not opted in
            return
        }
        do {
            let data = try transport.send(.signal(cohortID: join.cohortID, lessonID: lessonID))
            if let signal = CohortEngine.peerSignal(from: data,
                                                    joinedCohortID: join.cohortID,
                                                    lessonID: lessonID) {
                display = .peer(signal)
            } else {
                display = .joinedNoData(startDate: join.startDate)   // honest empty, never a guess
            }
        } catch {
            display = .joinedNoData(startDate: join.startDate)       // unreachable → honest empty
        }
    }

    /// Report that the buyer finished a lesson, so the anonymous per-lesson count grows for the rest
    /// of the cohort. No-op (and no network) when not joined. Best-effort: a failure never surfaces a
    /// fabricated local number.
    func markCompleted(lessonID: String) {
        guard let join = store.currentJoin() else { return }
        _ = try? transport.send(.complete(cohortID: join.cohortID, lessonID: lessonID, token: join.token))
    }
}

// MARK: - SwiftUI surface (additive; opt-in; no price copy)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
#if canImport(SwiftUI)
/// The cohort panel shown in Settings on both platforms. It is purely additive to the solo reader and
/// never blocks it. Three honest states, no price copy anywhere. The strings "cohort", "peer", and
/// "others finished" are user-facing here (they compile into the binary as the AC-09 proof).
struct CohortPanel: View {
    @StateObject private var client = CohortClient()
    /// A representative lesson to preview the peer signal against (the reader passes the open lesson;
    /// Settings previews the first lesson id). Optional — the panel still renders the opt-in state.
    var previewLessonID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.3.fill").foregroundColor(BLTheme.goldLite).font(.system(size: 12))
                Text("Cohort — learn alongside others")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(BLTheme.goldLite)
                Spacer()
            }
            switch client.display {
            case .notJoined:
                Text("Optional: start the library with a cohort and see peer progress — how many others finished each lesson. Nothing is shared but an anonymous count; you can leave anytime.")
                    .font(.system(size: 11)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                Button { client.join(); refresh() } label: {
                    Text("Join a cohort").font(.system(size: 11, weight: .semibold)).foregroundColor(BLTheme.cyan)
                }.buttonStyle(.plain)
            case .joinedNoData(let start):
                Text("You're in the cohort starting \(Self.dateFmt.string(from: start)).")
                    .font(.system(size: 11.5)).foregroundColor(BLTheme.text)
                Text("No cohort running yet — peer progress will appear here once other members start finishing lessons.")
                    .font(.system(size: 11)).foregroundColor(BLTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
                leaveButton
            case .peer(let signal):
                Text(CohortEngine.peerLine(signal))
                    .font(.system(size: 11.5)).foregroundColor(BLTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                leaveButton
            }
            if let err = client.lastError {
                Text(err).font(.system(size: 10.5)).foregroundColor(BLTheme.sub)
            }
        }
        .onAppear(perform: refresh)
    }

    private var leaveButton: some View {
        Button { client.leave() } label: {
            Text("Leave cohort").font(.system(size: 11, weight: .semibold)).foregroundColor(BLTheme.sub)
        }.buttonStyle(.plain)
    }

    private func refresh() {
        if let id = previewLessonID { client.refreshSignal(lessonID: id) }
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()
}
#endif
#endif // circuit-convert

// MARK: - Headless self-test (`--selftest-cohort`) — proves the three honesty invariants

/// A transport that COUNTS calls and can be told to fail or return canned bytes. Lets the self-test
/// prove "not joined → zero network" and "joined + empty/unreachable → honest empty" deterministically.
final class MockCohortTransport: CohortTransport {
    private(set) var callCount = 0
    var responses: [CohortEndpoint: Data] = [:]
    var throwOnEverything = false

    func send(_ endpoint: CohortEndpoint) throws -> Data {
        callCount += 1
        if throwOnEverything { throw CohortTransportError.unreachable }
        // Match by case (ignore associated values so canned bytes are easy to register).
        for (key, data) in responses where sameCase(key, endpoint) { return data }
        throw CohortTransportError.unreachable
    }

    private func sameCase(_ a: CohortEndpoint, _ b: CohortEndpoint) -> Bool {
        switch (a, b) {
        case (.join, .join), (.complete, .complete), (.signal, .signal): return true
        default: return false
        }
    }
}

/// `Black Label Academy --selftest-cohort`. Proves, without a WindowServer:
///  1. NOT joined → `refreshSignal` makes ZERO network calls and shows `.notJoined`;
///  2. joined + empty/unreachable server → honest `.joinedNoData` ("No cohort running yet"), NO number;
///  3. a REAL validated server response → the exact peer count renders;
///  4. a PLANTED fake peer count (impossible / wrong-cohort / not-joined) is REJECTED by `validate`.
/// Wired into tests/smoke.sh as the reproducible AC-09 proof. Platform-agnostic (cohort ships on both).
@MainActor
func runCohortSelfTest() -> Never {
    print("== Black Label Academy — cohort peer-progress self-test ==")
    var ok = true
    var liveProven = false
    func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL: \(msg)"); ok = false } }

    let suite = "bl.academy.cohort.selftest.\(ProcessInfo.processInfo.processIdentifier)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = CohortStore(defaults: defaults)

    // 1) NOT joined → refreshing a signal makes ZERO network calls and stays notJoined.
    let mock1 = MockCohortTransport()
    let c1 = CohortClient(store: store, transport: mock1)
    c1.refreshSignal(lessonID: "operations__llc-basics-101")
    print("  not-joined refresh → transport calls=\(mock1.callCount), display=\(c1.display)")
    check(mock1.callCount == 0, "a not-joined refresh made \(mock1.callCount) network call(s) (must be zero)")
    check(c1.display == .notJoined, "a not-joined refresh did not stay .notJoined")

    // Opt in with a real join response, then prove the empty-server + real-signal + planted cases.
    let cohortID = "cohort-2026-07-13"
    let startDate = Date(timeIntervalSince1970: 1_752_364_800)  // fixed, deterministic
    store.saveJoin(cohortID: cohortID, startDate: startDate)

    // 2) Joined + unreachable/empty server → honest joinedNoData, NO peer number.
    let mock2 = MockCohortTransport(); mock2.throwOnEverything = true
    let c2 = CohortClient(store: store, transport: mock2)
    c2.refreshSignal(lessonID: "operations__llc-basics-101")
    print("  joined + unreachable → calls=\(mock2.callCount), display=\(c2.display)")
    check(mock2.callCount == 1, "a joined refresh should make exactly one network attempt")
    if case .joinedNoData = c2.display {} else { check(false, "unreachable server did not fall back to honest 'No cohort running yet'") }

    // 2b) Joined but server reports no active cohort (active:false) → still honest empty, no number.
    let mock2b = MockCohortTransport()
    mock2b.responses[.signal(cohortID: cohortID, lessonID: "x")] =
        Data(#"{"active":false}"#.utf8)
    let c2b = CohortClient(store: store, transport: mock2b)
    c2b.refreshSignal(lessonID: "operations__llc-basics-101")
    if case .joinedNoData = c2b.display {} else { check(false, "active:false did not render honest empty") }

    // 3) A REAL, validated server response → the exact peer count renders.
    let lesson = "operations__llc-basics-101"
    let realBody = #"{"active":true,"cohort_id":"\#(cohortID)","lesson_id":"\#(lesson)","others_finished":7,"cohort_size":24}"#
    let mock3 = MockCohortTransport()
    mock3.responses[.signal(cohortID: cohortID, lessonID: lesson)] = Data(realBody.utf8)
    let c3 = CohortClient(store: store, transport: mock3)
    c3.refreshSignal(lessonID: lesson)
    if case .peer(let s) = c3.display {
        print("  real signal → \(CohortEngine.peerLine(s))")
        check(s.othersFinished == 7 && s.cohortSize == 24 && s.cohortID == cohortID,
              "the validated peer signal did not carry the server's real numbers")
    } else {
        check(false, "a real validated server response did not render a peer signal")
    }

    // 4) PLANTED fake peer counts are REJECTED by validate (the H6 honesty tooth).
    // 4a) impossible count (larger than the cohort).
    let planted = PeerSignal(cohortID: cohortID, lessonID: lesson, othersFinished: 9999, cohortSize: 24)
    let v4a = CohortEngine.validate(planted, joinedCohortID: cohortID, lessonID: lesson)
    if v4a.isEmpty { print("FAIL: a planted 9999-peer count PASSED validation (H6 gate broken)"); ok = false }
    else { print("  planted-count rejection OK — \(v4a.first!)") }
    // 4b) a signal rendered while NOT joined is rejected.
    let v4b = CohortEngine.validate(PeerSignal(cohortID: cohortID, lessonID: lesson, othersFinished: 3, cohortSize: 24),
                                    joinedCohortID: nil, lessonID: lesson)
    check(!v4b.isEmpty, "a peer signal while not joined must be rejected")
    // 4c) a signal for a DIFFERENT cohort than the one joined is rejected.
    let v4c = CohortEngine.validate(PeerSignal(cohortID: "someone-elses-cohort", lessonID: lesson, othersFinished: 3, cohortSize: 24),
                                    joinedCohortID: cohortID, lessonID: lesson)
    check(!v4c.isEmpty, "a peer signal for a cohort the device did not join must be rejected")
    // 4d) the decode path itself refuses to surface a planted body whose count is impossible.
    let plantedBody = #"{"active":true,"cohort_id":"\#(cohortID)","lesson_id":"\#(lesson)","others_finished":9999,"cohort_size":24}"#
    let decoded = CohortEngine.peerSignal(from: Data(plantedBody.utf8), joinedCohortID: cohortID, lessonID: lesson)
    check(decoded == nil, "the decode path surfaced an impossible planted peer count (must return nil)")
    // 4e) the honest real signal passes validation (no false positives).
    check(CohortEngine.validate(PeerSignal(cohortID: cohortID, lessonID: lesson, othersFinished: 7, cohortSize: 24),
                                joinedCohortID: cohortID, lessonID: lesson).isEmpty,
          "an honest server-backed signal must pass validation")

    // 5) LIVE round-trip against the deployed cohort Worker, through the PRODUCTION transport.
    // Mocks above prove the honesty logic; this proves the logic is wired to the real endpoint.
    // READ-ONLY on purpose: it calls `signal` and never `join`, because joining a probe token would
    // enroll a fake member and inflate `cohort_size` for real buyers. The raw served bytes are printed
    // so a live pass can never be confused with a canned one.
    // Offline CI stays deterministic: an unreachable server SKIPS (the mock proofs above still gate).
    // Pass `--require-live` to make the live leg mandatory — that is the AC-09 wiring evidence run.
    let requireLive = CommandLine.arguments.contains("--require-live")
    // Mirrors the Worker's OPEN_COHORT_ID (web/cohort-worker.js). The APP never hardcodes this — it
    // learns its cohort id from the `join` response. It lives here only so the self-test can READ the
    // live open cohort without writing a membership.
    let liveCohortID = "cohort-open"
    let liveLesson = "operations__llc-basics-101"
    let liveTransport = URLSessionCohortTransport(baseURL: AcademyConfig.cohortBaseURL)
    print("  live endpoint → \(AcademyConfig.cohortBaseURL.absoluteString)")
    do {
        // The real open cohort, fetched over HTTPS from the deployed Worker.
        let bytes = try liveTransport.send(.signal(cohortID: liveCohortID, lessonID: liveLesson))
        let body = String(decoding: bytes, as: UTF8.self)
        print("  live signal(\(liveCohortID)) → served bytes: \(body)")
        check(!bytes.isEmpty, "the live cohort endpoint returned no bytes")

        // The client half, end-to-end: a device joined to the live cohort, refreshing through the
        // PRODUCTION transport against the LIVE server. An empty cohort must render the honest empty
        // state — never a fabricated or placeholder number.
        store.saveJoin(cohortID: liveCohortID, startDate: startDate)
        let liveClient = CohortClient(store: store, transport: liveTransport)
        liveClient.refreshSignal(lessonID: liveLesson)
        switch liveClient.display {
        case .joinedNoData:
            print("  live joined+empty → honest 'No cohort running yet' (no number fabricated)")
        case .peer(let s):
            // A live cohort with real members is legitimate — but it must still validate.
            check(CohortEngine.validate(s, joinedCohortID: liveCohortID, lessonID: liveLesson).isEmpty,
                  "the LIVE server's peer signal failed validation")
            print("  live joined+active → validated peer signal \(s.othersFinished)/\(s.cohortSize)")
        case .notJoined:
            check(false, "a joined device rendered .notJoined against the live server")
        }

        // The planted-count tooth still bites on a body wearing the LIVE cohort's id: even if the
        // server were compromised and returned an impossible count, the client refuses to show it.
        let livePlanted = #"{"active":true,"cohort_id":"\#(liveCohortID)","lesson_id":"\#(liveLesson)","others_finished":9999,"cohort_size":24}"#
        check(CohortEngine.peerSignal(from: Data(livePlanted.utf8),
                                      joinedCohortID: liveCohortID, lessonID: liveLesson) == nil,
              "a planted count carrying the LIVE cohort id was surfaced (H6 gate broken)")
        print("  live-shaped planted count (9999/24) → REJECTED")
        liveProven = true
    } catch {
        if requireLive {
            print("FAIL: --require-live was set but the live cohort endpoint was unreachable: \(error)")
            ok = false
        } else {
            print("  LIVE SKIPPED — cohort endpoint unreachable (\(error)); mock proofs above still gate")
        }
    }
    if requireLive { check(liveProven, "the live round-trip did not complete") }

    let liveNote = liveProven ? " Live round-trip against \(AcademyConfig.cohortBaseURL.absoluteString) confirmed."
                              : " (live leg skipped — offline)"
    print(ok ? "COHORT SELFTEST OK — not-joined makes zero network, joined+empty renders honest 'No cohort running yet', a peer count renders only from a real validated response, and a planted count is rejected.\(liveNote)"
             : "COHORT SELFTEST FAILED")
    exit(ok ? 0 : 1)
}
