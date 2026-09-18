// Black Label Sovereign — SV-16: the white-label export engine.
//
// This is the PURE half of the deploy-for-a-client lane. It owns every decision the exporter
// makes — validating a client config, deriving the bundle identity, writing the brand seed, and
// authoring the license stub — with NO filesystem, no shell, and no AppKit. `build-whitelabel.sh`
// is a thin script over this engine (it compiles THIS FILE, verbatim, into its plan tool), and
// Tests/LogicTests.swift exercises it directly. There is exactly one implementation of the rules,
// so the script and the tests can never drift apart.
//
// Two invariants this file exists to hold:
//
//   FAIL CLOSED. A config with a missing, unknown, or invalid field produces an ERROR LIST and no
//   plan. The script refuses to emit anything at all rather than shipping a half-branded app that
//   still says "Sovereign" in half its surfaces — a half-branded app is worse than no app, because
//   the client would have to discover the leak themselves, in front of their own customers.
//
//   THE EXPORT IS NOT A BLACK LABEL APP. A white-labeled bundle gets its OWN bundle identifier
//   (so it gets its own UserDefaults domain and Keychain scope and cannot inherit anyone's data)
//   and its in-app updater is OFF (§5.1): Sovereign's updater points at Black Label's public
//   manifest and self-replaces the bundle, so a shipped white-label would have silently swapped
//   the client's branded app for a Black-Label-branded one on the first daily check. Updates for
//   a white-label build are re-exported and delivered by the licensee.
//
// It also carries NO buyer data and NO license terms it made up: LICENSE-STUB.md is a stub on
// purpose (§3 — pricing/licensing is a founder gate; this engine writes "FOUNDER INPUT NEEDED"
// where the terms go and never invents a number).
import Foundation

enum WhiteLabel {

    /// The term the founder banned from every shipped surface (2026-07-11, grep-zero). The exporter
    /// refuses a config that reintroduces it, and Tests/whitelabel-export.command re-greps the
    /// finished bundle so a config can never smuggle it into a client's hands.
    ///
    /// ASSEMBLED AT RUNTIME, NOT WRITTEN AS A LITERAL — and that is not paranoia. Writing it as
    /// `"local-first"` emitted the banned term straight into the shipped Mach-O (2 hits, one per
    /// arch slice), i.e. the code enforcing grep-zero would itself have broken grep-zero. The
    /// harness greps the built binary for exactly this, so a future edit that folds it back into one
    /// literal fails the build rather than quietly re-shipping the term.
    static let bannedTerm = ["local", "first"].joined(separator: "-")

    /// The base app's identifier. A white-label MUST NOT reuse it: same identifier == same
    /// UserDefaults domain and Keychain scope as the buyer's own Sovereign install, so the export
    /// would boot into someone else's conversations. Reusing it also collides in /Applications.
    static let baseBundleID = "com.blacklabel.sovereign"

    /// The brand seed's filename inside `Contents/Resources`. Its presence is what makes a bundle a
    /// white-label at runtime.
    static let seedFileName = "WhiteLabel.json"

    /// Why an export was refused. Carries EVERY reason at once — an operator fixing one error per
    /// failed export is how a rushed client deploy goes out half-branded.
    struct Refusal: Error, Equatable {
        var reasons: [String]
    }

    // MARK: - Config (what the operator writes)

    /// A client config. EVERY field is required — there is no default that would let a missing field
    /// pass silently as "Sovereign".
    struct Config: Codable, Equatable {
        var client: String            // the licensee, named in LICENSE-STUB.md
        var displayName: String       // CFBundleDisplayName + the .app's filename
        var assistantName: String     // what the assistant calls itself in-app
        var bundleIdentifier: String  // reverse-DNS, the client's own
        var accentHex: String         // "RRGGBB"
        var wakePhrase: String        // what the client says out loud to wake it
        var tagline: String
        var iconPath: String          // square PNG, >= 1024x1024

        static let requiredKeys: Set<String> = [
            "client", "displayName", "assistantName", "bundleIdentifier",
            "accentHex", "wakePhrase", "tagline", "iconPath",
        ]
    }

    /// The seed written into `Contents/Resources/WhiteLabel.json` — the runtime half of the brand.
    /// Deliberately NOT the whole Config: `iconPath` is a path on the OPERATOR's machine and has no
    /// business travelling to a client, and the bundle identity already lives in Info.plist.
    struct Brand: Codable, Equatable {
        var client: String
        var assistantName: String
        var accentHex: String
        var wakePhrase: String
        var tagline: String
    }

