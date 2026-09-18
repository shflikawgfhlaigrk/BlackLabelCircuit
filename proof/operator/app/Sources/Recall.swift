// Sovereign — SV-18: the on-device CITED RECALL VAULT.
//
// The feature: "what was that thing I was looking at on Tuesday?" — Sovereign can remember what
// crossed your screen and hand it back to you WITH A CITATION (which app, when). Rewind/Limitless
// sell this. The difference is the posture, and the posture is the whole product:
//
//   1. OPT-IN, and it SHIPS OFF.  `RecallPolicy.shipsEnabled == false`, `RecallStore.optedIn`
//      defaults to false, and the vault ships EMPTY (§5.2). A buyer who never finds this screen is
//      never recorded — no dark-pattern default, no "we already started capturing".
//   2. ON-DEVICE + KEYLESS.  Capture reuses the SAME foundation as SV-14's vision analyzer: the
//      Quartz window graph for the source app + Apple's Vision OCR for the text. No cloud, no API
//      key, no upload — the frames are never even written to disk; only redacted TEXT is kept.
//   3. SECRETS ARE REDACTED BEFORE PERSIST.  Every capture goes through `SecretRedactor` on the way
//      in — there is no code path that writes raw OCR text to the store. A capture taken over a
//      credential surface (a Keychain prompt, a password manager) is DROPPED WHOLE, not redacted.
//   4. EVERY ENTRY IS CITED.  Source app + timestamp, always. A recall with no provenance is a
//      fabrication (§5.1); `RecallEntry.citation` is non-empty by construction.
//
// The gate is a PURE type (`RecallPolicy`), mirroring `DictationPolicy` (SV-23): one honest
// decision, unit-testable off the main actor, with no way for the UI to route around it.
import Foundation
#if canImport(SwiftUI) && !CIRCUIT_WINDOWS_SIM
import SwiftUI
#endif
#if canImport(AppKit)
import AppKit
#endif
#if canImport(Vision)
import Vision
#endif
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - The gate (PURE — mirrors DictationPolicy)

enum RecallPolicy {
    /// Why recall is (or isn't) capturing. Anything but `.ready` means NOTHING is captured and the
    /// UI says why, honestly — never a dead toggle, never a silent capture.
    enum Availability: Equatable { case ready, optedOut, noScreenAccess, unsupported }

    /// THE SHIP-NO-DATA CONSTANT (§5.2). Recall ships OFF. This is a named truth so the gate can't
    /// drift to on-by-default without a test failing — `gate_ships_no_data` stays green because the
    /// shipped app captures nothing until the buyer opts in themselves.
    static let shipsEnabled = false

    /// The hard gate. Recall captures ONLY when the buyer opted in, the OS granted screen access,
    /// and the platform supports the keyless capture path. PURE.
    ///
    /// Opt-in is judged BEFORE screen access on purpose: a buyer who hasn't opted in is `.optedOut`,
    /// never `.noScreenAccess` — so the app has no reason to probe (or prompt for) the screen-
    /// recording permission of someone who never asked for this feature.
    static func availability(optedIn: Bool, screenAccessGranted: Bool, supported: Bool) -> Availability {
        if !supported { return .unsupported }
        if !optedIn { return .optedOut }               // OFF by default → the shipped posture
        if !screenAccessGranted { return .noScreenAccess }
        return .ready
    }

    /// Convenience: capture may run only in the `.ready` state.
    static func isCapturing(optedIn: Bool, screenAccessGranted: Bool, supported: Bool) -> Bool {
        availability(optedIn: optedIn, screenAccessGranted: screenAccessGranted, supported: supported) == .ready
    }

    // MARK: - SCHEDULED (background-interval) capture — the Rewind-shaped posture, behind its OWN gate

    /// THE SECOND SHIP-NO-DATA CONSTANT (§5.2). Scheduled capture — the only path that reads the
    /// screen without a tap — is the single highest-risk posture in the app, so it gets its OWN named
    /// false and its OWN opt-in. Turning Recall on does NOT turn this on; a buyer who never finds this
    /// second switch is never sampled in the background. `gate_ships_no_data` covers both constants.
    static let scheduledShipsEnabled = false

