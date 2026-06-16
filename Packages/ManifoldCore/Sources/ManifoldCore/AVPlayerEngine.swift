import AVFoundation
import AudioToolbox
import Combine

@MainActor
public final class AVPlayerEngine: ObservableObject {

    public let player = AVPlayer()

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentTime: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var displaySize: CGSize?
    @Published public private(set) var hasMedia = false
    @Published public private(set) var metadata: VideoMetadata?

    /// Raw start-timecode info for the loaded clip (nil if no TC track).
    public private(set) var tcInfo: TimecodeReader.Result?

    private var timeObserverToken: Any?
    private var cancellables = Set<AnyCancellable>()

    public init() {
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.isPlaying = (status == .playing)
            }
            .store(in: &cancellables)

        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            let dur = self.player.currentItem?.duration.seconds
            Task { @MainActor in
                self.currentTime = seconds
                if let dur, dur.isFinite { self.duration = dur }
            }
        }

        NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isPlaying = false
            }
            .store(in: &cancellables)
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
    }

    public func load(url: URL) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        currentTime = 0
        duration = 0
        displaySize = nil
        metadata = nil
        tcInfo = nil
        hasMedia = true
        resolveDisplaySize(for: asset)
        resolveMetadata(for: asset, url: url)
    }

    private func resolveDisplaySize(for asset: AVURLAsset) {
        Task {
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let naturalSize = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform)
            else { return }
            let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            let size = CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
            await MainActor.run { self.displaySize = size }
        }
    }

    private func resolveMetadata(for asset: AVURLAsset, url: URL) {
        Task {
            var meta = VideoMetadata()
            meta.container = url.pathExtension.uppercased()

            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                if let naturalSize = try? await track.load(.naturalSize) {
                    meta.width = Int(naturalSize.width.rounded())
                    meta.height = Int(naturalSize.height.rounded())
                }
                if let fps = try? await track.load(.nominalFrameRate), fps > 0 {
                    meta.frameRate = Double(fps)
                }
                if let formats = try? await track.load(.formatDescriptions),
                   let fmt = formats.first {
                    meta.codecName = Self.codecName(for: fmt)
                    let c = Self.colorTags(for: fmt)
                    meta.colorPrimaries = c.primName
                    meta.colorPrimariesCode = c.primCode
                    meta.transferFunction = c.transName
                    meta.transferFunctionCode = c.transCode
                    meta.colorMatrix = c.matrixName
                    meta.colorMatrixCode = c.matrixCode
                }
                if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                    meta.videoDataRate = Double(rate)
                }
            }

            meta.audioTracks = await Self.audioTracks(for: asset)
            let tc = TimecodeReader.readStartTimecode(url: url)
            meta.startTimecode = tc?.timecode
            await MainActor.run { self.tcInfo = tc }
            meta.chapters = await Self.chapters(for: asset)

            let resolved = meta
            await MainActor.run {
                self.metadata = resolved
                print("""
                ── Manifold metadata ──────────
                codec:     \(resolved.codecName)
                size:      \(resolved.resolutionString)
                fps:       \(resolved.frameRateString)
                vid rate:  \(resolved.videoDataRateString)
                container: \(resolved.container)
                nclc:      \(resolved.nclcTriple)
                timecode:  \(resolved.startTimecode ?? "(none)")
                audio:     \(resolved.audioTracks.count) track(s)
                \(resolved.audioTracks.enumerated().map { "  [\($0)] \($1.codecName) · \($1.summary) · \($1.dataRateString)" }.joined(separator: "\n"))
                ───────────────────────────────
                """)
            }
        }
    }

    /// Map the track's FourCC codec code to a friendly name (seeded from Flip's
    /// proven list; falls back to the raw code for anything unmapped).
    private static func codecName(for fmt: CMFormatDescription) -> String {
        let code = CMFormatDescriptionGetMediaSubType(fmt)
        let map: [FourCharCode: String] = [
            fourCC("avc1"): "H.264", fourCC("avc3"): "H.264",
            fourCC("hvc1"): "H.265", fourCC("hev1"): "H.265",
            fourCC("apch"): "ProRes 422 HQ", fourCC("apcn"): "ProRes 422",
            fourCC("apcs"): "ProRes 422 LT", fourCC("apco"): "ProRes 422 Proxy",
            fourCC("ap4h"): "ProRes 4444", fourCC("ap4x"): "ProRes 4444 XQ",
            fourCC("ap4c"): "ProRes 4444",
            fourCC("AVdh"): "DNxHR", fourCC("AVdn"): "DNxHD",
            fourCC("dnxh"): "DNxHR", fourCC("dnxd"): "DNxHD",
            fourCC("v210"): "Uncompressed 10-bit 4:2:2",
            fourCC("2vuy"): "Uncompressed 8-bit 4:2:2",
            fourCC("UYVY"): "Uncompressed 8-bit 4:2:2",
            fourCC("raw "): "Uncompressed RGB",
            fourCC("R10k"): "Uncompressed 10-bit RGB",
            fourCC("R10g"): "Uncompressed 10-bit RGB",
            fourCC("jpeg"): "Motion JPEG",
            fourCC("mp4v"): "MPEG-4",
            fourCC("dvh1"): "Dolby Vision HEVC"
        ]
        if let name = map[code] { return name }
        return fourCCString(code)
    }

    private static func colorTags(for fmt: CMFormatDescription)
        -> (primName: String, primCode: Int?,
            transName: String, transCode: Int?,
            matrixName: String, matrixCode: Int?) {

        func ext(_ key: CFString) -> String? {
            CMFormatDescriptionGetExtension(fmt, extensionKey: key) as? String
        }

        // string constant -> (friendly name, nclc/CICP numeric code)
        let primMap: [String: (String, Int)] = [
            "ITU_R_709_2": ("Rec. 709", 1),
            "ITU_R_2020": ("Rec. 2020", 9),
            "SMPTE_C": ("SMPTE-C", 6),
            "EBU_3213": ("EBU 3213", 5),
            "P3_D65": ("P3 D65", 12),
            "DCI_P3": ("DCI-P3", 11),
            "SMPTE_ST_428_1": ("ST 428-1", 10)
        ]
        let transferMap: [String: (String, Int)] = [
            "ITU_R_709_2": ("Rec. 709", 1),
            "SMPTE_ST_2084_PQ": ("PQ (ST 2084)", 16),
            "ITU_R_2100_HLG": ("HLG", 18),
            "ARIB_STD_B67_HLG": ("HLG", 18),
            "sRGB": ("sRGB", 13),
            "Linear": ("Linear", 8),
            "SMPTE_ST_428_1": ("ST 428-1", 17),
            "SMPTE_240M_1995": ("SMPTE 240M", 7)
        ]
        let matrixMap: [String: (String, Int)] = [
            "ITU_R_709_2": ("Rec. 709", 1),
            "ITU_R_2020": ("Rec. 2020", 9),
            "SMPTE_240M_1995": ("SMPTE 240M", 7),
            "SMPTE_C": ("SMPTE-C / 170M", 6)
        ]

        let primRaw = ext(kCMFormatDescriptionExtension_ColorPrimaries)
        let transRaw = ext(kCMFormatDescriptionExtension_TransferFunction)
        let matrixRaw = ext(kCMFormatDescriptionExtension_YCbCrMatrix)

        let prim = primRaw.map { primMap[$0] ?? ($0, -1) }
        let trans = transRaw.map { transferMap[$0] ?? ($0, -1) }
        let matrix = matrixRaw.map { matrixMap[$0] ?? ($0, -1) }

        func name(_ t: (String, Int)?) -> String { t?.0 ?? "—" }
        func code(_ t: (String, Int)?) -> Int? {
            guard let c = t?.1, c >= 0 else { return nil }
            return c
        }
        return (name(prim), code(prim),
                name(trans), code(trans),
                name(matrix), code(matrix))
    }

    /// Read chapter markers (title + start time) from the asset, if any.
    private static func chapters(for asset: AVURLAsset) async -> [ChapterMarker] {
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        let locale = locales.first ?? Locale.current
        guard let groups = try? await asset.loadChapterMetadataGroups(
            withTitleLocale: locale, containingItemsWithCommonKeys: []
        ) else { return [] }

        var result: [ChapterMarker] = []
        for group in groups {
            let time = group.timeRange.start.seconds
            var title = "Chapter"
            if let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
               let value = (try? await titleItem.load(.stringValue)) ?? nil {
                title = value
            }
            result.append(ChapterMarker(time: time.isFinite ? time : 0, title: title))
        }
        return result
    }

    private static func audioTracks(for asset: AVURLAsset) async -> [AudioTrackInfo] {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return [] }
        var result: [AudioTrackInfo] = []
        for track in tracks {
            var info = AudioTrackInfo()
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                info.dataRate = Double(rate)
            }
            if let formats = try? await track.load(.formatDescriptions), let fmt = formats.first {
                let sub = CMFormatDescriptionGetMediaSubType(fmt)
                info.codecName = audioCodecName(sub)
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee {
                    info.sampleRate = asbd.mSampleRate
                    info.channelCount = Int(asbd.mChannelsPerFrame)
                    if asbd.mBitsPerChannel > 0 {
                        info.bitDepth = Int(asbd.mBitsPerChannel)
                    }
                }
            }
            info.layoutName = VideoMetadata.layoutName(forChannels: info.channelCount)
            result.append(info)
        }
        return result
    }

    private static func audioCodecName(_ code: FourCharCode) -> String {
        switch code {
        case kAudioFormatLinearPCM: return "PCM"
        case kAudioFormatMPEG4AAC: return "AAC"
        case kAudioFormatAppleLossless: return "ALAC"
        case kAudioFormatAC3: return "AC-3"
        case kAudioFormatEnhancedAC3: return "E-AC-3"
        case kAudioFormatFLAC: return "FLAC"
        case kAudioFormatOpus: return "Opus"
        default: return fourCCString(code)
        }
    }

    private static func fourCC(_ s: String) -> FourCharCode {
        var result: FourCharCode = 0
        for ch in s.utf16 { result = (result << 8) + FourCharCode(ch) }
        return result
    }

    private static func fourCCString(_ code: FourCharCode) -> String {
        let chars = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        let s = String(bytes: chars, encoding: .macOSRoman) ?? "????"
        return "'\(s)'"
    }

    public func play() { player.play() }
    public func pause() { player.pause() }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func scrubSeek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .positiveInfinity, toleranceAfter: .positiveInfinity)
    }

    public func exactSeek(to seconds: Double) {
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Current frame number from the START of the file (0-based, like Resolve).
    public var currentFrame: Int {
        let fps = (metadata?.frameRate ?? 0) > 0 ? metadata!.frameRate : 24
        return Int((currentTime * fps).rounded())
    }

    /// Total frame count of the clip (0-based: last frame = total - 1).
    public var totalFrames: Int {
        let fps = (metadata?.frameRate ?? 0) > 0 ? metadata!.frameRate : 24
        return max(Int((duration * fps).rounded()) - 1, 0)
    }

    /// Live source timecode at the current position (start TC + elapsed frames).
    /// nil if the file has no timecode track.
    public func currentSourceTimecode(at seconds: Double) -> String? {
        guard let tc = tcInfo, tc.nfr > 0 else { return nil }
        let elapsedFrames = Int((seconds * Double(tc.nfr)).rounded())
        return TimecodeReader.format(frameCount: tc.startFrame + elapsedFrames,
                                     nfr: tc.nfr, fps: tc.fps, dropFrame: tc.dropFrame)
    }

    /// Source timecode at the END of the clip.
    public func endSourceTimecode() -> String? {
        currentSourceTimecode(at: duration)
    }
}
