#import "NDIBridge.h"

#import <dlfcn.h>
#import <string>

// POD structs, no inline C++ constructors. The constructors are only DECLARED in structs.h and
// DEFINED in the SDK's Lib.cplusplus.h; taking the C path keeps this translation unit free of any
// reference to a directly-linked NDI symbol. Everything we call goes through the function-pointer
// struct returned by the loader, so the binary has NO link-time dependency on libndi at all.
#define NDILIB_CPP_DEFAULT_CONSTRUCTORS 0
#include <Processing.NDI.Lib.h>

// MARK: - Runtime loading
//
// dlopen, NOT a hard link. Manifold must launch on a machine with no NDI runtime — so the
// library is resolved at first use and every failure path below is a logged no-op, never a
// crash and never a missing-dylib launch failure.
//
// The FALLBACK CHAIN matters here and is not defensive boilerplate: the SDK ships v6.3 headers,
// but the runtime actually installed on this machine is NDI 6.0.1, which exports NDIlib_v5_load
// and NOT NDIlib_v6_load. The SDK's own examples hardcode the v6 loader and would simply fail to
// find a symbol. All three loaders return a pointer to the SAME struct (the header typedefs
// NDIlib_v5/v6/v6_3 to one another), so taking the first that resolves is correct.
//
// CONSEQUENCE, and the reason this is spelled out: the struct we get back from a v5 runtime is
// only populated through the "// v5" marker in Processing.NDI.DynamicLoad.h. Fields declared
// after it (v6.1+) are NOT THERE — reading them off a v5-loaded struct is an out-of-bounds read
// of a shorter allocation. Everything the receive path needs (initialize, find_*, recv_create_v3,
// framesync_*) sits before that marker, so this file stays strictly inside it. Do not reach past
// it without first confirming the loaded runtime is actually v6.1+.

typedef const NDIlib_v5 *(*NDIlib_load_fn)(void);

static const NDIlib_v5 *gNDI = nullptr;
static NSString *gLoaderSymbol = nil;
static NSString *gRuntimeVersion = nil;
static NSString *gRuntimePath = nil;

/// Candidate dylib paths, in search order: the SDK's documented env override, the standard
/// install location, then the bare name (let dyld's own search do the work).
static NSArray<NSString *> *NDICandidatePaths(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    const char *env = getenv("NDI_RUNTIME_DIR_V6");
    if (env && *env) {
        [paths addObject:[[NSString stringWithUTF8String:env]
                          stringByAppendingPathComponent:@"libndi.dylib"]];
    }
    [paths addObject:@"/usr/local/lib/libndi.dylib"];
    [paths addObject:@"libndi.dylib"];
    return paths;
}

static BOOL NDILoadOnce(void) {
    void *handle = NULL;
    for (NSString *path in NDICandidatePaths()) {
        handle = dlopen(path.UTF8String, RTLD_LOCAL | RTLD_LAZY);
        if (handle) {
            gRuntimePath = [path copy];
            break;
        }
    }
    if (!handle) {
        NSLog(@"[NDI] runtime not found — tried %@. NDI features are unavailable; "
              @"the app runs normally without them.", [NDICandidatePaths() componentsJoinedByString:@", "]);
        return NO;
    }

    // First loader that resolves wins. Newest first, so a newer runtime still takes its own path.
    NSArray<NSString *> *symbols = @[@"NDIlib_v6_3_load", @"NDIlib_v6_load", @"NDIlib_v5_load"];
    NDIlib_load_fn load = NULL;
    for (NSString *sym in symbols) {
        load = (NDIlib_load_fn)dlsym(handle, sym.UTF8String);
        if (load) {
            gLoaderSymbol = [sym copy];
            break;
        }
    }
    if (!load) {
        NSLog(@"[NDI] loaded %@ but none of %@ resolved — runtime too old. NDI unavailable.",
              gRuntimePath, [symbols componentsJoinedByString:@" / "]);
        return NO;
    }

    const NDIlib_v5 *lib = load();
    if (!lib) {
        NSLog(@"[NDI] %@ returned NULL. NDI unavailable.", gLoaderSymbol);
        return NO;
    }
    if (!lib->initialize()) {
        NSLog(@"[NDI] NDIlib_initialize() failed (unsupported CPU?). NDI unavailable.");
        return NO;
    }

    gNDI = lib;
    if (lib->version) {
        const char *v = lib->version();
        if (v) gRuntimeVersion = [NSString stringWithUTF8String:v];
    }
    NSLog(@"[NDI] runtime loaded: %@", gRuntimePath);
    NSLog(@"[NDI] loader symbol resolved: %@", gLoaderSymbol);
    NSLog(@"[NDI] runtime version: %@", gRuntimeVersion ?: @"<unknown>");
    return YES;
}

