#if canImport(AppKit) && !CIRCUIT_WINDOWS_SIM
import AppKit
#endif
#if canImport(Combine) && !CIRCUIT_WINDOWS_SIM
import Combine
#else
import OpenCombine
import OpenCombineFoundation
import OpenCombineDispatch
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import CircuitPortKit

/// Deterministic grammar and assembly for the morning brief — "did anything
/// happen last night?", "what's my day look like", "brief me".
///
/// Founder requirement 2026-08-07: the brief must be REAL. It is assembled by
/// app-owned code from the bundled read-only tools the owner already granted,
/// never invented by a model and never spoken as a plausible-sounding guess.
/// A source that cannot be read is reported as unavailable, out loud, by name —
/// the same fail-closed posture as every other Ace lane.
nonisolated enum MorningBriefPolicy {

    /// Whole-utterance grammar. Deliberately anchored: "did anything happen at
    /// the meeting" is a question for the brain, not a brief request, and a
    /// mutation verb anywhere disqualifies the whole utterance so this can
    /// never become an effect path.
    private static let requestPattern =
        #"(?i)^\s*(?:(?:hey\s+)?ace[\s,]+)?(?:please\s+)?(?:(?:can|could|would)\s+you\s+)?(?:"#
        + #"(?:give\s+me\s+(?:my\s+|the\s+)?(?:morning\s+)?(?:brief|briefing|rundown|update))"#
        + #"|(?:brief\s+me(?:\s+on\s+(?:my\s+)?(?:day|morning))?)"#
        + #"|(?:what(?:'?s|\s+is)\s+(?:my|the)\s+(?:day|morning|schedule)\s+look(?:ing)?\s+like)"#
        + #"|(?:did\s+anything\s+happen\s+(?:last\s+night|overnight|while\s+i\s+(?:was\s+)?(?:slept|was\s+asleep|were\s+asleep)))"#
        + #"|(?:(?:what|anything)\s+happened?\s+(?:last\s+night|overnight))"#
        + #"|(?:catch\s+me\s+up(?:\s+on\s+(?:my\s+)?(?:day|morning))?)"#
        + #")\s*[?.!]?\s*$"#

    private static let mutationPattern =
        #"(?i)\b(send|reply|delete|remove|schedule|create|add|book|buy|pay|post|publish|move|rename|archive|forward)\b"#

    static func isBriefRequest(_ text: String) -> Bool {
        guard text.range(
            of: mutationPattern,
            options: .regularExpression
        ) == nil else { return false }
        return text.range(
            of: requestPattern,
            options: .regularExpression
        ) != nil
    }

    /// Per-source deadline for the brief. Deliberately far tighter than the
    /// 45s inbox route: measured 2026-08-07, `email-read` hangs for minutes
    /// when Mail automation is ungranted. A spoken brief that arrives after the
    /// owner has walked away is a failure, so a slow reader is reported as
    /// unavailable rather than allowed to hold the whole brief hostage.
    static let sourceTimeoutSeconds: UInt64 = 12

    /// Time-of-day greeting. Deterministic, so the brief never opens with a
    /// cheerful "good morning" at eleven at night.
    static func greeting(
        for date: Date,
        calendar: Calendar = .current
    ) -> String {
        switch calendar.component(.hour, from: date) {
        case 4..<12: return "morning."
        case 12..<17: return "afternoon."
        case 17..<22: return "evening."
        default: return "late one."
        }
    }

    /// One readable source of the brief. `tool` is a bundled read-only wrapper
    /// name; nothing else may appear here, so the brief can never widen the
    /// approved read surface.
    struct Source: Equatable, Sendable {
        let tool: String
        let spokenLabel: String
        let unavailableLine: String
    }

    /// Ordered exactly as the brief is spoken. Every tool here is read-only and
    /// already part of the bundled wrapper contract (tools/TOOLS.md).
    static let sources: [Source] = [
        Source(
            tool: "calendar-today",
            spokenLabel: "schedule",
            unavailableLine:
                "i couldn't read your calendar, so i can't tell you what's on it."
        ),
        Source(
            tool: "email-read",
            spokenLabel: "mail",
            unavailableLine:
                "i couldn't read your mail, so nothing there is in this brief."
        ),
        Source(
            tool: "weather",
            spokenLabel: "weather",
            unavailableLine: "i couldn't get the weather."
        ),
        Source(
            tool: "system-info",
            spokenLabel: "this mac",
            unavailableLine: "i couldn't read this mac's status."
        ),
    ]

    /// The result of running one source. `output` is the wrapper's real stdout.
    struct SourceResult: Equatable, Sendable {
        let source: Source
        let succeeded: Bool
        let output: String
    }

    /// Assembles the spoken brief from REAL results only.
    ///
    /// Rules that make this trustworthy:
    /// - A failed source contributes its honest unavailable line, never silence
    ///   and never a substitute.
    /// - A source that succeeds but returns nothing says so plainly rather than
    ///   letting the listener assume it was skipped.
    /// - If every source failed, the brief says exactly that; it never returns
    ///   a cheerful empty summary.
    static func spokenBrief(
        from results: [SourceResult],
        greeting: String
    ) -> String {
        guard !results.isEmpty else {
            return "\(greeting) i don't have any sources to read for a brief."
        }
        let failures = results.filter { !$0.succeeded }
        if failures.count == results.count {
            return "\(greeting) i couldn't read any of your sources, "
                + "so i have no brief for you. "
                + failures.map(\.source.unavailableLine).joined(separator: " ")
        }

        var spokenParts: [String] = [greeting]
        for result in results {
            guard result.succeeded else {
                spokenParts.append(result.source.unavailableLine)
                continue
            }
            let condensed = condense(result.output)
            if condensed.isEmpty {
                spokenParts.append(
                    "nothing new in your \(result.source.spokenLabel)."
                )
            } else {
                spokenParts.append(
                    "\(result.source.spokenLabel): \(condensed)"
                )
            }
        }
        return spokenParts.joined(separator: " ")
    }

    /// Spoken lines must stay short enough to listen to. Each source is bounded
    /// independently so one chatty reader cannot crowd the others out.
    static let maximumSpokenCharactersPerSource = 240

    static func condense(_ output: String) -> String {
        let singleLine = output
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !singleLine.isEmpty else { return "" }
        guard singleLine.count > maximumSpokenCharactersPerSource else {
            return singleLine
        }
        return String(
            singleLine.prefix(maximumSpokenCharactersPerSource - 1)
        ) + "…"
    }
}

