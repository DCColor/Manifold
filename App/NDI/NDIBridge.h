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
/// The sender's DECLARED frame rate, handed over as NDI's EXACT RATIONAL and never as a float:
/// `frame_rate_N` / `frame_rate_D` verbatim. 24000/1001 is 23.976 and 30000/1001 is 29.97 — the
/// two rates a bridge-side division would round away, and the two that matter most to a broadcast
/// output. Swift divides and decides (NDIService); this stays a transport.
///
/// 0 IN EITHER FIELD MEANS "THIS SENDER DECLARED NOTHING", and that is not an inference: the
/// capture struct is `memset` to zero before `framesync_capture_video` fills it, so an untouched
/// pair reads 0/0. They are therefore handed over UNVALIDATED — refusing a nonsense pair is a
/// policy decision about what may reconfigure an SDI card, and it belongs with the other three
/// transports' refusals, not here.
///
/// This is the best rate signal any of the four live transports has — an exact rational the
/// sender states outright, where SRT guesses, HLS measures and WHEP parses. It is also the one
/// with NO independent measurement to cross-check it against; see NDIService.
@property (nonatomic, readonly) int frameRateN;
@property (nonatomic, readonly) int frameRateD;
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
/// NDI's 100ns submit timestamp (the SENDER's clock), or `NDIlib_recv_timestamp_undefined`
/// (INT64_MAX) when the sender does not supply one. NOT used as the tap PTS — the receive path keys
/// audio to the same free-running monotonic clock it stamps video with, so audio and video land
/// together on the SDI wire.
///
/// It is, however, the AUTHENTICITY PROOF for the pulled samples, and that is not a decorative
/// claim: FrameSync will happily manufacture samples to satisfy an over-large request (see
/// `captureAudioFrameForInterval:`), and manufactured samples are indistinguishable from real ones
/// by inspection. Sender time is the one quantity FrameSync cannot invent. Across consecutive pulls
/// it must advance by `frameCount / sampleRate`; if it advances more slowly than that, the
/// difference was synthesised. The `[NDI-AUDIO]` trace prints exactly that ratio.
@property (nonatomic, readonly) int64_t timestamp;

/// `framesync_audio_queue_depth` READ AT PULL TIME, in samples per channel — a DIAGNOSTIC ONLY, and
/// deliberately not used to size anything (it was, and that was the defect; see BUGS.md #NDI-AUDIO).
///
/// It earns its place because it is the only view of the SDK side of the seam: with the pull
/// correctly sized to our cadence, this sits low and roughly flat, because FrameSync is consuming
/// what it hands us. The failure it exists to make un-missable is the old one — a depth that
/// sawtooths up to the request ceiling, which is what "we are asking for samples that were never
/// sent" looks like from outside the library. One `int` read per pull, so it stays unconditional
/// rather than `#if DEBUG`: the cost is nothing and a diagnostic compiled out of the build that
/// ships is a diagnostic nobody can ask a tester for.
@property (nonatomic, readonly) int queueDepthAtPull;

@end

/// One discovered NDI source — name + url, BOTH deep-copied at discovery time. The SDK's
/// `find_get_current_sources` hands back char* buffers that are only valid until the next
/// get_current_sources / find_destroy (same lifetime caveat as step-A's connect path), so the
/// discovery code copies every field the instant it reads it and never lets a raw SDK pointer
/// escape into Swift.
@interface NDISource : NSObject
/// The NDI source name, in the SDK's "MACHINE (Sender Name)" form — the picker's display + identity.
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