    /// The floor an interval is clamped to. A "capture every 5 seconds" is not a memory aid, it's a
    /// screen recorder — so the buyer's interval is floored to once a minute, and there is no way for
    /// the UI to set anything faster. PURE.
    static let minScheduledInterval: TimeInterval = 60
    /// What the interval defaults to when the buyer turns scheduled capture on without picking one.
    static let defaultScheduledInterval: TimeInterval = 300   // 5 minutes

    /// Floor a requested interval to the minimum. A zero/negative/absent value resolves to the
    /// default rather than to "every 0 seconds". PURE.
    static func clampInterval(_ raw: TimeInterval) -> TimeInterval {
        guard raw > 0 else { return defaultScheduledInterval }
        return max(minScheduledInterval, raw)
    }

    /// The scheduled gate. Background sampling runs ONLY when the buyer opted into Recall AND flipped
    /// the SEPARATE scheduled switch AND granted screen access AND the platform supports the keyless
    /// path. Both opt-ins are required: a scheduled capture with the second switch off is `.optedOut`,
    /// so an "always-on-without-opt-in" state can never reach `.ready`. PURE.
    static func scheduledAvailability(optedIn: Bool, scheduledOptedIn: Bool,
                                      screenAccessGranted: Bool, supported: Bool) -> Availability {
        if !supported { return .unsupported }
        if !optedIn || !scheduledOptedIn { return .optedOut }   // either switch off → nothing sampled
        if !screenAccessGranted { return .noScreenAccess }
        return .ready
    }

    /// Convenience: background sampling may run only in the fully-consented `.ready` state.
    static func isScheduledCapturing(optedIn: Bool, scheduledOptedIn: Bool,
                                     screenAccessGranted: Bool, supported: Bool) -> Bool {
        scheduledAvailability(optedIn: optedIn, scheduledOptedIn: scheduledOptedIn,
                              screenAccessGranted: screenAccessGranted, supported: supported) == .ready
    }

    /// The honest one-liner the UI shows instead of pretending to record. PURE.
    static func reason(_ a: Availability) -> String {
        switch a {
        case .ready:          return "Recall is on. What's on your screen is read on this device, stripped of detected secrets, and saved in local app data. Selected recall text is sent to a configured external provider only when you use it as brain context."
        case .optedOut:       return "Recall is off. Nothing on your screen is being read or saved. Turn it on below if you want Sovereign to remember what you looked at."
        case .noScreenAccess: return "Recall needs Screen Recording permission in System Settings › Privacy & Security. Until you grant it, nothing is captured."
        case .unsupported:    return "Recall needs macOS on-device screen reading, which isn't available in this build."
        }
    }
}

// MARK: - Secret redaction (PURE — runs BEFORE anything is persisted)

/// Strips credentials out of captured screen text on the way into the vault. This is the tooth
/// behind "secrets redacted": there is no path from a capture to the store that skips it.
///
/// Two levels of defence:
///   · `isCredentialSurface` — the capture is over a Keychain prompt / password manager / a screen
///     that is ALL secret. The whole capture is DROPPED. Redacting it would still leave the shape
///     of it (labels, the account name) in the vault, and there is nothing worth remembering on a
///     password prompt anyway.
///   · `redact` — a normal screen that happens to contain a card number, an API key, a `password:`
///     line, or a masked field. The secret is replaced with a marker; the rest of the line stays,
///     because the line is what makes the memory useful.
enum SecretRedactor {
    /// What replaces a secret. Visible on purpose — the buyer should SEE that redaction happened.
    static let marker = "[redacted]"

    struct Result: Equatable {
        var text: String
        var redactedCount: Int
        var kinds: [String]           // e.g. ["card", "api-key"] — what was stripped, honestly named

        /// Nothing worth keeping. A screen that was ALL secret redacts down to markers and
        /// punctuation — storing that husk would be a memory of nothing, dressed up as a memory.
        var isEmpty: Bool {
            text.replacingOccurrences(of: marker, with: " ")
                .rangeOfCharacter(from: .alphanumerics) == nil
        }
    }

