//
//  WorkflowPlan.swift
//  Ace
//
//  THE BUILD LANE'S PLAN — founder ruling 2026-08-01: "he workflows entire
//  systems together … if they want a full dashboard built it should be do this."
//
//  Every other effect path in this app is one wrapper, one readback, one
//  `confirm`, one spawn. That shape is correct for "send this email" and
//  useless for "build me a dashboard": a real build is hundreds of effects and
//  nobody confirms three hundred times. So the gate moves from PER EFFECT to
//  PER JOB. This file is the per-job object: the complete, immutable, readable
//  description of what Ace is about to go do, decoded fail-closed from the
//  planner before any authority exists anywhere.
//
//  The decoder is deliberately paranoid in the same way `AppActionPlanner` is,
//  because the thing it gates is far larger:
//    • the workspace is ONE sanitized path component under ~/Ace Projects —
//      never absolute, never traversing, never a symlink, never an existing
//      non-directory. The job's deliverable lands there and the readback names
//      that exact directory.
//    • systems are an allowlist mapped onto the bundled wrappers that already
//      exist. The planner cannot invent a data source.
//    • external sources are explicit, absolute https URLs, listed separately
//      and read back separately, because each one is a new egress path.
//    • steps are bounded and value-only. A plan that is missing, malformed,
//      over-long, or ambiguous produces a clarification and NO job.
//
//  Nothing here executes. This file has no process, no filesystem mutation, and
//  no authority — it is pure, which is what makes it testable offline.
//

import Foundation

// MARK: - Systems

/// The buyer's own systems a workflow may wire into its deliverable. Each case
/// maps onto a bundled wrapper that already ships and is already tested; the
/// build lane never invents a data source, and a planner naming anything
/// outside this list fails the whole plan.
///
/// Founder ruling 2026-08-01 chose live local data AND external sources AND a
/// shell-only mode. Local systems are this enum; external sources ride the
/// separate `externalSources` list precisely so the readback can say them out
/// loud one at a time; a shell-only build is simply a plan with neither.
enum WorkflowSystem: String, CaseIterable, Codable, Sendable {
    case inbox
    case calendar
    case contacts
    case files
    case music
    case weather
    case systemVitals = "system-vitals"
    case screen
    case clipboard
    case apps
    case web
    case webSearch = "web-search"

    /// The bundled wrapper this system reads through. The runtime hands these
    /// names to the build prompt as the ONLY sanctioned way to reach the
    /// owner's data, so a generated dashboard shells out to a tested,
    /// read-only tool instead of improvising AppleScript.
    ///
    /// 🚨 Every entry here must be a READ. `reminders` and `notes` are
    /// deliberately absent: the shipped library has `reminder-add` and
    /// `note-create` and no reader for either, and the first cut of this file
    /// mapped those two write tools as "reads" — a dashboard asking to show
    /// your reminders would have started creating them. They exist only as
    /// declared effects now.
    var bundledReadTool: String {
        switch self {
        case .inbox:         return "email-read"
        case .calendar:      return "calendar-today"
        case .contacts:      return "contact-find"
        case .files:         return "find-file"
        case .music:         return "music-control"
        case .weather:       return "weather"
        case .systemVitals:  return "system-info"
        case .screen:        return "screenshot-take"
        case .clipboard:     return "clipboard"
        case .apps:          return "app-list"
        case .web:           return "web-fetch"
        case .webSearch:     return "web-search"
        }
    }

    /// The exact invocation shape, so the build prompt never has to guess at a
    /// wrapper's contract and a generated script does not call it wrongly.
    var invocation: String {
        switch self {
        case .inbox:         return "email-read [count] [unread]"
        case .calendar:      return "calendar-today"
        case .contacts:      return "contact-find <exact-full-name>"
        case .files:         return "find-file <query...>"
        case .music:         return "music-control current"
        case .weather:       return "weather [location...]"
        case .systemVitals:  return "system-info"
        case .screen:        return "screenshot-take [path.png]"
        case .clipboard:     return "clipboard get"
        case .apps:          return "app-list"
        case .web:           return "web-fetch <url>"
        case .webSearch:     return "web-search <query...>"
        }
    }

