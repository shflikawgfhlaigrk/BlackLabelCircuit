// Presets: streaming loudness targets, per-genre tonal/mastering targets, and processing-mode enums.

import Foundation

// MARK: - Processing mode + input kind

/// What the user wants Sunset to do with the material.
enum ProcessMode: String, Codable, CaseIterable, Identifiable {
    case masterOnly     // a finished stereo bounce -> polished master
    case mixOnly        // raw stems -> finished stereo mix bounce
    var id: String { rawValue }
    var label: String {
        switch self {
        case .masterOnly:   return "Master Only"
        case .mixOnly:      return "Mixing"
        }
    }
}

/// The shape of the input the user handed us.
enum InputKind: String, Codable, CaseIterable, Identifiable {
    case stereoMix   // one interleaved-source stereo file
    case stems       // a folder / set of stem files
    var id: String { rawValue }
    var label: String {
        switch self {
        case .stereoMix: return "Stereo Mix"
        case .stems:     return "Stems"
        }
    }
}

// MARK: - User 5-band EQ

/// A fixed 5-band tone control the user rides on top of the auto master.
/// Sub + Air are shelves; the three middle bands are broad peaks.
enum UserEQ {
    static let specs: [(label: String, freq: Double, kind: Int)] = [
        ("Sub",      60,    1),   // low shelf
        ("Low",      220,   0),   // peak
        ("Mid",      1000,  0),   // peak
        ("Presence", 4000,  0),   // peak
        ("Air",      12000, 2),   // high shelf
    ]
    static let count = specs.count
    static let flat: [Double] = Array(repeating: 0, count: specs.count)

    /// Build EQBands from 5 gains (dB); skips bands sitting at ~0 dB.
    static func bands(_ gains: [Double]) -> [EQBand] {
        var out: [EQBand] = []
        for (i, s) in specs.enumerated() {
            let g = i < gains.count ? gains[i] : 0
            if abs(g) < 0.05 { continue }
            switch s.kind {
            case 1: out.append(.lowShelf(s.freq, g))
            case 2: out.append(.highShelf(s.freq, g))
            default: out.append(.peak(s.freq, g, 0.9))
            }
        }
        return out
    }
}

struct TonePreset: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var blurb: String
    var gains: [Double]
}

enum TonePresets {
    static let flat = TonePreset(name: "Flat", blurb: "No extra tone curve", gains: UserEQ.flat)
    static let warm = TonePreset(name: "Warm", blurb: "Rounder low end, softer top",
                                 gains: [0.5, 1.5, -0.5, -0.5, -1.0])
    static let bright = TonePreset(name: "Bright", blurb: "Cleaner presence and air",
                                   gains: [-0.5, -0.5, 0.0, 1.5, 2.0])
    static let club = TonePreset(name: "Club", blurb: "Tight sub, dipped mud, open top",
                                 gains: [1.5, -1.5, -0.5, 1.0, 1.0])
    static let vocal = TonePreset(name: "Vocal", blurb: "Pushes lead clarity forward",
                                  gains: [-0.5, -1.0, 0.5, 2.0, 1.0])
    static let smooth = TonePreset(name: "Smooth", blurb: "Tames edge and harshness",
                                   gains: [0.0, 0.5, 0.0, -1.5, -0.5])
    static let techHouse = TonePreset(name: "Tech House", blurb: "Tight sub, clean low-mids, present click and air",
                                      gains: [1.0, -1.5, 0.0, 1.5, 1.5])
    static let custom = TonePreset(name: "Custom", blurb: "Manual tone curve", gains: UserEQ.flat)

    static let all: [TonePreset] = [flat, warm, bright, club, techHouse, vocal, smooth]
    static let menu: [TonePreset] = all + [custom]

    static func byID(_ id: String) -> TonePreset? {
        menu.first { $0.id == id }
    }
}

// MARK: - Mix style + per-role options (stems path)

/// Per-role mix behaviour. Styles fill these; they shape the sound the artist described —
/// bass ducked under the kick (low, strong, never taking over), kick transient snapped,
/// vocals kept clear by ducking the bed, synth lifted to carry the flow.
struct MixOptions: Equatable {
    var sidechainDepthDB: Double    // how hard bass/pads/fx duck to the kick
    var sidechainReleaseMs: Double  // pump speed / groove
    var kickPunch: Double           // 0…1 transient emphasis on the kick ("strong, quick")
    var bassDrive: Double           // 0…1 saturation warmth on the bass ("strong, not distorted")
    var vocalDuckDB: Double         // how hard the bed ducks under the vocal (clarity)
    var synthAir: Double            // 0…1 presence/air lift on synth/lead ("carry the flow")
    static let balanced = MixOptions(sidechainDepthDB: 5, sidechainReleaseMs: 160,
                                     kickPunch: 0.35, bassDrive: 0.25, vocalDuckDB: 3, synthAir: 0.45)
}

