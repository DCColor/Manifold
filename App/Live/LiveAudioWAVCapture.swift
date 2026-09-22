//
//  LiveAudioWAVCapture.swift
//  Manifold
//
//  DEBUG-ONLY. Writes the EXACT interleaved Int32 bytes a live transport hands to
//  `AudioTapBuffer` to a .wav, so they can be listened to somewhere other than through the app
//  that is under suspicion.
//
//  ── WHY THIS EXISTS, AND WHAT HAS ALREADY BEEN ELIMINATED ──────────────────────────────────────
//
//  SRT audio from Cloudflare is gravel. Everything cheaper than looking at the samples has been
//  ruled out, and each one is recorded here so nobody spends an evening re-eliminating it:
//
//    * THE TRANSPORT IS FINE — the same stream plays clean in another client.
//    * THE FRAMING IS FINE — `[SRT-AUDIO-PROBE]` read the packets as received: 7-byte ADTS header,
//      `frame_length` matching the packet, `rdblocks = 0`, 1024 frames × 2 ch.
//    * THE DECODER IS FINE — and this line once read "decode is libavcodec now", because the
//      decoder swap was in force while this file was written. It was reverted: the fault was the
//      sender's PTS grid, upstream of every decoder, and AudioToolbox was then measured clean on
//      the same feed. See `SRTAudioDecoder`'s header.
//    * THE TIMING IS FINE — `timebase−clock` holds within 5 ms, with frame counts and PTS agreeing
//      to the sample.
//    * THE LEVEL IS IRRELEVANT — this is not quiet or loud audio, it is wrong audio.
//    * THE FLOAT→INT CONVERSION IS FINE — local SRT runs through the identical `swr_convert` and
//      is clean.
//
//  What is left is the samples themselves. This writes them down.
//
//  ── ⚠️ THE FILE MUST CONTAIN THE GARBAGE, IF THERE IS GARBAGE ──────────────────────────────────
//
//  There is no conversion, no normalisation, no resampling and no clamping anywhere in this file.
//  The bytes are copied out of the `CMSampleBuffer`'s own block buffer at the handoff point and
//  land in the `data` chunk unaltered; the 44-byte header is a container for them, not a
//  transformation of them. A capture that quietly repaired its input would be worse than no
//  capture at all — it would prove the samples were fine.
//
//  ⚠️ `CMBlockBufferCopyDataBytes`, NOT `CMBlockBufferGetDataPointer`. A block buffer may be
//  non-contiguous; the pointer form hands back only the run at that offset, and `lengthAtOffset`
//  can be less than `totalLength`. Copying is the form that cannot silently truncate — and a
//  diagnostic that truncated would manufacture exactly the discontinuities being hunted.
//
//  ── RELATIONSHIP TO `NDIService`'s CAPTURE ─────────────────────────────────────────────────────
//
//  This is that capture's structure — in-memory buffering, copy at the enqueue point, canonical
//  44-byte PCM header, write on stop — lifted somewhere a second transport can reach it. It is NOT
//  a shared instance of it: the NDI one is `private`, typed on NDI's own state (`toneMode`) and
//  driven from a menu item with a live title. Those are the parts that did not generalise. If the
//  NDI path is ever revisited, it could be reduced to a caller of this and roughly 150 lines would
//  go with it; that is deliberately NOT done here, because it would mean editing a working audio
//  path in a change whose entire purpose is to observe a broken one.
#if DEBUG
import AVFoundation
import ManifoldCore   // UnfairLock

/// ── ARMED BEFORE LAUNCH, BY PREFERENCE. NO MENU ITEM, NO UI. ─────────────────────────────────
///
///     defaults write com.graviton.manifold manifold.captureLiveAudioWAV -bool YES
///
/// or, for a single run that leaves nothing behind:
///
///     MANIFOLD_CAPTURE_LIVE_AUDIO_WAV=1 /Applications/Manifold.app/Contents/MacOS/Manifold
///
/// Same shape as `DebugMenuGate`, for the same reasons: a preference survives relaunch and works
/// with an ordinary double-click, and the environment variable cannot be left on by accident.
///
/// ⚠️ LATCHED ONCE, AT FIRST READ. `static let` with an initialiser closure is evaluated exactly
/// once and is thread-safe. A gate re-read per packet could change under a running capture and
/// leave a half-written file describing a window it did not actually cover.
///
/// ⚠️ IT SAYS SO WHEN IT IS ON AND NOTHING WHEN IT IS OFF. Someone who set this weeks ago and
/// forgot needs the log to explain why .wav files are appearing on their Desktop.
enum LiveAudioWAVCaptureGate {
    static let defaultsKey = "manifold.captureLiveAudioWAV"
    static let environmentVariable = "MANIFOLD_CAPTURE_LIVE_AUDIO_WAV"