    /// How the whole-job readback names this system out loud. The owner is
    /// approving access to their own data, so the words have to be the words
    /// they would use, not the tool name.
    var spokenName: String {
        switch self {
        case .inbox:         return "your inbox"
        case .calendar:      return "your calendar"
        case .contacts:      return "your contacts"
        case .files:         return "your files"
        case .music:         return "your music"
        case .weather:       return "the weather"
        case .systemVitals:  return "this Mac's battery, disk and network"
        case .screen:        return "your screen"
        case .clipboard:     return "your clipboard"
        case .apps:          return "which apps are open"
        case .web:           return "the web pages you named"
        case .webSearch:     return "web search"
        }
    }

    /// Systems whose contents are personal enough that the readback names them
    /// before the owner arms the job, even when the job is otherwise dull.
    var isPersonalData: Bool {
        switch self {
        case .weather, .systemVitals, .music, .web, .webSearch, .apps:
            return false
        case .inbox, .calendar, .contacts, .files, .screen, .clipboard:
            return true
        }
    }
}

// MARK: - Effects

/// Things a build may CHANGE about the Mac, as opposed to read.
///
/// Split from `WorkflowSystem` on purpose. A dashboard that reads your calendar
/// and a dashboard that writes to it are different grants, and the second one
/// is named individually in the readback so "build me a planner" can never
/// quietly acquire the ability to create events.
enum WorkflowEffect: String, CaseIterable, Codable, Sendable {
    case createCalendarEvent = "create-calendar-event"
    case createReminder = "create-reminder"
    case createNote = "create-note"
    case draftEmail = "draft-email"
    case setClipboard = "set-clipboard"
    case postNotification = "post-notification"
    case setTimer = "set-timer"
    case setVolume = "set-volume"
    case controlMusic = "control-music"
    case setAppearance = "set-appearance"
    case setWallpaper = "set-wallpaper"
    case moveWindow = "move-window"
    case setWiFiPower = "set-wifi-power"

    var bundledTool: String {
        switch self {
        case .createCalendarEvent: return "calendar-add"
        case .createReminder:      return "reminder-add"
        case .createNote:          return "note-create"
        case .draftEmail:          return "email-draft"
        case .setClipboard:        return "clipboard"
        case .postNotification:    return "notify"
        case .setTimer:            return "timer-set"
        case .setVolume:           return "volume-set"
        case .controlMusic:        return "music-control"
        case .setAppearance:       return "dark-mode"
        case .setWallpaper:        return "wallpaper-set"
        case .moveWindow:          return "window-move"
        case .setWiFiPower:        return "wifi-power"
        }
    }

    var invocation: String {
        switch self {
        case .createCalendarEvent:
            return "calendar-add <name:CALENDAR|id:ID> <title> <YYYY-MM-DD HH:MM> <minutes>"
        case .createReminder:
            return "reminder-add <name:ACCOUNT|id:ID> <name:LIST|id:ID> <text> [YYYY-MM-DD HH:MM]"
        case .createNote:       return "note-create <exact-account> <exact-folder> <title> <body>"
        case .draftEmail:       return "email-draft [--from <sender>] <to> <subject> <body...>"
        case .setClipboard:     return "clipboard set <text...>"
        case .postNotification: return "notify <message...>"
        case .setTimer:         return "timer-set set <operation-id> <90s|10m|1h> [label...]"
        case .setVolume:        return "volume-set <0-100>|mute|unmute"
        case .controlMusic:     return "music-control play|pause|next|previous"
        case .setAppearance:    return "dark-mode dark|light|toggle"
        case .setWallpaper:     return "wallpaper-set dark|<absolute-image-path>"
        case .moveWindow:       return "window-move (native-only; not callable from a build)"
        case .setWiFiPower:     return "wifi-power on|off"
        }
    }

    /// Named individually in the readback, in the owner's words.
    var spokenName: String {
        switch self {
        case .createCalendarEvent: return "put events on your calendar"
        case .createReminder:      return "create reminders"
        case .createNote:          return "create notes"
        case .draftEmail:          return "open email drafts for you to send"
        case .setClipboard:        return "change your clipboard"
        case .postNotification:    return "post notifications"
        case .setTimer:            return "set timers"
        case .setVolume:           return "change your volume"
        case .controlMusic:        return "control your music"
        case .setAppearance:       return "switch dark and light mode"
        case .setWallpaper:        return "change your wallpaper"
        case .moveWindow:          return "move windows"
        case .setWiFiPower:        return "turn Wi-Fi on and off"
        }
    }