// MARK: - Receiver (owns recv + framesync)

/// Owns the receiver and its FrameSync instance, and — critically — OUTLIVES ITS LAST FRAME.
/// Each pulled frame's release callback holds a strong reference to this object, so the
/// framesync instance cannot be destroyed while a free is still pending against it. Teardown is
/// therefore just "drop the references": the last one to go runs dealloc, in the right order.
@interface NDIReceiver : NSObject {
@public
    NDIlib_recv_instance_t _recv;
    NDIlib_framesync_instance_t _framesync;
}
- (void)freeVideoFrame:(NDIlib_video_frame_v2_t *)frame;
@end

@implementation NDIReceiver

- (void)freeVideoFrame:(NDIlib_video_frame_v2_t *)frame {
    if (gNDI && _framesync && frame) {
        gNDI->framesync_free_video(_framesync, frame);
    }
}

- (void)dealloc {
    // Order matters: framesync first (it holds the receiver), then the receiver.
    if (gNDI) {
        if (_framesync) gNDI->framesync_destroy(_framesync);
        if (_recv) gNDI->recv_destroy(_recv);
    }
    _framesync = nullptr;
    _recv = nullptr;
    NSLog(@"[NDI] receiver torn down");
}

@end

// MARK: - Zero-copy frame wrapping

/// Refcon for the CVPixelBuffer release callback. Carries the NDI frame descriptor by VALUE (so
/// the free gets back exactly the pointers the SDK handed us) plus a RETAINED receiver reference.
struct NDIFrameContext {
    void *receiver;                    // __bridge_retained NDIReceiver *
    NDIlib_video_frame_v2_t frame;
};

/// Runs when the last reference to the zero-copy CVPixelBuffer drops — i.e. the moment nothing
/// is reading NDI's pixels any more. Frees the NDI frame, then releases the receiver.
static void NDIFrameRelease(void *refcon, const void *baseAddress) {
    (void)baseAddress;
    NDIFrameContext *ctx = (NDIFrameContext *)refcon;
    if (!ctx) return;
    NDIReceiver *receiver = (__bridge_transfer NDIReceiver *)ctx->receiver;   // balances the retain
    [receiver freeVideoFrame:&ctx->frame];
    delete ctx;
}

@implementation NDIVideoFrame {
    CVPixelBufferRef _pixelBuffer;
}

@synthesize width = _width, height = _height, fourCC = _fourCC;
@synthesize lineStrideInBytes = _lineStrideInBytes, timestamp = _timestamp;
@synthesize metadataXML = _metadataXML;

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pb
                              frame:(const NDIlib_video_frame_v2_t *)frame
                             fourCC:(NSString *)fourCC {
    if ((self = [super init])) {
        _pixelBuffer = (CVPixelBufferRef)CFRetain(pb);
        _width = frame->xres;
        _height = frame->yres;
        _lineStrideInBytes = frame->line_stride_in_bytes;
        _timestamp = frame->timestamp;
        _fourCC = [fourCC copy];
        // DEEP-COPIED, like the source strings: p_metadata points into memory the SDK owns and
        // reclaims at framesync_free_video, which happens the moment the pixel buffer's last
        // reference drops — i.e. potentially before the string is read. NULL is normal and means
        // exactly what it says: this sender declared no per-frame metadata. stringWithUTF8String
        // returns nil on invalid UTF-8, which lands in the same "no metadata" branch downstream.
        _metadataXML = frame->p_metadata ? [NSString stringWithUTF8String:frame->p_metadata] : nil;
    }
    return self;
}

- (CVPixelBufferRef)pixelBuffer { return _pixelBuffer; }

- (void)dealloc {
    if (_pixelBuffer) CFRelease(_pixelBuffer);   // may run NDIFrameRelease
}

@end

// MARK: - Bridge

@implementation NDIBridge {
    NDIReceiver *_receiver;
    int64_t _lastTimestamp;
    BOOL _loggedFirstFrame;
    BOOL _loggedUnexpectedFourCC;
}

+ (BOOL)loadRuntime {
    static dispatch_once_t once;
    static BOOL ok = NO;
    dispatch_once(&once, ^{ ok = NDILoadOnce(); });
    return ok;
}

+ (NSString *)loaderSymbol { return gLoaderSymbol; }
+ (NSString *)runtimeVersion { return gRuntimeVersion; }
+ (NSString *)runtimePath { return gRuntimePath; }

