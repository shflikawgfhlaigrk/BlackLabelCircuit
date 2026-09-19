// AudioFileIO.swift — load/write audio as deinterleaved Float channels + a test-tone generator.
import Foundation
#if canImport(AVFoundation) && !CIRCUIT_WINDOWS_SIM
import AVFoundation
#endif
#if canImport(AudioToolbox) && !CIRCUIT_WINDOWS_SIM
import AudioToolbox
#endif
import CircuitPortKit

// The shared audio container. Deinterleaved: channels[ch][sample], Float in [-1, 1].
struct AudioSignal {
    var channels: [[Float]]
    var sampleRate: Double

    var frameCount: Int { channels.first?.count ?? 0 }
    var channelCount: Int { channels.count }

    init(channels: [[Float]], sampleRate: Double) {
        self.channels = channels
        self.sampleRate = sampleRate
    }

    // RMS level of one channel, in dBFS. Empty/silent → -inf clamped to -200.
    func rmsDBFS(channel: Int) -> Double {
        guard channel >= 0, channel < channels.count else { return -200 }
        let buf = channels[channel]
        guard !buf.isEmpty else { return -200 }
        var sumSq = 0.0
        for s in buf { let d = Double(s); sumSq += d * d }
        let rms = (sumSq / Double(buf.count)).squareRoot()
        guard rms > 0 else { return -200 }
        return max(-200, 20 * log10(rms))
    }

    // Absolute sample peak across ALL channels, in dBFS.
    func peakDBFS() -> Double {
        var peak = 0.0
        for ch in channels {
            for s in ch { let a = abs(Double(s)); if a > peak { peak = a } }
        }
        guard peak > 0 else { return -200 }
        return max(-200, 20 * log10(peak))
    }
}

enum AudioIOError: Error, LocalizedError {
    case cannotOpen(URL, String)
    case emptyFile(URL)
    case unsupportedFormat(String)
    case conversionFailed(String)
    case cannotCreate(URL, String)
    case writeFailed(String)
    case badBitDepth(Int)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let u, let m):     return "Cannot open \(u.lastPathComponent): \(m)"
        case .emptyFile(let u):             return "File is empty: \(u.lastPathComponent)"
        case .unsupportedFormat(let m):     return "Unsupported format: \(m)"
        case .conversionFailed(let m):      return "Audio conversion failed: \(m)"
        case .cannotCreate(let u, let m):   return "Cannot create \(u.lastPathComponent): \(m)"
        case .writeFailed(let m):           return "Write failed: \(m)"
        case .badBitDepth(let b):           return "Unsupported bit depth \(b) (use 16 or 24)"
        }
    }
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
enum AudioIO {

    // Load any AVFoundation-readable file into deinterleaved Float32 channels at its native rate.
    static func load(_ url: URL) throws -> AudioSignal {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioIOError.cannotOpen(url, error.localizedDescription)
        }

        let srcFormat = file.processingFormat
        let total = file.length
        guard total > 0 else { throw AudioIOError.emptyFile(url) }

        let sampleRate = srcFormat.sampleRate
        let channelCount = Int(srcFormat.channelCount)
        guard channelCount > 0 else { throw AudioIOError.unsupportedFormat("0 channels") }