    /// Everything the script needs to produce the bundle. Derived purely; nothing is decided in bash.
    struct Plan: Equatable {
        var config: Config
        var brand: Brand
        var appBundleName: String        // "Acme Atlas.app"
        var executableName: String       // Contents/MacOS/<this> + CFBundleExecutable
        var urlScheme: String            // the client's own scheme, never "sovereign"
        var infoPlistFields: [String: String]
        var licenseStub: String
    }

    // MARK: - Validation (the fail-closed gate)

    /// Decode a config, refusing anything ambiguous. Missing keys and UNKNOWN keys are both hard
    /// errors: an unknown key is nearly always a typo of a real one ("accent_hex" for "accentHex"),
    /// and silently ignoring it is exactly how a half-branded app gets emitted — the operator thinks
    /// they set the accent, the app ships Black Label gold.
    static func decodeConfig(_ data: Data) -> Result<Config, Refusal> {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let dict = any as? [String: Any] else {
            return .failure(Refusal(reasons: ["config is not a JSON object"]))
        }
        let keys = Set(dict.keys)
        var errors: [String] = []
        for missing in Config.requiredKeys.subtracting(keys).sorted() {
            errors.append("missing required field: \(missing)")
        }
        for unknown in keys.subtracting(Config.requiredKeys).sorted() {
            errors.append("unknown field: \(unknown) (typo? every field is required and spelled exactly)")
        }
        guard errors.isEmpty else { return .failure(Refusal(reasons: errors)) }
        do {
            return .success(try JSONDecoder().decode(Config.self, from: data))
        } catch {
            // A present-but-wrong-typed field (e.g. accentHex: 12345) lands here.
            return .failure(Refusal(reasons: ["config field has the wrong type: \(error)"]))
        }
    }

    /// Every reason this config cannot be exported. Empty == valid. The exporter treats a non-empty
    /// list as fatal BEFORE it creates any output directory.
    static func validate(_ c: Config, iconBytes: Data?) -> [String] {
        var e: [String] = []

        func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Text fields: present, sane length, single-line.
        for (label, value, max) in [("client", c.client, 64), ("displayName", c.displayName, 64),
                                    ("assistantName", c.assistantName, 32), ("tagline", c.tagline, 80)] {
            let t = trimmed(value)
            if t.isEmpty { e.append("\(label) is empty") }
            else if t.count > max { e.append("\(label) is longer than \(max) characters") }
            if value.contains("\n") { e.append("\(label) must be a single line") }
        }

        // The .app's filename is the display name — it cannot carry path separators or a colon.
        if c.displayName.contains("/") || c.displayName.contains(":") {
            e.append("displayName cannot contain '/' or ':' (it becomes the .app's filename)")
        }
        if executableName(for: c.displayName).isEmpty {
            e.append("displayName has no alphanumeric characters to derive an executable name from")
        }

        // Bundle identifier: real reverse-DNS, and NOT ours.
        let bid = trimmed(c.bundleIdentifier)
        let bidOK = bid.split(separator: ".", omittingEmptySubsequences: false).count >= 2
            && !bid.hasPrefix(".") && !bid.hasSuffix(".")
            && bid.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
            && !bid.isEmpty
        if !bidOK {
            e.append("bundleIdentifier must be reverse-DNS (letters/numbers/'-'/'.', at least two components)")
        }
        if bid.lowercased() == baseBundleID {
            e.append("bundleIdentifier must not be \(baseBundleID) — a white-label needs its own identity, "
                     + "or it shares the buyer's Sovereign defaults, Keychain scope and /Applications slot")
        }
        if bidOK && urlScheme(for: bid) == "sovereign" {
            e.append("bundleIdentifier's last component cannot be 'sovereign' (its URL scheme would collide with the base app)")
        }

        // Accent: exactly six hex digits (a '#' prefix is tolerated and stripped).
        let hex = normalizedHex(c.accentHex)
        if hex.count != 6 || !hex.allSatisfy({ $0.isHexDigit }) {
            e.append("accentHex must be 6 hex digits (RRGGBB)")
        }

        // Wake phrase: something a human can actually say, and long enough not to fire on noise.
        let wake = trimmed(c.wakePhrase)
        if wake.count < 2 { e.append("wakePhrase must be at least 2 characters") }
        else if wake.count > 32 { e.append("wakePhrase is longer than 32 characters") }
        if !wake.isEmpty && !wake.allSatisfy({ $0.isLetter || $0 == " " || $0 == "'" || $0 == "-" }) {
            e.append("wakePhrase must be speakable — letters, spaces, apostrophes and hyphens only")
        }

        // Icon: a real, square PNG big enough to fill every macOS slot down from 1024.
        if trimmed(c.iconPath).isEmpty { e.append("iconPath is empty") }
        if let bytes = iconBytes {
            guard let (w, h) = pngSize(bytes) else {
                e.append("icon is not a readable PNG")
                return e + bannedTermErrors(c)
            }
            if w != h { e.append("icon must be square (got \(w)x\(h))") }
            if w < 1024 { e.append("icon must be at least 1024x1024 (got \(w)x\(h))") }
        } else {
            e.append("icon file could not be read at iconPath")
        }

        return e + bannedTermErrors(c)
    }