    /// `window-move` is native-only by contract: Ace binds the app name, PID,
    /// and exact window ID itself and the signed executor revalidates all three. A build
    /// script cannot satisfy that, so it is declarable but never handed over.
    var isCallableFromABuild: Bool { self != .moveWindow }
}

// MARK: - Forbidden tools

/// Wrappers the build lane may never invoke, whatever the owner approved.
/// Enumerated as a type rather than left as prose so the prohibition is
/// testable and a newly added wrapper cannot drift into the lane silently.
enum WorkflowForbiddenTool: String, CaseIterable, Sendable {
    case emailSend = "email-send"
    case shortcutRun = "shortcut-run"
    case trashFile = "trash-file"
    case blackLabelStatus = "bl-status"

    var reason: String {
        switch self {
        case .emailSend:
            return "user-addressed mail is never sent without the owner "
                + "pressing Send; builds use email-draft"
        case .shortcutRun:
            return "a Shortcut's nested send/pay/delete effects cannot be "
                + "previewed or verified"
        case .trashFile:
            return "destructive; a build never deletes the owner's files"
        case .blackLabelStatus:
            return "developer-machine only and not part of any buyer build"
        }
    }
}

// MARK: - Steps

/// One announced unit of a build. Steps exist for the owner's benefit, not the
/// model's: they are what Ace says out loud as it works and what lands in the
/// ledger, so an unattended-looking build is never actually opaque.
struct WorkflowStep: Equatable, Codable, Sendable {
    /// Short imperative title, spoken as the step begins ("wire up the inbox").
    let title: String
    /// The concrete work, handed to the build lane verbatim.
    let detail: String
}

// MARK: - Plan

/// A complete, immutable job. Once decoded this value never changes: the
/// runtime revalidates the SAME plan immediately before it spawns anything, so
/// a plan cannot be swapped between readback and execution.
struct WorkflowPlan: Equatable, Codable, Sendable {
    /// What the owner asked for, in their own framing.
    let goal: String
    /// Single sanitized path component under ~/Ace Projects.
    let workspaceName: String
    /// The owner's systems this build reads. May be empty (a shell-only build).
    let systems: [WorkflowSystem]
    /// Things this build may CHANGE. Empty for a read-only build. Each one is
    /// named individually in the readback — reading your calendar and writing
    /// to it are different grants.
    let effects: [WorkflowEffect]
    /// Absolute https sources. May be empty. Each is read back individually.
    let externalSources: [URL]
    /// Bounded, ordered work.
    let steps: [WorkflowStep]
    /// The one file the owner opens when it is done, relative to the workspace.
    let deliverable: String

    // MARK: Bounds

    static let maximumSteps = 12
    static let maximumExternalSources = 6
    static let maximumEffects = 6
    static let maximumWorkspaceNameLength = 48
    static let maximumGoalLength = 400
    static let maximumStepTitleLength = 80
    static let maximumStepDetailLength = 600
    static let maximumDeliverableLength = 120

    /// The one directory a workflow is created in. The deliverable resolves
    /// under this; the readback names it; the ledger records it.
    static func projectsRoot(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        home.appendingPathComponent("Ace Projects", isDirectory: true)
    }

    /// The absolute workspace directory for this plan. Pure — it does not
    /// create, test, or touch the filesystem.
    func workspaceURL(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        Self.projectsRoot(home: home)
            .appendingPathComponent(workspaceName, isDirectory: true)
    }

    /// The absolute deliverable path. Pure.
    func deliverableURL(
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> URL {
        workspaceURL(home: home).appendingPathComponent(deliverable)
    }
}

// MARK: - Decoder outcome

enum WorkflowPlanDecoding: Equatable {
    /// A complete, bounded, sanitized job.
    case plan(WorkflowPlan)
    /// The planner could not produce a job. The string is what Ace says; it
    /// names the missing detail and never guesses one.
    case clarification(String)
}

// MARK: - Planner

/// Fail-closed decoder for the one value-only JSON object the isolated planner
/// may return. Mirrors `AppActionPlanner`: the model's output is untrusted
/// text, every field is validated here, and anything short of a complete plan
/// becomes a clarification rather than a smaller job.
enum WorkflowPlanner {

