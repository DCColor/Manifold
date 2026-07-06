#import "DeckLinkBridge.h"

// The DeckLink SDK header (C++/COM). Resolved via HEADER_SEARCH_PATHS pointing at
// docs/BlackmagicDeckLinkSDK16.0/Mac/include. The matching DeckLinkAPIDispatch.cpp is compiled
// into this target and provides CreateDeckLinkIteratorInstance + the IID constants at link time;
// the installed Desktop Video driver provides the runtime. No dylib/framework to link.
#include "DeckLinkAPI.h"

#include <vector>
#include <functional>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>

#pragma mark - Value object

@implementation DeckLinkDeviceInfo {
    NSInteger _index;
    NSString *_modelName;
    NSString *_displayName;
}

- (instancetype)initWithIndex:(NSInteger)index
                    modelName:(NSString *)modelName
                  displayName:(NSString *)displayName {
    if ((self = [super init])) {
        _index = index;
        _modelName = [modelName copy];
        _displayName = [displayName copy];
    }
    return self;
}

- (NSInteger)index { return _index; }
- (NSString *)modelName { return _modelName; }
- (NSString *)displayName { return _displayName; }

@end

#pragma mark - Output result

@implementation DeckLinkOutputResult {
    BOOL _success;
    NSArray<NSString *> *_log;
}
- (instancetype)initWithSuccess:(BOOL)success log:(NSArray<NSString *> *)log {
    if ((self = [super init])) {
        _success = success;
        _log = [log copy];
    }
    return self;
}
- (BOOL)success { return _success; }
- (NSArray<NSString *> *)log { return _log; }
@end

#pragma mark - D3 scheduled player (synthetic, pluggable fill source)

// Pluggable frame-fill: given a frame index + a target v210 buffer, fill it. Knows NOTHING about
// DeckLink — the scheduling loop calls it blind. This is the seam where the synthetic hue-walk is
// later swapped for the Metal/decoded-frame path WITHOUT touching the scheduler. Dimensions/rowBytes
// come from the output mode (passed in), not hardcoded.
typedef std::function<void(int64_t frameIndex, uint8_t *buffer, int32_t rowBytes, int32_t width, int32_t height)> FrameFillFn;

// --- Synthetic fill: a solid-color per-frame HUE WALK. Steady color change on the monitor == frames
// advancing on the clock; a frozen color == a stall. No spatial pattern (a solid proves advance).
static void HSVtoRGB(double h, double s, double v, double &r, double &g, double &b) {
    double c = v * s;
    double hp = h / 60.0;
    double x = c * (1.0 - fabs(fmod(hp, 2.0) - 1.0));
    double r1 = 0, g1 = 0, b1 = 0;
    if      (hp < 1) { r1 = c; g1 = x; }
    else if (hp < 2) { r1 = x; g1 = c; }
    else if (hp < 3) { g1 = c; b1 = x; }
    else if (hp < 4) { g1 = x; b1 = c; }
    else if (hp < 5) { r1 = x; b1 = c; }
    else             { r1 = c; b1 = x; }
    double m = v - c;
    r = r1 + m; g = g1 + m; b = b1 + m;
}

// BT.709 LIMITED-range 10-bit YCbCr (v210): Y' 64..940, Cb/Cr 64..960 (8-bit ×4).
static void RGBtoYCbCr709Limited10(double r, double g, double b, uint32_t &Y, uint32_t &Cb, uint32_t &Cr) {
    const double yf = 0.2126 * r + 0.7152 * g + 0.0722 * b;   // full-range luma [0,1]
    const double y  = 64.0  + 876.0 * yf;
    const double cb = 512.0 + 896.0 * (b - yf) / 1.8556;
    const double cr = 512.0 + 896.0 * (r - yf) / 1.5748;
    auto clamp10 = [](double v, double lo, double hi) { return (uint32_t)std::lround(std::min(hi, std::max(lo, v))); };
    Y  = clamp10(y,  64, 940);
    Cb = clamp10(cb, 64, 960);
    Cr = clamp10(cr, 64, 960);
}