/// A named mix vibe: the tonal target + the per-role mix knobs + a default master intensity.
struct MixStyle: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var genre: GenreTarget
    var options: MixOptions
    var intensity: MasterIntensity
    var blurb: String
    var guideNotes: [String] = []
}

enum MixStyles {
    static let westendTechHouse = MixStyle(name: "Westend Tech House", genre: GenreTargets.modernTechHouse,
        options: MixOptions(sidechainDepthDB: 4, sidechainReleaseMs: 115, kickPunch: 0.62, bassDrive: 0.32, vocalDuckDB: 3.5, synthAir: 0.46),
        intensity: .max, blurb: "Punchy kick, layered bass, fast 2-5 dB duck, mono sub, wide tops",
        guideNotes: [
            "Kick anchors the mix: short house punch, little sub mud, soft clip over compression.",
            "Bass runs as sub, mid bass, and texture: sub below 90-120 Hz, mid presence near 700 Hz-2 kHz.",
            "Fast sidechain ducks bass 2-5 dB with a quick release so the groove breathes.",
            "Drum bus stays light: 2:1 glue, slow attack, 1-2 dB gain reduction, saturation, clipper.",
            "Below 120 Hz stays mono; synths, hats, vocals, and FX carry the width and automation."
        ])
    static let edmFoundation = MixStyle(name: "EDM Foundation", genre: GenreTargets.melodicTechno,
        options: MixOptions(sidechainDepthDB: 6, sidechainReleaseMs: 140, kickPunch: 0.48, bassDrive: 0.30, vocalDuckDB: 3.5, synthAir: 0.50),
        intensity: .loud, blurb: "Guide-based gain staging, role EQ, fast pump, low-end mono")
    static let melodicTechno = MixStyle(name: "Melodic Techno", genre: GenreTargets.melodicTechno,
        options: MixOptions(sidechainDepthDB: 5, sidechainReleaseMs: 160, kickPunch: 0.35, bassDrive: 0.25, vocalDuckDB: 3, synthAir: 0.45),
        intensity: .loud, blurb: "Deep groove, ducked bass, airy synths")
    static let festival = MixStyle(name: "Festival / Big Room", genre: GenreTargets.melodicTechno,
        options: MixOptions(sidechainDepthDB: 7, sidechainReleaseMs: 120, kickPunch: 0.55, bassDrive: 0.30, vocalDuckDB: 4, synthAir: 0.55),
        intensity: .max, blurb: "Hard pump, punchy kick, slammed")
    static let futureBass = MixStyle(name: "Future Bass", genre: GenreTargets.pop,
        options: MixOptions(sidechainDepthDB: 6, sidechainReleaseMs: 190, kickPunch: 0.40, bassDrive: 0.35, vocalDuckDB: 5, synthAir: 0.60),
        intensity: .loud, blurb: "Wide supersaws, vocal-forward")
    static let deep = MixStyle(name: "Deep / Organic", genre: GenreTargets.melodicTechno,
        options: MixOptions(sidechainDepthDB: 3, sidechainReleaseMs: 210, kickPunch: 0.25, bassDrive: 0.20, vocalDuckDB: 2, synthAir: 0.35),
        intensity: .balanced, blurb: "Subtle, dynamic, transparent")
    static let peakTime = MixStyle(name: "Peak-Time Techno", genre: GenreTargets.melodicTechno,
        options: MixOptions(sidechainDepthDB: 6, sidechainReleaseMs: 110, kickPunch: 0.60, bassDrive: 0.28, vocalDuckDB: 3, synthAir: 0.40),
        intensity: .max, blurb: "Relentless kick, tight low end")
    /// Non-EDM style for the Jazz target: no sidechain pump, natural transients, gentle intensity.
    static let jazzCombo = MixStyle(name: "Jazz Combo", genre: GenreTargets.jazz,
        options: MixOptions(sidechainDepthDB: 0, sidechainReleaseMs: 200, kickPunch: 0.12, bassDrive: 0.10, vocalDuckDB: 1.5, synthAir: 0.20),
        intensity: .gentle, blurb: "Natural dynamics, warm upright bass, brushed kit — no pumping")
    /// Non-EDM style for the Orchestral target: full dynamic range, wide hall, transient-safe.
    static let cinematicScore = MixStyle(name: "Cinematic Score", genre: GenreTargets.orchestral,
        options: MixOptions(sidechainDepthDB: 0, sidechainReleaseMs: 240, kickPunch: 0.10, bassDrive: 0.05, vocalDuckDB: 1.0, synthAir: 0.15),
        intensity: .gentle, blurb: "Full dynamic range, wide hall image, uncompressed feel")
    static let all: [MixStyle] = [westendTechHouse, edmFoundation, melodicTechno, festival, futureBass, deep, peakTime, jazzCombo, cinematicScore]
    // Westend Tech House is a SELECTABLE style (present in `all`), NOT the out-of-box default.
    // The shipped default stays edmFoundation — identical to build 2 (782efdf). Flipping this
    // is a customer-facing default-behavior change and is founder/§3-gated. Locked by
    // tests/audio_regression.swift ("default mix style must remain EDM Foundation").
    static let `default`: MixStyle = edmFoundation
}

