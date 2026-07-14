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
/// the FIRST one found (step A takes the first; the real picker comes with source switching).
/// Call OFF the main thread. Returns nil when the runtime is unavailable or nothing appeared.
///
/// Source name/URL strings are deep-copied immediately — the SDK's char* buffers are only valid
/// until the next get_current_sources / find_destroy.
+ (nullable NDIBridge *)connectToFirstSourceWithTimeout:(NSTimeInterval)timeout;

/// The connected source's NDI name (deep-copied at discovery).
@property (nonatomic, copy, readonly) NSString *sourceName;

/// Non-blocking pull of the CURRENT frame on the caller's clock — FrameSync owns the buffering
/// and jitter, we just take whatever is current at display time. Returns nil when no frame is
/// available yet, when FrameSync is repeating a frame we already converted (deduped on
/// timestamp), or when the frame is not UYVY (this step forces the 8-bit UYVY path).
///
/// Safe to call from the CVDisplayLink thread.
- (nullable NDIVideoFrame *)captureVideoFrame;

/// Tear down the receiver. The underlying framesync/recv instances are destroyed once the last
/// outstanding NDIVideoFrame is also released (see the lifetime note on NDIVideoFrame).
- (void)disconnect;

@end

NS_ASSUME_NONNULL_END