    /// The planner's contract. Handed to a zero-tool model process that
    /// receives no paths, no approval, no credentials, and no history.
    static let plannerContract = """
        Decompose the owner's build request into ONE JSON object and nothing \
        else. No prose, no markdown fence, no explanation.

        {
          "goal": "<one sentence, the owner's own framing>",
          "workspace": "<2-48 chars, letters/digits/spaces/hyphens only>",
          "systems": [<zero or more READ sources: inbox, calendar, contacts, \
        files, music, weather, system-vitals, screen, clipboard, apps, web, \
        web-search>],
          "effects": [<zero or more CHANGES: create-calendar-event, \
        create-reminder, create-note, draft-email, set-clipboard, \
        post-notification, set-timer, set-volume, control-music, \
        set-appearance, set-wallpaper, set-wifi-power>],
          "external": [<zero or more absolute https:// URLs the owner named>],
          "steps": [{"title": "<imperative, <=80 chars>", \
        "detail": "<what to build, <=600 chars>"}],
          "deliverable": "<one relative filename the owner opens, e.g. index.html>"
        }

        Rules. Use at most 12 steps and at most 6 effects. Never invent a \
        system or an effect the owner did not ask for; empty lists are correct \
        and common — a dashboard that only DISPLAYS things has no effects. \
        Reading a system never implies the matching effect: showing the \
        calendar is "systems": ["calendar"], not "effects". There is no reader \
        for reminders or notes, so those appear only as effects. Never invent \
        an external URL. Never put a path, "..", "~", or a leading slash in \
        workspace or deliverable. If the request is too vague to name a \
        deliverable, return {"clarification": "<the one missing detail>"} \
        instead.
        """