// Synthetic hue-walk (D3 debug/fallback) — now v210 10-bit so it stays valid against the v210 frame
// format. Solid color per frame → all Y/Cb/Cr equal, so the four v210 words are a fixed pattern
// repeated per 6-pixel group (respecting the 128-byte-aligned rowBytes).
static void SyntheticHueWalkFill(int64_t frameIndex, uint8_t *buffer, int32_t rowBytes, int32_t width, int32_t height) {
    const double hue = fmod((double)frameIndex * 2.0, 360.0);   // +2°/frame → full cycle ~7.5 s at 23.98
    double r, g, b;  HSVtoRGB(hue, 0.65, 0.80, r, g, b);
    uint32_t Y, Cb, Cr;  RGBtoYCbCr709Limited10(r, g, b, Y, Cb, Cr);
    // Solid v210: Word0=Cb|Y|Cr, Word1=Y|Cb|Y, Word2=Cr|Y|Cb, Word3=Y|Cr|Y.
    const uint32_t w0 = Cb | (Y  << 10) | (Cr << 20);
    const uint32_t w1 = Y  | (Cb << 10) | (Y  << 20);
    const uint32_t w2 = Cr | (Y  << 10) | (Cb << 20);
    const uint32_t w3 = Y  | (Cr << 10) | (Y  << 20);
    const int32_t groupsPerRow = rowBytes / 16;   // full padded row
    for (int32_t y = 0; y < height; y++) {
        uint32_t *p = (uint32_t *)(buffer + (size_t)y * (size_t)rowBytes);
        for (int32_t g6 = 0; g6 < groupsPerRow; g6++) {
            p[0] = w0; p[1] = w1; p[2] = w2; p[3] = w3; p += 4;
        }
    }
}

// The scheduled-playback engine + the frame-completion callback in ONE ref-counted object (the SDK
// requires an IDeckLinkVideoOutputCallback). Owns the IDeckLinkOutput, a small reusable frame POOL,
// the running frame index, and the pluggable fill fn. All output access is encapsulated here so
// start/stop ordering and cleanup live in one place.
class DeckLinkScheduledPlayer : public IDeckLinkVideoOutputCallback {
public:
    DeckLinkScheduledPlayer(IDeckLinkOutput *output,
                            int32_t width, int32_t height, int32_t rowBytes,
                            BMDTimeValue frameDuration, BMDTimeScale timeScale,
                            FrameFillFn fill, int64_t colorspace)
        : m_refCount(1), m_output(output),
          m_width(width), m_height(height), m_rowBytes(rowBytes),
          m_frameDuration(frameDuration), m_timeScale(timeScale),
          m_fill(std::move(fill)), m_running(false), m_nextIndex(0),
          m_completed(0), m_late(0), m_dropped(0), m_flushed(0),
          m_colorspace(colorspace) {
        m_output->AddRef();
    }

    // Output colorspace TAG (BMDColorspace) — set on each scheduled frame's metadata so the monitor
    // knows what it's receiving. Chosen upstream by the source PRIMARIES code (never the matrix).
    // Updated live via setColorspace so a mid-session source change is picked up on the next frame.
    void setColorspace(int64_t colorspace) { m_colorspace = colorspace; }

    // --- Setup steps (called from the Obj-C bridge, each bool-returning so it can log per-step) ---

