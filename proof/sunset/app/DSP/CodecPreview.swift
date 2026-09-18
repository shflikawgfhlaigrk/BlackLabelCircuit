// CodecPreview.swift — SS-25 "Hear the codec before you export": a real encode→decode round-trip so
// the buyer auditions the artifacts a lossy transcode will introduce BEFORE they ship the master.
//
// Honest by construction:
//   1. Encode — the finished WAV master is encoded to AAC (.m4a) at a chosen bitrate using the SAME
//      CoreAudio-native AAC path proven in SS-07 (AudioIO.encodeCompressed). No vendored codec.
//   2. Decode — the .m4a is decoded straight back to Float PCM (AudioIO.load). What returns is exactly
//      what a streaming platform / phone would play: band-limited, quantized, MDCT-smeared.
//   3. A/B at equal loudness — the decoded render is loudness-matched to the WAV master (via
//      DSP/LoudnessMatch / DSP/DeltaAudition, BS.1770) so "the codec sounds different" can never be
//      "the codec is quieter". The residual (master − matched codec render) is the AUDIBLE artifact.
//
// MP3 honesty: there is NO licensed MP3 encoder in this tree (LAME needs a license ruling), so this
// ships AAC-only and says so — `mp3Note`. We never paint a fake "MP3 preview" from an AAC render.

import Foundation
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(AudioToolbox) && !CIRCUIT_WINDOWS_SIM
import AudioToolbox
#endif

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum CodecPreview {

    /// The honest label shown in-code and in-UI: AAC is the only real lossy encoder we can ship.
    static let uiLabel = "AAC preview; MP3 encoder not licensed"
    static let mp3Note = "No licensed MP3 encoder in-tree — codec preview is AAC-only (honest, not faked)."

    /// The common streaming/transcode rungs the buyer can audition. 128 = aggressive (radio/some
    /// social), 256 = transparent-ish (Apple Music / high-quality). Both are real CoreAudio AAC.
    static let bitratesKbps = [128, 256]

    struct Audition {
        var bitrateKbps: Int            // the AAC bitrate this render was encoded at
        var decoded: AudioSignal        // the codec render, decoded back to PCM (raw playback)
        var matchedDecoded: AudioSignal // decoded, loudness-matched to the master for equal-loudness A/B
        var residual: DeltaAudition.Residual // master − matched codec render: the audible artifact
        var codecLabel: String          // honest codec identity (AAC-only; MP3 not licensed)
        var hasData: Bool               // false when the master is empty or the round-trip failed
    }

    /// Encode `master` to AAC at `bitrateKbps`, decode it back, and measure the artifact residual
    /// against the master. `workDir` receives a temp .m4a (removed after decode). Returns nil only
    /// when the master is empty; a failed encode/decode returns an honest empty-data Audition.
    static func audition(master: AudioSignal, bitrateKbps: Int, workDir: URL? = nil) -> Audition? {
        guard master.frameCount > 0, master.channelCount > 0 else { return nil }

        let dir = workDir ?? FileManager.default.temporaryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("codec_preview_\(bitrateKbps)kbps.m4a")
        try? FileManager.default.removeItem(at: url)

        // 1. Encode to AAC at the requested bitrate (same path SS-07 proved).
        do {
            try AudioIO.encodeCompressed(master, to: url, formatID: kAudioFormatMPEG4AAC,
                                         bitDepth: nil, bitrate: bitrateKbps * 1000)
        } catch {
            return emptyAudition(bitrateKbps: bitrateKbps, master: master)
        }

        // 2. Decode straight back to PCM — this is what the platform would actually play.
        guard let decoded = try? AudioIO.load(url) else {
            try? FileManager.default.removeItem(at: url)
            return emptyAudition(bitrateKbps: bitrateKbps, master: master)
        }
        try? FileManager.default.removeItem(at: url)

        // 3. Residual = master − aligned, loudness-matched codec render. AAC carries encoder priming
        //    (~2112 samples at 44.1 kHz), so we widen the alignment search well past the SS-18 default.
        let residual = DeltaAudition.residual(original: master, master: decoded, maxLagSamples: 6000)

        // Equal-loudness A/B render: apply the SAME measured match gain DeltaAudition used, so the
        // buyer compares TONE, not level, when they toggle WAV master ↔ codec render.
        let g = Float(pow(10.0, residual.matchGainDB / 20.0))
        let matched = AudioSignal(channels: decoded.channels.map { ch in ch.map { $0 * g } },
                                  sampleRate: decoded.sampleRate)

        return Audition(bitrateKbps: bitrateKbps, decoded: decoded, matchedDecoded: matched,
                        residual: residual, codecLabel: uiLabel, hasData: residual.hasData)
    }

    /// Audition every standard bitrate rung in one call (128 + 256 kbps), lowest first.
    static func auditionAll(master: AudioSignal, workDir: URL? = nil) -> [Audition] {
        bitratesKbps.compactMap { audition(master: master, bitrateKbps: $0, workDir: workDir) }
    }

    // MARK: - helpers

    private static func emptyAudition(bitrateKbps: Int, master: AudioSignal) -> Audition {
        let empty = AudioSignal(channels: [], sampleRate: master.sampleRate)
        let noRes = DeltaAudition.Residual(signal: empty, lagSamples: 0, matchGainDB: 0,
                                           residualRMSDBFS: -200, hasData: false)
        return Audition(bitrateKbps: bitrateKbps, decoded: empty, matchedDecoded: empty,
                        residual: noRes, codecLabel: uiLabel, hasData: false)
    }
}
#endif // circuit-convert