        // Target: non-interleaved Float32 at the SAME sample rate — easy to slice into [[Float]].
        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: srcFormat.channelCount,
                                            interleaved: false) else {
            throw AudioIOError.unsupportedFormat("cannot build Float32 target format")
        }

        // Fast path: file already reads as non-interleaved Float32 → read straight in.
        if formatsMatch(srcFormat, dstFormat) {
            return try readNonInterleavedFloat32(file: file, format: dstFormat, frames: AVAudioFrameCount(total))
        }

        // Otherwise convert (handles Int16/Int24/Int32, interleaved, other float layouts).
        return try convertAndRead(file: file, src: srcFormat, dst: dstFormat, totalFrames: total)
    }

    // Write WAV/AIFF (by extension) at 16 or 24-bit integer PCM. Samples clamped to [-1,1] first.
    static func write(_ signal: AudioSignal, to url: URL, bitDepth: Int) throws {
        guard bitDepth == 16 || bitDepth == 24 else { throw AudioIOError.badBitDepth(bitDepth) }
        let channels = max(1, signal.channelCount)
        let frames = signal.frameCount
        let sampleRate = signal.sampleRate

        let isAIFF = url.pathExtension.lowercased() == "aiff" || url.pathExtension.lowercased() == "aif"
        let formatID = isAIFF ? kAudioFormatLinearPCM : kAudioFormatLinearPCM
        // AIFF is big-endian by convention; WAV little-endian.
        let bigEndian = isAIFF

        let settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: bigEndian,
            AVLinearPCMIsNonInterleaved: false
        ]

        // Encode as interleaved Int (matches the settings above) so the writer does no extra conversion.
        guard let outFormat = AVAudioFormat(settings: settings) else {
            throw AudioIOError.cannotCreate(url, "invalid output settings")
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioIOError.cannotCreate(url, error.localizedDescription)
        }

        guard frames > 0 else { return } // empty signal → valid header, no frames

        // Feed the writer non-interleaved Float32 (its native processing format); it converts to the int settings.
        guard let procFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: sampleRate,
                                             channels: AVAudioChannelCount(channels),
                                             interleaved: false) else {
            throw AudioIOError.writeFailed("cannot build processing format")
        }
        _ = outFormat // settings already applied to file; procFormat is what we hand buffers in

        let chunk = 65536
        var offset = 0
        while offset < frames {
            let n = min(chunk, frames - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: AVAudioFrameCount(n)) else {
                throw AudioIOError.writeFailed("buffer alloc failed")
            }
            buf.frameLength = AVAudioFrameCount(n)
            guard let dst = buf.floatChannelData else {
                throw AudioIOError.writeFailed("no float channel data")
            }
            for ch in 0..<channels {
                let src = ch < signal.channels.count ? signal.channels[ch] : []
                let out = dst[ch]
                for i in 0..<n {
                    let idx = offset + i
                    var v: Float = idx < src.count ? src[idx] : 0
                    if v > 1 { v = 1 } else if v < -1 { v = -1 }
                    out[i] = v
                }
            }
            do { try file.write(from: buf) }
            catch { throw AudioIOError.writeFailed(error.localizedDescription) }
            offset += n
        }
    }

    // Test-tone generator for verification (sine at given freq/amp, N channels).
    static func sine(freq: Double, seconds: Double, sampleRate: Double,
                     channels: Int = 2, amp: Float = 0.5) -> AudioSignal {
        let ch = max(1, channels)
        let n = max(0, Int(seconds * sampleRate))
        let a = min(1, max(0, amp))
        let w = 2.0 * Double.pi * freq / sampleRate
        var one = [Float](repeating: 0, count: n)
        for i in 0..<n { one[i] = Float(Double(a) * sin(w * Double(i))) }
        return AudioSignal(channels: Array(repeating: one, count: ch), sampleRate: sampleRate)
    }

    // MARK: - Private read helpers

    private static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        return a.commonFormat == .pcmFormatFloat32
            && !a.isInterleaved
            && a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
    }

    private static func readNonInterleavedFloat32(file: AVAudioFile,
                                                  format: AVAudioFormat,
                                                  frames: AVAudioFrameCount) throws -> AudioSignal {
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw AudioIOError.conversionFailed("read buffer alloc failed")
        }
        do { try file.read(into: buf) }
        catch { throw AudioIOError.cannotOpen(file.url, error.localizedDescription) }
        return signalFromBuffer(buf)
    }

    private static func convertAndRead(file: AVAudioFile,
                                       src: AVAudioFormat,
                                       dst: AVAudioFormat,
                                       totalFrames: AVAudioFramePosition) throws -> AudioSignal {
        guard let converter = AVAudioConverter(from: src, to: dst) else {
            throw AudioIOError.conversionFailed("no converter \(src) -> \(dst)")
        }

        let channelCount = Int(dst.channelCount)
        var out = [[Float]](repeating: [], count: channelCount)
        for c in 0..<channelCount { out[c].reserveCapacity(Int(totalFrames)) }

        let readChunk: AVAudioFrameCount = 65536
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: readChunk) else {
            throw AudioIOError.conversionFailed("input buffer alloc failed")
        }

        var reachedEnd = false
        while !reachedEnd {
            inBuf.frameLength = 0
            do { try file.read(into: inBuf, frameCount: readChunk) }
            catch { throw AudioIOError.cannotOpen(file.url, error.localizedDescription) }

            if inBuf.frameLength == 0 { break } // EOF

            // Same sample rate → 1:1 frame capacity is enough.
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: inBuf.frameLength) else {
                throw AudioIOError.conversionFailed("output buffer alloc failed")
            }

            var supplied = false
            var convErr: NSError?
            let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
                if supplied {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                outStatus.pointee = .haveData
                return inBuf
            }

            if let e = convErr { throw AudioIOError.conversionFailed(e.localizedDescription) }
            if status == .error { throw AudioIOError.conversionFailed("converter error") }

            appendBuffer(outBuf, into: &out)

            if inBuf.frameLength < readChunk { reachedEnd = true }
        }

        if out.allSatisfy({ $0.isEmpty }) {
            throw AudioIOError.emptyFile(file.url)
        }
        return AudioSignal(channels: out, sampleRate: dst.sampleRate)
    }

    private static func signalFromBuffer(_ buf: AVAudioPCMBuffer) -> AudioSignal {
        let channelCount = Int(buf.format.channelCount)
        let n = Int(buf.frameLength)
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: channelCount)
        if let data = buf.floatChannelData {
            for c in 0..<channelCount {
                let p = data[c]
                for i in 0..<n { out[c][i] = p[i] }
            }
        }
        return AudioSignal(channels: out, sampleRate: buf.format.sampleRate)
    }

    private static func appendBuffer(_ buf: AVAudioPCMBuffer, into out: inout [[Float]]) {
        let channelCount = min(Int(buf.format.channelCount), out.count)
        let n = Int(buf.frameLength)
        guard n > 0, let data = buf.floatChannelData else { return }
        for c in 0..<channelCount {
            let p = data[c]
            out[c].append(contentsOf: UnsafeBufferPointer(start: p, count: n))
        }
    }
}
#endif // circuit-convert