    /// Decode one planner response. `rawOutput` is untrusted model text.
    static func decode(
        _ rawOutput: String,
        ownerRequest: String? = nil
    ) -> WorkflowPlanDecoding {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .clarification(
                "i didn't get a plan back, so i didn't start anything.")
        }
        guard let objectText = firstJSONObject(in: trimmed),
              let objectData = objectText.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: objectData))
                as? [String: Any]
        else {
            return .clarification(
                "i couldn't read that back as a plan, so i didn't build anything.")
        }

        // An explicit clarification always wins — a planner that admits it is
        // missing something must never be salvaged into a partial job.
        if let clarification = root["clarification"] as? String {
            let cleaned = collapseWhitespace(clarification)
            guard !cleaned.isEmpty else {
                return .clarification("i need one more detail before i build that.")
            }
            return .clarification(cleaned)
        }

        guard let plannedGoal = boundedString(
            root["goal"], limit: WorkflowPlan.maximumGoalLength)
        else {
            return .clarification("tell me what you want built and i'll plan it.")
        }
        let normalizedRequest = ownerRequest.map(normalizedOwnerRequest)
        let goal = normalizedRequest.flatMap {
            boundedString($0, limit: WorkflowPlan.maximumGoalLength)
        } ?? plannedGoal

        guard let plannedWorkspaceName = sanitizedWorkspaceName(root["workspace"]) else {
            return .clarification(
                "i need a short name for the project folder before i start.")
        }
        let workspaceName = normalizedRequest.flatMap {
            explicitWorkspaceName(in: $0)
        } ?? plannedWorkspaceName

        guard let deliverable = sanitizedDeliverable(root["deliverable"]) else {
            return .clarification(
                "i need to know which single file you'll open when it's done.")
        }

        switch decodeSystems(root["systems"]) {
        case let .failure(message):
            return .clarification(message)
        case let .success(decodedSystems):
            let systems = mergedExplicitSystems(
                decodedSystems,
                ownerRequest: normalizedRequest
            )
            switch decodeEffects(root["effects"]) {
            case let .failure(message):
                return .clarification(message)
            case let .success(effects):
                switch decodeExternalSources(root["external"]) {
                case let .failure(message):
                    return .clarification(message)
                case let .success(externalSources):
                    switch decodeSteps(root["steps"]) {
                    case let .failure(message):
                        return .clarification(message)
                    case let .success(steps):
                        return .plan(
                            WorkflowPlan(
                                goal: goal,
                                workspaceName: workspaceName,
                                systems: systems,
                                effects: effects,
                                externalSources: externalSources,
                                steps: steps,
                                deliverable: deliverable
                            )
                        )
                    }
                }
            }
        }
    }

    private static func normalizedOwnerRequest(_ rawRequest: String) -> String {
        collapseWhitespace(rawRequest).replacingOccurrences(
            of: #"(?i)\b(system information|system info|system vitals)\s+and\s+whether\b"#,
            with: "$1 and weather",
            options: .regularExpression
        )
    }

    private static func explicitWorkspaceName(in request: String) -> String? {
        guard let named = request.range(
            of: #"(?i)\bnamed\s+"#,
            options: .regularExpression
        ) else { return nil }
        let remainder = request[named.upperBound...]
        let end = remainder.range(
            of: #"[.,;]|\s+(show|with|that|which|using|use|include|including|require|requiring|display|containing|featuring)\b"#,
            options: .regularExpression
        )?.lowerBound ?? remainder.endIndex
        return sanitizedWorkspaceName(String(remainder[..<end]))
    }

    private static func mergedExplicitSystems(
        _ decoded: [WorkflowSystem],
        ownerRequest: String?
    ) -> [WorkflowSystem] {
        guard let ownerRequest else { return decoded }
        let request = collapseWhitespace(ownerRequest).lowercased()
        var systems = decoded

        let excludesWeather = request.range(
            of: #"\b(no|without|exclude|omit|don't|do not)\s+(the\s+)?weather\b"#,
            options: .regularExpression
        ) != nil
        if !excludesWeather,
           request.range(of: #"\bweather\b"#, options: .regularExpression) != nil,
           !systems.contains(.weather) {
            systems.append(.weather)
        }

        let excludesVitals = request.range(
            of: #"\b(no|without|exclude|omit|don't|do not)\s+(live\s+)?(system (information|info|vitals)|battery|disk|network)\b"#,
            options: .regularExpression
        ) != nil
        if !excludesVitals,
           request.range(
            of: #"\b(system information|system info|system vitals|battery|disk)\b"#,
            options: .regularExpression
           ) != nil,
           !systems.contains(.systemVitals) {
            systems.append(.systemVitals)
        }
        return systems
    }

    // MARK: Field decoding

    private enum FieldResult<Value> {
        case success(Value)
        case failure(String)
    }

    private static func decodeSystems(
        _ raw: Any?
    ) -> FieldResult<[WorkflowSystem]> {
        guard let raw, !(raw is NSNull) else { return .success([]) }
        guard let names = raw as? [Any] else {
            return .failure("i couldn't tell which of your systems that should use.")
        }
        var systems: [WorkflowSystem] = []
        for entry in names {
            guard let name = entry as? String,
                  let system = WorkflowSystem(
                    rawValue: name.trimmingCharacters(in: .whitespaces).lowercased())
            else {
                return .failure(
                    "part of that plan wanted a data source i don't have a "
                        + "tested way to read, so i didn't start it.")
            }
            if !systems.contains(system) { systems.append(system) }
        }
        return .success(systems)
    }

    /// Effects are refused whole on any unknown name. A plan that asked for
    /// one thing Ace cannot do must not quietly run as the subset it can —
    /// the owner would be approving a readback that no longer matches the job.
    private static func decodeEffects(
        _ raw: Any?
    ) -> FieldResult<[WorkflowEffect]> {
        guard let raw, !(raw is NSNull) else { return .success([]) }
        guard let names = raw as? [Any] else {
            return .failure("i couldn't tell what that build wanted to change.")
        }
        guard names.count <= WorkflowPlan.maximumEffects else {
            return .failure(
                "that plan wants to change more things than i'll take in one "
                    + "job. cut it to \(WorkflowPlan.maximumEffects) changes or "
                    + "fewer and it runs.")
        }
        var effects: [WorkflowEffect] = []
        for entry in names {
            guard let name = entry as? String else {
                return .failure("i couldn't read what that build wanted to change.")
            }
            let normalized = name.trimmingCharacters(in: .whitespaces).lowercased()

            // A forbidden wrapper named as an effect is refused by name, so the
            // owner hears WHY rather than a generic "unsupported".
            if let forbidden = WorkflowForbiddenTool(rawValue: normalized) {
                return .failure(
                    "that build wanted to use \(forbidden.rawValue), which i "
                        + "don't do from a build — \(forbidden.reason). i "
                        + "didn't start it.")
            }
            guard let effect = WorkflowEffect(rawValue: normalized) else {
                return .failure(
                    "that build wanted to change something i don't have a "
                        + "tested way to change, so i didn't start it.")
            }
            if !effects.contains(effect) { effects.append(effect) }
        }
        return .success(effects)
    }

    private static func decodeExternalSources(
        _ raw: Any?
    ) -> FieldResult<[URL]> {
        guard let raw, !(raw is NSNull) else { return .success([]) }
        guard let entries = raw as? [Any] else {
            return .failure("i couldn't read the outside sources for that build.")
        }
        guard entries.count <= WorkflowPlan.maximumExternalSources else {
            return .failure(
                "that plan reaches out to more outside sources than i'll take "
                    + "in one job. cut it to "
                    + "\(WorkflowPlan.maximumExternalSources) sources or fewer "
                    + "and it runs.")
        }
        var sources: [URL] = []
        for entry in entries {
            guard let text = entry as? String,
                  let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
                  url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty
            else {
                return .failure(
                    "one of those outside sources wasn't a plain https address, "
                        + "so i didn't start the build.")
            }
            if !sources.contains(url) { sources.append(url) }
        }
        return .success(sources)
    }

    private static func decodeSteps(_ raw: Any?) -> FieldResult<[WorkflowStep]> {
        guard let entries = raw as? [Any], !entries.isEmpty else {
            return .failure("i couldn't break that into steps, so i didn't start.")
        }
        guard entries.count <= WorkflowPlan.maximumSteps else {
            return .failure(
                "that's a bigger job than i'll take in one pass. split it and "
                    + "i'll build the first part.")
        }
        var steps: [WorkflowStep] = []
        for entry in entries {
            guard let object = entry as? [String: Any],
                  let title = boundedString(
                    object["title"], limit: WorkflowPlan.maximumStepTitleLength),
                  let detail = boundedString(
                    object["detail"], limit: WorkflowPlan.maximumStepDetailLength)
            else {
                return .failure("one of those steps came back empty, so i stopped.")
            }
            steps.append(WorkflowStep(title: title, detail: detail))
        }
        return .success(steps)
    }

    // MARK: Sanitizers

    /// ONE path component. Rejects traversal, separators, tilde, hidden names,
    /// extensions, and anything the filesystem would read as a route rather
    /// than a name. The result is the exact folder the readback names.
    static func sanitizedWorkspaceName(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let collapsed = collapseWhitespace(text)
        guard !collapsed.isEmpty,
              collapsed.count >= 2,
              collapsed.count <= WorkflowPlan.maximumWorkspaceNameLength
        else { return nil }
        guard collapsed != ".", collapsed != "..",
              !collapsed.hasPrefix("."),
              !collapsed.contains("/"),
              !collapsed.contains("\\"),
              !collapsed.contains(":"),
              !collapsed.contains("~"),
              !collapsed.contains("..")
        else { return nil }
        let permitted = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_"))
        guard collapsed.unicodeScalars.allSatisfy({ permitted.contains($0) })
        else { return nil }
        // A name that normalizes to a different component is not a name.
        guard (collapsed as NSString).lastPathComponent == collapsed
        else { return nil }
        return collapsed
    }

    /// A relative filename, optionally one directory deep. Same refusals as the
    /// workspace name plus an explicit absolute-path rejection, so the
    /// deliverable can never resolve outside its own workspace.
    static func sanitizedDeliverable(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let collapsed = collapseWhitespace(text)
        guard !collapsed.isEmpty,
              collapsed.count <= WorkflowPlan.maximumDeliverableLength
        else { return nil }
        guard !collapsed.hasPrefix("/"),
              !collapsed.hasPrefix("~"),
              !collapsed.hasPrefix("."),
              !collapsed.contains(".."),
              !collapsed.contains("\\"),
              !collapsed.contains(":")
        else { return nil }
        let components = collapsed.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 2 else { return nil }
        let permitted = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: " -_."))
        for component in components {
            guard !component.isEmpty,
                  component != ".", component != "..",
                  !component.hasPrefix("."),
                  String(component).unicodeScalars.allSatisfy({ permitted.contains($0) })
            else { return nil }
        }
        // The last component must actually be a file.
        guard let last = components.last,
              last.contains("."),
              !last.hasSuffix(".")
        else { return nil }
        return collapsed
    }

    private static func boundedString(_ raw: Any?, limit: Int) -> String? {
        guard let text = raw as? String else { return nil }
        let collapsed = collapseWhitespace(text)
        guard !collapsed.isEmpty, collapsed.count <= limit else { return nil }
        return collapsed
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Extract the first balanced top-level JSON object, ignoring braces inside
    /// strings. A model that wraps its object in prose or a fence still decodes;
    /// a model that returns no object at all does not.
    static func firstJSONObject(in text: String) -> String? {
        var depth = 0
        var startIndex: String.Index?
        var isInsideString = false
        var isEscaped = false
        for index in text.indices {
            let character = text[index]
            if isEscaped { isEscaped = false; continue }
            if character == "\\" { if isInsideString { isEscaped = true }; continue }
            if character == "\"" { isInsideString.toggle(); continue }
            guard !isInsideString else { continue }
            if character == "{" {
                if depth == 0 { startIndex = index }
                depth += 1
            } else if character == "}" {
                guard depth > 0 else { return nil }
                depth -= 1
                if depth == 0, let startIndex {
                    return String(text[startIndex...index])
                }
            }
        }
        return nil
    }
}