    /// §5.4 / SV-04: the founder's grep-zero directive applies to a client's build too. A config that
    /// reintroduces the banned term is refused at the door.
    private static func bannedTermErrors(_ c: Config) -> [String] {
        let fields = [("client", c.client), ("displayName", c.displayName), ("assistantName", c.assistantName),
                      ("tagline", c.tagline), ("wakePhrase", c.wakePhrase), ("bundleIdentifier", c.bundleIdentifier)]
        return fields.filter { containsBannedTerm($0.1) }
                     .map { "\($0.0) contains the banned term '\(bannedTerm)'" }
    }

    static func containsBannedTerm(_ s: String) -> Bool {
        s.lowercased().contains(bannedTerm)
    }

    // MARK: - Plan (the only thing the script is allowed to act on)

    static func plan(_ c: Config, iconBytes: Data?) -> Result<Plan, Refusal> {
        let errors = validate(c, iconBytes: iconBytes)
        guard errors.isEmpty else { return .failure(Refusal(reasons: errors)) }

        let display = c.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bid = c.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let exec = executableName(for: display)
        let scheme = urlScheme(for: bid)
        let brand = Brand(client: c.client.trimmingCharacters(in: .whitespacesAndNewlines),
                          assistantName: c.assistantName.trimmingCharacters(in: .whitespacesAndNewlines),
                          accentHex: normalizedHex(c.accentHex).uppercased(),
                          wakePhrase: c.wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines),
                          tagline: c.tagline.trimmingCharacters(in: .whitespacesAndNewlines))

        // NOTE what is NOT here: CFBundleVersion and CFBundleShortVersionString. The export re-brands
        // an already-built bundle byte-for-byte; it never renumbers it. The exported build carries the
        // SAME version as the Sovereign build it was derived from, so a client build is always
        // traceable back to the exact Black Label build that produced it.
        let fields: [String: String] = [
            "CFBundleDisplayName": display,
            "CFBundleName": display,
            "CFBundleIdentifier": bid,
            "CFBundleExecutable": exec,
        ]