    bool doesSupportMode() {
        BMDDisplayMode actual = bmdModeUnknown; bool supported = false;
        HRESULT hr = m_output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, bmdMode4K2160p2398,
                                                    bmdFormat10BitYUV, bmdNoVideoOutputConversion,
                                                    bmdSupportedVideoModeDefault, &actual, &supported);
        return (hr == S_OK && supported);
    }

    bool enableOutput() {
        return m_output->EnableVideoOutput(bmdMode4K2160p2398, bmdVideoOutputFlagDefault) == S_OK;
    }

    bool createPool(int poolSize) {
        for (int i = 0; i < poolSize; i++) {
            IDeckLinkMutableVideoFrame *f = NULL;
            if (m_output->CreateVideoFrame(m_width, m_height, m_rowBytes, bmdFormat10BitYUV,
                                           bmdFrameFlagDefault, &f) != S_OK || f == NULL)
                return false;
            m_pool.push_back(f);
        }
        return true;
    }

    // Register self as the completion callback + arm the running flag.
    void beginRunning() {
        m_running = true;
        m_output->SetScheduledFrameCompletionCallback(this);
    }

    // Pre-roll: fill + schedule one frame per pool slot (indices 0..pool-1).
    bool preroll() {
        for (size_t i = 0; i < m_pool.size(); i++) {
            const int64_t idx = m_nextIndex.fetch_add(1);
            if (!fillFrame(m_pool[i], idx)) return false;
            tagFrame(m_pool[i]);   // colorspace metadata (source primaries → BMDColorspace)
            if (m_output->ScheduleVideoFrame(m_pool[i], idx * m_frameDuration, m_frameDuration, m_timeScale) != S_OK)
                return false;
        }
        return true;
    }

    bool startPlayback() {
        return m_output->StartScheduledPlayback(0, m_timeScale, 1.0) == S_OK;
    }

    // Clean, idempotent stop. Safe even if never started, and safe against an in-flight callback:
    // m_running is cleared FIRST (so any flush callback won't reschedule), then playback is stopped
    // and the callback unset (SDK stops invoking us) BEFORE the pool/output are released.
    void stop() {
        m_running = false;
        if (m_output) {
            BMDTimeValue actualStop = 0;
            m_output->StopScheduledPlayback(0, &actualStop, m_timeScale);
            m_output->SetScheduledFrameCompletionCallback(NULL);
            m_output->DisableVideoOutput();
        }
        for (auto *f : m_pool) { if (f) f->Release(); }
        m_pool.clear();
        if (m_output) { m_output->Release(); m_output = NULL; }
    }

    // Stats (read after stop for the run summary).
    int64_t  framesScheduled() const { return m_nextIndex.load(); }
    uint64_t completedCount()  const { return m_completed.load(); }
    uint64_t lateCount()       const { return m_late.load(); }
    uint64_t droppedCount()    const { return m_dropped.load(); }
    uint64_t flushedCount()    const { return m_flushed.load(); }

    // --- IUnknown ---
    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (ppv == nullptr) return E_POINTER;
        CFUUIDBytes iunknown = CFUUIDGetUUIDBytes(IUnknownUUID);
        if (memcmp(&iid, &iunknown, sizeof(REFIID)) == 0) { *ppv = this; AddRef(); return S_OK; }
        if (memcmp(&iid, &IID_IDeckLinkVideoOutputCallback, sizeof(REFIID)) == 0) {
            *ppv = static_cast<IDeckLinkVideoOutputCallback *>(this); AddRef(); return S_OK;
        }
        *ppv = nullptr; return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++m_refCount; }
    ULONG Release() override { ULONG r = --m_refCount; if (r == 0) delete this; return r; }

    // --- IDeckLinkVideoOutputCallback (runs on the SDK's dedicated callback thread) ---
    HRESULT ScheduledFrameCompleted(IDeckLinkVideoFrame *completedFrame, BMDOutputFrameCompletionResult result) override {
        // Tally + immediately surface any non-Completed result (the "is scheduling keeping up?" signal).
        switch (result) {
            case bmdOutputFrameCompleted:     m_completed.fetch_add(1); break;
            case bmdOutputFrameDisplayedLate: m_late.fetch_add(1);
                fprintf(stdout, "DeckLink D3: !! DisplayedLate at frame %lld\n", (long long)m_nextIndex.load()); fflush(stdout); break;
            case bmdOutputFrameDropped:       m_dropped.fetch_add(1);
                fprintf(stdout, "DeckLink D3: !! Dropped at frame %lld\n", (long long)m_nextIndex.load()); fflush(stdout); break;
            case bmdOutputFrameFlushed:       m_flushed.fetch_add(1); break;   // expected during stop
            default: break;
        }

        // Stopping (or a flush during stop): do NOT reschedule / touch output.
        if (!m_running.load() || result == bmdOutputFrameFlushed) return S_OK;

        // Reuse the just-completed frame (guaranteed free): refill with the next color, reschedule.
        IDeckLinkMutableVideoFrame *frame = static_cast<IDeckLinkMutableVideoFrame *>(completedFrame);
        const int64_t idx = m_nextIndex.fetch_add(1);
        fillFrame(frame, idx);
        tagFrame(frame);   // re-tag per-schedule so a mid-session colorspace change is picked up
        m_output->ScheduleVideoFrame(frame, idx * m_frameDuration, m_frameDuration, m_timeScale);

        // Periodic queue-depth + completion summary (~every 48 frames ≈ 2 s).
        if ((idx % 48) == 0) {
            uint32_t buffered = 0; m_output->GetBufferedVideoFrameCount(&buffered);
            fprintf(stdout, "DeckLink D3: frame %lld — completed=%llu late=%llu dropped=%llu buffered=%u\n",
                    (long long)idx, (unsigned long long)m_completed.load(),
                    (unsigned long long)m_late.load(), (unsigned long long)m_dropped.load(), buffered);
            fflush(stdout);
        }
        return S_OK;
    }

    HRESULT ScheduledPlaybackHasStopped(void) override {
        fprintf(stdout, "DeckLink D3: ScheduledPlaybackHasStopped\n"); fflush(stdout);
        return S_OK;
    }

