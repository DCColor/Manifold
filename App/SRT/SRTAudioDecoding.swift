//
//  SRTAudioDecoding.swift
//  Manifold
//
//  The seam between SRT's audio router and whichever AAC decoder is decoding for it.
//
//  ── WHY THIS EXISTS ────────────────────────────────────────────────────────────────────────────
//
//  There are two decoders now, and the choice is made per stream:
//
//    * `SRTAudioDecoderLibav`  — libavcodec. STEREO ONLY. The default, because AudioToolbox
//      renders the Cloudflare SRT feed as gravel and libav renders the same bytes clean.
//    * `SRTAudioDecoder`       — AudioToolbox. Everything else, i.e. multichannel, because the
//      channel-ORDER work that path carries has not been redone for libav and re-deriving it in a
//      hurry is how the 5.1 mislabelling happened the first time.
//
//  ⚠️ THIS PROTOCOL IS EXACTLY WHAT `handleAudioPacket` ALREADY USED, AND NOTHING MORE. The four
//  members below are the complete set that `SRTFrameRouter` reads off its decoder — verified by
//  grep, not by inspection. Adding to it means adding to what both decoders must answer for, so a
//  member belongs here only when the ROUTER needs it; anything one decoder wants to say about
//  itself belongs on that decoder's own type, where the other one is not obliged to have an
//  opinion. `SRTAudioDecoder.cookieState` is the model: meaningless to libav, absent from here.
import Foundation

protocol SRTAudioDecoding: AnyObject {
    /// The rate the DECODED samples are at. For libav this is read back from the frame, which is
    /// the only place SBR's doubling is visible; for AudioToolbox it is the mux's declaration.
    var sampleRate: Double { get }

    /// The channel count of the interleaved buffer `decode` returns — again, what came out, not
    /// what the mux promised.
    var channelCount: Int { get }

    /// A CoreAudio `AudioChannelLayout` for the decoded interleave, or nil when nothing about the
    /// channels could be established. Nil is a supported answer and means "the meters show channel
    /// numbers", which is the honest fallback this codebase uses everywhere else.
    var channelLayoutData: Data? { get }

    /// Per-channel role names for `channelLayoutData`, or empty.
    var channelRoles: [String] { get }

    /// Decode one packet into interleaved Int32 frames.
    ///
    /// ⚠️ THE RETURNED BUFFER IS THE DECODER'S OWN SCRATCH AND IS VALID ONLY UNTIL THE NEXT CALL.
    /// Both implementations return a pointer into a buffer they own and reuse. The caller copies
    /// immediately — `handleAudioPacket` does, into a `CMBlockBuffer`.
    func decode(_ packet: UnsafeRawBufferPointer) -> UnsafeBufferPointer<Int32>?
}