// MARK: - Master intensity (loudness ↔ dynamics character)

/// How hard the master is pushed. Trades loudness against dynamic range/punch — the
/// control the earlier build was missing (it was hardwired to a crushed genre preset).
/// Intensity sets the loudness target, the limiter feel, and saturation density; the
/// true-peak ceiling always comes from the platform, so every setting stays clip-safe.
enum MasterIntensity: String, Codable, CaseIterable, Identifiable {
    case gentle, balanced, loud, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gentle:   return "Gentle"
        case .balanced: return "Balanced"
        case .loud:     return "Loud"
        case .max:      return "Max"
        }
    }
    var blurb: String {
        switch self {
        case .gentle:   return "Preserve dynamics — open, audiophile"
        case .balanced: return "Everyday release loudness"
        case .loud:     return "Competitive streaming/club loudness"
        case .max:      return "Slammed — festival / DJ pool"
        }
    }
    /// Integrated LUFS the chain aims for.
    var targetLUFS: Double {
        switch self {
        case .gentle:   return -13.0
        case .balanced: return -10.5
        case .loud:     return -8.5
        case .max:      return -7.0
        }
    }
    /// Limiter release — long/transparent when gentle, snappy/dense when max.
    var limiterReleaseMs: Double {
        switch self {
        case .gentle:   return 140
        case .balanced: return 90
        case .loud:     return 60
        case .max:      return 40
        }
    }
    /// Parallel-saturation blend — more density as it gets louder.
    var saturationMix: Double {
        switch self {
        case .gentle:   return 0.06
        case .balanced: return 0.11
        case .loud:     return 0.15
        case .max:      return 0.20
        }
    }
    static let `default`: MasterIntensity = .balanced
}

// MARK: - Loudness profiles (selectable club/tech-house target)

/// A named, selectable loudness profile: an integrated-LUFS target with an honest
/// measured window, a true-peak ceiling, and whether it engages the pre-limiter soft
/// clip. Sits ALONGSIDE the existing intensity/platform controls. `none` is the shipped
/// default — it defers entirely to the Intensity control, so the out-of-box master is
/// unchanged (founder/§3-gated to flip). Loudness read-outs are always MEASURED (the
/// profile only sets the *target*; the meters report what the master actually hit).
struct LoudnessProfile: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var targetLUFS: Double?      // nil → defer to Intensity (no loudness override)
    var rangeLowLUFS: Double     // measured-target window, low edge (LUFS)
    var rangeHighLUFS: Double    // measured-target window, high edge (LUFS)
    var truePeakDBTP: Double?    // nil → platform/genre owns the true-peak ceiling
    var softClip: SoftClipSettings
    var blurb: String

    /// Did the master's measured integrated loudness land inside this profile's window?
    func lands(_ measuredLUFS: Double) -> Bool {
        guard targetLUFS != nil else { return true }
        return measuredLUFS >= rangeLowLUFS - 0.6 && measuredLUFS <= rangeHighLUFS + 0.6
    }
}

enum LoudnessProfiles {
    /// Shipped default — loudness follows the Intensity control; no soft clip.
    static let none = LoudnessProfile(name: "Default (Intensity)", targetLUFS: nil,
        rangeLowLUFS: 0, rangeHighLUFS: 0, truePeakDBTP: nil, softClip: .bypassed,
        blurb: "Loudness follows the Intensity control.")