private:
    ~DeckLinkScheduledPlayer() { }   // deleted via Release(); output/pool already freed by stop()

    bool fillFrame(IDeckLinkMutableVideoFrame *frame, int64_t frameIndex) {
        IDeckLinkVideoBuffer *buffer = NULL;
        if (frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buffer) != S_OK || buffer == NULL) return false;
        if (buffer->StartAccess(bmdBufferAccessWrite) != S_OK) { buffer->Release(); return false; }
        void *bytes = NULL;
        if (buffer->GetBytes(&bytes) != S_OK || bytes == NULL) {
            buffer->EndAccess(bmdBufferAccessWrite); buffer->Release(); return false;
        }
        m_fill(frameIndex, (uint8_t *)bytes, m_rowBytes, m_width, m_height);   // pluggable — no DeckLink knowledge
        buffer->EndAccess(bmdBufferAccessWrite);
        buffer->Release();
        return true;
    }

    // Tag the frame's colorspace metadata (BMDColorspace) so the monitor knows the signal. Set per
    // schedule from the live m_colorspace atomic (handles source change + any per-output clearing).
    void tagFrame(IDeckLinkMutableVideoFrame *frame) {
        IDeckLinkVideoFrameMutableMetadataExtensions *meta = NULL;
        if (frame->QueryInterface(IID_IDeckLinkVideoFrameMutableMetadataExtensions, (void **)&meta) == S_OK && meta != NULL) {
            meta->SetInt(bmdDeckLinkFrameMetadataColorspace, m_colorspace.load());
            meta->Release();
        }
    }

    std::atomic<ULONG> m_refCount;
    IDeckLinkOutput *m_output;
    int32_t m_width, m_height, m_rowBytes;
    BMDTimeValue m_frameDuration;
    BMDTimeScale m_timeScale;
    FrameFillFn m_fill;
    std::vector<IDeckLinkMutableVideoFrame *> m_pool;
    std::atomic<bool> m_running;
    std::atomic<int64_t> m_nextIndex;
    std::atomic<uint64_t> m_completed, m_late, m_dropped, m_flushed;
    std::atomic<int64_t> m_colorspace;   // BMDColorspace tag (from source primaries), live-updatable
};

// Output colorspace TAG from the source CICP PRIMARIES code ONLY (never the matrix). P3 has no
// native output tag, so P3-D65 / DCI-P3 are signalled as Rec.2020 (P3-in-2020 monitoring convention).
static int64_t BMDColorspaceForPrimaries(NSInteger primariesCode) {
    switch (primariesCode) {
        case 9:            return bmdColorspaceRec2020;   // Rec.2020
        case 11: case 12:  return bmdColorspaceRec2020;   // DCI-P3 / P3-D65 → P3-in-2020
        case 1:            return bmdColorspaceRec709;    // Rec.709
        default:           return bmdColorspaceRec709;    // nil / 2 (unspecified) / unknown → 709
    }
}

#pragma mark - Bridge

// GetModelName / GetDisplayName return a NEWLY-CREATED CFStringRef via out-param on macOS (the
// SDK's dl_string maps to CFStringRef here). The caller owns it, so __bridge_transfer hands the
// +1 to ARC (no leak). Nil-safe.
static NSString *NSStringTakeDeckLink(CFStringRef s) {
    if (s == NULL) { return @""; }
    return (__bridge_transfer NSString *)s;
}

// Private: the shared start sequence parameterized by a C++ FrameFillFn (C++ type in the selector,
// so it can only live in the .mm). Public entry points wrap their fill and forward here.
@interface DeckLinkBridge ()
- (DeckLinkOutputResult *)startScheduledPlaybackWithFillFn:(FrameFillFn)fill
                                               deviceIndex:(NSInteger)deviceIndex
                                                colorspace:(int64_t)colorspace;
@end

@implementation DeckLinkBridge {
    // Held across start/stop so the displayed frame stays alive on the output (C++ ivars are fine
    // in the .mm — objcpp). Retained by -startTestFrameOutputOnDevice0, released by -stopTestOutput.
    IDeckLinkOutput *_heldOutput;
    IDeckLinkMutableVideoFrame *_heldFrame;
    // D3 scheduled-playback engine (owns its own output + frame pool + callback). nil when stopped.
    DeckLinkScheduledPlayer *_player;
}