+ (NDIBridge *)connectToFirstSourceWithTimeout:(NSTimeInterval)timeout {
    if (![self loadRuntime]) return nil;

    // Discovery. show_local_sources so a sender on THIS machine is visible too.
    NDIlib_find_create_t findSettings;
    memset(&findSettings, 0, sizeof(findSettings));
    findSettings.show_local_sources = true;
    findSettings.p_groups = NULL;
    findSettings.p_extra_ips = NULL;

    NDIlib_find_instance_t finder = gNDI->find_create_v2(&findSettings);
    if (!finder) {
        NSLog(@"[NDI] find_create_v2 failed");
        return nil;
    }

    NSString *name = nil;
    NSString *url = nil;
    NDIlib_source_t connectTo;
    memset(&connectTo, 0, sizeof(connectTo));

    // Deep-copied source strings live here for the lifetime of the recv_create call — the SDK's
    // char* buffers are only valid until the next get_current_sources / find_destroy, so we must
    // own the bytes we hand back to recv_create_v3.
    std::string nameStorage;
    std::string urlStorage;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0 && !name) {
        gNDI->find_wait_for_sources(finder, 1000);
        uint32_t count = 0;
        const NDIlib_source_t *sources = gNDI->find_get_current_sources(finder, &count);
        if (sources && count > 0) {
            NSLog(@"[NDI] discovery found %u source(s):", count);
            for (uint32_t i = 0; i < count; i++) {
                NSLog(@"[NDI]   [%u] %s  (%s)", i,
                      sources[i].p_ndi_name ?: "<unnamed>",
                      sources[i].p_url_address ?: "<no url>");
            }
            // STEP A: take the first. A real source picker arrives with source switching.
            if (sources[0].p_ndi_name) {
                nameStorage = sources[0].p_ndi_name;
                name = [NSString stringWithUTF8String:nameStorage.c_str()];
            }
            if (sources[0].p_url_address) {
                urlStorage = sources[0].p_url_address;
                url = [NSString stringWithUTF8String:urlStorage.c_str()];
            }
        }
    }

    if (!name) {
        NSLog(@"[NDI] no sources found within %.0fs", timeout);
        gNDI->find_destroy(finder);
        return nil;
    }

    connectTo.p_ndi_name = nameStorage.c_str();
    connectTo.p_url_address = urlStorage.empty() ? NULL : urlStorage.c_str();

    NDIlib_recv_create_v3_t recvSettings;
    memset(&recvSettings, 0, sizeof(recvSettings));
    recvSettings.source_to_connect_to = connectTo;
    // Force the 8-bit UYVY path. NOT _best: _best would hand us P216 (10-bit) from a 10-bit
    // sender, and the 10-bit/P216 path is a deferred step — this one proves the pipe.
    recvSettings.color_format = NDIlib_recv_color_format_UYVY_BGRA;
    recvSettings.bandwidth = NDIlib_recv_bandwidth_highest;
    // Let NDI de-interlace rather than handing us fields to reassemble — field handling is not
    // this step's problem.
    recvSettings.allow_video_fields = false;
    recvSettings.p_ndi_recv_name = NULL;

    NDIlib_recv_instance_t recv = gNDI->recv_create_v3(&recvSettings);
    gNDI->find_destroy(finder);   // finder's strings are dead after this — we copied what we need

    if (!recv) {
        NSLog(@"[NDI] recv_create_v3 failed for \"%@\"", name);
        return nil;
    }

    // FrameSync, not raw capture: it owns the jitter buffer and gives us "the current frame" on
    // OUR clock (the display tick), which is exactly the pull model the renderer wants.
    NDIlib_framesync_instance_t framesync = gNDI->framesync_create(recv);
    if (!framesync) {
        NSLog(@"[NDI] framesync_create failed");
        gNDI->recv_destroy(recv);
        return nil;
    }

    NDIReceiver *receiver = [[NDIReceiver alloc] init];
    receiver->_recv = recv;
    receiver->_framesync = framesync;

    NDIBridge *bridge = [[NDIBridge alloc] init];
    bridge->_receiver = receiver;
    bridge->_sourceName = [name copy];
    NSLog(@"[NDI] connected to \"%@\" (%@) — UYVY, highest bandwidth, FrameSync", name, url ?: @"no url");
    return bridge;
}

@synthesize sourceName = _sourceName;