    /// Club / Tech-House pre-master level: −10 to −8 LUFS integrated (aim −9), −1 dBTP
    /// ceiling, mono-safe lows (via the genre target), gentle pre-limiter soft clip on.
    static let clubTechHouse = LoudnessProfile(name: "Club / Tech-House", targetLUFS: -9.0,
        rangeLowLUFS: -10.0, rangeHighLUFS: -8.0, truePeakDBTP: -1.0, softClip: .gentle,
        blurb: "Pre-master club range (−10 to −8 LUFS), −1 dBTP ceiling, gentle soft clip.")

    /// Streaming-normalized target for contrast: −14 LUFS, dynamics preserved.
    static let streaming = LoudnessProfile(name: "Streaming (−14)", targetLUFS: -14.0,
        rangeLowLUFS: -15.0, rangeHighLUFS: -13.0, truePeakDBTP: -1.0, softClip: .bypassed,
        blurb: "Streaming-normalized target, dynamics preserved.")

    static let all: [LoudnessProfile] = [none, clubTechHouse, streaming]
    static let `default`: LoudnessProfile = none
    static func byID(_ id: String) -> LoudnessProfile? { all.first { $0.id == id } }
}

// MARK: - Platform loudness targets

/// A delivery target: integrated loudness + true-peak ceiling for a given platform.
struct PlatformTarget: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var lufs: Double          // integrated LUFS the platform normalizes toward
    var truePeakDBTP: Double  // recommended true-peak ceiling (dBTP)
    var note: String
}

enum PlatformTargets {
    /// Published, well-known normalization targets. Ceilings kept conservative to survive lossy transcode.
    static let all: [PlatformTarget] = [
        PlatformTarget(name: "Spotify",     lufs: -14, truePeakDBTP: -1, note: "Normalizes to -14 LUFS; -1 dBTP survives Ogg/AAC transcode."),
        PlatformTarget(name: "Apple Music", lufs: -16, truePeakDBTP: -1, note: "Sound Check targets -16 LUFS; -1 dBTP ceiling."),
        PlatformTarget(name: "YouTube",     lufs: -14, truePeakDBTP: -1, note: "Playback normalizes to ~-14 LUFS."),
        PlatformTarget(name: "Tidal",       lufs: -14, truePeakDBTP: -1, note: "Normalizes to -14 LUFS."),
        PlatformTarget(name: "Amazon",      lufs: -14, truePeakDBTP: -2, note: "Amazon Music targets -14 LUFS; slightly lower ceiling."),
        PlatformTarget(name: "SoundCloud",  lufs:  -9, truePeakDBTP: -1, note: "Minimal / inconsistent normalization — many EDM masters run hot (~-9 LUFS)."),
        PlatformTarget(name: "Club / DJ",   lufs:  -6, truePeakDBTP: -1, note: "Loud, no normalization; hot master for DJ playout."),
    ]

    /// Sensible default for a streaming-first melodic-techno release.
    static let `default`: PlatformTarget = all.first { $0.name == "Spotify" } ?? all[0]
}

// MARK: - Genre / tonal targets

/// A per-genre mastering target: a corrective tonal curve plus loudness, peak, mono, and width goals.
struct GenreTarget: Identifiable, Equatable {
    var id: String { name }
    var name: String
    var bands: [EQBand]        // corrective/tonal target curve applied by the master chain
    var targetLUFS: Double
    var truePeakDBTP: Double
    var lowMonoHz: Double       // fold everything below this to mono for a tight low end
    var stereoWidth: Double     // 1.0 = unchanged; >1 wider, <1 narrower
}

enum GenreTargets {
    /// Modern tech-house target: punchy kick/bass relationship, cleaned low-mids, vocal/lead presence, bright hats/FX, mono club low end.
    static let modernTechHouse = GenreTarget(
        name: "Modern Tech House",
        bands: [
            .highPass(28, 0.707),
            .peak(75, 1.2, 0.9),
            .peak(300, -2.0, 1.0),
            .peak(900, 0.8, 0.9),
            .peak(4000, 1.8, 0.9),
            .highShelf(12000, 1.8),
        ],
        targetLUFS: -7,
        truePeakDBTP: -1.0,
        lowMonoHz: 120,
        stereoWidth: 1.18
    )

    /// The user's HNTR / Anyma-style reference profile: tight sub, scooped low-mids, present top, airy sheen, wide and loud.
    static let melodicTechno = GenreTarget(
        name: "Melodic Techno / EDM",
        bands: [
            .highPass(28, 0.707),     // clear rumble below the kick fundamental
            .peak(45, -1.0, 0.9),     // control the sub so the kick punches instead of booming
            .peak(250, -2.0, 1.0),    // scoop low-mid mud / boxiness
            .peak(600, -1.5, 1.0),    // tame honk in the low-mids
            .peak(4000, 2.0, 0.9),    // presence / synth + pluck bite
            .highShelf(11000, 2.5),   // air / sheen on top
        ],
        targetLUFS: -8,
        truePeakDBTP: -1.0,
        lowMonoHz: 120,
        stereoWidth: 1.15
    )

