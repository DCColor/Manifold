#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// One pulled NDI video frame, handed to Swift as a CVPixelBuffer.
///
/// LIFETIME — the load-bearing part of this class. `pixelBuffer` is a ZERO-COPY wrapper over
/// the NDI SDK's own frame memory (CVPixelBufferCreateWithBytes over `p_data`). The bytes stay
/// valid only until NDIlib_framesync_free_video is called on that frame, so the free is driven
/// by the pixel buffer's RELEASE CALLBACK: when the last reference to `pixelBuffer` drops, the
/// callback frees the NDI frame — and, with it, releases the receiver that owns the framesync
/// instance the free must be issued against. Hold this object (or the buffer) for exactly as
/// long as you read the pixels, and no longer.
///
/// This is why NDIReceiver is retained by the callback rather than by the service alone: a
/// disconnect while a frame is still in flight would otherwise destroy the framesync instance
/// out from under the pending free. Here the receiver simply outlives its last frame.
@interface NDIVideoFrame : NSObject

/// 8-bit packed 4:2:2 ('2vuy' / kCVPixelFormatType_422YpCbCr8), video-range. Zero-copy over NDI
/// memory — see the lifetime note above.
///
/// UNTAGGED on arrival: the colorimetry lives in `metadataXML`, and the CICP attachments are
/// applied by the receive path (NDIColorInfo) from what the sender actually declared. This class
/// deliberately does not tag it 709 — that hardcode was why every NDI source read Rec.709.
@property (nonatomic, readonly) CVPixelBufferRef pixelBuffer;
@property (nonatomic, readonly) int width;
@property (nonatomic, readonly) int height;
/// NDI's FourCC as text (e.g. "UYVY") — for logging / the "what did we actually get" check.
@property (nonatomic, copy, readonly) NSString *fourCC;
@property (nonatomic, readonly) int lineStrideInBytes;
/// The frame's per-frame metadata XML (NDI's `p_metadata`), deep-copied at capture — nil when the
/// sender sends none (it is OPTIONAL, and often absent). This is where NDI carries its color
/// signaling: `<ndi_color_info transfer="…" matrix="…" primaries="…"/>`. Parsing and the mapping
/// to CICP are Swift's job (NDIColorInfo); the bridge stays a transport and hands over the string
/// verbatim.
@property (nonatomic, copy, readonly, nullable) NSString *metadataXML;
/// NDI's 100ns timestamp. Used only to skip re-converting a frame FrameSync is repeating;
/// NOT used as a clock this step (real timestamp handling is the deferred clock step).
@property (nonatomic, readonly) int64_t timestamp;

@end

/// One pulled NDI audio frame, already converted to the tap's card-ready format: 32-bit signed
/// integer, INTERLEAVED, at the SOURCE's native sample rate + channel count (no resampling).
///
/// NDI audio is natively float32 PLANAR. The planar→interleaved + float→Int32 conversion is done
/// MANUALLY and at FULL SCALE (sample × 2147483647, clamped at ±2147483647) — deliberately NOT via
/// NDIlib_util_audio_to_interleaved_32s_v2, which applies a +4 dBu reference-level GAIN and CLIPS,
/// baking an opaque level change and ~16-bit-ish precision loss into the samples. This mirrors the
/// libav path's direct float→Int32 conversion: honest, no reference-level scaling.
///
/// Unlike NDIVideoFrame there is no zero-copy lifetime dance: the conversion IS the copy, so the
/// underlying NDI frame is freed inside `captureAudioFrame` and this object owns the `samples`
/// allocation outright (freed on dealloc).
@interface NDIAudioFrame : NSObject

/// Interleaved Int32 PCM — `frameCount * channelCount` samples, channel-major within each frame.
@property (nonatomic, readonly) const int32_t *samples NS_RETURNS_INNER_POINTER;
/// Samples per channel in `samples`.
@property (nonatomic, readonly) int frameCount;
@property (nonatomic, readonly) int channelCount;
@property (nonatomic, readonly) int sampleRate;
/// NDI's 100ns submit timestamp (the SENDER's clock). Carried for logging / the deferred real-clock
/// step — NOT used as the tap PTS (the receive path keys audio to the same free-running monotonic
/// clock it stamps video with, so audio and video land together on the SDI wire).
@property (nonatomic, readonly) int64_t timestamp;

@end

/// One discovered NDI source — name + url, BOTH deep-copied at discovery time. The SDK's
/// `find_get_current_sources` hands back char* buffers that are only valid until the next
/// get_current_sources / find_destroy (same lifetime caveat as step-A's connect path), so the
/// discovery code copies every field the instant it reads it and never lets a raw SDK pointer
/// escape into Swift.
@interface NDISource : NSObject
/// The NDI source name (e.g. "MACHINE (OmniScope)") — the picker's display + identity.
@property (nonatomic, copy, readonly) NSString *name;
/// The source URL/address, when the SDK provided one. Passed to recv_create_v3 alongside the name.
@property (nonatomic, copy, readonly, nullable) NSString *url;
@end