// MARK: - Readback

extension WorkflowPlan {

    /// The complete, untruncated whole-job readback. This is the ONE thing the
    /// owner hears before the build lane gets authority, so it names the goal,
    /// the exact folder, every personal system it will read, every outside
    /// address it will reach, the step count, and the file they will open.
    /// Nothing here is elided — a truncated readback would be an unreviewed
    /// grant.
    var spokenReadback: String {
        var sentences: [String] = []
        sentences.append("here's the job. \(goal).")
        sentences.append(
            "i'll build it in a new folder called \(workspaceName), "
                + "inside Ace Projects in your home folder.")

        if systems.isEmpty {
            sentences.append("it doesn't read any of your data.")
        } else {
            let names = systems.map(\.spokenName)
            sentences.append("it reads \(Self.spokenList(names)).")
        }

        // Effects are the sharp end and get their own sentence, named one by
        // one. "it reads your calendar" and "it can put events on your
        // calendar" must never collapse into the same phrase.
        if effects.isEmpty {
            sentences.append("it doesn't change anything on this Mac outside its own folder.")
        } else {
            sentences.append(
                "it can also \(Self.spokenList(effects.map(\.spokenName))).")
        }

        if !externalSources.isEmpty {
            let hosts = externalSources.compactMap(\.host)
            sentences.append(
                "it also goes out to \(Self.spokenList(hosts)).")
        }

        sentences.append(
            steps.count == 1
                ? "one step." : "\(steps.count) steps.")
        sentences.append("when it's done you'll open \(deliverable).")
        sentences.append(
            "while it runs i can create, change and delete files on this Mac.")
        // The owner is granting full machine authority; they are entitled to
        // hear what it still cannot reach.
        sentences.append(WorkflowBoundary.spokenBoundaries)
        sentences.append(
            "say confirm to start it, or stop at any point to kill it.")
        return sentences.joined(separator: " ")
    }