struct MorningLinkBriefSchedule: Codable, Equatable, Identifiable {
    let id: UUID
    var sourceURLs: [String]
    var hour: Int
    var minute: Int
    var isPaused: Bool
    var nextRunAt: Date
    var lastRunAt: Date?
    var lastResult: String?
    var deferredSpeech: String?
    var catchUpIsPending: Bool
}

nonisolated enum MorningLinkBriefValidation {
    struct ParsedConfiguration: Equatable, Sendable {
        let sourceStrings: [String]
        let hour: Int
        let minute: Int
    }

    enum Control: Equatable, Sendable {
        case listOrStatus
        case runNow
        case pause
        case resume
        case edit
        case delete
    }

    static func validatedSources(_ values: [String]) -> [URL]? {
        guard values.count == 3 else { return nil }
        let urls = values.compactMap { value -> URL? in
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard let url = URL(string: trimmed),
                  url.scheme?.lowercased() == "https",
                  url.host?.isEmpty == false,
                  url.user == nil,
                  url.password == nil else { return nil }
            return url
        }
        return urls.count == 3 ? urls : nil
    }

    static func nextDailyRun(
        hour: Int,
        minute: Int,
        after date: Date,
        calendar: Calendar = .current
    ) -> Date {
        var components = DateComponents()
        components.hour = max(0, min(23, hour))
        components.minute = max(0, min(59, minute))
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(24 * 60 * 60)
    }

    static func parsedConfiguration(
        from text: String
    ) -> ParsedConfiguration? {
        let normalized = text.replacingOccurrences(of: "’", with: "'")
        guard normalized.range(
            of: #"(?i)\bevery\s+(?:day|morning)\s+at\s+([0-9]{1,2})(?::([0-9]{2}))?\s*(a\.?m\.?|p\.?m\.?)?\b"#,
            options: .regularExpression
        ) != nil,
        normalized.range(
            of: #"(?i)\b(?:read\s+and\s+summarize|summarize|morning\s+brief(?:ing)?)\b"#,
            options: .regularExpression
        ) != nil else { return nil }

        guard let timeExpression = try? NSRegularExpression(
            pattern: #"(?i)\bevery\s+(?:day|morning)\s+at\s+([0-9]{1,2})(?::([0-9]{2}))?\s*(a\.?m\.?|p\.?m\.?)?\b"#
        ), let match = timeExpression.firstMatch(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized)
        ), let hourRange = Range(match.range(at: 1), in: normalized),
        var hour = Int(normalized[hourRange]) else { return nil }
        let minute: Int
        if match.range(at: 2).location != NSNotFound,
           let minuteRange = Range(match.range(at: 2), in: normalized),
           let parsedMinute = Int(normalized[minuteRange]) {
            minute = parsedMinute
        } else {
            minute = 0
        }
        var meridiem = ""
        if match.range(at: 3).location != NSNotFound,
           let range = Range(match.range(at: 3), in: normalized) {
            meridiem = normalized[range]
                .lowercased()
                .replacingOccurrences(of: ".", with: "")
        }
        guard (0...59).contains(minute) else { return nil }
        if meridiem == "pm", hour < 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
        guard (0...23).contains(hour) else { return nil }

        let urlExpression = try? NSRegularExpression(
            pattern: #"https://[^\s<>()\[\]{}\"']+"#,
            options: [.caseInsensitive]
        )
        let urls = urlExpression?.matches(
            in: normalized,
            range: NSRange(normalized.startIndex..., in: normalized)
        ).compactMap { match -> String? in
            guard let range = Range(match.range, in: normalized) else {
                return nil
            }
            return String(normalized[range]).trimmingCharacters(
                in: CharacterSet(charactersIn: ".,;!?"))
        } ?? []
        guard validatedSources(urls) != nil else { return nil }
        return ParsedConfiguration(
            sourceStrings: urls,
            hour: hour,
            minute: minute
        )
    }

    static func control(from text: String) -> Control? {
        let normalized = text.lowercased()
            .replacingOccurrences(
                of: #"[^a-z0-9\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.contains("brief") else { return nil }
        if normalized.range(
            of: #"^(?:show|list|status|what is|what s).*(?:brief|briefing)"#,
            options: .regularExpression
        ) != nil { return .listOrStatus }
        if normalized.range(
            of: #"^(?:run|read|start).*(?:brief|briefing).*now$"#,
            options: .regularExpression
        ) != nil { return .runNow }
        if normalized.hasPrefix("pause ") { return .pause }
        if normalized.hasPrefix("resume ") { return .resume }
        if normalized.hasPrefix("edit ") { return .edit }
        if normalized.hasPrefix("delete ")
            || normalized.hasPrefix("cancel ") {
            return .delete
        }
        return nil
    }
}

