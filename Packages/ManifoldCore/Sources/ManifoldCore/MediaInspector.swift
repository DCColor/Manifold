import AVFoundation
import CoreMedia
import AudioToolbox

/// Engine-agnostic asset inspection: reads "what a file IS" (metadata, timecode,
/// display size) independent of how it's played. Shared by AVPlayerEngine and
/// FrameEngine so the extraction logic lives in one place.
public enum MediaInspector {

    /// Produce a fully-populated `VideoMetadata` for the given asset/URL.
    public static func metadata(for asset: AVURLAsset, url: URL) async -> VideoMetadata {
        var meta = VideoMetadata()
        meta.container = url.pathExtension.uppercased()
        meta.fileName = url.lastPathComponent
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            meta.fileCreatedDate = attrs[.creationDate] as? Date
            meta.fileModifiedDate = attrs[.modificationDate] as? Date
        }

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
                meta.codecName = codecName(for: fmt)
                let c = colorTags(for: fmt)
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

        meta.audioTracks = await audioTracks(for: asset)
        meta.textTracks = await textTracks(for: asset)
        let tc = TimecodeReader.readStartTimecode(url: url)
        meta.startTimecode = tc?.timecode
        meta.chapters = await chapters(for: asset)

        if let createdItem = (try? await asset.load(.creationDate)) ?? nil,
           let dateValue = (try? await createdItem.load(.dateValue)) ?? nil {
            meta.creationDate = dateValue
        }
        let common = (try? await asset.load(.commonMetadata)) ?? []
        for item in common {
            guard let key = item.commonKey else { continue }
            if key == .commonKeyCreator || key == .commonKeyAuthor {
                if let s = (try? await item.load(.stringValue)) ?? nil, !s.isEmpty { meta.creator = s }
            }
            if key == .commonKeySoftware {
                if let s = (try? await item.load(.stringValue)) ?? nil, !s.isEmpty { meta.software = s }
            }
        }