    /// The same facts as one written block for the ledger and the review card.
    /// Byte-identical field values to the spoken readback — the card and the
    /// voice must never disagree about what was approved.
    var writtenReadback: String {
        var lines: [String] = []
        lines.append("GOAL: \(goal)")
        lines.append("WORKSPACE: \(workspaceURL().path)")
        lines.append(
            "SYSTEMS: "
                + (systems.isEmpty
                    ? "none"
                    : systems.map(\.rawValue).joined(separator: ", ")))
        lines.append(
            "EFFECTS: "
                + (effects.isEmpty
                    ? "none"
                    : effects.map(\.rawValue).joined(separator: ", ")))
        lines.append(
            "EXTERNAL: "
                + (externalSources.isEmpty
                    ? "none"
                    : externalSources.map(\.absoluteString).joined(separator: ", ")))
        lines.append("DELIVERABLE: \(deliverableURL().path)")
        lines.append("AUTHORITY: full machine authority for the duration of this job")
        lines.append(WorkflowBoundary.writtenBoundaries)
        for (index, step) in steps.enumerated() {
            lines.append("STEP \(index + 1)/\(steps.count): \(step.title) — \(step.detail)")
        }
        return lines.joined(separator: "\n")
    }

    static func spokenList(_ items: [String]) -> String {
        switch items.count {
        case 0:  return "nothing"
        case 1:  return items[0]
        case 2:  return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ")
            + " and \(items[items.count - 1])"
        }
    }
}

// MARK: - Request grammar