nonisolated struct MorningLinkFetchedSource: Sendable {
    let requestedURL: URL
    let finalURL: URL
    let fetchedAt: Date
    let contentType: String
    let data: Data
}

private final class MorningLinkBriefFetcher:
    NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    private static let maximumBytes = 300_000
    private static let maximumRedirects = 3
    private var requestedURL: URL?
    private var responseURL: URL?
    private var responseContentType = ""
    private var responseData = Data()
    private var redirectCount = 0
    private var completion:
        CheckedContinuation<MorningLinkFetchedSource, Error>?
    private var session: URLSession?
    private var completed = false

    func fetch(_ url: URL) async throws -> MorningLinkFetchedSource {
        requestedURL = url
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 12
                configuration.timeoutIntervalForResource = 15
                configuration.requestCachePolicy =
                    .reloadIgnoringLocalCacheData
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: nil
                )
                self.session = session
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                request.setValue(
                    "text/html,text/plain,application/json,application/xml;q=0.8",
                    forHTTPHeaderField: "Accept"
                )
                session.dataTask(with: request).resume()
            }
        } onCancel: { [weak self] in
            self?.finish(
                .failure(CancellationError())
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectCount += 1
        guard redirectCount <= Self.maximumRedirects,
              let redirectedURL = request.url,
              redirectedURL.scheme?.lowercased() == "https",
              redirectedURL.user == nil,
              redirectedURL.password == nil else {
            completionHandler(nil)
            finish(.failure(fetchError("redirect was refused")))
            return
        }
        var getRequest = request
        getRequest.httpMethod = "GET"
        getRequest.httpBody = nil
        completionHandler(getRequest)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let finalURL = http.url,
              finalURL.scheme?.lowercased() == "https" else {
            completionHandler(.cancel)
            finish(.failure(fetchError("source returned a non-success response")))
            return
        }
        let contentType = (http.value(
            forHTTPHeaderField: "Content-Type"
        ) ?? "").lowercased()
        let allowed = [
            "text/html", "text/plain", "application/json",
            "application/xml", "text/xml",
        ].contains { contentType.hasPrefix($0) }
        guard allowed else {
            completionHandler(.cancel)
            finish(.failure(fetchError("source content type is not readable text")))
            return
        }
        if response.expectedContentLength > Int64(Self.maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(fetchError("source exceeded the byte limit")))
            return
        }
        responseURL = finalURL
        responseContentType = contentType
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard responseData.count + data.count <= Self.maximumBytes else {
            dataTask.cancel()
            finish(.failure(fetchError("source exceeded the byte limit")))
            return
        }
        responseData.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        guard let requestedURL,
              let responseURL else {
            finish(.failure(fetchError("source returned no verified response")))
            return
        }
        finish(.success(MorningLinkFetchedSource(
            requestedURL: requestedURL,
            finalURL: responseURL,
            fetchedAt: Date(),
            contentType: responseContentType,
            data: responseData
        )))
    }

    private func finish(
        _ result: Result<MorningLinkFetchedSource, Error>
    ) {
        guard !completed else { return }
        completed = true
        let completion = completion
        self.completion = nil
        session?.invalidateAndCancel()
        session = nil
        completion?.resume(with: result)
    }

    private func fetchError(_ description: String) -> NSError {
        NSError(
            domain: "AceMorningLinkBrief",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class MorningLinkBriefRuntime: ObservableObject {
    @Published private(set) var schedule: MorningLinkBriefSchedule?
    @Published private(set) var isRunning = false
    @Published private(set) var lastControlError: String?

    private static let defaultsKey = "AceMorningLinkBrief.v1"
    private let speak: (String) -> Bool
    private let summarize: (String) async throws -> String
    private let fetch: (URL) async throws -> MorningLinkFetchedSource
    private let now: () -> Date
    private let calendar: Calendar
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var timeZoneObserver: NSObjectProtocol?
    private var runTask: Task<Void, Never>?
    private var activeManualCompletion: ((String, Bool) -> Void)?
    private var isSuspended = false
    private var timeZoneReconciliationIsPending = false

    init(
        speak: @escaping (String) -> Bool,
        summarize: @escaping (String) async throws -> String = {
            evidence in evidence
        },
        fetch: @escaping (URL) async throws -> MorningLinkFetchedSource = {
            url in try await MorningLinkBriefFetcher().fetch(url)
        },
        now: @escaping () -> Date = Date.init,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.speak = speak
        self.summarize = summarize
        self.fetch = fetch
        self.now = now
        self.calendar = calendar
    }

    func start() {
        schedule = Self.load()
        recoverMissedRunAfterRelaunchOrWake()
        timer?.invalidate()
        timer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer?.tolerance = 5
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter
                .addObserver(
                    forName: NSWorkspace.didWakeNotification,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.recoverMissedRunAfterRelaunchOrWake()
                        self?.tick()
                    }
                }
        }
        if timeZoneObserver == nil {
            timeZoneObserver = NotificationCenter.default.addObserver(
                forName: NSNotification.Name.NSSystemTimeZoneDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.reconcileAfterSystemTimeZoneChange()
                }
            }
        }
    }

    func configure(
        sourceStrings: [String],
        hour: Int,
        minute: Int
    ) -> Bool {
        guard let urls = MorningLinkBriefValidation
                .validatedSources(sourceStrings) else {
            lastControlError =
                "Enter exactly three complete HTTPS source URLs."
            return false
        }
        let now = now()
        schedule = MorningLinkBriefSchedule(
            id: schedule?.id ?? UUID(),
            sourceURLs: urls.map(\.absoluteString),
            hour: max(0, min(23, hour)),
            minute: max(0, min(59, minute)),
            isPaused: false,
            nextRunAt: MorningLinkBriefValidation.nextDailyRun(
                hour: hour,
                minute: minute,
                after: now,
                calendar: calendar
            ),
            lastRunAt: schedule?.lastRunAt,
            lastResult: schedule?.lastResult,
            deferredSpeech: schedule?.deferredSpeech,
            catchUpIsPending: false
        )
        lastControlError = nil
        return persist()
    }

    func setPaused(_ paused: Bool) {
        guard var current = schedule else { return }
        current.isPaused = paused
        if !paused {
            current.nextRunAt = MorningLinkBriefValidation.nextDailyRun(
                hour: current.hour,
                minute: current.minute,
                after: now(),
                calendar: calendar
            )
        }
        schedule = current
        _ = persist()
    }

    func suspend() {
        isSuspended = true
        runTask?.cancel()
        runTask = nil
        isRunning = false
        activeManualCompletion?(
            "Morning briefing stopped before completion because Stealth became active.",
            false
        )
        activeManualCompletion = nil
    }

    func resume() {
        isSuspended = false
        recoverMissedRunAfterRelaunchOrWake()
        tick()
    }

    @discardableResult
    func runNow(
        completion: ((String, Bool) -> Void)? = nil
    ) -> Bool {
        guard schedule != nil, !isRunning else { return false }
        activeManualCompletion = completion
        run(catchUp: false)
        return true
    }

    /// Evaluates one scheduler edge with an injectable completion. Production
    /// timer/wake paths call the same method; tests advance the injected clock
    /// and prove separate daily fires without waiting for wall time.
    @discardableResult
    func runDueNow(
        completion: ((String, Bool) -> Void)? = nil
    ) -> Bool {
        guard let current = schedule,
              !current.isPaused,
              !isSuspended,
              !isRunning,
              current.nextRunAt <= now() else { return false }
        activeManualCompletion = completion
        run(catchUp: current.catchUpIsPending)
        return true
    }

    @discardableResult
    func stopActiveRunKeepingSchedule() -> Bool {
        guard isRunning else { return false }
        runTask?.cancel()
        runTask = nil
        isRunning = false
        activeManualCompletion?(
            "The active briefing firing was stopped. The durable schedule remains armed.",
            false
        )
        activeManualCompletion = nil
        if var current = schedule {
            current.catchUpIsPending = false
            current.nextRunAt = MorningLinkBriefValidation.nextDailyRun(
                hour: current.hour,
                minute: current.minute,
                after: now(),
                calendar: calendar
            )
            current.lastResult =
                "Active firing stopped by the owner. The durable daily schedule remains armed for \(current.nextRunAt.formatted())."
            schedule = current
            _ = persist()
        }
        return true
    }

    func statusDescription() -> String {
        guard let schedule else {
            return "No three-link morning briefing is configured."
        }
        let sources = schedule.sourceURLs.joined(separator: "; ")
        let state = schedule.isPaused ? "paused" : "armed"
        let last = schedule.lastRunAt.map {
            " Last run \($0.formatted())."
        } ?? " It has not run yet."
        let deferred = schedule.deferredSpeech == nil
            ? "" : " Speech is retained for delivery after suppression ends."
        return "Morning briefing is \(state) for "
            + String(format: "%02d:%02d", schedule.hour, schedule.minute)
            + ". Sources: \(sources). Next run "
            + schedule.nextRunAt.formatted() + "." + last + deferred
    }

    func delete() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
        activeManualCompletion?(
            "The briefing was deleted before the active firing completed.",
            false
        )
        activeManualCompletion = nil
        schedule = nil
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    func deliverDeferredSpeechIfPossible() {
        guard var current = schedule,
              let deferred = current.deferredSpeech,
              speak(deferred) else { return }
        current.deferredSpeech = nil
        schedule = current
        _ = persist()
    }

    func tick() {
        _ = runDueNow()
    }

    func recoverMissedRunAfterRelaunchOrWake() {
        guard var current = schedule,
              !current.isPaused,
              current.nextRunAt < now() else { return }
        // A closed or sleeping Mac cannot execute. Preserve exactly one catch-
        // up run after wake/relaunch instead of skipping or replaying a backlog.
        current.nextRunAt = now().addingTimeInterval(5)
        current.catchUpIsPending = true
        schedule = current
        _ = persist()
    }

    /// The schedule is a local wall-clock promise. A student who travels or
    /// changes the Mac's time zone should still get one 8 AM run in the new
    /// local day, never a duplicate or an old-zone fire.
    func reconcileAfterSystemTimeZoneChange() {
        guard var current = schedule, !current.isPaused else { return }
        if isRunning {
            timeZoneReconciliationIsPending = true
            return
        }
        let currentDate = now()
        if current.catchUpIsPending {
            current.nextRunAt = currentDate.addingTimeInterval(5)
            schedule = current
            _ = persist()
            return
        }
        if let lastRunAt = current.lastRunAt,
           calendar.isDate(lastRunAt, inSameDayAs: currentDate) {
            current.nextRunAt = MorningLinkBriefValidation.nextDailyRun(
                hour: current.hour,
                minute: current.minute,
                after: currentDate,
                calendar: calendar
            )
            current.catchUpIsPending = false
        } else {
            let localScheduledTime = calendar.date(
                bySettingHour: current.hour,
                minute: current.minute,
                second: 0,
                of: currentDate
            )
            if let localScheduledTime,
               localScheduledTime <= currentDate {
                current.nextRunAt = currentDate.addingTimeInterval(5)
                current.catchUpIsPending = true
            } else {
                current.nextRunAt = localScheduledTime
                    ?? MorningLinkBriefValidation.nextDailyRun(
                        hour: current.hour,
                        minute: current.minute,
                        after: currentDate,
                        calendar: calendar
                    )
                current.catchUpIsPending = false
            }
        }
        schedule = current
        _ = persist()
    }

    private func run(catchUp: Bool) {
        guard let admitted = schedule,
              !isSuspended,
              let urls = MorningLinkBriefValidation
                .validatedSources(admitted.sourceURLs) else { return }
        isRunning = true
        runTask = Task { [weak self] in
            guard let self else { return }
            var results: [(URL, Result<MorningLinkFetchedSource, Error>)] = []
            for url in urls {
                if Task.isCancelled { return }
                do {
                    let fetched = try await self.fetch(url)
                    results.append((url, .success(fetched)))
                } catch {
                    results.append((url, .failure(error)))
                }
            }
            guard !Task.isCancelled else { return }
            let failures = results.compactMap { item -> String? in
                guard case let .failure(error) = item.1 else { return nil }
                return "\(item.0.host ?? item.0.absoluteString) failed: \(error.localizedDescription)"
            }
            var receiptParts: [String] = [
                catchUp
                    ? "This is the one briefing catch-up after your Mac woke or Ace reopened."
                    : "Your scheduled three-source morning briefing is ready."
            ]
            var evidenceParts: [String] = []
            for (url, result) in results {
                switch result {
                case .success(let fetched):
                    let source = String(
                        data: fetched.data,
                        encoding: .utf8
                    ) ?? ""
                    let value = Self.condenseWeb(source)
                    let timestamp = ISO8601DateFormatter().string(
                        from: fetched.fetchedAt
                    )
                    receiptParts.append(
                        "Source \(url.absoluteString) fetched \(timestamp) as \(fetched.contentType); final URL \(fetched.finalURL.absoluteString)."
                    )
                    evidenceParts.append(
                        "SOURCE: \(url.absoluteString)\nFETCHED: \(timestamp)\nTEXT: \(value.isEmpty ? "no readable text" : value)"
                    )
                case .failure:
                    break
                }
            }
            var summary = ""
            if !evidenceParts.isEmpty {
                do {
                    summary = try await self.summarize(
                        "Summarize only the supplied source evidence for a short spoken morning briefing. Do not add facts. Preserve named source failures outside this summary.\n\n"
                            + evidenceParts.joined(separator: "\n\n")
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    receiptParts.append(
                        "The no-tools summarizer failed: \(error.localizedDescription)."
                    )
                    summary = evidenceParts.joined(separator: " ")
                }
            }
            if !summary.isEmpty {
                receiptParts.append("Summary: \(summary)")
            }
            if !failures.isEmpty {
                receiptParts.append(
                    "This briefing is incomplete. "
                        + failures.joined(separator: "; ")
                )
            }
            if evidenceParts.isEmpty {
                receiptParts.append(
                    "This briefing is incomplete. No source produced readable evidence."
                )
            }
            let spoken = receiptParts.joined(separator: " ")
            var completed = admitted
            completed.lastRunAt = self.now()
            completed.lastResult = spoken
            completed.catchUpIsPending = false
            completed.nextRunAt = MorningLinkBriefValidation.nextDailyRun(
                hour: completed.hour,
                minute: completed.minute,
                after: self.now(),
                calendar: self.calendar
            )
            completed.deferredSpeech = self.speak(spoken) ? nil : spoken
            self.schedule = completed
            self.isRunning = false
            self.runTask = nil
            _ = self.persist()
            if self.timeZoneReconciliationIsPending {
                self.timeZoneReconciliationIsPending = false
                self.reconcileAfterSystemTimeZoneChange()
            }
            self.activeManualCompletion?(
                spoken,
                failures.isEmpty && !evidenceParts.isEmpty
            )
            self.activeManualCompletion = nil
        }
    }

    private func persist() -> Bool {
        guard let schedule,
              let data = try? JSONEncoder().encode(schedule) else {
            return false
        }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        return true
    }

    private static func load() -> MorningLinkBriefSchedule? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey)
        else { return nil }
        return try? JSONDecoder().decode(
            MorningLinkBriefSchedule.self,
            from: data
        )
    }

    private static func condenseWeb(_ source: String) -> String {
        let withoutScripts = source.replacingOccurrences(
            of: #"(?is)<(script|style).*?>.*?</\1>"#,
            with: " ",
            options: .regularExpression
        )
        let withoutTags = withoutScripts.replacingOccurrences(
            of: #"(?s)<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        let plain = withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(plain.prefix(600))
    }
}
#endif // circuit-convert