    /// Apps whose windows are, by definition, credential surfaces. A capture owned by one of these
    /// is never stored at all.
    static let credentialApps = [
        "securityagent", "keychain access", "1password", "bitwarden", "lastpass",
        "dashlane", "keeper password manager", "enpass", "strongbox",
    ]

    /// Window/text signals that this frame is a credential prompt (the macOS Keychain dialog, an
    /// auth sheet, a login form focused on the password field).
    static let credentialSignals = [
        "wants to use your confidential information stored in",
        "wants to make changes",              // the macOS auth sheet
        "enter your password",
        "enter the password for",
        "unlock keychain",
        "keychain access wants",
        "touch id or enter your password",
    ]

    /// TRUE when the whole capture must be dropped, not merely redacted. PURE.
    static func isCredentialSurface(app: String, windowTitle: String, text: String) -> Bool {
        let a = app.lowercased()
        if credentialApps.contains(where: { a.contains($0) }) { return true }
        let hay = (windowTitle + "\n" + text).lowercased()
        return credentialSignals.contains(where: { hay.contains($0) })
    }

    /// Strip every secret we can positively identify. PURE, line-oriented, order-stable.
    static func redact(_ raw: String) -> Result {
        var kinds: [String] = []
        var count = 0
        var out: [String] = []

        for line in raw.components(separatedBy: .newlines) {
            // A private-key block header means the body is key material — drop the whole line.
            if line.range(of: #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, options: .regularExpression) != nil {
                count += 1
                if !kinds.contains("private-key") { kinds.append("private-key") }
                out.append(marker)
                continue
            }
            var l = line
            for rule in rules {
                guard let re = rule.regex else { continue }
                let matches = re.matches(in: l, range: NSRange(l.startIndex..., in: l))
                guard !matches.isEmpty else { continue }

                if rule.kind == "card" {
                    // A card-shaped run of digits is only a card if it passes Luhn. An order number or
                    // a build id must NOT be silently redacted — over-redaction is its own dishonesty:
                    // the vault would claim to hold a memory it had actually mangled. Replace from the
                    // END so each earlier match's range stays valid.
                    var hit = 0
                    for m in matches.reversed() {
                        let ns = l as NSString
                        guard isLuhnValid(ns.substring(with: m.range)) else { continue }
                        l = ns.replacingCharacters(in: m.range, with: marker)
                        hit += 1
                    }
                    if hit > 0 {
                        count += hit
                        if !kinds.contains(rule.kind) { kinds.append(rule.kind) }
                    }
                } else {
                    // Template replacement (so `$1` keeps the LABEL and drops only the VALUE).
                    l = re.stringByReplacingMatches(in: l, range: NSRange(l.startIndex..., in: l),
                                                    withTemplate: rule.replacement)
                    count += matches.count
                    if !kinds.contains(rule.kind) { kinds.append(rule.kind) }
                }
            }
            out.append(l)
        }
        return Result(text: out.joined(separator: "\n"), redactedCount: count, kinds: kinds)
    }

    private struct Rule {
        let kind: String
        let pattern: String
        let replacement: String
        var regex: NSRegularExpression? { try? NSRegularExpression(pattern: pattern) }
    }

