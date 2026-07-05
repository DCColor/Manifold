#import "DeckLinkBridge.h"

// The DeckLink SDK header (C++/COM). Resolved via HEADER_SEARCH_PATHS pointing at
// docs/BlackmagicDeckLinkSDK16.0/Mac/include. The matching DeckLinkAPIDispatch.cpp is compiled
// into this target and provides CreateDeckLinkIteratorInstance + the IID constants at link time;
// the installed Desktop Video driver provides the runtime. No dylib/framework to link.
#include "DeckLinkAPI.h"

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

#pragma mark - Bridge

// GetModelName / GetDisplayName return a NEWLY-CREATED CFStringRef via out-param on macOS (the
// SDK's dl_string maps to CFStringRef here). The caller owns it, so __bridge_transfer hands the
// +1 to ARC (no leak). Nil-safe.
static NSString *NSStringTakeDeckLink(CFStringRef s) {
    if (s == NULL) { return @""; }
    return (__bridge_transfer NSString *)s;
}

@implementation DeckLinkBridge {
    // Held across start/stop so the displayed frame stays alive on the output (C++ ivars are fine
    // in the .mm — objcpp). Retained by -startTestFrameOutputOnDevice0, released by -stopTestOutput.
    IDeckLinkOutput *_heldOutput;
    IDeckLinkMutableVideoFrame *_heldFrame;
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

- (void)dealloc {
    [self stopTestOutput];
}

@end
