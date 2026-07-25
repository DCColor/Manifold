//
//  SRTSpike.h
//  Manifold
//
//  SRT STAGE 2 — TRANSPORT SPIKE. TEMPORARY, DEBUG-ONLY, DELETE WHEN STAGE 3 LANDS.
//
//  What this is: libsrt caller socket -> custom AVIOContext -> mpegts demux ->
//  av_read_frame -> LOG. That is the whole scope. Packets are counted, described
//  and DISCARDED. Nothing is decoded, nothing is rendered, nothing reaches
//  LiveDisplayRoute, LiveSource, the renderer or the UI.
//
//  WHY IT EXISTS. Two things are unknown and both are cheaper to learn now than to
//  design around later:
//    1. THE MECHANISM. There is no avio_alloc_context precedent in this codebase —
//       all four libavformat call sites open a file path. The vendored FFmpeg is
//       built --disable-network with ff_file_protocol as the ONLY protocol, so
//       handing libavformat a "srt://..." string is not merely discouraged, it is
//       impossible. A custom AVIOContext is the only door, and this file proves it
//       opens.
//    2. THE CONTENT. Chiefly: DOES A REAL SRT FEED CARRY B-FRAMES? Three places in
//       the WHEP decode path assume decode order == display order, and professional
//       SRT contribution routinely runs High profile with B-frames. The header field
//       (video_delay) is not trusted here — see the empirical probe in SRTSpike.m.
//
//  Same header discipline as DataChannelBridge.h / NDIBridge.h / DeckLinkBridge.h:
//  this header is PURE C and pulls in NEITHER <srt/*> NOR <libav*/*>, so neither
//  library's API ever reaches Swift or the bridging header's module scan. The .m
//  owns all of it.
//
//  DEBUG-ONLY BY CONSTRUCTION. Both the declarations here and the entire body of
//  SRTSpike.m are wrapped in `#ifdef DEBUG`, so under the Release configuration this
//  header is empty, the implementation compiles to nothing, and no SRT or libav
//  symbol is reachable from any shipping code path. The bridging header may import
//  it unconditionally precisely because of that. (Profile also defines DEBUG — see
//  the note at the top of project.yml — which is deliberate: the spike should be
//  runnable at -O, like the ⌃⌥L / ⌃⌥H harnesses.)
//

#ifdef DEBUG

/// Connect the spike and start demuxing. Bound to ⌃⌥D.
///
/// Returns immediately: the connect, the demux and all logging happen on a dedicated
/// thread (`com.manifold.srt.spike`). The target is the hardcoded constant
/// `kSRTSpikeURL` in SRTSpike.m — bookmark-UI integration is a later stage, so there
/// is deliberately no URL parameter and no ambient configuration here.
///
/// Idempotent: a second call while a session is running logs and returns. Main thread
/// only (it is called from a SwiftUI Button action).
void ManifoldSRTSpikeStart(void);

/// Tear the session down and BLOCK until the thread has actually exited. Bound to ⌃⌥⇧D.
///
/// The wait is bounded by one SRTO_RCVTIMEO period (200 ms) plus one demux iteration —
/// see the join discussion in SRTSpike.m. Idempotent: a no-op if nothing is running.
/// Main thread only.
void ManifoldSRTSpikeStop(void);

#endif  /* DEBUG */