/// Whether the runtime DYLIB EXISTS ON DISK — a filesystem check only.
///
/// ⚠️ THIS IS NOT `loadRuntime` AND MUST NOT BE USED AS IF IT WERE. It does no `dlopen`, resolves
/// no loader symbol, and — the part that matters — never calls `NDIlib_initialize()`. That is the
/// whole reason it exists: `loadRuntime` stands the NDI library up (threads, discovery machinery),
/// which is why `NDIService` says to call it lazily and NOT at app launch. This answers the much
/// smaller question "is the package installed", cheaply enough to ask at launch, so a menu item can
/// decide whether to offer the download.
///
/// ⚠️ It checks only the ABSOLUTE candidate paths. `loadRuntime`'s last candidate is the bare name
/// `libndi.dylib`, which is a dyld search rather than a file, so a runtime reachable only that way
/// reads as absent here. `loadRuntime` remains the authoritative answer to "can we use NDI".
+ (BOOL)runtimeFilePresent;

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
/// ── PACING: PASS YOUR CADENCE, NOT A CEILING. `seconds` IS THE CALLER'S POLL INTERVAL. ────────
///
/// `NDIlib_framesync_capture_audio`'s `no_samples` is "give me EXACTLY this many, resampled to the
/// rate at which I am calling you" — NOT "give me at most this many". Processing.NDI.FrameSync.h,
/// verbatim: "This function will always return data immediately, inserting silence if no current
/// audio data is present. You should call this at the rate that you want audio and it will
/// automatically adapt the incoming audio signal to match the rate at which you are calling by
/// using dynamic audio sampling."
///
/// So the request is an INSTRUCTION about the consumer's clock, and what must be true is that the
/// counts we ask for add up to `sampleRate` over a second of OUR time. This method therefore asks
/// for `MEASURED elapsed since the previous pull × sampleRate`, carrying the sub-sample remainder.
/// `seconds` is the caller's NOMINAL interval and is used for the first pull only (there is no
/// previous one to measure against) and to pace the format requery.
///
/// ⚠️ A FIXED COUNT AT A NOMINAL CADENCE IS NOT GOOD ENOUGH, AND THIS COMMENT ONCE SAID IT WAS.
/// It read: "DO NOT 'IMPROVE' THIS BY DERIVING THE COUNT FROM MEASURED ELAPSED TIME … a second
/// controller measuring the same thing would fight [the TBC]". That is wrong, and it is wrong for a
/// reason worth keeping: it assumed the pump's period EQUALLED `pollInterval`. It does not — the
/// sleep is at the bottom of the loop, so the period is `pollInterval + pull + convert`, measured
/// ~10.9 ms against a nominal 10 ms. Asking for 480 samples 91.7 times a second declares a 44030 Hz
/// consumer and leaves 8.3% of the stream unconsumed: measured `cum=44030Hz`, a `depth` sawtooth of
/// 250..2280 samples, `dev` climbing to +50 ms and ~2 tap re-anchors a second.
///
/// Measuring elapsed time does not fight the TBC, it FEEDS it: `elapsed × rate` makes our draw
/// exactly `rate` per second by our own clock, which is the quantity the TBC reconciles against the
/// sender's. The SDK examples use fixed counts because theirs are driven by an audio device
/// callback or a video frame duration — cadences that ARE exact. A sleeping thread's is not.
///
/// ⚠️ AND DO NOT SIZE IT FROM `framesync_audio_queue_depth`. That is what this used to do, and it
/// told FrameSync the consumer clock ran at up to 480 kHz: measured 1.44M samples sent against 8.1M
/// delivered, a sustained ~270 kHz effective rate, and a tap fed ~82% synthesised audio. The header
/// warns against it in its own words — "you should treat the results of this function with some
/// care because in reality the frame-sync API is meant to dynamically resample audio to match the
/// rate that you are calling it" — and the comment that used to sit here asserted the exact
/// opposite ("Requesting no more than what's buffered means FrameSync never pads silence"). It
/// pads whenever the request exceeds what it holds, regardless. See BUGS.md #NDI-AUDIO.
///
/// The dedicated NDI audio pump thread (NDIService) calls this every ~10 ms — NOT the CVDisplayLink
/// tick, whose rate must not gate the audio drain (that coupling was the fps-collapse bug).
/// Non-blocking; safe to call from the audio pump thread.
- (nullable NDIAudioFrame *)captureAudioFrameForInterval:(double)seconds;

/// Tear down the receiver. The underlying framesync/recv instances are destroyed once the last
/// outstanding NDIVideoFrame is also released (see the lifetime note on NDIVideoFrame).
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