// MARK: - Export breadth (SS-07 / SS-08): format, bit-depth, sample-rate, metadata.
//
// WAV/AIFF (lossless PCM, 16/24-bit) and — via CoreAudio-native encoders, no vendored codecs —
// AAC (.m4a) and FLAC (.flac). MP3 is NOT in CoreAudio's encoder set and is intentionally omitted
// (no LAME without a license ruling). Sample-rate changes go through a real AVAudioConverter SRC,
// never a naive stride, so 44.1↔48 kHz is band-limited and honest.

/// A delivery container the buyer can pick. `pcm` covers WAV/AIFF (extension decides endianness).
enum ExportFormat: String, CaseIterable, Identifiable, Codable {
    case wav, aiff, aac, flac
    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .wav:  return "wav"
        case .aiff: return "aiff"
        case .aac:  return "m4a"   // AAC lives in an MPEG-4 container
        case .flac: return "flac"
        }
    }

    var displayName: String {
        switch self {
        case .wav:  return "WAV (PCM)"
        case .aiff: return "AIFF (PCM)"
        case .aac:  return "AAC (.m4a)"
        case .flac: return "FLAC (lossless)"
        }
    }

    /// PCM containers carry a real bit depth; lossy/compressed pick their own internal precision.
    var isPCM: Bool { self == .wav || self == .aiff }
    /// FLAC is lossless with a selectable stored bit depth; WAV/AIFF/FLAC all honor 16/24.
    var honorsBitDepth: Bool { self != .aac }
}

/// Tags embedded where the container supports them (ISRC is the release-critical one for distribution).
struct AudioMetadata: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var isrc: String?

    var hasAny: Bool { [title, artist, album, isrc].contains { !($0 ?? "").isEmpty } }

    static let none = AudioMetadata()
}

/// A full export request: container + PCM bit depth + optional target sample rate (nil = keep source) + tags.
struct ExportSettings {
    var format: ExportFormat = .wav
    var bitDepth: Int = 24               // 16 or 24 (PCM + FLAC)
    var sampleRate: Double? = nil        // nil = keep the master's rate; else 44100 / 48000
    var metadata: AudioMetadata = .none

    static let masterWAV = ExportSettings()
}

#if canImport(Darwin) && !CIRCUIT_WINDOWS_SIM // circuit-convert: Apple platforms only — see CONVERSION.md
extension AudioIO {