    static let pop = GenreTarget(
        name: "Pop",
        bands: [
            .highPass(30, 0.707),
            .peak(300, -1.0, 1.0),    // clean the low-mids
            .peak(3000, 1.5, 0.9),    // vocal presence
            .highShelf(12000, 2.0),   // sparkle
        ],
        targetLUFS: -9,
        truePeakDBTP: -1.0,
        lowMonoHz: 100,
        stereoWidth: 1.05
    )

    static let hipHop = GenreTarget(
        name: "Hip-Hop",
        bands: [
            .highPass(25, 0.707),
            .lowShelf(60, 1.5),       // weight under the 808
            .peak(400, -1.5, 1.0),    // clear muddy low-mids
            .peak(3000, 1.0, 0.9),    // vocal intelligibility
            .highShelf(10000, 1.5),
        ],
        targetLUFS: -8,
        truePeakDBTP: -1.0,
        lowMonoHz: 110,
        stereoWidth: 1.0
    )

    static let rock = GenreTarget(
        name: "Rock",
        bands: [
            .highPass(30, 0.707),
            .peak(200, -1.0, 1.0),    // trim boom
            .peak(2500, 1.5, 0.9),    // guitar/snare crack
            .highShelf(11000, 1.5),
        ],
        targetLUFS: -10,
        truePeakDBTP: -1.0,
        lowMonoHz: 100,
        stereoWidth: 1.0
    )

    static let neutral = GenreTarget(
        name: "Acoustic / Neutral",
        bands: [
            .highPass(24, 0.707),     // gentle infrasonic cleanup only
        ],
        targetLUFS: -14,
        truePeakDBTP: -1.0,
        lowMonoHz: 80,
        stereoWidth: 1.0
    )

    /// Jazz: preserve the natural dynamics and room. Only gentle corrective tone — unbox the
    /// upright/piano low-mids, lift brushed-kit and horn presence, a touch of cymbal air. Kept
    /// open (−14 LUFS) and never crushed; the low end stays mostly natural (mono only below 80 Hz).
    static let jazz = GenreTarget(
        name: "Jazz",
        bands: [
            .highPass(26, 0.707),     // clear infrasonic rumble under the bass
            .peak(200, -0.8, 1.0),    // gently unbox the upright/piano low-mids
            .peak(2500, 0.8, 0.9),    // brushed-snare + horn presence
            .highShelf(12000, 1.0),   // cymbal air, kept subtle
        ],
        targetLUFS: -14,              // preserve dynamics — natural, uncrushed
        truePeakDBTP: -1.0,
        lowMonoHz: 80,
        stereoWidth: 1.05             // keep the room's natural stereo image
    )

    /// Orchestral / cinematic: protect the widest dynamic range of any target. Infrasonic
    /// cleanup, a hair of low-mid clarity for large sections, gentle string/brass definition,
    /// hall air. Very open (−16 LUFS), and never widened — an acoustically-recorded stage keeps
    /// its own image; only the deep low strings fold to mono (below 60 Hz).
    static let orchestral = GenreTarget(
        name: "Orchestral / Cinematic",
        bands: [
            .highPass(22, 0.707),     // infrasonic cleanup only — protect dynamic range
            .peak(300, -0.6, 1.0),    // slight low-mid clarity for large sections
            .peak(4000, 0.6, 0.9),    // string/brass definition, gentle
            .highShelf(14000, 0.8),   // hall air
        ],
        targetLUFS: -16,              // film/score dynamics — very open
        truePeakDBTP: -1.0,
        lowMonoHz: 60,                // keep the low strings' natural width
        stereoWidth: 1.0              // never widen an acoustically-recorded stage
    )

    static let all: [GenreTarget] = [modernTechHouse, melodicTechno, pop, hipHop, rock, neutral, jazz, orchestral]

    // modernTechHouse is a SELECTABLE target (present in `all`), reached via the Westend Tech
    // House style or an explicit tech-house reference — NOT the out-of-box default.
    /// Default profile for this app's primary user — unchanged from build 2 (782efdf).
    /// Flipping this is a customer-facing default change and is founder/§3-gated.
    static let `default`: GenreTarget = melodicTechno
}