/// Minimal NDI receive bridge (STEP A: prove frames reach the Metal path).
///
/// The runtime is loaded DYNAMICALLY (dlopen + dlsym), never hard-linked: Manifold launches
/// normally on a machine with no NDI runtime installed, and every entry point below degrades to
/// a logged no-op. Nothing from the NDI SDK is compiled into or copied out of the repo — the
/// headers are referenced at their system path and the dylib is found at runtime.
@interface NDIBridge : NSObject

/// Load + initialize the NDI runtime. Idempotent (dispatch_once); safe to call from any thread.
/// Returns NO when the runtime is absent or too old to resolve a loader symbol.
+ (BOOL)loadRuntime;

/// Which loader symbol actually resolved ("NDIlib_v6_3_load" / "NDIlib_v6_load" /
/// "NDIlib_v5_load"), or nil if none did. The installed 6.0.1 runtime exports only v5.
@property (class, nonatomic, copy, readonly, nullable) NSString *loaderSymbol;

/// Runtime version string as reported by the loaded library, or nil.
@property (class, nonatomic, copy, readonly, nullable) NSString *runtimeVersion;

/// The dylib path that dlopen actually accepted, or nil.
@property (class, nonatomic, copy, readonly, nullable) NSString *runtimePath;

/// BLOCKING discovery: wait up to `timeout` for at least one source, then connect a receiver to
/// the FIRST one found. The keyboard quick-connect (⌃⌥N) uses this when the picker has not yet
/// populated a source list; the toolbar picker uses the non-blocking discovery below instead.
/// Call OFF the main thread. Returns nil when the runtime is unavailable or nothing appeared.
///
/// Source name/URL strings are deep-copied immediately — the SDK's char* buffers are only valid
/// until the next get_current_sources / find_destroy.
+ (nullable NDIBridge *)connectToFirstSourceWithTimeout:(NSTimeInterval)timeout;

/// NON-BLOCKING discovery for the source PICKER. Creates a persistent finder on first call and
/// reuses it after, then returns whatever sources are visible RIGHT NOW (deep-copied to NDISource,
/// so nothing SDK-owned escapes). The finder learns the network on its own background thread
/// between calls, so the first call is typically empty and later calls fill in — poll it lightly
/// (e.g. once a second) while the picker is on screen to track sources coming and going. Returns
/// an empty array when the runtime is unavailable. Main-thread friendly (returns immediately).
+ (NSArray<NDISource *> *)refreshDiscoveredSources;

/// Tear down the persistent discovery finder (call when the picker is dismissed). Cheap to
/// restart on the next refresh. Pair with -refreshDiscoveredSources on the SAME thread (main).
+ (void)stopDiscovery;

/// Connect a receiver+FrameSync to a SPECIFIC discovered source — the picker's action. Identical
/// receiver setup to the first-source path (UYVY, highest bandwidth, FrameSync); only the source
/// differs. Call OFF the main thread (recv_create can block). Returns nil when the runtime is
/// unavailable or the receiver could not be created.
+ (nullable NDIBridge *)connectToSource:(NDISource *)source;

/// The connected source's NDI name (deep-copied at discovery).
@property (nonatomic, copy, readonly) NSString *sourceName;

/// Non-blocking pull of the CURRENT frame on the caller's clock — FrameSync owns the buffering
/// and jitter, we just take whatever is current at display time. Returns nil when no frame is
/// available yet, when FrameSync is repeating a frame we already converted (deduped on
/// timestamp), or when the frame is not UYVY (this step forces the 8-bit UYVY path).
///
/// Safe to call from the CVDisplayLink thread.
- (nullable NDIVideoFrame *)captureVideoFrame;

/// Non-blocking pull of buffered audio, converted to Int32 interleaved for the tap. Returns nil when
/// the source carries no audio yet or nothing is buffered this tick. Pulls at the source's NATIVE
/// sample rate + channel count — NO resampling (a non-48k source is refused downstream at the
/// tap→DeckLink seam, not resampled here). Uses the v2 (float, non-FourCC) FrameSync audio API,
/// which sits inside the v5 struct slice this bridge is pinned to.
///
/// PACING lives in the caller: this drains `framesync_audio_queue_depth` (whatever accumulated since
/// the last call) and returns it, so calling it steadily on a real-time-paced loop self-corrects to
/// the true production rate with no drift. `maxSamples` is a SAFETY CEILING that bounds one call's
/// work if a startup/stall backlog is large (the result is `min(maxSamples, queue_depth)`); it does
/// NOT set the rate. The dedicated NDI audio pump thread (NDIService) calls this every ~10 ms with a
/// generous ceiling — NOT the CVDisplayLink tick, whose rate must not gate the audio drain (that
/// coupling was the fps-collapse bug). Requesting no more than what's buffered means FrameSync never
/// pads silence. Non-blocking; safe to call from the audio pump thread.
- (nullable NDIAudioFrame *)captureAudioFrameForMaxSamples:(int)maxSamples;

/// Tear down the receiver. The underlying framesync/recv instances are destroyed once the last
/// outstanding NDIVideoFrame is also released (see the lifetime note on NDIVideoFrame).
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