+ (NSArray<DeckLinkDeviceInfo *> *)enumerateOutputDevices {
    NSMutableArray<DeckLinkDeviceInfo *> *devices = [NSMutableArray array];

    // Plain C entry point on macOS (no COM initialization needed).
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (iterator == NULL) {
        // Driver not installed / SDK runtime unavailable.
        return devices;
    }

    IDeckLink *device = NULL;
    NSInteger index = 0;
    while (iterator->Next(&device) == S_OK) {
        // Output-capable? A device that vends IDeckLinkOutput supports playback.
        IDeckLinkOutput *output = NULL;
        HRESULT hr = device->QueryInterface(IID_IDeckLinkOutput, (void **)&output);
        if (hr == S_OK && output != NULL) {
            CFStringRef modelName = NULL;
            CFStringRef displayName = NULL;
            device->GetModelName(&modelName);
            device->GetDisplayName(&displayName);

            DeckLinkDeviceInfo *info =
                [[DeckLinkDeviceInfo alloc] initWithIndex:index
                                                modelName:NSStringTakeDeckLink(modelName)
                                              displayName:NSStringTakeDeckLink(displayName)];
            [devices addObject:info];

            output->Release();   // balance the QueryInterface +1
        }
        device->Release();       // balance the Next() +1
        device = NULL;
        index++;
    }

    iterator->Release();         // balance CreateDeckLinkIteratorInstance +1
    return devices;
}

#pragma mark - D2: first light (one synthetic frame, held on the output)