    /// Ordered: the most specific formats first, so a `Bearer sk-…` is named once, not twice.
    private static let rules: [Rule] = [
        // Vendor-formatted keys — unambiguous, redact on sight.
        Rule(kind: "api-key", pattern: #"\bsk-[A-Za-z0-9_\-]{16,}"#, replacement: marker),
        Rule(kind: "api-key", pattern: #"\b(ghp|gho|ghs|ghu)_[A-Za-z0-9]{20,}"#, replacement: marker),
        Rule(kind: "api-key", pattern: #"\bxox[baprs]-[A-Za-z0-9\-]{10,}"#, replacement: marker),
        Rule(kind: "api-key", pattern: #"\bAKIA[0-9A-Z]{16}\b"#, replacement: marker),
        Rule(kind: "token",   pattern: #"\bBearer\s+[A-Za-z0-9._\-]{12,}"#, replacement: "Bearer " + marker),
        Rule(kind: "token",   pattern: #"\beyJ[A-Za-z0-9._\-]{20,}"#, replacement: marker),   // JWT

        // A labelled secret: `password: hunter2`, `API key = …`, `secret — …`. The LABEL survives
        // (so the memory still reads sensibly); the VALUE does not. The negative lookahead skips a
        // value a vendor-key rule above ALREADY redacted, so one secret is never counted twice —
        // an inflated redaction count is a fabricated number like any other (§5.1).
        Rule(kind: "password",
             pattern: #"(?i)\b(pass(word|phrase|code)?|secret|api[ _-]?key|token|auth|pin)\b\s*[:=\-—]\s*(?!\[redacted\])\S+"#,
             replacement: "$1: " + marker),

        // A masked/secure field as OCR sees it — a run of bullets or asterisks.
        Rule(kind: "masked-field", pattern: #"[•●∙*]{4,}"#, replacement: marker),

        // Payment cards: 13–19 digits, optionally space/dash grouped. Luhn-checked above.
        Rule(kind: "card", pattern: #"\b(?:\d[ \-]?){13,19}\b"#, replacement: marker),
    ]

    /// The Luhn checksum every real payment card satisfies. Keeps redaction honest in BOTH
    /// directions: real cards are always caught, arbitrary long numbers are left alone. PURE.
    static func isLuhnValid(_ candidate: String) -> Bool {
        let digits = candidate.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}

// MARK: - A cited entry

/// One remembered screen. `text` is ALWAYS post-redaction — the raw OCR never reaches this type.
struct RecallEntry: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var text: String = ""
    var sourceApp: String = ""
    var windowTitle: String = ""
    var captured = Date()
    var redactedCount: Int = 0

    /// Honest source label — never blank, so a recall can always name where it came from.
    var app: String { sourceApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Unknown app" : sourceApp }

    /// THE CITATION (§5.1). Every recalled line can point at the app and the moment it was seen —
    /// if Sovereign can't say where a memory came from, it has no business claiming to remember it.
    var citation: String { "\(app) · \(Self.stamp.string(from: captured))" }

    /// The citation with the window, when there is one — what the recall UI shows under a hit.
    var fullCitation: String {
        let t = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? citation : "\(app) — \(t) · \(Self.stamp.string(from: captured))"
    }

    static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()
}

/// What a capture is allowed to become. Every outcome is honest — a refusal is never silently
/// swallowed, and a refusal never persists a byte.
enum RecallOutcome: Equatable {
    case stored(RecallEntry)
    case refusedNotReady(RecallPolicy.Availability)   // recall is off / unpermitted / unsupported
    case refusedCredentialSurface                     // a Keychain prompt etc — dropped whole
    case nothingToStore                               // empty screen, or nothing left after redaction
}

// MARK: - The vault

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
@MainActor
final class RecallStore: ObservableObject {
    /// The raw material of a capture, before the store is allowed to keep any of it.
    struct RawCapture: Equatable {
        var text: String
        var sourceApp: String
        var windowTitle: String = ""
        var captured = Date()
    }

    /// OFF BY DEFAULT — the buyer turns this on themselves or it never runs (§5.2).
    @Published var optedIn: Bool { didSet { d.set(optedIn, forKey: Self.optInKey) } }
    @Published private(set) var entries: [RecallEntry] = [] { didSet { persist() } }

    /// THE SECOND, SEPARATE OPT-IN — background scheduled sampling. OFF by default, persisted on its
    /// own key. Turning `optedIn` on does NOT flip this; it is a deliberate second act (§5.2).
    @Published var scheduledOptedIn: Bool { didSet { d.set(scheduledOptedIn, forKey: Self.scheduledOptInKey) } }
    /// The buyer-set sampling interval, floored to `RecallPolicy.minScheduledInterval`. Stored raw and
    /// clamped on read, so a persisted-then-lowered floor can never let an old tiny interval through.
    @Published var scheduledInterval: TimeInterval { didSet { d.set(scheduledInterval, forKey: Self.scheduledIntervalKey) } }

    private let d: UserDefaults
    nonisolated static let storeKey = "com.blacklabel.sovereign.recall.v1"
    nonisolated static let optInKey = "com.blacklabel.sovereign.recall.optin.v1"
    nonisolated static let scheduledOptInKey = "com.blacklabel.sovereign.recall.scheduled.optin.v1"
    nonisolated static let scheduledIntervalKey = "com.blacklabel.sovereign.recall.scheduled.interval.v1"

    /// Bounded on purpose: a recall vault that grows forever is a liability, not a feature.
    nonisolated static let cap = 500

    /// Every grant/refusal/capture leaves a receipt, like every other autonomous surface.
    weak var activity: ActivityLog?

    init(defaults: UserDefaults = .standard) {
        d = defaults
        // `bool(forKey:)` returns false for an absent key — so ABSENT MEANS OFF, and there is
        // deliberately no default-on fallback anywhere in this type. The shipped default is the safe
        // one: a buyer who never touched this setting is never captured.
        optedIn = d.bool(forKey: Self.optInKey)
        // The second switch reads the SAME way: `bool(forKey:)` is false for an absent key, so an
        // absent scheduled opt-in is OFF. There is no default-on fallback — scheduled sampling ships off.
        scheduledOptedIn = d.bool(forKey: Self.scheduledOptInKey)
        // `double(forKey:)` is 0 for an absent key; `clampInterval` turns 0 into the honest default
        // and floors anything below the minimum, so no stored value can drop below the 1-per-minute cap.
        scheduledInterval = RecallPolicy.clampInterval(d.double(forKey: Self.scheduledIntervalKey))
        if let data = d.data(forKey: Self.storeKey),
           let e = try? JSONDecoder().decode([RecallEntry].self, from: data) { entries = e }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { d.set(data, forKey: Self.storeKey) }
    }

    /// Read the vault straight off the device, with no brain and no main actor — the same
    /// brain-independent read SV-13 uses to prove the vault is the buyer's, not the model's.
    nonisolated static func persistedEntries(_ defaults: UserDefaults = .standard) -> [RecallEntry] {
        guard let data = defaults.data(forKey: storeKey),
              let e = try? JSONDecoder().decode([RecallEntry].self, from: data) else { return [] }
        return e
    }
    nonisolated static func persistedOptIn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: optInKey)   // absent → false → ships OFF
    }
    nonisolated static func persistedScheduledOptIn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: scheduledOptInKey)   // absent → false → scheduled sampling ships OFF
    }

    /// THE ONLY WRITE PATH INTO THE VAULT. Gate → credential-surface drop → redact → persist.
    /// There is deliberately no `add(_ text:)` that skips this; raw OCR cannot reach the store.
    @discardableResult
    func record(_ raw: RawCapture, availability: RecallPolicy.Availability) -> RecallOutcome {
        guard availability == .ready else { return .refusedNotReady(availability) }

        // A password prompt is not a memory. Drop the whole frame — never redact-and-keep.
        guard !SecretRedactor.isCredentialSurface(app: raw.sourceApp, windowTitle: raw.windowTitle, text: raw.text) else {
            activity?.record(kind: .connector, title: "Recall skipped a credential screen",
                             detail: "A capture over \(raw.sourceApp) looked like a password or Keychain prompt. Nothing was saved.",
                             outcome: .info)
            return .refusedCredentialSurface
        }

        let scrubbed = SecretRedactor.redact(raw.text)
        guard !scrubbed.isEmpty else { return .nothingToStore }

        let entry = RecallEntry(text: scrubbed.text, sourceApp: raw.sourceApp,
                                windowTitle: raw.windowTitle, captured: raw.captured,
                                redactedCount: scrubbed.redactedCount)
        entries.insert(entry, at: 0)
        if entries.count > Self.cap { entries = Array(entries.prefix(Self.cap)) }
        return .stored(entry)
    }

    /// THE SCHEDULED WRITE PATH — and it is NOT a second write path. A background tick computes the
    /// scheduled availability from BOTH opt-ins and forwards to `record`, the one and only method that
    /// touches the vault. That means every scheduled capture inherits, unchanged, the credential-surface
    /// drop and the `SecretRedactor` pass — there is deliberately no raw-write bypass for the ambient
    /// path. A tick taken while the second switch is off resolves to `.optedOut` and persists nothing,
    /// so an "always-on-without-opt-in" capture is refused at the store, not merely hidden in the UI.
    @discardableResult
    func recordScheduled(_ raw: RawCapture, screenAccessGranted: Bool, supported: Bool) -> RecallOutcome {
        let av = RecallPolicy.scheduledAvailability(optedIn: optedIn, scheduledOptedIn: scheduledOptedIn,
                                                    screenAccessGranted: screenAccessGranted, supported: supported)
        return record(raw, availability: av)
    }

    func forget(_ e: RecallEntry) { entries.removeAll { $0.id == e.id } }

    /// Erase the whole vault AND every recall setting from memory and disk — the "delete all my data"
    /// path (App Store 5.1.1(v)). This is stronger than opting out (which only stops capture): it drops
    /// the stored entries, BOTH opt-in flags, and the interval, so no recall trace survives in
    /// UserDefaults. Mirrors how `ambient` is wiped (its key is removed in DataWipe; here we also clear
    /// the in-memory @Published state so the UI empties instantly).
    func wipeAll() {
        // 1. Clear in-memory. Each assignment's didSet re-persists its key; we hard-remove them next,
        //    and the removals run strictly AFTER these assignments, so no key can be re-created.
        entries = []
        optedIn = false
        scheduledOptedIn = false
        scheduledInterval = RecallPolicy.defaultScheduledInterval
        // 2. Hard-remove every recall UserDefaults key: the entries blob, both opt-in flags, and the
        //    interval. After this there is no recall key left on disk at all.
        for key in [Self.storeKey, Self.optInKey, Self.scheduledOptInKey, Self.scheduledIntervalKey] {
            d.removeObject(forKey: key)
        }
    }

    var redactedTotal: Int { entries.reduce(0) { $0 + $1.redactedCount } }

    /// CITED RECALL: find what crossed the screen, and hand back the citation with it. PURE and
    /// nonisolated so the honesty (a hit always carries provenance) is unit-testable.
    func recall(_ query: String) -> [RecallEntry] { Self.recall(entries, query: query) }

    nonisolated static func recall(_ entries: [RecallEntry], query raw: String) -> [RecallEntry] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }        // honest empty below the floor, never a guess
        return entries.filter { $0.text.range(of: q, options: .caseInsensitive) != nil }
    }

    /// The standing context a recall hit contributes to a brain call — WITH its citation, so the
    /// model is never handed a floating claim it can present as its own knowledge (§5.1).
    nonisolated static func groundingContext(_ hits: [RecallEntry]) -> String {
        guard !hits.isEmpty else { return "" }
        let lines = hits.prefix(5).map { "• \($0.text.prefix(400)) [seen in \($0.citation)]" }.joined(separator: "\n")
        return "From the user's on-device recall vault (each line is something they actually had on "
            + "screen — cite the source when you use it, never present it as your own knowledge):\n" + lines
    }
}
#endif // circuit-convert

// MARK: - Buyer-facing copy (pinned by tests — the honesty of this feature IS its copy)

/// The words the recall surface uses. Held as constants so a test can assert they stay honest: the
/// empty state must not imply a recording that isn't happening, and the on-state must not imply an
/// always-on recorder we never built — Sovereign reads the screen when ASKED, and says so.
enum RecallCopy {
    static let title = "Recall — what was on your screen"
    static let optInLabel = "Let Sovereign remember what's on my screen"

    /// The honest empty state: it names the fact that nothing is stored AND that nothing is running.
    static let emptyTitle = "Nothing remembered yet"
    static let emptyHint = "Recall is empty. When you ask Sovereign to remember a screen, it reads the "
        + "text on this Mac, strips out anything that looks like a password or card number, and saves the "
        + "rest here with the app it came from and the time you saw it."

    /// The scope statement. There is no background recorder in this build — say that plainly rather
    /// than let the buyer assume one (§5.1: no fabricated capability).
    static let scopeNote = "Sovereign reads your screen only when you ask it to — there's no always-on "
        + "recorder running in the background, and screenshots are never saved or uploaded. Only the "
        + "redacted text stays, on this device. Scheduled snapshots are a separate switch below, off "
        + "until you turn them on, and even then Sovereign samples on your interval rather than "
        + "recording continuously."

    static let captureLabel = "Remember this screen"
    static let redactionNote = "Passwords, card numbers, API keys and masked fields are removed before "
        + "anything is written. A screen that's a password or Keychain prompt is skipped entirely."

    // ── SCHEDULED (background-interval) capture. This is the Rewind-shaped posture, so the copy is
    // deliberately conservative: it names the switch as OFF until the buyer flips it, states exactly
    // what it stores, floors the interval, and refuses any always-on / continuous-recording implication
    // (§5.1: no fabricated capability — we sample on an interval, we do not record a timeline).
    static let scheduledLabel = "Capture my screen on a schedule while I work"

    /// The scope statement for scheduled sampling. Held as a constant so a test can pin its honesty.
    static let scheduledNote = "Scheduled capture is off until you turn it on. When it's on, Sovereign "
        + "takes a single snapshot of the frontmost window on an interval you set — never faster than "
        + "once a minute — runs the exact same redaction, and keeps only the redacted text with the app "
        + "it came from and the time. It is not a continuous recorder and there is no always-on timeline: "
        + "it samples on your interval, it pauses itself on any password or Keychain screen, and no "
        + "image is saved. Redacted text is stored locally; selected text is sent to a configured external "
        + "provider only when you use it as brain context. Turn the "
        + "switch off and scheduled capture stops."

    /// The honest state line shown when the second switch is off.
    static let scheduledOffNote = "Scheduled capture is off. Sovereign takes no snapshots on its own — "
        + "it only reads a screen when you click Remember this screen."

    /// The interval control's label.
    static let scheduledIntervalLabel = "Take a snapshot every"
}

// MARK: - Capture (macOS, KEYLESS — the SV-14 Quartz + Vision foundation)

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
#if os(macOS)
/// The capture foundation, reused wholesale from the keyless vision analyzer that already ships
/// (SV-14): the Quartz window graph names the source app (that's the citation), and Apple's Vision
/// OCR reads the text — both entirely on this Mac, no key, no network, no cloud model.
///
/// The captured IMAGE is never written to disk and never leaves this function. Only redacted text,
/// via `RecallStore.record`, is ever persisted.
enum RecallCapture {
    static var supported: Bool {
        #if canImport(Vision)
        return true
        #else
        return false
        #endif
    }

    /// The REAL TCC state — read, never assumed. `CGPreflightScreenCaptureAccess` does not prompt,
    /// so calling it can't nag a buyer who is merely looking at the settings panel.
    static var screenAccessGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Ask the OS for screen access — only ever from the buyer's explicit tap on the opt-in.
    static func requestScreenAccess() { CGRequestScreenCaptureAccess() }

    /// The live gate for this machine, from the real opt-in + the real permission.
    static func availability(optedIn: Bool) -> RecallPolicy.Availability {
        // Opt-in FIRST — a buyer who hasn't opted in is never the subject of a permission probe.
        guard optedIn else {
            return RecallPolicy.availability(optedIn: false, screenAccessGranted: false, supported: supported)
        }
        return RecallPolicy.availability(optedIn: true, screenAccessGranted: screenAccessGranted, supported: supported)
    }

    /// The live SCHEDULED gate for this machine. Both switches gate the permission probe: a buyer who
    /// hasn't turned on scheduled sampling is never the subject of a TCC read for it.
    static func scheduledAvailability(optedIn: Bool, scheduledOptedIn: Bool) -> RecallPolicy.Availability {
        guard optedIn && scheduledOptedIn else {
            return RecallPolicy.scheduledAvailability(optedIn: optedIn, scheduledOptedIn: scheduledOptedIn,
                                                      screenAccessGranted: false, supported: supported)
        }
        return RecallPolicy.scheduledAvailability(optedIn: optedIn, scheduledOptedIn: scheduledOptedIn,
                                                  screenAccessGranted: screenAccessGranted, supported: supported)
    }

    /// Read the frontmost window: who owns it (citation) and what it says (OCR). Returns nil rather
    /// than guessing — no window, no text, no capture. NEVER fabricates a source app.
    static func captureFrontmost() -> RecallStore.RawCapture? {
        #if canImport(Vision)
        guard let (windowID, app, title) = frontmostWindow() else { return nil }
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID,
                                                  [.boundsIgnoreFraming, .nominalResolution]) else { return nil }
        let text = ocr(image)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return RecallStore.RawCapture(text: text, sourceApp: app, windowTitle: title)
        #else
        return nil
        #endif
    }

    /// The Quartz window graph — the same `kCGWindowOwnerName` / `kCGWindowName` read the shipped
    /// vision analyzer uses to name what's on screen.
    private static func frontmostWindow() -> (CGWindowID, String, String)? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                     kCGNullWindowID) as? [[String: Any]] else { return nil }
        let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        for info in infos {
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? ""
            guard !owner.isEmpty, owner != "Sovereign" else { continue }   // never record ourselves
            guard front.isEmpty || owner == front else { continue }
            guard let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }                             // real windows only
            return (id, owner, (info[kCGWindowName as String] as? String) ?? "")
        }
        return nil
    }

    /// Apple Vision OCR, on-device. `.accurate` is a ~2-minute cold start then sub-second warm —
    /// that's the analyzer's known behavior, not a hang.
    private static func ocr(_ image: CGImage) -> String {
        #if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false      // screen text is not prose; don't "fix" it
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let obs = request.results ?? []
        return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        #else
        return ""
        #endif
    }
}