- (NDIVideoFrame *)captureVideoFrame {
    NDIReceiver *receiver = _receiver;
    if (!gNDI || !receiver || !receiver->_framesync) return nil;

    NDIlib_video_frame_v2_t frame;
    memset(&frame, 0, sizeof(frame));
    // Non-blocking: returns whatever FrameSync currently holds (and repeats the last frame if the
    // source hasn't produced a new one since our last tick).
    gNDI->framesync_capture_video(receiver->_framesync, &frame,
                                  NDIlib_frame_format_type_progressive);

    if (!frame.p_data || frame.xres <= 0 || frame.yres <= 0) {
        gNDI->framesync_free_video(receiver->_framesync, &frame);   // no-op on an empty frame, but correct
        return nil;
    }

    // FrameSync repeats the current frame on every pull. At 60Hz on a 30fps source that is half
    // our ticks — skip them rather than re-running the pixel conversion on identical bytes. The
    // renderer simply keeps displaying the frame it already has.
    if (frame.timestamp != 0 && frame.timestamp != NDIlib_recv_timestamp_undefined &&
        frame.timestamp == _lastTimestamp) {
        gNDI->framesync_free_video(receiver->_framesync, &frame);
        return nil;
    }
    _lastTimestamp = frame.timestamp;

    const uint32_t fourCC = (uint32_t)frame.FourCC;
    NSString *fourCCString = [NSString stringWithFormat:@"%c%c%c%c",
                              (char)(fourCC & 0xFF), (char)((fourCC >> 8) & 0xFF),
                              (char)((fourCC >> 16) & 0xFF), (char)((fourCC >> 24) & 0xFF)];

    if (frame.FourCC != NDIlib_FourCC_video_type_UYVY) {
        // We asked for UYVY_BGRA, so a BGRA frame here means an alpha-bearing source. Out of
        // scope for step A — report it once instead of silently rendering garbage.
        if (!_loggedUnexpectedFourCC) {
            _loggedUnexpectedFourCC = YES;
            NSLog(@"[NDI] unsupported FourCC '%@' (expected UYVY) — frames ignored this step",
                  fourCCString);
        }
        gNDI->framesync_free_video(receiver->_framesync, &frame);
        return nil;
    }

    // ZERO-COPY: wrap NDI's own buffer. No memcpy — the pixel buffer points straight at
    // frame.p_data, and the release callback below hands that exact frame back to FrameSync when
    // the last reader lets go. Lifetime and copy-avoidance fall out of the same mechanism.
    NDIFrameContext *ctx = new NDIFrameContext();
    ctx->frame = frame;
    ctx->receiver = (__bridge_retained void *)receiver;   // freed in NDIFrameRelease

    CVPixelBufferRef pb = NULL;
    CVReturn status = CVPixelBufferCreateWithBytes(
        kCFAllocatorDefault,
        frame.xres, frame.yres,
        kCVPixelFormatType_422YpCbCr8,          // '2vuy' — packed UYVY, byte-identical to NDI's layout
        frame.p_data,
        frame.line_stride_in_bytes,
        NDIFrameRelease, ctx,
        NULL, &pb);

    if (status != kCVReturnSuccess || !pb) {
        NSLog(@"[NDI] CVPixelBufferCreateWithBytes failed (%d)", status);
        NDIFrameRelease(ctx, NULL);   // releases receiver + frees the NDI frame
        return nil;
    }

    // NO colorimetry tagging here. This buffer used to be stamped Rec.709 unconditionally, and that
    // hardcode WAS the bug: the UYVY->x422 conversion downstream propagates whatever attachments it
    // finds on its source, so the assumption was carried intact to the display buffer, the scopes
    // and the EDR gate — a PQ source read 709 because we had told it to. The real signaling is in
    // frame.p_metadata (copied into metadataXML above); the receive path parses it and applies the
    // CICP attachments (NDIColorInfo), to this buffer and to the conversion's output.

    if (!_loggedFirstFrame) {
        _loggedFirstFrame = YES;
        NSLog(@"[NDI] first frame: %dx%d FourCC=%@ stride=%d (expected %d for packed UYVY)",
              frame.xres, frame.yres, fourCCString, frame.line_stride_in_bytes, frame.xres * 2);
        NSLog(@"[NDI] first frame metadata: %@",
              frame.p_metadata ? [NSString stringWithUTF8String:frame.p_metadata] : @"<none>");
    }

    NDIVideoFrame *result = [[NDIVideoFrame alloc] initWithPixelBuffer:pb frame:&frame fourCC:fourCCString];
    CFRelease(pb);   // the NDIVideoFrame holds the only reference now
    return result;
}

- (void)disconnect {
    // Just drop our reference. Any frame still in flight holds the receiver alive and will free
    // itself against a live framesync instance; the last release tears everything down in order.
    _receiver = nil;
}

- (void)dealloc {
    [self disconnect];
}

@end