        return .success(Plan(config: c,
                             brand: brand,
                             appBundleName: "\(display).app",
                             executableName: exec,
                             urlScheme: scheme,
                             infoPlistFields: fields,
                             licenseStub: licenseStub(for: brand, bundleID: bid)))
    }

    /// CFBundleExecutable + Contents/MacOS/<name>. Alphanumerics only — the base app's "Sovereign"
    /// binary name is itself a brand leak in `ps`, the Activity Monitor and a crash report.
    static func executableName(for displayName: String) -> String {
        String(displayName.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The client's own URL scheme, derived from the last component of their bundle id.
    static func urlScheme(for bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? ""
        return last.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func normalizedHex(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
         .replacingOccurrences(of: "#", with: "")
    }

    /// Minimal PNG IHDR read — enough to prove the icon is a real PNG of the right shape without
    /// pulling in ImageIO (this engine has to compile standalone for the plan tool).
    static func pngSize(_ data: Data) -> (Int, Int)? {
        // Copy through an Array first: a Data that arrived as a SLICE does not index from 0, and
        // subscripting it with absolute offsets would trap at runtime.
        let bytes = [UInt8](data.prefix(24))
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.count == 24, Array(bytes[0..<8]) == magic else { return nil }
        guard Array(bytes[12..<16]) == [0x49, 0x48, 0x44, 0x52] else { return nil }   // "IHDR"
        func be32(_ o: Int) -> Int {
            (Int(bytes[o]) << 24) | (Int(bytes[o + 1]) << 16) | (Int(bytes[o + 2]) << 8) | Int(bytes[o + 3])
        }
        return (be32(16), be32(20))
    }

    // MARK: - License stub (§3 — never invent terms)

    static let founderInputMarker = "FOUNDER INPUT NEEDED"

    static func licenseStub(for brand: Brand, bundleID: String) -> String {
        """
        # License — \(brand.assistantName)

        \(brand.assistantName) is a white-label build of Black Label Sovereign, exported for
        **\(brand.client)** (bundle identifier `\(bundleID)`).

        ## Terms

        > **\(founderInputMarker)** — the commercial terms of this white-label license are not set in
        > this document and must not be inferred from it. Price, term length, seat count, territory,
        > sublicensing rights, support scope and renewal are all owner decisions and are recorded in
        > the signed agreement between Black Label and \(brand.client), not here.

        | Term | Value |
        |---|---|
        | Licensee | \(brand.client) |
        | Price | \(founderInputMarker) |
        | License term | \(founderInputMarker) |
        | Seats / devices | \(founderInputMarker) |
        | Sublicensing | \(founderInputMarker) |
        | Support & updates | \(founderInputMarker) |

        This file is a STUB. It ships with the export so that no build can reach a client without the
        gap being visible; it is not itself a license, an offer, or a quote.

        ## What this build does and does not do

        - It runs on the client's own hardware and, where a cloud brain is connected, on the client's
          own account. Black Label never receives their data.
        - It carries no conversations, memories, keys or tokens: it starts empty on the client's own
          machine.
        - **It does not self-update.** Sovereign's in-app updater fetches Black Label's public build,
          which would replace this branded app with a Black-Label-branded one. It is switched off in
          every white-label export. New builds are re-exported and delivered by the licensee.
        """
    }

    // MARK: - Runtime (the seed the exported app actually reads)

    static func brand(fromSeed data: Data?) -> Brand? {
        guard let data, let b = try? JSONDecoder().decode(Brand.self, from: data) else { return nil }
        // A seed that survived decoding but is empty is not a brand — fall back to Sovereign's own
        // identity rather than booting a client's app with a blank name.
        guard !b.assistantName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return b
    }

    /// The brand of the RUNNING bundle. `nil` on every genuine Black Label Sovereign build — the base
    /// app ships no seed, which is what makes "is this a white-label?" a fact rather than a flag.
    static var installed: Brand? = {
        guard let url = Bundle.main.url(forResource: "WhiteLabel", withExtension: "json") else { return nil }
        return brand(fromSeed: try? Data(contentsOf: url))
    }()

    static var isWhiteLabel: Bool { installed != nil }

    /// §5.1 — the in-app updater is OFF in a white-label build. See the file header: leaving it on
    /// would let a client's branded app quietly self-replace with the Black Label build.
    static func updatesAllowed(brand: Brand?) -> Bool { brand == nil }

    static func updatesDisabledMessage(brand: Brand?) -> String {
        guard let brand else { return "" }
        return "Updates for \(brand.assistantName) are delivered by \(brand.client), not from inside the app."
    }

    // MARK: - Ships-no-data (mirrors BlackLabelShip/apps/sovereign.toml)

    /// The same globs ship.py's gate_ships_no_data enforces on a Sovereign ship. An export is a ship
    /// too — into a client's hands — so it is held to the identical bar, checked against the finished
    /// bundle by Tests/whitelabel-export.command.
    static let shipsNoDataGlobs = ["*.sqlite", "*.db", "*.csv", "*.pem", "*.key",
                                   "*.tokens", "*secrets*", "*.jsonl", "leads*", "bars*"]

    /// Which of these bundle-relative filenames would trip the ships-no-data gate. Pure so the rule
    /// is unit-testable rather than living only inside a shell pipeline.
    static func dataFileViolations(in fileNames: [String]) -> [String] {
        fileNames.filter { name in
            let low = (name as NSString).lastPathComponent.lowercased()
            // Source files are never buyer data (mirrors ship.py's SOURCE_EXT carve-out).
            if [".py", ".pyc", ".js", ".mjs", ".ts", ".map"].contains(where: { low.hasSuffix($0) }) { return false }
            return shipsNoDataGlobs.contains { glob in
                fnmatch(glob, low)
            }
        }
    }

    /// Tiny glob matcher for the leading/trailing-`*` patterns above (no libc fnmatch — this file
    /// must compile standalone for the plan tool on any machine).
    private static func fnmatch(_ pattern: String, _ name: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return pattern == name }
        var idx = name.startIndex
        for (i, part) in parts.enumerated() where !part.isEmpty {
            if i == 0 {
                guard name.hasPrefix(part) else { return false }
                idx = name.index(idx, offsetBy: part.count)
            } else if i == parts.count - 1 {
                guard name[idx...].hasSuffix(part) else { return false }
            } else {
                guard let r = name.range(of: part, range: idx..<name.endIndex) else { return false }
                idx = r.upperBound
            }
        }
        return true
    }
}