// MARK: - The scheduled sampler (macOS runtime)

/// Drives background scheduled capture. It owns a single CANCELLABLE `Timer` — never an uncancelable
/// forever-loop (those burned CPU in the background because they can't be cancelled; §fx).
/// It runs ONLY while the scheduled gate is `.ready`, and every tick forwards through
/// `RecallStore.recordScheduled` → `record`, so the sampler cannot skip redaction or the credential
/// drop. `sync()` is idempotent: call it on attach and on any opt-in / interval change; it starts,
/// restarts (to pick up a new interval), or stops to match the current gate.
@MainActor
final class RecallScheduler: ObservableObject {
    private weak var store: RecallStore?
    private var timer: Timer?
    private var runningInterval: TimeInterval = 0
    @Published private(set) var isRunning = false

    /// Bind the scheduler to the vault and reconcile once.
    func attach(_ store: RecallStore) { self.store = store; sync() }

    /// Reconcile the timer to the live gate. Idempotent.
    func sync() {
        guard let store else { stop(); return }
        let interval = RecallPolicy.clampInterval(store.scheduledInterval)
        let ready = RecallCapture.scheduledAvailability(optedIn: store.optedIn,
                                                        scheduledOptedIn: store.scheduledOptedIn) == .ready
        guard ready else { stop(); return }
        // Already running at this interval → nothing to do (don't churn the timer every re-render).
        if isRunning && runningInterval == interval { return }
        start(interval: interval)
    }

    private func start(interval: TimeInterval) {
        stop()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        runningInterval = interval
        isRunning = true
    }

    /// Stop sampling. Called on opt-out, on an unready gate, and on teardown.
    func stop() {
        timer?.invalidate()
        timer = nil
        runningInterval = 0
        isRunning = false
    }

    /// One scheduled sample: read the frontmost window keylessly and hand it to the ONE write path.
    /// A credential surface or an all-secret screen is dropped inside `record`; the sampler keeps no
    /// bytes of its own. Never fabricates a capture — no readable window means no entry.
    private func tick() {
        guard let store, let raw = RecallCapture.captureFrontmost() else { return }
        store.recordScheduled(raw, screenAccessGranted: RecallCapture.screenAccessGranted,
                              supported: RecallCapture.supported)
    }

    deinit { timer?.invalidate() }
}
#endif
#endif // circuit-convert

#if !os(macOS)
/// The scheduled screen sampler is a macOS-only capability. Keep the shared
/// environment graph intact on iOS while remaining explicitly inert.
@MainActor
final class RecallScheduler: ObservableObject {
    @Published private(set) var isRunning = false
    func attach(_ store: RecallStore) {}
    func sync() {}
    func stop() { isRunning = false }
}
#endif