- (DeckLinkOutputResult *)startTestFrameOutputOnDevice0 {
    NSMutableArray<NSString *> *log = [NSMutableArray array];

    // Re-fire cleanly: tear down any previously-held output first.
    [self stopTestOutput];

    // (b) Version floor — Desktop Video >= 14.3 (the IOSurface/zero-copy floor). Read the INSTALLED
    // driver's runtime API version (not the SDK header). Encoding is 0xMMmmpp00 (see DeviceList sample).
    {
        IDeckLinkAPIInformation *apiInfo = CreateDeckLinkAPIInformationInstance();
        if (apiInfo == NULL) {
            [log addObject:@"version: DeckLink API information unavailable (driver not reachable) — aborting"];
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
        }
        int64_t apiVersion = 0;
        apiInfo->GetInt(BMDDeckLinkAPIVersion, &apiVersion);
        apiInfo->Release();

        const int major = (int)((apiVersion & 0xFF000000) >> 24);
        const int minor = (int)((apiVersion & 0x00FF0000) >> 16);
        const int point = (int)((apiVersion & 0x0000FF00) >> 8);
        NSString *verStr = [NSString stringWithFormat:@"%d.%d.%d", major, minor, point];
        if (major < 14 || (major == 14 && minor < 3)) {
            [log addObject:[NSString stringWithFormat:
                @"version floor: DeckLink output requires Desktop Video 14.3 or later; installed: %@ — aborting", verStr]];
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
        }
        [log addObject:[NSString stringWithFormat:@"version: Desktop Video %@ (>= 14.3 floor OK)", verStr]];
    }

    // (a) Device index 0 + IDeckLinkOutput.
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (iterator == NULL) {
        [log addObject:@"device: iterator unavailable — aborting"];
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    IDeckLink *target = NULL;
    {
        IDeckLink *device = NULL;
        NSInteger idx = 0;
        while (iterator->Next(&device) == S_OK) {
            if (idx == 0) { target = device; /* keep */ break; }
            device->Release();
            idx++;
        }
    }
    iterator->Release();
    if (target == NULL) {
        [log addObject:@"device: index 0 not found — aborting"];
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }

    IDeckLinkOutput *output = NULL;
    HRESULT hr = target->QueryInterface(IID_IDeckLinkOutput, (void **)&output);
    CFStringRef nameRef = NULL;
    target->GetDisplayName(&nameRef);
    NSString *name = NSStringTakeDeckLink(nameRef);
    target->Release();   // `output` holds its own reference; safe to drop the device now
    if (hr != S_OK || output == NULL) {
        [log addObject:@"device: index 0 has no IDeckLinkOutput — aborting"];
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:[NSString stringWithFormat:@"device: index 0 = \"%@\", IDeckLinkOutput acquired", name]];

    // (c) DoesSupportVideoMode for 2160p23.98 / 8-bit YUV / output.
    BMDDisplayMode actualMode = bmdModeUnknown;
    bool supported = false;
    hr = output->DoesSupportVideoMode(bmdVideoConnectionUnspecified,
                                      bmdMode4K2160p2398,
                                      bmdFormat8BitYUV,
                                      bmdNoVideoOutputConversion,
                                      bmdSupportedVideoModeDefault,
                                      &actualMode,
                                      &supported);
    if (hr != S_OK || !supported) {
        [log addObject:@"mode: 2160p23.98 / 8-bit YUV NOT supported on device 0 — aborting"];
        output->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:@"mode: 2160p23.98 / 8-bit YUV supported"];

    // (d) EnableVideoOutput.
    hr = output->EnableVideoOutput(bmdMode4K2160p2398, bmdVideoOutputFlagDefault);
    if (hr != S_OK) {
        [log addObject:[NSString stringWithFormat:@"enable: EnableVideoOutput failed (hr=0x%08X) — aborting", (unsigned)hr]];
        output->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:@"enable: video output enabled"];

    // (e) CreateVideoFrame (3840x2160, rowBytes from RowBytesForPixelFormat).
    const int32_t width = 3840, height = 2160;
    int32_t rowBytes = 0;
    output->RowBytesForPixelFormat(bmdFormat8BitYUV, width, &rowBytes);
    IDeckLinkMutableVideoFrame *frame = NULL;
    hr = output->CreateVideoFrame(width, height, rowBytes, bmdFormat8BitYUV, bmdFrameFlagDefault, &frame);
    if (hr != S_OK || frame == NULL) {
        [log addObject:[NSString stringWithFormat:@"frame: CreateVideoFrame failed (hr=0x%08X) — aborting", (unsigned)hr]];
        output->DisableVideoOutput();
        output->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:[NSString stringWithFormat:@"frame: created %dx%d 2vuy, rowBytes=%d", width, height, rowBytes]];

    // (f) Fill with a solid mid-saturation ORANGE. 2vuy packs 4:2:2 as [Cb, Y0, Cr, Y1] per pixel
    // pair. Values are BT.709 LIMITED range for RGB(230,120,40): Y=134, Cb=82, Cr=180. Byte access
    // in SDK 16.0 is via IDeckLinkVideoBuffer (StartAccess / GetBytes / EndAccess).
    {
        const uint8_t Y = 134, Cb = 82, Cr = 180;
        IDeckLinkVideoBuffer *buffer = NULL;
        hr = frame->QueryInterface(IID_IDeckLinkVideoBuffer, (void **)&buffer);
        if (hr != S_OK || buffer == NULL) {
            [log addObject:@"fill: IDeckLinkVideoBuffer unavailable — aborting"];
            frame->Release(); output->DisableVideoOutput(); output->Release();
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
        }
        if (buffer->StartAccess(bmdBufferAccessWrite) != S_OK) {
            [log addObject:@"fill: StartAccess(write) failed — aborting"];
            buffer->Release(); frame->Release(); output->DisableVideoOutput(); output->Release();
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
        }
        void *bytes = NULL;
        if (buffer->GetBytes(&bytes) != S_OK || bytes == NULL) {
            [log addObject:@"fill: GetBytes failed — aborting"];
            buffer->EndAccess(bmdBufferAccessWrite); buffer->Release();
            frame->Release(); output->DisableVideoOutput(); output->Release();
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
        }
        uint8_t *base = (uint8_t *)bytes;
        for (int y = 0; y < height; y++) {
            uint8_t *p = base + (size_t)y * (size_t)rowBytes;
            for (int x = 0; x < width; x += 2) {
                p[0] = Cb; p[1] = Y; p[2] = Cr; p[3] = Y;
                p += 4;
            }
        }
        buffer->EndAccess(bmdBufferAccessWrite);
        buffer->Release();
        [log addObject:@"fill: solid orange (2vuy Cb=82 Y=134 Cr=180 Y=134)"];
    }

    // (g) DisplayVideoFrameSync — put the frame on the output now.
    hr = output->DisplayVideoFrameSync(frame);
    if (hr != S_OK) {
        [log addObject:[NSString stringWithFormat:@"display: DisplayVideoFrameSync failed (hr=0x%08X) — aborting", (unsigned)hr]];
        frame->Release(); output->DisableVideoOutput(); output->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:@"display: DisplayVideoFrameSync OK — frame on output"];

    // (h) HOLD: keep output enabled + frame retained so it stays on the monitor until -stopTestOutput.
    _heldOutput = output;
    _heldFrame = frame;
    [log addObject:@"held: output enabled + frame retained (call stop to clear)"];
    return [[DeckLinkOutputResult alloc] initWithSuccess:YES log:log];
}

- (void)stopTestOutput {
    if (_heldOutput != NULL) {
        _heldOutput->DisableVideoOutput();   // stop using the frame before releasing it
    }
    if (_heldFrame != NULL) {
        _heldFrame->Release();
        _heldFrame = NULL;
    }
    if (_heldOutput != NULL) {
        _heldOutput->Release();
        _heldOutput = NULL;
    }
}

#pragma mark - D3: scheduled (continuous free-running) playback

// Shared start sequence — parameterized by the pluggable fill (C++ FrameFillFn). Private (C++ type
// in the selector, so .mm-only). The public entry points wrap their fill and call this.
- (DeckLinkOutputResult *)startScheduledPlaybackWithFillFn:(FrameFillFn)fill
                                               deviceIndex:(NSInteger)deviceIndex
                                                colorspace:(int64_t)colorspace {
    NSMutableArray<NSString *> *log = [NSMutableArray array];

    // Re-fire cleanly.
    [self stopScheduledPlayback];

    // Version floor — Desktop Video >= 14.3 (same check as D2).
    {
        IDeckLinkAPIInformation *apiInfo = CreateDeckLinkAPIInformationInstance();
        if (apiInfo == NULL) {
            [log addObject:@"version: DeckLink API information unavailable — aborting"];
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
        }
        int64_t apiVersion = 0;
        apiInfo->GetInt(BMDDeckLinkAPIVersion, &apiVersion);
        apiInfo->Release();
        const int major = (int)((apiVersion & 0xFF000000) >> 24);
        const int minor = (int)((apiVersion & 0x00FF0000) >> 16);
        const int point = (int)((apiVersion & 0x0000FF00) >> 8);
        NSString *verStr = [NSString stringWithFormat:@"%d.%d.%d", major, minor, point];
        if (major < 14 || (major == 14 && minor < 3)) {
            [log addObject:[NSString stringWithFormat:
                @"version floor: DeckLink output requires Desktop Video 14.3 or later; installed: %@ — aborting", verStr]];
            return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
        }
        [log addObject:[NSString stringWithFormat:@"version: Desktop Video %@ (>= 14.3 floor OK)", verStr]];
    }

    // Device at `deviceIndex` + IDeckLinkOutput.
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (iterator == NULL) {
        [log addObject:@"device: iterator unavailable — aborting"];
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    IDeckLink *target = NULL;
    {
        IDeckLink *device = NULL; NSInteger idx = 0;
        while (iterator->Next(&device) == S_OK) {
            if (idx == deviceIndex) { target = device; break; }
            device->Release(); idx++;
        }
    }
    iterator->Release();
    if (target == NULL) {
        [log addObject:[NSString stringWithFormat:@"device: index %ld not found — aborting", (long)deviceIndex]];
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    IDeckLinkOutput *output = NULL;
    HRESULT hr = target->QueryInterface(IID_IDeckLinkOutput, (void **)&output);
    CFStringRef nameRef = NULL; target->GetDisplayName(&nameRef);
    NSString *name = NSStringTakeDeckLink(nameRef);
    target->Release();
    if (hr != S_OK || output == NULL) {
        [log addObject:[NSString stringWithFormat:@"device: index %ld has no IDeckLinkOutput — aborting", (long)deviceIndex]];
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:[NSString stringWithFormat:@"device: index %ld = \"%@\", IDeckLinkOutput acquired", (long)deviceIndex, name]];

    // SEAM: dimensions + frame rate come from the OUTPUT MODE object, not hardcoded. (Resolution
    // independence slots in here later — a different mode drives width/height/rowBytes/timescale.)
    IDeckLinkDisplayMode *mode = NULL;
    if (output->GetDisplayMode(bmdMode4K2160p2398, &mode) != S_OK || mode == NULL) {
        [log addObject:@"mode: could not resolve 2160p23.98 display mode — aborting"];
        output->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    const int32_t width  = (int32_t)mode->GetWidth();
    const int32_t height = (int32_t)mode->GetHeight();
    BMDTimeValue frameDuration = 0; BMDTimeScale timeScale = 0;
    mode->GetFrameRate(&frameDuration, &timeScale);
    mode->Release();
    int32_t rowBytes = 0;
    output->RowBytesForPixelFormat(bmdFormat10BitYUV, width, &rowBytes);   // authoritative v210 stride (128-aligned)
    [log addObject:[NSString stringWithFormat:@"mode: %dx%d @ %lld/%lld (duration/timescale), v210 rowBytes=%d",
                    width, height, (long long)timeScale, (long long)frameDuration, rowBytes]];

    // Build the player (SEAM: fill source is pluggable — synthetic hue-walk for D3). The player
    // AddRefs the output; drop our local ref. `colorspace` is the output signal tag (from source
    // primaries) applied to each scheduled frame's metadata.
    DeckLinkScheduledPlayer *player =
        new DeckLinkScheduledPlayer(output, width, height, rowBytes, frameDuration, timeScale, fill, colorspace);
    output->Release();
    [log addObject:[NSString stringWithFormat:@"tag: output colorspace = %@",
                    (colorspace == bmdColorspaceRec2020 ? @"Rec.2020" : @"Rec.709")]];

    if (!player->doesSupportMode()) {
        [log addObject:@"mode: 2160p23.98 / v210 10-bit YUV NOT supported — aborting"];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:@"mode: 2160p23.98 / v210 10-bit YUV supported"];

    if (!player->enableOutput()) {
        [log addObject:@"enable: EnableVideoOutput failed — aborting"];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:@"enable: video output enabled"];

    const int poolSize = 4;
    if (!player->createPool(poolSize)) {
        [log addObject:@"pool: CreateVideoFrame failed — aborting"];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:[NSString stringWithFormat:@"pool: %d reusable frames created", poolSize]];

    player->beginRunning();   // set completion callback + arm
    [log addObject:@"callback: SetScheduledFrameCompletionCallback installed"];

    if (!player->preroll()) {
        [log addObject:@"preroll: ScheduleVideoFrame failed — aborting"];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:[NSString stringWithFormat:@"preroll: %d frames scheduled (indices 0..%d)", poolSize, poolSize - 1]];

    if (!player->startPlayback()) {
        [log addObject:@"start: StartScheduledPlayback failed — aborting"];
        player->stop(); player->Release();
        return [[DeckLinkOutputResult alloc] initWithSuccess:NO log:log];
    }
    [log addObject:@"start: StartScheduledPlayback(0, timescale, 1.0) OK — free-running"];

    _player = player;   // held; callback keeps the pipeline full until -stopScheduledPlayback
    return [[DeckLinkOutputResult alloc] initWithSuccess:YES log:log];
}

// Public: synthetic hue-walk on device 0 (D3 — debug/fallback). No source → tag Rec.709.
- (DeckLinkOutputResult *)startScheduledPlaybackOnDevice0 {
    return [self startScheduledPlaybackWithFillFn:FrameFillFn(&SyntheticHueWalkFill)
                                      deviceIndex:0
                                       colorspace:bmdColorspaceRec709];
}

// Public: REAL video (D-real) on a chosen device. Wrap the Obj-C fill block into the C++ FrameFillFn
// the scheduler expects; the std::function retains the (heap-copied) block for the player's lifetime.
// The block itself sources pixels (renderer.copyLatest…) and handles the neutral fallback — the
// scheduler stays source-agnostic. `primariesCode` → the output colorspace TAG (SEPARATE from the
// kernel's encoding matrix, which the renderer selects from the matrix code).
- (DeckLinkOutputResult *)startScheduledPlaybackWithDeviceIndex:(NSInteger)deviceIndex
                                                          fill:(DeckLinkFillBlock)fill
                                                 primariesCode:(NSInteger)primariesCode {
    DeckLinkFillBlock block = [fill copy];
    FrameFillFn fn = [block](int64_t frameIndex, uint8_t *buffer, int32_t rowBytes, int32_t width, int32_t height) {
        (void)block(frameIndex, buffer, rowBytes, width, height);
    };
    return [self startScheduledPlaybackWithFillFn:fn
                                      deviceIndex:deviceIndex
                                       colorspace:BMDColorspaceForPrimaries(primariesCode)];
}

// Update the output colorspace tag mid-session (source colorspace changed while output is running).
// Per-schedule tagging means the next scheduled frame picks this up — no in-flight re-tag race.
- (void)setOutputColorspaceForPrimaries:(NSInteger)primariesCode {
    if (_player != NULL) { _player->setColorspace(BMDColorspaceForPrimaries(primariesCode)); }
}

- (void)stopScheduledPlayback {
    if (_player != NULL) {
        _player->stop();      // StopScheduledPlayback → unset callback → DisableVideoOutput → free pool/output
        // Final run summary (post-stop, so counts are settled).
        fprintf(stdout, "DeckLink D3: stopped — scheduled=%lld completed=%llu late=%llu dropped=%llu flushed=%llu\n",
                (long long)_player->framesScheduled(),
                (unsigned long long)_player->completedCount(),
                (unsigned long long)_player->lateCount(),
                (unsigned long long)_player->droppedCount(),
                (unsigned long long)_player->flushedCount());
        fflush(stdout);
        _player->Release();   // drops the construction ref → delete
        _player = NULL;
    }
}

- (void)dealloc {
    [self stopTestOutput];
    [self stopScheduledPlayback];
}

@end