    static let isEnabled: Bool = {
        let viaEnvironment = ProcessInfo.processInfo.environment[environmentVariable] == "1"
        let viaPreference = UserDefaults.standard.bool(forKey: defaultsKey)
        guard viaEnvironment || viaPreference else { return false }
        NSLog("[LIVE-AUDIO-WAV] ARMED via %@ — the first %.0f seconds of live audio reaching the "
            + "tap will be written to a .wav on your Desktop, then the capture stops for the rest "
            + "of this launch. Turn it off with: defaults delete com.graviton.manifold %@",
              viaEnvironment ? "\(environmentVariable)=1" : "the \(defaultsKey) preference",
              LiveAudioWAVCapture.captureSeconds, defaultsKey)
        return true
    }()
}

final class LiveAudioWAVCapture {

    /// 10 seconds. Long enough that a fault with any periodicity shows up, short enough to open
    /// without hesitating — and, at 48 kHz stereo 32-bit, ~3.8 MB.
    static let captureSeconds = 10.0

    /// ⚠️ ONE CAPTURE PER LAUNCH, NOT PER CONNECTION. It starts at the first buffer that reaches
    /// the tap, runs `captureSeconds`, writes, and is then permanently done for this process. Two
    /// captures to compare means two launches, which is also what keeps the files unambiguous
    /// about which source produced them — a second file appearing mid-session from a reconnect is
    /// exactly the kind of thing that gets mixed up at 1am.
    private enum State { case waiting, capturing, finished }

    private let lock = UnfairLock()
    private var state: State = .waiting
    private var bytes = [UInt8]()
    private var rate = 0.0
    private var channels = 0
    private var startHost = 0.0
    private let tag: String

    init(tag: String) {
        self.tag = tag
    }