    /// Real band-limited sample-rate conversion via AVAudioConverter. Returns the input unchanged
    /// when the target matches (no needless re-encode) or when SRC can't be built.
    static func resample(_ signal: AudioSignal, to targetRate: Double) -> AudioSignal {
        let srcRate = signal.sampleRate > 0 ? signal.sampleRate : 44100
        guard targetRate > 0, abs(srcRate - targetRate) > 0.5, signal.frameCount > 0 else { return signal }
        let ch = max(1, signal.channelCount)
        guard let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: srcRate,
                                         channels: AVAudioChannelCount(ch), interleaved: false),
              let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                         channels: AVAudioChannelCount(ch), interleaved: false),
              let conv = AVAudioConverter(from: srcFmt, to: dstFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt,
                                           frameCapacity: AVAudioFrameCount(signal.frameCount)) else { return signal }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        inBuf.frameLength = AVAudioFrameCount(signal.frameCount)
        if let d = inBuf.floatChannelData {
            for c in 0..<ch {
                let src = signal.channels[min(c, signal.channelCount - 1)]
                let p = d[c]
                for i in 0..<signal.frameCount { p[i] = i < src.count ? src[i] : 0 }
            }
        }
        var out = [[Float]](repeating: [], count: ch)
        let ratio = targetRate / srcRate
        let outCap = AVAudioFrameCount(Double(signal.frameCount) * ratio + 8192)
        var provided = false
        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: outCap) else { break }
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, inStatus in
                if provided { inStatus.pointee = .noDataNow; return nil }
                provided = true; inStatus.pointee = .haveData; return inBuf
            }
            if let d = outBuf.floatChannelData, outBuf.frameLength > 0 {
                for c in 0..<ch {
                    out[c].append(contentsOf: UnsafeBufferPointer(start: d[c], count: Int(outBuf.frameLength)))
                }
            }
            if status == .haveData { continue }
            break   // .inputRanDry (flushed) / .endOfStream / .error
        }
        if out.allSatisfy({ $0.isEmpty }) { return signal }
        return AudioSignal(channels: out, sampleRate: targetRate)
    }

    /// The single export entry point. Resamples if asked, then writes the chosen container, then
    /// best-effort embeds metadata. Throws on a real write failure; metadata embed never throws.
    static func export(_ signal: AudioSignal, to url: URL, settings: ExportSettings) throws {
        let out = settings.sampleRate.map { resample(signal, to: $0) } ?? signal
        switch settings.format {
        case .wav, .aiff:
            try write(out, to: url, bitDepth: settings.bitDepth)
        case .aac:
            try encodeCompressed(out, to: url, formatID: kAudioFormatMPEG4AAC, bitDepth: nil)
        case .flac:
            // FLAC via ExtAudioFile: the AVAudioFile FLAC writer leaves STREAMINFO total-samples
            // unset (streaming encoder), so decoders stop after the first packet. ExtAudioFile
            // finalizes the header on dispose, producing a file real decoders read in full.
            try encodeFLAC(out, to: url, bitDepth: settings.bitDepth)
        }
        embedMetadata(settings.metadata, into: url)
        // FLAC total-samples patch runs LAST: CoreAudio's metadata write (embedMetadata) rewrites the
        // header and would otherwise reset the count we spliced in.
        if settings.format == .flac { patchFLACTotalSamples(url, totalFrames: out.frameCount) }
    }

    /// CoreAudio-native compressed/lossless encode (AAC in MPEG-4, or FLAC). Feeds the writer
    /// non-interleaved Float32 (its processing format); the encoder does the codec conversion.
    static func encodeCompressed(_ signal: AudioSignal, to url: URL,
                                 formatID: AudioFormatID, bitDepth: Int?, bitrate: Int? = nil) throws {
        let channels = max(1, signal.channelCount)
        let sampleRate = signal.sampleRate > 0 ? signal.sampleRate : 44100
        var settings: [String: Any] = [
            AVFormatIDKey: formatID,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels
        ]
        if formatID == kAudioFormatMPEG4AAC {
            // Export default is transparent 256 kbps; the codec-artifact preview (SS-25) passes an
            // explicit bitrate (e.g. 128 kbps) so the buyer can audition what a lower-rate transcode costs.
            settings[AVEncoderBitRateKey] = bitrate ?? 256_000
            settings[AVEncoderAudioQualityKey] = AVAudioQuality.max.rawValue
        } else if formatID == kAudioFormatFLAC {
            settings[AVLinearPCMBitDepthKey] = (bitDepth == 16 ? 16 : 24)
        }

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw AudioIOError.cannotCreate(url, error.localizedDescription)
        }

        let frames = signal.frameCount
        guard frames > 0 else { return }
        let procFormat = file.processingFormat

        let chunk = 65536
        var offset = 0
        while offset < frames {
            let n = min(chunk, frames - offset)
            guard let buf = AVAudioPCMBuffer(pcmFormat: procFormat, frameCapacity: AVAudioFrameCount(n)) else {
                throw AudioIOError.writeFailed("encode buffer alloc failed")
            }
            buf.frameLength = AVAudioFrameCount(n)
            guard let dst = buf.floatChannelData else { throw AudioIOError.writeFailed("no float channel data") }
            let procCh = Int(procFormat.channelCount)
            for ch in 0..<procCh {
                let src = ch < signal.channels.count ? signal.channels[ch] : []
                let outp = dst[ch]
                for i in 0..<n {
                    let idx = offset + i
                    var v: Float = idx < src.count ? src[idx] : 0
                    if v > 1 { v = 1 } else if v < -1 { v = -1 }
                    outp[i] = v
                }
            }
            do { try file.write(from: buf) }
            catch { throw AudioIOError.writeFailed(error.localizedDescription) }
            offset += n
        }
    }

    /// FLAC encode via ExtAudioFile. Client format is interleaved Float32; the encoder converts to
    /// the file's 16/24-bit FLAC. ExtAudioFile writes a correct STREAMINFO frame count on dispose,
    /// so the result decodes in full (unlike the AVAudioFile FLAC path).
    static func encodeFLAC(_ signal: AudioSignal, to url: URL, bitDepth: Int) throws {
        let channels = max(1, signal.channelCount)
        let sr = signal.sampleRate > 0 ? signal.sampleRate : 44100
        let bits: UInt32 = (bitDepth == 16 ? 16 : 24)

        var fileASBD = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatFLAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: bits, mReserved: 0)

        let floatBytesPerFrame = UInt32(MemoryLayout<Float>.size * channels)
        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: sr, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: floatBytesPerFrame, mFramesPerPacket: 1,
            mBytesPerFrame: floatBytesPerFrame, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)

        var ext: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(url as CFURL, kAudioFileFLACType, &fileASBD, nil,
                                                     AudioFileFlags.eraseFile.rawValue, &ext)
        guard createStatus == noErr, let ef = ext else {
            throw AudioIOError.cannotCreate(url, "ExtAudioFile FLAC create failed (\(createStatus))")
        }
        func finish() { if ext != nil { ExtAudioFileDispose(ef); ext = nil } }

        let setStatus = ExtAudioFileSetProperty(ef, kExtAudioFileProperty_ClientDataFormat,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &clientASBD)
        guard setStatus == noErr else { finish(); throw AudioIOError.writeFailed("FLAC client format (\(setStatus))") }

        let frames = signal.frameCount
        guard frames > 0 else { finish(); return }

        let chunk = 65536
        var interleaved = [Float](repeating: 0, count: chunk * channels)
        var offset = 0
        while offset < frames {
            let n = min(chunk, frames - offset)
            for i in 0..<n {
                let idx = offset + i
                for c in 0..<channels {
                    let src = c < signal.channels.count ? signal.channels[c] : []
                    var v: Float = idx < src.count ? src[idx] : 0
                    if v > 1 { v = 1 } else if v < -1 { v = -1 }
                    interleaved[i * channels + c] = v
                }
            }
            let writeStatus: OSStatus = interleaved.withUnsafeMutableBytes { raw -> OSStatus in
                var abl = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                                          mDataByteSize: UInt32(n * channels * MemoryLayout<Float>.size),
                                          mData: raw.baseAddress))
                return ExtAudioFileWrite(ef, UInt32(n), &abl)
            }
            guard writeStatus == noErr else { finish(); throw AudioIOError.writeFailed("FLAC write (\(writeStatus))") }
            offset += n
        }
        finish()                                   // finalize (header patched later, after metadata embed)
    }

    /// CoreAudio's FLAC encoder leaves STREAMINFO `total_samples` = 0 ("unknown length" — legal, but
    /// it makes header-based duration reads (Finder/QuickLook/CoreAudio decoder) wrong even though
    /// every packet decodes). We splice the real count into the low 36 bits of the STREAMINFO packed
    /// field. Best-effort: validated against the FLAC magic + STREAMINFO block type; no-op otherwise.
    private static func patchFLACTotalSamples(_ url: URL, totalFrames: Int) {
        // Read the whole file and rewrite it ATOMICALLY (temp + rename → new inode). ExtAudioFile can
        // leave a lingering fd on the original inode that would clobber an in-place seek/write; the
        // atomic replace sidesteps that race entirely (its stale write lands on the orphaned inode).
        guard totalFrames > 0, var data = try? Data(contentsOf: url), data.count >= 42 else { return }
        // "fLaC" magic and first metadata block must be STREAMINFO (type 0, low 7 bits of byte 4).
        guard data[0] == 0x66, data[1] == 0x4C, data[2] == 0x61, data[3] == 0x43,
              (data[4] & 0x7F) == 0 else { return }
        // 64-bit packed field at bytes 18..25: [sampleRate:20][channels-1:3][bps-1:5][totalSamples:36].
        var packed: UInt64 = 0
        for i in 18..<26 { packed = (packed << 8) | UInt64(data[i]) }
        let mask36: UInt64 = (1 << 36) - 1
        packed = (packed & ~mask36) | (UInt64(totalFrames) & mask36)
        for i in 0..<8 { data[18 + i] = UInt8((packed >> (UInt64(7 - i) * 8)) & 0xFF) }
        try? data.write(to: url, options: .atomic)
    }

    /// Best-effort tag embed via the CoreAudio info dictionary (ISRC/Title/Artist/Album). Silent
    /// no-op when the container rejects a key — never corrupts audio, never throws.
    static func embedMetadata(_ meta: AudioMetadata, into url: URL) {
        guard meta.hasAny else { return }
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readWritePermission, 0, &fileID) == noErr,
              let fid = fileID else { return }
        defer { AudioFileClose(fid) }
        var info: [String: String] = [:]
        if let t = meta.title,  !t.isEmpty { info[kAFInfoDictionary_Title as String]  = t }
        if let a = meta.artist, !a.isEmpty { info[kAFInfoDictionary_Artist as String] = a }
        if let al = meta.album, !al.isEmpty { info[kAFInfoDictionary_Album as String] = al }
        if let i = meta.isrc,   !i.isEmpty { info[kAFInfoDictionary_ISRC as String]   = i }
        guard !info.isEmpty else { return }
        var dict = info as CFDictionary
        let size = UInt32(MemoryLayout<CFDictionary>.size)
        _ = withUnsafeMutablePointer(to: &dict) { ptr in
            AudioFileSetProperty(fid, kAudioFilePropertyInfoDictionary, size, ptr)
        }
    }

    /// Real codec probe for verification: reads back the on-disk stream description (format ID,
    /// sample rate, channels) and frame count. Nil if the file can't be opened.
    struct Probe { var formatID: AudioFormatID; var sampleRate: Double; var channels: Int; var frames: Int64 }
    static func probe(_ url: URL) -> Probe? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let asbd = file.fileFormat.streamDescription.pointee
        return Probe(formatID: asbd.mFormatID,
                     sampleRate: file.fileFormat.sampleRate,
                     channels: Int(file.fileFormat.channelCount),
                     frames: file.length)
    }

    /// Read back embedded tags for verification (best-effort; empty when the container carries none).
    static func readInfoTags(_ url: URL) -> [String: String] {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr,
              let fid = fileID else { return [:] }
        defer { AudioFileClose(fid) }
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        var dict: CFDictionary?
        let status = withUnsafeMutablePointer(to: &dict) { ptr -> OSStatus in
            AudioFileGetProperty(fid, kAudioFilePropertyInfoDictionary, &size, ptr)
        }
        guard status == noErr, let d = dict as? [String: String] else { return [:] }
        return d
    }
}
#endif // circuit-convert