/// Deterministic, positive whole-request grammar for the build lane. Same
/// discipline as `CrossAppActionPolicy`: keyword-anywhere matching turned
/// questions and negations into executions, so every entry point here is
/// anchored at the start of the utterance.
enum WorkflowRequestPolicy {

    /// Questions, negations, and hypotheticals are conversation, never jobs.
    private static let disqualifyingOpenerPattern =
        #"(?i)^\s*(?:don'?t|do\s+not|never|how\s+(?:do|would|can|should|hard)|what\s+(?:if|would|happens)|why|when|where|who|which|did\s+you|have\s+you|are\s+you|could\s+you\s+have|should\s+i|is\s+it)\b"#

    /// "build me a dashboard", "put together a tracker that …", "make me a
    /// site that pulls my calendar". The verb has to lead, and it has to be a
    /// CREATE verb — "check my email" is not a build.
    private static let buildOpenerPattern =
        #"(?i)^\s*(?:(?:hey\s+)?ace[\s,]+)?(?:please[\s,]+)?(?:(?:i\s+(?:want|need)\s+you\s+to|(?:can|could|would|will)\s+you(?:\s+please)?|go\s+ahead\s+and)\s+)?(?:please\s+)?(?:build|make|create|put\s+together|set\s+up|generate|design|code|write)\b"#

    /// The object has to be a whole deliverable, not a note or an email — those
    /// already have exact, tested, single-effect routes and must keep them.
    private static let deliverableNounPattern =
        #"(?i)\b(dashboard|tracker|app|site|website|web\s*page|webpage|page|tool|report|planner|board|panel|visuali[sz]ation|chart|graph|spreadsheet|script|widget|portal|hub|overview|summary\s+page|landing\s+page|project)\b"#

    /// Routes that own their own exact single-effect path. A build request that
    /// is really one of these is NOT a build — it goes to the tested wrapper.
    private static let singleEffectNounPattern =
        #"(?i)\b(note|email|e-?mail|draft|reminder|event|meeting|timer|screenshot|playlist|contact)\b"#

    /// True only for a genuine whole-job build request.
    static func isBuildRequest(_ text: String) -> Bool {
        guard text.range(
            of: disqualifyingOpenerPattern, options: .regularExpression) == nil
        else { return false }
        guard text.range(
            of: buildOpenerPattern, options: .regularExpression) != nil
        else { return false }
        guard text.range(
            of: deliverableNounPattern, options: .regularExpression) != nil
        else { return false }
        // "make me a note about the dashboard" stays on the note route.
        if let singleEffectRange = text.range(
            of: singleEffectNounPattern, options: .regularExpression),
           let deliverableRange = text.range(
            of: deliverableNounPattern, options: .regularExpression),
           singleEffectRange.lowerBound < deliverableRange.lowerBound {
            return false
        }
        return true
    }

    /// Arming a job reuses the exact `confirm` grammar every other consequential
    /// action uses. One word, whole utterance, nothing inherited.
    static func isExplicitConfirmation(_ utterance: String) -> Bool {
        CrossAppActionPolicy.isExplicitConfirmation(utterance)
    }

    static func isExplicitCancellation(_ utterance: String) -> Bool {
        CrossAppActionPolicy.isExplicitCancellation(utterance)
    }

    /// The kill word. A running build must die on a plain "stop" — the owner
    /// should never have to remember a special phrase to revoke authority they
    /// just granted.
    static func isAbortRequest(_ utterance: String) -> Bool {
        utterance.range(
            of: #"(?i)^\s*(?:ace[\s,]+)?(?:stop|halt|abort|cancel|quit|kill|never\s+mind|forget\s+it)\b[^.!?]*[.!?]*\s*$"#,
            options: .regularExpression
        ) != nil
    }

    /// "how's that build going", "what are you doing" while a job runs.
    static func isProgressRequest(_ utterance: String) -> Bool {
        utterance.range(
            of: #"(?i)^\s*(?:ace[\s,]+)?(?:how'?s|hows|what'?s|whats|where\s+are\s+you)\b[^.!?]{0,60}\b(?:build|building|going|progress|at|up\s+to|doing|status)\b"#,
            options: .regularExpression
        ) != nil
    }

    /// The confirmation window for a whole-job grant. Deliberately the same 30
    /// seconds as every single-effect confirmation: a larger grant does not get
    /// a longer window to sit armed in.
    static let confirmationLifetime: TimeInterval =
        CrossAppActionPolicy.confirmationLifetime
}