        return meta
    }

    /// Produce the display size (naturalSize × preferredTransform), or nil.
    public static func displaySize(for asset: AVURLAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform)
        else { return nil }
        let displayRect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return CGSize(width: abs(displayRect.width), height: abs(displayRect.height))
    }

    /// Read the start-timecode info for the file (nil if no TC track).
    public static func timecode(for url: URL) -> TimecodeReader.Result? {
        TimecodeReader.readStartTimecode(url: url)
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
                let layout = audioLayout(from: fmt, channelCount: info.channelCount)
                info.layoutName = layout.name
                info.layoutConfidence = layout.confidence
            } else {
                info.layoutName = info.channelCount > 0 ? "\(info.channelCount) ch" : "—"
                info.layoutConfidence = .undeclared
            }
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

    // MARK: - Audio channel layout derivation (ported interpretation from Flip)

    /// Short role names in channel order, derived from the format description's
    /// AudioChannelLayout. Returns nil if no usable layout/roles are present.
    private static func channelRoles(from fmt: CMFormatDescription) -> [String]? {
        var size = 0
        guard let rawPtr = CMAudioFormatDescriptionGetChannelLayout(fmt, sizeOut: &size) else {
            return nil
        }

        // Read the fixed header fields safely.
        let tag = rawPtr.pointee.mChannelLayoutTag

        // Camp B: explicit per-channel descriptions.
        if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
            let count = Int(rawPtr.pointee.mNumberChannelDescriptions)
            guard count > 0 else { return nil }

            // mChannelDescriptions is a C flexible-array member. Its byte offset
            // within AudioChannelLayout is the size of the two leading UInt32 fields
            // (mChannelLayoutTag, mChannelBitmap) plus the UInt32 count =
            // offsetof(AudioChannelLayout, mChannelDescriptions). Compute it from
            // the struct layout rather than via the imported fixed-size tuple.
            let headerSize = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            let descStride = MemoryLayout<AudioChannelDescription>.stride

            // Bound check against the reported size.
            guard size >= headerSize + count * descStride else { return nil }

            let base = UnsafeRawPointer(rawPtr).advanced(by: headerSize)
            var roles: [String] = []
            roles.reserveCapacity(count)
            for i in 0..<count {
                let desc = base.advanced(by: i * descStride)
                    .loadUnaligned(as: AudioChannelDescription.self)
                roles.append(roleName(for: desc.mChannelLabel))
            }
            return roles
        }

        // Camp A: a known layout tag.
        if let seq = roleSequence(forTag: tag) { return seq }

        // Bitmap or unknown tag: no role info we trust.
        return nil
    }

    /// Apple AudioChannelLabel -> short role name (Flip vocabulary, normalized).
    private static func roleName(for label: AudioChannelLabel) -> String {
        switch label {
        case kAudioChannelLabel_Left: return "L"
        case kAudioChannelLabel_Right: return "R"
        case kAudioChannelLabel_Center: return "C"
        case kAudioChannelLabel_LFEScreen: return "LFE"
        case kAudioChannelLabel_LeftSurround: return "Ls"
        case kAudioChannelLabel_RightSurround: return "Rs"
        case kAudioChannelLabel_CenterSurround: return "Cs"
        case kAudioChannelLabel_LeftSurroundDirect: return "Lsd"
        case kAudioChannelLabel_RightSurroundDirect: return "Rsd"
        case kAudioChannelLabel_RearSurroundLeft: return "Lss"   // Apple Rls -> Flip Lss
        case kAudioChannelLabel_RearSurroundRight: return "Rss"  // Apple Rrs -> Flip Rss
        case kAudioChannelLabel_LeftCenter: return "Lc"
        case kAudioChannelLabel_RightCenter: return "Rc"
        case kAudioChannelLabel_Mono: return "Mono"
        case kAudioChannelLabel_Unused: return "—"
        default: return "?(\(label))"   // unmapped label — show raw value
        }
    }

    /// For Camp A known tags, the canonical role sequence (so tag-based files name
    /// identically to description-based ones).
    private static func roleSequence(forTag tag: AudioChannelLayoutTag) -> [String]? {
        switch tag {
        case kAudioChannelLayoutTag_Mono:   return ["Mono"]
        case kAudioChannelLayoutTag_Stereo: return ["L", "R"]
        case kAudioChannelLayoutTag_MPEG_5_1_A: return ["L", "R", "C", "LFE", "Ls", "Rs"]   // 5.1 SMPTE
        case kAudioChannelLayoutTag_MPEG_5_1_C: return ["L", "C", "R", "Ls", "Rs", "LFE"]   // 5.1 Film
        case kAudioChannelLayoutTag_MPEG_7_1_C: return ["L", "R", "C", "LFE", "Ls", "Rs", "Lss", "Rss"] // 7.1
        default: return nil
        }
    }

    /// Map a role SEQUENCE to a layout name. This is the heart of the fix:
    /// the SEQUENCE determines the layout, distinguishing SMPTE vs Film, Quad vs LCRS.
    /// Returns nil if the sequence matches no known layout.
    private static func layoutName(forRoles roles: [String]) -> String? {
        let seq = roles.joined(separator: " ")
        let table: [String: String] = [
            "Mono": "Mono",
            "L R": "Stereo",
            "L C R": "3.0",
            "L R C": "3.0",
            "L C R Cs": "4.0 (LCRS)",
            "L R C Cs": "4.0 (LRCS)",
            "L R Ls Rs": "4.0 (Quad)",
            "L C R Ls Rs": "5.0 Film",
            "L R C Ls Rs": "5.0 SMPTE",
            "L R C LFE Ls Rs": "5.1 SMPTE",
            "L C R Ls Rs LFE": "5.1 Film",
            "L R C Ls Rs Lss Rss": "7.0 SMPTE",
            "L C R Ls Rs Lss Rss": "7.0 Film",
            "L R C LFE Ls Rs Lss Rss": "7.1 SMPTE",
            "L C R LFE Ls Rs Lss Rss": "7.1 Film",
            "L C R Ls Rs Lss Rss LFE": "7.1 Film"
        ]
        return table[seq]
    }

    /// Most-common layout for a channel count, used ONLY as a marked inference
    /// when no declaration is present. Returns nil for counts with no common layout.
    private static func inferredLayoutName(forChannels n: Int) -> String? {
        switch n {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return nil   // 3,4,5,7,etc. are ambiguous — don't guess
        }
    }

    /// Derive a layout name + confidence for an audio format description.
    static func audioLayout(from fmt: CMFormatDescription, channelCount: Int) -> (name: String, confidence: LayoutConfidence) {
        // Tier 1: real declaration via channel descriptions / known tag.
        if let roles = channelRoles(from: fmt) {
            let meaningful = roles.filter { $0 != "?" && !$0.hasPrefix("?(") && $0 != "—" }
            if !meaningful.isEmpty, let name = layoutName(forRoles: roles) {
                return (name, .declared)
            }
        }
        // Tier 2: inferred from channel count (marked).
        if let inferred = inferredLayoutName(forChannels: channelCount) {
            return ("\(inferred) (inferred)", .inferred)
        }
        // Tier 3: honest unknown.
        return (channelCount > 0 ? "\(channelCount) ch" : "—", .undeclared)
    }

    private static func textTracks(for asset: AVURLAsset) async -> [TextTrackInfo] {
        var result: [TextTrackInfo] = []
        let mediaTypes: [(AVMediaType, String)] = [
            (.closedCaption, "Closed Caption"),
            (.subtitle, "Subtitle"),
            (.text, "Timed Text")
        ]
        for (mediaType, kindName) in mediaTypes {
            guard let tracks = try? await asset.loadTracks(withMediaType: mediaType) else { continue }
            for track in tracks {
                var info = TextTrackInfo()
                info.kind = kindName
                if let formats = try? await track.load(.formatDescriptions), let fmt = formats.first {
                    info.format = textFormatName(CMFormatDescriptionGetMediaSubType(fmt))
                }
                if let lang = (try? await track.load(.languageCode)) ?? nil, !lang.isEmpty {
                    info.language = lang
                }
                result.append(info)
            }
        }
        return result
    }

    private static func textFormatName(_ code: FourCharCode) -> String {
        switch fourCCString(code).replacingOccurrences(of: "'", with: "") {
        case "c608": return "CEA-608"
        case "c708": return "CEA-708"
        case "wvtt": return "WebVTT"
        case "tx3g": return "Timed Text (tx3g)"
        case "stpp": return "TTML / IMSC"
        case "text": return "Text"
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
}