    /// ⚠️ CALLED ON THE SESSION THREAD, AT THE HANDOFF POINT, AND IT MUST NOT BLOCK IT. Everything
    /// here is a lock, a length check and an append into reserved capacity. The file write, the
    /// header and the sample analysis all happen on a background queue after the window closes —
    /// file I/O on the thread that feeds the tap would add its own jitter to the cadence under
    /// investigation, and a measurement that perturbs what it measures is worthless here.
    func capture(_ sb: CMSampleBuffer, sampleRate: Double, channels ch: Int) {
        lock.lock()
        switch state {
        case .finished:
            lock.unlock(); return
        case .waiting:
            state = .capturing
            rate = sampleRate
            channels = ch
            startHost = CACurrentMediaTime()
            // Reserved up front so no append can trigger a reallocation mid-handoff.
            bytes.reserveCapacity(Int(Self.captureSeconds * sampleRate * Double(ch) * 4) + 1024)
            let r = rate, c = channels
            lock.unlock()
            NSLog("[LIVE-AUDIO-WAV] capture STARTED — %.0f Hz · %d ch · 32-bit signed int, "
                + "%.0f s. These are the exact bytes handed to AudioTapBuffer, copied at the "
                + "handoff with no conversion of any kind.", r, c, Self.captureSeconds)
            lock.lock()
        case .capturing:
            break
        }

        // A format change mid-capture would leave one WAV header describing two formats. Stop and
        // write what was captured before the change rather than a file that misrepresents itself.
        guard rate == sampleRate, channels == ch else {
            let oldRate = rate, oldCh = channels
            state = .finished
            let captured = bytes
            bytes = []
            lock.unlock()
            NSLog("[LIVE-AUDIO-WAV] ⚠️ format changed mid-capture (%.0f Hz·%d ch → %.0f Hz·%d ch) "
                + "— writing what was captured before the change.",
                  oldRate, oldCh, sampleRate, ch)
            write(captured, rate: oldRate, channels: oldCh)
            return
        }

        let elapsed = CACurrentMediaTime() - startHost
        if elapsed >= Self.captureSeconds {
            state = .finished
            let captured = bytes
            let r = rate, c = channels
            bytes = []
            lock.unlock()
            write(captured, rate: r, channels: c)
            return
        }

        if let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            if len > 0 {
                let start = bytes.count
                bytes.append(contentsOf: repeatElement(UInt8(0), count: len))
                bytes.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len,
                                                   destination: raw.baseAddress!.advanced(by: start))
                }
            }
        }
        lock.unlock()
    }

    // MARK: - Writing, off the session thread

    private func write(_ data: [UInt8], rate: Double, channels: Int) {
        DispatchQueue.global(qos: .utility).async {
            guard !data.isEmpty, rate > 0, channels > 0 else {
                NSLog("[LIVE-AUDIO-WAV] capture ended with nothing recorded.")
                return
            }
            let stamp = ISO8601DateFormatter()
            stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
            // Colons are legal in HFS+ filenames but display as "/" in Finder — swap them out so
            // the name reads as a timestamp rather than as a path.
            let when = stamp.string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let name = "Manifold-\(self.tag)-audio-\(when).wav"
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop").appendingPathComponent(name)

            var file = Self.wavHeader(dataBytes: data.count, sampleRate: rate, channels: channels)
            file.append(contentsOf: data)

            let stats = Self.analyse(data)
            let frames = data.count / (channels * 4)
            do {
                try Data(file).write(to: url)
                NSLog("""
                      [LIVE-AUDIO-WAV] WRITTEN → %@
                                       %d frames · %.3f s · %.0f Hz · %d ch · 32-bit signed int · %.1f MB
                                       peak |sample| = %llu (%.2f dBFS)
                                       at/within 1%% of Int32 min/max: %llu of %llu samples (%.4f%%)
                                       %@
                      """,
                      url.path, frames, Double(frames) / rate, rate, channels,
                      Double(file.count) / 1_048_576,
                      stats.peak, stats.peakDBFS, stats.nearFullScale, stats.total,
                      stats.total > 0 ? 100.0 * Double(stats.nearFullScale) / Double(stats.total) : 0,
                      stats.verdict)
            } catch {
                NSLog("[LIVE-AUDIO-WAV] write FAILED at %@ — %@",
                      url.path, error.localizedDescription)
            }
        }
    }

    // MARK: - Sample statistics

    /// ── WHAT THE LOG HAS TO ANSWER WITHOUT OPENING THE FILE ───────────────────────────────────
    ///
    /// Two failure shapes are visible as pure counting and are worth ruling in or out before
    /// anybody puts headphones on:
    ///
    ///   * CLIPPING — the signal genuinely reaches full scale and is squared off there. Shows as a
    ///     large `nearFullScale` count spread through the file.
    ///   * WRAPPING — a value overflowed and came back with the opposite sign. Also produces
    ///     near-full-scale samples, but the giveaway is ADJACENT samples at opposite extremes,
    ///     which is why `signFlipsAtScale` is counted separately. A clipped signal sits at one rail;
    ///     a wrapped one slams between them.
    ///
    /// ⚠️ NEITHER IS THE EXPECTED ANSWER. Level was eliminated before this file was written. If
    /// these counts come back at zero, that is information — it says the damage is not amplitude
    /// and the file has to be listened to.
    private struct Stats {
        var peak: UInt64 = 0
        var peakDBFS: Double = 0
        var nearFullScale: UInt64 = 0
        var signFlipsAtScale: UInt64 = 0
        var total: UInt64 = 0
        var verdict = ""
    }

    /// `Int32.max` less 1% of it. `Int32.min`'s magnitude is 2147483648, one greater than
    /// `Int32.max`, so comparing MAGNITUDES covers both rails with one threshold and cannot trap
    /// on `abs(Int32.min)`.
    private static let nearFullScaleThreshold: UInt64 = 2_126_008_811   // 2147483647 - 21474836

    private static func analyse(_ data: [UInt8]) -> Stats {
        var s = Stats()
        let count = data.count / 4
        guard count > 0 else { return s }
        s.total = UInt64(count)

        var previousAtScale = 0    // -1, 0 or +1: the sign of the last near-full-scale sample
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                // Read the four bytes by hand rather than binding the buffer to Int32: the array's
                // base address carries no guarantee of 4-byte alignment, and `loadUnaligned` is the
                // form that is correct either way.
                let v = raw.loadUnaligned(fromByteOffset: i * 4, as: Int32.self)
                let magnitude = UInt64(Int64(v).magnitude)
                if magnitude > s.peak { s.peak = magnitude }
                if magnitude >= nearFullScaleThreshold {
                    s.nearFullScale += 1
                    let sign = v < 0 ? -1 : 1
                    if previousAtScale != 0 && sign != previousAtScale { s.signFlipsAtScale += 1 }
                    previousAtScale = sign
                } else {
                    previousAtScale = 0
                }
            }
        }

        let fullScale = 2_147_483_648.0
        s.peakDBFS = s.peak == 0 ? -.infinity : 20.0 * log10(Double(s.peak) / fullScale)

        if s.nearFullScale == 0 {
            s.verdict = "No sample reaches the rails — the damage, if any, is NOT clipping or "
                      + "wrapping. Listen to the file."
        } else if s.signFlipsAtScale > s.nearFullScale / 10 {
            s.verdict = "⚠️ \(s.signFlipsAtScale) adjacent sign flips AT FULL SCALE — that is the "
                      + "signature of WRAPPING, not clipping. A value overflowed."
        } else {
            s.verdict = "⚠️ Samples sit at the rails without slamming between them — consistent "
                      + "with CLIPPING rather than wrapping."
        }
        return s
    }

    /// A 44-byte canonical PCM WAV header. Little-endian throughout, format tag 1 (PCM integer),
    /// 32 bits per sample — matching what the buffers actually carry
    /// (`kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked`, `mBitsPerChannel = 32`), so
    /// the file is a faithful container for the bytes rather than a conversion of them.
    private static func wavHeader(dataBytes: Int, sampleRate: Double, channels: Int) -> [UInt8] {
        var h = [UInt8]()
        func u32(_ v: UInt32) { h.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                                                      UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func u16(_ v: UInt16) { h.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        func ascii(_ s: String) { h.append(contentsOf: Array(s.utf8)) }

        let blockAlign = UInt16(channels * 4)
        ascii("RIFF"); u32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); u32(16)
        u16(1)                                  // PCM integer
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate) * UInt32(blockAlign))   // byte rate
        u16(blockAlign)
        u16(32)                                 // bits per sample
        ascii("data"); u32(UInt32(dataBytes))
        return h
    }
}
#endif
