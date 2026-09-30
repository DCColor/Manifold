//
//  ADTSWalk.swift
//  AACFraming
//
//  Splits one MPEG-TS PES payload into its ADTS frames (docs/BUGS.md, "SRT audio decodes nothing
//  when a PES carries more than one ADTS frame").
//
//  ISO/IEC 13818-1 lets a PES carry any number of whole access units, and ADTS frames are
//  self-delimiting: `aac_frame_length` (13 bits, header INCLUDED) says where the next one starts.
//  ffmpeg packs several per PES by default (its `pes_payload_size`, 170 bytes at the minimum, groups
//  small frames such as digital silence even when asked for 0). The vendored libavformat has no AAC
//  parser (`--enable-parser=h264` only), so its mpegts demuxer hands back the whole PES payload as
//  one packet. SRTAudioDecoder used to strip ONE header and hand the rest to AudioToolbox as one
//  frame, which decoded the first frame and dropped the others.
//
//  A LEAF TARGET, like RTCPWire and DisplayProviders, so `swift test` can reach it: the byte
//  layouts are only observable at test time. No dependencies.

public enum ADTSWalk {

    /// One ADTS frame inside a payload.
    public struct Frame: Equatable, Sendable {
        /// Byte offset of the frame's header in the payload.
        public let offset: Int
        /// Whole frame, header included (`aac_frame_length`).
        public let length: Int
        /// 7, or 9 with the CRC (`protection_absent == 0`).
        public let headerBytes: Int
        /// ADTS `profile` (object type − 1), `sampling_frequency_index`, `channel_configuration`.
        public let profileMinusOne: UInt8
        public let samplingIndex: UInt8
        public let channelConfig: UInt8
        /// `number_of_raw_data_blocks_in_frame`: 0 for one raw block (1024 samples on LC).
        public let rawDataBlocks: UInt8

        /// The raw AAC after the header.
        public var payloadOffset: Int { offset + headerBytes }
        public var payloadLength: Int { length - headerBytes }
    }

    /// Why the walk stopped before the end of the payload.
    public enum Stop: Equatable, Sendable {
        /// The bytes left do not start with the ADTS syncword.
        case noSyncword
        /// `aac_frame_length` is shorter than the header, or runs past the payload.
        case badLength(declared: Int, available: Int)
        /// Fewer bytes left than an ADTS header.
        case shortHeader
    }

    public struct Result: Equatable, Sendable {
        public let frames: [Frame]
        /// Bytes after the last whole frame that were not walked (0 on a clean payload).
        public let leftoverBytes: Int
        /// nil when the walk consumed the whole payload.
        public let stop: Stop?
    }

    /// The ADTS header fields at `offset`, or nil when the syncword is absent or fewer than 7 bytes
    /// remain.
    public static func header(_ p: UnsafeRawBufferPointer, at offset: Int) -> Frame? {
        guard offset >= 0, p.count - offset >= 7 else { return nil }
        let b0 = p[offset], b1 = p[offset + 1], b2 = p[offset + 2], b3 = p[offset + 3]
        let b4 = p[offset + 4], b5 = p[offset + 5], b6 = p[offset + 6]
        guard b0 == 0xFF, b1 & 0xF0 == 0xF0 else { return nil }
        let length = (Int(b3 & 0x03) << 11) | (Int(b4) << 3) | (Int(b5) >> 5)
        return Frame(offset: offset, length: length,
                     headerBytes: b1 & 0x01 != 0 ? 7 : 9,
                     profileMinusOne: (b2 >> 6) & 0x03,
                     samplingIndex: (b2 >> 2) & 0x0F,
                     channelConfig: ((b2 & 0x01) << 2) | ((b3 >> 6) & 0x03),
                     rawDataBlocks: b6 & 0x03)
    }

    /// Walks the payload frame by frame. Returns nil when it does not START with an ADTS header,
    /// which is raw AAC or LATM: not ours to split. Otherwise every whole frame, in order, and why
    /// the walk stopped early if it did. A bad frame ends the walk; nothing after it is guessed at.
    public static func walk(_ p: UnsafeRawBufferPointer) -> Result? {
        guard header(p, at: 0) != nil else { return nil }
        var frames: [Frame] = []
        var at = 0
        while at < p.count {
            let left = p.count - at
            guard left >= 7 else { return Result(frames: frames, leftoverBytes: left, stop: .shortHeader) }
            guard let f = header(p, at: at) else {
                return Result(frames: frames, leftoverBytes: left, stop: .noSyncword)
            }
            guard f.length > f.headerBytes, f.length <= left else {
                return Result(frames: frames, leftoverBytes: left,
                              stop: .badLength(declared: f.length, available: left))
            }
            frames.append(f)
            at += f.length
        }
        return Result(frames: frames, leftoverBytes: 0, stop: nil)
    }
}
